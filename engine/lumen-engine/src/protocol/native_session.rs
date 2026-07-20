use prost::{Enumeration, Message};

use super::native_transport::{
    NATIVE_AUDIO_STREAM_ID, NATIVE_FEC_BLOCK_HEADER_BYTES, NATIVE_INITIAL_CONFIGURATION_ID,
    NATIVE_INPUT_MOTION_STREAM_ID, NATIVE_VIDEO_STREAM_ID,
};

pub const NATIVE_PROTOCOL_VERSION: u32 = 4;
const MINIMUM_DATAGRAM_PAYLOAD: u32 = NATIVE_FEC_BLOCK_HEADER_BYTES as u32 + 1;
const INITIAL_POLICY_REVISION: u32 = 1;
const OPUS_PACKET_DURATION_MICROSECONDS: u32 = 5_000;
const MAXIMUM_DATA_SHARDS: u32 = 255;
const MAXIMUM_PARITY_SHARDS: u32 = 255;
const INITIAL_PARITY_PERCENTAGE: u32 = 20;
pub const NATIVE_CONTROL_MESSAGE_LIMIT: usize = 32 * 1024;
pub const NATIVE_VIDEO_BOOTSTRAP_MESSAGE_LIMIT: usize = 16 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeVideoCodec {
    Unspecified = 0,
    H264 = 1,
    Hevc = 2,
    Av1 = 3,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeDynamicRange {
    Unspecified = 0,
    Sdr = 1,
    Hdr10 = 2,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeVideoProfile {
    Unspecified = 0,
    H264Main = 1,
    H264High = 2,
    H264High444Predictive = 3,
    HevcMain = 4,
    HevcMain10 = 5,
    HevcMain444 = 6,
    HevcMain44410 = 7,
    Av1Main = 8,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeChromaSubsampling {
    Unspecified = 0,
    Yuv420 = 1,
    Yuv444 = 2,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeColorRange {
    Unspecified = 0,
    Limited = 1,
    Full = 2,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeAudioChannelMode {
    Unspecified = 0,
    Stereo = 1,
    Surround51 = 2,
    Surround71 = 3,
}

impl NativeAudioChannelMode {
    fn channel_count(self) -> u32 {
        match self {
            Self::Stereo => 2,
            Self::Surround51 => 6,
            Self::Surround71 => 8,
            Self::Unspecified => 0,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeAudioQuality {
    Unspecified = 0,
    Standard = 1,
    High = 2,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeNegotiationFailure {
    Unspecified = 0,
    UnsupportedProtocolVersion = 1,
    InvalidSessionEpoch = 3,
    InvalidDisplayMode = 4,
    InvalidPresentationContract = 5,
    InvalidVideoCodec = 6,
    UnsupportedVideoSelection = 7,
    InvalidDynamicRange = 8,
    InvalidPolicyMode = 9,
    DatagramPayloadTooSmall = 10,
    InvalidReceiveMemory = 11,
    UnsupportedAudioLayout = 12,
    InvalidAudioQuality = 13,
    InvalidStreamingProfileRevision = 14,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativePolicyMode {
    Unspecified = 0,
    UltraLatency = 1,
    Balanced = 2,
    Quality = 3,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeDisplayGamut {
    Unspecified = 0,
    Srgb = 1,
    DisplayP3 = 2,
    Rec2020 = 3,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeDisplayTransfer {
    Unspecified = 0,
    Sdr = 1,
    Pq = 2,
    Hlg = 3,
}

#[derive(Clone, Eq, PartialEq, Message)]
pub struct NativeVideoFormat {
    #[prost(enumeration = "NativeVideoCodec", tag = "1")]
    pub codec: i32,
    #[prost(enumeration = "NativeVideoProfile", tag = "2")]
    pub profile: i32,
    #[prost(enumeration = "NativeChromaSubsampling", tag = "3")]
    pub chroma_subsampling: i32,
    #[prost(uint32, tag = "4")]
    pub bit_depth: u32,
    #[prost(enumeration = "NativeDynamicRange", tag = "5")]
    pub dynamic_range: i32,
    #[prost(enumeration = "NativeColorRange", tag = "6")]
    pub color_range: i32,
}

#[derive(Clone, Eq, PartialEq, Message)]
pub struct NativeVideoCapability {
    #[prost(message, optional, tag = "7")]
    pub format: Option<NativeVideoFormat>,
    #[prost(uint32, tag = "8")]
    pub max_width: u32,
    #[prost(uint32, tag = "9")]
    pub max_height: u32,
    #[prost(uint32, tag = "10")]
    pub max_refresh_millihz: u32,
    #[prost(bool, optional, tag = "11")]
    pub hardware_accelerated: Option<bool>,
}

#[derive(Clone, PartialEq, Message)]
pub struct ClientSessionHello {
    #[prost(uint32, tag = "1")]
    pub minimum_protocol_version: u32,
    #[prost(uint32, tag = "2")]
    pub maximum_protocol_version: u32,
    #[prost(uint32, tag = "4")]
    pub width: u32,
    #[prost(uint32, tag = "5")]
    pub height: u32,
    #[prost(uint32, tag = "6")]
    pub refresh_millihz: u32,
    #[prost(message, repeated, tag = "7")]
    pub video_capabilities: Vec<NativeVideoCapability>,
    #[prost(enumeration = "NativePolicyMode", tag = "9")]
    pub requested_policy: i32,
    #[prost(uint32, tag = "10")]
    pub maximum_datagram_payload: u32,
    #[prost(uint64, tag = "11")]
    pub receive_memory_bytes: u64,
    #[prost(uint32, repeated, tag = "12")]
    pub opus_channel_counts: Vec<u32>,
    #[prost(string, tag = "14")]
    pub device_id: String,
    #[prost(string, tag = "15")]
    pub access_token: String,
    #[prost(uint32, tag = "16")]
    pub application_id: u32,
    #[prost(bool, tag = "17")]
    pub resume: bool,
    #[prost(uint32, tag = "18")]
    pub bitrate_kbps: u32,
    #[prost(bool, tag = "19")]
    pub play_audio_on_host: bool,
    #[prost(bool, tag = "20")]
    pub virtual_display: bool,
    #[prost(bool, tag = "21")]
    pub sink_hidpi: bool,
    #[prost(bool, tag = "22")]
    pub sink_scale_explicit: bool,
    #[prost(bool, tag = "23")]
    pub sink_mode_is_logical: bool,
    #[prost(uint32, tag = "24")]
    pub sink_scale_percent: u32,
    #[prost(enumeration = "NativeDisplayGamut", tag = "25")]
    pub sink_gamut: i32,
    #[prost(enumeration = "NativeDisplayTransfer", tag = "26")]
    pub sink_transfer: i32,
    #[prost(float, tag = "27")]
    pub sink_current_edr_headroom: f32,
    #[prost(float, tag = "28")]
    pub sink_potential_edr_headroom: f32,
    #[prost(uint32, tag = "29")]
    pub sink_current_peak_luminance_nits: u32,
    #[prost(uint32, tag = "30")]
    pub sink_potential_peak_luminance_nits: u32,
    #[prost(bool, tag = "31")]
    pub sink_supports_frame_gated_hdr: bool,
    #[prost(bool, tag = "32")]
    pub sink_supports_hdr_tile_overlay: bool,
    #[prost(bool, tag = "33")]
    pub sink_supports_per_frame_hdr_metadata: bool,
    #[prost(enumeration = "NativeAudioQuality", tag = "34")]
    pub requested_audio_quality: i32,
    #[prost(enumeration = "NativeAudioChannelMode", tag = "35")]
    pub requested_audio_channel_mode: i32,
    #[prost(uint64, tag = "36")]
    pub streaming_profile_revision: u64,
    #[prost(message, optional, tag = "37")]
    pub requested_video_format: Option<NativeVideoFormat>,
}

#[derive(Clone, PartialEq, Message)]
pub struct HostSessionPlan {
    #[prost(uint32, tag = "1")]
    pub protocol_version: u32,
    #[prost(uint32, tag = "2")]
    pub session_epoch: u32,
    #[prost(uint32, tag = "4")]
    pub encoded_width: u32,
    #[prost(uint32, tag = "5")]
    pub encoded_height: u32,
    #[prost(uint32, tag = "6")]
    pub refresh_millihz: u32,
    #[prost(enumeration = "NativePolicyMode", tag = "10")]
    pub policy: i32,
    #[prost(uint32, tag = "11")]
    pub maximum_datagram_payload: u32,
    #[prost(uint32, tag = "12")]
    pub maximum_presentable_frames: u32,
    #[prost(uint32, tag = "14")]
    pub policy_revision: u32,
    #[prost(uint32, tag = "15")]
    pub opus_channel_count: u32,
    #[prost(uint32, tag = "16")]
    pub opus_packet_duration_microseconds: u32,
    #[prost(uint32, tag = "17")]
    pub bitrate_kbps: u32,
    #[prost(uint32, tag = "18")]
    pub sink_scale_percent: u32,
    #[prost(enumeration = "NativeDisplayGamut", tag = "19")]
    pub sink_gamut: i32,
    #[prost(enumeration = "NativeDisplayTransfer", tag = "20")]
    pub sink_transfer: i32,
    #[prost(float, tag = "21")]
    pub sink_current_edr_headroom: f32,
    #[prost(float, tag = "22")]
    pub sink_potential_edr_headroom: f32,
    #[prost(uint32, tag = "23")]
    pub sink_current_peak_luminance_nits: u32,
    #[prost(uint32, tag = "24")]
    pub sink_potential_peak_luminance_nits: u32,
    #[prost(bool, tag = "25")]
    pub sink_supports_frame_gated_hdr: bool,
    #[prost(bool, tag = "26")]
    pub sink_supports_hdr_tile_overlay: bool,
    #[prost(bool, tag = "27")]
    pub sink_supports_per_frame_hdr_metadata: bool,
    #[prost(bool, tag = "28")]
    pub enhanced_audio_quality: bool,
    #[prost(uint32, tag = "29")]
    pub dynamic_range_transport: u32,
    #[prost(bool, tag = "30")]
    pub sink_hidpi: bool,
    #[prost(bool, tag = "31")]
    pub sink_scale_explicit: bool,
    #[prost(bool, tag = "32")]
    pub sink_mode_is_logical: bool,
    #[prost(uint64, tag = "33")]
    pub streaming_profile_revision: u64,
    #[prost(uint32, tag = "34")]
    pub opus_stream_count: u32,
    #[prost(uint32, tag = "35")]
    pub opus_coupled_stream_count: u32,
    #[prost(bytes = "vec", tag = "36")]
    pub opus_mapping: Vec<u8>,
    #[prost(uint32, tag = "37")]
    pub video_stream_id: u32,
    #[prost(uint32, tag = "38")]
    pub audio_stream_id: u32,
    #[prost(uint32, tag = "39")]
    pub input_motion_stream_id: u32,
    #[prost(uint32, tag = "40")]
    pub video_configuration_id: u32,
    #[prost(uint32, tag = "41")]
    pub maximum_data_shards: u32,
    #[prost(uint32, tag = "42")]
    pub maximum_parity_shards: u32,
    #[prost(uint32, tag = "43")]
    pub initial_parity_percentage: u32,
    #[prost(message, optional, tag = "44")]
    pub selected_video_capability: Option<NativeVideoCapability>,
    #[prost(uint32, tag = "45")]
    pub maximum_object_delay_us: u32,
}

impl HostSessionPlan {
    pub fn selected_video_format(&self) -> Option<&NativeVideoFormat> {
        self.selected_video_capability
            .as_ref()
            .and_then(|capability| capability.format.as_ref())
    }

    pub fn selected_video_codec(&self) -> Option<NativeVideoCodec> {
        self.selected_video_format()
            .and_then(|format| NativeVideoCodec::try_from(format.codec).ok())
    }
}

#[derive(Clone, PartialEq, Message)]
pub struct CodecConfiguration {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
    #[prost(uint32, tag = "3")]
    pub configuration_id: u32,
    #[prost(enumeration = "NativeVideoCodec", tag = "4")]
    pub codec: i32,
    #[prost(bytes = "vec", tag = "5")]
    pub decoder_configuration_record: Vec<u8>,
}

#[derive(Clone, PartialEq, Message)]
pub struct CodecConfigurationAck {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
    #[prost(uint32, tag = "3")]
    pub configuration_id: u32,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeVideoKeyframeRequestReason {
    Unspecified = 0,
    IncompleteUnit = 1,
    DecoderRecovery = 2,
}

#[derive(Clone, PartialEq, Message)]
pub struct VideoKeyframeRequest {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
    #[prost(uint32, tag = "3")]
    pub after_frame_id: u32,
    #[prost(enumeration = "NativeVideoKeyframeRequestReason", tag = "4")]
    pub reason: i32,
    #[prost(uint32, tag = "5")]
    pub generation_id: u32,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeVideoBootstrapReason {
    Unspecified = 0,
    Initial = 1,
    Periodic = 2,
    Repair = 3,
    ConfigurationChange = 4,
}

#[derive(Clone, PartialEq, Message)]
pub struct VideoBootstrap {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
    #[prost(uint32, tag = "3")]
    pub configuration_id: u32,
    #[prost(uint32, tag = "4")]
    pub generation_id: u32,
    #[prost(uint32, tag = "5")]
    pub frame_id: u32,
    #[prost(uint32, tag = "6")]
    pub capture_timestamp_us: u32,
    #[prost(enumeration = "NativeVideoBootstrapReason", tag = "7")]
    pub reason: i32,
    #[prost(bytes = "vec", tag = "8")]
    pub access_unit: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeVideoBootstrapResultCode {
    Unspecified = 0,
    Decoded = 1,
    DecoderRejected = 2,
    Stale = 3,
}

#[derive(Clone, PartialEq, Message)]
pub struct VideoBootstrapResult {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
    #[prost(uint32, tag = "2")]
    pub stream_id: u32,
    #[prost(uint32, tag = "3")]
    pub configuration_id: u32,
    #[prost(uint32, tag = "4")]
    pub generation_id: u32,
    #[prost(uint32, tag = "5")]
    pub frame_id: u32,
    #[prost(enumeration = "NativeVideoBootstrapResultCode", tag = "6")]
    pub result: i32,
    #[prost(string, tag = "7")]
    pub message: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct MediaFeedback {
    #[prost(uint32, tag = "1")]
    pub stream_id: u32,
    #[prost(uint32, tag = "2")]
    pub highest_datagram_sequence: u32,
    #[prost(uint32, tag = "3")]
    pub received_datagrams: u32,
    #[prost(uint32, tag = "4")]
    pub recovered_shards: u32,
    #[prost(uint32, tag = "5")]
    pub unrecoverable_objects: u32,
    #[prost(uint32, tag = "6")]
    pub late_objects: u32,
    #[prost(uint32, tag = "7")]
    pub reordered_datagrams: u32,
    #[prost(uint32, tag = "8")]
    pub estimated_jitter_us: u32,
    #[prost(uint32, tag = "9")]
    pub decoder_queue_depth: u32,
    #[prost(uint32, tag = "10")]
    pub presentation_drops: u32,
    #[prost(uint32, tag = "11")]
    pub window_milliseconds: u32,
    #[prost(uint32, tag = "12")]
    pub first_datagram_sequence: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct ClientTelemetryEnvelope {
    #[prost(uint64, tag = "1")]
    pub sequence: u64,
    #[prost(oneof = "client_telemetry_envelope::Payload", tags = "10")]
    pub payload: Option<client_telemetry_envelope::Payload>,
}

pub mod client_telemetry_envelope {
    use super::MediaFeedback;
    use prost::Oneof;

    #[derive(Clone, PartialEq, Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        MediaFeedback(MediaFeedback),
    }
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeProtocolError {
    #[prost(uint32, tag = "1")]
    pub code: u32,
    #[prost(string, tag = "2")]
    pub message: String,
    #[prost(enumeration = "NativeNegotiationFailure", tag = "3")]
    pub negotiation_failure: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct StartSessionAck {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct StopSession {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct SessionStopped {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct SessionStarted {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct ClientControlEnvelope {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(
        oneof = "client_control_envelope::Payload",
        tags = "10, 11, 13, 14, 15, 16"
    )]
    pub payload: Option<client_control_envelope::Payload>,
}

pub mod client_control_envelope {
    use super::{
        ClientSessionHello, CodecConfigurationAck, StartSessionAck, StopSession,
        VideoBootstrapResult, VideoKeyframeRequest,
    };
    use prost::Oneof;

    #[derive(Clone, PartialEq, Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        Hello(ClientSessionHello),
        #[prost(message, tag = "11")]
        StartSession(StartSessionAck),
        #[prost(message, tag = "13")]
        StopSession(StopSession),
        #[prost(message, tag = "14")]
        CodecConfigurationAck(CodecConfigurationAck),
        #[prost(message, tag = "15")]
        VideoKeyframeRequest(VideoKeyframeRequest),
        #[prost(message, tag = "16")]
        VideoBootstrapResult(VideoBootstrapResult),
    }
}

#[derive(Clone, PartialEq, Message)]
pub struct HostControlEnvelope {
    #[prost(uint64, tag = "1")]
    pub request_id: u64,
    #[prost(oneof = "host_control_envelope::Payload", tags = "10, 12, 13, 15")]
    pub payload: Option<host_control_envelope::Payload>,
}

pub mod host_control_envelope {
    use super::{HostSessionPlan, NativeProtocolError, SessionStarted, SessionStopped};
    use prost::Oneof;

    #[derive(Clone, PartialEq, Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        SessionPlan(HostSessionPlan),
        #[prost(message, tag = "12")]
        SessionStopped(SessionStopped),
        #[prost(message, tag = "13")]
        Error(NativeProtocolError),
        #[prost(message, tag = "15")]
        SessionStarted(SessionStarted),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeControlWireError {
    InvalidEnvelope,
    TruncatedLength,
    LengthOverflow,
    MessageTooLarge,
    TruncatedMessage,
    TrailingBytes,
    InvalidMessage,
}

pub fn encode_client_control_message(
    envelope: &ClientControlEnvelope,
) -> Result<Vec<u8>, NativeControlWireError> {
    encode_control_message(envelope, envelope.request_id, envelope.payload.is_some())
}

pub fn decode_client_control_message(
    bytes: &[u8],
) -> Result<ClientControlEnvelope, NativeControlWireError> {
    let envelope = ClientControlEnvelope::decode(control_body(bytes)?)
        .map_err(|_| NativeControlWireError::InvalidMessage)?;
    validate_envelope(envelope.request_id, envelope.payload.is_some())?;
    Ok(envelope)
}

pub fn encode_host_control_message(
    envelope: &HostControlEnvelope,
) -> Result<Vec<u8>, NativeControlWireError> {
    encode_control_message(envelope, envelope.request_id, envelope.payload.is_some())
}

pub fn decode_host_control_message(
    bytes: &[u8],
) -> Result<HostControlEnvelope, NativeControlWireError> {
    let envelope = HostControlEnvelope::decode(control_body(bytes)?)
        .map_err(|_| NativeControlWireError::InvalidMessage)?;
    validate_envelope(envelope.request_id, envelope.payload.is_some())?;
    Ok(envelope)
}

pub fn encode_client_telemetry_message(
    envelope: &ClientTelemetryEnvelope,
) -> Result<Vec<u8>, NativeControlWireError> {
    encode_control_message(envelope, envelope.sequence, envelope.payload.is_some())
}

pub fn decode_client_telemetry_message(
    bytes: &[u8],
) -> Result<ClientTelemetryEnvelope, NativeControlWireError> {
    let envelope = ClientTelemetryEnvelope::decode(control_body(bytes)?)
        .map_err(|_| NativeControlWireError::InvalidMessage)?;
    validate_envelope(envelope.sequence, envelope.payload.is_some())?;
    Ok(envelope)
}

pub fn encode_codec_configuration_message(
    configuration: &CodecConfiguration,
) -> Result<Vec<u8>, NativeControlWireError> {
    if configuration.session_epoch == 0
        || configuration.stream_id == 0
        || configuration.configuration_id == 0
        || NativeVideoCodec::try_from(configuration.codec).is_err()
        || configuration.decoder_configuration_record.is_empty()
    {
        return Err(NativeControlWireError::InvalidEnvelope);
    }
    if configuration.encoded_len() > NATIVE_CONTROL_MESSAGE_LIMIT {
        return Err(NativeControlWireError::MessageTooLarge);
    }
    let mut encoded = Vec::with_capacity(configuration.encoded_len() + 3);
    configuration
        .encode_length_delimited(&mut encoded)
        .map_err(|_| NativeControlWireError::InvalidMessage)?;
    Ok(encoded)
}

pub fn encode_video_bootstrap_message(
    bootstrap: &VideoBootstrap,
) -> Result<Vec<u8>, NativeControlWireError> {
    validate_video_bootstrap(bootstrap)?;
    if bootstrap.encoded_len() > NATIVE_VIDEO_BOOTSTRAP_MESSAGE_LIMIT {
        return Err(NativeControlWireError::MessageTooLarge);
    }
    let mut encoded = Vec::with_capacity(bootstrap.encoded_len() + 4);
    bootstrap
        .encode_length_delimited(&mut encoded)
        .map_err(|_| NativeControlWireError::InvalidMessage)?;
    Ok(encoded)
}

pub fn decode_video_bootstrap_message(
    bytes: &[u8],
) -> Result<VideoBootstrap, NativeControlWireError> {
    let body = delimited_body(bytes, NATIVE_VIDEO_BOOTSTRAP_MESSAGE_LIMIT)?;
    let bootstrap =
        VideoBootstrap::decode(body).map_err(|_| NativeControlWireError::InvalidMessage)?;
    validate_video_bootstrap(&bootstrap)?;
    Ok(bootstrap)
}

fn validate_video_bootstrap(bootstrap: &VideoBootstrap) -> Result<(), NativeControlWireError> {
    if bootstrap.session_epoch == 0
        || bootstrap.stream_id != u32::from(NATIVE_VIDEO_STREAM_ID)
        || bootstrap.configuration_id == 0
        || bootstrap.generation_id == 0
        || bootstrap.frame_id == 0
        || NativeVideoBootstrapReason::try_from(bootstrap.reason)
            .ok()
            .filter(|reason| *reason != NativeVideoBootstrapReason::Unspecified)
            .is_none()
        || bootstrap.access_unit.is_empty()
    {
        Err(NativeControlWireError::InvalidEnvelope)
    } else {
        Ok(())
    }
}

fn encode_control_message<M: Message>(
    message: &M,
    request_id: u64,
    has_payload: bool,
) -> Result<Vec<u8>, NativeControlWireError> {
    validate_envelope(request_id, has_payload)?;
    if message.encoded_len() > NATIVE_CONTROL_MESSAGE_LIMIT {
        return Err(NativeControlWireError::MessageTooLarge);
    }
    let mut encoded = Vec::with_capacity(message.encoded_len() + 3);
    message
        .encode_length_delimited(&mut encoded)
        .map_err(|_| NativeControlWireError::InvalidMessage)?;
    Ok(encoded)
}

fn validate_envelope(request_id: u64, has_payload: bool) -> Result<(), NativeControlWireError> {
    if request_id == 0 || !has_payload {
        Err(NativeControlWireError::InvalidEnvelope)
    } else {
        Ok(())
    }
}

fn control_body(bytes: &[u8]) -> Result<&[u8], NativeControlWireError> {
    delimited_body(bytes, NATIVE_CONTROL_MESSAGE_LIMIT)
}

fn delimited_body(bytes: &[u8], message_limit: usize) -> Result<&[u8], NativeControlWireError> {
    if bytes.is_empty() {
        return Err(NativeControlWireError::TruncatedLength);
    }
    let mut length = 0_usize;
    let mut shift = 0_u32;
    for (index, byte) in bytes.iter().copied().enumerate().take(10) {
        let value = usize::from(byte & 0x7f)
            .checked_shl(shift)
            .ok_or(NativeControlWireError::LengthOverflow)?;
        length = length
            .checked_add(value)
            .ok_or(NativeControlWireError::LengthOverflow)?;
        if byte & 0x80 == 0 {
            if length > message_limit {
                return Err(NativeControlWireError::MessageTooLarge);
            }
            let body_start = index + 1;
            let body_end = body_start
                .checked_add(length)
                .ok_or(NativeControlWireError::LengthOverflow)?;
            if bytes.len() < body_end {
                return Err(NativeControlWireError::TruncatedMessage);
            }
            if bytes.len() > body_end {
                return Err(NativeControlWireError::TrailingBytes);
            }
            return Ok(&bytes[body_start..body_end]);
        }
        shift = shift
            .checked_add(7)
            .ok_or(NativeControlWireError::LengthOverflow)?;
    }
    if bytes.len() < 10 {
        Err(NativeControlWireError::TruncatedLength)
    } else {
        Err(NativeControlWireError::LengthOverflow)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostSessionCapabilities {
    pub maximum_datagram_payload: u32,
    pub maximum_receive_memory_bytes: u64,
    pub video_capabilities: Vec<NativeVideoCapability>,
    pub supported_opus_channel_counts: Vec<u32>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeSessionError {
    UnsupportedProtocolVersion,
    InvalidSessionEpoch,
    InvalidDisplayMode,
    InvalidPresentationContract,
    InvalidVideoCodec,
    UnsupportedVideoSelection,
    InvalidDynamicRange,
    InvalidPolicyMode,
    DatagramPayloadTooSmall,
    InvalidReceiveMemory,
    UnsupportedAudioLayout,
    InvalidAudioQuality,
    InvalidStreamingProfileRevision,
}

impl NativeSessionError {
    pub const fn message(self) -> &'static str {
        match self {
            Self::UnsupportedProtocolVersion => "protocol version 4 is not in the client offer",
            Self::InvalidSessionEpoch => "session epoch is invalid",
            Self::InvalidDisplayMode => "the selected display mode exceeds an exact capability row",
            Self::InvalidPresentationContract => "the presentation contract is invalid",
            Self::InvalidVideoCodec => "the requested video codec is missing or invalid",
            Self::UnsupportedVideoSelection => {
                "the exact hardware video selection is malformed or unsupported"
            }
            Self::InvalidDynamicRange => "the requested dynamic range is missing or invalid",
            Self::InvalidPolicyMode => "the requested policy mode is invalid",
            Self::DatagramPayloadTooSmall => "the negotiated QUIC DATAGRAM payload is too small",
            Self::InvalidReceiveMemory => "the client receive-memory budget is invalid",
            Self::UnsupportedAudioLayout => "the requested audio layout is unsupported",
            Self::InvalidAudioQuality => "the requested audio quality is invalid",
            Self::InvalidStreamingProfileRevision => {
                "the streaming profile revision must be nonzero"
            }
        }
    }
}

impl From<NativeSessionError> for NativeNegotiationFailure {
    fn from(error: NativeSessionError) -> Self {
        match error {
            NativeSessionError::UnsupportedProtocolVersion => Self::UnsupportedProtocolVersion,
            NativeSessionError::InvalidSessionEpoch => Self::InvalidSessionEpoch,
            NativeSessionError::InvalidDisplayMode => Self::InvalidDisplayMode,
            NativeSessionError::InvalidPresentationContract => Self::InvalidPresentationContract,
            NativeSessionError::InvalidVideoCodec => Self::InvalidVideoCodec,
            NativeSessionError::UnsupportedVideoSelection => Self::UnsupportedVideoSelection,
            NativeSessionError::InvalidDynamicRange => Self::InvalidDynamicRange,
            NativeSessionError::InvalidPolicyMode => Self::InvalidPolicyMode,
            NativeSessionError::DatagramPayloadTooSmall => Self::DatagramPayloadTooSmall,
            NativeSessionError::InvalidReceiveMemory => Self::InvalidReceiveMemory,
            NativeSessionError::UnsupportedAudioLayout => Self::UnsupportedAudioLayout,
            NativeSessionError::InvalidAudioQuality => Self::InvalidAudioQuality,
            NativeSessionError::InvalidStreamingProfileRevision => {
                Self::InvalidStreamingProfileRevision
            }
        }
    }
}

pub fn negotiate_native_session(
    client: &ClientSessionHello,
    host: &HostSessionCapabilities,
    session_epoch: u32,
) -> Result<HostSessionPlan, NativeSessionError> {
    validate_protocol(client, host, session_epoch)?;
    let policy = NativePolicyMode::try_from(client.requested_policy)
        .ok()
        .filter(|policy| *policy != NativePolicyMode::Unspecified)
        .ok_or(NativeSessionError::InvalidPolicyMode)?;
    let requested_format = client
        .requested_video_format
        .as_ref()
        .ok_or(NativeSessionError::InvalidVideoCodec)?;
    let requested_exact_format = validate_exact_video_format(requested_format)?;
    let sink_gamut = NativeDisplayGamut::try_from(client.sink_gamut)
        .ok()
        .filter(|gamut| *gamut != NativeDisplayGamut::Unspecified)
        .ok_or(NativeSessionError::InvalidPresentationContract)?;
    let requested_transfer = NativeDisplayTransfer::try_from(client.sink_transfer)
        .ok()
        .filter(|transfer| *transfer != NativeDisplayTransfer::Unspecified)
        .ok_or(NativeSessionError::InvalidPresentationContract)?;
    let client_video_capability =
        find_exact_capability(&client.video_capabilities, requested_format)
            .ok_or(NativeSessionError::UnsupportedVideoSelection)?;
    let host_video_capability = find_exact_capability(&host.video_capabilities, requested_format)
        .ok_or(NativeSessionError::UnsupportedVideoSelection)?;
    validate_display_capabilities(client, client_video_capability, host_video_capability)?;
    let sink_transfer = if requested_exact_format.dynamic_range == NativeDynamicRange::Hdr10 {
        requested_transfer
    } else {
        NativeDisplayTransfer::Sdr
    };
    let maximum_datagram_payload = client
        .maximum_datagram_payload
        .min(host.maximum_datagram_payload);
    if maximum_datagram_payload < MINIMUM_DATAGRAM_PAYLOAD {
        return Err(NativeSessionError::DatagramPayloadTooSmall);
    }
    let audio_channel_mode = NativeAudioChannelMode::try_from(client.requested_audio_channel_mode)
        .ok()
        .filter(|mode| *mode != NativeAudioChannelMode::Unspecified)
        .ok_or(NativeSessionError::UnsupportedAudioLayout)?;
    let opus_channel_count = audio_channel_mode.channel_count();
    if !client.opus_channel_counts.contains(&opus_channel_count)
        || !host
            .supported_opus_channel_counts
            .contains(&opus_channel_count)
    {
        return Err(NativeSessionError::UnsupportedAudioLayout);
    }
    let audio_quality = NativeAudioQuality::try_from(client.requested_audio_quality)
        .ok()
        .filter(|quality| *quality != NativeAudioQuality::Unspecified)
        .ok_or(NativeSessionError::InvalidAudioQuality)?;
    let opus_layout = crate::resolve_audio_stream(crate::LumenAudioStreamRequest {
        channels: opus_channel_count as i32,
        packet_duration_milliseconds: 5,
        enhanced_audio_quality: audio_quality == NativeAudioQuality::High,
    })
    .map_err(|_| NativeSessionError::UnsupportedAudioLayout)?;
    if client.streaming_profile_revision == 0 {
        return Err(NativeSessionError::InvalidStreamingProfileRevision);
    }

    Ok(HostSessionPlan {
        protocol_version: NATIVE_PROTOCOL_VERSION,
        session_epoch,
        encoded_width: client.width,
        encoded_height: client.height,
        refresh_millihz: client.refresh_millihz,
        policy: policy as i32,
        maximum_datagram_payload,
        maximum_presentable_frames: match policy {
            NativePolicyMode::UltraLatency => 1,
            NativePolicyMode::Balanced => 2,
            NativePolicyMode::Quality => 3,
            NativePolicyMode::Unspecified => unreachable!(),
        },
        policy_revision: INITIAL_POLICY_REVISION,
        opus_channel_count,
        opus_packet_duration_microseconds: OPUS_PACKET_DURATION_MICROSECONDS,
        bitrate_kbps: client.bitrate_kbps,
        sink_scale_percent: client.sink_scale_percent,
        sink_gamut: sink_gamut as i32,
        sink_transfer: sink_transfer as i32,
        sink_current_edr_headroom: client.sink_current_edr_headroom,
        sink_potential_edr_headroom: client.sink_potential_edr_headroom,
        sink_current_peak_luminance_nits: client.sink_current_peak_luminance_nits,
        sink_potential_peak_luminance_nits: client.sink_potential_peak_luminance_nits,
        sink_supports_frame_gated_hdr: client.sink_supports_frame_gated_hdr,
        sink_supports_hdr_tile_overlay: client.sink_supports_hdr_tile_overlay,
        sink_supports_per_frame_hdr_metadata: client.sink_supports_per_frame_hdr_metadata,
        enhanced_audio_quality: audio_quality == NativeAudioQuality::High,
        dynamic_range_transport: selected_dynamic_range_transport(
            client,
            requested_exact_format.dynamic_range,
        ),
        sink_hidpi: client.sink_hidpi,
        sink_scale_explicit: client.sink_scale_explicit,
        sink_mode_is_logical: client.sink_mode_is_logical,
        streaming_profile_revision: client.streaming_profile_revision,
        opus_stream_count: opus_layout.streams as u32,
        opus_coupled_stream_count: opus_layout.coupled_streams as u32,
        opus_mapping: opus_layout.mapping[..opus_channel_count as usize].to_vec(),
        video_stream_id: u32::from(NATIVE_VIDEO_STREAM_ID),
        audio_stream_id: u32::from(NATIVE_AUDIO_STREAM_ID),
        input_motion_stream_id: u32::from(NATIVE_INPUT_MOTION_STREAM_ID),
        video_configuration_id: NATIVE_INITIAL_CONFIGURATION_ID,
        maximum_data_shards: MAXIMUM_DATA_SHARDS,
        maximum_parity_shards: MAXIMUM_PARITY_SHARDS,
        initial_parity_percentage: INITIAL_PARITY_PERCENTAGE,
        selected_video_capability: Some(NativeVideoCapability {
            format: Some(requested_format.clone()),
            max_width: client.width,
            max_height: client.height,
            max_refresh_millihz: client.refresh_millihz,
            hardware_accelerated: Some(true),
        }),
        maximum_object_delay_us: maximum_object_delay_us(client.refresh_millihz, policy),
    })
}

fn maximum_object_delay_us(refresh_millihz: u32, policy: NativePolicyMode) -> u32 {
    let frame_us = 1_000_000_000_u64.div_ceil(u64::from(refresh_millihz));
    let frames = match policy {
        NativePolicyMode::UltraLatency => 2,
        NativePolicyMode::Balanced => 3,
        NativePolicyMode::Quality => 4,
        NativePolicyMode::Unspecified => 2,
    };
    u32::try_from(frame_us.saturating_mul(frames)).unwrap_or(u32::MAX)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ExactVideoFormat {
    codec: NativeVideoCodec,
    profile: NativeVideoProfile,
    chroma_subsampling: NativeChromaSubsampling,
    bit_depth: u32,
    dynamic_range: NativeDynamicRange,
    color_range: NativeColorRange,
}

fn exact_video_format(format: &NativeVideoFormat) -> Option<ExactVideoFormat> {
    let exact = ExactVideoFormat {
        codec: NativeVideoCodec::try_from(format.codec).ok()?,
        profile: NativeVideoProfile::try_from(format.profile).ok()?,
        chroma_subsampling: NativeChromaSubsampling::try_from(format.chroma_subsampling).ok()?,
        bit_depth: format.bit_depth,
        dynamic_range: NativeDynamicRange::try_from(format.dynamic_range).ok()?,
        color_range: NativeColorRange::try_from(format.color_range).ok()?,
    };
    let profile_matches = match exact.profile {
        NativeVideoProfile::H264Main | NativeVideoProfile::H264High => {
            exact.codec == NativeVideoCodec::H264
                && exact.chroma_subsampling == NativeChromaSubsampling::Yuv420
                && exact.bit_depth == 8
        }
        NativeVideoProfile::H264High444Predictive => {
            exact.codec == NativeVideoCodec::H264
                && exact.chroma_subsampling == NativeChromaSubsampling::Yuv444
                && exact.bit_depth == 8
        }
        NativeVideoProfile::HevcMain => {
            exact.codec == NativeVideoCodec::Hevc
                && exact.chroma_subsampling == NativeChromaSubsampling::Yuv420
                && exact.bit_depth == 8
        }
        NativeVideoProfile::HevcMain10 => {
            exact.codec == NativeVideoCodec::Hevc
                && exact.chroma_subsampling == NativeChromaSubsampling::Yuv420
                && exact.bit_depth == 10
        }
        NativeVideoProfile::HevcMain444 => {
            exact.codec == NativeVideoCodec::Hevc
                && exact.chroma_subsampling == NativeChromaSubsampling::Yuv444
                && exact.bit_depth == 8
        }
        NativeVideoProfile::HevcMain44410 => {
            exact.codec == NativeVideoCodec::Hevc
                && exact.chroma_subsampling == NativeChromaSubsampling::Yuv444
                && exact.bit_depth == 10
        }
        NativeVideoProfile::Av1Main => {
            exact.codec == NativeVideoCodec::Av1
                && exact.chroma_subsampling == NativeChromaSubsampling::Yuv420
                && matches!(exact.bit_depth, 8 | 10)
        }
        NativeVideoProfile::Unspecified => false,
    };
    let range_matches = match exact.dynamic_range {
        NativeDynamicRange::Sdr => true,
        NativeDynamicRange::Hdr10 => {
            exact.bit_depth == 10 && exact.color_range == NativeColorRange::Limited
        }
        NativeDynamicRange::Unspecified => false,
    };
    (profile_matches
        && range_matches
        && exact.codec != NativeVideoCodec::Unspecified
        && exact.chroma_subsampling != NativeChromaSubsampling::Unspecified
        && exact.color_range != NativeColorRange::Unspecified)
        .then_some(exact)
}

fn validate_protocol(
    client: &ClientSessionHello,
    host: &HostSessionCapabilities,
    session_epoch: u32,
) -> Result<(), NativeSessionError> {
    if client.minimum_protocol_version > NATIVE_PROTOCOL_VERSION
        || client.maximum_protocol_version < NATIVE_PROTOCOL_VERSION
    {
        return Err(NativeSessionError::UnsupportedProtocolVersion);
    }
    if client.video_capabilities.is_empty() {
        return Err(NativeSessionError::UnsupportedVideoSelection);
    }
    for capability in &client.video_capabilities {
        if capability.hardware_accelerated.is_none() {
            return Err(NativeSessionError::UnsupportedVideoSelection);
        }
        validate_exact_video_format(
            capability
                .format
                .as_ref()
                .ok_or(NativeSessionError::UnsupportedVideoSelection)?,
        )?;
    }
    if session_epoch == 0 {
        return Err(NativeSessionError::InvalidSessionEpoch);
    }
    if client.receive_memory_bytes == 0
        || client.receive_memory_bytes > host.maximum_receive_memory_bytes
    {
        return Err(NativeSessionError::InvalidReceiveMemory);
    }
    let dynamic_range = client
        .requested_video_format
        .as_ref()
        .ok_or(NativeSessionError::InvalidVideoCodec)
        .and_then(validate_exact_video_format)?
        .dynamic_range;
    validate_presentation_contract(client, dynamic_range)?;
    Ok(())
}

fn validate_exact_video_format(
    format: &NativeVideoFormat,
) -> Result<ExactVideoFormat, NativeSessionError> {
    let codec = NativeVideoCodec::try_from(format.codec)
        .ok()
        .filter(|codec| *codec != NativeVideoCodec::Unspecified)
        .ok_or(NativeSessionError::InvalidVideoCodec)?;
    NativeDynamicRange::try_from(format.dynamic_range)
        .ok()
        .filter(|range| *range != NativeDynamicRange::Unspecified)
        .ok_or(NativeSessionError::InvalidDynamicRange)?;
    let exact = exact_video_format(format).ok_or(NativeSessionError::UnsupportedVideoSelection)?;
    debug_assert_eq!(exact.codec, codec);
    Ok(exact)
}

fn validate_presentation_contract(
    client: &ClientSessionHello,
    dynamic_range: NativeDynamicRange,
) -> Result<(), NativeSessionError> {
    let transfer = NativeDisplayTransfer::try_from(client.sink_transfer)
        .map_err(|_| NativeSessionError::InvalidPresentationContract)?;
    let gamut = NativeDisplayGamut::try_from(client.sink_gamut)
        .map_err(|_| NativeSessionError::InvalidPresentationContract)?;
    let transfer_matches = matches!(
        (dynamic_range, transfer),
        (NativeDynamicRange::Sdr, NativeDisplayTransfer::Sdr)
            | (NativeDynamicRange::Hdr10, NativeDisplayTransfer::Pq)
    );
    if gamut == NativeDisplayGamut::Unspecified
        || !transfer_matches
        || !(1..=800).contains(&client.sink_scale_percent)
        || client.bitrate_kbps == 0
        || !client.sink_current_edr_headroom.is_finite()
        || !client.sink_potential_edr_headroom.is_finite()
        || client.sink_current_edr_headroom < 0.0
        || client.sink_potential_edr_headroom < client.sink_current_edr_headroom
        || client.sink_potential_peak_luminance_nits < client.sink_current_peak_luminance_nits
        || client.sink_current_peak_luminance_nits > i32::MAX as u32
        || client.sink_potential_peak_luminance_nits > i32::MAX as u32
    {
        Err(NativeSessionError::InvalidPresentationContract)
    } else {
        Ok(())
    }
}

fn selected_dynamic_range_transport(
    client: &ClientSessionHello,
    dynamic_range: NativeDynamicRange,
) -> u32 {
    if dynamic_range == NativeDynamicRange::Sdr {
        super::TRANSPORT_SDR
    } else if client.sink_supports_frame_gated_hdr && client.sink_supports_per_frame_hdr_metadata {
        super::TRANSPORT_FRAME_GATED_HDR
    } else {
        super::TRANSPORT_FULL_FRAME_HDR
    }
}

fn find_exact_capability<'a>(
    capabilities: &'a [NativeVideoCapability],
    requested_format: &NativeVideoFormat,
) -> Option<&'a NativeVideoCapability> {
    capabilities.iter().find(|capability| {
        capability.hardware_accelerated == Some(true)
            && capability.format.as_ref() == Some(requested_format)
            && capability
                .format
                .as_ref()
                .and_then(exact_video_format)
                .is_some()
    })
}

fn validate_display_capabilities(
    client: &ClientSessionHello,
    client_capability: &NativeVideoCapability,
    host_capability: &NativeVideoCapability,
) -> Result<(), NativeSessionError> {
    if client.width == 0
        || client.height == 0
        || client.refresh_millihz == 0
        || client.width > client_capability.max_width
        || client.height > client_capability.max_height
        || client.refresh_millihz > client_capability.max_refresh_millihz
        || client.width > host_capability.max_width
        || client.height > host_capability.max_height
        || client.refresh_millihz > host_capability.max_refresh_millihz
    {
        Err(NativeSessionError::InvalidDisplayMode)
    } else {
        Ok(())
    }
}
