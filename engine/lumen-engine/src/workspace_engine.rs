use super::*;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum LumenWorkspacePolicy {
    Coexist = 0,
    PromoteVirtualMain = 1,
    FocusedWorkspace = 2,
    IsolatedWorkspace = 3,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenWorkspaceState {
    Idle = 0,
    Starting = 1,
    Active = 2,
    Stopping = 3,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenWorkspaceCommandKind {
    SnapshotWorkspace = 0,
    CreateVirtualDisplay = 1,
    ConfigureVirtualDisplay = 2,
    PromoteVirtualMain = 3,
    MoveTargetWindows = 4,
    ApplyIsolation = 5,
    StartCapture = 6,
    StopCapture = 7,
    RestoreWorkspace = 8,
    DestroyVirtualDisplay = 9,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenWorkspaceSessionRequest {
    pub policy: LumenWorkspacePolicy,
    pub move_target_windows: bool,
    pub manage_capture: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenWorkspaceCommand {
    pub kind: LumenWorkspaceCommandKind,
    pub generation: u64,
    pub sequence: u32,
}

#[derive(Default)]
pub(crate) struct AppliedResources {
    pub(crate) snapshot: bool,
    pub(crate) display: bool,
    pub(crate) capture: bool,
}

pub struct WorkspaceEngine {
    pub(crate) state: LumenWorkspaceState,
    pub(crate) generation: u64,
    pub(crate) next_sequence: u32,
    pub(crate) queued: VecDeque<LumenWorkspaceCommand>,
    pub(crate) awaiting: Option<LumenWorkspaceCommand>,
    pub(crate) resources: AppliedResources,
    manage_capture: bool,
    pub(crate) recovery_store: Option<RecoveryJournalStore>,
    pub(crate) recovery_journal: Option<WorkspaceRecoveryJournal>,
    pub(crate) last_failure: LumenEngineStatus,
}

impl Default for WorkspaceEngine {
    fn default() -> Self {
        Self {
            state: LumenWorkspaceState::Idle,
            generation: 0,
            next_sequence: 0,
            queued: VecDeque::new(),
            awaiting: None,
            resources: AppliedResources::default(),
            manage_capture: true,
            recovery_store: None,
            recovery_journal: None,
            last_failure: LumenEngineStatus::Ok,
        }
    }
}

impl WorkspaceEngine {
    #[cfg(test)]
    pub(crate) fn awaiting_command(&self) -> Option<LumenWorkspaceCommand> {
        self.awaiting
    }

    pub fn begin_session(&mut self, request: LumenWorkspaceSessionRequest) -> LumenEngineStatus {
        if self.state != LumenWorkspaceState::Idle || self.awaiting.is_some() {
            return LumenEngineStatus::InvalidState;
        }
        let recovery_status = self.recover_before_session();
        if recovery_status != LumenEngineStatus::Ok {
            return recovery_status;
        }

        self.generation = self.generation.wrapping_add(1).max(1);
        self.next_sequence = 0;
        self.queued.clear();
        self.resources = AppliedResources::default();
        self.manage_capture = request.manage_capture;
        self.last_failure = LumenEngineStatus::Ok;
        self.state = LumenWorkspaceState::Starting;

        self.enqueue(LumenWorkspaceCommandKind::SnapshotWorkspace);
        self.enqueue(LumenWorkspaceCommandKind::CreateVirtualDisplay);
        self.enqueue(LumenWorkspaceCommandKind::ConfigureVirtualDisplay);
        if self.manage_capture {
            self.enqueue(LumenWorkspaceCommandKind::StartCapture);
        }

        if request.policy != LumenWorkspacePolicy::Coexist {
            self.enqueue(LumenWorkspaceCommandKind::PromoteVirtualMain);
        }
        if request.move_target_windows
            || matches!(
                request.policy,
                LumenWorkspacePolicy::FocusedWorkspace | LumenWorkspacePolicy::IsolatedWorkspace
            )
        {
            self.enqueue(LumenWorkspaceCommandKind::MoveTargetWindows);
        }
        if request.policy == LumenWorkspacePolicy::IsolatedWorkspace {
            self.enqueue(LumenWorkspaceCommandKind::ApplyIsolation);
        }
        self.finish_transition_if_ready();
        LumenEngineStatus::Ok
    }

    pub fn next_command(&mut self) -> Result<LumenWorkspaceCommand, LumenEngineStatus> {
        if self.awaiting.is_some() {
            return Err(LumenEngineStatus::InvalidState);
        }

        let Some(command) = self.queued.pop_front() else {
            return Err(LumenEngineStatus::NoCommand);
        };
        self.awaiting = Some(command);
        Ok(command)
    }

    pub fn complete_command(
        &mut self,
        command: LumenWorkspaceCommand,
        succeeded: bool,
    ) -> LumenEngineStatus {
        let Some(expected) = self.awaiting else {
            return LumenEngineStatus::InvalidState;
        };
        if command != expected {
            return LumenEngineStatus::CommandMismatch;
        }
        self.awaiting = None;

        if !succeeded {
            self.last_failure = LumenEngineStatus::CommandFailed;
            if self.state == LumenWorkspaceState::Stopping {
                self.record_cleanup_failure(command.kind);
            } else {
                let _ = self.schedule_recovery();
            }
            return LumenEngineStatus::CommandFailed;
        }

        self.record_success(command.kind);
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
        if self.state == LumenWorkspaceState::Idle {
            return LumenEngineStatus::InvalidState;
        }
        if self.awaiting.is_some() {
            return LumenEngineStatus::InvalidState;
        }

        self.schedule_recovery()
    }

    pub(crate) fn enqueue(&mut self, kind: LumenWorkspaceCommandKind) {
        let command = LumenWorkspaceCommand {
            kind,
            generation: self.generation,
            sequence: self.next_sequence,
        };
        self.next_sequence = self.next_sequence.wrapping_add(1);
        self.queued.push_back(command);
    }

    fn record_success(&mut self, kind: LumenWorkspaceCommandKind) {
        match kind {
            LumenWorkspaceCommandKind::SnapshotWorkspace => self.resources.snapshot = true,
            LumenWorkspaceCommandKind::CreateVirtualDisplay => self.resources.display = true,
            LumenWorkspaceCommandKind::StartCapture => self.resources.capture = true,
            LumenWorkspaceCommandKind::StopCapture => self.resources.capture = false,
            LumenWorkspaceCommandKind::RestoreWorkspace => self.resources.snapshot = false,
            LumenWorkspaceCommandKind::DestroyVirtualDisplay => self.resources.display = false,
            LumenWorkspaceCommandKind::ConfigureVirtualDisplay
            | LumenWorkspaceCommandKind::PromoteVirtualMain
            | LumenWorkspaceCommandKind::MoveTargetWindows
            | LumenWorkspaceCommandKind::ApplyIsolation => {}
        }
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
            }
            _ => {}
        }
    }
}
