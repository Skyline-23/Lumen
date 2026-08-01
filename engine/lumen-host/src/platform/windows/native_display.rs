use std::path::PathBuf;
use std::ptr::null;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use lumen_engine::{
    PhysicalDisplayTopology, RecoveryJournalLoad, RecoveryJournalStore, RecoveryPhase,
    VirtualDisplayIdentity, WorkspacePlatform, WorkspaceRecoveryJournal, WorkspaceRecoveryMetadata,
};

use windows_sys::core::GUID;
use windows_sys::Win32::Devices::Display::{SetDisplayConfig, SDC_APPLY, SDC_TOPOLOGY_EXTEND};
use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::System::Com::CoCreateGuid;

use crate::{HostArguments, HostAuthorityPaths, PlatformApplicationPlan};

use super::display_isolation::{
    first_frame_timed_out, monitor_required, DisplayIsolationLifecycle, FIRST_FRAME_TIMEOUT,
};
use super::display_topology::{AdapterLuid, WindowsPathIdentity};
use super::native_display_driver::{DriverHandle, MonitorArrivalIdentity, MonitorState};
use super::native_display_topology::{
    apply_topology, query_active_topology, query_active_topology_if_available, verify_topology,
};

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
        let physical = query_active_topology_if_available()?;
        let topology = physical
            .as_ref()
            .map(|snapshot| snapshot.to_physical_topology())
            .transpose()?
            .unwrap_or_else(unavailable_physical_topology);
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
        let arrival = match driver.create_monitor(
            monitor_id,
            guid,
            plan.width,
            plan.height,
            refresh_millihertz,
        ) {
            Ok(arrival) => arrival,
            Err(error) => {
                let recovery = recover_persisted_topology(&self.recovery_store, &driver).err();
                return Err(combine_error(error, recovery));
            }
        };
        let mut display = ActiveDisplay {
            driver,
            monitor_id,
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
        if let Err(error) = activate_virtual_display() {
            let cleanup = cleanup_display(&mut display, &self.recovery_store);
            if cleanup.is_some() {
                *active = Some(display);
            }
            return Err(combine_error(error, cleanup));
        }
        let identity = match wait_for_swapchain(&display.driver, monitor_id, arrival) {
            Ok(identity) => identity,
            Err(error) => {
                let cleanup = cleanup_display(&mut display, &self.recovery_store);
                if cleanup.is_some() {
                    *active = Some(display);
                }
                return Err(combine_error(error, cleanup));
            }
        };
        display.identity = Some(identity);
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

    pub(super) fn capture_driver(&self) -> Result<DriverHandle, String> {
        let active = self
            .active
            .lock()
            .map_err(|_| "Windows display state lock is poisoned".to_owned())?;
        active
            .as_ref()
            .ok_or_else(|| "Windows IDD output is not active".to_owned())?
            .driver
            .duplicate()
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
        let Some(active_topology) = query_active_topology_if_available()? else {
            return Ok(());
        };
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
        let physical_mutation_applied = self.journal.physical_mutation_applied != Some(false);
        let physical = physical_mutation_applied
            .then(|| {
                super::display_topology::WindowsDisplayConfigSnapshot::from_physical_topology(
                    &self.journal.physical_topology,
                )
            })
            .transpose()?;
        if let Some(physical) = &physical {
            apply_topology(physical)?;
        }
        let phase = self.lifecycle.phase();
        if phase != RecoveryPhase::PhysicalRestored && phase != RecoveryPhase::RestorationVerified {
            self.persist_phase(store, phase, RecoveryPhase::PhysicalRestored)?;
        }
        if let Some(physical) = &physical {
            verify_topology(physical)?;
        }
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
    let physical_mutation_applied = journal.physical_mutation_applied != Some(false);
    let physical = physical_mutation_applied
        .then(|| {
            super::display_topology::WindowsDisplayConfigSnapshot::from_physical_topology(
                &journal.physical_topology,
            )
        })
        .transpose()?;
    if let Some(physical) = &physical {
        apply_topology(physical)?;
    }
    let restored = journal.clone().with_phase(RecoveryPhase::PhysicalRestored);
    store
        .update(&restored)
        .map_err(|error| format!("Windows display restore phase failed: {error}"))?;
    if let Some(physical) = &physical {
        verify_topology(physical)?;
    }
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
    let physical_mutation_applied = journal.physical_mutation_applied != Some(false);
    let physical = physical_mutation_applied
        .then(|| {
            super::display_topology::WindowsDisplayConfigSnapshot::from_physical_topology(
                &journal.physical_topology,
            )
        })
        .transpose()?;
    if let Some(physical) = &physical {
        apply_topology(physical)?;
    }
    let restored = journal.clone().with_phase(RecoveryPhase::PhysicalRestored);
    store
        .update(&restored)
        .map_err(|error| format!("Windows display restore phase failed: {error}"))?;
    if let Some(physical) = &physical {
        verify_topology(physical)?;
    }
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

fn unavailable_physical_topology() -> PhysicalDisplayTopology {
    PhysicalDisplayTopology {
        displays: Vec::new(),
        mac_windows: Vec::new(),
        windows_adapter_luid: None,
        windows_target_paths: Vec::new(),
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
fn wait_for_swapchain(
    driver: &DriverHandle,
    monitor_id: u64,
    arrival: MonitorArrivalIdentity,
) -> Result<WindowsPathIdentity, String> {
    let identity = WindowsPathIdentity {
        adapter: AdapterLuid {
            high_part: (arrival.adapter_luid >> 32) as i32,
            low_part: arrival.adapter_luid as u32,
        },
        target_id: arrival.target_id,
    };
    for delay in [0, 20, 40, 80, 160, 320, 640, 1_000, 1_000, 1_000] {
        if delay != 0 {
            thread::sleep(Duration::from_millis(delay));
        }
        if driver.swapchain_assigned(monitor_id)? {
            return Ok(identity);
        }
    }
    Err(format!(
        "Windows could not activate the IDD target {:08x}:{:08x}/{}",
        identity.adapter.high_part, identity.adapter.low_part, identity.target_id
    ))
}

fn activate_virtual_display() -> Result<(), String> {
    // IddCxMonitorArrival exposes a connected target but intentionally does not
    // add it to the active desktop topology. The companion host must request
    // the standard extend topology from the interactive session before QDC can
    // report the path and before DWM can create the swapchain.
    let status = unsafe { SetDisplayConfig(0, null(), 0, null(), SDC_APPLY | SDC_TOPOLOGY_EXTEND) };
    (status == ERROR_SUCCESS as i32)
        .then_some(())
        .ok_or_else(|| format!("Windows could not activate the IDD display topology: {status}"))
}
