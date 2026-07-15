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
struct AppliedResources {
    snapshot: bool,
    display: bool,
    capture: bool,
}

pub struct WorkspaceEngine {
    pub(crate) state: LumenWorkspaceState,
    pub(crate) generation: u64,
    next_sequence: u32,
    queued: VecDeque<LumenWorkspaceCommand>,
    awaiting: Option<LumenWorkspaceCommand>,
    resources: AppliedResources,
    manage_capture: bool,
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
                self.finish_transition_if_ready();
            } else {
                self.schedule_recovery();
            }
            return LumenEngineStatus::CommandFailed;
        }

        self.record_success(command.kind);
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

        self.schedule_recovery();
        LumenEngineStatus::Ok
    }

    fn enqueue(&mut self, kind: LumenWorkspaceCommandKind) {
        let command = LumenWorkspaceCommand {
            kind,
            generation: self.generation,
            sequence: self.next_sequence,
        };
        self.next_sequence = self.next_sequence.wrapping_add(1);
        self.queued.push_back(command);
    }

    fn schedule_recovery(&mut self) {
        self.state = LumenWorkspaceState::Stopping;
        self.queued.clear();

        if self.resources.capture {
            self.enqueue(LumenWorkspaceCommandKind::StopCapture);
        }
        if self.resources.snapshot {
            self.enqueue(LumenWorkspaceCommandKind::RestoreWorkspace);
        }
        if self.resources.display {
            self.enqueue(LumenWorkspaceCommandKind::DestroyVirtualDisplay);
        }
        self.finish_transition_if_ready();
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

    fn record_cleanup_failure(&mut self, kind: LumenWorkspaceCommandKind) {
        match kind {
            LumenWorkspaceCommandKind::StopCapture => self.resources.capture = false,
            LumenWorkspaceCommandKind::RestoreWorkspace => self.resources.snapshot = false,
            LumenWorkspaceCommandKind::DestroyVirtualDisplay => self.resources.display = false,
            _ => {}
        }
    }

    fn finish_transition_if_ready(&mut self) {
        if self.awaiting.is_some() || !self.queued.is_empty() {
            return;
        }

        match self.state {
            LumenWorkspaceState::Starting if !self.manage_capture || self.resources.capture => {
                self.state = LumenWorkspaceState::Active;
            }
            LumenWorkspaceState::Stopping => {
                self.state = LumenWorkspaceState::Idle;
            }
            _ => {}
        }
    }
}
