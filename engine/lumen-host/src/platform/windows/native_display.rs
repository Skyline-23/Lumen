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
use windows_sys::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, GetDisplayConfigBufferSizes, QueryDisplayConfig, SetDisplayConfig,
    DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, DISPLAYCONFIG_MODE_INFO,
    DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_RATIONAL,
    DISPLAYCONFIG_SOURCE_DEVICE_NAME, QDC_ONLY_ACTIVE_PATHS, SDC_APPLY, SDC_SAVE_TO_DATABASE,
    SDC_USE_SUPPLIED_DISPLAY_CONFIG,
};
use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::Graphics::Gdi::{
    ChangeDisplaySettingsExW, EnumDisplaySettingsW, CDS_UPDATEREGISTRY, DEVMODEW,
    DISP_CHANGE_SUCCESSFUL, DM_DISPLAYFREQUENCY, DM_PELSHEIGHT, DM_PELSWIDTH,
    ENUM_CURRENT_SETTINGS,
};
use windows_sys::Win32::System::Com::CoCreateGuid;

use crate::{HostArguments, HostAuthorityPaths, PlatformApplicationPlan};

use super::display_isolation::{
    first_frame_timed_out, monitor_required, DisplayIsolationLifecycle, FIRST_FRAME_TIMEOUT,
};
use super::display_topology::WindowsPathIdentity;
use super::native_display_driver::{DriverHandle, MonitorState};
use super::native_display_topology::{apply_topology, query_active_topology, verify_topology};

pub(super) struct NativeWindowsDisplay {
    recovery_store: RecoveryJournalStore,
    active: Mutex<Option<ActiveDisplay>>,
}

impl NativeWindowsDisplay {
    pub(super) fn new(arguments: &HostArguments) -> Result<Self, String> {
        let recovery_store = RecoveryJournalStore::new(recovery_path(arguments)?);
        let driver = DriverHandle::open()?;
        recover_persisted_topology(&recovery_store, &driver)?;
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
        let monitor_id = monitor_id(guid);
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
            id: monitor_id_text(monitor_id),
        });
        self.recovery_store
            .create(&journal)
            .map_err(|error| format!("Windows display recovery snapshot failed: {error}"))?;
        let driver = match DriverHandle::open() {
            Ok(driver) => driver,
            Err(error) => {
                let recovery = recover_uncreated_topology(&self.recovery_store).err();
                return Err(combine_error(error, recovery));
            }
        };
        if driver.query_monitor()? != MonitorState::Missing {
            return Err(
                "Windows driver already owns a monitor without startup recovery".to_owned(),
            );
        }
        if let Err(error) =
            driver.create_monitor(monitor_id, plan.width, plan.height, refresh_millihertz)
        {
            let recovery = recover_persisted_topology(&self.recovery_store, &driver).err();
            return Err(combine_error(error, recovery));
        }
        let mut display = ActiveDisplay {
            driver,
            monitor_id,
            output_name: None,
            identity: None,
            isolated_topology: None,
            journal,
            lifecycle: DisplayIsolationLifecycle::new(),
            capture_started_at: None,
            recovery_deleted: false,
            removed: false,
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
        let (identity, output_name) = match wait_for_new_display(&physical) {
            Ok(output) => output,
            Err(error) => {
                let cleanup = cleanup_display(&mut display, &self.recovery_store);
                if cleanup.is_some() {
                    *active = Some(display);
                }
                return Err(combine_error(error, cleanup));
            }
        };
        display.identity = Some(identity);
        display.output_name = Some(output_name.clone());
        if let Err(error) =
            apply_display_mode(&output_name, plan.width, plan.height, refresh_millihertz)
        {
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
            .and_then(|display| display.output_name.clone())
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
            return display.validate_isolated_topology(&self.recovery_store);
        }
        display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::CaptureStarting,
            RecoveryPhase::FirstFrameReady,
        )?;
        let active_topology = query_active_topology()?;
        display.refresh_physical_snapshot(&active_topology, &self.recovery_store)?;
        display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::FirstFrameReady,
            RecoveryPhase::IsolationStarted,
        )?;
        let identity = display
            .identity
            .ok_or_else(|| "Windows IDD path identity is unavailable".to_owned())?;
        let isolated = active_topology.isolated_for(identity)?;
        apply_topology(&isolated)?;
        verify_topology(&isolated)?;
        display.isolated_topology = Some(isolated);
        display.persist_phase(
            &self.recovery_store,
            RecoveryPhase::IsolationStarted,
            RecoveryPhase::Isolated,
        )
    }

    pub(super) fn check_first_frame_timeout(&self) -> Result<(), String> {
        let mut active = self
            .active
            .lock()
            .map_err(|_| "Windows display state lock is poisoned".to_owned())?;
        let display = active
            .as_mut()
            .ok_or_else(|| "Windows IDD output is not active".to_owned())?;
        if display.lifecycle.phase() == RecoveryPhase::Isolated {
            return display.validate_isolated_topology(&self.recovery_store);
        }
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
        display.remove()?;
        if !display.recovery_deleted {
            self.recovery_store
                .delete()
                .map_err(|error| format!("Windows display recovery cleanup failed: {error}"))?;
            display.recovery_deleted = true;
        }
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
    monitor_id: u64,
    output_name: Option<String>,
    identity: Option<WindowsPathIdentity>,
    isolated_topology: Option<super::display_topology::WindowsDisplayConfigSnapshot>,
    journal: WorkspaceRecoveryJournal,
    lifecycle: DisplayIsolationLifecycle,
    capture_started_at: Option<Instant>,
    recovery_deleted: bool,
    removed: bool,
}

