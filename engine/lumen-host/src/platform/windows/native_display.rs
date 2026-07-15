use std::ffi::c_void;
use std::mem::size_of;
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use lumen_engine::{
    RecoveryJournalLoad, RecoveryJournalStore, RecoveryPhase, VirtualDisplayIdentity,
    WorkspacePlatform, WorkspaceRecoveryJournal, WorkspaceRecoveryMetadata,
};

use windows_sys::core::GUID;
use windows_sys::Win32::Devices::DeviceAndDriverInstallation::{
    SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInterfaces, SetupDiGetClassDevsW,
    SetupDiGetDeviceInterfaceDetailW, DIGCF_DEVICEINTERFACE, DIGCF_PRESENT, HDEVINFO,
    SP_DEVICE_INTERFACE_DATA, SP_DEVICE_INTERFACE_DETAIL_DATA_W,
};
use windows_sys::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, GetDisplayConfigBufferSizes, QueryDisplayConfig, SetDisplayConfig,
    DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, DISPLAYCONFIG_MODE_INFO,
    DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_RATIONAL,
    DISPLAYCONFIG_SOURCE_DEVICE_NAME, QDC_ONLY_ACTIVE_PATHS, SDC_APPLY, SDC_SAVE_TO_DATABASE,
    SDC_USE_SUPPLIED_DISPLAY_CONFIG,
};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_SUCCESS, GENERIC_READ, GENERIC_WRITE, HANDLE,
    INVALID_HANDLE_VALUE, LUID,
};
use windows_sys::Win32::Graphics::Gdi::{
    ChangeDisplaySettingsExW, EnumDisplaySettingsW, CDS_UPDATEREGISTRY, DEVMODEW,
    DISP_CHANGE_SUCCESSFUL, DM_DISPLAYFREQUENCY, DM_PELSHEIGHT, DM_PELSWIDTH,
    ENUM_CURRENT_SETTINGS,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::Com::CoCreateGuid;
use windows_sys::Win32::System::IO::DeviceIoControl;

use crate::{HostArguments, HostAuthorityPaths, PlatformApplicationPlan};

use super::display_isolation::{
    first_frame_timed_out, monitor_required, DisplayIsolationLifecycle, FIRST_FRAME_TIMEOUT,
};
use super::display_topology::{AdapterLuid, WindowsPathIdentity};
use super::native_display_topology::{apply_topology, query_active_topology, verify_topology};

const VIRTUAL_DISPLAY_INTERFACE_GUID: GUID =
    GUID::from_u128(0xe5bcc234_1e0c_418a_a0d4_ef8b7501414d);
const PROTOCOL_VERSION: DriverProtocolVersion = DriverProtocolVersion {
    major: 0,
    minor: 2,
    incremental: 1,
    test_build: 1,
};
const IOCTL_ADD_VIRTUAL_DISPLAY: u32 = control_code(0x800);
const IOCTL_REMOVE_VIRTUAL_DISPLAY: u32 = control_code(0x801);
const IOCTL_GET_PROTOCOL_VERSION: u32 = control_code(0x8ff);

const fn control_code(function: u32) -> u32 {
    (0x22 << 16) | (function << 2)
}

pub(super) struct NativeWindowsDisplay {
    recovery_store: RecoveryJournalStore,
    active: Mutex<Option<ActiveDisplay>>,
}

impl NativeWindowsDisplay {
    pub(super) fn new(arguments: &HostArguments) -> Result<Self, String> {
        let recovery_store = RecoveryJournalStore::new(recovery_path(arguments)?);
        recover_persisted_topology(&recovery_store)?;
        Ok(Self {
            recovery_store,
            active: Mutex::new(None),
        })
    }

    pub(super) fn start(&self, plan: &PlatformApplicationPlan) -> Result<(), String> {
        let mut active = self
            .active
            .lock()
            .map_err(|_| "Windows display state lock is poisoned".to_owned())?;
        if active.is_some() {
            return Err("A Windows virtual display is already active".to_owned());
        }
        if !monitor_required(Some(plan.virtual_display), plan.application.virtual_display) {
            return Err("Windows requires the first-party IDD monitor".to_owned());
        }
        let refresh_millihertz = plan
            .frames_per_second
            .checked_mul(1_000)
            .ok_or_else(|| "Windows virtual display refresh rate overflowed".to_owned())?;
        let physical = query_active_topology()?;
        let topology = physical.to_physical_topology()?;
        let guid = create_guid()?;
        let now = timestamp_millis()?;
        let journal = WorkspaceRecoveryJournal::new(
            WorkspaceRecoveryMetadata {
                platform: WorkspacePlatform::Windows,
                generation: now.max(1),
                session_id: guid_text(guid),
                timestamp_unix_ms: now,
                capture_managed: true,
            },
            topology,
        )
        .map_err(|error| format!("Windows display recovery journal is invalid: {error}"))?
        .with_virtual_display(VirtualDisplayIdentity {
            id: guid_text(guid),
        });
        self.recovery_store
            .create(&journal)
            .map_err(|error| format!("Windows display recovery snapshot failed: {error}"))?;
        let mut display = match ActiveDisplay::create(
            plan.application.uuid.as_str(),
            plan.application.name.as_str(),
            plan.width,
            plan.height,
            refresh_millihertz,
            guid,
            journal,
        ) {
            Ok(display) => display,
            Err(error) => {
                let recovery = recover_persisted_topology(&self.recovery_store).err();
                return Err(combine_error(error, recovery));
            }
        };
        if let Err(error) = display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::SnapshotPersisted,
            RecoveryPhase::VirtualCreated,
        ) {
            let cleanup = cleanup_display(&mut display, &self.recovery_store);
            if cleanup.is_some() {
                *active = Some(display);
            }
            return Err(combine_error(error, cleanup));
        }
        if let Err(error) = display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::VirtualCreated,
            RecoveryPhase::VirtualConfigured,
        ) {
            let cleanup = cleanup_display(&mut display, &self.recovery_store);
            if cleanup.is_some() {
                *active = Some(display);
            }
            return Err(combine_error(error, cleanup));
        }
        *active = Some(display);
        Ok(())
    }

    pub(super) fn current_output_name(&self) -> Result<String, String> {
        let active = self
            .active
            .lock()
            .map_err(|_| "Windows display state lock is poisoned".to_owned())?;
        active
            .as_ref()
            .map(|display| display.output_name.clone())
            .ok_or_else(|| "Windows IDD output is not active".to_owned())
    }

    pub(super) fn capture_started(&self) -> Result<(), String> {
        let mut active = self
            .active
            .lock()
            .map_err(|_| "Windows display state lock is poisoned".to_owned())?;
        let display = active
            .as_mut()
            .ok_or_else(|| "Windows IDD output is not active".to_owned())?;
        display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::VirtualConfigured,
            RecoveryPhase::CaptureStarting,
        )?;
        display.capture_started_at = Some(Instant::now());
        Ok(())
    }

    pub(super) fn first_frame_ready(&self) -> Result<(), String> {
        let mut active = self
            .active
            .lock()
            .map_err(|_| "Windows display state lock is poisoned".to_owned())?;
        let display = active
            .as_mut()
            .ok_or_else(|| "Windows IDD output is not active".to_owned())?;
        if display.lifecycle.phase() == RecoveryPhase::Isolated {
            return Ok(());
        }
        display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::CaptureStarting,
            RecoveryPhase::FirstFrameReady,
        )?;
        display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::FirstFrameReady,
            RecoveryPhase::IsolationStarted,
        )?;
        let active_topology = query_active_topology()?;
        let isolated = active_topology.isolated_for(display.identity)?;
        apply_topology(&isolated)?;
        verify_topology(&isolated)?;
        display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::IsolationStarted,
            RecoveryPhase::Isolated,
        )
    }

    pub(super) fn check_first_frame_timeout(&self) -> Result<(), String> {
        let active = self
            .active
            .lock()
            .map_err(|_| "Windows display state lock is poisoned".to_owned())?;
        let display = active
            .as_ref()
            .ok_or_else(|| "Windows IDD output is not active".to_owned())?;
        if display.capture_started_at.is_some_and(|started| {
            first_frame_timed_out(display.lifecycle.phase(), started.elapsed())
        }) {
            return Err(format!(
                "Windows first encoded frame did not arrive within {} ms",
                FIRST_FRAME_TIMEOUT.as_millis()
            ));
        }
        Ok(())
    }

    pub(super) fn stop(&self) -> Result<(), String> {
        let mut active = self
            .active
            .lock()
            .map_err(|_| "Windows display state lock is poisoned".to_owned())?;
        let Some(display) = active.as_mut() else {
            return Ok(());
        };
        if matches!(
            display.lifecycle.phase(),
            RecoveryPhase::CaptureStarting
                | RecoveryPhase::FirstFrameReady
                | RecoveryPhase::IsolationStarted
                | RecoveryPhase::Isolated
        ) {
            let phase = display.lifecycle.phase();
            display.persist_phase(&self.recovery_store, phase, RecoveryPhase::CaptureStopped)?;
        }
        display.restore_and_verify(&self.recovery_store)?;
        if !display.lifecycle.can_destroy_monitor() {
            return Err("Windows physical topology is not verified for IDD removal".to_owned());
        }
        if !display.recovery_deleted {
            self.recovery_store
                .delete()
                .map_err(|error| format!("Windows display recovery cleanup failed: {error}"))?;
            display.recovery_deleted = true;
        }
        display.remove()?;
        *active = None;
        Ok(())
    }
}

