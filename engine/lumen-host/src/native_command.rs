use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Mutex};

use crate::{HostCommand, HostCommandSource};

static COMMAND_SENDER: Mutex<Option<mpsc::Sender<HostCommand>>> = Mutex::new(None);
static RESTART_REQUESTED: AtomicBool = AtomicBool::new(false);

pub const LUMEN_HOST_COMMAND_SHUTDOWN: u32 = 0;
pub const LUMEN_HOST_COMMAND_FORCE_STOP_STREAM: u32 = 1;
pub const LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS: u32 = 2;
pub const LUMEN_HOST_COMMAND_RESTART: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostCommandSendStatus {
    Ok = 0,
    InvalidCommand = 1,
    Unavailable = 2,
    Panic = 3,
}

pub struct NativeCommandSource {
    receiver: mpsc::Receiver<HostCommand>,
}

impl NativeCommandSource {
    pub fn install() -> Result<Self, String> {
        let mut active = COMMAND_SENDER
            .lock()
            .map_err(|_| "native command source lock is unavailable".to_owned())?;
        if active.is_some() {
            return Err("native command source is already installed".to_owned());
        }
        let (sender, receiver) = mpsc::channel();
        *active = Some(sender);
        RESTART_REQUESTED.store(false, Ordering::Release);
        Ok(Self { receiver })
    }
}

impl HostCommandSource for NativeCommandSource {
    fn next_command(&mut self) -> Result<HostCommand, String> {
        self.receiver
            .recv()
            .map_err(|_| "native command channel closed".to_owned())
    }
}

impl Drop for NativeCommandSource {
    fn drop(&mut self) {
        if let Ok(mut active) = COMMAND_SENDER.lock() {
            *active = None;
        }
    }
}

#[no_mangle]
pub extern "C" fn lumen_host_send_command(command: u32) -> LumenHostCommandSendStatus {
    match catch_unwind(AssertUnwindSafe(|| send_command(command))) {
        Ok(status) => status,
        Err(_) => LumenHostCommandSendStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_host_take_restart_request() -> bool {
    RESTART_REQUESTED.swap(false, Ordering::AcqRel)
}

fn send_command(command: u32) -> LumenHostCommandSendStatus {
    let (command, restart) = match command {
        LUMEN_HOST_COMMAND_SHUTDOWN => (HostCommand::Shutdown, false),
        LUMEN_HOST_COMMAND_FORCE_STOP_STREAM => (HostCommand::ForceStopStream, false),
        LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS => (HostCommand::ReloadApplications, false),
        LUMEN_HOST_COMMAND_RESTART => (HostCommand::Restart, true),
        _ => return LumenHostCommandSendStatus::InvalidCommand,
    };
    let active = match COMMAND_SENDER.lock() {
        Ok(active) => active,
        Err(_) => return LumenHostCommandSendStatus::Unavailable,
    };
    match active.as_ref().map(|sender| sender.send(command)) {
        Some(Ok(())) => {
            if restart {
                RESTART_REQUESTED.store(true, Ordering::Release);
            }
            LumenHostCommandSendStatus::Ok
        }
        Some(Err(_)) | None => LumenHostCommandSendStatus::Unavailable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_shell_commands_are_typed_ordered_and_lifetime_bound() {
        assert_eq!(
            lumen_host_send_command(LUMEN_HOST_COMMAND_SHUTDOWN),
            LumenHostCommandSendStatus::Unavailable
        );
        let mut source = NativeCommandSource::install().unwrap();
        assert!(NativeCommandSource::install().is_err());
        for (wire, expected) in [
            (
                LUMEN_HOST_COMMAND_FORCE_STOP_STREAM,
                HostCommand::ForceStopStream,
            ),
            (
                LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS,
                HostCommand::ReloadApplications,
            ),
            (LUMEN_HOST_COMMAND_RESTART, HostCommand::Restart),
            (LUMEN_HOST_COMMAND_SHUTDOWN, HostCommand::Shutdown),
        ] {
            assert_eq!(
                lumen_host_send_command(wire),
                LumenHostCommandSendStatus::Ok
            );
            assert_eq!(source.next_command().unwrap(), expected);
        }
        assert_eq!(
            lumen_host_send_command(u32::MAX),
            LumenHostCommandSendStatus::InvalidCommand
        );
        drop(source);
        assert!(lumen_host_take_restart_request());
        assert_eq!(
            lumen_host_send_command(LUMEN_HOST_COMMAND_SHUTDOWN),
            LumenHostCommandSendStatus::Unavailable
        );
    }
}
