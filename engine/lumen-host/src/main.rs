use std::process::ExitCode;

#[cfg(any(unix, windows))]
use lumen_host::run_native_host;

#[cfg(any(unix, windows))]
fn main() -> ExitCode {
    match run_native_host(std::env::args_os().skip(1)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Lumen Rust host {error}");
            ExitCode::from(error.exit_code() as u8)
        }
    }
}

#[cfg(not(any(unix, windows)))]
fn main() -> ExitCode {
    eprintln!("Lumen Rust host worker is not available on this platform");
    ExitCode::from(69)
}