impl Drop for NativeWindowsDisplay {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

struct ActiveDisplay {
    driver: DriverHandle,
    guid: GUID,
    output_name: String,
    identity: WindowsPathIdentity,
    journal: WorkspaceRecoveryJournal,
    lifecycle: DisplayIsolationLifecycle,
    capture_started_at: Option<Instant>,
    recovery_deleted: bool,
    removed: bool,
}

impl ActiveDisplay {
    fn create(
        device_key: &str,
        device_name: &str,
        width: u32,
        height: u32,
        refresh_millihertz: u32,
        guid: GUID,
        journal: WorkspaceRecoveryJournal,
    ) -> Result<Self, String> {
        if width == 0 || height == 0 || refresh_millihertz == 0 {
            return Err("Windows virtual display dimensions are invalid".to_owned());
        }
        let driver = DriverHandle::open()?;
        driver.require_compatible_protocol()?;
        let output = driver.add_display(
            guid,
            driver_text(device_name, "Lumen"),
            driver_text(device_key, "LumenDevice"),
            width,
            height,
            refresh_millihertz,
        )?;
        let output_name = match wait_for_display_name(output) {
            Ok(name) => name,
            Err(error) => {
                let _ = driver.remove_display(guid);
                return Err(error);
            }
        };
        if let Err(error) = apply_display_mode(&output_name, width, height, refresh_millihertz) {
            let _ = driver.remove_display(guid);
            return Err(error);
        }
        Ok(Self {
            driver,
            guid,
            output_name,
            identity: WindowsPathIdentity {
                adapter: AdapterLuid {
                    high_part: output.adapter_luid.HighPart,
                    low_part: output.adapter_luid.LowPart,
                },
                target_id: output.target_id,
            },
            journal,
            lifecycle: DisplayIsolationLifecycle::new(),
            capture_started_at: None,
            recovery_deleted: false,
            removed: false,
        })
    }

