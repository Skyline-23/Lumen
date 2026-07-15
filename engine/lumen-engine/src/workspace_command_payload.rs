use std::ffi::{c_char, CStr};

use crate::{
    LumenEngineStatus, LumenWorkspaceCommand, LumenWorkspaceCommandKind, PhysicalDisplayTopology,
    VirtualDisplayIdentity, WorkspaceEngine,
};

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenWorkspaceCommandPayloadKind {
    None = 0,
    PhysicalTopology = 1,
    VirtualDisplayIdentity = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenWorkspaceCommandCompletion {
    pub succeeded: bool,
    pub payload_kind: LumenWorkspaceCommandPayloadKind,
    pub payload_json: *const c_char,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceCommandPayload {
    None,
    PhysicalTopology(PhysicalDisplayTopology),
    VirtualDisplayIdentity(VirtualDisplayIdentity),
}

impl WorkspaceCommandPayload {
    pub const fn kind(&self) -> LumenWorkspaceCommandPayloadKind {
        match self {
            Self::None => LumenWorkspaceCommandPayloadKind::None,
            Self::PhysicalTopology(_) => LumenWorkspaceCommandPayloadKind::PhysicalTopology,
            Self::VirtualDisplayIdentity(_) => {
                LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity
            }
        }
    }

    pub(crate) fn json(&self) -> Result<Option<String>, LumenEngineStatus> {
        match self {
            Self::None => Ok(None),
            Self::PhysicalTopology(topology) => serde_json::to_string(topology)
                .map(Some)
                .map_err(|_| LumenEngineStatus::CorruptData),
            Self::VirtualDisplayIdentity(identity) => serde_json::to_string(identity)
                .map(Some)
                .map_err(|_| LumenEngineStatus::CorruptData),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandCompletion {
    pub succeeded: bool,
    pub payload: WorkspaceCommandPayload,
}

impl WorkspaceCommandCompletion {
    pub const fn succeeded() -> Self {
        Self {
            succeeded: true,
            payload: WorkspaceCommandPayload::None,
        }
    }

    pub const fn failed() -> Self {
        Self {
            succeeded: false,
            payload: WorkspaceCommandPayload::None,
        }
    }

    pub const fn physical_topology(topology: PhysicalDisplayTopology) -> Self {
        Self {
            succeeded: true,
            payload: WorkspaceCommandPayload::PhysicalTopology(topology),
        }
    }

    pub const fn virtual_display(identity: VirtualDisplayIdentity) -> Self {
        Self {
            succeeded: true,
            payload: WorkspaceCommandPayload::VirtualDisplayIdentity(identity),
        }
    }
}

impl WorkspaceEngine {
    pub fn command_payload(
        &self,
        command: LumenWorkspaceCommand,
    ) -> Result<WorkspaceCommandPayload, LumenEngineStatus> {
        if self.awaiting != Some(command) {
            return Err(LumenEngineStatus::CommandMismatch);
        }
        match command.payload_kind {
            LumenWorkspaceCommandPayloadKind::None => Ok(WorkspaceCommandPayload::None),
            LumenWorkspaceCommandPayloadKind::PhysicalTopology => self
                .physical_topology
                .clone()
                .map(WorkspaceCommandPayload::PhysicalTopology)
                .ok_or(LumenEngineStatus::CorruptData),
            LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity => self
                .virtual_display
                .clone()
                .map(WorkspaceCommandPayload::VirtualDisplayIdentity)
                .ok_or(LumenEngineStatus::CorruptData),
        }
    }
}

pub(crate) unsafe fn decode_ffi_completion(
    command: LumenWorkspaceCommand,
    completion: LumenWorkspaceCommandCompletion,
) -> Result<WorkspaceCommandCompletion, LumenEngineStatus> {
    if !completion.succeeded {
        return match completion.payload_kind {
            LumenWorkspaceCommandPayloadKind::None => Ok(WorkspaceCommandCompletion::failed()),
            LumenWorkspaceCommandPayloadKind::PhysicalTopology
            | LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity => {
                Err(LumenEngineStatus::InvalidArgument)
            }
        };
    }
    let payload = match completion.payload_kind {
        LumenWorkspaceCommandPayloadKind::None => WorkspaceCommandPayload::None,
        LumenWorkspaceCommandPayloadKind::PhysicalTopology => {
            // SAFETY: Category 8 (FFI boundary). The outer FFI contract keeps
            // this non-null NUL-terminated JSON pointer live for the call.
            WorkspaceCommandPayload::PhysicalTopology(unsafe {
                decode_payload(completion.payload_json)?
            })
        }
        LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity => {
            // SAFETY: Category 8 (FFI boundary). The outer FFI contract keeps
            // this non-null NUL-terminated JSON pointer live for the call.
            WorkspaceCommandPayload::VirtualDisplayIdentity(unsafe {
                decode_payload(completion.payload_json)?
            })
        }
    };
    let expected = expected_completion_kind(command.kind);
    if payload.kind() != expected {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    Ok(WorkspaceCommandCompletion {
        succeeded: true,
        payload,
    })
}

const fn expected_completion_kind(
    kind: LumenWorkspaceCommandKind,
) -> LumenWorkspaceCommandPayloadKind {
    match kind {
        LumenWorkspaceCommandKind::SnapshotWorkspace => {
            LumenWorkspaceCommandPayloadKind::PhysicalTopology
        }
        LumenWorkspaceCommandKind::CreateVirtualDisplay => {
            LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity
        }
        LumenWorkspaceCommandKind::ConfigureVirtualDisplay
        | LumenWorkspaceCommandKind::PromoteVirtualMain
        | LumenWorkspaceCommandKind::MoveTargetWindows
        | LumenWorkspaceCommandKind::ApplyIsolation
        | LumenWorkspaceCommandKind::StartCapture
        | LumenWorkspaceCommandKind::StopCapture
        | LumenWorkspaceCommandKind::RestoreWorkspace
        | LumenWorkspaceCommandKind::VerifyPhysicalDisplays
        | LumenWorkspaceCommandKind::DestroyVirtualDisplay => {
            LumenWorkspaceCommandPayloadKind::None
        }
    }
}

unsafe fn decode_payload<T: serde::de::DeserializeOwned>(
    payload_json: *const c_char,
) -> Result<T, LumenEngineStatus> {
    if payload_json.is_null() {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    // SAFETY: Category 8 (FFI boundary). The caller contract requires a live
    // NUL-terminated JSON string, and null was rejected above.
    let json = unsafe { CStr::from_ptr(payload_json) };
    serde_json::from_slice(json.to_bytes()).map_err(|_| LumenEngineStatus::CorruptData)
}
