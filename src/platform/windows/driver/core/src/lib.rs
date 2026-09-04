#![deny(unsafe_code)]

mod abi;
mod edid;
mod state;

pub use abi::*;
pub use edid::*;

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

#[allow(
    unsafe_code,
    reason = "the C++ shim supplies a fixed EDID output buffer"
)]
#[no_mangle]
/// Builds one EDID block into the caller-owned output buffer.
///
/// # Safety
///
/// When non-null, `output` must be valid for writes of `output_len` bytes for
/// the duration of this call. The buffer must not overlap Rust-owned memory.
pub unsafe extern "C" fn lumen_driver_core_build_monitor_edid(
    width: u32,
    height: u32,
    refresh_millihertz: u32,
    hdr_capable: u32,
    output: *mut u8,
    output_len: u32,
) -> u32 {
    if output.is_null() || output_len < MONITOR_EDID_BYTES as u32 {
        return EDID_STATUS_BUFFER_TOO_SMALL;
    }
    let edid = match build_monitor_edid(width, height, refresh_millihertz, hdr_capable != 0) {
        Ok(edid) => edid,
        Err(MonitorEdidBuildError::InvalidMode) => return EDID_STATUS_INVALID,
    };
    unsafe {
        core::ptr::copy_nonoverlapping(edid.as_ptr(), output, MONITOR_EDID_BYTES);
    }
    EDID_STATUS_OK
}

#[allow(
    unsafe_code,
    reason = "the C++ shim supplies fixed EDID input and output buffers"
)]
#[no_mangle]
/// Parses one caller-owned EDID block into a caller-owned mode structure.
///
/// # Safety
///
/// When non-null, `input` must be valid for reads of `input_len` bytes and
/// `output` must be valid and aligned for one `MonitorEdidMode` write for the
/// duration of this call. The input and output regions must not overlap.
pub unsafe extern "C" fn lumen_driver_core_parse_monitor_edid(
    input: *const u8,
    input_len: u32,
    output: *mut MonitorEdidMode,
) -> u32 {
    if input.is_null() || output.is_null() || input_len < MONITOR_EDID_BYTES as u32 {
        return EDID_STATUS_INVALID;
    }
    let input = unsafe { core::slice::from_raw_parts(input, input_len as usize) };
    let Some(mode) = parse_monitor_edid(input) else {
        return EDID_STATUS_INVALID;
    };
    unsafe {
        *output = mode;
    }
    EDID_STATUS_OK
}

#[allow(unsafe_code, reason = "the C++ shim links this fixed C ABI export")]
#[no_mangle]
pub extern "C" fn lumen_driver_core_dispatch(
    state: CoreState,
    request: CoreRequest,
) -> CoreTransition {
    state::dispatch(state, request)
}
