use std::ffi::{c_char, OsString};
use std::fmt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

#[cfg(target_os = "macos")]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(target_os = "macos")]
use std::sync::mpsc::{self, SyncSender};
#[cfg(target_os = "macos")]
use std::thread;

#[cfg(any(unix, windows))]
use std::ffi::CStr;
#[cfg(unix)]
use std::os::unix::ffi::OsStringExt;

use crate::platform::CallbackPlatformSessionControl;
#[cfg(target_os = "macos")]
use crate::platform::MacPlatformSessionControl;
#[cfg(windows)]
use crate::platform::{NativeWindowsLifecycle, NativeWindowsShell, WindowsPlatformSessionControl};
#[cfg(all(unix, not(target_os = "macos")))]
use crate::IdlePlatformSessionControl;
#[cfg(windows)]
use crate::NativeCommandSource;
#[cfg(unix)]
use crate::UnixSignalCommandSource;
#[cfg(any(unix, windows))]
use crate::{engine_abi_version, run_worker, HostArguments, HostRuntime, NativeHostService};
use crate::{
    HostArgumentsError, LumenHostPlatformCallbacks, PlatformSessionControl, WorkerRunError,
};

#[derive(Debug)]
pub enum NativeHostRunError {
    Configuration(HostArgumentsError),
    CommandSource(String),
    Runtime(WorkerRunError),
    InvalidProcessArguments,
    Panic,
}

impl NativeHostRunError {
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Configuration(_) | Self::InvalidProcessArguments => 78,
            Self::CommandSource(_) => 71,
            Self::Runtime(_) | Self::Panic => 70,
        }
    }
}

impl fmt::Display for NativeHostRunError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(error) => write!(formatter, "configuration rejected: {error}"),
            Self::CommandSource(error) => {
                write!(formatter, "command source setup failed: {error}")
            }
            Self::Runtime(error) => write!(formatter, "runtime failed: {error}"),
            Self::InvalidProcessArguments => formatter.write_str("process arguments are invalid"),
            Self::Panic => formatter.write_str("host runtime panicked"),
        }
    }
}

impl std::error::Error for NativeHostRunError {}

#[cfg(any(unix, windows))]
pub fn run_native_host<I>(arguments: I) -> Result<(), NativeHostRunError>
where
    I: IntoIterator<Item = OsString>,
{
    let arguments =
        HostArguments::parse_process(arguments).map_err(NativeHostRunError::Configuration)?;
    #[cfg(target_os = "macos")]
    {
        run_macos_native_host(arguments)
    }
    #[cfg(not(target_os = "macos"))]
    {
        #[cfg(all(unix, not(target_os = "macos")))]
        let platform: Arc<dyn PlatformSessionControl> = Arc::new(IdlePlatformSessionControl);
        #[cfg(windows)]
        let platform: Arc<dyn PlatformSessionControl> = Arc::new(
            WindowsPlatformSessionControl::new(&arguments)
                .map_err(NativeHostRunError::CommandSource)?,
        );
        run_parsed_native_host(arguments, platform)
    }
}

#[cfg(target_os = "macos")]
fn run_macos_native_host(arguments: HostArguments) -> Result<(), NativeHostRunError> {
    eprintln!(
        "Lumen Rust host configuration accepted: fields={} engine-abi={}",
        arguments.len(),
        engine_abi_version()
    );
    // Block the supervisor command signals before AppKit or the bridge creates
    // any threads so every descendant inherits the sigwait contract.
    let mut source =
        UnixSignalCommandSource::install().map_err(NativeHostRunError::CommandSource)?;
    let platform =
        Arc::new(MacPlatformSessionControl::new().map_err(NativeHostRunError::CommandSource)?);
    let worker_platform = Arc::clone(&platform);
    let run_loop_platform = Arc::clone(&platform);
    let stop_loop_platform = Arc::clone(&platform);
    run_macos_worker_lifecycle(
        move || {
            let mut runtime =
                HostRuntime::new(NativeHostService::production_with_platform(worker_platform));
            run_worker(&arguments, &mut runtime, &mut source).map_err(NativeHostRunError::Runtime)
        },
        move |readiness| run_loop_platform.run_application_event_loop(readiness),
        move || stop_loop_platform.stop_application_event_loop(),
        request_macos_worker_shutdown,
    )
}

