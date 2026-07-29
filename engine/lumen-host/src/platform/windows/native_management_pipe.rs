use std::ffi::c_void;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_PIPE_CONNECTED, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FlushFileBuffers, ReadFile, WriteFile, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    OPEN_EXISTING, PIPE_ACCESS_DUPLEX,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, GetNamedPipeClientProcessId,
    PIPE_READMODE_MESSAGE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE, PIPE_WAIT,
};
use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows_sys::Win32::System::Threading::GetCurrentProcessId;

use crate::native_command::{
    lumen_host_send_command, LumenHostCommandSendStatus, LUMEN_HOST_COMMAND_FORCE_STOP_STREAM,
    LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS, LUMEN_HOST_COMMAND_RESTART,
    LUMEN_HOST_COMMAND_SHUTDOWN,
};
use crate::windows_app::WindowsAppModel;
use crate::windows_management::{handle_windows_management_request, WindowsManagementCommands};
use crate::HostArguments;

const PIPE_NAME: &[u16] = &[
    0x005c, 0x005c, 0x002e, 0x005c, 0x0070, 0x0069, 0x0070, 0x0065, 0x005c, 0x004c, 0x0075, 0x006d,
    0x0065, 0x006e, 0x002e, 0x004d, 0x0061, 0x006e, 0x0061, 0x0067, 0x0065, 0x006d, 0x0065, 0x006e,
    0x0074, 0x002e, 0x0076, 0x0031, 0,
];
const PIPE_BUFFER_SIZE: u32 = 64 * 1024;
const PIPE_DACL: &str = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)";

pub(crate) struct NativeWindowsManagement {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

impl NativeWindowsManagement {
    pub(crate) fn start(arguments: &HostArguments) -> Result<Self, String> {
        let model = WindowsAppModel::from_arguments(arguments)?;
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("lumen-windows-management".to_owned())
            .spawn(move || run_server(model, worker_stop, ready_sender))
            .map_err(|error| format!("Windows management thread failed to start: {error}"))?;
        ready_receiver
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| "Windows management pipe did not become ready".to_owned())??;
        Ok(Self {
            stop,
            thread: Some(thread),
        })
    }
}

impl Drop for NativeWindowsManagement {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        wake_server();
        if let Some(thread) = self.thread.take() {
            if thread.join().is_err() {
                eprintln!("Lumen Windows management thread did not stop cleanly");
            }
        }
    }
}

struct NativeCommands;

impl WindowsManagementCommands for NativeCommands {
    fn reload_applications(&self) -> Result<(), String> {
        send_command(LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS)
    }

    fn force_stop_stream(&self) -> Result<(), String> {
        send_command(LUMEN_HOST_COMMAND_FORCE_STOP_STREAM)
    }

    fn restart_host(&self) -> Result<(), String> {
        send_command(LUMEN_HOST_COMMAND_RESTART)
    }

    fn shutdown_host(&self) -> Result<(), String> {
        send_command(LUMEN_HOST_COMMAND_SHUTDOWN)
    }
}

fn send_command(command: u32) -> Result<(), String> {
    match lumen_host_send_command(command) {
        LumenHostCommandSendStatus::Ok => Ok(()),
        status => Err(format!("host command is unavailable: {status:?}")),
    }
}

fn run_server(
    mut model: WindowsAppModel,
    stop: Arc<AtomicBool>,
    ready: mpsc::SyncSender<Result<(), String>>,
) {
    let mut ready = Some(ready);
    loop {
        let pipe = match create_pipe() {
            Ok(pipe) => pipe,
            Err(error) => {
                if let Some(ready) = ready.take() {
                    let _ = ready.send(Err(error));
                }
                return;
            }
        };
        if let Some(ready) = ready.take() {
            let _ = ready.send(Ok(()));
        }
        let connected = unsafe { ConnectNamedPipe(pipe.get(), null_mut()) } != 0
            || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        if !connected {
            continue;
        }
        if stop.load(Ordering::Acquire) {
            break;
        }
        if !client_is_in_agent_session(pipe.get()).unwrap_or(false) {
            unsafe {
                DisconnectNamedPipe(pipe.get());
            }
            continue;
        }
        if let Ok(request) = read_request(pipe.get()) {
            let response = handle_windows_management_request(&mut model, &NativeCommands, &request);
            let _ = write_response(pipe.get(), &response);
        }
        unsafe {
            FlushFileBuffers(pipe.get());
            DisconnectNamedPipe(pipe.get());
        }
    }
}