impl ActiveDisplay {
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

    fn refresh_physical_snapshot(
        &mut self,
        active: &super::display_topology::WindowsDisplayConfigSnapshot,
        store: &RecoveryJournalStore,
    ) -> Result<(), String> {
        let identity = self
            .identity
            .ok_or_else(|| "Windows IDD path identity is unavailable".to_owned())?;
        let refreshed = active.physical_without(identity)?;
        let persisted =
            super::display_topology::WindowsDisplayConfigSnapshot::from_physical_topology(
                &self.journal.physical_topology,
            )?;
        if refreshed == persisted {
            return Ok(());
        }
        let mut updated = self.journal.clone();
        updated.physical_topology = refreshed.to_physical_topology()?;
        store
            .update(&updated)
            .map_err(|error| format!("Windows hotplug snapshot refresh failed: {error}"))?;
        self.journal = updated;
        Ok(())
    }

    fn validate_isolated_topology(&mut self, store: &RecoveryJournalStore) -> Result<(), String> {
        let identity = self
            .identity
            .ok_or_else(|| "Windows IDD path identity is unavailable".to_owned())?;
        let expected = self
            .isolated_topology
            .as_ref()
            .ok_or_else(|| "Windows isolated topology baseline is unavailable".to_owned())?;
        let observed = query_active_topology()?;
        if expected.matches_exact_isolation(identity, &observed) {
            return Ok(());
        }
        self.persist_phase(
            store,
            RecoveryPhase::Isolated,
            RecoveryPhase::CaptureStopped,
        )?;
        match self.restore_and_verify(store) {
            Ok(()) => Err(
                "Windows display topology changed during isolation; physical topology was restored"
                    .to_owned(),
            ),
            Err(recovery) => Err(format!(
                "Windows display topology changed during isolation; fail-closed recovery failed: {recovery}"
            )),
        }
    }

