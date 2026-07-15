use std::ffi::c_void;
use std::path::PathBuf;
use std::process::Child;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::{
    reset_host_storage, HostResetStoragePaths, HostRuntimeEngine, LumenEngineStatus,
    LumenHostResetStorageResult, LumenHostRuntimeCommand, LumenHostRuntimeCommandKind,
    LumenHostRuntimeState,
};

use super::process::{
    append_log, exit_code_for_signal, signal_process, spawn_worker, WorkerSignal,
};

pub(super) type RuntimeStatusCallback = unsafe extern "C" fn(bool, i32, u32, f64, *mut c_void);

#[derive(Clone, Copy)]
pub(super) struct StatusCallback {
    function: RuntimeStatusCallback,
    context: usize,
}

impl StatusCallback {
    pub(super) fn new(function: RuntimeStatusCallback, context: *mut c_void) -> Self {
        Self {
            function,
            context: context as usize,
        }
    }

    fn notify(self, exit_code: i32, restart_attempt: u32, restart_delay: Duration) {
        unsafe {
            (self.function)(
                true,
                exit_code,
                restart_attempt,
                restart_delay.as_secs_f64(),
                self.context as *mut c_void,
            );
        }
    }
}

struct SupervisorState {
    engine: HostRuntimeEngine,
    worker_pid: Option<u32>,
    stop_requested: bool,
    callback: Option<StatusCallback>,
    worker_path: PathBuf,
    arguments: Vec<String>,
    log_path: PathBuf,
    last_error: String,
}

impl Default for SupervisorState {
    fn default() -> Self {
        Self {
            engine: HostRuntimeEngine::default(),
            worker_pid: None,
            stop_requested: false,
            callback: None,
            worker_path: PathBuf::new(),
            arguments: Vec::new(),
            log_path: PathBuf::new(),
            last_error: String::new(),
        }
    }
}

struct SharedSupervisor {
    state: Mutex<SupervisorState>,
    wake: Condvar,
}

impl Default for SharedSupervisor {
    fn default() -> Self {
        Self {
            state: Mutex::new(SupervisorState::default()),
            wake: Condvar::new(),
        }
    }
}

#[repr(C)]
pub(crate) struct LumenHostRuntimeSupervisor {
    shared: Arc<SharedSupervisor>,
    watcher: Mutex<Option<JoinHandle<()>>>,
}

