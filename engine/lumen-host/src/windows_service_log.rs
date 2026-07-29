use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;

use crossbeam_queue::ArrayQueue;
use serde::Serialize;

#[cfg(windows)]
const SERVICE_EVENT_LOG_FILE: &str = "service-events.jsonl";
#[cfg(windows)]
const ROTATED_SERVICE_EVENT_LOG_FILE: &str = "service-events.1.jsonl";
const SERVICE_EVENT_LANE_CAPACITY: usize = 1;
#[cfg(windows)]
const MAXIMUM_SERVICE_EVENT_LOG_BYTES: u64 = 256 * 1024;
#[cfg(windows)]
const SERVICE_EVENT_DIRECTORY_SDDL: &str = "O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

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
    wake: mpsc::SyncSender<()>,
    stopping: AtomicBool,
    publishing: AtomicUsize,
    coalesced_events: AtomicU64,
    dropped_events: AtomicU64,
    write_failures: AtomicU64,
}

struct WindowsServiceEventLanePublisher {
    shared: Arc<ServiceEventLaneShared>,
}

impl WindowsServiceEventPublisher for WindowsServiceEventLanePublisher {
    fn publish_adaptive_video_apply(
        &self,
        event: WindowsAdaptiveVideoApplyEvent,
    ) -> WindowsServiceEventPublishStatus {
        self.shared.publishing.fetch_add(1, Ordering::AcqRel);
        if self.shared.stopping.load(Ordering::Acquire) {
            self.shared.dropped_events.fetch_add(1, Ordering::Relaxed);
            self.shared.publishing.fetch_sub(1, Ordering::AcqRel);
            return WindowsServiceEventPublishStatus::Dropped;
        }
        let coalesced = self.shared.pending.force_push(event).is_some();

        let status = match self.shared.wake.try_send(()) {
            Ok(()) | Err(mpsc::TrySendError::Full(())) => {
                if coalesced {
                    self.shared.coalesced_events.fetch_add(1, Ordering::Relaxed);
                    WindowsServiceEventPublishStatus::Coalesced
                } else {
                    WindowsServiceEventPublishStatus::Queued
                }
            }
            Err(mpsc::TrySendError::Disconnected(())) => {
                self.shared.dropped_events.fetch_add(1, Ordering::Relaxed);
                WindowsServiceEventPublishStatus::Dropped
            }
        };
        self.shared.publishing.fetch_sub(1, Ordering::AcqRel);
        status
    }
}

trait ServiceEventWriter: Send {
    fn write_event(&mut self, event: WindowsAdaptiveVideoApplyEvent) -> Result<(), String>;
    fn flush(&mut self) -> Result<(), String>;
}

pub(crate) struct WindowsServiceEventLane {
    shared: Arc<ServiceEventLaneShared>,
    worker: Option<thread::JoinHandle<()>>,
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
        let shared = Arc::new(ServiceEventLaneShared {
            pending: ArrayQueue::new(SERVICE_EVENT_LANE_CAPACITY),
            wake,
            stopping: AtomicBool::new(false),
            publishing: AtomicUsize::new(0),
            coalesced_events: AtomicU64::new(0),
            dropped_events: AtomicU64::new(0),
            write_failures: AtomicU64::new(0),
        });
        let worker_shared = Arc::clone(&shared);
        let worker = thread::Builder::new()
            .name("lumen-windows-service-event-log".to_owned())
            .spawn(move || run_service_event_lane(receiver, worker_shared, writer))
            .map_err(|error| format!("start Windows service event log worker: {error}"))?;
        Ok(Self {
            shared,
            worker: Some(worker),
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
        self.shared.stopping.store(true, Ordering::Release);
        while self.shared.publishing.load(Ordering::Acquire) != 0 {
            thread::yield_now();
        }
        let _ = self.shared.wake.try_send(());
        if worker.join().is_err() {
            self.shared.write_failures.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[cfg(test)]
    fn diagnostics(&self) -> WindowsServiceEventDiagnostics {
        WindowsServiceEventDiagnostics {
            coalesced_events: self.shared.coalesced_events.load(Ordering::Acquire),
            dropped_events: self.shared.dropped_events.load(Ordering::Acquire),
            write_failures: self.shared.write_failures.load(Ordering::Acquire),
        }
    }

    #[cfg(test)]
    fn pending_event_count(&self) -> usize {
        self.shared.pending.len()
    }
}

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
}

fn run_service_event_lane(
    receiver: mpsc::Receiver<()>,
    shared: Arc<ServiceEventLaneShared>,
    mut writer: Box<dyn ServiceEventWriter>,
) {
    while receiver.recv().is_ok() {
        loop {
            let event = shared.pending.pop();
            let Some(event) = event else {
                break;
            };
            if writer.write_event(event).is_err() {
                shared.write_failures.fetch_add(1, Ordering::Relaxed);
            }
        }
        if shared.stopping.load(Ordering::Acquire) {
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
        let mut options = OpenOptions::new();
        options.create(true).append(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            use windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ;

            options.share_mode(FILE_SHARE_READ);
        }
        let file = options
            .open(&self.path)
            .map_err(|error| format!("open Windows service event log: {error}"))?;
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

#[cfg(windows)]
fn validate_service_event_directory_security(directory: &Path) -> std::io::Result<()> {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr::{null_mut, slice_from_raw_parts};
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, GetNamedSecurityInfoW,
        SDDL_REVISION_1, SE_FILE_OBJECT,
    };
    use windows_sys::Win32::Security::{
        EqualSid, GetSecurityDescriptorControl, GetSecurityDescriptorDacl,
        GetSecurityDescriptorOwner, ACL, DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION,
        PSECURITY_DESCRIPTOR, PSID, SE_DACL_PROTECTED,
    };

    struct OwnedLocal(*mut c_void);

    impl Drop for OwnedLocal {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }

    let path = directory
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
    let mut descriptor_control = 0;
    let mut descriptor_revision = 0;
    if unsafe {
        GetSecurityDescriptorControl(
            actual_descriptor,
            &mut descriptor_control,
            &mut descriptor_revision,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    let owner_matches = !actual_owner.is_null()
        && !expected_owner.is_null()
        && unsafe { EqualSid(actual_owner, expected_owner) } != 0;
    let actual_acl = (!actual_dacl.is_null()).then(|| unsafe {
        &*slice_from_raw_parts(
            actual_dacl.cast::<u8>(),
            usize::from((*actual_dacl).AclSize),
        )
    });
    let expected_acl = (dacl_present != 0 && !expected_dacl.is_null()).then(|| unsafe {
        &*slice_from_raw_parts(
            expected_dacl.cast::<u8>(),
            usize::from((*expected_dacl).AclSize),
        )
    });
    let dacl_matches = actual_acl == expected_acl;
    let dacl_is_protected = descriptor_control & SE_DACL_PROTECTED != 0;
    if !owner_matches || !dacl_matches || !dacl_is_protected {
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
        BoundedJsonlServiceEventWriter, ServiceEventWriter, WindowsAdaptiveVideoApplyEvent,
        WindowsServiceEventLane, WindowsServiceEventPublishStatus,
    };
    use std::sync::{mpsc, Arc, Mutex};

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
