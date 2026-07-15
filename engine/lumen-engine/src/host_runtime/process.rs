use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy)]
pub(super) enum WorkerSignal {
    Terminate,
    ForceStopStream,
    ReloadApplications,
}

pub(super) fn append_log(path: &Path, message: &str) {
    if path.as_os_str().is_empty() {
        return;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) else {
        return;
    };
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let _ = writeln!(file, "{timestamp} {message}");
}

pub(super) fn spawn_worker(
    worker_path: &Path,
    arguments: &[String],
    log_path: &Path,
) -> Result<Child, String> {
    if worker_path.as_os_str().is_empty() {
        return Err("LumenHostWorker path is empty.".to_owned());
    }
    if let Some(parent) = log_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("Could not create the runtime log directory: {error}"))?;
    }
    let stdout = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
        .map_err(|error| format!("Could not open the runtime log: {error}"))?;
    let stderr = stdout
        .try_clone()
        .map_err(|error| format!("Could not duplicate the runtime log handle: {error}"))?;
    Command::new(worker_path)
        .args(arguments)
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .spawn()
        .map_err(|error| format!("LumenHostWorker spawn failed: {error}"))
}

#[cfg(unix)]
pub(super) fn signal_process(pid: u32, signal: WorkerSignal) -> Result<(), String> {
    let pid = i32::try_from(pid).map_err(|_| "Worker process identifier is invalid.".to_owned())?;
    let native_signal = match signal {
        WorkerSignal::Terminate => libc::SIGTERM,
        WorkerSignal::ForceStopStream => libc::SIGUSR1,
        WorkerSignal::ReloadApplications => libc::SIGUSR2,
    };
    let result = unsafe { libc::kill(pid, native_signal) };
    if result == 0 {
        Ok(())
    } else {
        Err(format!(
            "Could not signal LumenHostWorker: {}",
            std::io::Error::last_os_error()
        ))
    }
}

#[cfg(not(unix))]
pub(super) fn signal_process(_pid: u32, _signal: WorkerSignal) -> Result<(), String> {
    Err("Native worker signals are unavailable on this platform.".to_owned())
}

#[cfg(unix)]
pub(super) fn exit_code_for_signal(signal: WorkerSignal) -> i32 {
    let native_signal = match signal {
        WorkerSignal::Terminate => libc::SIGTERM,
        WorkerSignal::ForceStopStream => libc::SIGUSR1,
        WorkerSignal::ReloadApplications => libc::SIGUSR2,
    };
    128 + native_signal
}

#[cfg(not(unix))]
pub(super) fn exit_code_for_signal(_signal: WorkerSignal) -> i32 {
    -1
}