    fn remove(&mut self) -> Result<(), String> {
        if !self.lifecycle.can_destroy_monitor() {
            return Err("Windows physical topology is not verified for IDD removal".to_owned());
        }
        self.driver.remove_monitor(self.monitor_id)?;
        self.removed = true;
        Ok(())
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

fn recover_persisted_topology(
    store: &RecoveryJournalStore,
    driver: &DriverHandle,
) -> Result<(), String> {
    let loaded = store
        .load()
        .map_err(|error| format!("Windows display recovery load failed: {error}"))?;
    let monitor = driver.query_monitor()?;
    let journal = match loaded {
        RecoveryJournalLoad::Missing => {
            return match monitor {
                MonitorState::Missing => Ok(()),
                MonitorState::Owned(_) | MonitorState::Orphaned(_) => Err(
                    "Windows driver retained a monitor without a trusted recovery journal"
                        .to_owned(),
                ),
            };
        }
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
    let expected_monitor = journal
        .virtual_display
        .as_ref()
        .map(|identity| parse_monitor_id(&identity.id))
        .transpose()?;
    match monitor {
        MonitorState::Missing => {}
        MonitorState::Orphaned(monitor_id) => {
            if expected_monitor != Some(monitor_id) {
                return Err("Windows orphan monitor does not match the recovery journal".to_owned());
            }
            driver.adopt_monitor(monitor_id)?;
        }
        MonitorState::Owned(monitor_id) => {
            if expected_monitor != Some(monitor_id) {
                return Err("Windows owned monitor does not match the recovery journal".to_owned());
            }
        }
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
    if let Some(monitor_id) = expected_monitor {
        match driver.query_monitor()? {
            MonitorState::Owned(active) if active == monitor_id => {
                driver.remove_monitor(monitor_id)?;
            }
            MonitorState::Missing => {}
            MonitorState::Owned(_) | MonitorState::Orphaned(_) => {
                return Err("Windows recovery monitor identity changed before removal".to_owned());
            }
        }
    }
    store
        .delete()
        .map_err(|error| format!("Windows display recovery cleanup failed: {error}"))
}

fn recover_uncreated_topology(store: &RecoveryJournalStore) -> Result<(), String> {
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

fn monitor_id(guid: GUID) -> u64 {
    let value = (u128::from(guid.data1) << 96)
        | (u128::from(guid.data2) << 80)
        | (u128::from(guid.data3) << 64)
        | u128::from(u64::from_be_bytes(guid.data4));
    (value as u64).max(1)
}

fn monitor_id_text(monitor_id: u64) -> String {
    format!("{monitor_id:016x}")
}

fn parse_monitor_id(value: &str) -> Result<u64, String> {
    u64::from_str_radix(value, 16)
        .ok()
        .filter(|monitor_id| *monitor_id != 0)
        .ok_or_else(|| "Windows recovery monitor identity is invalid".to_owned())
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
    if let Err(error) = display.remove() {
        return Some(error);
    }
    match store.delete() {
        Ok(()) => {
            display.recovery_deleted = true;
            None
        }
        Err(error) => Some(format!("Windows display recovery cleanup failed: {error}")),
    }
}
fn wait_for_new_display(
    physical: &super::display_topology::WindowsDisplayConfigSnapshot,
) -> Result<(WindowsPathIdentity, String), String> {
    for delay in [0, 20, 40, 80, 160, 320, 640] {
        if delay != 0 {
            thread::sleep(Duration::from_millis(delay));
        }
        let active = query_active_topology()?;
        if let Ok(identity) = active.new_path_since(physical) {
            if let Some(name) = display_name(identity) {
                return Ok((identity, name));
            }
        }
    }
    Err("Windows could not resolve the newly added virtual display".to_owned())
}

fn display_name(identity: WindowsPathIdentity) -> Option<String> {
    let (mut paths, _) = active_display_configuration()?;
    let path = paths.iter_mut().find(|path| {
        path.targetInfo.id == identity.target_id
            && path.targetInfo.adapterId.LowPart == identity.adapter.low_part
            && path.targetInfo.adapterId.HighPart == identity.adapter.high_part
    })?;
    let mut source_name = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
    source_name.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    source_name.header.size = size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
    source_name.header.adapterId = path.sourceInfo.adapterId;
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

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