fn client_is_in_agent_session(pipe: HANDLE) -> Result<bool, String> {
    let mut client_process_id = 0_u32;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut client_process_id) } == 0 {
        return Err(last_error("resolve Windows management client process"));
    }
    let mut client_session_id = 0_u32;
    if unsafe { ProcessIdToSessionId(client_process_id, &mut client_session_id) } == 0 {
        return Err(last_error("resolve Windows management client session"));
    }
    let mut agent_session_id = 0_u32;
    if unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut agent_session_id) } == 0 {
        return Err(last_error("resolve Lumen session agent session"));
    }
    Ok(client_session_id == agent_session_id)
}

fn create_pipe() -> Result<OwnedHandle, String> {
    let mut descriptor = null_mut();
    let dacl = wide(PIPE_DACL);
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            dacl.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            null_mut(),
        )
    } == 0
    {
        return Err(last_error(
            "create Windows management pipe security descriptor",
        ));
    }
    let descriptor = OwnedLocal::new(descriptor);
    let mut security = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.get(),
        bInheritHandle: 0,
    };
    let handle = unsafe {
        CreateNamedPipeW(
            PIPE_NAME.as_ptr(),
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            PIPE_BUFFER_SIZE,
            PIPE_BUFFER_SIZE,
            0,
            &mut security,
        )
    };
    OwnedHandle::new(handle, "create Windows management pipe")
}

fn read_request(pipe: HANDLE) -> Result<Vec<u8>, String> {
    let mut buffer = vec![0_u8; PIPE_BUFFER_SIZE as usize];
    let mut read = 0_u32;
    if unsafe {
        ReadFile(
            pipe,
            buffer.as_mut_ptr(),
            PIPE_BUFFER_SIZE,
            &mut read,
            null_mut(),
        )
    } == 0
    {
        return Err(last_error("read Windows management request"));
    }
    buffer.truncate(read as usize);
    Ok(buffer)
}

fn write_response(pipe: HANDLE, response: &[u8]) -> Result<(), String> {
    let length = u32::try_from(response.len())
        .map_err(|_| "Windows management response is too large".to_owned())?;
    let mut written = 0_u32;
    if unsafe { WriteFile(pipe, response.as_ptr(), length, &mut written, null_mut()) } == 0
        || written != length
    {
        return Err(last_error("write Windows management response"));
    }
    Ok(())
}

fn wake_server() {
    let pipe = unsafe {
        CreateFileW(
            PIPE_NAME.as_ptr(),
            FILE_GENERIC_READ | FILE_GENERIC_WRITE,
            0,
            null(),
            OPEN_EXISTING,
            0,
            null_mut(),
        )
    };
    if pipe != INVALID_HANDLE_VALUE {
        unsafe {
            CloseHandle(pipe);
        }
    }
}

fn last_error(action: &str) -> String {
    format!("{action} failed: {}", std::io::Error::last_os_error())
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain([0]).collect()
}

struct OwnedHandle(HANDLE);

impl OwnedHandle {
    fn new(handle: HANDLE, action: &str) -> Result<Self, String> {
        if handle == INVALID_HANDLE_VALUE || handle.is_null() {
            Err(last_error(action))
        } else {
            Ok(Self(handle))
        }
    }

    fn get(&self) -> HANDLE {
        self.0
    }
}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

struct OwnedLocal(*mut c_void);

impl OwnedLocal {
    fn new(value: *mut c_void) -> Self {
        Self(value)
    }

    fn get(&self) -> *mut c_void {
        self.0
    }
}

impl Drop for OwnedLocal {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}
