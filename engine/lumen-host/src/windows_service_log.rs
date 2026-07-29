use std::fs::File;
#[cfg(not(windows))]
use std::fs::OpenOptions;
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::Duration;

use crossbeam_queue::ArrayQueue;
use serde::Serialize;

#[cfg(windows)]
const SERVICE_EVENT_LOG_FILE: &str = "service-events.jsonl";
#[cfg(windows)]
const ROTATED_SERVICE_EVENT_LOG_FILE: &str = "service-events.1.jsonl";
const SERVICE_EVENT_LANE_CAPACITY: usize = 1;
const PUBLISH_STOPPING: usize = 1 << (usize::BITS - 1);
const PUBLISH_COUNT_MASK: usize = PUBLISH_STOPPING - 1;
#[cfg(not(test))]
const LOG_WORKER_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(1);
#[cfg(test)]
const LOG_WORKER_SHUTDOWN_TIMEOUT: Duration = Duration::from_millis(100);
#[cfg(windows)]
const MAXIMUM_SERVICE_EVENT_LOG_BYTES: u64 = 256 * 1024;
#[cfg(windows)]
const SERVICE_EVENT_DIRECTORY_SDDL: &str = "O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
#[cfg(windows)]
const SERVICE_EVENT_FILE_SDDL: &str = "O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub(crate) struct WindowsAdaptiveVideoApplyEvent {
    event: &'static str,
    pub(crate) session_epoch: u32,
    pub(crate) encoder_epoch: u64,
    pub(crate) requested_bitrate_bps: u32,
    pub(crate) applied_bitrate_bps: u32,
}

impl WindowsAdaptiveVideoApplyEvent {
    pub(crate) fn new(
        session_epoch: u32,
        encoder_epoch: u64,
        requested_bitrate_bps: u32,
        applied_bitrate_bps: u32,
    ) -> Self {
        Self {
            event: "windows_adaptive_video_apply",
            session_epoch,
            encoder_epoch,
            requested_bitrate_bps,
            applied_bitrate_bps,
        }
    }

    fn ordering_key(self) -> u64 {
        self.encoder_epoch
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WindowsServiceEventPublishStatus {
    Queued,
    Coalesced,
    Dropped,
}

pub(crate) trait WindowsServiceEventPublisher: Send + Sync {
    fn publish_adaptive_video_apply(
        &self,
        event: WindowsAdaptiveVideoApplyEvent,
    ) -> WindowsServiceEventPublishStatus;
}

struct ServiceEventLaneShared {
    pending: ArrayQueue<WindowsAdaptiveVideoApplyEvent>,
    pending_update: Mutex<()>,
    wake: mpsc::SyncSender<()>,
    publish_state: AtomicUsize,
    last_event_order: AtomicU64,
    coalesced_events: AtomicU64,
    dropped_events: AtomicU64,
    write_failures: AtomicU64,
    abandoned_workers: AtomicU64,
}

impl ServiceEventLaneShared {
    fn is_stopping(&self) -> bool {
        self.publish_state.load(Ordering::Acquire) & PUBLISH_STOPPING != 0
    }

    fn active_publishers(&self) -> usize {
        self.publish_state.load(Ordering::Acquire) & PUBLISH_COUNT_MASK
    }

    fn stop_admission(&self) {
        self.publish_state
            .fetch_or(PUBLISH_STOPPING, Ordering::AcqRel);
        let _ = self.wake.try_send(());
    }

    fn try_admit(self: &Arc<Self>) -> Option<PublishPermit> {
        let mut state = self.publish_state.load(Ordering::Acquire);
        loop {
            if state & PUBLISH_STOPPING != 0 || state & PUBLISH_COUNT_MASK == PUBLISH_COUNT_MASK {
                self.dropped_events.fetch_add(1, Ordering::Relaxed);
                return None;
            }
            match self.publish_state.compare_exchange_weak(
                state,
                state + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    return Some(PublishPermit {
                        shared: Arc::clone(self),
                        accounted: false,
                    });
                }
                Err(current) => state = current,
            }
        }
    }
}

struct PublishPermit {
    shared: Arc<ServiceEventLaneShared>,
    accounted: bool,
}

impl PublishPermit {
    fn finish(mut self, published: bool) {
        if !published {
            self.shared.dropped_events.fetch_add(1, Ordering::Relaxed);
        }
        self.accounted = true;
    }
}

impl Drop for PublishPermit {
    fn drop(&mut self) {
        if !self.accounted {
            self.shared.dropped_events.fetch_add(1, Ordering::Relaxed);
        }
        let previous = self.shared.publish_state.fetch_sub(1, Ordering::AcqRel);
        if previous & PUBLISH_STOPPING != 0 {
            let _ = self.shared.wake.try_send(());
        }
    }
}

struct WindowsServiceEventLanePublisher {
    shared: Arc<ServiceEventLaneShared>,
}

impl WindowsServiceEventPublisher for WindowsServiceEventLanePublisher {
    fn publish_adaptive_video_apply(
        &self,
        event: WindowsAdaptiveVideoApplyEvent,
    ) -> WindowsServiceEventPublishStatus {
        publish_adaptive_video_apply(&self.shared, event, || {}, || {})
    }
}

fn publish_adaptive_video_apply(
    shared: &Arc<ServiceEventLaneShared>,
    event: WindowsAdaptiveVideoApplyEvent,
    admitted: impl FnOnce(),
    ordered: impl FnOnce(),
) -> WindowsServiceEventPublishStatus {
    let Some(permit) = shared.try_admit() else {
        return WindowsServiceEventPublishStatus::Dropped;
    };
    admitted();
    if shared.is_stopping() {
        return WindowsServiceEventPublishStatus::Dropped;
    }
    ordered();
    let Ok(_pending_update) = shared.pending_update.try_lock() else {
        return WindowsServiceEventPublishStatus::Dropped;
    };
    let order = event.ordering_key();
    let latest = shared.last_event_order.load(Ordering::Acquire);
    if order < latest {
        return WindowsServiceEventPublishStatus::Dropped;
    }
    match shared.wake.try_send(()) {
        Ok(()) | Err(mpsc::TrySendError::Full(())) => {}
        Err(mpsc::TrySendError::Disconnected(())) => {
            return WindowsServiceEventPublishStatus::Dropped;
        }
    }
    let coalesced = shared.pending.force_push(event).is_some();
    if order > latest {
        shared.last_event_order.store(order, Ordering::Release);
    }
    let status = if coalesced {
        shared.coalesced_events.fetch_add(1, Ordering::Relaxed);
        WindowsServiceEventPublishStatus::Coalesced
    } else {
        WindowsServiceEventPublishStatus::Queued
    };
    permit.finish(true);
    status
}

trait ServiceEventWriter: Send {
    fn write_event(&mut self, event: WindowsAdaptiveVideoApplyEvent) -> Result<(), String>;
    fn flush(&mut self) -> Result<(), String>;
}

pub(crate) struct WindowsServiceEventLane {
    shared: Arc<ServiceEventLaneShared>,
    worker: Option<thread::JoinHandle<()>>,
    worker_completed: Mutex<mpsc::Receiver<()>>,
}

impl WindowsServiceEventLane {
    #[cfg(windows)]
    pub(crate) fn from_program_data() -> Result<Self, String> {
        let path = program_data_lumen_path(SERVICE_EVENT_LOG_FILE)
            .ok_or_else(|| "Windows ProgramData is unavailable for service events".to_owned())?;
        let rotated_path =
            program_data_lumen_path(ROTATED_SERVICE_EVENT_LOG_FILE).ok_or_else(|| {
                "Windows ProgramData is unavailable for rotated service events".to_owned()
            })?;
        Self::start(Box::new(BoundedJsonlServiceEventWriter::new(
            path,
            rotated_path,
            MAXIMUM_SERVICE_EVENT_LOG_BYTES,
        )))
    }