#[cfg(target_os = "macos")]
fn run_macos_worker_lifecycle<Worker, RunLoop, StopLoop, RequestShutdown>(
    worker: Worker,
    run_loop: RunLoop,
    stop_loop: StopLoop,
    request_shutdown: RequestShutdown,
) -> Result<(), NativeHostRunError>
where
    Worker: FnOnce() -> Result<(), NativeHostRunError> + Send + 'static,
    RunLoop: FnOnce(SyncSender<bool>) -> Result<(), String>,
    StopLoop: FnOnce() + Send + 'static,
    RequestShutdown: FnOnce() -> Result<(), String>,
{
    let completed = Arc::new(AtomicBool::new(false));
    let worker_completed = Arc::clone(&completed);
    let event_loop_exited = Arc::new(AtomicBool::new(false));
    let worker_event_loop_exited = Arc::clone(&event_loop_exited);
    let (readiness_sender, readiness_receiver) = mpsc::sync_channel(1);
    let worker_thread = thread::Builder::new()
        .name("lumen-host-runtime".to_owned())
        .spawn(move || {
            let result = match readiness_receiver.recv() {
                Ok(true) => {
                    catch_unwind(AssertUnwindSafe(worker)).unwrap_or(Err(NativeHostRunError::Panic))
                }
                Ok(false) | Err(_) => Err(NativeHostRunError::CommandSource(
                    "macOS application event loop did not report readiness".to_owned(),
                )),
            };
            worker_completed.store(true, Ordering::Release);
            if !worker_event_loop_exited.load(Ordering::Acquire) {
                stop_loop();
            }
            result
        })
        .map_err(|error| {
            NativeHostRunError::CommandSource(format!(
                "could not start the macOS host runtime thread: {error}"
            ))
        })?;

    let run_loop_result = run_loop(readiness_sender).map_err(NativeHostRunError::CommandSource);
    event_loop_exited.store(true, Ordering::Release);
    let event_loop_exited_before_worker = !completed.load(Ordering::Acquire);
    let shutdown_result = if !event_loop_exited_before_worker {
        Ok(())
    } else {
        request_shutdown().map_err(NativeHostRunError::CommandSource)
    };
    let worker_result = worker_thread
        .join()
        .unwrap_or(Err(NativeHostRunError::Panic));
    run_loop_result?;
    shutdown_result?;
    if event_loop_exited_before_worker {
        return Err(NativeHostRunError::CommandSource(
            "macOS application event loop exited before host runtime completed".to_owned(),
        ));
    }
    worker_result
}

#[cfg(target_os = "macos")]
fn request_macos_worker_shutdown() -> Result<(), String> {
    if unsafe { libc::kill(libc::getpid(), libc::SIGTERM) } == 0 {
        Ok(())
    } else {
        Err(format!(
            "could not request worker shutdown after the macOS event loop exited: {}",
            std::io::Error::last_os_error()
        ))
    }
}

#[cfg(any(unix, windows))]
pub fn run_native_host_with_platform<I>(
    arguments: I,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), NativeHostRunError>
where
    I: IntoIterator<Item = OsString>,
{
    let arguments =
        HostArguments::parse_process(arguments).map_err(NativeHostRunError::Configuration)?;
    run_parsed_native_host(arguments, platform)
}

