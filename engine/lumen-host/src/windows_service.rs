use std::ffi::{c_char, c_int, c_void, CStr};
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use std::slice;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::OnceLock;

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::{
    DuplicateTokenEx, SecurityImpersonation, SetTokenInformation, TokenPrimary, TOKEN_ALL_ACCESS,
    TOKEN_DUPLICATE,
};
use windows_sys::Win32::System::Console::{
    AttachConsole, GenerateConsoleCtrlEvent, SetConsoleCtrlHandler, CTRL_C_EVENT,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_BREAKAWAY_OK,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows_sys::Win32::System::RemoteDesktop::WTSGetActiveConsoleSessionId;
use windows_sys::Win32::System::Services::{
    RegisterServiceCtrlHandlerExW, SetServiceStatus, StartServiceCtrlDispatcherW,
    SERVICE_ACCEPT_PRESHUTDOWN, SERVICE_ACCEPT_SESSIONCHANGE, SERVICE_ACCEPT_STOP,
    SERVICE_CONTROL_INTERROGATE, SERVICE_CONTROL_PRESHUTDOWN, SERVICE_CONTROL_SESSIONCHANGE,
    SERVICE_CONTROL_STOP, SERVICE_RUNNING, SERVICE_START_PENDING, SERVICE_STATUS,
    SERVICE_STATUS_HANDLE, SERVICE_STOPPED, SERVICE_STOP_PENDING, SERVICE_TABLE_ENTRYW,
    SERVICE_WIN32_OWN_PROCESS,
};
use windows_sys::Win32::System::Threading::{
    CreateEventW, CreateProcessAsUserW, GetCurrentProcess, GetExitCodeProcess, GetProcessId,
    OpenProcessToken, ResumeThread, SetEvent, TerminateProcess, WaitForMultipleObjects,
    WaitForSingleObject, CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT,
    DETACHED_PROCESS, INFINITE, PROCESS_INFORMATION, STARTUPINFOW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::WTS_CONSOLE_CONNECT;

const SERVICE_NAME: [u16; 13] = [76, 117, 109, 101, 110, 83, 101, 114, 118, 105, 99, 101, 0];
const NO_CONSOLE_SESSION: u32 = u32::MAX;
const ERROR_PROCESS_ABORTED: u32 = 1067;
const ERROR_SHUTDOWN_IN_PROGRESS: u32 = 1115;
const ERROR_INVALID_PARAMETER: c_int = 87;

struct ServiceControl {
    status: AtomicPtr<c_void>,
    stop_event: AtomicPtr<c_void>,
    session_event: AtomicPtr<c_void>,
}

static SERVICE_CONTROL_STATE: OnceLock<ServiceControl> = OnceLock::new();

impl ServiceControl {
    fn shared() -> &'static Self {
        SERVICE_CONTROL_STATE.get_or_init(|| Self {
            status: AtomicPtr::new(null_mut()),
            stop_event: AtomicPtr::new(null_mut()),
            session_event: AtomicPtr::new(null_mut()),
        })
    }

    fn report(&self, state: u32, accepted: u32, error: u32, wait_hint: u32) {
        let handle = self.status.load(Ordering::Acquire) as SERVICE_STATUS_HANDLE;
        if handle.is_null() {
            return;
        }
        let status = SERVICE_STATUS {
            dwServiceType: SERVICE_WIN32_OWN_PROCESS,
            dwCurrentState: state,
            dwControlsAccepted: accepted,
            dwWin32ExitCode: error,
            dwServiceSpecificExitCode: 0,
            dwCheckPoint: 0,
            dwWaitHint: wait_hint,
        };
        unsafe {
            SetServiceStatus(handle, &status);
        }
    }
}

struct OwnedHandle(HANDLE);

impl OwnedHandle {
    fn new(handle: HANDLE, operation: &str) -> Result<Self, String> {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            Err(last_error(operation))
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

struct ProcessHandles {
    process: OwnedHandle,
    thread: OwnedHandle,
}

enum ServiceInvocation {
    Dispatch,
    Terminate(u32),
}

#[no_mangle]
/// Runs the Windows SCM service entrypoint or its console-termination helper.
///
/// # Safety
///
/// `argv` must point to `argc` valid, NUL-terminated C string pointers for the
/// duration of this call, matching the process entrypoint contract.
pub unsafe extern "C" fn lumen_windows_service_run(
    argc: c_int,
    argv: *const *const c_char,
) -> c_int {
    match service_arguments(argc, argv) {
        Ok(ServiceInvocation::Terminate(process_id)) => graceful_termination(process_id)
            .map(|()| 0)
            .unwrap_or_else(|_| unsafe { GetLastError() as c_int }),
        Ok(ServiceInvocation::Dispatch) => dispatch_service()
            .map(|()| 0)
            .unwrap_or_else(|_| unsafe { GetLastError() as c_int }),
        Err(()) => ERROR_INVALID_PARAMETER,
    }
}

unsafe fn service_arguments(
    argc: c_int,
    argv: *const *const c_char,
) -> Result<ServiceInvocation, ()> {
    if argc == 1 {
        return Ok(ServiceInvocation::Dispatch);
    }
    if argc != 3 || argv.is_null() {
        return Err(());
    }
    let arguments = unsafe { slice::from_raw_parts(argv, argc as usize) };
    if arguments[1].is_null() || arguments[2].is_null() {
        return Err(());
    }
    let command = unsafe { CStr::from_ptr(arguments[1]) }
        .to_str()
        .map_err(|_| ())?;
    let process_id = unsafe { CStr::from_ptr(arguments[2]) }
        .to_str()
        .map_err(|_| ())?
        .parse::<u32>()
        .map_err(|_| ())?;
    (command == "--terminate" && process_id != 0)
        .then_some(ServiceInvocation::Terminate(process_id))
        .ok_or(())
}

fn dispatch_service() -> Result<(), String> {
    let executable = std::env::current_exe()
        .map_err(|error| format!("resolve Lumen service executable: {error}"))?;
    let host_directory = executable
        .parent()
        .and_then(|tools| tools.parent())
        .ok_or_else(|| "Lumen service executable has no host directory".to_owned())?;
    std::env::set_current_dir(host_directory)
        .map_err(|error| format!("set Lumen service host directory: {error}"))?;

    let table = [
        SERVICE_TABLE_ENTRYW {
            lpServiceName: SERVICE_NAME.as_ptr().cast_mut(),
            lpServiceProc: Some(service_main),
        },
        SERVICE_TABLE_ENTRYW::default(),
    ];
    if unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } == 0 {
        Err(last_error("start Lumen service dispatcher"))
    } else {
        Ok(())
    }
}

unsafe extern "system" fn service_control_handler(
    control: u32,
    event_type: u32,
    _event_data: *mut c_void,
    _context: *mut c_void,
) -> u32 {
    let state = ServiceControl::shared();
    match control {
        SERVICE_CONTROL_INTERROGATE => 0,
        SERVICE_CONTROL_SESSIONCHANGE if event_type == WTS_CONSOLE_CONNECT => {
            signal(state.session_event.load(Ordering::Acquire) as HANDLE);
            0
        }
        SERVICE_CONTROL_STOP | SERVICE_CONTROL_PRESHUTDOWN => {
            state.report(SERVICE_STOP_PENDING, 0, 0, 30_000);
            signal(state.stop_event.load(Ordering::Acquire) as HANDLE);
            0
        }
        _ => 120,
    }
}

unsafe extern "system" fn service_main(_argc: u32, _argv: *mut *mut u16) {
    let state = ServiceControl::shared();
    let status = unsafe {
        RegisterServiceCtrlHandlerExW(SERVICE_NAME.as_ptr(), Some(service_control_handler), null())
    };
    if status.is_null() {
        return;
    }
    state.status.store(status.cast(), Ordering::Release);
    state.report(SERVICE_START_PENDING, 0, 0, 0);
    let result = run_service(state);
    let error = if result.is_ok() {
        0
    } else {
        unsafe { GetLastError() }.max(1)
    };
    state.report(SERVICE_STOPPED, 0, error, 0);
    state.stop_event.store(null_mut(), Ordering::Release);
    state.session_event.store(null_mut(), Ordering::Release);
    state.status.store(null_mut(), Ordering::Release);
}

fn run_service(state: &ServiceControl) -> Result<(), String> {
    let stop_event = OwnedHandle::new(
        unsafe { CreateEventW(null(), 1, 0, null()) },
        "create Lumen service stop event",
    )?;
    let session_event = OwnedHandle::new(
        unsafe { CreateEventW(null(), 0, 0, null()) },
        "create Lumen service session event",
    )?;
    state
        .stop_event
        .store(stop_event.get().cast(), Ordering::Release);
    state
        .session_event
        .store(session_event.get().cast(), Ordering::Release);
    state.report(
        SERVICE_RUNNING,
        SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_PRESHUTDOWN | SERVICE_ACCEPT_SESSIONCHANGE,
        0,
        0,
    );

    loop {
        match unsafe { WaitForSingleObject(stop_event.get(), 3_000) } {
            WAIT_OBJECT_0 => break,
            WAIT_TIMEOUT => {}
            _ => return Err(last_error("wait for Lumen service control event")),
        }
        let session_id = unsafe { WTSGetActiveConsoleSessionId() };
        if session_id == NO_CONSOLE_SESSION {
            continue;
        }
        let token = match duplicate_service_token(session_id) {
            Ok(token) => token,
            Err(_) => continue,
        };
        let job = match create_host_job() {
            Ok(job) => job,
            Err(_) => continue,
        };
        let process = match launch_host(&token, &job) {
            Ok(process) => process,
            Err(_) => continue,
        };
        supervise_host(
            &token,
            session_id,
            &process,
            stop_event.get(),
            session_event.get(),
        );
    }
    Ok(())
}

fn duplicate_service_token(session_id: u32) -> Result<OwnedHandle, String> {
    let mut current = null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE, &mut current) } == 0 {
        return Err(last_error("open Lumen service process token"));
    }
    let current = OwnedHandle::new(current, "open Lumen service process token")?;
    let mut token = null_mut();
    if unsafe {
        DuplicateTokenEx(
            current.get(),
            TOKEN_ALL_ACCESS,
            null(),
            SecurityImpersonation,
            TokenPrimary,
            &mut token,
        )
    } == 0
    {
        return Err(last_error("duplicate Lumen service token"));
    }
    let token = OwnedHandle::new(token, "duplicate Lumen service token")?;
    if unsafe {
        SetTokenInformation(
            token.get(),
            windows_sys::Win32::Security::TokenSessionId,
            (&session_id as *const u32).cast(),
            size_of::<u32>() as u32,
        )
    } == 0
    {
        return Err(last_error("assign Lumen service token session"));
    }
    Ok(token)
}