impl Default for LumenHostRuntimeSupervisor {
    fn default() -> Self {
        Self {
            shared: Arc::new(SharedSupervisor::default()),
            watcher: Mutex::new(None),
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn request_command(
    engine: &mut HostRuntimeEngine,
    request: impl FnOnce(&mut HostRuntimeEngine) -> LumenEngineStatus,
    expected: LumenHostRuntimeCommandKind,
) -> Result<LumenHostRuntimeCommand, LumenEngineStatus> {
    let status = request(engine);
    if status != LumenEngineStatus::Ok {
        return Err(status);
    }
    let command = engine.next_command()?;
    if command.kind != expected {
        return Err(LumenEngineStatus::CommandMismatch);
    }
    Ok(command)
}

fn restart_delay(attempt: u32) -> Duration {
    let exponent = attempt.saturating_sub(1).min(4);
    Duration::from_secs((1_u64 << exponent).min(30))
}

fn wait_for_restart(shared: &SharedSupervisor, delay: Duration) -> bool {
    let state = lock(&shared.state);
    if state.stop_requested {
        return false;
    }
    let (state, _) = shared
        .wake
        .wait_timeout_while(state, delay, |state| !state.stop_requested)
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    !state.stop_requested
}

fn watch_worker(shared: Arc<SharedSupervisor>, mut child: Child) {
    let mut restart_attempt = 0_u32;
    let mut started_at = Instant::now();

    loop {
        let exit_code = match child.wait() {
            Ok(status) => worker_exit_code(&status),
            Err(error) => {
                let mut state = lock(&shared.state);
                state.last_error = format!("Waiting for LumenHostWorker failed: {error}");
                -1
            }
        };

        let (callback, log_path, lifetime, should_stop) = {
            let mut state = lock(&shared.state);
            state.worker_pid = None;
            let _ = state.engine.report_exit(exit_code);
            (
                state.callback,
                state.log_path.clone(),
                started_at.elapsed(),
                state.stop_requested,
            )
        };
        if should_stop {
            shared.wake.notify_all();
            return;
        }

        restart_attempt = if lifetime >= Duration::from_secs(60) {
            1
        } else {
            restart_attempt.saturating_add(1).max(1)
        };

        loop {
            let delay = restart_delay(restart_attempt);
            append_log(
                &log_path,
                &format!(
                    "worker exited code={exit_code} restart-attempt={restart_attempt} delay-seconds={}",
                    delay.as_secs()
                ),
            );
            if let Some(callback) = callback {
                callback.notify(exit_code, restart_attempt, delay);
            }
            if !wait_for_restart(&shared, delay) {
                return;
            }

            let (command, worker_path, arguments, current_log_path) = {
                let mut state = lock(&shared.state);
                let command = match request_command(
                    &mut state.engine,
                    HostRuntimeEngine::request_start,
                    LumenHostRuntimeCommandKind::Start,
                ) {
                    Ok(command) => command,
                    Err(status) => {
                        state.last_error = format!(
                            "Rust runtime restart request failed with status {}.",
                            status as u32
                        );
                        restart_attempt = restart_attempt.saturating_add(1);
                        continue;
                    }
                };
                (
                    command,
                    state.worker_path.clone(),
                    state.arguments.clone(),
                    state.log_path.clone(),
                )
            };

            match spawn_worker(&worker_path, &arguments, &current_log_path) {
                Ok(replacement) => {
                    let replacement_pid = replacement.id();
                    {
                        let mut state = lock(&shared.state);
                        let completion = state.engine.complete_command(command, true);
                        if completion != LumenEngineStatus::Ok {
                            state.last_error = format!(
                                "Rust runtime restart completion failed with status {}.",
                                completion as u32
                            );
                            let _ = signal_process(replacement_pid, WorkerSignal::Terminate);
                            restart_attempt = restart_attempt.saturating_add(1);
                            continue;
                        }
                        state.worker_pid = Some(replacement_pid);
                        state.last_error.clear();
                    }
                    append_log(
                        &current_log_path,
                        &format!("worker restarted pid={replacement_pid}"),
                    );
                    child = replacement;
                    started_at = Instant::now();
                    break;
                }
                Err(error) => {
                    let mut state = lock(&shared.state);
                    let _ = state.engine.complete_command(command, false);
                    state.last_error = error.clone();
                    append_log(&current_log_path, &error);
                    restart_attempt = restart_attempt.saturating_add(1);
                }
            }
        }
    }
}

fn worker_exit_code(status: &std::process::ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        status.signal().map_or(-1, |signal| 128 + signal)
    }
    #[cfg(not(unix))]
    {
        -1
    }
}

impl LumenHostRuntimeSupervisor {
    fn join_finished_watcher(&self) {
        let handle = {
            let mut watcher = lock(&self.watcher);
            if watcher.as_ref().is_some_and(JoinHandle::is_finished) {
                watcher.take()
            } else {
                None
            }
        };
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }

    pub(super) fn start(
        &self,
        worker_path: PathBuf,
        arguments: Vec<String>,
        log_path: PathBuf,
        callback: Option<StatusCallback>,
    ) -> LumenEngineStatus {
        self.join_finished_watcher();
        if lock(&self.watcher).is_some() {
            return if self.state() == LumenHostRuntimeState::Running {
                LumenEngineStatus::Ok
            } else {
                LumenEngineStatus::InvalidState
            };
        }

        let command = {
            let mut state = lock(&self.shared.state);
            state.stop_requested = false;
            state.callback = callback;
            state.worker_path = worker_path.clone();
            state.arguments = arguments.clone();
            state.log_path = log_path.clone();
            state.last_error.clear();
            match request_command(
                &mut state.engine,
                HostRuntimeEngine::request_start,
                LumenHostRuntimeCommandKind::Start,
            ) {
                Ok(command) => command,
                Err(status) => {
                    state.last_error = format!(
                        "Rust runtime start request failed with status {}.",
                        status as u32
                    );
                    return status;
                }
            }
        };

        let child = match spawn_worker(&worker_path, &arguments, &log_path) {
            Ok(child) => child,
            Err(error) => {
                let mut state = lock(&self.shared.state);
                let _ = state.engine.complete_command(command, false);
                state.last_error = error.clone();
                append_log(&log_path, &error);
                return LumenEngineStatus::CommandFailed;
            }
        };
        let worker_pid = child.id();
        {
            let mut state = lock(&self.shared.state);
            let completion = state.engine.complete_command(command, true);
            if completion != LumenEngineStatus::Ok {
                state.last_error = format!(
                    "Rust runtime start completion failed with status {}.",
                    completion as u32
                );
                let _ = signal_process(worker_pid, WorkerSignal::Terminate);
                return completion;
            }
            state.worker_pid = Some(worker_pid);
        }
        append_log(&log_path, &format!("worker started pid={worker_pid}"));

        let shared = Arc::clone(&self.shared);
        let watcher = thread::Builder::new()
            .name("lumen-host-supervisor".to_owned())
            .spawn(move || watch_worker(shared, child));
        match watcher {
            Ok(handle) => {
                *lock(&self.watcher) = Some(handle);
                LumenEngineStatus::Ok
            }
            Err(error) => {
                let _ = signal_process(worker_pid, WorkerSignal::Terminate);
                let mut state = lock(&self.shared.state);
                state.worker_pid = None;
                let _ = state
                    .engine
                    .report_exit(exit_code_for_signal(WorkerSignal::Terminate));
                state.last_error = format!("Could not start the Rust runtime supervisor: {error}");
                LumenEngineStatus::CommandFailed
            }
        }
    }

    pub(super) fn stop(&self) -> LumenEngineStatus {
        let (worker_pid, stop_command, request_status) = {
            let mut state = lock(&self.shared.state);
            state.stop_requested = true;
            self.shared.wake.notify_all();
            let worker_pid = state.worker_pid;
            let request_status = state.engine.request_stop();
            let stop_command = if request_status == LumenEngineStatus::Ok {
                state
                    .engine
                    .next_command()
                    .ok()
                    .filter(|command| command.kind == LumenHostRuntimeCommandKind::Stop)
            } else {
                None
            };
            (worker_pid, stop_command, request_status)
        };

        if let Some(worker_pid) = worker_pid {
            if let Err(error) = signal_process(worker_pid, WorkerSignal::Terminate) {
                lock(&self.shared.state).last_error = error;
            }
        }
        if let Some(handle) = lock(&self.watcher).take() {
            let _ = handle.join();
        }

        let mut state = lock(&self.shared.state);
        state.worker_pid = None;
        state.stop_requested = false;
        if let Some(command) = stop_command {
            return state.engine.complete_command(command, true);
        }
        request_status
    }

    pub(super) fn state(&self) -> LumenHostRuntimeState {
        lock(&self.shared.state).engine.state()
    }

    pub(super) fn last_exit_code(&self) -> i32 {
        lock(&self.shared.state).engine.last_exit_code()
    }

    pub(super) fn last_failure(&self) -> LumenEngineStatus {
        lock(&self.shared.state).engine.last_failure()
    }

    pub(super) fn last_error(&self) -> String {
        lock(&self.shared.state).last_error.clone()
    }

    pub(super) fn force_stop_stream(&self) -> LumenEngineStatus {
        let (worker_pid, command) = {
            let mut state = lock(&self.shared.state);
            let command = match request_command(
                &mut state.engine,
                HostRuntimeEngine::request_force_stop_stream,
                LumenHostRuntimeCommandKind::ForceStopStream,
            ) {
                Ok(command) => command,
                Err(status) => return status,
            };
            (state.worker_pid, command)
        };
        let succeeded = worker_pid
            .map(|pid| signal_process(pid, WorkerSignal::ForceStopStream).is_ok())
            .unwrap_or(false);
        lock(&self.shared.state)
            .engine
            .complete_command(command, succeeded)
    }

    pub(super) fn reload_applications(&self) -> LumenEngineStatus {
        let state = lock(&self.shared.state);
        if state.engine.state() != LumenHostRuntimeState::Running {
            return LumenEngineStatus::InvalidState;
        }
        let Some(worker_pid) = state.worker_pid else {
            return LumenEngineStatus::InvalidState;
        };
        drop(state);
        match signal_process(worker_pid, WorkerSignal::ReloadApplications) {
            Ok(()) => LumenEngineStatus::Ok,
            Err(error) => {
                lock(&self.shared.state).last_error = error;
                LumenEngineStatus::CommandFailed
            }
        }
    }

    pub(super) fn reset_storage(
        &self,
        paths: HostResetStoragePaths,
        result: &mut LumenHostResetStorageResult,
    ) -> LumenEngineStatus {
        if lock(&self.watcher).is_some() {
            return LumenEngineStatus::InvalidState;
        }
        let mut state = lock(&self.shared.state);
        let command = match request_command(
            &mut state.engine,
            HostRuntimeEngine::request_reset,
            LumenHostRuntimeCommandKind::Reset,
        ) {
            Ok(command) => command,
            Err(status) => return status,
        };
        *result = reset_host_storage(&paths);
        let succeeded = result.failed_path_count == 0;
        let completion = state.engine.complete_command(command, succeeded);
        if succeeded {
            completion
        } else {
            state.last_error = format!(
                "Host storage reset failed for {} path(s).",
                result.failed_path_count
            );
            LumenEngineStatus::CommandFailed
        }
    }
}

impl Drop for LumenHostRuntimeSupervisor {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn supervisor_starts_and_stops_a_real_worker_process() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let supervisor = LumenHostRuntimeSupervisor::default();
        let status = supervisor.start(
            PathBuf::from("/bin/sh"),
            vec![
                "-c".to_owned(),
                "trap 'exit 0' TERM; while :; do sleep 0.05; done".to_owned(),
            ],
            directory.path().join("worker.log"),
            None,
        );
        assert_eq!(status, LumenEngineStatus::Ok);
        assert_eq!(supervisor.state(), LumenHostRuntimeState::Running);
        assert_eq!(supervisor.stop(), LumenEngineStatus::Ok);
        assert_eq!(supervisor.state(), LumenHostRuntimeState::Stopped);
    }

    #[test]
    fn supervisor_reports_spawn_failures_without_claiming_to_run() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let supervisor = LumenHostRuntimeSupervisor::default();
        let status = supervisor.start(
            directory.path().join("missing-worker"),
            Vec::new(),
            directory.path().join("worker.log"),
            None,
        );
        assert_eq!(status, LumenEngineStatus::CommandFailed);
        assert_eq!(supervisor.state(), LumenHostRuntimeState::Failed);
        assert!(supervisor.last_error().contains("spawn failed"));
    }
}
