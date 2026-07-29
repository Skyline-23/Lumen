use std::ffi::c_void;
use std::os::windows::io::AsRawHandle;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_IO_PENDING, ERROR_PIPE_CONNECTED, HANDLE,
    INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, WriteFile, FILE_FLAG_OVERLAPPED, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    OPEN_EXISTING, PIPE_ACCESS_DUPLEX,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, GetNamedPipeClientProcessId,
    PIPE_READMODE_MESSAGE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE, PIPE_WAIT,
};
use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows_sys::Win32::System::Threading::{
    CreateEventW, GetCurrentProcessId, WaitForSingleObject,
};
use windows_sys::Win32::System::IO::{
    CancelIoEx, CancelSynchronousIo, GetOverlappedResult, OVERLAPPED,
};

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
const RESPONSE_ACK: u8 = 0x06;
const CLIENT_IO_TIMEOUT: Duration = Duration::from_secs(3);
const IO_WAIT_SLICE: Duration = Duration::from_millis(25);
const THREAD_STOP_TIMEOUT: Duration = Duration::from_secs(1);
const THREAD_STOP_POLL_INTERVAL: Duration = Duration::from_millis(25);

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
        if let Some(thread) = self.thread.take() {
            stop_server_thread(thread);
        }
    }
}