fn create_host_job() -> Result<OwnedHandle, String> {
    let job = OwnedHandle::new(
        unsafe { CreateJobObjectW(null(), null()) },
        "create Lumen service host job",
    )?;
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    if unsafe {
        SetInformationJobObject(
            job.get(),
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        return Err(last_error("configure Lumen service host job"));
    }
    Ok(job)
}

fn launch_host(token: &OwnedHandle, job: &OwnedHandle) -> Result<ProcessHandles, String> {
    let application = wide("Lumen.exe");
    let desktop = wide("winsta0\\default");
    let mut startup: STARTUPINFOW = unsafe { zeroed() };
    startup.cb = size_of::<STARTUPINFOW>() as u32;
    startup.lpDesktop = desktop.as_ptr().cast_mut();
    let mut process: PROCESS_INFORMATION = unsafe { zeroed() };
    if unsafe {
        CreateProcessAsUserW(
            token.get(),
            application.as_ptr(),
            null_mut(),
            null(),
            null(),
            0,
            CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW | CREATE_SUSPENDED,
            null(),
            null(),
            &startup,
            &mut process,
        )
    } == 0
    {
        return Err(last_error("launch Lumen host from service"));
    }
    let handles = ProcessHandles {
        process: OwnedHandle::new(process.hProcess, "open Lumen host process")?,
        thread: OwnedHandle::new(process.hThread, "open Lumen host thread")?,
    };
    if unsafe { AssignProcessToJobObject(job.get(), handles.process.get()) } == 0 {
        return Err(last_error("assign Lumen host to service job"));
    }
    if unsafe { ResumeThread(handles.thread.get()) } == u32::MAX {
        return Err(last_error("resume Lumen service host"));
    }
    Ok(handles)
}

fn supervise_host(
    token: &OwnedHandle,
    session_id: u32,
    process: &ProcessHandles,
    stop_event: HANDLE,
    session_event: HANDLE,
) {
    loop {
        let handles = [stop_event, process.process.get(), session_event];
        let signaled =
            unsafe { WaitForMultipleObjects(handles.len() as u32, handles.as_ptr(), 0, INFINITE) };
        if signaled == WAIT_OBJECT_0 + 2 && unsafe { WTSGetActiveConsoleSessionId() } == session_id
        {
            continue;
        }
        if signaled == WAIT_OBJECT_0 + 1 {
            let mut exit_code = 0;
            if unsafe { GetExitCodeProcess(process.process.get(), &mut exit_code) } != 0
                && exit_code == ERROR_SHUTDOWN_IN_PROGRESS
            {
                signal(ServiceControl::shared().stop_event.load(Ordering::Acquire) as HANDLE);
            }
            return;
        }
        if run_termination_helper(token, process.process.get()).is_err()
            || unsafe { WaitForSingleObject(process.process.get(), 20_000) } != WAIT_OBJECT_0
        {
            unsafe {
                TerminateProcess(process.process.get(), ERROR_PROCESS_ABORTED);
            }
        }
        return;
    }
}

fn run_termination_helper(token: &OwnedHandle, process: HANDLE) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;

    let executable = std::env::current_exe()
        .map_err(|error| format!("resolve Lumen service helper: {error}"))?;
    let executable_wide: Vec<u16> = executable.as_os_str().encode_wide().chain([0]).collect();
    let process_id = unsafe { GetProcessId(process) };
    if process_id == 0 {
        return Err(last_error("resolve Lumen host process id"));
    }
    let mut command = Vec::with_capacity(executable_wide.len() + 32);
    command.push('"' as u16);
    command.extend_from_slice(&executable_wide[..executable_wide.len() - 1]);
    command.extend(format!("\" --terminate {process_id}").encode_utf16());
    command.push(0);
    let desktop = wide("winsta0\\default");
    let mut startup: STARTUPINFOW = unsafe { zeroed() };
    startup.cb = size_of::<STARTUPINFOW>() as u32;
    startup.lpDesktop = desktop.as_ptr().cast_mut();
    let mut helper: PROCESS_INFORMATION = unsafe { zeroed() };
    if unsafe {
        CreateProcessAsUserW(
            token.get(),
            executable_wide.as_ptr(),
            command.as_mut_ptr(),
            null(),
            null(),
            0,
            CREATE_UNICODE_ENVIRONMENT | DETACHED_PROCESS,
            null(),
            null(),
            &startup,
            &mut helper,
        )
    } == 0
    {
        return Err(last_error("launch Lumen termination helper"));
    }
    let helper = ProcessHandles {
        process: OwnedHandle::new(helper.hProcess, "open Lumen termination helper")?,
        thread: OwnedHandle::new(helper.hThread, "open Lumen termination helper thread")?,
    };
    if unsafe { WaitForSingleObject(helper.process.get(), INFINITE) } != WAIT_OBJECT_0 {
        return Err(last_error("wait for Lumen termination helper"));
    }
    let mut exit_code = 0;
    if unsafe { GetExitCodeProcess(helper.process.get(), &mut exit_code) } == 0 || exit_code != 0 {
        return Err(format!(
            "Lumen termination helper failed with status {exit_code}"
        ));
    }
    Ok(())
}

fn graceful_termination(process_id: u32) -> Result<(), String> {
    if unsafe { AttachConsole(process_id) } == 0 {
        return Err(last_error("attach to Lumen host console"));
    }
    if unsafe { SetConsoleCtrlHandler(None, 1) } == 0 {
        return Err(last_error("disable Lumen helper console handler"));
    }
    if unsafe { GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) } == 0 {
        return Err(last_error("send Lumen host control event"));
    }
    Ok(())
}

fn signal(event: HANDLE) {
    if !event.is_null() {
        unsafe {
            SetEvent(event);
        }
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain([0]).collect()
}

fn last_error(operation: &str) -> String {
    format!("{operation} failed with Windows error {}", unsafe {
        GetLastError()
    })
}