    fn persist_phase(
        &mut self,
        store: &RecoveryJournalStore,
        expected: RecoveryPhase,
        next: RecoveryPhase,
    ) -> Result<(), String> {
        self.lifecycle.transition(expected, next)?;
        let updated = self.journal.clone().with_phase(next);
        if let Err(error) = store.update(&updated) {
            self.lifecycle = DisplayIsolationLifecycle::at(expected);
            return Err(format!("Windows display recovery phase failed: {error}"));
        }
        self.journal = updated;
        Ok(())
    }

    fn restore_and_verify(&mut self, store: &RecoveryJournalStore) -> Result<(), String> {
        let physical =
            super::display_topology::WindowsDisplayConfigSnapshot::from_physical_topology(
                &self.journal.physical_topology,
            )?;
        apply_topology(&physical)?;
        let phase = self.lifecycle.phase();
        if phase != RecoveryPhase::PhysicalRestored && phase != RecoveryPhase::RestorationVerified {
            self.persist_phase(store, phase, RecoveryPhase::PhysicalRestored)?;
        }
        verify_topology(&physical)?;
        if self.lifecycle.phase() != RecoveryPhase::RestorationVerified {
            self.persist_phase(
                store,
                RecoveryPhase::PhysicalRestored,
                RecoveryPhase::RestorationVerified,
            )?;
        }
        Ok(())
    }

