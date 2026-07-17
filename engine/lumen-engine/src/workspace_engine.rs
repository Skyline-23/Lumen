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
    VerifyPhysicalDisplays = 9,
    DestroyVirtualDisplay = 10,
    AwaitExternalFirstEncodedFrame = 11,
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
    pub payload_kind: LumenWorkspaceCommandPayloadKind,
}

impl LumenWorkspaceCommand {
    pub const fn placeholder() -> Self {
        Self {
            kind: LumenWorkspaceCommandKind::SnapshotWorkspace,
            generation: 0,
            sequence: 0,
            payload_kind: LumenWorkspaceCommandPayloadKind::None,
        }
    }
}

#[derive(Default)]
pub(crate) struct AppliedResources {
    pub(crate) snapshot: bool,
    pub(crate) display: bool,
    pub(crate) capture: bool,
    pub(crate) physical_restored: bool,
}

pub struct WorkspaceEngine {
    pub(crate) state: LumenWorkspaceState,
    pub(crate) generation: u64,
    pub(crate) next_sequence: u32,
    pub(crate) queued: VecDeque<LumenWorkspaceCommand>,
    pub(crate) awaiting: Option<LumenWorkspaceCommand>,
    pub(crate) resources: AppliedResources,
    pub(crate) manage_capture: bool,
    pub(crate) recovery_store: Option<RecoveryJournalStore>,
    pub(crate) recovery_platform: Option<WorkspacePlatform>,
    pub(crate) recovery_metadata: Option<WorkspaceRecoveryMetadata>,
    pub(crate) recovery_journal: Option<WorkspaceRecoveryJournal>,
    pub(crate) physical_topology: Option<PhysicalDisplayTopology>,
    pub(crate) virtual_display: Option<VirtualDisplayIdentity>,
    pub(crate) last_failure: LumenEngineStatus,
    pub(crate) cleanup_verification_failed: bool,
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
            recovery_platform: None,
            recovery_metadata: None,
            recovery_journal: None,
            physical_topology: None,
            virtual_display: None,
            last_failure: LumenEngineStatus::Ok,
            cleanup_verification_failed: false,
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
        self.cleanup_verification_failed = false;
        self.manage_capture = request.manage_capture;
        let recovery_status = self.prepare_new_recovery_session();
        if recovery_status != LumenEngineStatus::Ok {
            self.last_failure = recovery_status;
            return recovery_status;
        }
        self.last_failure = LumenEngineStatus::Ok;
        self.state = LumenWorkspaceState::Starting;

        self.enqueue(LumenWorkspaceCommandKind::SnapshotWorkspace);
        self.enqueue(LumenWorkspaceCommandKind::CreateVirtualDisplay);
        self.enqueue(LumenWorkspaceCommandKind::ConfigureVirtualDisplay);
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
        if self.manage_capture {
            self.enqueue(LumenWorkspaceCommandKind::StartCapture);
        } else if request.policy != LumenWorkspacePolicy::Coexist {
            self.enqueue(LumenWorkspaceCommandKind::AwaitExternalFirstEncodedFrame);
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
        let preparation = self.prepare_command(command.kind);
        if preparation != LumenEngineStatus::Ok {
            self.queued.push_front(command);
            self.last_failure = preparation;
            return Err(preparation);
        }
        self.awaiting = Some(command);
        Ok(command)
    }
}
