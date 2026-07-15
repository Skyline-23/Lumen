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

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenDisplayModeRequest {
    pub width: u32,
    pub height: u32,
    pub scale_percent: u32,
    pub dimensions_are_logical: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenDisplayGeometry {
    pub stream_width: u32,
    pub stream_height: u32,
    pub logical_width: u32,
    pub logical_height: u32,
    pub backing_width: u32,
    pub backing_height: u32,
}

pub const VIRTUAL_DISPLAY_REASON_SESSION_REQUESTED: u32 = 1 << 0;
pub const VIRTUAL_DISPLAY_REASON_APP_REQUESTED: u32 = 1 << 1;
pub const VIRTUAL_DISPLAY_REASON_HDR_DISPLAY_REQUIRED: u32 = 1 << 2;
pub const VIRTUAL_DISPLAY_REASON_HIDPI_REQUESTED: u32 = 1 << 3;
pub const VIRTUAL_DISPLAY_REASON_LOGICAL_DIMENSIONS: u32 = 1 << 4;
pub const VIRTUAL_DISPLAY_REASON_SCALED_DESKTOP: u32 = 1 << 5;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenVirtualDisplayRequest {
    pub session_requested: bool,
    pub app_requested: bool,
    pub hdr_display_required: bool,
    pub hidpi_requested: bool,
    pub dimensions_are_logical: bool,
    pub scale_percent: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenVirtualDisplayPlan {
    pub required: bool,
    pub reason_flags: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenDisplayGamut {
    Srgb = 0,
    DisplayP3 = 1,
    Rec2020 = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenDisplayTransfer {
    Sdr = 0,
    Pq = 1,
    Hlg = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenDisplayColorRequest {
    pub hdr_enabled: bool,
    pub client_gamut: i32,
    pub client_transfer: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LumenDisplayColorProfile {
    pub gamut: LumenDisplayGamut,
    pub transfer: LumenDisplayTransfer,
    pub red_x: f64,
    pub red_y: f64,
    pub green_x: f64,
    pub green_y: f64,
    pub blue_x: f64,
    pub blue_y: f64,
    pub white_x: f64,
    pub white_y: f64,
    pub hdr_capable: bool,
}

fn even_dimension(value: u32) -> u32 {
    value.max(2) & !1
}

pub fn resolve_display_geometry(
    request: LumenDisplayModeRequest,
) -> Result<LumenDisplayGeometry, LumenEngineStatus> {
    if request.width == 0 || request.height == 0 || request.scale_percent == 0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }

    let width = even_dimension(request.width);
    let height = even_dimension(request.height);
    if request.dimensions_are_logical {
        return Ok(LumenDisplayGeometry {
            stream_width: width,
            stream_height: height,
            logical_width: width,
            logical_height: height,
            backing_width: width,
            backing_height: height,
        });
    }

    let scale = u64::from(request.scale_percent.max(100));
    Ok(LumenDisplayGeometry {
        stream_width: width,
        stream_height: height,
        logical_width: even_dimension(((u64::from(width) * 100) / scale) as u32),
        logical_height: even_dimension(((u64::from(height) * 100) / scale) as u32),
        backing_width: width,
        backing_height: height,
    })
}

pub fn resolve_virtual_display_plan(
    request: LumenVirtualDisplayRequest,
) -> Result<LumenVirtualDisplayPlan, LumenEngineStatus> {
    if request.scale_percent == 0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }

    let mut reason_flags = 0;
    if request.session_requested {
        reason_flags |= VIRTUAL_DISPLAY_REASON_SESSION_REQUESTED;
    }
    if request.app_requested {
        reason_flags |= VIRTUAL_DISPLAY_REASON_APP_REQUESTED;
    }
    if request.hdr_display_required {
        reason_flags |= VIRTUAL_DISPLAY_REASON_HDR_DISPLAY_REQUIRED;
    }
    if request.hidpi_requested {
        reason_flags |= VIRTUAL_DISPLAY_REASON_HIDPI_REQUESTED;
    }
    if request.dimensions_are_logical {
        reason_flags |= VIRTUAL_DISPLAY_REASON_LOGICAL_DIMENSIONS;
    }
    if request.scale_percent != 100 {
        reason_flags |= VIRTUAL_DISPLAY_REASON_SCALED_DESKTOP;
    }

    Ok(LumenVirtualDisplayPlan {
        required: reason_flags != 0,
        reason_flags,
    })
}

pub fn resolve_display_color(request: LumenDisplayColorRequest) -> LumenDisplayColorProfile {
    let transfer = match request.client_transfer {
        2 => LumenDisplayTransfer::Pq,
        3 => LumenDisplayTransfer::Hlg,
        _ => LumenDisplayTransfer::Sdr,
    };
    let hdr_capable = request.hdr_enabled || transfer != LumenDisplayTransfer::Sdr;
    let gamut = match request.client_gamut {
        1 => LumenDisplayGamut::Srgb,
        2 => LumenDisplayGamut::DisplayP3,
        3 => LumenDisplayGamut::Rec2020,
        _ if hdr_capable => LumenDisplayGamut::DisplayP3,
        _ => LumenDisplayGamut::Srgb,
    };
    let (red_x, red_y, green_x, green_y, blue_x, blue_y) = match gamut {
        LumenDisplayGamut::Srgb => (0.6400, 0.3300, 0.3000, 0.6000, 0.1500, 0.0600),
        LumenDisplayGamut::DisplayP3 => (0.6800, 0.3200, 0.2650, 0.6900, 0.1500, 0.0600),
        LumenDisplayGamut::Rec2020 => (0.7080, 0.2920, 0.1700, 0.7970, 0.1310, 0.0460),
    };
    LumenDisplayColorProfile {
        gamut,
        transfer,
        red_x,
        red_y,
        green_x,
        green_y,
        blue_x,
        blue_y,
        white_x: 0.3127,
        white_y: 0.3290,
        hdr_capable,
    }
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
        if self.manage_capture {
            self.enqueue(LumenWorkspaceCommandKind::StartCapture);
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
