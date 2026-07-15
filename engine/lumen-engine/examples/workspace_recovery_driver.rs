use std::error::Error;
use std::future::Future;
use std::path::PathBuf;
use std::time::Duration;

use lumen_engine::{
    PhysicalDisplayMode, PhysicalDisplayState, PhysicalDisplayTopology, RecoverableWorkspaceEngine,
    RecoveryJournalStore, RecoveryPhase, VirtualDisplayIdentity, WorkspaceAdapterError,
    WorkspacePlatform, WorkspacePlatformAdapter, WorkspaceRecoveryJournal,
    WorkspaceRecoveryMetadata, WorkspaceRecoverySession,
};

#[derive(Default)]
struct DriverAdapter {
    events: Vec<&'static str>,
}

impl WorkspacePlatformAdapter for DriverAdapter {
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
        async { Ok(virtual_display()) }
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
        self.events.push("first-encoded-frame");
        async { Ok(()) }
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
                width: 3840,
                height: 2160,
                refresh_millihz: 120_000,
                bit_depth: 10,
            },
            origin_x: 0,
            origin_y: 0,
            mirror_master_id: None,
            enabled: true,
        }],
        windows_adapter_luid: None,
        windows_target_paths: vec!["DISPLAYCONFIG_PATH_INFO:0".to_owned()],
    }
}

fn virtual_display() -> VirtualDisplayIdentity {
    VirtualDisplayIdentity {
        id: "virtual-1".to_owned(),
    }
}

fn runtime() -> Result<tokio::runtime::Runtime, Box<dyn Error>> {
    Ok(tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()?)
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let mode = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("usage: workspace_recovery_driver <happy|kill|restart> <journal-path>")?;
    let journal_path = arguments
        .next()
        .map(PathBuf::from)
        .ok_or("journal path is required")?;
    let store = RecoveryJournalStore::new(journal_path.clone());

    match mode.as_str() {
        "happy" => {
            let adapter = DriverAdapter::default();
            let mut engine =
                RecoverableWorkspaceEngine::new(adapter, store, Duration::from_secs(1));
            runtime()?.block_on(engine.start_session(WorkspaceRecoverySession {
                platform: WorkspacePlatform::Windows,
                session_id: "driver-happy".to_owned(),
                timestamp_unix_ms: 1_784_000_000_000,
            }))?;
            println!(
                "phase={:?} events={:?}",
                engine.active_phase(),
                engine.adapter().events
            );
            runtime()?.block_on(engine.stop_session())?;
            println!(
                "cleanup={:?} journal_exists={}",
                engine.adapter().events,
                journal_path.exists()
            );
        }
        "kill" => {
            let journal = WorkspaceRecoveryJournal::new(
                WorkspaceRecoveryMetadata {
                    platform: WorkspacePlatform::Windows,
                    generation: 77,
                    session_id: "driver-kill".to_owned(),
                    timestamp_unix_ms: 1_784_000_000_000,
                },
                topology(),
            )?
            .with_virtual_display(virtual_display())
            .with_phase(RecoveryPhase::IsolationStarted);
            store.create(&journal)?;
            let envelope: serde_json::Value =
                serde_json::from_slice(&std::fs::read(&journal_path)?)?;
            println!(
                "simulated_kill phase={:?} topology={:?} checksum={} journal={}",
                journal.phase,
                journal.physical_topology.displays,
                envelope["checksum_sha256"],
                journal_path.display()
            );
            std::process::exit(75);
        }
        "restart" => {
            let adapter = DriverAdapter::default();
            let mut engine =
                RecoverableWorkspaceEngine::new(adapter, store, Duration::from_secs(1));
            let outcome = runtime()?.block_on(engine.recover_before_session())?;
            println!(
                "restart={outcome:?} events={:?} journal_exists={}",
                engine.adapter().events,
                journal_path.exists()
            );
        }
        _ => return Err(format!("unknown mode: {mode}").into()),
    }
    Ok(())
}
