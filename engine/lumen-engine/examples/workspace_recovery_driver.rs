use std::error::Error;
use std::ffi::{c_char, CString};
use std::path::{Path, PathBuf};

use lumen_engine::{
    lumen_workspace_engine_begin_session, lumen_workspace_engine_command_payload_json_size,
    lumen_workspace_engine_complete_command_with_payload,
    lumen_workspace_engine_copy_command_payload_json, lumen_workspace_engine_create_recoverable,
    lumen_workspace_engine_destroy, lumen_workspace_engine_end_session,
    lumen_workspace_engine_next_command, lumen_workspace_engine_state, LumenEngineStatus,
    LumenWorkspaceCommand, LumenWorkspaceCommandCompletion, LumenWorkspaceCommandKind,
    LumenWorkspaceCommandPayloadKind, LumenWorkspaceEngine, LumenWorkspacePolicy,
    LumenWorkspaceSessionRequest, LumenWorkspaceState, PhysicalDisplayMode, PhysicalDisplayState,
    PhysicalDisplayTopology, WorkspacePlatform,
};

struct ProductionEngine(*mut LumenWorkspaceEngine);

impl ProductionEngine {
    fn open(journal_path: &Path) -> Result<Self, Box<dyn Error>> {
        let path = CString::new(journal_path.to_string_lossy().as_bytes())?;
        // SAFETY: Category 8 (FFI boundary). `path` is NUL terminated and remains
        // live for the duration of this constructor call.
        let engine = unsafe {
            lumen_workspace_engine_create_recoverable(path.as_ptr(), WorkspacePlatform::Windows)
        };
        if engine.is_null() {
            return Err("production workspace engine allocation failed".into());
        }
        Ok(Self(engine))
    }

    fn begin(&mut self) -> LumenEngineStatus {
        lumen_workspace_engine_begin_session(
            self.0,
            LumenWorkspaceSessionRequest {
                policy: LumenWorkspacePolicy::IsolatedWorkspace,
                move_target_windows: true,
                manage_capture: true,
            },
        )
    }

    fn end(&mut self) -> LumenEngineStatus {
        lumen_workspace_engine_end_session(self.0)
    }

    fn state(&self) -> LumenWorkspaceState {
        lumen_workspace_engine_state(self.0)
    }

    fn next(&mut self) -> Result<Option<LumenWorkspaceCommand>, Box<dyn Error>> {
        let mut command = LumenWorkspaceCommand::placeholder();
        match lumen_workspace_engine_next_command(self.0, &mut command) {
            LumenEngineStatus::Ok => Ok(Some(command)),
            LumenEngineStatus::NoCommand => Ok(None),
            status => Err(format!("next command failed: {status:?}").into()),
        }
    }

    fn payload_json(
        &self,
        command: LumenWorkspaceCommand,
    ) -> Result<Option<String>, Box<dyn Error>> {
        let size = lumen_workspace_engine_command_payload_json_size(self.0, command);
        if size == 0 {
            return Ok(None);
        }
        let mut bytes = vec![0_u8; size];
        let status = lumen_workspace_engine_copy_command_payload_json(
            self.0,
            command,
            bytes.as_mut_ptr().cast::<c_char>(),
            bytes.len(),
        );
        if status != LumenEngineStatus::Ok {
            return Err(format!("payload copy failed: {status:?}").into());
        }
        bytes.pop();
        Ok(Some(String::from_utf8(bytes)?))
    }

    fn complete(
        &mut self,
        command: LumenWorkspaceCommand,
        kind: LumenWorkspaceCommandPayloadKind,
        json: Option<&CString>,
    ) -> Result<(), Box<dyn Error>> {
        let completion = LumenWorkspaceCommandCompletion {
            succeeded: true,
            payload_kind: kind,
            payload_json: json.map_or(std::ptr::null(), |value| value.as_ptr()),
        };
        // SAFETY: Category 8 (FFI boundary). Any payload pointer references the
        // live `CString` held by this stack frame for the complete call.
        let status = unsafe {
            lumen_workspace_engine_complete_command_with_payload(self.0, command, completion)
        };
        if status != LumenEngineStatus::Ok {
            return Err(format!("complete {:?} failed: {status:?}", command.kind).into());
        }
        Ok(())
    }
}

impl Drop for ProductionEngine {
    fn drop(&mut self) {
        // SAFETY: Category 12 (double free). This owner stores the sole pointer
        // returned by the constructor and destroys it exactly once in `drop`.
        unsafe { lumen_workspace_engine_destroy(self.0) };
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
            origin_x: -1920,
            origin_y: 0,
            mirror_master_id: Some("physical-2".to_owned()),
            enabled: true,
            active: true,
            online: true,
        }],
        windows_adapter_luid: None,
        windows_target_paths: vec!["DISPLAYCONFIG_PATH_INFO:0".to_owned()],
    }
}

fn drive(
    engine: &mut ProductionEngine,
    stop_after: Option<LumenWorkspaceCommandKind>,
) -> Result<Vec<String>, Box<dyn Error>> {
    let mut events = Vec::new();
    while let Some(command) = engine.next()? {
        let input = engine.payload_json(command)?;
        events.push(format!("{:?}", command.kind));
        let (kind, payload) = match command.kind {
            LumenWorkspaceCommandKind::SnapshotWorkspace => (
                LumenWorkspaceCommandPayloadKind::PhysicalTopology,
                Some(CString::new(serde_json::to_vec(&topology())?)?),
            ),
            LumenWorkspaceCommandKind::CreateVirtualDisplay => (
                LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity,
                Some(CString::new(
                    input.ok_or("create identity payload missing")?,
                )?),
            ),
            _ => (LumenWorkspaceCommandPayloadKind::None, None),
        };
        engine.complete(command, kind, payload.as_ref())?;
        if stop_after == Some(command.kind) {
            break;
        }
    }
    Ok(events)
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
    let mut engine = ProductionEngine::open(&journal_path)?;

    match mode.as_str() {
        "happy" => {
            let begin = engine.begin();
            if begin != LumenEngineStatus::Ok {
                return Err(format!("begin failed: {begin:?}").into());
            }
            let startup = drive(&mut engine, None)?;
            let journal_active = journal_path.exists();
            if engine.end() != LumenEngineStatus::Ok {
                return Err("end failed".into());
            }
            let cleanup = drive(&mut engine, None)?;
            println!(
                "startup={startup:?} journal_active={journal_active} cleanup={cleanup:?} state={:?} journal_exists={}",
                engine.state(),
                journal_path.exists()
            );
        }
        "kill" => {
            let begin = engine.begin();
            if begin != LumenEngineStatus::Ok {
                return Err(format!("begin failed: {begin:?}").into());
            }
            let startup = drive(&mut engine, Some(LumenWorkspaceCommandKind::ApplyIsolation))?;
            println!(
                "simulated_kill startup={startup:?} state={:?} journal_exists={} journal={}",
                engine.state(),
                journal_path.exists(),
                journal_path.display()
            );
            std::process::exit(75);
        }
        "restart" => {
            let begin = engine.begin();
            if begin != LumenEngineStatus::RecoveryRequired {
                return Err(format!("restart did not require recovery: {begin:?}").into());
            }
            let cleanup = drive(&mut engine, None)?;
            println!(
                "restart=Recovered cleanup={cleanup:?} state={:?} journal_exists={}",
                engine.state(),
                journal_path.exists()
            );
        }
        _ => return Err(format!("unknown mode: {mode}").into()),
    }
    Ok(())
}