#[cfg(any(unix, windows))]
fn run_parsed_native_host(
    arguments: HostArguments,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), NativeHostRunError> {
    eprintln!(
        "Lumen Rust host configuration accepted: fields={} engine-abi={}",
        arguments.len(),
        engine_abi_version()
    );
    let mut runtime = HostRuntime::new(NativeHostService::production_with_platform(platform));
    #[cfg(unix)]
    {
        let mut source =
            UnixSignalCommandSource::install().map_err(NativeHostRunError::CommandSource)?;
        run_worker(&arguments, &mut runtime, &mut source).map_err(NativeHostRunError::Runtime)
    }
    #[cfg(windows)]
    {
        let mut source =
            NativeCommandSource::install().map_err(NativeHostRunError::CommandSource)?;
        let lifecycle =
            NativeWindowsLifecycle::start().map_err(NativeHostRunError::CommandSource)?;
        let shell =
            NativeWindowsShell::start(&arguments).map_err(NativeHostRunError::CommandSource)?;
        let result =
            run_worker(&arguments, &mut runtime, &mut source).map_err(NativeHostRunError::Runtime);
        drop(shell);
        drop(lifecycle);
        result
    }
}

#[cfg(not(any(unix, windows)))]
pub fn run_native_host<I>(_arguments: I) -> Result<(), NativeHostRunError>
where
    I: IntoIterator<Item = OsString>,
{
    Err(NativeHostRunError::InvalidProcessArguments)
}

#[cfg(not(any(unix, windows)))]
pub fn run_native_host_with_platform<I>(
    _arguments: I,
    _platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), NativeHostRunError>
where
    I: IntoIterator<Item = OsString>,
{
    Err(NativeHostRunError::InvalidProcessArguments)
}

/// Runs the native Rust host from a conventional C `argc`/`argv` process boundary.
///
/// # Safety
///
/// `argv` must reference `argc` valid pointers. Each pointer must address a NUL-terminated byte
/// string for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn lumen_host_run(argc: i32, argv: *const *const c_char) -> i32 {
    run_c_entry(|| {
        let arguments = process_arguments(argc, argv)?;
        run_native_host(arguments)
    })
}

/// Runs the native Rust host with an injected platform capture callback table.
///
/// # Safety
///
/// The `argc`/`argv` contract matches [`lumen_host_run`]. `callbacks` must remain valid for the
/// duration of this call, and its function pointers must be safe to invoke from Rust worker threads.
#[no_mangle]
pub unsafe extern "C" fn lumen_host_run_with_platform(
    argc: i32,
    argv: *const *const c_char,
    callbacks: *const LumenHostPlatformCallbacks,
) -> i32 {
    run_c_entry(|| {
        let arguments = process_arguments(argc, argv)?;
        let callbacks = callbacks
            .as_ref()
            .copied()
            .ok_or(NativeHostRunError::InvalidProcessArguments)?;
        let platform = CallbackPlatformSessionControl::new(callbacks)
            .map_err(|_| NativeHostRunError::InvalidProcessArguments)?;
        run_native_host_with_platform(arguments, Arc::new(platform))
    })
}

fn run_c_entry(operation: impl FnOnce() -> Result<(), NativeHostRunError>) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(operation));
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            eprintln!("Lumen Rust host {error}");
            error.exit_code()
        }
        Err(_) => {
            let error = NativeHostRunError::Panic;
            eprintln!("Lumen Rust host {error}");
            error.exit_code()
        }
    }
}

#[cfg(unix)]
fn process_arguments(
    argc: i32,
    argv: *const *const c_char,
) -> Result<Vec<OsString>, NativeHostRunError> {
    if argc < 1 || argv.is_null() {
        return Err(NativeHostRunError::InvalidProcessArguments);
    }
    let arguments = unsafe { std::slice::from_raw_parts(argv, argc as usize) };
    arguments
        .iter()
        .skip(1)
        .map(|argument| {
            if argument.is_null() {
                return Err(NativeHostRunError::InvalidProcessArguments);
            }
            let bytes = unsafe { CStr::from_ptr(*argument) }.to_bytes().to_vec();
            Ok(OsString::from_vec(bytes))
        })
        .collect()
}

