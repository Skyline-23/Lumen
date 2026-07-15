use std::collections::BTreeMap;
use std::ffi::c_void;
use std::mem::size_of;
use std::ptr::{null, null_mut};
use std::sync::{Mutex, MutexGuard};

use lumen_engine::settings::CommandInvocation;
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::{
    GetTokenInformation, TokenElevation, TokenLinkedToken, SECURITY_ATTRIBUTES, TOKEN_ELEVATION,
    TOKEN_LINKED_TOKEN, TOKEN_QUERY,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_APPEND_DATA, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, OPEN_ALWAYS,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows_sys::Win32::System::RemoteDesktop::{
    ProcessIdToSessionId, WTSGetActiveConsoleSessionId, WTSQueryUserToken,
};
use windows_sys::Win32::System::Threading::{
    CreateProcessAsUserW, CreateProcessW, GetCurrentProcess, GetCurrentProcessId,
    GetExitCodeProcess, GetProcessId, OpenProcessToken, ResumeThread, TerminateProcess,
    WaitForSingleObject, CREATE_NEW_PROCESS_GROUP, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT,
    INFINITE, PROCESS_INFORMATION, STARTF_USESTDHANDLES, STARTUPINFOW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowThreadProcessId, PostMessageW, WM_CLOSE,
};

use crate::platform::windows::process_command_line::{
    command_line, environment_block, invocation_command_line, optional_wide, wide,
};

pub(super) struct NativeWindowsProcess {
    environment: Vec<u16>,
    output: Option<OwnedHandle>,
    state: Mutex<ProcessState>,
}

#[derive(Default)]
struct ProcessState {
    main: Option<OwnedHandle>,
    job: Option<OwnedHandle>,
}

struct OwnedHandle(usize);

impl OwnedHandle {
    fn new(handle: HANDLE) -> Result<Self, String> {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            Err(last_error("create Windows handle"))
        } else {
            Ok(Self(handle as usize))
        }
    }

    fn get(&self) -> HANDLE {
        self.0 as HANDLE
    }
}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.get());
        }
    }
}

impl NativeWindowsProcess {
    pub(super) fn new(
        environment: &BTreeMap<String, String>,
        output: &str,
    ) -> Result<Self, String> {
        Ok(Self {
            environment: environment_block(environment)?,
            output: open_output(output)?,
            state: Mutex::new(ProcessState::default()),
        })
    }

    pub(super) fn run_blocking(
        &self,
        command: &str,
        working_directory: &str,
        elevated: bool,
    ) -> Result<(), String> {
        let _state = self.lock()?;
        let process = self.launch(command_line(command)?, working_directory, elevated, None)?;
        if unsafe { WaitForSingleObject(process.get(), INFINITE) } != WAIT_OBJECT_0 {
            return Err(last_error("wait for Windows command"));
        }
        let mut exit_code = 0;
        if unsafe { GetExitCodeProcess(process.get(), &mut exit_code) } == 0 {
            return Err(last_error("read Windows command exit status"));
        }
        (exit_code == 0)
            .then_some(())
            .ok_or_else(|| format!("Windows command exited with status {exit_code}"))
    }

    pub(super) fn run_invocation(
        &self,
        invocation: &CommandInvocation,
        working_directory: &str,
        elevated: bool,
    ) -> Result<(), String> {
        let _state = self.lock()?;
        let process = self.launch(
            invocation_command_line(invocation)?,
            working_directory,
            elevated,
            None,
        )?;
        if unsafe { WaitForSingleObject(process.get(), INFINITE) } != WAIT_OBJECT_0 {
            return Err(last_error("wait for structured Windows command"));
        }
        let mut exit_code = 0;
        if unsafe { GetExitCodeProcess(process.get(), &mut exit_code) } == 0 {
            return Err(last_error("read structured Windows command status"));
        }
        (exit_code == 0)
            .then_some(())
            .ok_or_else(|| format!("Structured Windows command exited with status {exit_code}"))
    }

