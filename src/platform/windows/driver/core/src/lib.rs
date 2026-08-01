#![deny(unsafe_code)]

mod abi;
mod state;

pub use abi::*;

#[allow(unsafe_code, reason = "the C++ shim links this fixed C ABI export")]
#[no_mangle]
pub extern "C" fn lumen_driver_core_initial_state() -> CoreState {
    CoreState::initial()
}

#[allow(unsafe_code, reason = "the C++ shim links this fixed C ABI export")]
#[no_mangle]
pub extern "C" fn lumen_driver_core_build_video_signal_mode(
    width: u32,
    height: u32,
    refresh_millihertz: u32,
    vertical_sync_divider: u32,
) -> VideoSignalMode {
    VideoSignalMode::new(width, height, refresh_millihertz, vertical_sync_divider)
}

#[allow(unsafe_code, reason = "the C++ shim links this fixed C ABI export")]
#[no_mangle]
pub extern "C" fn lumen_driver_core_dispatch(
    state: CoreState,
    request: CoreRequest,
) -> CoreTransition {
    state::dispatch(state, request)
}