    fn start(writer: Box<dyn ServiceEventWriter>) -> Result<Self, String> {
        let (wake, receiver) = mpsc::sync_channel(SERVICE_EVENT_LANE_CAPACITY);
        let (completion, worker_completed) = mpsc::sync_channel(1);
        let shared = Arc::new(ServiceEventLaneShared {
            pending: ArrayQueue::new(SERVICE_EVENT_LANE_CAPACITY),
            pending_update: Mutex::new(()),
            wake,
            publish_state: AtomicUsize::new(0),
            last_event_order: AtomicU64::new(0),
            coalesced_events: AtomicU64::new(0),
            dropped_events: AtomicU64::new(0),
            write_failures: AtomicU64::new(0),
            abandoned_workers: AtomicU64::new(0),
        });
        let worker_shared = Arc::clone(&shared);
        let worker = thread::Builder::new()
            .name("lumen-windows-service-event-log".to_owned())
            .spawn(move || {
                run_service_event_lane(receiver, worker_shared, writer);
                let _ = completion.send(());
            })
            .map_err(|error| format!("start Windows service event log worker: {error}"))?;
        Ok(Self {
            shared,
            worker: Some(worker),
            worker_completed: Mutex::new(worker_completed),
        })
    }

    pub(crate) fn publisher(&self) -> Arc<dyn WindowsServiceEventPublisher> {
        Arc::new(WindowsServiceEventLanePublisher {
            shared: Arc::clone(&self.shared),
        })
    }

    pub(crate) fn shutdown(&mut self) {
        let Some(worker) = self.worker.take() else {
            return;
        };
        self.shared.stop_admission();
        match self
            .worker_completed
            .get_mut()
            .expect("exclusive service event lane owns completion state")
            .recv_timeout(LOG_WORKER_SHUTDOWN_TIMEOUT)
        {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) if worker.is_finished() => {
                if worker.join().is_err() {
                    self.shared.write_failures.fetch_add(1, Ordering::Relaxed);
                }
            }
            Ok(()) => {
                if worker.join().is_err() {
                    self.shared.write_failures.fetch_add(1, Ordering::Relaxed);
                }
            }
            Err(_) => {
                self.shared
                    .abandoned_workers
                    .fetch_add(1, Ordering::Relaxed);
                record_windows_log_worker_abandonment();
                drop(worker);
            }
        }
    }

    #[cfg(test)]
    fn diagnostics(&self) -> WindowsServiceEventDiagnostics {
        WindowsServiceEventDiagnostics {
            coalesced_events: self.shared.coalesced_events.load(Ordering::Acquire),
            dropped_events: self.shared.dropped_events.load(Ordering::Acquire),
            write_failures: self.shared.write_failures.load(Ordering::Acquire),
            abandoned_workers: self.shared.abandoned_workers.load(Ordering::Acquire),
        }
    }

    #[cfg(test)]
    fn pending_event_count(&self) -> usize {
        self.shared.pending.len()
    }
}

