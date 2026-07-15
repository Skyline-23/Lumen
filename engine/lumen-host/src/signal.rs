#![cfg(unix)]

use std::io;
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::{HostCommand, HostCommandSource};

pub struct UnixSignalCommandSource {
    signals: libc::sigset_t,
    watchdog_stop: Arc<AtomicBool>,
    watchdog: Option<JoinHandle<()>>,
}

impl UnixSignalCommandSource {
    pub fn install() -> Result<Self, String> {
        let mut signals = MaybeUninit::<libc::sigset_t>::uninit();
        if unsafe { libc::sigemptyset(signals.as_mut_ptr()) } != 0 {
            return Err(last_signal_error(
                "could not initialize the worker signal set",
            ));
        }
        let mut signals = unsafe { signals.assume_init() };
        for signal in [libc::SIGTERM, libc::SIGUSR1, libc::SIGUSR2] {
            if unsafe { libc::sigaddset(&mut signals, signal) } != 0 {
                return Err(last_signal_error(
                    "could not configure the worker signal set",
                ));
            }
        }
        let status =
            unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, &signals, std::ptr::null_mut()) };
        if status != 0 {
            return Err(format!(
                "could not block worker command signals: {}",
                io::Error::from_raw_os_error(status)
            ));
        }
        let supervisor_pid = unsafe { libc::getppid() };
        let watchdog_stop = Arc::new(AtomicBool::new(false));
        let watchdog = spawn_parent_watchdog(supervisor_pid, Arc::clone(&watchdog_stop))?;
        Ok(Self {
            signals,
            watchdog_stop,
            watchdog: Some(watchdog),
        })
    }
}

impl HostCommandSource for UnixSignalCommandSource {
    fn next_command(&mut self) -> Result<HostCommand, String> {
        loop {
            let mut signal = 0;
            let status = unsafe { libc::sigwait(&self.signals, &mut signal) };
            if status != 0 {
                return Err(format!(
                    "worker signal wait failed: {}",
                    io::Error::from_raw_os_error(status)
                ));
            }
            if let Some(command) = command_for_signal(signal) {
                return Ok(command);
            }
        }
    }
}

impl Drop for UnixSignalCommandSource {
    fn drop(&mut self) {
        self.watchdog_stop.store(true, Ordering::Release);
        if let Some(watchdog) = self.watchdog.take() {
            let _ = watchdog.join();
        }
    }
}

fn spawn_parent_watchdog(
    supervisor_pid: libc::pid_t,
    stop: Arc<AtomicBool>,
) -> Result<JoinHandle<()>, String> {
    thread::Builder::new()
        .name("lumen-parent-watchdog".into())
        .spawn(move || {
            while !stop.load(Ordering::Acquire) {
                if supervisor_exited(supervisor_pid) {
                    unsafe { libc::kill(libc::getpid(), libc::SIGTERM) };
                    return;
                }
                thread::sleep(Duration::from_millis(250));
            }
        })
        .map_err(|error| format!("could not start the worker parent watchdog: {error}"))
}

fn supervisor_exited(supervisor_pid: libc::pid_t) -> bool {
    if unsafe { libc::getppid() } != supervisor_pid {
        return true;
    }
    if unsafe { libc::kill(supervisor_pid, 0) } == 0 {
        return false;
    }
    io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

fn command_for_signal(signal: libc::c_int) -> Option<HostCommand> {
    match signal {
        libc::SIGTERM => Some(HostCommand::Shutdown),
        libc::SIGUSR1 => Some(HostCommand::ForceStopStream),
        libc::SIGUSR2 => Some(HostCommand::ReloadApplications),
        _ => None,
    }
}

fn last_signal_error(context: &str) -> String {
    format!("{context}: {}", io::Error::last_os_error())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_the_supervisor_signal_contract_to_typed_commands() {
        assert_eq!(
            command_for_signal(libc::SIGTERM),
            Some(HostCommand::Shutdown)
        );
        assert_eq!(
            command_for_signal(libc::SIGUSR1),
            Some(HostCommand::ForceStopStream)
        );
        assert_eq!(
            command_for_signal(libc::SIGUSR2),
            Some(HostCommand::ReloadApplications)
        );
        assert_eq!(command_for_signal(libc::SIGINT), None);
    }

    #[test]
    fn current_parent_is_not_reported_as_exited() {
        assert!(!supervisor_exited(unsafe { libc::getppid() }));
    }
}
