use std::collections::{BTreeSet, VecDeque};
use std::ffi::{c_char, CStr};
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::ptr::NonNull;

mod application;
mod audio_ingress;
mod audio_selection;
mod audio_sink;
mod audio_stream;
mod auth;
mod device;
mod external_ingress;
mod file_store;
mod host_identity;
mod host_runtime;
mod launch_request;
mod network_policy;
mod owner;
mod protocol;
mod session_registry;
pub mod settings;
mod settings_ffi;
mod stream_fleet;
mod stream_session;
mod video_codec;
mod video_colorspace;
mod video_packetization;
mod video_rate;
mod video_timing;

pub use application::{
    ApplicationCatalog, ApplicationCommandPlan, ApplicationDescriptor, ApplicationLaunchPlan,
    CatalogError,
};
pub use audio_selection::{
    resolve_audio_selection, LumenAudioChannelMode, LumenAudioSelectionPlan,
    LumenAudioSelectionRequest, AUDIO_CHANNEL_MODE_WIRE_VALUES, AUDIO_PACKET_DURATION_MILLISECONDS,
    ENHANCED_AUDIO_QUALITY_SUPPORTED,
};
pub use audio_sink::{
    resolve_audio_sink, LumenAudioSinkPlan, LumenAudioSinkRequest, AUDIO_SINK_CONFIGURED,
    AUDIO_SINK_HOST, AUDIO_SINK_UNAVAILABLE,
};
pub use audio_stream::{
    resolve_audio_stream, LumenAudioStreamPlan, LumenAudioStreamRequest, AUDIO_OPUS_APPLICATION,
    AUDIO_SAMPLE_RATE, AUDIO_VARIABLE_BITRATE,
};
pub use auth::{
    AccessCredentialResult, AccessTokenVerificationRequest, AuthAuthority, AuthChallenge,
    AuthChallengePurpose, AuthErrorCode, AuthErrorDetail, AuthErrorEnvelope, AuthHttpOperation,
    AuthHttpResponse, AuthRequestEnvelope, AuthSignatureAlgorithm, AuthSuccessEnvelope,
    AuthorizationResult, DeviceRevocationRequest, DeviceRevocationResult,
    EnrollmentChallengeRequest, EnrollmentRequest, EnrollmentResult, LumenAuthAuthority,
    LumenAuthHttpResponse, RefreshChallengeRequest, RefreshExchangeRequest,
    AUTH_ACCESS_TOKEN_LIFETIME_SECONDS, AUTH_CHALLENGE_LIFETIME_SECONDS, AUTH_SCHEMA_VERSION,
};
pub use host_identity::{HostIdentityAuthority, HostIdentityError};
pub use launch_request::{
    lumen_engine_parse_launch_request, parse_launch_request, LaunchDisplayMode, LaunchRequestError,
    LaunchRequestErrorCode, LumenLaunchQueryField, LumenLaunchRequest, LumenLaunchRequestPlan,
};
pub use network_policy::{classify_network_address, NETWORK_LAN, NETWORK_PC, NETWORK_WAN};
pub use owner::{LumenOwnerState, OwnerAccountError, OwnerAccountStore};
pub use protocol::{
    client_control_envelope, client_input_envelope, client_motion_envelope,
    decode_client_control_message, decode_client_input_message, decode_host_control_message,
    decode_host_input_message, decode_native_media_datagram, decode_native_video_access_unit,
    dynamic_range_transport_name, encode_client_control_message, encode_client_input_message,
    encode_codec_configuration_message, encode_host_control_message, encode_host_input_message,
    encode_native_media_header, encode_native_media_header_with_fec_block,
    encode_native_video_access_unit_descriptor, host_control_envelope, host_input_envelope,
    negotiate_native_session, parse_session_offer, resolve_video_transport, ClientControlEnvelope,
    ClientInputEnvelope, ClientMotionEnvelope, ClientSessionHello, CodecConfiguration,
    CodecConfigurationAck, DecodedNativeMediaDatagram, HostControlEnvelope, HostInputEnvelope,
    HostSessionCapabilities, HostSessionPlan, LumenSessionOffer, LumenSinkTransportPlan,
    LumenSinkTransportRequest, MediaPathChallenge, MediaPathResponse, MediaPathValidated,
    NativeAudioChannelMode, NativeAudioQuality, NativeChromaSubsampling, NativeColorRange,
    NativeContactPhase, NativeControlWireError, NativeDisplayGamut, NativeDisplayTransfer,
    NativeDynamicRange, NativeFecBlockExtension, NativeGamepadButton, NativeGamepadButtonInput,
    NativeGamepadConnectionInput, NativeGamepadMotionInput, NativeInputAck, NativeInputReset,
    NativeInputWireError, NativeKeyboardInput, NativeMediaHeader, NativeMediaKind,
    NativeNegotiationFailure, NativePenContactInput, NativePenMotionInput,
    NativePointerButtonInput, NativePointerMotionInput, NativePointerMotionMode, NativePolicyMode,
    NativeProtocolError, NativeRumbleAck, NativeRumbleCommand, NativeScrollInput,
    NativeSessionError, NativeTextInput, NativeTouchContactInput, NativeTouchMotionInput,
    NativeTransportError, NativeVideoAccessUnitDescriptor, NativeVideoCapability, NativeVideoCodec,
    NativeVideoFormat, NativeVideoProfile, SessionStarted, SessionStopped, StartSessionAck,
    StopSession, LUMEN_STREAMING_DESCRIPTOR_SHA256, LUMEN_STREAMING_EXPORTER_LABEL,
    LUMEN_STREAMING_PROTOCOL_ALPN, LUMEN_STREAMING_PROTOCOL_PACKAGE, LUMEN_STREAMING_SCHEMA_SHA256,
    NATIVE_AUDIO_STREAM_ID, NATIVE_CONTROL_MESSAGE_LIMIT, NATIVE_FEC_BLOCK_EXTENSION_BYTES,
    NATIVE_FEC_BLOCK_HEADER_BYTES, NATIVE_INITIAL_CONFIGURATION_ID, NATIVE_INPUT_MESSAGE_LIMIT,
    NATIVE_INPUT_MOTION_STREAM_ID, NATIVE_MEDIA_FLAG_CONFIGURATION_BOUNDARY,
    NATIVE_MEDIA_FLAG_DISCONTINUITY, NATIVE_MEDIA_FLAG_END_OF_STREAM, NATIVE_MEDIA_FLAG_FEC_BLOCK,
    NATIVE_MEDIA_FLAG_KEYFRAME, NATIVE_MEDIA_FLAG_PARITY_SHARD, NATIVE_MEDIA_HEADER_BYTES,
    NATIVE_MEDIA_MAGIC, NATIVE_MEDIA_VERSION, NATIVE_PROTOCOL_VERSION,
    NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES, NATIVE_VIDEO_STREAM_ID, TRANSPORT_FRAME_GATED_HDR,
    TRANSPORT_FULL_FRAME_HDR,
};
pub use video_packetization::{plan_fec_blocks, plan_fec_shards};

pub const ABI_VERSION: u32 = 62;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenEngineStatus {
    Ok = 0,
    NoCommand = 1,
    InvalidArgument = 2,
    InvalidState = 3,
    CommandMismatch = 4,
    CommandFailed = 5,
    Panic = 6,
    AlreadyExists = 7,
    AuthenticationFailed = 8,
    StorageError = 9,
    CorruptData = 10,
    RecoveryRequired = 11,
}

mod engine_ffi;
mod host_engine;
mod workspace_command_recovery;
mod workspace_display;
mod workspace_engine;
mod workspace_engine_ffi;
mod workspace_recovery;
mod workspace_recovery_journal;
mod workspace_recovery_model;

pub use engine_ffi::*;
pub use host_engine::*;
pub use workspace_display::*;
pub use workspace_engine::*;
pub use workspace_engine_ffi::*;
pub use workspace_recovery::*;
pub use workspace_recovery_journal::*;
pub use workspace_recovery_model::*;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod workspace_engine_recovery_tests;
#[cfg(test)]
mod workspace_engine_tests;
#[cfg(test)]
mod workspace_recovery_cancellation_tests;
#[cfg(test)]
mod workspace_recovery_journal_tests;
#[cfg(test)]
mod workspace_recovery_tests;