#[cfg(windows)]
fn record_windows_log_worker_abandonment() {
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::System::EventLog::{
        DeregisterEventSource, RegisterEventSourceW, ReportEventW, EVENTLOG_WARNING_TYPE,
    };

    let source = "LumenService".encode_utf16().chain([0]).collect::<Vec<_>>();
    let message = "Lumen service event log worker exceeded its shutdown deadline and was detached"
        .encode_utf16()
        .chain([0])
        .collect::<Vec<_>>();
    let event_source = unsafe { RegisterEventSourceW(null(), source.as_ptr()) };
    if event_source.is_null() {
        return;
    }
    let strings = [message.as_ptr()];
    unsafe {
        ReportEventW(
            event_source,
            EVENTLOG_WARNING_TYPE,
            0,
            1,
            null_mut(),
            1,
            0,
            strings.as_ptr(),
            null_mut(),
        );
        DeregisterEventSource(event_source);
    }
}

#[cfg(not(windows))]
fn record_windows_log_worker_abandonment() {}

impl Drop for WindowsServiceEventLane {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct WindowsServiceEventDiagnostics {
    coalesced_events: u64,
    dropped_events: u64,
    write_failures: u64,
    abandoned_workers: u64,
}

fn run_service_event_lane(
    receiver: mpsc::Receiver<()>,
    shared: Arc<ServiceEventLaneShared>,
    mut writer: Box<dyn ServiceEventWriter>,
) {
    while receiver.recv().is_ok() {
        loop {
            let (event, latest_order) = {
                let _pending_update = shared
                    .pending_update
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                (
                    shared.pending.pop(),
                    shared.last_event_order.load(Ordering::Acquire),
                )
            };
            let Some(event) = event else {
                break;
            };
            if event.ordering_key() < latest_order {
                shared.dropped_events.fetch_add(1, Ordering::Relaxed);
            } else if writer.write_event(event).is_err() {
                shared.write_failures.fetch_add(1, Ordering::Relaxed);
            }
        }
        if shared.is_stopping() && shared.active_publishers() == 0 {
            break;
        }
    }
    if writer.flush().is_err() {
        shared.write_failures.fetch_add(1, Ordering::Relaxed);
    }
}

struct BoundedJsonlServiceEventWriter {
    path: PathBuf,
    rotated_path: PathBuf,
    maximum_bytes: u64,
    file: Option<File>,
    current_bytes: u64,
}

impl BoundedJsonlServiceEventWriter {
    fn new(path: PathBuf, rotated_path: PathBuf, maximum_bytes: u64) -> Self {
        Self {
            path,
            rotated_path,
            maximum_bytes,
            file: None,
            current_bytes: 0,
        }
    }

    fn open(&mut self) -> Result<(), String> {
        let directory = self
            .path
            .parent()
            .ok_or_else(|| "Windows service event log has no parent directory".to_owned())?;
        validate_service_event_directory(directory)
            .map_err(|error| format!("validate Windows service event log directory: {error}"))?;
        remove_if_oversized(&self.path, self.maximum_bytes)?;
        remove_if_oversized(&self.rotated_path, self.maximum_bytes)?;
        #[cfg(windows)]
        {
            remove_untrusted_service_event_file(&self.path)?;
            remove_untrusted_service_event_file(&self.rotated_path)?;
        }
        #[cfg(windows)]
        let file = open_secure_service_event_file(&self.path)
            .map_err(|error| format!("open Windows service event log: {error}"))?;
        #[cfg(not(windows))]
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .map_err(|error| format!("open Windows service event log: {error}"))?;
        #[cfg(windows)]
        if let Err(error) = validate_service_event_file_security(&self.path) {
            drop(file);
            let _ = std::fs::remove_file(&self.path);
            return Err(format!(
                "validate Windows service event log file security: {error}"
            ));
        }
        self.current_bytes = file
            .metadata()
            .map_err(|error| format!("inspect Windows service event log: {error}"))?
            .len();
        self.file = Some(file);
        Ok(())
    }

    fn rotate(&mut self) -> Result<(), String> {
        if let Some(file) = self.file.take() {
            file.sync_data().map_err(|error| {
                format!("persist Windows service event log before rotate: {error}")
            })?;
        }
        match std::fs::remove_file(&self.rotated_path) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "replace rotated Windows service event log: {error}"
                ));
            }
        }
        match std::fs::rename(&self.path, &self.rotated_path) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(format!("rotate Windows service event log: {error}")),
        }
        self.current_bytes = 0;
        self.open()
    }
}

impl ServiceEventWriter for BoundedJsonlServiceEventWriter {
    fn write_event(&mut self, event: WindowsAdaptiveVideoApplyEvent) -> Result<(), String> {
        let mut line = serde_json::to_vec(&event)
            .map_err(|error| format!("serialize Windows adaptive video event: {error}"))?;
        line.push(b'\n');
        let line_bytes = u64::try_from(line.len())
            .map_err(|_| "Windows service event exceeds the platform size range".to_owned())?;
        if line_bytes > self.maximum_bytes {
            return Err("Windows service event exceeds the bounded log size".to_owned());
        }
        if self.file.is_none() {
            self.open()?;
        }
        if self.current_bytes.saturating_add(line_bytes) > self.maximum_bytes {
            self.rotate()?;
        }
        let file = self
            .file
            .as_mut()
            .ok_or_else(|| "Windows service event log is unavailable".to_owned())?;
        if let Err(error) = file.write_all(&line) {
            self.file.take();
            return Err(format!("append Windows service event log: {error}"));
        }
        self.current_bytes += line_bytes;
        file.sync_data()
            .map_err(|error| format!("persist Windows service event log: {error}"))?;
        Ok(())
    }