    fn remove(&mut self) -> Result<(), String> {
        self.driver.remove_display(self.guid)?;
        self.removed = true;
        Ok(())
    }
}

impl Drop for ActiveDisplay {
    fn drop(&mut self) {
        if !self.removed {
            let _ = self.driver.remove_display(self.guid);
        }
    }
}

fn recovery_path(arguments: &HostArguments) -> Result<PathBuf, String> {
    let paths = HostAuthorityPaths::from_arguments(arguments).map_err(|error| error.to_string())?;
    let parent = paths
        .settings
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or_else(|| "Windows display recovery directory is invalid".to_owned())?;
    Ok(parent.join("display-recovery.json"))
}

fn recover_persisted_topology(store: &RecoveryJournalStore) -> Result<(), String> {
    let journal = match store
        .load()
        .map_err(|error| format!("Windows display recovery load failed: {error}"))?
    {
        RecoveryJournalLoad::Missing => return Ok(()),
        RecoveryJournalLoad::Verified(journal) => journal,
        RecoveryJournalLoad::Quarantined(warning) => {
            return Err(format!(
                "Windows display recovery journal was quarantined ({:?}): {}",
                warning.code,
                warning.quarantined_path.display()
            ));
        }
    };
    if journal.platform != WorkspacePlatform::Windows {
        return Err("Windows display recovery journal belongs to another platform".to_owned());
    }
    let physical = super::display_topology::WindowsDisplayConfigSnapshot::from_physical_topology(
        &journal.physical_topology,
    )?;
    apply_topology(&physical)?;
    let restored = journal.clone().with_phase(RecoveryPhase::PhysicalRestored);
    store
        .update(&restored)
        .map_err(|error| format!("Windows display restore phase failed: {error}"))?;
    verify_topology(&physical)?;
    let verified = restored.with_phase(RecoveryPhase::RestorationVerified);
    store
        .update(&verified)
        .map_err(|error| format!("Windows display verification phase failed: {error}"))?;
    store
        .delete()
        .map_err(|error| format!("Windows display recovery cleanup failed: {error}"))
}

fn create_guid() -> Result<GUID, String> {
    let mut guid = GUID::from_u128(0);
    // SAFETY: Category 8 (FFI boundary). `guid` is a live writable GUID for the full call.
    let status = unsafe { CoCreateGuid(&mut guid) };
    if status < 0 {
        Err(format!(
            "Windows virtual display GUID creation failed: {status:#x}"
        ))
    } else {
        Ok(guid)
    }
}

fn guid_text(guid: GUID) -> String {
    let value = (u128::from(guid.data1) << 96)
        | (u128::from(guid.data2) << 80)
        | (u128::from(guid.data3) << 64)
        | u128::from(u64::from_be_bytes(guid.data4));
    format!("{value:032x}")
}

fn timestamp_millis() -> Result<u64, String> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "Windows system clock is before the Unix epoch".to_owned())?;
    u64::try_from(elapsed.as_millis())
        .map_err(|_| "Windows system clock millisecond value overflowed".to_owned())
}

fn combine_error(primary: String, cleanup: Option<String>) -> String {
    match cleanup {
        Some(cleanup) => format!("{primary}; Windows display recovery also failed: {cleanup}"),
        None => primary,
    }
}

fn cleanup_display(display: &mut ActiveDisplay, store: &RecoveryJournalStore) -> Option<String> {
    if let Err(error) = display.restore_and_verify(store) {
        return Some(error);
    }
    if let Err(error) = store.delete() {
        return Some(format!("Windows display recovery cleanup failed: {error}"));
    }
    display.recovery_deleted = true;
    display.remove().err()
}

struct DriverHandle(usize);

impl DriverHandle {
    fn open() -> Result<Self, String> {
        for delay in [0, 40, 80, 160, 320, 640] {
            if delay != 0 {
                thread::sleep(Duration::from_millis(delay));
            }
            if let Some(handle) = open_driver_once() {
                return Ok(Self(handle as usize));
            }
        }
        Err(format!(
            "Windows virtual display driver is unavailable: {}",
            unsafe { GetLastError() }
        ))
    }