    pub(super) fn spawn_invocation(
        &self,
        invocation: &CommandInvocation,
        working_directory: &str,
        elevated: bool,
    ) -> Result<(), String> {
        let _state = self.lock()?;
        let _process = self.launch(
            invocation_command_line(invocation)?,
            working_directory,
            elevated,
            None,
        )?;
        Ok(())
    }

    pub(super) fn spawn_detached(
        &self,
        command: &str,
        working_directory: &str,
        elevated: bool,
    ) -> Result<(), String> {
        let _state = self.lock()?;
        let _process = self.launch(command_line(command)?, working_directory, elevated, None)?;
        Ok(())
    }

    pub(super) fn spawn_main(
        &self,
        command: &str,
        working_directory: &str,
        elevated: bool,
    ) -> Result<(), String> {
        let mut state = self.lock()?;
        if state.main.is_some() {
            return Err("A Windows application process is already running".to_owned());
        }
        let job = create_job()?;
        let process = self.launch(
            command_line(command)?,
            working_directory,
            elevated,
            Some(job.get()),
        )?;
        state.main = Some(process);
        state.job = Some(job);
        Ok(())
    }

    pub(super) fn stop_main(&self, timeout_seconds: u32) -> Result<(), String> {
        let mut state = self.lock()?;
        let Some(process) = state.main.as_ref() else {
            state.job = None;
            return Ok(());
        };
        let process_id = unsafe { GetProcessId(process.get()) };
        if process_id != 0 {
            unsafe {
                EnumWindows(Some(request_window_close), process_id as isize);
            }
        }
        let timeout = timeout_seconds.saturating_mul(1_000).min(INFINITE - 1);
        let wait = unsafe { WaitForSingleObject(process.get(), timeout) };
        let termination_error = if wait == WAIT_TIMEOUT {
            state.job.as_ref().and_then(|job| {
                (unsafe { TerminateJobObject(job.get(), 1) } == 0)
                    .then(|| last_error("terminate Windows application job"))
            })
        } else if wait == WAIT_OBJECT_0 {
            None
        } else {
            Some(last_error("wait for Windows application exit"))
        };
        state.main = None;
        state.job = None;
        termination_error.map_or(Ok(()), Err)
    }

    fn launch(
        &self,
        mut command_line: Vec<u16>,
        working_directory: &str,
        elevated: bool,
        target_job: Option<HANDLE>,
    ) -> Result<OwnedHandle, String> {
        let directory = optional_wide(working_directory)?;
        let output = self.output.as_ref().map(OwnedHandle::get);
        let mut startup = STARTUPINFOW {
            cb: size_of::<STARTUPINFOW>() as u32,
            ..Default::default()
        };
        if let Some(output) = output {
            startup.dwFlags = STARTF_USESTDHANDLES;
            startup.hStdOutput = output;
            startup.hStdError = output;
        }
        let mut process_info = PROCESS_INFORMATION::default();
        let token = launch_token(elevated)?;
        let created = unsafe {
            match token.as_ref() {
                Some(token) => CreateProcessAsUserW(
                    token.get(),
                    null(),
                    command_line.as_mut_ptr(),
                    null(),
                    null(),
                    output.is_some().into(),
                    CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP,
                    self.environment.as_ptr().cast::<c_void>(),
                    directory.as_ref().map_or(null(), |value| value.as_ptr()),
                    &startup,
                    &mut process_info,
                ),
                None => CreateProcessW(
                    null(),
                    command_line.as_mut_ptr(),
                    null(),
                    null(),
                    output.is_some().into(),
                    CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP,
                    self.environment.as_ptr().cast::<c_void>(),
                    directory.as_ref().map_or(null(), |value| value.as_ptr()),
                    &startup,
                    &mut process_info,
                ),
            }
        };
        if created == 0 {
            return Err(last_error("create Windows process"));
        }
        let thread = OwnedHandle::new(process_info.hThread)?;
        let process = OwnedHandle::new(process_info.hProcess)?;
        if let Some(job) = target_job {
            if unsafe { AssignProcessToJobObject(job, process.get()) } == 0 {
                unsafe { TerminateProcess(process.get(), 1) };
                return Err(last_error("assign Windows process to job"));
            }
        }
        if unsafe { ResumeThread(thread.get()) } == u32::MAX {
            unsafe { TerminateProcess(process.get(), 1) };
            return Err(last_error("resume Windows process"));
        }
        Ok(process)
    }

