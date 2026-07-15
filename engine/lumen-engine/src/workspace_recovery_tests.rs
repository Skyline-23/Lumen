use std::future::{pending, Future};
use std::time::Duration;

use super::*;

#[derive(Default)]
pub(crate) struct FakeWorkspaceAdapter {
    pub(crate) events: Vec<&'static str>,
    pub(crate) hang_before_first_frame: bool,
    pub(crate) first_frame_started: Option<tokio::sync::oneshot::Sender<()>>,
}

impl WorkspacePlatformAdapter for FakeWorkspaceAdapter {
    fn snapshot_workspace(
        &mut self,
    ) -> impl Future<Output = Result<PhysicalDisplayTopology, WorkspaceAdapterError>> + Send {
        self.events.push("snapshot");
        async { Ok(topology()) }
    }

    fn create_virtual_display(
        &mut self,
    ) -> impl Future<Output = Result<VirtualDisplayIdentity, WorkspaceAdapterError>> + Send {
        self.events.push("create-virtual");
        async {
            Ok(VirtualDisplayIdentity {
                id: "virtual-1".to_owned(),
            })
        }
    }

    fn configure_virtual_display(
        &mut self,
        _identity: &VirtualDisplayIdentity,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send {
        self.events.push("configure-virtual");
        async { Ok(()) }
    }

    fn start_capture_until_first_frame(
        &mut self,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send {
        self.events.push("capture-started");
        let first_frame_started = self.first_frame_started.take();
        let hang = self.hang_before_first_frame;
        async move {
            if let Some(sender) = first_frame_started {
                let _ = sender.send(());
            }
            if hang {
                pending::<()>().await;
            }
            Ok(())
        }
    }

    fn isolate_physical_displays(
        &mut self,
        _topology: &PhysicalDisplayTopology,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send {
        self.events.push("isolate-physical");
        async { Ok(()) }
    }

    fn stop_capture(&mut self) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send {
        self.events.push("stop-capture");
        async { Ok(()) }
    }

    fn restore_physical_displays(
        &mut self,
        _topology: &PhysicalDisplayTopology,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send {
        self.events.push("restore-physical");
        async { Ok(()) }
    }

    fn verify_physical_displays(
        &mut self,
        _topology: &PhysicalDisplayTopology,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send {
        self.events.push("verify-physical");
        async { Ok(()) }
    }

    fn destroy_virtual_display(
        &mut self,
        _identity: &VirtualDisplayIdentity,
    ) -> impl Future<Output = Result<(), WorkspaceAdapterError>> + Send {
        self.events.push("destroy-virtual");
        async { Ok(()) }
    }
}

fn topology() -> PhysicalDisplayTopology {
    PhysicalDisplayTopology {
        displays: vec![PhysicalDisplayState {
            id: "physical-1".to_owned(),
            mode: PhysicalDisplayMode {
                width: 2560,
                height: 1440,
                refresh_millihz: 120_000,
                bit_depth: 10,
            },
            origin_x: 0,
            origin_y: 0,
            mirror_master_id: None,
            enabled: true,
        }],
        windows_adapter_luid: None,
        windows_target_paths: Vec::new(),
    }
}

pub(crate) fn session() -> WorkspaceRecoverySession {
    WorkspaceRecoverySession {
        platform: WorkspacePlatform::Macos,
        session_id: "session-1".to_owned(),
        timestamp_unix_ms: 1_784_000_000_000,
    }
}

pub(crate) fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .unwrap()
}

#[test]
fn first_encoded_frame_precedes_physical_isolation() {
    // Given: an empty recovery store and a first-frame-capable adapter.
    let directory = tempfile::tempdir().unwrap();
    let store = RecoveryJournalStore::new(directory.path().join("display-recovery.json"));
    let adapter = FakeWorkspaceAdapter::default();
    let mut engine = RecoverableWorkspaceEngine::new(adapter, store, Duration::from_secs(1));

    // When: a workspace session starts successfully.
    runtime().block_on(engine.start_session(session())).unwrap();

    // Then: isolation occurs only after capture reports its first encoded frame.
    assert_eq!(
        engine.adapter().events,
        vec![
            "snapshot",
            "create-virtual",
            "configure-virtual",
            "capture-started",
            "isolate-physical",
        ]
    );
    assert_eq!(engine.active_phase(), Some(RecoveryPhase::Isolated));
}

#[test]
fn hung_first_frame_times_out_without_isolating() {
    // Given: an adapter whose capture never produces a first frame.
    let directory = tempfile::tempdir().unwrap();
    let store = RecoveryJournalStore::new(directory.path().join("display-recovery.json"));
    let adapter = FakeWorkspaceAdapter {
        hang_before_first_frame: true,
        ..FakeWorkspaceAdapter::default()
    };
    let mut engine = RecoverableWorkspaceEngine::new(adapter, store, Duration::from_millis(1));

    // When: bounded startup reaches the first-frame barrier.
    let error = runtime()
        .block_on(engine.start_session(session()))
        .unwrap_err();

    // Then: timeout recovery restores topology and never isolates it.
    assert!(matches!(
        error,
        WorkspaceLifecycleError::FirstFrameTimeout { .. }
    ));
    assert!(!engine.adapter().events.contains(&"isolate-physical"));
    assert_eq!(
        &engine.adapter().events[4..],
        &[
            "stop-capture",
            "restore-physical",
            "verify-physical",
            "destroy-virtual"
        ]
    );
}

#[test]
fn every_crash_phase_restores_before_destroying_virtual_display() {
    // Given: each journal phase reachable at a deterministic process kill point.
    let phases = [
        RecoveryPhase::SnapshotPersisted,
        RecoveryPhase::VirtualCreated,
        RecoveryPhase::VirtualConfigured,
        RecoveryPhase::CaptureStarting,
        RecoveryPhase::FirstFrameReady,
        RecoveryPhase::IsolationStarted,
        RecoveryPhase::Isolated,
        RecoveryPhase::CaptureStopped,
        RecoveryPhase::PhysicalRestored,
        RecoveryPhase::RestorationVerified,
    ];

    for (index, phase) in phases.into_iter().enumerate() {
        let directory = tempfile::tempdir().unwrap();
        let store = RecoveryJournalStore::new(directory.path().join("display-recovery.json"));
        let journal = WorkspaceRecoveryJournal::new(
            WorkspaceRecoveryMetadata {
                platform: WorkspacePlatform::Windows,
                generation: u64::try_from(index + 1).unwrap(),
                session_id: format!("crash-{index}"),
                timestamp_unix_ms: 1_784_000_000_000,
            },
            topology(),
        )
        .unwrap()
        .with_virtual_display(VirtualDisplayIdentity {
            id: "virtual-1".to_owned(),
        })
        .with_phase(phase);
        store.create(&journal).unwrap();
        let adapter = FakeWorkspaceAdapter::default();
        let mut engine = RecoverableWorkspaceEngine::new(adapter, store, Duration::from_secs(1));

        // When: the next process recovers before accepting a session.
        runtime().block_on(engine.recover_before_session()).unwrap();

        // Then: destroy is last and follows a verified physical topology.
        let events = &engine.adapter().events;
        assert_eq!(events.last(), Some(&"destroy-virtual"), "phase {phase:?}");
        let verify = events.iter().position(|event| *event == "verify-physical");
        let destroy = events.iter().position(|event| *event == "destroy-virtual");
        assert!(verify < destroy, "phase {phase:?}: {events:?}");
    }
}

#[test]
fn verified_restore_deletes_journal_before_destroy() {
    // Given: an active isolated workspace with a durable journal.
    let directory = tempfile::tempdir().unwrap();
    let store = RecoveryJournalStore::new(directory.path().join("display-recovery.json"));
    let journal_path = store.path().to_path_buf();
    let adapter = FakeWorkspaceAdapter::default();
    let mut engine = RecoverableWorkspaceEngine::new(adapter, store, Duration::from_secs(1));
    runtime().block_on(engine.start_session(session())).unwrap();

    // When: the session is stopped normally.
    runtime().block_on(engine.stop_session()).unwrap();

    // Then: capture stops, topology verifies, the journal is gone, and virtual destroys last.
    assert_eq!(
        &engine.adapter().events[5..],
        &[
            "stop-capture",
            "restore-physical",
            "verify-physical",
            "destroy-virtual"
        ]
    );
    assert!(!journal_path.exists());
}
