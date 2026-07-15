use super::*;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostRuntimeState {
    Stopped = 0,
    Starting = 1,
    Running = 2,
    Stopping = 3,
    Resetting = 4,
    Failed = 5,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostRuntimeCommandKind {
    Start = 0,
    Stop = 1,
    Reset = 2,
    ForceStopStream = 3,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenHostRuntimeCommand {
    pub kind: LumenHostRuntimeCommandKind,
    pub generation: u64,
    pub sequence: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenHostResetStorageRequest {
    pub app_data_path: *const c_char,
    pub config_file_path: *const c_char,
    pub app_catalog_file_path: *const c_char,
    pub state_file_path: *const c_char,
    pub credential_file_path: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenHostResetStorageResult {
    pub attempted_path_count: u32,
    pub removed_path_count: u32,
    pub failed_path_count: u32,
}

pub(crate) struct HostRuntimeEngine {
    state: LumenHostRuntimeState,
    generation: u64,
    next_sequence: u32,
    queued: VecDeque<LumenHostRuntimeCommand>,
    awaiting: Option<LumenHostRuntimeCommand>,
    last_failure: LumenEngineStatus,
    last_exit_code: i32,
    exit_observed: bool,
}

impl Default for HostRuntimeEngine {
    fn default() -> Self {
        Self {
            state: LumenHostRuntimeState::Stopped,
            generation: 0,
            next_sequence: 0,
            queued: VecDeque::new(),
            awaiting: None,
            last_failure: LumenEngineStatus::Ok,
            last_exit_code: 0,
            exit_observed: false,
        }
    }
}

impl HostRuntimeEngine {
    pub fn request_start(&mut self) -> LumenEngineStatus {
        match self.state {
            LumenHostRuntimeState::Running => return LumenEngineStatus::Ok,
            LumenHostRuntimeState::Stopped | LumenHostRuntimeState::Failed => {}
            _ => return LumenEngineStatus::InvalidState,
        }
        if self.awaiting.is_some() || !self.queued.is_empty() {
            return LumenEngineStatus::InvalidState;
        }

        self.begin_transition(LumenHostRuntimeState::Starting);
        self.last_failure = LumenEngineStatus::Ok;
        self.last_exit_code = 0;
        self.exit_observed = false;
        self.enqueue(LumenHostRuntimeCommandKind::Start);
        LumenEngineStatus::Ok
    }

    pub fn request_stop(&mut self) -> LumenEngineStatus {
        match self.state {
            LumenHostRuntimeState::Stopped => return LumenEngineStatus::Ok,
            LumenHostRuntimeState::Running | LumenHostRuntimeState::Failed => {}
            _ => return LumenEngineStatus::InvalidState,
        }
        if self.awaiting.is_some() || !self.queued.is_empty() {
            return LumenEngineStatus::InvalidState;
        }
        if self.state == LumenHostRuntimeState::Failed && self.exit_observed {
            self.state = LumenHostRuntimeState::Stopped;
            self.exit_observed = false;
            return LumenEngineStatus::Ok;
        }

        self.begin_transition(LumenHostRuntimeState::Stopping);
        self.enqueue(LumenHostRuntimeCommandKind::Stop);
        LumenEngineStatus::Ok
    }

    pub fn request_reset(&mut self) -> LumenEngineStatus {
        if !matches!(
            self.state,
            LumenHostRuntimeState::Stopped | LumenHostRuntimeState::Failed
        ) || self.awaiting.is_some()
            || !self.queued.is_empty()
        {
            return LumenEngineStatus::InvalidState;
        }

        self.begin_transition(LumenHostRuntimeState::Resetting);
        self.enqueue(LumenHostRuntimeCommandKind::Reset);
        LumenEngineStatus::Ok
    }

    pub fn request_force_stop_stream(&mut self) -> LumenEngineStatus {
        if self.state != LumenHostRuntimeState::Running
            || self.awaiting.is_some()
            || !self.queued.is_empty()
        {
            return LumenEngineStatus::InvalidState;
        }
        self.enqueue(LumenHostRuntimeCommandKind::ForceStopStream);
        LumenEngineStatus::Ok
    }

    pub fn next_command(&mut self) -> Result<LumenHostRuntimeCommand, LumenEngineStatus> {
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
        command: LumenHostRuntimeCommand,
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
            self.state = LumenHostRuntimeState::Failed;
            self.queued.clear();
            return LumenEngineStatus::CommandFailed;
        }

        match command.kind {
            LumenHostRuntimeCommandKind::Start => self.finish_start(),
            LumenHostRuntimeCommandKind::Stop | LumenHostRuntimeCommandKind::Reset => {
                self.state = LumenHostRuntimeState::Stopped;
                self.exit_observed = false;
            }
            LumenHostRuntimeCommandKind::ForceStopStream => {
                self.apply_observed_exit_if_needed();
            }
        }
        LumenEngineStatus::Ok
    }

    pub fn report_exit(&mut self, exit_code: i32) -> LumenEngineStatus {
        self.last_exit_code = exit_code;
        self.exit_observed = true;
        if self.awaiting.is_none() {
            self.apply_observed_exit_if_needed();
        }
        LumenEngineStatus::Ok
    }

    pub(crate) fn state(&self) -> LumenHostRuntimeState {
        self.state
    }

    pub(crate) fn last_exit_code(&self) -> i32 {
        self.last_exit_code
    }

    pub(crate) fn last_failure(&self) -> LumenEngineStatus {
        self.last_failure
    }

    fn begin_transition(&mut self, state: LumenHostRuntimeState) {
        self.generation = self.generation.wrapping_add(1).max(1);
        self.next_sequence = 0;
        self.state = state;
    }

    fn enqueue(&mut self, kind: LumenHostRuntimeCommandKind) {
        self.queued.push_back(LumenHostRuntimeCommand {
            kind,
            generation: self.generation,
            sequence: self.next_sequence,
        });
        self.next_sequence = self.next_sequence.wrapping_add(1);
    }

    fn finish_start(&mut self) {
        if self.exit_observed {
            self.apply_observed_exit_if_needed();
        } else {
            self.state = LumenHostRuntimeState::Running;
        }
    }

    fn apply_observed_exit_if_needed(&mut self) {
        if !self.exit_observed {
            return;
        }
        self.state = if self.last_exit_code == 0 {
            LumenHostRuntimeState::Stopped
        } else {
            self.last_failure = LumenEngineStatus::CommandFailed;
            LumenHostRuntimeState::Failed
        };
    }
}

#[derive(Debug)]
pub(crate) struct HostResetStoragePaths {
    pub(crate) app_data: PathBuf,
    pub(crate) explicit_paths: Vec<PathBuf>,
}

fn collect_reset_paths(paths: &HostResetStoragePaths) -> Result<BTreeSet<PathBuf>, std::io::Error> {
    let mut reset_paths = BTreeSet::new();
    reset_paths.extend(
        paths
            .explicit_paths
            .iter()
            .filter(|path| !path.as_os_str().is_empty())
            .cloned(),
    );
    reset_paths.insert(paths.app_data.join("shadow_state.json"));
    reset_paths.insert(paths.app_data.join("credentials"));
    reset_paths.insert(paths.app_data.join("covers"));
    reset_paths.insert(paths.app_data.join("owner-account.json"));
    reset_paths.insert(paths.app_data.join("devices.json"));
    reset_paths.insert(paths.app_data.join("settings.json"));

    match fs::read_dir(&paths.app_data) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry?;
                let filename = entry.file_name();
                let filename = filename.to_string_lossy();
                if filename.starts_with("lumen_state.json.")
                    || filename.starts_with("shadow_state.json.")
                    || filename.starts_with(".lumen-settings-")
                {
                    reset_paths.insert(entry.path());
                }
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    Ok(reset_paths)
}

fn remove_reset_path(path: &Path) -> Result<bool, std::io::Error> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(true)
}

pub(crate) fn reset_host_storage(paths: &HostResetStoragePaths) -> LumenHostResetStorageResult {
    let mut result = LumenHostResetStorageResult::default();
    let reset_paths = match collect_reset_paths(paths) {
        Ok(paths) => paths,
        Err(_) => {
            result.failed_path_count = 1;
            return result;
        }
    };
    result.attempted_path_count = reset_paths.len().try_into().unwrap_or(u32::MAX);
    for path in reset_paths {
        match remove_reset_path(&path) {
            Ok(true) => result.removed_path_count = result.removed_path_count.saturating_add(1),
            Ok(false) => {}
            Err(_) => result.failed_path_count = result.failed_path_count.saturating_add(1),
        }
    }
    result
}

pub(crate) unsafe fn path_from_c_string(
    value: *const c_char,
) -> Result<Option<PathBuf>, LumenEngineStatus> {
    if value.is_null() {
        return Ok(None);
    }
    let value = unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| LumenEngineStatus::InvalidArgument)?;
    if value.is_empty() {
        Ok(None)
    } else {
        Ok(Some(PathBuf::from(value)))
    }
}
