use std::ffi::{c_char, c_void, CString};
use std::sync::Mutex;

use lumen_engine::settings::{PrepCommand, ServerCommand};
use lumen_engine::{ApplicationLaunchPlan, LumenSessionOffer};

#[cfg(test)]
use crate::LumenHostPlatformControlFeedbackKind;
use crate::{LumenHostPlatformControlFeedback, PlatformControlFeedback, PlatformNativeInputEvent};

mod application_environment;
#[cfg(target_os = "macos")]
mod macos_native_input;
#[cfg(not(windows))]
mod portable_process;
#[cfg(any(test, windows))]
mod windows;

#[cfg(not(windows))]
use portable_process::PortableApplication;
#[cfg(windows)]
pub(crate) use windows::{
    NativeWindowsLifecycle, NativeWindowsShell, WindowsPlatformSessionControl,
};

const INITIAL_VIDEO_BUFFER_BYTES: usize = 1024 * 1024;
const MAX_VIDEO_BUFFER_BYTES: usize = 32 * 1024 * 1024;
const INITIAL_AUDIO_BUFFER_BYTES: usize = 64 * 1024;
const MAX_AUDIO_BUFFER_BYTES: usize = 1024 * 1024;

const PLATFORM_POLL_ERROR: i32 = -1;
const PLATFORM_POLL_EMPTY: i32 = 0;
const PLATFORM_POLL_READY: i32 = 1;
const PLATFORM_POLL_BUFFER_TOO_SMALL: i32 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlatformVideoCodec {
    H264,
    Hevc,
    Av1,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PlatformApplicationPlan {
    pub application: ApplicationLaunchPlan,
    pub global_prep_commands: Vec<PrepCommand>,
    pub global_state_commands: Vec<PrepCommand>,
    pub server_commands: Vec<ServerCommand>,
    pub width: u32,
    pub height: u32,
    pub frames_per_second: u32,
    pub virtual_display: bool,
    pub session_offer: LumenSessionOffer,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlatformSessionPlan {
    pub width: u32,
    pub height: u32,
    pub frames_per_second: u32,
    pub bitrate_kbps: u32,
    pub video_codec: PlatformVideoCodec,
    pub yuv444: bool,
    pub audio_channels: u8,
    pub enhanced_audio_quality: bool,
    pub play_audio_on_host: bool,
    pub virtual_display: bool,
    pub encoder_csc_mode: u32,
    pub sink_hidpi: bool,
    pub sink_scale_explicit: bool,
    pub sink_mode_is_logical: bool,
    pub sink_scale_percent: i32,
    pub sink_gamut: i32,
    pub sink_transfer: i32,
    pub sink_current_edr_headroom: f32,
    pub sink_potential_edr_headroom: f32,
    pub sink_current_peak_luminance_nits: i32,
    pub sink_potential_peak_luminance_nits: i32,
    pub sink_supports_frame_gated_hdr: bool,
    pub sink_supports_hdr_tile_overlay: bool,
    pub sink_supports_per_frame_hdr_metadata: bool,
    pub negotiated_dynamic_range_transport: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlatformEncodedVideoFrame {
    /// Native encoder access unit. H.264/HEVC adapters emit Annex-B; AV1 emits low-overhead OBU.
    pub payload: Vec<u8>,
    /// Required for AV1 and optional when a native H.264/HEVC adapter exposes its config record.
    pub decoder_configuration_record: Option<Vec<u8>>,
    pub presentation_time_90khz: u32,
    pub key_frame: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlatformEncodedAudioPacket {
    /// One complete Opus packet matching the selected explicit Lumen layout.
    pub payload: Vec<u8>,
    pub presentation_time_48khz: u32,
    pub duration_frames: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PlatformControlEvent {
    RequestIdrFrame,
    InvalidateReferenceFrames { first_frame: i64, last_frame: i64 },
    ResetInput,
    ExecuteServerCommand { index: u8 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlatformRuntimeEventDisposition {
    Raised,
    Cleared,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlatformRuntimeEventSeverity {
    Warning,
    Error,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlatformRuntimeEventCode {
    UpnpGatewayDiscovery,
    UpnpLocalAddressDiscovery,
    UpnpPortMapping,
    UpnpIpv6Pinhole,
    UpnpPortRemoval,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlatformRuntimeEvent {
    pub disposition: PlatformRuntimeEventDisposition,
    pub severity: PlatformRuntimeEventSeverity,
    pub code: PlatformRuntimeEventCode,
    pub message: Option<String>,
}

pub trait PlatformSessionControl: Send + Sync {
    fn start_application(&self, _plan: PlatformApplicationPlan) -> Result<(), String> {
        Ok(())
    }

    fn stop_application(&self) -> Result<(), String> {
        Ok(())
    }

    fn start_session(&self, plan: PlatformSessionPlan) -> Result<(), String>;
    fn stop_session(&self) -> Result<(), String>;

    fn poll_encoded_video(&self) -> Result<Option<PlatformEncodedVideoFrame>, String> {
        Ok(None)
    }

    fn poll_encoded_audio(&self) -> Result<Option<PlatformEncodedAudioPacket>, String> {
        Ok(None)
    }

    fn handle_control_event(
        &self,
        _control_connect_data: u32,
        _event: PlatformControlEvent,
    ) -> Result<(), String> {
        Ok(())
    }

    fn handle_native_input(
        &self,
        _session_epoch: u32,
        _event: PlatformNativeInputEvent,
    ) -> Result<(), String> {
        Err("native v2 input is unavailable on this platform adapter".to_owned())
    }

    fn reset_native_input(&self, session_epoch: u32) -> Result<(), String> {
        self.handle_control_event(session_epoch, PlatformControlEvent::ResetInput)
    }

    fn poll_control_feedback(&self) -> Result<Option<PlatformControlFeedback>, String> {
        Ok(None)
    }

    fn publish_runtime_event(&self, _event: PlatformRuntimeEvent) -> Result<(), String> {
        Ok(())
    }
}

#[derive(Default)]
pub struct IdlePlatformSessionControl;

impl PlatformSessionControl for IdlePlatformSessionControl {
    fn start_session(&self, _plan: PlatformSessionPlan) -> Result<(), String> {
        Ok(())
    }

    fn stop_session(&self) -> Result<(), String> {
        Ok(())
    }

    fn handle_native_input(
        &self,
        _session_epoch: u32,
        _event: PlatformNativeInputEvent,
    ) -> Result<(), String> {
        Ok(())
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostPlatformVideoCodec {
    H264 = 0,
    Hevc = 1,
    Av1 = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LumenHostPlatformSessionPlan {
    pub width: u32,
    pub height: u32,
    pub frames_per_second: u32,
    pub bitrate_kbps: u32,
    pub video_codec: LumenHostPlatformVideoCodec,
    pub yuv444: bool,
    pub audio_channels: u8,
    pub enhanced_audio_quality: bool,
    pub play_audio_on_host: bool,
    pub virtual_display: bool,
    pub encoder_csc_mode: u32,
    pub sink_hidpi: bool,
    pub sink_scale_explicit: bool,
    pub sink_mode_is_logical: bool,
    pub sink_scale_percent: i32,
    pub sink_gamut: i32,
    pub sink_transfer: i32,
    pub sink_current_edr_headroom: f32,
    pub sink_potential_edr_headroom: f32,
    pub sink_current_peak_luminance_nits: i32,
    pub sink_potential_peak_luminance_nits: i32,
    pub sink_supports_frame_gated_hdr: bool,
    pub sink_supports_hdr_tile_overlay: bool,
    pub sink_supports_per_frame_hdr_metadata: bool,
    pub negotiated_dynamic_range_transport: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenHostPlatformEncodedVideoFrame {
    pub payload_size: usize,
    pub presentation_time_90khz: u32,
    pub key_frame: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenHostPlatformEncodedAudioPacket {
    pub payload_size: usize,
    pub presentation_time_48khz: u32,
    pub duration_frames: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostPlatformControlEventKind {
    RequestIdrFrame = 0,
    InvalidateReferenceFrames = 1,
    ResetInput = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenHostPlatformControlEvent {
    pub kind: LumenHostPlatformControlEventKind,
    pub control_connect_data: u32,
    pub first_frame: i64,
    pub last_frame: i64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostPlatformRuntimeEventDisposition {
    Raised = 0,
    Cleared = 1,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostPlatformRuntimeEventSeverity {
    Warning = 0,
    Error = 1,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostPlatformRuntimeEventCode {
    UpnpGatewayDiscovery = 0,
    UpnpLocalAddressDiscovery = 1,
    UpnpPortMapping = 2,
    UpnpIpv6Pinhole = 3,
    UpnpPortRemoval = 4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenHostPlatformRuntimeEvent {
    pub disposition: LumenHostPlatformRuntimeEventDisposition,
    pub severity: LumenHostPlatformRuntimeEventSeverity,
    pub code: LumenHostPlatformRuntimeEventCode,
    pub message: *const c_char,
}

impl From<PlatformSessionPlan> for LumenHostPlatformSessionPlan {
    fn from(plan: PlatformSessionPlan) -> Self {
        Self {
            width: plan.width,
            height: plan.height,
            frames_per_second: plan.frames_per_second,
            bitrate_kbps: plan.bitrate_kbps,
            video_codec: match plan.video_codec {
                PlatformVideoCodec::H264 => LumenHostPlatformVideoCodec::H264,
                PlatformVideoCodec::Hevc => LumenHostPlatformVideoCodec::Hevc,
                PlatformVideoCodec::Av1 => LumenHostPlatformVideoCodec::Av1,
            },
            yuv444: plan.yuv444,
            audio_channels: plan.audio_channels,
            enhanced_audio_quality: plan.enhanced_audio_quality,
            play_audio_on_host: plan.play_audio_on_host,
            virtual_display: plan.virtual_display,
            encoder_csc_mode: plan.encoder_csc_mode,
            sink_hidpi: plan.sink_hidpi,
            sink_scale_explicit: plan.sink_scale_explicit,
            sink_mode_is_logical: plan.sink_mode_is_logical,
            sink_scale_percent: plan.sink_scale_percent,
            sink_gamut: plan.sink_gamut,
            sink_transfer: plan.sink_transfer,
            sink_current_edr_headroom: plan.sink_current_edr_headroom,
            sink_potential_edr_headroom: plan.sink_potential_edr_headroom,
            sink_current_peak_luminance_nits: plan.sink_current_peak_luminance_nits,
            sink_potential_peak_luminance_nits: plan.sink_potential_peak_luminance_nits,
            sink_supports_frame_gated_hdr: plan.sink_supports_frame_gated_hdr,
            sink_supports_hdr_tile_overlay: plan.sink_supports_hdr_tile_overlay,
            sink_supports_per_frame_hdr_metadata: plan.sink_supports_per_frame_hdr_metadata,
            negotiated_dynamic_range_transport: plan.negotiated_dynamic_range_transport,
        }
    }
}

pub type LumenHostPlatformStartSessionCallback =
    unsafe extern "C" fn(*mut c_void, *const LumenHostPlatformSessionPlan) -> i32;
pub type LumenHostPlatformStopSessionCallback = unsafe extern "C" fn(*mut c_void) -> i32;
pub type LumenHostPlatformPollEncodedVideoCallback = unsafe extern "C" fn(
    *mut c_void,
    *mut u8,
    usize,
    *mut LumenHostPlatformEncodedVideoFrame,
) -> i32;
pub type LumenHostPlatformPollEncodedAudioCallback = unsafe extern "C" fn(
    *mut c_void,
    *mut u8,
    usize,
    *mut LumenHostPlatformEncodedAudioPacket,
) -> i32;
pub type LumenHostPlatformHandleControlEventCallback =
    unsafe extern "C" fn(*mut c_void, *const LumenHostPlatformControlEvent) -> i32;
pub type LumenHostPlatformPollControlFeedbackCallback =
    unsafe extern "C" fn(*mut c_void, *mut LumenHostPlatformControlFeedback) -> i32;
pub type LumenHostPlatformPublishRuntimeEventCallback =
    unsafe extern "C" fn(*mut c_void, *const LumenHostPlatformRuntimeEvent) -> i32;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct LumenHostPlatformCallbacks {
    pub context: *mut c_void,
    pub start_session: Option<LumenHostPlatformStartSessionCallback>,
    pub stop_session: Option<LumenHostPlatformStopSessionCallback>,
    pub poll_encoded_video: Option<LumenHostPlatformPollEncodedVideoCallback>,
    pub poll_encoded_audio: Option<LumenHostPlatformPollEncodedAudioCallback>,
    pub handle_control_event: Option<LumenHostPlatformHandleControlEventCallback>,
    pub poll_control_feedback: Option<LumenHostPlatformPollControlFeedbackCallback>,
    pub publish_runtime_event: Option<LumenHostPlatformPublishRuntimeEventCallback>,
}

pub(crate) struct CallbackPlatformSessionControl {
    callbacks: LumenHostPlatformCallbacks,
    video_buffer: Mutex<Vec<u8>>,
    audio_buffer: Mutex<Vec<u8>>,
    #[cfg(not(windows))]
    application: PortableApplication,
    #[cfg(target_os = "macos")]
    native_input: macos_native_input::MacNativeInput,
}

unsafe impl Send for CallbackPlatformSessionControl {}
unsafe impl Sync for CallbackPlatformSessionControl {}

impl CallbackPlatformSessionControl {
    pub(crate) fn new(callbacks: LumenHostPlatformCallbacks) -> Result<Self, String> {
        if callbacks.start_session.is_none()
            || callbacks.stop_session.is_none()
            || callbacks.poll_encoded_video.is_none()
            || callbacks.poll_encoded_audio.is_none()
            || callbacks.handle_control_event.is_none()
            || callbacks.poll_control_feedback.is_none()
            || callbacks.publish_runtime_event.is_none()
        {
            Err("platform session callbacks are incomplete".to_owned())
        } else {
            Ok(Self {
                callbacks,
                video_buffer: Mutex::new(vec![0; INITIAL_VIDEO_BUFFER_BYTES]),
                audio_buffer: Mutex::new(vec![0; INITIAL_AUDIO_BUFFER_BYTES]),
                #[cfg(not(windows))]
                application: PortableApplication::default(),
                #[cfg(target_os = "macos")]
                native_input: macos_native_input::MacNativeInput::default(),
            })
        }
    }
}

impl PlatformSessionControl for CallbackPlatformSessionControl {
    #[cfg(not(windows))]
    fn start_application(&self, plan: PlatformApplicationPlan) -> Result<(), String> {
        self.application.start(plan)
    }

    #[cfg(not(windows))]
    fn stop_application(&self) -> Result<(), String> {
        self.application.stop()
    }

    fn start_session(&self, plan: PlatformSessionPlan) -> Result<(), String> {
        let callback = self
            .callbacks
            .start_session
            .ok_or_else(|| "platform start callback is missing".to_owned())?;
        let plan = LumenHostPlatformSessionPlan::from(plan);
        let status = unsafe { callback(self.callbacks.context, &plan) };
        if status == 0 {
            Ok(())
        } else {
            Err(format!(
                "platform start callback failed with status {status}"
            ))
        }
    }

    fn stop_session(&self) -> Result<(), String> {
        let callback = self
            .callbacks
            .stop_session
            .ok_or_else(|| "platform stop callback is missing".to_owned())?;
        let status = unsafe { callback(self.callbacks.context) };
        if status == 0 {
            Ok(())
        } else {
            Err(format!(
                "platform stop callback failed with status {status}"
            ))
        }
    }

    fn poll_encoded_video(&self) -> Result<Option<PlatformEncodedVideoFrame>, String> {
        let callback = self
            .callbacks
            .poll_encoded_video
            .ok_or_else(|| "platform video poll callback is missing".to_owned())?;
        let mut buffer = self
            .video_buffer
            .lock()
            .map_err(|_| "platform video poll buffer is unavailable".to_owned())?;
        let (payload, metadata) =
            poll_video_callback(callback, self.callbacks.context, &mut buffer)?;
        Ok(payload.map(|payload| PlatformEncodedVideoFrame {
            payload,
            decoder_configuration_record: None,
            presentation_time_90khz: metadata.presentation_time_90khz,
            key_frame: metadata.key_frame,
        }))
    }

    fn poll_encoded_audio(&self) -> Result<Option<PlatformEncodedAudioPacket>, String> {
        let callback = self
            .callbacks
            .poll_encoded_audio
            .ok_or_else(|| "platform audio poll callback is missing".to_owned())?;
        let mut buffer = self
            .audio_buffer
            .lock()
            .map_err(|_| "platform audio poll buffer is unavailable".to_owned())?;
        let (payload, metadata) =
            poll_audio_callback(callback, self.callbacks.context, &mut buffer)?;
        Ok(payload.map(|payload| PlatformEncodedAudioPacket {
            payload,
            presentation_time_48khz: metadata.presentation_time_48khz,
            duration_frames: metadata.duration_frames,
        }))
    }

    fn handle_control_event(
        &self,
        control_connect_data: u32,
        event: PlatformControlEvent,
    ) -> Result<(), String> {
        if let PlatformControlEvent::ExecuteServerCommand { index } = event {
            #[cfg(not(windows))]
            return self.application.execute_server_command(index);
            #[cfg(windows)]
            {
                let _ = index;
                return Err(
                    "server command execution is unavailable on this callback platform".to_owned(),
                );
            }
        }
        let callback = self
            .callbacks
            .handle_control_event
            .ok_or_else(|| "platform control event callback is missing".to_owned())?;
        let event = match &event {
            PlatformControlEvent::RequestIdrFrame => LumenHostPlatformControlEvent {
                kind: LumenHostPlatformControlEventKind::RequestIdrFrame,
                control_connect_data,
                first_frame: 0,
                last_frame: 0,
            },
            PlatformControlEvent::InvalidateReferenceFrames {
                first_frame,
                last_frame,
            } => LumenHostPlatformControlEvent {
                kind: LumenHostPlatformControlEventKind::InvalidateReferenceFrames,
                control_connect_data,
                first_frame: *first_frame,
                last_frame: *last_frame,
            },
            PlatformControlEvent::ResetInput => LumenHostPlatformControlEvent {
                kind: LumenHostPlatformControlEventKind::ResetInput,
                control_connect_data,
                first_frame: 0,
                last_frame: 0,
            },
            PlatformControlEvent::ExecuteServerCommand { .. } => unreachable!(),
        };
        let status = unsafe { callback(self.callbacks.context, &event) };
        if status == 0 {
            Ok(())
        } else {
            Err(format!(
                "platform control event callback failed with status {status}"
            ))
        }
    }

    #[cfg(target_os = "macos")]
    fn handle_native_input(
        &self,
        session_epoch: u32,
        event: PlatformNativeInputEvent,
    ) -> Result<(), String> {
        self.native_input.handle(session_epoch, event)
    }

    #[cfg(target_os = "macos")]
    fn reset_native_input(&self, session_epoch: u32) -> Result<(), String> {
        self.native_input.reset(session_epoch)
    }

    fn poll_control_feedback(&self) -> Result<Option<PlatformControlFeedback>, String> {
        let callback = self
            .callbacks
            .poll_control_feedback
            .ok_or_else(|| "platform control feedback callback is missing".to_owned())?;
        let mut feedback = std::mem::MaybeUninit::<LumenHostPlatformControlFeedback>::uninit();
        let status = unsafe { callback(self.callbacks.context, feedback.as_mut_ptr()) };
        match status {
            PLATFORM_POLL_EMPTY => Ok(None),
            PLATFORM_POLL_READY => Ok(Some(PlatformControlFeedback::from(unsafe {
                feedback.assume_init()
            }))),
            PLATFORM_POLL_ERROR => Err("platform control feedback poll failed".to_owned()),
            other => Err(format!(
                "platform control feedback poll returned invalid status {other}"
            )),
        }
    }

    fn publish_runtime_event(&self, event: PlatformRuntimeEvent) -> Result<(), String> {
        let callback = self
            .callbacks
            .publish_runtime_event
            .ok_or_else(|| "platform runtime event callback is missing".to_owned())?;
        let message = event
            .message
            .map(CString::new)
            .transpose()
            .map_err(|_| "platform runtime event message contains a null byte".to_owned())?;
        let event = LumenHostPlatformRuntimeEvent {
            disposition: match event.disposition {
                PlatformRuntimeEventDisposition::Raised => {
                    LumenHostPlatformRuntimeEventDisposition::Raised
                }
                PlatformRuntimeEventDisposition::Cleared => {
                    LumenHostPlatformRuntimeEventDisposition::Cleared
                }
            },
            severity: match event.severity {
                PlatformRuntimeEventSeverity::Warning => {
                    LumenHostPlatformRuntimeEventSeverity::Warning
                }
                PlatformRuntimeEventSeverity::Error => LumenHostPlatformRuntimeEventSeverity::Error,
            },
            code: match event.code {
                PlatformRuntimeEventCode::UpnpGatewayDiscovery => {
                    LumenHostPlatformRuntimeEventCode::UpnpGatewayDiscovery
                }
                PlatformRuntimeEventCode::UpnpLocalAddressDiscovery => {
                    LumenHostPlatformRuntimeEventCode::UpnpLocalAddressDiscovery
                }
                PlatformRuntimeEventCode::UpnpPortMapping => {
                    LumenHostPlatformRuntimeEventCode::UpnpPortMapping
                }
                PlatformRuntimeEventCode::UpnpIpv6Pinhole => {
                    LumenHostPlatformRuntimeEventCode::UpnpIpv6Pinhole
                }
                PlatformRuntimeEventCode::UpnpPortRemoval => {
                    LumenHostPlatformRuntimeEventCode::UpnpPortRemoval
                }
            },
            message: message
                .as_ref()
                .map_or(std::ptr::null(), |message| message.as_ptr()),
        };
        let status = unsafe { callback(self.callbacks.context, &event) };
        if status == 0 {
            Ok(())
        } else {
            Err(format!(
                "platform runtime event callback failed with status {status}"
            ))
        }
    }
}

fn poll_video_callback(
    callback: LumenHostPlatformPollEncodedVideoCallback,
    context: *mut c_void,
    payload: &mut Vec<u8>,
) -> Result<(Option<Vec<u8>>, LumenHostPlatformEncodedVideoFrame), String> {
    let mut metadata = LumenHostPlatformEncodedVideoFrame::default();
    let status = unsafe { callback(context, payload.as_mut_ptr(), payload.len(), &mut metadata) };
    if status == PLATFORM_POLL_EMPTY {
        return Ok((None, metadata));
    }
    if status == PLATFORM_POLL_BUFFER_TOO_SMALL {
        resize_poll_buffer(
            payload,
            metadata.payload_size,
            MAX_VIDEO_BUFFER_BYTES,
            "video",
        )?;
        metadata = LumenHostPlatformEncodedVideoFrame::default();
        let retry =
            unsafe { callback(context, payload.as_mut_ptr(), payload.len(), &mut metadata) };
        return finish_video_poll(retry, payload, metadata);
    }
    finish_video_poll(status, payload, metadata)
}

fn finish_video_poll(
    status: i32,
    payload: &[u8],
    metadata: LumenHostPlatformEncodedVideoFrame,
) -> Result<(Option<Vec<u8>>, LumenHostPlatformEncodedVideoFrame), String> {
    match status {
        PLATFORM_POLL_EMPTY => Ok((None, metadata)),
        PLATFORM_POLL_READY if metadata.payload_size == 0 => {
            Err("platform video poll returned an empty frame".to_owned())
        }
        PLATFORM_POLL_READY if metadata.payload_size <= payload.len() => {
            Ok((Some(payload[..metadata.payload_size].to_vec()), metadata))
        }
        PLATFORM_POLL_READY => {
            Err("platform video poll exceeded its destination buffer".to_owned())
        }
        PLATFORM_POLL_BUFFER_TOO_SMALL => {
            Err("platform video frame size changed during a bounded retry".to_owned())
        }
        PLATFORM_POLL_ERROR => Err("platform video poll failed".to_owned()),
        status => Err(format!(
            "platform video poll returned invalid status {status}"
        )),
    }
}

fn poll_audio_callback(
    callback: LumenHostPlatformPollEncodedAudioCallback,
    context: *mut c_void,
    payload: &mut Vec<u8>,
) -> Result<(Option<Vec<u8>>, LumenHostPlatformEncodedAudioPacket), String> {
    let mut metadata = LumenHostPlatformEncodedAudioPacket::default();
    let status = unsafe { callback(context, payload.as_mut_ptr(), payload.len(), &mut metadata) };
    if status == PLATFORM_POLL_EMPTY {
        return Ok((None, metadata));
    }
    if status == PLATFORM_POLL_BUFFER_TOO_SMALL {
        resize_poll_buffer(
            payload,
            metadata.payload_size,
            MAX_AUDIO_BUFFER_BYTES,
            "audio",
        )?;
        metadata = LumenHostPlatformEncodedAudioPacket::default();
        let retry =
            unsafe { callback(context, payload.as_mut_ptr(), payload.len(), &mut metadata) };
        return finish_audio_poll(retry, payload, metadata);
    }
    finish_audio_poll(status, payload, metadata)
}

fn finish_audio_poll(
    status: i32,
    payload: &[u8],
    metadata: LumenHostPlatformEncodedAudioPacket,
) -> Result<(Option<Vec<u8>>, LumenHostPlatformEncodedAudioPacket), String> {
    match status {
        PLATFORM_POLL_EMPTY => Ok((None, metadata)),
        PLATFORM_POLL_READY if metadata.payload_size == 0 || metadata.duration_frames == 0 => {
            Err("platform audio poll returned an empty packet".to_owned())
        }
        PLATFORM_POLL_READY if metadata.payload_size <= payload.len() => {
            Ok((Some(payload[..metadata.payload_size].to_vec()), metadata))
        }
        PLATFORM_POLL_READY => {
            Err("platform audio poll exceeded its destination buffer".to_owned())
        }
        PLATFORM_POLL_BUFFER_TOO_SMALL => {
            Err("platform audio packet size changed during a bounded retry".to_owned())
        }
        PLATFORM_POLL_ERROR => Err("platform audio poll failed".to_owned()),
        status => Err(format!(
            "platform audio poll returned invalid status {status}"
        )),
    }
}

fn resize_poll_buffer(
    payload: &mut Vec<u8>,
    required: usize,
    maximum: usize,
    kind: &str,
) -> Result<(), String> {
    if required <= payload.len() || required > maximum {
        return Err(format!(
            "platform {kind} poll requested invalid buffer size {required}"
        ));
    }
    payload.resize(required, 0);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    static STARTS: AtomicUsize = AtomicUsize::new(0);
    static STOPS: AtomicUsize = AtomicUsize::new(0);
    static FEEDBACK_READY: AtomicBool = AtomicBool::new(false);
    static CONTROL_EVENTS: Mutex<Vec<LumenHostPlatformControlEvent>> = Mutex::new(Vec::new());
    static RUNTIME_EVENTS: Mutex<Vec<RecordedRuntimeEvent>> = Mutex::new(Vec::new());

    #[derive(Debug, Eq, PartialEq)]
    struct RecordedRuntimeEvent {
        disposition: LumenHostPlatformRuntimeEventDisposition,
        severity: LumenHostPlatformRuntimeEventSeverity,
        code: LumenHostPlatformRuntimeEventCode,
        message: Option<String>,
    }

    unsafe extern "C" fn start(
        _context: *mut c_void,
        plan: *const LumenHostPlatformSessionPlan,
    ) -> i32 {
        let plan = unsafe { *plan };
        assert_eq!(plan.video_codec, LumenHostPlatformVideoCodec::Hevc);
        assert_eq!(plan.audio_channels, 8);
        STARTS.fetch_add(1, Ordering::Relaxed);
        0
    }

    unsafe extern "C" fn stop(_context: *mut c_void) -> i32 {
        STOPS.fetch_add(1, Ordering::Relaxed);
        0
    }

    unsafe extern "C" fn poll_video(
        _context: *mut c_void,
        destination: *mut u8,
        destination_capacity: usize,
        frame: *mut LumenHostPlatformEncodedVideoFrame,
    ) -> i32 {
        const PAYLOAD: &[u8] = b"annex-b-video";
        unsafe {
            (*frame).payload_size = PAYLOAD.len();
            (*frame).presentation_time_90khz = 90_000;
            (*frame).key_frame = true;
        }
        if destination_capacity < PAYLOAD.len() {
            return PLATFORM_POLL_BUFFER_TOO_SMALL;
        }
        unsafe { std::ptr::copy_nonoverlapping(PAYLOAD.as_ptr(), destination, PAYLOAD.len()) };
        PLATFORM_POLL_READY
    }

    unsafe extern "C" fn poll_audio(
        _context: *mut c_void,
        destination: *mut u8,
        destination_capacity: usize,
        packet: *mut LumenHostPlatformEncodedAudioPacket,
    ) -> i32 {
        const PAYLOAD: &[u8] = b"opus";
        unsafe {
            (*packet).payload_size = PAYLOAD.len();
            (*packet).presentation_time_48khz = 240;
            (*packet).duration_frames = 240;
        }
        if destination_capacity < PAYLOAD.len() {
            return PLATFORM_POLL_BUFFER_TOO_SMALL;
        }
        unsafe { std::ptr::copy_nonoverlapping(PAYLOAD.as_ptr(), destination, PAYLOAD.len()) };
        PLATFORM_POLL_READY
    }

    unsafe extern "C" fn handle_control_event(
        _context: *mut c_void,
        event: *const LumenHostPlatformControlEvent,
    ) -> i32 {
        let event = unsafe { *event };
        CONTROL_EVENTS.lock().unwrap().push(event);
        0
    }

    unsafe extern "C" fn poll_control_feedback(
        _context: *mut c_void,
        feedback: *mut LumenHostPlatformControlFeedback,
    ) -> i32 {
        if feedback.is_null() {
            return PLATFORM_POLL_ERROR;
        }
        if !FEEDBACK_READY.swap(false, Ordering::AcqRel) {
            return PLATFORM_POLL_EMPTY;
        }
        unsafe {
            *feedback = LumenHostPlatformControlFeedback {
                kind: LumenHostPlatformControlFeedbackKind::Rumble,
                control_connect_data: 66_051,
                controller_id: 2,
                value_a: 3,
                value_b: 4,
                report_rate: 0,
                motion_type: 0,
                red: 0,
                green: 0,
                blue: 0,
                event_flags: 0,
                type_left: 0,
                type_right: 0,
                left: [0; 10],
                right: [0; 10],
            };
        }
        PLATFORM_POLL_READY
    }

    unsafe extern "C" fn publish_runtime_event(
        _context: *mut c_void,
        event: *const LumenHostPlatformRuntimeEvent,
    ) -> i32 {
        let event = unsafe { &*event };
        let message = (!event.message.is_null()).then(|| {
            unsafe { CStr::from_ptr(event.message) }
                .to_string_lossy()
                .into_owned()
        });
        RUNTIME_EVENTS.lock().unwrap().push(RecordedRuntimeEvent {
            disposition: event.disposition,
            severity: event.severity,
            code: event.code,
            message,
        });
        0
    }

    fn callbacks() -> LumenHostPlatformCallbacks {
        LumenHostPlatformCallbacks {
            context: std::ptr::null_mut(),
            start_session: Some(start),
            stop_session: Some(stop),
            poll_encoded_video: Some(poll_video),
            poll_encoded_audio: Some(poll_audio),
            handle_control_event: Some(handle_control_event),
            poll_control_feedback: Some(poll_control_feedback),
            publish_runtime_event: Some(publish_runtime_event),
        }
    }

    #[test]
    fn callback_adapter_forwards_one_typed_session_plan() {
        STARTS.store(0, Ordering::Relaxed);
        STOPS.store(0, Ordering::Relaxed);
        let adapter = CallbackPlatformSessionControl::new(callbacks()).unwrap();
        adapter
            .start_session(PlatformSessionPlan {
                width: 3_512,
                height: 2_290,
                frames_per_second: 120,
                bitrate_kbps: 80_000,
                video_codec: PlatformVideoCodec::Hevc,
                yuv444: false,
                audio_channels: 8,
                enhanced_audio_quality: true,
                play_audio_on_host: false,
                virtual_display: true,
                encoder_csc_mode: 2,
                sink_hidpi: true,
                sink_scale_explicit: true,
                sink_mode_is_logical: true,
                sink_scale_percent: 200,
                sink_gamut: 2,
                sink_transfer: 2,
                sink_current_edr_headroom: 2.4,
                sink_potential_edr_headroom: 16.0,
                sink_current_peak_luminance_nits: 240,
                sink_potential_peak_luminance_nits: 1_600,
                sink_supports_frame_gated_hdr: true,
                sink_supports_hdr_tile_overlay: false,
                sink_supports_per_frame_hdr_metadata: true,
                negotiated_dynamic_range_transport: 3,
            })
            .unwrap();
        adapter.stop_session().unwrap();
        assert_eq!(
            adapter.poll_encoded_video().unwrap().unwrap(),
            PlatformEncodedVideoFrame {
                payload: b"annex-b-video".to_vec(),
                decoder_configuration_record: None,
                presentation_time_90khz: 90_000,
                key_frame: true,
            }
        );
        assert_eq!(
            adapter.poll_encoded_audio().unwrap().unwrap(),
            PlatformEncodedAudioPacket {
                payload: b"opus".to_vec(),
                presentation_time_48khz: 240,
                duration_frames: 240,
            }
        );
        assert_eq!(STARTS.load(Ordering::Relaxed), 1);
        assert_eq!(STOPS.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn callback_adapter_forwards_typed_control_events() {
        CONTROL_EVENTS.lock().unwrap().clear();
        RUNTIME_EVENTS.lock().unwrap().clear();
        let adapter = CallbackPlatformSessionControl::new(callbacks()).unwrap();
        adapter
            .handle_control_event(66_051, PlatformControlEvent::RequestIdrFrame)
            .unwrap();
        adapter
            .handle_control_event(
                66_051,
                PlatformControlEvent::InvalidateReferenceFrames {
                    first_frame: 7,
                    last_frame: 11,
                },
            )
            .unwrap();
        adapter
            .handle_control_event(66_051, PlatformControlEvent::ResetInput)
            .unwrap();
        let events = CONTROL_EVENTS.lock().unwrap();
        assert_eq!(events.len(), 3);
        assert!(events
            .iter()
            .all(|event| event.control_connect_data == 66_051));
        assert_eq!(
            events[0].kind,
            LumenHostPlatformControlEventKind::RequestIdrFrame
        );
        assert_eq!(events[1].first_frame, 7);
        assert_eq!(events[1].last_frame, 11);
        assert_eq!(
            events[2].kind,
            LumenHostPlatformControlEventKind::ResetInput
        );
        drop(events);
        FEEDBACK_READY.store(true, Ordering::Release);
        assert_eq!(
            adapter.poll_control_feedback().unwrap(),
            Some(PlatformControlFeedback::Rumble {
                control_connect_data: 66_051,
                controller_id: 2,
                low_frequency: 3,
                high_frequency: 4,
            })
        );
        assert_eq!(adapter.poll_control_feedback().unwrap(), None);
        adapter
            .publish_runtime_event(PlatformRuntimeEvent {
                disposition: PlatformRuntimeEventDisposition::Raised,
                severity: PlatformRuntimeEventSeverity::Warning,
                code: PlatformRuntimeEventCode::UpnpPortMapping,
                message: Some("UDP 47998 is already mapped".to_owned()),
            })
            .unwrap();
        adapter
            .publish_runtime_event(PlatformRuntimeEvent {
                disposition: PlatformRuntimeEventDisposition::Cleared,
                severity: PlatformRuntimeEventSeverity::Warning,
                code: PlatformRuntimeEventCode::UpnpPortMapping,
                message: None,
            })
            .unwrap();
        assert_eq!(
            *RUNTIME_EVENTS.lock().unwrap(),
            vec![
                RecordedRuntimeEvent {
                    disposition: LumenHostPlatformRuntimeEventDisposition::Raised,
                    severity: LumenHostPlatformRuntimeEventSeverity::Warning,
                    code: LumenHostPlatformRuntimeEventCode::UpnpPortMapping,
                    message: Some("UDP 47998 is already mapped".to_owned()),
                },
                RecordedRuntimeEvent {
                    disposition: LumenHostPlatformRuntimeEventDisposition::Cleared,
                    severity: LumenHostPlatformRuntimeEventSeverity::Warning,
                    code: LumenHostPlatformRuntimeEventCode::UpnpPortMapping,
                    message: None,
                },
            ]
        );
    }

    #[test]
    fn rejects_incomplete_callback_tables() {
        assert!(
            CallbackPlatformSessionControl::new(LumenHostPlatformCallbacks {
                start_session: None,
                ..callbacks()
            })
            .is_err()
        );
    }

    #[test]
    fn retries_one_oversized_frame_without_crossing_the_abi_allocation_boundary() {
        let mut buffer = vec![0; 2];
        let (payload, metadata) =
            poll_video_callback(poll_video, std::ptr::null_mut(), &mut buffer).unwrap();
        assert_eq!(payload.unwrap(), b"annex-b-video");
        assert_eq!(metadata.payload_size, b"annex-b-video".len());
        assert_eq!(buffer.len(), b"annex-b-video".len());
    }

    #[test]
    fn rejects_unbounded_or_inconsistent_callback_sizes() {
        assert!(resize_poll_buffer(&mut vec![0; 4], 4, 8, "video").is_err());
        assert!(resize_poll_buffer(&mut vec![0; 4], 9, 8, "video").is_err());
        assert!(finish_video_poll(
            PLATFORM_POLL_READY,
            &[0; 4],
            LumenHostPlatformEncodedVideoFrame {
                payload_size: 5,
                ..Default::default()
            }
        )
        .is_err());
    }
}
