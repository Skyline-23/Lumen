mod authority;
mod config;
mod control;
mod credentials;
#[cfg(any(test, windows))]
mod cursor_mask;
mod discovery;
mod entry;
mod local_settings;
pub mod media;
mod native_command;
mod native_input;
mod network_ports;
mod platform;
mod platform_feedback;
mod runtime;
mod server;
mod service;
mod signal;
mod upnp;
#[cfg(any(test, windows))]
mod windows_app;
#[cfg(windows)]
mod windows_service;
mod worker;

pub use authority::{HostAuthorities, HostAuthorityError, HostAuthorityPaths};
pub use config::{HostArguments, HostArgumentsError};
pub use control::{
    ControlMethod, ControlRequest, ControlResponse, ControlRouter, HostDiscoveryState,
};
pub use entry::{
    lumen_host_run, lumen_host_run_with_platform, run_native_host, run_native_host_with_platform,
    NativeHostRunError,
};
pub use native_command::{
    lumen_host_send_command, lumen_host_take_restart_request, LumenHostCommandSendStatus,
    NativeCommandSource, LUMEN_HOST_COMMAND_FORCE_STOP_STREAM,
    LUMEN_HOST_COMMAND_RELOAD_APPLICATIONS, LUMEN_HOST_COMMAND_RESTART,
    LUMEN_HOST_COMMAND_SHUTDOWN,
};
pub use native_input::{NativeInputError, PlatformNativeInputEvent};
pub use platform::{
    IdlePlatformSessionControl, LumenHostPlatformCallbacks, LumenHostPlatformControlEvent,
    LumenHostPlatformControlEventKind, LumenHostPlatformEncodedAudioPacket,
    LumenHostPlatformEncodedVideoFrame, LumenHostPlatformSessionPlan, LumenHostPlatformVideoCodec,
    PlatformApplicationPlan, PlatformControlEvent, PlatformEncodedAudioPacket,
    PlatformEncodedVideoFrame, PlatformSessionControl, PlatformSessionPlan, PlatformVideoCodec,
};
pub use platform_feedback::{
    LumenHostPlatformControlFeedback, LumenHostPlatformControlFeedbackKind,
    PlatformControlFeedback, ADAPTIVE_TRIGGER_BYTES,
};
pub use runtime::{HostCommand, HostRuntime, HostRuntimeError, HostRuntimeState, HostService};
pub use server::{
    IdleControlTransport, NativeControlTransport, QuicSessionTransport, TlsControlTransport,
};
pub use service::{IdleStreamControl, NativeHostService, NativeStreamControl};
#[cfg(unix)]
pub use signal::UnixSignalCommandSource;
#[cfg(windows)]
pub use windows_service::lumen_windows_service_run;
pub use worker::{run_worker, HostCommandSource, WorkerRunError};

pub fn engine_abi_version() -> u32 {
    lumen_engine::ABI_VERSION
}