    fn flush(&mut self) -> Result<(), String> {
        let Some(file) = self.file.as_mut() else {
            return Ok(());
        };
        file.flush()
            .and_then(|()| file.sync_data())
            .map_err(|error| format!("flush Windows service event log: {error}"))
    }
}

fn remove_if_oversized(path: &Path, maximum_bytes: u64) -> Result<(), String> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("inspect Windows service event log bound: {error}")),
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err("Windows service event log target is not a physical file".to_owned());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err("Windows service event log target is a reparse point".to_owned());
        }
    }
    match metadata.len() {
        length if length > maximum_bytes => std::fs::remove_file(path)
            .map_err(|error| format!("replace oversized Windows service event log: {error}")),
        _ => Ok(()),
    }
}

#[cfg(windows)]
fn remove_untrusted_service_event_file(path: &Path) -> Result<(), String> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => match validate_service_event_file_security(path) {
            Ok(()) => Ok(()),
            Err(_) => std::fs::remove_file(path)
                .map_err(|error| format!("replace untrusted Windows service event log: {error}")),
        },
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "inspect Windows service event log security: {error}"
        )),
    }
}

#[cfg(windows)]
fn open_secure_service_event_file(path: &Path) -> std::io::Result<File> {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::FromRawHandle;
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{LocalFree, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_APPEND_DATA, FILE_ATTRIBUTE_NORMAL, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ, OPEN_ALWAYS,
    };

    struct OwnedLocal(*mut c_void);

    impl Drop for OwnedLocal {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }

    let descriptor_sddl = SERVICE_EVENT_FILE_SDDL
        .encode_utf16()
        .chain([0])
        .collect::<Vec<_>>();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            descriptor_sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            null_mut(),
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    let _descriptor = OwnedLocal(descriptor);
    let security = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    let path = path
        .as_os_str()
        .encode_wide()
        .chain([0])
        .collect::<Vec<_>>();
    let handle = unsafe {
        CreateFileW(
            path.as_ptr(),
            FILE_APPEND_DATA | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ,
            &security,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_handle(handle) })
}

#[cfg(windows)]
pub(crate) fn prepare_program_data_lumen_directory() -> std::io::Result<()> {
    let path = program_data_lumen_path(SERVICE_EVENT_LOG_FILE).ok_or_else(|| {
        std::io::Error::new(
            ErrorKind::NotFound,
            "Windows ProgramData is unavailable for service events",
        )
    })?;
    let directory = path.parent().ok_or_else(|| {
        std::io::Error::new(
            ErrorKind::InvalidInput,
            "Windows service event log has no parent directory",
        )
    })?;
    validate_service_event_directory(directory)
}

fn validate_service_event_directory(directory: &Path) -> std::io::Result<()> {
    let metadata = std::fs::symlink_metadata(directory)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(std::io::Error::new(
            ErrorKind::PermissionDenied,
            "Windows service event log directory is not a physical directory",
        ));
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(std::io::Error::new(
                ErrorKind::PermissionDenied,
                "Windows service event log directory is a reparse point",
            ));
        }
        validate_service_event_directory_security(directory)?;
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct NormalizedAccessRule {
    ace_type: u8,
    ace_flags: u8,
    access_mask: u32,
    sid: Vec<u8>,
}

fn semantic_access_policy_matches(
    owner_matches: bool,
    dacl_is_protected: bool,
    expected_protected: bool,
    expected: &[NormalizedAccessRule],
    actual: &[NormalizedAccessRule],
) -> bool {
    if !owner_matches || dacl_is_protected != expected_protected {
        return false;
    }
    let mut expected = expected.to_vec();
    let mut actual = actual.to_vec();
    expected.sort_unstable();
    actual.sort_unstable();
    actual == expected
}

#[cfg(windows)]
fn validate_service_event_directory_security(directory: &Path) -> std::io::Result<()> {
    validate_service_event_path_security(directory, WindowsSecurityTarget::Directory)
}

#[cfg(windows)]
fn validate_service_event_file_security(path: &Path) -> std::io::Result<()> {
    validate_service_event_path_security(path, WindowsSecurityTarget::File)
}

#[cfg(windows)]
#[derive(Clone, Copy)]
enum WindowsSecurityTarget {
    Directory,
    File,
}