    fn lock(&self) -> Result<MutexGuard<'_, ProcessState>, String> {
        self.state
            .lock()
            .map_err(|_| "Windows process state lock is poisoned".to_owned())
    }
}

impl Drop for NativeWindowsProcess {
    fn drop(&mut self) {
        let _ = self.stop_main(0);
    }
}

fn create_job() -> Result<OwnedHandle, String> {
    let job = OwnedHandle::new(unsafe { CreateJobObjectW(null(), null()) })?;
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if unsafe {
        SetInformationJobObject(
            job.get(),
            JobObjectExtendedLimitInformation,
            (&raw const limits).cast::<c_void>(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        return Err(last_error("configure Windows process job"));
    }
    Ok(job)
}

fn open_output(path: &str) -> Result<Option<OwnedHandle>, String> {
    if path.is_empty() || path == "null" {
        return Ok(None);
    }
    let path = wide(path)?;
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    };
    OwnedHandle::new(unsafe {
        CreateFileW(
            path.as_ptr(),
            FILE_APPEND_DATA,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            &attributes,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    })
    .map(Some)
}

fn launch_token(elevated: bool) -> Result<Option<OwnedHandle>, String> {
    let mut current_session = 0;
    let service_session = unsafe {
        ProcessIdToSessionId(GetCurrentProcessId(), &mut current_session) != 0
            && current_session == 0
    };
    if service_session {
        let mut token = null_mut();
        if unsafe { WTSQueryUserToken(WTSGetActiveConsoleSessionId(), &mut token) } == 0 {
            return Err(last_error("query active Windows user token"));
        }
        let token = OwnedHandle::new(token)?;
        if !elevated {
            return Ok(Some(token));
        }
        if let Some(linked) = linked_token(&token)? {
            return Ok(Some(linked));
        }
        return token_elevated(&token)?
            .then_some(Some(token))
            .ok_or_else(|| "Active Windows user token is not elevated".to_owned());
    }
    if elevated {
        let mut token = null_mut();
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
            return Err(last_error("open current Windows process token"));
        }
        let token = OwnedHandle::new(token)?;
        if !token_elevated(&token)? {
            return Err("Current Windows process is not elevated".to_owned());
        }
    }
    Ok(None)
}

fn linked_token(token: &OwnedHandle) -> Result<Option<OwnedHandle>, String> {
    let mut linked = TOKEN_LINKED_TOKEN::default();
    let mut size = 0;
    if unsafe {
        GetTokenInformation(
            token.get(),
            TokenLinkedToken,
            (&raw mut linked).cast::<c_void>(),
            size_of::<TOKEN_LINKED_TOKEN>() as u32,
            &mut size,
        )
    } == 0
    {
        return Ok(None);
    }
    OwnedHandle::new(linked.LinkedToken).map(Some)
}

fn token_elevated(token: &OwnedHandle) -> Result<bool, String> {
    let mut elevation = TOKEN_ELEVATION::default();
    let mut size = 0;
    if unsafe {
        GetTokenInformation(
            token.get(),
            TokenElevation,
            (&raw mut elevation).cast::<c_void>(),
            size_of::<TOKEN_ELEVATION>() as u32,
            &mut size,
        )
    } == 0
    {
        return Err(last_error("read Windows token elevation"));
    }
    Ok(elevation.TokenIsElevated != 0)
}

unsafe extern "system" fn request_window_close(window: *mut c_void, process_id: isize) -> i32 {
    let mut owner = 0;
    unsafe { GetWindowThreadProcessId(window, &mut owner) };
    if owner == process_id as u32 {
        unsafe { PostMessageW(window, WM_CLOSE, 0, 0) };
    }
    1
}

fn last_error(operation: &str) -> String {
    format!("Could not {operation} (Win32 error {})", unsafe {
        GetLastError()
    })
}