    fn raw(&self) -> HANDLE {
        self.0 as HANDLE
    }

    fn require_compatible_protocol(&self) -> Result<(), String> {
        let mut output = DriverProtocolOutput::default();
        ioctl_output(self.raw(), IOCTL_GET_PROTOCOL_VERSION, &mut output)?;
        let version = output.version;
        if version.major == PROTOCOL_VERSION.major && version.minor >= PROTOCOL_VERSION.minor {
            Ok(())
        } else {
            Err(format!(
                "Windows virtual display driver protocol is incompatible: {}.{}.{}",
                version.major, version.minor, version.incremental
            ))
        }
    }

    fn add_display(
        &self,
        guid: GUID,
        device_name: [i8; 14],
        serial_number: [i8; 14],
        width: u32,
        height: u32,
        refresh_millihertz: u32,
    ) -> Result<VirtualDisplayAddOutput, String> {
        let input = VirtualDisplayAddParameters {
            width,
            height,
            refresh_rate: refresh_millihertz,
            monitor_guid: guid,
            device_name,
            serial_number,
        };
        let mut output = VirtualDisplayAddOutput::default();
        ioctl(self.raw(), IOCTL_ADD_VIRTUAL_DISPLAY, &input, &mut output)?;
        Ok(output)
    }

    fn remove_display(&self, guid: GUID) -> Result<(), String> {
        let input = VirtualDisplayRemoveParameters { monitor_guid: guid };
        ioctl_input(self.raw(), IOCTL_REMOVE_VIRTUAL_DISPLAY, &input)
    }
}

