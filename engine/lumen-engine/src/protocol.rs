use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

mod hdr_frame_state;
mod hdr_regions;
mod lumen_streaming_v3_provenance;
mod native_input;
mod native_session;
#[cfg(test)]
mod native_session_tests;
mod native_transport;
#[cfg(test)]
mod native_transport_tests;
mod session_offer;
mod transport_plan;

pub use lumen_streaming_v3_provenance::{
    LUMEN_STREAMING_DESCRIPTOR_SHA256, LUMEN_STREAMING_EXPORTER_LABEL,
    LUMEN_STREAMING_PROTOCOL_ALPN, LUMEN_STREAMING_PROTOCOL_PACKAGE, LUMEN_STREAMING_SCHEMA_SHA256,
};
pub use native_input::{
    client_input_envelope, client_motion_envelope, decode_client_input_message,
    decode_host_input_message, encode_client_input_message, encode_host_input_message,
    host_input_envelope, ClientInputEnvelope, ClientMotionEnvelope, HostInputEnvelope,
    NativeContactPhase, NativeGamepadButton, NativeGamepadButtonInput,
    NativeGamepadConnectionInput, NativeGamepadMotionInput, NativeInputAck, NativeInputFailure,
    NativeInputFailureCode, NativeInputReset, NativeInputWireError, NativeKeyboardInput,
    NativePenContactInput, NativePenMotionInput, NativePointerButtonInput,
    NativePointerMotionInput, NativePointerMotionMode, NativeRumbleAck, NativeRumbleCommand,
    NativeScrollInput, NativeTextInput, NativeTouchContactInput, NativeTouchMotionInput,
    NATIVE_INPUT_MESSAGE_LIMIT,
};
pub use native_session::{
    client_control_envelope, decode_client_control_message, decode_host_control_message,
    encode_client_control_message, encode_codec_configuration_message, encode_host_control_message,
    host_control_envelope, negotiate_native_session, ClientControlEnvelope, ClientSessionHello,
    CodecConfiguration, CodecConfigurationAck, HostControlEnvelope, HostSessionCapabilities,
    HostSessionPlan, MediaPathChallenge, MediaPathResponse, MediaPathValidated,
    NativeAudioChannelMode, NativeAudioQuality, NativeChromaSubsampling, NativeColorRange,
    NativeControlWireError, NativeDisplayGamut, NativeDisplayTransfer, NativeDynamicRange,
    NativeNegotiationFailure, NativePolicyMode, NativeProtocolError, NativeSessionError,
    NativeVideoCapability, NativeVideoCodec, NativeVideoFormat, NativeVideoProfile, SessionStarted,
    SessionStopped, StartSessionAck, StopSession, NATIVE_CONTROL_MESSAGE_LIMIT,
    NATIVE_PROTOCOL_VERSION,
};
pub use native_transport::{
    decode_native_media_datagram, decode_native_video_access_unit, encode_native_media_header,
    encode_native_media_header_with_fec_block, encode_native_video_access_unit_descriptor,
    DecodedNativeMediaDatagram, NativeFecBlockExtension, NativeMediaHeader, NativeMediaKind,
    NativeTransportError, NativeVideoAccessUnitDescriptor, NATIVE_AUDIO_STREAM_ID,
    NATIVE_FEC_BLOCK_EXTENSION_BYTES, NATIVE_FEC_BLOCK_HEADER_BYTES,
    NATIVE_INITIAL_CONFIGURATION_ID, NATIVE_INPUT_MOTION_STREAM_ID,
    NATIVE_MEDIA_FLAG_CONFIGURATION_BOUNDARY, NATIVE_MEDIA_FLAG_DISCONTINUITY,
    NATIVE_MEDIA_FLAG_END_OF_STREAM, NATIVE_MEDIA_FLAG_FEC_BLOCK, NATIVE_MEDIA_FLAG_KEYFRAME,
    NATIVE_MEDIA_FLAG_PARITY_SHARD, NATIVE_MEDIA_HEADER_BYTES, NATIVE_MEDIA_MAGIC,
    NATIVE_MEDIA_VERSION, NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES, NATIVE_VIDEO_STREAM_ID,
};