#[cfg(windows)]
fn validate_service_event_path_security(
    path: &Path,
    target: WindowsSecurityTarget,
) -> std::io::Result<()> {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr::{addr_of, null_mut};
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, GetNamedSecurityInfoW,
        SDDL_REVISION_1, SE_FILE_OBJECT,
    };
    use windows_sys::Win32::Security::{
        EqualSid, GetAce, GetLengthSid, GetSecurityDescriptorControl, GetSecurityDescriptorDacl,
        GetSecurityDescriptorOwner, ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, CONTAINER_INHERIT_ACE,
        DACL_SECURITY_INFORMATION, OBJECT_INHERIT_ACE, OWNER_SECURITY_INFORMATION,
        PSECURITY_DESCRIPTOR, PSID, SE_DACL_PROTECTED,
    };
    use windows_sys::Win32::System::SystemServices::ACCESS_ALLOWED_ACE_TYPE;

    struct OwnedLocal(*mut c_void);

    impl Drop for OwnedLocal {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }

    unsafe fn normalized_access_rules(acl: *mut ACL) -> Option<Vec<NormalizedAccessRule>> {
        if acl.is_null() {
            return None;
        }
        let mut rules = Vec::with_capacity(usize::from(unsafe { (*acl).AceCount }));
        for index in 0..u32::from(unsafe { (*acl).AceCount }) {
            let mut raw_ace = null_mut();
            if unsafe { GetAce(acl, index, &mut raw_ace) } == 0 || raw_ace.is_null() {
                return None;
            }
            let header = unsafe { &*raw_ace.cast::<ACE_HEADER>() };
            if u32::from(header.AceType) != ACCESS_ALLOWED_ACE_TYPE
                || usize::from(header.AceSize) < std::mem::size_of::<ACCESS_ALLOWED_ACE>()
            {
                return None;
            }
            let ace = unsafe { &*raw_ace.cast::<ACCESS_ALLOWED_ACE>() };
            let sid = addr_of!(ace.SidStart).cast_mut().cast::<c_void>();
            let sid_length = unsafe { GetLengthSid(sid) };
            let sid_offset = std::mem::size_of::<ACCESS_ALLOWED_ACE>() - std::mem::size_of::<u32>();
            if sid_length == 0
                || sid_offset.saturating_add(usize::try_from(sid_length).ok()?)
                    > usize::from(header.AceSize)
            {
                return None;
            }
            let sid = unsafe {
                std::slice::from_raw_parts(sid.cast::<u8>(), usize::try_from(sid_length).ok()?)
            }
            .to_vec();
            rules.push(NormalizedAccessRule {
                ace_type: ace.Header.AceType,
                ace_flags: ace.Header.AceFlags,
                access_mask: ace.Mask,
                sid,
            });
        }
        Some(rules)
    }

    let path = path
        .as_os_str()
        .encode_wide()
        .chain([0])
        .collect::<Vec<_>>();
    let mut actual_owner: PSID = null_mut();
    let mut actual_dacl: *mut ACL = null_mut();
    let mut actual_descriptor: PSECURITY_DESCRIPTOR = null_mut();
    let status = unsafe {
        GetNamedSecurityInfoW(
            path.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut actual_owner,
            null_mut(),
            &mut actual_dacl,
            null_mut(),
            &mut actual_descriptor,
        )
    };
    if status != 0 {
        return Err(std::io::Error::from_raw_os_error(
            i32::try_from(status).unwrap_or(i32::MAX),
        ));
    }
    let _actual_descriptor = OwnedLocal(actual_descriptor);

    let expected_sddl = SERVICE_EVENT_DIRECTORY_SDDL
        .encode_utf16()
        .chain([0])
        .collect::<Vec<_>>();
    let mut expected_descriptor: PSECURITY_DESCRIPTOR = null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            expected_sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut expected_descriptor,
            null_mut(),
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    let _expected_descriptor = OwnedLocal(expected_descriptor);
    let mut expected_owner: PSID = null_mut();
    let mut owner_defaulted = 0;
    if unsafe {
        GetSecurityDescriptorOwner(
            expected_descriptor,
            &mut expected_owner,
            &mut owner_defaulted,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    let mut expected_dacl: *mut ACL = null_mut();
    let mut dacl_present = 0;
    let mut dacl_defaulted = 0;
    if unsafe {
        GetSecurityDescriptorDacl(
            expected_descriptor,
            &mut dacl_present,
            &mut expected_dacl,
            &mut dacl_defaulted,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    let mut actual_control = 0;
    let mut actual_revision = 0;
    if unsafe {
        GetSecurityDescriptorControl(actual_descriptor, &mut actual_control, &mut actual_revision)
    } == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    let owner_matches = !actual_owner.is_null()
        && !expected_owner.is_null()
        && unsafe { EqualSid(actual_owner, expected_owner) } != 0;
    let Some(mut expected_rules) = (dacl_present != 0)
        .then(|| unsafe { normalized_access_rules(expected_dacl) })
        .flatten()
    else {
        return Err(std::io::Error::new(
            ErrorKind::InvalidData,
            "Windows service event log expected DACL is invalid",
        ));
    };
    let Some(actual_rules) = (unsafe { normalized_access_rules(actual_dacl) }) else {
        return Err(std::io::Error::new(
            ErrorKind::PermissionDenied,
            "Windows service event log DACL contains unsupported or invalid ACEs",
        ));
    };
    let (expected_protected, expected_flags) = match target {
        WindowsSecurityTarget::Directory => (
            true,
            u8::try_from(OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE)
                .expect("directory ACE inheritance flags fit in one byte"),
        ),
        WindowsSecurityTarget::File => (true, 0),
    };
    for rule in &mut expected_rules {
        rule.ace_flags = expected_flags;
    }
    let dacl_is_protected = actual_control & SE_DACL_PROTECTED != 0;
    if !semantic_access_policy_matches(
        owner_matches,
        dacl_is_protected,
        expected_protected,
        &expected_rules,
        &actual_rules,
    ) {
        return Err(std::io::Error::new(
            ErrorKind::PermissionDenied,
            "Windows service event log directory owner or DACL is untrusted",
        ));
    }
    Ok(())
}

#[cfg(windows)]
pub(crate) fn program_data_lumen_path(file_name: &str) -> Option<PathBuf> {
    std::env::var_os("ProgramData").map(|program_data| {
        std::path::Path::new(&program_data)
            .join("Lumen")
            .join(file_name)
    })
}

#[cfg(test)]
mod tests {
    use super::{
        publish_adaptive_video_apply, BoundedJsonlServiceEventWriter, NormalizedAccessRule,
        ServiceEventLaneShared, ServiceEventWriter, WindowsAdaptiveVideoApplyEvent,
        WindowsServiceEventLane, WindowsServiceEventPublishStatus, PUBLISH_COUNT_MASK,
        SERVICE_EVENT_LANE_CAPACITY,
    };
    use crossbeam_queue::ArrayQueue;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::Duration;

    struct RecordingWriter {
        events: Arc<Mutex<Vec<WindowsAdaptiveVideoApplyEvent>>>,
        entered: Option<mpsc::SyncSender<()>>,
        release: Option<mpsc::Receiver<()>>,
        fail: bool,
        flushes: Arc<Mutex<usize>>,
    }

    impl ServiceEventWriter for RecordingWriter {
        fn write_event(&mut self, event: WindowsAdaptiveVideoApplyEvent) -> Result<(), String> {
            if let Some(entered) = self.entered.take() {
                entered.send(()).unwrap();
            }
            if let Some(release) = self.release.take() {
                release.recv().unwrap();
            }
            if self.fail {
                return Err("injected service event write failure".to_owned());
            }
            self.events.lock().unwrap().push(event);
            Ok(())
        }

        fn flush(&mut self) -> Result<(), String> {
            *self.flushes.lock().unwrap() += 1;
            Ok(())
        }
    }

    fn event(epoch: u32, bitrate_bps: u32) -> WindowsAdaptiveVideoApplyEvent {
        WindowsAdaptiveVideoApplyEvent::new(epoch, u64::from(epoch), bitrate_bps, bitrate_bps)
    }

    fn ordered_event(
        session_epoch: u32,
        encoder_epoch: u64,
        bitrate_bps: u32,
    ) -> WindowsAdaptiveVideoApplyEvent {
        WindowsAdaptiveVideoApplyEvent::new(session_epoch, encoder_epoch, bitrate_bps, bitrate_bps)
    }

    fn access_rule(sid: u8, ace_flags: u8) -> NormalizedAccessRule {
        NormalizedAccessRule {
            ace_type: 0,
            ace_flags,
            access_mask: 0x001f_01ff,
            sid: vec![sid],
        }
    }

    #[test]
    fn semantic_acl_validation_ignores_rule_order_only() {
        let expected = vec![access_rule(18, 3), access_rule(32, 3)];
        let actual = vec![access_rule(32, 3), access_rule(18, 3)];
        assert!(super::semantic_access_policy_matches(
            true, true, true, &expected, &actual
        ));
    }

    #[test]
    fn semantic_acl_validation_rejects_extra_deny_rights_and_inheritance() {
        let expected = vec![access_rule(18, 3), access_rule(32, 3)];
        let mut extra = expected.clone();
        extra.push(access_rule(99, 3));
        assert!(!super::semantic_access_policy_matches(
            true, true, true, &expected, &extra
        ));

        let mut deny = expected.clone();
        deny[0].ace_type = 1;
        assert!(!super::semantic_access_policy_matches(
            true, true, true, &expected, &deny
        ));

        let mut rights = expected.clone();
        rights[0].access_mask = 0x0012_0089;
        assert!(!super::semantic_access_policy_matches(
            true, true, true, &expected, &rights
        ));

        let mut inheritance = expected.clone();
        inheritance[0].ace_flags = 0x10;
        assert!(!super::semantic_access_policy_matches(
            true,
            true,
            true,
            &expected,
            &inheritance
        ));
        assert!(!super::semantic_access_policy_matches(
            false, true, true, &expected, &expected
        ));
        assert!(!super::semantic_access_policy_matches(
            true, false, true, &expected, &expected
        ));
    }

    #[test]
    fn admitted_publisher_is_counted_dropped_before_shutdown_exits() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut lane = WindowsServiceEventLane::start(Box::new(RecordingWriter {
            events: Arc::clone(&events),
            entered: None,
            release: None,
            fail: false,
            flushes: Arc::new(Mutex::new(0)),
        }))
        .unwrap();
        let shared = Arc::clone(&lane.shared);
        let publisher_shared = Arc::clone(&shared);
        let (entered_send, entered_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let publisher = std::thread::spawn(move || {
            publish_adaptive_video_apply(
                &publisher_shared,
                event(7, 60_000_000),
                || {
                    entered_send.send(()).unwrap();
                    release_receive.recv().unwrap();
                },
                || {},
            )
        });

        entered_receive.recv().unwrap();
        shared.stop_admission();
        let shutdown = std::thread::spawn(move || {
            lane.shutdown();
            lane
        });
        release_send.send(()).unwrap();

        assert_eq!(
            publisher.join().unwrap(),
            WindowsServiceEventPublishStatus::Dropped
        );
        let lane = shutdown.join().unwrap();
        assert_eq!(lane.diagnostics().dropped_events, 1);
        assert!(events.lock().unwrap().is_empty());
    }

    #[test]
    fn paused_old_epoch_cannot_replace_a_newer_epoch() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut lane = WindowsServiceEventLane::start(Box::new(RecordingWriter {
            events: Arc::clone(&events),
            entered: None,
            release: None,
            fail: false,
            flushes: Arc::new(Mutex::new(0)),
        }))
        .unwrap();
        let shared = Arc::clone(&lane.shared);
        let publisher_shared = Arc::clone(&shared);
        let (entered_send, entered_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let old = std::thread::spawn(move || {
            publish_adaptive_video_apply(
                &publisher_shared,
                ordered_event(4_000_000_000, 8, 50_000_000),
                || {},
                || {
                    entered_send.send(()).unwrap();
                    release_receive.recv().unwrap();
                },
            )
        });

        entered_receive.recv().unwrap();
        assert_ne!(
            lane.publisher()
                .publish_adaptive_video_apply(ordered_event(1, 9, 70_000_000)),
            WindowsServiceEventPublishStatus::Dropped
        );
        release_send.send(()).unwrap();
        assert_eq!(
            old.join().unwrap(),
            WindowsServiceEventPublishStatus::Dropped
        );
        lane.shutdown();

        assert_eq!(
            events.lock().unwrap().as_slice(),
            [ordered_event(1, 9, 70_000_000)]
        );
    }

    #[test]
    fn smaller_session_epoch_with_newer_encoder_epoch_wins_total_order() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut lane = WindowsServiceEventLane::start(Box::new(RecordingWriter {
            events: Arc::clone(&events),
            entered: None,
            release: None,
            fail: false,
            flushes: Arc::new(Mutex::new(0)),
        }))
        .unwrap();
        let publisher = lane.publisher();

        assert_ne!(
            publisher.publish_adaptive_video_apply(ordered_event(
                u32::MAX,
                u64::MAX - 1,
                50_000_000,
            )),
            WindowsServiceEventPublishStatus::Dropped
        );
        assert_ne!(
            publisher.publish_adaptive_video_apply(ordered_event(1, u64::MAX, 70_000_000)),
            WindowsServiceEventPublishStatus::Dropped
        );
        assert_eq!(
            publisher.publish_adaptive_video_apply(ordered_event(
                u32::MAX,
                u64::MAX - 1,
                60_000_000,
            )),
            WindowsServiceEventPublishStatus::Dropped
        );
        lane.shutdown();

        assert_eq!(
            events.lock().unwrap().last(),
            Some(&ordered_event(1, u64::MAX, 70_000_000))
        );
    }

    #[test]
    fn lock_contended_drop_does_not_advance_order_watermark() {
        let mut lane = WindowsServiceEventLane::start(Box::new(RecordingWriter {
            events: Arc::new(Mutex::new(Vec::new())),
            entered: None,
            release: None,
            fail: false,
            flushes: Arc::new(Mutex::new(0)),
        }))
        .unwrap();
        let publisher = lane.publisher();
        let pending_update = lane.shared.pending_update.lock().unwrap();

        assert_eq!(
            publisher.publish_adaptive_video_apply(ordered_event(1, 99, 70_000_000)),
            WindowsServiceEventPublishStatus::Dropped
        );
        assert_eq!(lane.shared.last_event_order.load(Ordering::Acquire), 0);

        drop(pending_update);
        lane.shutdown();
    }

    #[test]
    fn disconnected_wake_drop_does_not_advance_or_replace_pending_event() {
        let (wake, receiver) = mpsc::sync_channel(SERVICE_EVENT_LANE_CAPACITY);
        drop(receiver);
        let shared = Arc::new(ServiceEventLaneShared {
            pending: ArrayQueue::new(SERVICE_EVENT_LANE_CAPACITY),
            pending_update: Mutex::new(()),
            wake,
            publish_state: AtomicUsize::new(0),
            last_event_order: AtomicU64::new(7),
            coalesced_events: AtomicU64::new(0),
            dropped_events: AtomicU64::new(0),
            write_failures: AtomicU64::new(0),
            abandoned_workers: AtomicU64::new(0),
        });

        assert_eq!(
            publish_adaptive_video_apply(&shared, ordered_event(1, 8, 70_000_000), || {}, || {},),
            WindowsServiceEventPublishStatus::Dropped
        );
        assert_eq!(shared.last_event_order.load(Ordering::Acquire), 7);
        assert!(shared.pending.is_empty());
        assert_eq!(
            shared.publish_state.load(Ordering::Acquire) & PUBLISH_COUNT_MASK,
            0
        );
    }

    #[test]
    fn stalled_filesystem_worker_is_abandoned_after_the_shutdown_deadline() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let flushes = Arc::new(Mutex::new(0));
        let (entered_send, entered_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let mut lane = WindowsServiceEventLane::start(Box::new(RecordingWriter {
            events,
            entered: Some(entered_send),
            release: Some(release_receive),
            fail: false,
            flushes: Arc::clone(&flushes),
        }))
        .unwrap();
        lane.publisher()
            .publish_adaptive_video_apply(event(10, 80_000_000));
        entered_receive.recv().unwrap();

        let started = std::time::Instant::now();
        lane.shutdown();
        assert!(started.elapsed() < Duration::from_secs(1));
        assert_eq!(lane.diagnostics().abandoned_workers, 1);

        release_send.send(()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while *flushes.lock().unwrap() == 0 && std::time::Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert_eq!(*flushes.lock().unwrap(), 1);
    }

    #[test]
    fn hot_path_is_nonblocking_bounded_and_persists_the_latest_event() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let flushes = Arc::new(Mutex::new(0));
        let (entered_send, entered_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let mut lane = WindowsServiceEventLane::start(Box::new(RecordingWriter {
            events: Arc::clone(&events),
            entered: Some(entered_send),
            release: Some(release_receive),
            fail: false,
            flushes: Arc::clone(&flushes),
        }))
        .unwrap();
        let publisher = lane.publisher();

        assert_eq!(
            publisher.publish_adaptive_video_apply(event(1, 40_000_000)),
            WindowsServiceEventPublishStatus::Queued
        );
        entered_receive.recv().unwrap();
        assert_eq!(
            publisher.publish_adaptive_video_apply(event(2, 50_000_000)),
            WindowsServiceEventPublishStatus::Queued
        );
        assert_eq!(
            publisher.publish_adaptive_video_apply(event(3, 60_000_000)),
            WindowsServiceEventPublishStatus::Coalesced
        );
        assert_eq!(lane.pending_event_count(), 1);

        release_send.send(()).unwrap();
        lane.shutdown();

        assert_eq!(
            events.lock().unwrap().as_slice(),
            [event(1, 40_000_000), event(3, 60_000_000)]
        );
        assert_eq!(*flushes.lock().unwrap(), 1);
        assert_eq!(lane.diagnostics().coalesced_events, 1);
        assert_eq!(lane.diagnostics().dropped_events, 0);
    }

    #[test]
    fn writer_failure_is_diagnostic_only_for_the_publisher() {
        let flushes = Arc::new(Mutex::new(0));
        let mut lane = WindowsServiceEventLane::start(Box::new(RecordingWriter {
            events: Arc::new(Mutex::new(Vec::new())),
            entered: None,
            release: None,
            fail: true,
            flushes,
        }))
        .unwrap();
        let publisher = lane.publisher();

        assert_eq!(
            publisher.publish_adaptive_video_apply(event(4, 70_000_000)),
            WindowsServiceEventPublishStatus::Queued
        );
        lane.shutdown();

        assert_eq!(lane.diagnostics().write_failures, 1);
    }

    #[test]
    fn rotating_jsonl_storage_is_strictly_bounded_and_parseable() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("service-events.jsonl");
        let rotated_path = directory.path().join("service-events.1.jsonl");
        let maximum_bytes = 256;
        let mut writer =
            BoundedJsonlServiceEventWriter::new(path.clone(), rotated_path.clone(), maximum_bytes);

        for epoch in 1..=20 {
            writer.write_event(event(epoch, 80_000_000)).unwrap();
        }
        writer.flush().unwrap();

        let current_bytes = std::fs::metadata(&path).unwrap().len();
        let rotated_bytes = std::fs::metadata(&rotated_path).unwrap().len();
        assert!(current_bytes <= maximum_bytes);
        assert!(rotated_bytes <= maximum_bytes);
        assert!(current_bytes + rotated_bytes <= maximum_bytes * 2);
        for log in [path, rotated_path] {
            let body = std::fs::read_to_string(log).unwrap();
            for line in body.lines() {
                let value: serde_json::Value = serde_json::from_str(line).unwrap();
                assert_eq!(value["event"], "windows_adaptive_video_apply");
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn service_event_directory_rejects_a_symbolic_link() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let physical = directory.path().join("physical");
        let link = directory.path().join("link");
        std::fs::create_dir(&physical).unwrap();
        symlink(&physical, &link).unwrap();

        assert!(super::validate_service_event_directory(&link).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn service_event_writer_rejects_a_symbolic_link_target() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target.jsonl");
        let path = directory.path().join("service-events.jsonl");
        let rotated_path = directory.path().join("service-events.1.jsonl");
        std::fs::write(&target, "trusted target must remain unchanged\n").unwrap();
        symlink(&target, &path).unwrap();
        let mut writer = BoundedJsonlServiceEventWriter::new(path, rotated_path, 1_024);

        assert!(writer.write_event(event(1, 80_000_000)).is_err());
        assert_eq!(
            std::fs::read_to_string(target).unwrap(),
            "trusted target must remain unchanged\n"
        );
    }

    #[test]
    fn concurrent_publishers_produce_only_complete_json_lines() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("service-events.jsonl");
        let rotated_path = directory.path().join("service-events.1.jsonl");
        let mut lane = WindowsServiceEventLane::start(Box::new(
            BoundedJsonlServiceEventWriter::new(path.clone(), rotated_path, 32 * 1024),
        ))
        .unwrap();
        let publisher = lane.publisher();
        let workers = (0..8)
            .map(|worker| {
                let publisher = Arc::clone(&publisher);
                std::thread::spawn(move || {
                    for revision in 0..100 {
                        let epoch = worker * 100 + revision + 1;
                        let _ = publisher
                            .publish_adaptive_video_apply(event(epoch, 40_000_000 + epoch));
                    }
                })
            })
            .collect::<Vec<_>>();
        for worker in workers {
            worker.join().unwrap();
        }
        let latest = event(999, 99_000_000);
        assert_ne!(
            publisher.publish_adaptive_video_apply(latest),
            WindowsServiceEventPublishStatus::Dropped
        );
        lane.shutdown();

        let body = std::fs::read_to_string(path).unwrap();
        let persisted = body
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert!(!persisted.is_empty());
        let last = persisted.last().unwrap();
        assert_eq!(last["session_epoch"], 999);
        assert_eq!(last["requested_bitrate_bps"], 99_000_000);
        assert_eq!(last["applied_bitrate_bps"], 99_000_000);
    }
}
