use crate::{
    LumenEngineStatus, LumenWorkspaceCommand, LumenWorkspaceCommandKind,
    LumenWorkspaceCommandPayloadKind, LumenWorkspaceState, WorkspaceCommandCompletion,
    WorkspaceEngine,
};

#[cfg(test)]
use crate::{PhysicalDisplayTopology, VirtualDisplayIdentity};

impl WorkspaceEngine {
    #[cfg(test)]
    pub(crate) fn complete_command(
        &mut self,
        command: LumenWorkspaceCommand,
        succeeded: bool,
    ) -> LumenEngineStatus {
        let completion = if succeeded {
            match command.kind {
                LumenWorkspaceCommandKind::SnapshotWorkspace => {
                    WorkspaceCommandCompletion::physical_topology(PhysicalDisplayTopology {
                        displays: Vec::new(),
                        windows_adapter_luid: None,
                        windows_target_paths: Vec::new(),
                    })
                }
                LumenWorkspaceCommandKind::CreateVirtualDisplay => {
                    let identity =
                        self.virtual_display
                            .clone()
                            .unwrap_or_else(|| VirtualDisplayIdentity {
                                id: format!("legacy-virtual-{}", self.generation),
                            });
                    self.virtual_display = Some(identity.clone());
                    WorkspaceCommandCompletion::virtual_display(identity)
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
                    WorkspaceCommandCompletion::succeeded()
                }
            }
        } else {
            WorkspaceCommandCompletion::failed()
        };
        self.complete_command_with_payload(command, completion)
    }

    pub fn complete_command_with_payload(
        &mut self,
        command: LumenWorkspaceCommand,
        completion: WorkspaceCommandCompletion,
    ) -> LumenEngineStatus {
        let Some(expected) = self.awaiting else {
            return LumenEngineStatus::InvalidState;
        };
        if command != expected {
            return LumenEngineStatus::CommandMismatch;
        }
        self.awaiting = None;

        if !completion.succeeded {
            self.last_failure = LumenEngineStatus::CommandFailed;
            if self.state == LumenWorkspaceState::Stopping {
                self.record_cleanup_failure(command.kind);
            } else {
                let _ = self.schedule_recovery();
            }
            return LumenEngineStatus::CommandFailed;
        }

        let completion_status = self.record_command_success(command.kind, completion.payload);
        if completion_status != LumenEngineStatus::Ok {
            self.last_failure = completion_status;
            let _ = self.schedule_recovery();
            return completion_status;
        }
        if self.state == LumenWorkspaceState::Stopping {
            let cleanup_status = self.advance_cleanup(command.kind);
            if cleanup_status != LumenEngineStatus::Ok {
                self.last_failure = cleanup_status;
                return cleanup_status;
            }
        }
        self.finish_transition_if_ready();
        LumenEngineStatus::Ok
    }

    pub fn end_session(&mut self) -> LumenEngineStatus {
        if self.state == LumenWorkspaceState::Idle || self.awaiting.is_some() {
            return LumenEngineStatus::InvalidState;
        }
        self.schedule_recovery()
    }

    pub(crate) fn enqueue(&mut self, kind: LumenWorkspaceCommandKind) {
        let command = LumenWorkspaceCommand {
            kind,
            generation: self.generation,
            sequence: self.next_sequence,
            payload_kind: command_payload_kind(kind),
        };
        self.next_sequence = self.next_sequence.wrapping_add(1);
        self.queued.push_back(command);
    }

    pub(crate) fn finish_transition_if_ready(&mut self) {
        if self.awaiting.is_some() || !self.queued.is_empty() {
            return;
        }
        match self.state {
            LumenWorkspaceState::Starting if !self.manage_capture || self.resources.capture => {
                self.state = LumenWorkspaceState::Active;
            }
            LumenWorkspaceState::Stopping
                if !self.resources.capture
                    && !self.resources.snapshot
                    && !self.resources.display
                    && self.recovery_journal.is_none() =>
            {
                self.state = LumenWorkspaceState::Idle;
                self.recovery_metadata = None;
                self.physical_topology = None;
                self.virtual_display = None;
            }
            _ => {}
        }
    }
}

const fn command_payload_kind(kind: LumenWorkspaceCommandKind) -> LumenWorkspaceCommandPayloadKind {
    match kind {
        LumenWorkspaceCommandKind::CreateVirtualDisplay
        | LumenWorkspaceCommandKind::DestroyVirtualDisplay => {
            LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity
        }
        LumenWorkspaceCommandKind::RestoreWorkspace
        | LumenWorkspaceCommandKind::VerifyPhysicalDisplays => {
            LumenWorkspaceCommandPayloadKind::PhysicalTopology
        }
        LumenWorkspaceCommandKind::SnapshotWorkspace
        | LumenWorkspaceCommandKind::ConfigureVirtualDisplay
        | LumenWorkspaceCommandKind::PromoteVirtualMain
        | LumenWorkspaceCommandKind::MoveTargetWindows
        | LumenWorkspaceCommandKind::ApplyIsolation
        | LumenWorkspaceCommandKind::StartCapture
        | LumenWorkspaceCommandKind::StopCapture => LumenWorkspaceCommandPayloadKind::None,
    }
}