impl Drop for DriverHandle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.raw()) };
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct DriverProtocolVersion {
    major: u8,
    minor: u8,
    incremental: u8,
    test_build: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct DriverProtocolOutput {
    version: DriverProtocolVersion,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct VirtualDisplayAddParameters {
    width: u32,
    height: u32,
    refresh_rate: u32,
    monitor_guid: GUID,
    device_name: [i8; 14],
    serial_number: [i8; 14],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct VirtualDisplayRemoveParameters {
    monitor_guid: GUID,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct VirtualDisplayAddOutput {
    adapter_luid: LUID,
    target_id: u32,
}

const _: [(); 4] = [(); size_of::<DriverProtocolVersion>()];
const _: [(); 56] = [(); size_of::<VirtualDisplayAddParameters>()];
const _: [(); 16] = [(); size_of::<VirtualDisplayRemoveParameters>()];
const _: [(); 12] = [(); size_of::<VirtualDisplayAddOutput>()];
const _: () = assert!(IOCTL_ADD_VIRTUAL_DISPLAY == 0x0022_2000);
const _: () = assert!(IOCTL_REMOVE_VIRTUAL_DISPLAY == 0x0022_2004);
const _: () = assert!(IOCTL_GET_PROTOCOL_VERSION == 0x0022_23fc);

struct DeviceInfoSet(HDEVINFO);

impl DeviceInfoSet {
    fn open() -> Option<Self> {
        let value = unsafe {
            SetupDiGetClassDevsW(
                &VIRTUAL_DISPLAY_INTERFACE_GUID,
                null(),
                null_mut(),
                DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
            )
        };
        (value != INVALID_HANDLE_VALUE as isize).then_some(Self(value))
    }
}

impl Drop for DeviceInfoSet {
    fn drop(&mut self) {
        unsafe { SetupDiDestroyDeviceInfoList(self.0) };
    }
}

fn open_driver_once() -> Option<HANDLE> {
    let devices = DeviceInfoSet::open()?;
    let mut interface = SP_DEVICE_INTERFACE_DATA {
        cbSize: size_of::<SP_DEVICE_INTERFACE_DATA>() as u32,
        ..Default::default()
    };
    let mut index = 0;
    while unsafe {
        SetupDiEnumDeviceInterfaces(
            devices.0,
            null(),
            &VIRTUAL_DISPLAY_INTERFACE_GUID,
            index,
            &mut interface,
        )
    } != 0
    {
        index += 1;
        let mut required_size = 0;
        unsafe {
            SetupDiGetDeviceInterfaceDetailW(
                devices.0,
                &interface,
                null_mut(),
                0,
                &mut required_size,
                null_mut(),
            )
        };
        if required_size < size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32 {
            continue;
        }
        let mut storage = vec![0_u8; required_size as usize];
        let detail = storage
            .as_mut_ptr()
            .cast::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>();
        unsafe {
            (*detail).cbSize = size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32;
        }
        let resolved = unsafe {
            SetupDiGetDeviceInterfaceDetailW(
                devices.0,
                &interface,
                detail,
                required_size,
                &mut required_size,
                null_mut(),
            )
        };
        if resolved == 0 {
            continue;
        }
        let path = unsafe { std::ptr::addr_of!((*detail).DevicePath).cast::<u16>() };
        let handle = unsafe {
            CreateFileW(
                path,
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                null(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                null_mut(),
            )
        };
        if !handle.is_null() && handle != INVALID_HANDLE_VALUE {
            return Some(handle);
        }
    }
    None
}

fn wait_for_display_name(output: VirtualDisplayAddOutput) -> Result<String, String> {
    for delay in [0, 20, 40, 80, 160, 320, 640] {
        if delay != 0 {
            thread::sleep(Duration::from_millis(delay));
        }
        if let Some(name) = display_name(output) {
            return Ok(name);
        }
    }
    Err("Windows could not resolve the newly added virtual display".to_owned())
}

fn display_name(output: VirtualDisplayAddOutput) -> Option<String> {
    let (mut paths, _) = active_display_configuration()?;
    let path = paths.iter_mut().find(|path| {
        path.targetInfo.id == output.target_id
            && path.targetInfo.adapterId.LowPart == output.adapter_luid.LowPart
            && path.targetInfo.adapterId.HighPart == output.adapter_luid.HighPart
    })?;
    let mut source_name = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
    source_name.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    source_name.header.size = size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
    source_name.header.adapterId = output.adapter_luid;
    source_name.header.id = path.sourceInfo.id;
    if unsafe { DisplayConfigGetDeviceInfo(&mut source_name.header) } != ERROR_SUCCESS as i32 {
        return None;
    }
    let length = source_name
        .viewGdiDeviceName
        .iter()
        .position(|value| *value == 0)
        .unwrap_or(source_name.viewGdiDeviceName.len());
    String::from_utf16(&source_name.viewGdiDeviceName[..length]).ok()
}

fn apply_display_mode(
    device_name: &str,
    width: u32,
    height: u32,
    refresh_millihertz: u32,
) -> Result<(), String> {
    let wide_name = wide(device_name);
    let mut mode = DEVMODEW {
        dmSize: size_of::<DEVMODEW>() as u16,
        ..Default::default()
    };
    if unsafe { EnumDisplaySettingsW(wide_name.as_ptr(), ENUM_CURRENT_SETTINGS, &mut mode) } != 0 {
        mode.dmPelsWidth = width;
        mode.dmPelsHeight = height;
        mode.dmDisplayFrequency = (refresh_millihertz + 500) / 1_000;
        mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
        let status = unsafe {
            ChangeDisplaySettingsExW(
                wide_name.as_ptr(),
                &mode,
                null_mut(),
                CDS_UPDATEREGISTRY,
                null(),
            )
        };
        if status != DISP_CHANGE_SUCCESSFUL {
            return Err(format!(
                "Windows rejected the virtual display baseline mode: {status}"
            ));
        }
    }

    let (mut paths, mut modes) = active_display_configuration()
        .ok_or_else(|| "Windows could not query the active display configuration".to_owned())?;
    for path in &mut paths {
        let mut source_name = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
        source_name.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        source_name.header.size = size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
        source_name.header.adapterId = path.sourceInfo.adapterId;
        source_name.header.id = path.sourceInfo.id;
        if unsafe { DisplayConfigGetDeviceInfo(&mut source_name.header) } != ERROR_SUCCESS as i32 {
            continue;
        }
        let length = source_name
            .viewGdiDeviceName
            .iter()
            .position(|value| *value == 0)
            .unwrap_or(source_name.viewGdiDeviceName.len());
        if String::from_utf16_lossy(&source_name.viewGdiDeviceName[..length]) != device_name {
            continue;
        }
        for mode in &mut modes {
            if mode.infoType != DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE
                || mode.adapterId.LowPart != path.sourceInfo.adapterId.LowPart
                || mode.adapterId.HighPart != path.sourceInfo.adapterId.HighPart
                || mode.id != path.sourceInfo.id
            {
                continue;
            }
            let source_mode = unsafe { &mut mode.Anonymous.sourceMode };
            source_mode.width = width;
            source_mode.height = height;
            path.targetInfo.refreshRate = DISPLAYCONFIG_RATIONAL {
                Numerator: refresh_millihertz,
                Denominator: 1_000,
            };
            let status = unsafe {
                SetDisplayConfig(
                    paths.len() as u32,
                    paths.as_ptr(),
                    modes.len() as u32,
                    modes.as_ptr(),
                    SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE,
                )
            };
            return (status == ERROR_SUCCESS as i32)
                .then_some(())
                .ok_or_else(|| {
                    format!("Windows rejected the exact virtual display mode: {status}")
                });
        }
    }
    Err("Windows virtual display source mode was not found".to_owned())
}

fn active_display_configuration(
) -> Option<(Vec<DISPLAYCONFIG_PATH_INFO>, Vec<DISPLAYCONFIG_MODE_INFO>)> {
    let mut path_count = 0;
    let mut mode_count = 0;
    if unsafe {
        GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut path_count, &mut mode_count)
    } != ERROR_SUCCESS
    {
        return None;
    }
    let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); path_count as usize];
    let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); mode_count as usize];
    if unsafe {
        QueryDisplayConfig(
            QDC_ONLY_ACTIVE_PATHS,
            &mut path_count,
            paths.as_mut_ptr(),
            &mut mode_count,
            modes.as_mut_ptr(),
            null_mut(),
        )
    } != ERROR_SUCCESS
    {
        return None;
    }
    paths.truncate(path_count as usize);
    modes.truncate(mode_count as usize);
    Some((paths, modes))
}