#[cfg(windows)]
fn process_arguments(
    argc: i32,
    argv: *const *const c_char,
) -> Result<Vec<OsString>, NativeHostRunError> {
    if argc < 1 || argv.is_null() {
        return Err(NativeHostRunError::InvalidProcessArguments);
    }
    let arguments = unsafe { std::slice::from_raw_parts(argv, argc as usize) };
    arguments
        .iter()
        .skip(1)
        .map(|argument| {
            if argument.is_null() {
                return Err(NativeHostRunError::InvalidProcessArguments);
            }
            let value = unsafe { CStr::from_ptr(*argument) }
                .to_str()
                .map_err(|_| NativeHostRunError::InvalidProcessArguments)?;
            Ok(OsString::from(value))
        })
        .collect()
}

#[cfg(not(any(unix, windows)))]
fn process_arguments(
    _argc: i32,
    _argv: *const *const c_char,
) -> Result<Vec<OsString>, NativeHostRunError> {
    Err(NativeHostRunError::InvalidProcessArguments)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_c_process_boundaries_without_unwinding() {
        assert_eq!(unsafe { lumen_host_run(0, std::ptr::null()) }, 78);
    }

    #[cfg(unix)]
    #[test]
    fn preserves_non_unicode_arguments_until_typed_configuration_validation() {
        let program = b"lumen-host\0";
        let argument = [b'p', b'o', b'r', b't', b'=', 0xff, 0];
        let pointers = [program.as_ptr().cast(), argument.as_ptr().cast()];
        let parsed = process_arguments(2, pointers.as_ptr()).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(
            parsed[0].clone().into_vec(),
            vec![b'p', b'o', b'r', b't', b'=', 0xff]
        );
    }

    #[test]
    fn assigns_stable_process_exit_codes() {
        assert_eq!(NativeHostRunError::InvalidProcessArguments.exit_code(), 78);
        assert_eq!(
            NativeHostRunError::CommandSource("failed".into()).exit_code(),
            71
        );
        assert_eq!(NativeHostRunError::Panic.exit_code(), 70);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_worker_waits_for_main_event_loop_readiness() {
        use std::sync::mpsc;
        use std::sync::mpsc::TryRecvError;
        use std::time::Duration;

        let (stop_tx, stop_rx) = mpsc::channel();
        let (admission_tx, admission_rx) = mpsc::channel();
        let result = run_macos_worker_lifecycle(
            move || {
                admission_tx.send(()).expect("runtime admission");
                Ok(())
            },
            move |readiness| {
                assert_eq!(admission_rx.try_recv(), Err(TryRecvError::Empty));
                readiness.send(true).expect("event loop readiness");
                stop_rx
                    .recv_timeout(Duration::from_secs(1))
                    .map_err(|error| error.to_string())
            },
            move || {
                stop_tx.send(()).expect("event loop stop");
            },
            || Err("unexpected shutdown request".to_owned()),
        );

        assert!(result.is_ok());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_event_loop_exit_is_typed_after_requesting_worker_shutdown() {
        use std::sync::mpsc;
        use std::time::Duration;

        let (shutdown_tx, shutdown_rx) = mpsc::channel();
        let stop_requested = Arc::new(AtomicBool::new(false));
        let worker_stop_requested = Arc::clone(&stop_requested);
        let result = run_macos_worker_lifecycle(
            move || {
                shutdown_rx
                    .recv_timeout(Duration::from_secs(1))
                    .map_err(|error| NativeHostRunError::CommandSource(error.to_string()))
            },
            |readiness| {
                readiness.send(true).expect("event loop readiness");
                Ok(())
            },
            move || worker_stop_requested.store(true, Ordering::Release),
            move || shutdown_tx.send(()).map_err(|error| error.to_string()),
        );

        assert!(matches!(
            result,
            Err(NativeHostRunError::CommandSource(message))
                if message == "macOS application event loop exited before host runtime completed"
        ));
        assert!(!stop_requested.load(Ordering::Acquire));
    }
}
