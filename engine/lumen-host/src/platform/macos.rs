use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::PathBuf;
use std::ptr;
use std::sync::{mpsc::SyncSender, Mutex};
use std::time::{Duration, Instant};

use lumen_engine::{
    resolve_audio_stream, resolve_display_geometry, LumenAudioStreamRequest,
    LumenDisplayModeRequest,
};

use crate::{
    PlatformApplicationPlan, PlatformControlEvent, PlatformEncodedAudioPacket,
    PlatformEncodedVideoFrame, PlatformNativeInputEvent, PlatformRuntimeEvent,
    PlatformRuntimeEventDisposition, PlatformRuntimeEventSeverity, PlatformSessionControl,
    PlatformSessionPlan,
};

use super::macos_native_input::{
    MacInputCaptureViewport, MacInputDisplayBounds, MacNativeInput, MacPositionedButtonInput,
};
use super::portable_process::PortableApplication;

#[path = "macos_media.rs"]
mod media;
#[path = "macos_session.rs"]
mod session;
#[cfg(test)]
#[path = "macos_tests.rs"]
mod tests;

use media::{copy_annex_b_sample, NativeOpusEncoder};
#[cfg(test)]
use session::stop_workspace;

const MAXIMUM_VIDEO_BYTES: usize = 32 * 1024 * 1024;
const MAXIMUM_PCM_BYTES: usize = 1024 * 1024;
const AUDIO_FRAME_COUNT: usize = 240;
const AUDIO_PACKET_DURATION: Duration = Duration::from_millis(5);
const MAXIMUM_AUDIO_CATCHUP: Duration = Duration::from_millis(100);
const MACOS_WORKSPACE_DISPLAY_KEY: &str = "dev.skyline23.lumen.workspace.primary.v1";
type BridgeController = c_void;
type MacOpusEncoder = c_void;
type SampleBuffer = *const c_void;
type FormatDescription = *const c_void;
type BlockBuffer = *const c_void;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacSinkMode {
    hidpi: bool,
    scale_explicit: bool,
    mode_is_logical: bool,
    scale_percent: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacSinkCapability {
    gamut: i32,
    transfer: i32,
    current_edr_headroom: f32,
    potential_edr_headroom: f32,
    current_peak_luminance_nits: i32,
    potential_peak_luminance_nits: i32,
    supports_frame_gated_hdr: bool,
    supports_hdr_tile_overlay: bool,
    supports_per_frame_hdr_metadata: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacSinkRequest {
    mode: MacSinkMode,
    capability: MacSinkCapability,
    dynamic_range_transport: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacHdrStaticMetadata {
    values: [i32; 13],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacEffectiveDisplayState {
    gamut: i32,
    transfer: i32,
    has_hdr_static_metadata: bool,
    hdr_static_metadata: MacHdrStaticMetadata,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacCaptureConfiguration {
    display_id: u32,
    session_epoch: u32,
    policy_revision: u32,
    codec: i32,
    video_profile: i32,
    chroma_subsampling: i32,
    bit_depth: u8,
    dynamic_range: i32,
    color_range: i32,
    preprocess_strategy: i32,
    queue_profile: i32,
    target_frame_rate: i32,
    target_video_bitrate_kbps: i32,
    requested_width: i32,
    requested_height: i32,
    sink_request: MacSinkRequest,
    effective_display_state: MacEffectiveDisplayState,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MacAudioCaptureConfiguration {
    source_kind: i32,
    display_id: u32,
    excludes_current_process_audio: bool,
    sample_rate: i32,
    channel_count: i32,
    frame_size: i32,
    input_id: [c_char; 256],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MacWorkspaceSessionRequest {
    display_key: *const c_char,
    display_name: *const c_char,
    width: u32,
    height: u32,
    scale_percent: u32,
    dimensions_are_logical: bool,
    high_density: bool,
    refresh_rate: f64,
    hdr_enabled: bool,
    sink_gamut: i32,
    sink_transfer: i32,
    current_edr_headroom: f32,
    potential_edr_headroom: f32,
    current_peak_luminance_nits: i32,
    potential_peak_luminance_nits: i32,
    desktop_mirror_source_display_id: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MacWorkspaceActivationResult {
    activated: bool,
    isolation_status: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacEncodedFrameRecord {
    has_value: bool,
    codec: i32,
    payload_size: usize,
    source_sequence_number: u64,
    source_display_time: u64,
    has_output_callback_latency_milliseconds: bool,
    output_callback_latency_milliseconds: f64,
    is_key_frame: bool,
    requires_bootstrap_acknowledgement: bool,
    repair_key_frame: bool,
    is_hdr_signaled: bool,
    is_replay: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacAudioFrameRecord {
    has_value: bool,
    sequence_number: u64,
    host_time_nanoseconds: u64,
    sample_rate: i32,
    channel_count: i32,
    frame_count: i32,
    pcm_byte_count: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacAudioCaptureEventRecord {
    has_value: bool,
    kind: i32,
    has_stop_status: bool,
    stop_status: i32,
    has_automatic_restart_count: bool,
    automatic_restart_count: u64,
    has_source_sequence_number: bool,
    source_sequence_number: u64,
}

type CreateController = unsafe extern "C" fn() -> *mut BridgeController;
type DestroyController = unsafe extern "C" fn(*mut BridgeController);
type ApplicationReadinessCallback = unsafe extern "C" fn(*mut c_void, bool);
type PrepareApplicationMainThread = unsafe extern "C" fn() -> bool;
type RunApplicationMainThread =
    unsafe extern "C" fn(ApplicationReadinessCallback, *mut c_void) -> bool;
type StopApplicationMainThread = unsafe extern "C" fn();
type WarmScreenCaptureInventory = unsafe extern "C" fn();
type MakeVideoConfiguration = unsafe extern "C" fn(u32) -> MacCaptureConfiguration;
type MakeAudioConfiguration = unsafe extern "C" fn(u32) -> MacAudioCaptureConfiguration;
type ConfigureForwarding = unsafe extern "C" fn(*mut BridgeController, usize, usize);
type StartCapturePair = unsafe extern "C" fn(
    *mut BridgeController,
    MacCaptureConfiguration,
    MacAudioCaptureConfiguration,
    *mut c_char,
    usize,
) -> i32;
type StopCapture = unsafe extern "C" fn(*mut BridgeController);
type PopVideo =
    unsafe extern "C" fn(*mut BridgeController, *mut SampleBuffer) -> MacEncodedFrameRecord;
type PopAudio = unsafe extern "C" fn(
    *mut BridgeController,
    *mut c_void,
    usize,
    *mut usize,
) -> MacAudioFrameRecord;
type PopAudioEvent =
    unsafe extern "C" fn(*mut BridgeController, *mut c_char, usize) -> MacAudioCaptureEventRecord;
type RequestKeyFrame = unsafe extern "C" fn();
type RequestPeriodicKeyFrame = unsafe extern "C" fn() -> bool;
type ResumeVideoEncodingAfterCodecAck = unsafe extern "C" fn() -> bool;
type SetVideoDeliveryPolicy = unsafe extern "C" fn(u32, u32, u32, u8) -> bool;
type WakeUnchangedContentCadence = unsafe extern "C" fn(u32) -> bool;
type ResetMediaQueues = unsafe extern "C" fn(*mut BridgeController);
type PrepareWorkspace = unsafe extern "C" fn(MacWorkspaceSessionRequest, *mut c_char, usize) -> u32;
type ReconfigureWorkspace =
    unsafe extern "C" fn(MacWorkspaceSessionRequest, *mut c_char, usize) -> u32;
type ActivateWorkspace =
    unsafe extern "C" fn(*const c_char, *mut c_char, usize) -> MacWorkspaceActivationResult;
type StopWorkspace = unsafe extern "C" fn(*const c_char, *mut c_char, usize) -> bool;
type PublishRuntimeEvent = unsafe extern "C" fn(u32, u32, u32, *const c_char);
type CreateOpusEncoder = unsafe extern "C" fn(
    i32,
    i32,
    i32,
    i32,
    *const u8,
    i32,
    bool,
    *mut c_char,
    usize,
) -> *mut MacOpusEncoder;
type EncodeOpusFloat32 = unsafe extern "C" fn(
    *mut MacOpusEncoder,
    *const f32,
    i32,
    *mut u8,
    usize,
    *mut usize,
    *mut c_char,
    usize,
) -> bool;
type DestroyOpusEncoder = unsafe extern "C" fn(*mut MacOpusEncoder);

struct MacBridgeApi {
    // AppKit schedules process-lifetime run-loop callbacks into this image.
    _handle: *mut c_void,
    prepare_application_main_thread: PrepareApplicationMainThread,
    run_application_main_thread: RunApplicationMainThread,
    stop_application_main_thread: StopApplicationMainThread,
    warm_screen_capture_inventory: WarmScreenCaptureInventory,
    create_controller: CreateController,
    destroy_controller: DestroyController,
    make_video_configuration: MakeVideoConfiguration,
    make_audio_configuration: MakeAudioConfiguration,
    configure_video_forwarding: ConfigureForwarding,
    configure_audio_forwarding: ConfigureForwarding,
    start_capture_pair: StartCapturePair,
    stop_video_capture: StopCapture,
    stop_audio_capture: StopCapture,
    pop_video: PopVideo,
    pop_audio: PopAudio,
    pop_audio_event: PopAudioEvent,
    request_key_frame: RequestKeyFrame,
    request_periodic_key_frame: RequestPeriodicKeyFrame,
    resume_video_encoding_after_codec_ack: ResumeVideoEncodingAfterCodecAck,
    set_video_delivery_policy: SetVideoDeliveryPolicy,
    wake_unchanged_content_cadence: WakeUnchangedContentCadence,
    reset_media_queues: ResetMediaQueues,
    prepare_workspace: PrepareWorkspace,
    reconfigure_workspace: ReconfigureWorkspace,
    activate_workspace: ActivateWorkspace,
    stop_workspace: StopWorkspace,
    publish_runtime_event: PublishRuntimeEvent,
    create_opus_encoder: CreateOpusEncoder,
    encode_opus_float32: EncodeOpusFloat32,
    destroy_opus_encoder: DestroyOpusEncoder,
}

unsafe impl Send for MacBridgeApi {}
unsafe impl Sync for MacBridgeApi {}

impl MacBridgeApi {
    fn load() -> Result<Self, String> {
        let path = framework_path()?;
        let path = CString::new(path.to_string_lossy().as_bytes())
            .map_err(|_| "macOS bridge path contains a null byte".to_owned())?;
        let handle = unsafe { dlopen(path.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
        if handle.is_null() {
            return Err(format!("could not load LumenMacBridge: {}", dl_error()));
        }
        unsafe {
            Ok(Self {
                _handle: handle,
                prepare_application_main_thread: load_symbol(
                    handle,
                    b"LumenMacApplicationPrepareMainThread\0",
                )?,
                run_application_main_thread: load_symbol(
                    handle,
                    b"LumenMacApplicationRunMainThread\0",
                )?,
                stop_application_main_thread: load_symbol(
                    handle,
                    b"LumenMacApplicationStopMainThread\0",
                )?,
                warm_screen_capture_inventory: load_symbol(
                    handle,
                    b"LumenMacScreenCaptureWarmInventory\0",
                )?,
                create_controller: load_symbol(handle, b"LumenMacBridgeControllerCreate\0")?,
                destroy_controller: load_symbol(handle, b"LumenMacBridgeControllerDestroy\0")?,
                make_video_configuration: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerMakePanelNativeConfiguration\0",
                )?,
                make_audio_configuration: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerMakeSystemOutputAudioConfiguration\0",
                )?,
                configure_video_forwarding: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerConfigureVideoForwarding\0",
                )?,
                configure_audio_forwarding: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerConfigureAudioForwarding\0",
                )?,
                start_capture_pair: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerStartCapturePair\0",
                )?,
                stop_video_capture: load_symbol(handle, b"LumenMacBridgeControllerStopCapture\0")?,
                stop_audio_capture: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerStopAudioCapture\0",
                )?,
                pop_video: load_symbol(handle, b"LumenMacBridgeControllerPopNextForwardedFrame\0")?,
                pop_audio: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerPopNextForwardedAudioFrame\0",
                )?,
                pop_audio_event: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerPopNextForwardedAudioEvent\0",
                )?,
                request_key_frame: load_symbol(
                    handle,
                    b"LumenMacBridgeRequestImmediateCaptureKeyFrame\0",
                )?,
                request_periodic_key_frame: load_symbol(
                    handle,
                    b"LumenMacBridgeRequestPeriodicCaptureKeyFrame\0",
                )?,
                resume_video_encoding_after_codec_ack: load_symbol(
                    handle,
                    b"LumenMacBridgeResumeVideoEncodingAfterCodecAck\0",
                )?,
                set_video_delivery_policy: load_symbol(
                    handle,
                    b"LumenMacBridgeSetVideoDeliveryPolicy\0",
                )?,
                wake_unchanged_content_cadence: load_symbol(
                    handle,
                    b"LumenMacBridgeWakeUnchangedContentCadence\0",
                )?,
                reset_media_queues: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerResetMediaQueues\0",
                )?,
                prepare_workspace: load_symbol(handle, b"LumenMacWorkspacePrepareSession\0")?,
                reconfigure_workspace: load_symbol(
                    handle,
                    b"LumenMacWorkspaceReconfigureSession\0",
                )?,
                activate_workspace: load_symbol(handle, b"LumenMacWorkspaceActivateSession\0")?,
                stop_workspace: load_symbol(handle, b"LumenMacWorkspaceStopSession\0")?,
                publish_runtime_event: load_symbol(handle, b"LumenMacBridgePublishRuntimeEvent\0")?,
                create_opus_encoder: load_symbol(handle, b"LumenMacOpusEncoderCreate\0")?,
                encode_opus_float32: load_symbol(handle, b"LumenMacOpusEncoderEncodeFloat32\0")?,
                destroy_opus_encoder: load_symbol(handle, b"LumenMacOpusEncoderDestroy\0")?,
            })
        }
    }
}

struct MacSessionState {
    controller: *mut BridgeController,
    workspace_key: Option<CString>,
    display_id: u32,
    input_display_id: u32,
    input_display_bounds: Option<MacInputDisplayBounds>,
    input_capture_viewport: Option<MacInputCaptureViewport>,
    desktop_mirror_source_display_id: u32,
    opus: Option<NativeOpusEncoder>,
    audio_channels: usize,
    pcm: Vec<u8>,
    audio_scratch: Vec<u8>,
    next_audio_timestamp: u32,
    next_audio_deadline: Option<Instant>,
    audio_capture_failure: Option<String>,
    plan: Option<PlatformSessionPlan>,
}

unsafe impl Send for MacSessionState {}

pub(crate) struct MacPlatformSessionControl {
    api: MacBridgeApi,
    state: Mutex<MacSessionState>,
    native_input: MacNativeInput,
    application: PortableApplication,
}

fn workspace_isolation_event(
    outcome: MacWorkspaceActivationResult,
    message: String,
) -> Result<PlatformRuntimeEvent, String> {
    let cleared = || PlatformRuntimeEvent {
        disposition: PlatformRuntimeEventDisposition::Cleared,
        severity: PlatformRuntimeEventSeverity::Warning,
        code: crate::PlatformRuntimeEventCode::PhysicalDisplayIsolation,
        message: None,
    };
    match outcome.isolation_status {
        0 | 1 | 3 => Ok(cleared()),
        2 => Ok(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Warning,
            code: crate::PlatformRuntimeEventCode::PhysicalDisplayIsolation,
            message: Some(if message.is_empty() {
                "physical display isolation is unavailable".to_owned()
            } else {
                message
            }),
        }),
        4 => Err(if message.is_empty() {
            "physical display isolation failed".to_owned()
        } else {
            message
        }),
        status => Err(format!(
            "macOS workspace returned an invalid isolation status {status}"
        )),
    }
}

fn capture_pair_audio_failure(status: i32, error: String) -> Result<Option<String>, String> {
    match status {
        0 => Ok(None),
        2 => Ok(Some(if error.is_empty() {
            "macOS audio capture could not be scheduled".to_owned()
        } else {
            error
        })),
        1 => Err(format!("video capture failed: {error}")),
        _ => Err(format!("capture pair failed: {error}")),
    }
}

fn ready_audio_packet_deadline(
    state: &mut MacSessionState,
    now: Instant,
    packet_bytes: usize,
) -> Option<Instant> {
    let mut deadline = state.next_audio_deadline?;
    if now < deadline || state.pcm.len() < packet_bytes {
        return None;
    }
    if now.duration_since(deadline) > MAXIMUM_AUDIO_CATCHUP {
        state.next_audio_timestamp = audio_timestamp(monotonic_nanoseconds());
        deadline = now;
    }
    Some(deadline)
}

fn desktop_mirror_source_candidate_display_id(
    captures_desktop: bool,
    virtual_display: bool,
    main_display_id: u32,
) -> Result<u32, String> {
    if !captures_desktop || !virtual_display {
        return Ok(0);
    }
    (main_display_id != 0)
        .then_some(main_display_id)
        .ok_or_else(|| "macOS desktop capture has no current source display".to_owned())
}

fn physical_capture_display_id(current_main_display_id: u32) -> Result<u32, String> {
    (current_main_display_id != 0)
        .then_some(current_main_display_id)
        .ok_or_else(|| "macOS physical capture has no current source display".to_owned())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MacCaptureTopology {
    VirtualWorkspace {
        desktop_mirror_source_display_id: u32,
    },
    PhysicalDisplay(u32),
}

fn mac_capture_topology(
    requested_virtual_display: bool,
    desktop_mirror_source_display_id: u32,
    current_main_display_id: u32,
) -> Result<MacCaptureTopology, String> {
    if requested_virtual_display {
        return Ok(MacCaptureTopology::VirtualWorkspace {
            desktop_mirror_source_display_id,
        });
    }
    physical_capture_display_id(current_main_display_id).map(MacCaptureTopology::PhysicalDisplay)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MacDynamicDisplayReconfigurationMode {
    RetainedWorkspace,
    PhysicalCapture,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MacCaptureReconfigurationStep {
    StopCapturePair,
    ReconfigureWorkspace,
    StartCapturePair,
}

fn mac_capture_reconfiguration_steps(
    mode: MacDynamicDisplayReconfigurationMode,
) -> &'static [MacCaptureReconfigurationStep] {
    match mode {
        MacDynamicDisplayReconfigurationMode::RetainedWorkspace => &[
            MacCaptureReconfigurationStep::StopCapturePair,
            MacCaptureReconfigurationStep::ReconfigureWorkspace,
            MacCaptureReconfigurationStep::StartCapturePair,
        ],
        MacDynamicDisplayReconfigurationMode::PhysicalCapture => &[
            MacCaptureReconfigurationStep::StopCapturePair,
            MacCaptureReconfigurationStep::StartCapturePair,
        ],
    }
}

fn mac_reconfigured_display_ids(
    mode: MacDynamicDisplayReconfigurationMode,
    previous_display_id: u32,
    reconfigured_display_id: u32,
) -> (u32, u32) {
    match mode {
        MacDynamicDisplayReconfigurationMode::RetainedWorkspace => {
            (reconfigured_display_id, reconfigured_display_id)
        }
        MacDynamicDisplayReconfigurationMode::PhysicalCapture => {
            (previous_display_id, previous_display_id)
        }
    }
}

fn dynamic_display_reconfiguration_mode(
    previous_virtual_display: bool,
    next_virtual_display: bool,
) -> Result<MacDynamicDisplayReconfigurationMode, String> {
    match (previous_virtual_display, next_virtual_display) {
        (true, true) => Ok(MacDynamicDisplayReconfigurationMode::RetainedWorkspace),
        (false, false) => Ok(MacDynamicDisplayReconfigurationMode::PhysicalCapture),
        _ => Err("dynamic display reconfiguration cannot change the capture topology".to_owned()),
    }
}

fn input_display_id_after_workspace_prepare(
    capture_display_id: u32,
    workspace_prepared: bool,
) -> u32 {
    if !workspace_prepared {
        return 0;
    }
    capture_display_id
}

fn session_epoch_matches(active_session_epoch: Option<u32>, session_epoch: u32) -> bool {
    active_session_epoch == Some(session_epoch)
}

unsafe fn parameter_set(
    codec: i32,
    format: FormatDescription,
    index: usize,
    bytes: *mut *const u8,
    length: *mut usize,
    count: *mut usize,
    nal_length_size: *mut c_int,
) -> i32 {
    if codec == 0 {
        unsafe {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                index,
                bytes,
                length,
                count,
                nal_length_size,
            )
        }
    } else {
        unsafe {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                index,
                bytes,
                length,
                count,
                nal_length_size,
            )
        }
    }
}

fn framework_path() -> Result<PathBuf, String> {
    let executable = std::env::current_exe()
        .map_err(|error| format!("could not locate the Rust host worker: {error}"))?;
    Ok(executable
        .parent()
        .ok_or_else(|| "Rust host worker has no parent directory".to_owned())?
        .join("../Frameworks/LumenMacBridge.framework/LumenMacBridge"))
}

unsafe fn load_symbol<T: Copy>(handle: *mut c_void, name: &[u8]) -> Result<T, String> {
    let symbol = unsafe { dlsym(handle, name.as_ptr().cast()) };
    if symbol.is_null() {
        Err(format!(
            "LumenMacBridge symbol {} is missing: {}",
            String::from_utf8_lossy(&name[..name.len().saturating_sub(1)]),
            dl_error()
        ))
    } else {
        Ok(unsafe { std::mem::transmute_copy(&symbol) })
    }
}

fn dl_error() -> String {
    let error = unsafe { dlerror() };
    if error.is_null() {
        "unknown dynamic-loader error".to_owned()
    } else {
        unsafe { CStr::from_ptr(error) }
            .to_string_lossy()
            .into_owned()
    }
}

fn error_text(buffer: &[c_char]) -> String {
    unsafe { CStr::from_ptr(buffer.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

fn monotonic_nanoseconds() -> u64 {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC_RAW, &mut time) } != 0 {
        0
    } else {
        (time.tv_sec as u64)
            .saturating_mul(1_000_000_000)
            .saturating_add(time.tv_nsec as u64)
    }
}

fn audio_timestamp(nanoseconds: u64) -> u32 {
    ((nanoseconds / 1_000_000_000) * 48_000
        + ((nanoseconds % 1_000_000_000) * 48_000) / 1_000_000_000) as u32
}

#[repr(C)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

const RTLD_LOCAL: c_int = 0x4;
const RTLD_NOW: c_int = 0x2;

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *const c_char;
    fn CGMainDisplayID() -> u32;
    fn CFRelease(value: *const c_void);
    fn CMSampleBufferGetFormatDescription(sample: SampleBuffer) -> FormatDescription;
    fn CMSampleBufferGetDataBuffer(sample: SampleBuffer) -> BlockBuffer;
    fn CMSampleBufferGetPresentationTimeStamp(sample: SampleBuffer) -> CMTime;
    fn CMBlockBufferGetDataLength(buffer: BlockBuffer) -> usize;
    fn CMBlockBufferCopyDataBytes(
        buffer: BlockBuffer,
        offset: usize,
        length: usize,
        destination: *mut c_void,
    ) -> i32;
    fn CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format: FormatDescription,
        index: usize,
        bytes: *mut *const u8,
        length: *mut usize,
        count: *mut usize,
        nal_length_size: *mut c_int,
    ) -> i32;
    fn CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        format: FormatDescription,
        index: usize,
        bytes: *mut *const u8,
        length: *mut usize,
        count: *mut usize,
        nal_length_size: *mut c_int,
    ) -> i32;
}