fn stop_server_thread(thread: thread::JoinHandle<()>) {
    let deadline = Instant::now() + THREAD_STOP_TIMEOUT;
    while !thread.is_finished() && Instant::now() < deadline {
        // Overlapped waits observe the stop flag directly. This remains a
        // bounded safety net for any unexpected synchronous Win32 stall.
        unsafe {
            CancelSynchronousIo(thread.as_raw_handle() as HANDLE);
        }
        wake_server();
        if !thread.is_finished() {
            thread::sleep(THREAD_STOP_POLL_INTERVAL);
        }
    }
    if thread.is_finished() {
        if thread.join().is_err() {
            eprintln!("Lumen Windows management thread did not stop cleanly");
        }
    } else {
        // Dropping JoinHandle detaches it. The shared stop flag remains set,
        // and Drop itself stays bounded even if a Windows driver fails to
        // honor synchronous I/O cancellation.
        eprintln!("Lumen Windows management thread cancellation timed out; detaching");
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
        if stop.load(Ordering::Acquire) {
            break;
        }
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
        match connect_client(pipe.get(), &stop) {
            Ok(()) => {}
            Err(PipeIoError::Stopped) => break,
            Err(error) => {
                eprintln!("Windows management client connection ended: {error}");
                continue;
            }
        }
        if !client_is_in_agent_session(pipe.get()).unwrap_or(false) {
            unsafe {
                DisconnectNamedPipe(pipe.get());
            }
            continue;
        }
        match read_request(pipe.get(), &stop) {
            Ok(request) => {
                let response =
                    handle_windows_management_request(&mut model, &NativeCommands, &request);
                if write_response(pipe.get(), &response, &stop).is_ok() {
                    if let Err(error) = read_response_ack(pipe.get(), &stop) {
                        eprintln!("Windows management response acknowledgement ended: {error}");
                    }
                }
            }
            Err(PipeIoError::Stopped) => break,
            Err(error) => {
                eprintln!("Windows management request ended: {error}");
            }
        }
        unsafe {
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
    let security = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.get(),
        bInheritHandle: 0,
    };
    let handle = unsafe {
        CreateNamedPipeW(
            PIPE_NAME.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            PIPE_BUFFER_SIZE,
            PIPE_BUFFER_SIZE,
            0,
            &security,
        )
    };
    OwnedHandle::new(handle, "create Windows management pipe")
}

fn connect_client(pipe: HANDLE, stop: &AtomicBool) -> Result<(), PipeIoError> {
    let event = create_event()?;
    let mut overlapped = new_overlapped(event.get());
    if unsafe { ConnectNamedPipe(pipe, &mut overlapped) } != 0 {
        return Ok(());
    }
    match unsafe { GetLastError() } {
        ERROR_PIPE_CONNECTED => Ok(()),
        ERROR_IO_PENDING => wait_for_overlapped(pipe, &mut overlapped, None, stop).map(|_| ()),
        _ => Err(PipeIoError::Failed(last_error(
            "connect Windows management client",
        ))),
    }
}

fn read_request(pipe: HANDLE, stop: &AtomicBool) -> Result<Vec<u8>, PipeIoError> {
    let mut buffer = vec![0_u8; PIPE_BUFFER_SIZE as usize];
    let event = create_event()?;
    let mut overlapped = new_overlapped(event.get());
    if unsafe {
        ReadFile(
            pipe,
            buffer.as_mut_ptr(),
            PIPE_BUFFER_SIZE,
            null_mut(),
            &mut overlapped,
        )
    } == 0
        && unsafe { GetLastError() } != ERROR_IO_PENDING
    {
        return Err(PipeIoError::Failed(last_error(
            "read Windows management request",
        )));
    }
    let read = wait_for_overlapped(
        pipe,
        &mut overlapped,
        Some(("read Windows management request", CLIENT_IO_TIMEOUT)),
        stop,
    )?;
    buffer.truncate(read as usize);
    Ok(buffer)
}

fn write_response(pipe: HANDLE, response: &[u8], stop: &AtomicBool) -> Result<(), PipeIoError> {
    let length = u32::try_from(response.len())
        .map_err(|_| PipeIoError::Failed("Windows management response is too large".to_owned()))?;
    let event = create_event()?;
    let mut overlapped = new_overlapped(event.get());
    if unsafe { WriteFile(pipe, response.as_ptr(), length, null_mut(), &mut overlapped) } == 0
        && unsafe { GetLastError() } != ERROR_IO_PENDING
    {
        return Err(PipeIoError::Failed(last_error(
            "write Windows management response",
        )));
    }
    let written = wait_for_overlapped(
        pipe,
        &mut overlapped,
        Some(("write Windows management response", CLIENT_IO_TIMEOUT)),
        stop,
    )?;
    if written != length {
        return Err(PipeIoError::Failed(format!(
            "write Windows management response was incomplete: {written}/{length} bytes"
        )));
    }
    Ok(())
}

fn read_response_ack(pipe: HANDLE, stop: &AtomicBool) -> Result<(), PipeIoError> {
    let mut ack = 0_u8;
    let event = create_event()?;
    let mut overlapped = new_overlapped(event.get());
    if unsafe { ReadFile(pipe, &mut ack, 1, null_mut(), &mut overlapped) } == 0
        && unsafe { GetLastError() } != ERROR_IO_PENDING
    {
        return Err(PipeIoError::Failed(last_error(
            "read Windows management response acknowledgement",
        )));
    }
    let read = wait_for_overlapped(
        pipe,
        &mut overlapped,
        Some((
            "read Windows management response acknowledgement",
            CLIENT_IO_TIMEOUT,
        )),
        stop,
    )?;
    if read != 1 || ack != RESPONSE_ACK {
        return Err(PipeIoError::Failed(
            "invalid Windows management response acknowledgement".to_owned(),
        ));
    }
    Ok(())
}

fn wait_for_overlapped(
    pipe: HANDLE,
    overlapped: &mut OVERLAPPED,
    timeout: Option<(&'static str, Duration)>,
    stop: &AtomicBool,
) -> Result<u32, PipeIoError> {
    let deadline = timeout.map(|(_, duration)| Instant::now() + duration);
    loop {
        if stop.load(Ordering::Acquire) {
            cancel_overlapped(pipe, overlapped);
            return Err(PipeIoError::Stopped);
        }
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            cancel_overlapped(pipe, overlapped);
            return Err(PipeIoError::TimedOut(
                timeout.expect("deadline has timeout metadata").0,
            ));
        }
        let status = unsafe {
            WaitForSingleObject(
                overlapped.hEvent,
                u32::try_from(IO_WAIT_SLICE.as_millis()).unwrap_or(25),
            )
        };
        match status {
            WAIT_OBJECT_0 => {
                let mut transferred = 0_u32;
                if unsafe { GetOverlappedResult(pipe, overlapped, &mut transferred, 0) } == 0 {
                    return Err(PipeIoError::Failed(last_error(
                        "complete Windows management pipe I/O",
                    )));
                }
                return Ok(transferred);
            }
            WAIT_TIMEOUT => {}
            _ => {
                cancel_overlapped(pipe, overlapped);
                return Err(PipeIoError::Failed(last_error(
                    "wait for Windows management pipe I/O",
                )));
            }
        }
    }
}

fn cancel_overlapped(pipe: HANDLE, overlapped: &mut OVERLAPPED) {
    unsafe {
        CancelIoEx(pipe, overlapped);
        let mut ignored = 0_u32;
        GetOverlappedResult(pipe, overlapped, &mut ignored, 1);
    }
}

fn create_event() -> Result<OwnedHandle, PipeIoError> {
    OwnedHandle::new(
        unsafe { CreateEventW(null(), 1, 0, null()) },
        "create Windows management I/O event",
    )
    .map_err(PipeIoError::Failed)
}

fn new_overlapped(event: HANDLE) -> OVERLAPPED {
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    overlapped.hEvent = event;
    overlapped
}

#[derive(Debug)]
enum PipeIoError {
    Stopped,
    TimedOut(&'static str),
    Failed(String),
}

impl std::fmt::Display for PipeIoError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Stopped => formatter.write_str("server stopped"),
            Self::TimedOut(action) => write!(formatter, "{action} timed out"),
            Self::Failed(message) => formatter.write_str(message),
        }
    }
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