pub use session_offer::{parse_session_offer, LumenSessionOffer};
pub use transport_plan::{
    resolve_video_transport, LumenSinkTransportPlan, LumenSinkTransportRequest,
};

#[cfg(test)]
pub const TRANSPORT_UNKNOWN: u32 = 0;
pub const TRANSPORT_SDR: u32 = 1;
pub const TRANSPORT_FULL_FRAME_HDR: u32 = 2;
pub const TRANSPORT_FRAME_GATED_HDR: u32 = 3;
pub const TRANSPORT_SDR_BASE_HDR_OVERLAY: u32 = 4;

pub const PRESENTATION_CONTRACT_SINGLE_FRAME: u32 = 0;
pub const PRESENTATION_COMPLETION_FULL_FRAME: u32 = 0;

pub fn dynamic_range_transport_name(transport: u32) -> &'static str {
    match normalize_transport(transport) {
        TRANSPORT_FULL_FRAME_HDR => "full-frame-hdr",
        TRANSPORT_FRAME_GATED_HDR => "frame-gated-hdr",
        TRANSPORT_SDR_BASE_HDR_OVERLAY => "sdr-base-hdr-overlay",
        _ => "sdr",
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenProtocolSinkCapability {
    pub prefers_hdr: bool,
    pub supports_hdr_tile_overlay: bool,
    pub supports_per_frame_hdr_metadata: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenProtocolSourceCapability {
    pub hdr_enabled: bool,
    pub supports_hdr_overlay_encode: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenProtocolNegotiationRequest {
    pub requested_transport: u32,
    pub sink: LumenProtocolSinkCapability,
    pub source: LumenProtocolSourceCapability,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenProtocolAdapterRequest {
    pub requested_transport: u32,
    pub negotiated_transport: u32,
    pub sink: LumenProtocolSinkCapability,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenProtocolAdapterResult {
    pub requested_transport: u32,
    pub negotiated_transport: u32,
    pub sink: LumenProtocolSinkCapability,
    pub presentation_contract: u32,
    pub presentation_completion_rule: u32,
}

fn normalize_transport(transport: u32) -> u32 {
    match transport {
        TRANSPORT_SDR
        | TRANSPORT_FULL_FRAME_HDR
        | TRANSPORT_FRAME_GATED_HDR
        | TRANSPORT_SDR_BASE_HDR_OVERLAY => transport,
        _ => TRANSPORT_SDR,
    }
}

pub fn resolve_protocol_transport(request: LumenProtocolNegotiationRequest) -> u32 {
    let requested_transport = normalize_transport(request.requested_transport);
    if requested_transport == TRANSPORT_SDR
        || !request.source.hdr_enabled
        || !request.sink.prefers_hdr
    {
        return TRANSPORT_SDR;
    }

    match requested_transport {
        TRANSPORT_SDR_BASE_HDR_OVERLAY => {
            if !request.source.supports_hdr_overlay_encode {
                TRANSPORT_SDR
            } else if request.sink.supports_hdr_tile_overlay
                && request.sink.supports_per_frame_hdr_metadata
            {
                TRANSPORT_SDR_BASE_HDR_OVERLAY
            } else if request.sink.supports_per_frame_hdr_metadata {
                TRANSPORT_FRAME_GATED_HDR
            } else {
                TRANSPORT_SDR
            }
        }
        TRANSPORT_FRAME_GATED_HDR if request.sink.supports_per_frame_hdr_metadata => {
            TRANSPORT_FRAME_GATED_HDR
        }
        TRANSPORT_FULL_FRAME_HDR if request.source.supports_hdr_overlay_encode => {
            TRANSPORT_FULL_FRAME_HDR
        }
        _ => TRANSPORT_SDR,
    }
}

pub fn resolve_protocol_adapter(
    request: LumenProtocolAdapterRequest,
) -> LumenProtocolAdapterResult {
    LumenProtocolAdapterResult {
        requested_transport: normalize_transport(request.requested_transport),
        negotiated_transport: normalize_transport(request.negotiated_transport),
        sink: request.sink,
        presentation_contract: PRESENTATION_CONTRACT_SINGLE_FRAME,
        presentation_completion_rule: PRESENTATION_COMPLETION_FULL_FRAME,
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_protocol_transport(
    request: LumenProtocolNegotiationRequest,
    transport_out: *mut u32,
) -> LumenEngineStatus {
    let Some(mut transport_out) = NonNull::new(transport_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_protocol_transport(request))) {
        Ok(transport) => {
            unsafe { *transport_out.as_mut() = transport };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_protocol_adapter(
    request: LumenProtocolAdapterRequest,
    result_out: *mut LumenProtocolAdapterResult,
) -> LumenEngineStatus {
    let Some(mut result_out) = NonNull::new(result_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_protocol_adapter(request))) {
        Ok(result) => {
            unsafe { *result_out.as_mut() = result };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hdr_sink() -> LumenProtocolSinkCapability {
        LumenProtocolSinkCapability {
            prefers_hdr: true,
            supports_hdr_tile_overlay: true,
            supports_per_frame_hdr_metadata: true,
        }
    }

    #[test]
    fn overlay_transport_is_owned_by_rust_policy() {
        let transport = resolve_protocol_transport(LumenProtocolNegotiationRequest {
            requested_transport: TRANSPORT_SDR_BASE_HDR_OVERLAY,
            sink: hdr_sink(),
            source: LumenProtocolSourceCapability {
                hdr_enabled: true,
                supports_hdr_overlay_encode: true,
            },
        });

        assert_eq!(transport, TRANSPORT_SDR_BASE_HDR_OVERLAY);
    }

    #[test]
    fn overlay_falls_back_to_frame_gated_when_sink_cannot_composite_tiles() {
        let transport = resolve_protocol_transport(LumenProtocolNegotiationRequest {
            requested_transport: TRANSPORT_SDR_BASE_HDR_OVERLAY,
            sink: LumenProtocolSinkCapability {
                supports_hdr_tile_overlay: false,
                ..hdr_sink()
            },
            source: LumenProtocolSourceCapability {
                hdr_enabled: true,
                supports_hdr_overlay_encode: true,
            },
        });

        assert_eq!(transport, TRANSPORT_FRAME_GATED_HDR);
    }

    #[test]
    fn non_hdr_source_or_sink_cannot_negotiate_hdr() {
        for (source_hdr, sink_hdr) in [(false, true), (true, false)] {
            let transport = resolve_protocol_transport(LumenProtocolNegotiationRequest {
                requested_transport: TRANSPORT_FULL_FRAME_HDR,
                sink: LumenProtocolSinkCapability {
                    prefers_hdr: sink_hdr,
                    ..hdr_sink()
                },
                source: LumenProtocolSourceCapability {
                    hdr_enabled: source_hdr,
                    supports_hdr_overlay_encode: true,
                },
            });
            assert_eq!(transport, TRANSPORT_SDR);
        }
    }

    #[test]
    fn presentation_contract_is_single_complete_frame() {
        let result = resolve_protocol_adapter(LumenProtocolAdapterRequest {
            requested_transport: TRANSPORT_SDR_BASE_HDR_OVERLAY,
            negotiated_transport: TRANSPORT_FRAME_GATED_HDR,
            sink: hdr_sink(),
        });

        assert_eq!(result.requested_transport, TRANSPORT_SDR_BASE_HDR_OVERLAY);
        assert_eq!(result.negotiated_transport, TRANSPORT_FRAME_GATED_HDR);
        assert_eq!(
            result.presentation_contract,
            PRESENTATION_CONTRACT_SINGLE_FRAME
        );
        assert_eq!(
            result.presentation_completion_rule,
            PRESENTATION_COMPLETION_FULL_FRAME
        );
    }

    #[test]
    fn unknown_transport_values_are_normalized_at_the_ffi_boundary() {
        let result = resolve_protocol_adapter(LumenProtocolAdapterRequest {
            requested_transport: TRANSPORT_UNKNOWN,
            negotiated_transport: u32::MAX,
            sink: LumenProtocolSinkCapability::default(),
        });

        assert_eq!(result.requested_transport, TRANSPORT_SDR);
        assert_eq!(result.negotiated_transport, TRANSPORT_SDR);
    }
}