fn ioctl<I, O>(handle: HANDLE, code: u32, input: &I, output: &mut O) -> Result<(), String> {
    let mut bytes_returned = 0;
    let success = unsafe {
        DeviceIoControl(
            handle,
            code,
            std::ptr::from_ref(input).cast::<c_void>(),
            size_of::<I>() as u32,
            std::ptr::from_mut(output).cast::<c_void>(),
            size_of::<O>() as u32,
            &mut bytes_returned,
            null_mut(),
        )
    };
    (success != 0).then_some(()).ok_or_else(|| {
        format!(
            "Windows virtual display driver command {code:#x} failed: {}",
            unsafe { GetLastError() }
        )
    })
}

fn ioctl_input<I>(handle: HANDLE, code: u32, input: &I) -> Result<(), String> {
    let mut bytes_returned = 0;
    let success = unsafe {
        DeviceIoControl(
            handle,
            code,
            std::ptr::from_ref(input).cast::<c_void>(),
            size_of::<I>() as u32,
            null_mut(),
            0,
            &mut bytes_returned,
            null_mut(),
        )
    };
    (success != 0).then_some(()).ok_or_else(|| {
        format!(
            "Windows virtual display driver command {code:#x} failed: {}",
            unsafe { GetLastError() }
        )
    })
}

fn ioctl_output<O>(handle: HANDLE, code: u32, output: &mut O) -> Result<(), String> {
    let mut bytes_returned = 0;
    let success = unsafe {
        DeviceIoControl(
            handle,
            code,
            null(),
            0,
            std::ptr::from_mut(output).cast::<c_void>(),
            size_of::<O>() as u32,
            &mut bytes_returned,
            null_mut(),
        )
    };
    (success != 0).then_some(()).ok_or_else(|| {
        format!(
            "Windows virtual display driver command {code:#x} failed: {}",
            unsafe { GetLastError() }
        )
    })
}

fn driver_text(value: &str, fallback: &str) -> [i8; 14] {
    let value = if value.is_ascii() && value.bytes().all(|byte| !byte.is_ascii_control()) {
        value
    } else {
        fallback
    };
    let mut result = [0_i8; 14];
    for (destination, source) in result.iter_mut().take(13).zip(value.bytes()) {
        *destination = source as i8;
    }
    result
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
