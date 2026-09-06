# Lumen v4 API reference

> Generated file. Do not edit it directly. Change `docs/protocol/lumen-contract-v4.json` and run `lumen-contract-tool generate`.

- Contract SHA-256: `6bb33abf2aab138f6e14f1ab38a1fa1d3bfba391199ee85353dee90cf55fc225`
- Contract schema version: `1`
- Protobuf source: `docs/protocol/lumen-streaming-v4.proto`
- Descriptor source name: `lumen-streaming-v4.proto`
- Swift module: `LumenClientContracts`

## Identity

| Authority | Value |
| --- | --- |
| Protocol | <code>lumen-stream</code> |
| Version | <code>4</code> |
| Protobuf package | <code>lumen.streaming.v4</code> |
| QUIC ALPN | <code>lumen-stream/4</code> |

## Swift package consumption

`LumenClientContracts` publishes the generated SwiftProtobuf enums and value-type message structs listed below, together with the bundled contract authority. Applications construct their transport, authentication, settings, and session services in their composition root and pass those services through initializer injection. The generated package defines the wire contract; it does not hide or globally construct a QUIC runtime.

## Protobuf API

The following declarations are read from the compiled descriptor, not parsed from source text.

| File property | Value |
| --- | --- |
| Syntax | <code>proto3</code> |
| Package | <code>lumen.streaming.v4</code> |
| Dependencies | none |

| Declaration kind | Count |
| --- | ---: |
| Enums | 22 |
| Enum values | 117 |
| Messages | 42 |
| Services | 0 |
| Message fields | 286 |
| Explicit oneofs | 6 |
| Synthetic optional oneofs | 3 |

### enum `lumen.streaming.v4.VideoCodec`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.VideoCodec.VIDEO_CODEC_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.VideoCodec.VIDEO_CODEC_H264</code> | 1 |
| <code>lumen.streaming.v4.VideoCodec.VIDEO_CODEC_HEVC</code> | 2 |
| <code>lumen.streaming.v4.VideoCodec.VIDEO_CODEC_AV1</code> | 3 |
| <code>lumen.streaming.v4.VideoCodec.VIDEO_CODEC_SHADOW_VC</code> | 4 |

### enum `lumen.streaming.v4.DynamicRange`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.DynamicRange.DYNAMIC_RANGE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.DynamicRange.DYNAMIC_RANGE_SDR</code> | 1 |
| <code>lumen.streaming.v4.DynamicRange.DYNAMIC_RANGE_HDR10</code> | 2 |

### enum `lumen.streaming.v4.VideoProfile`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_H264_MAIN</code> | 1 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_H264_HIGH</code> | 2 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_H264_HIGH_444_PREDICTIVE</code> | 3 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_HEVC_MAIN</code> | 4 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_HEVC_MAIN10</code> | 5 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_HEVC_MAIN_444</code> | 6 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_HEVC_MAIN_444_10</code> | 7 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_AV1_MAIN</code> | 8 |
| <code>lumen.streaming.v4.VideoProfile.VIDEO_PROFILE_SHADOW_VC_SPATIAL_BASE16</code> | 9 |

### enum `lumen.streaming.v4.ChromaSubsampling`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.ChromaSubsampling.CHROMA_SUBSAMPLING_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.ChromaSubsampling.CHROMA_SUBSAMPLING_YUV420</code> | 1 |
| <code>lumen.streaming.v4.ChromaSubsampling.CHROMA_SUBSAMPLING_YUV444</code> | 2 |

### enum `lumen.streaming.v4.ColorRange`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.ColorRange.COLOR_RANGE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.ColorRange.COLOR_RANGE_LIMITED</code> | 1 |
| <code>lumen.streaming.v4.ColorRange.COLOR_RANGE_FULL</code> | 2 |

### enum `lumen.streaming.v4.AudioChannelMode`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.AudioChannelMode.AUDIO_CHANNEL_MODE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.AudioChannelMode.AUDIO_CHANNEL_MODE_STEREO</code> | 1 |
| <code>lumen.streaming.v4.AudioChannelMode.AUDIO_CHANNEL_MODE_SURROUND_5_1</code> | 2 |
| <code>lumen.streaming.v4.AudioChannelMode.AUDIO_CHANNEL_MODE_SURROUND_7_1</code> | 3 |

### enum `lumen.streaming.v4.AudioQuality`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.AudioQuality.AUDIO_QUALITY_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.AudioQuality.AUDIO_QUALITY_STANDARD</code> | 1 |
| <code>lumen.streaming.v4.AudioQuality.AUDIO_QUALITY_HIGH</code> | 2 |

### enum `lumen.streaming.v4.NegotiationFailure`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_UNSUPPORTED_PROTOCOL_VERSION</code> | 1 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_SESSION_EPOCH</code> | 3 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_DISPLAY_MODE</code> | 4 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_PRESENTATION_CONTRACT</code> | 5 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_VIDEO_CODEC</code> | 6 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_UNSUPPORTED_VIDEO_SELECTION</code> | 7 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_DYNAMIC_RANGE</code> | 8 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_POLICY_MODE</code> | 9 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_DATAGRAM_PAYLOAD_TOO_SMALL</code> | 10 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_RECEIVE_MEMORY</code> | 11 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_UNSUPPORTED_AUDIO_LAYOUT</code> | 12 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_AUDIO_QUALITY</code> | 13 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_INVALID_STREAMING_PROFILE_REVISION</code> | 14 |
| <code>lumen.streaming.v4.NegotiationFailure.NEGOTIATION_FAILURE_UNSUPPORTED_MEDIA_CAPABILITIES</code> | 15 |

Reserved numbers: <code>2...2</code>.

### enum `lumen.streaming.v4.PolicyMode`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.PolicyMode.POLICY_MODE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.PolicyMode.POLICY_MODE_ULTRA_LATENCY</code> | 1 |
| <code>lumen.streaming.v4.PolicyMode.POLICY_MODE_BALANCED</code> | 2 |
| <code>lumen.streaming.v4.PolicyMode.POLICY_MODE_QUALITY</code> | 3 |

### enum `lumen.streaming.v4.DisplayGamut`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.DisplayGamut.DISPLAY_GAMUT_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.DisplayGamut.DISPLAY_GAMUT_SRGB</code> | 1 |
| <code>lumen.streaming.v4.DisplayGamut.DISPLAY_GAMUT_DISPLAY_P3</code> | 2 |
| <code>lumen.streaming.v4.DisplayGamut.DISPLAY_GAMUT_REC2020</code> | 3 |

### enum `lumen.streaming.v4.DisplayTransfer`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.DisplayTransfer.DISPLAY_TRANSFER_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.DisplayTransfer.DISPLAY_TRANSFER_SDR</code> | 1 |
| <code>lumen.streaming.v4.DisplayTransfer.DISPLAY_TRANSFER_PQ</code> | 2 |
| <code>lumen.streaming.v4.DisplayTransfer.DISPLAY_TRANSFER_HLG</code> | 3 |

### enum `lumen.streaming.v4.PointerMotionMode`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.PointerMotionMode.POINTER_MOTION_MODE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.PointerMotionMode.POINTER_MOTION_MODE_RELATIVE</code> | 1 |
| <code>lumen.streaming.v4.PointerMotionMode.POINTER_MOTION_MODE_ABSOLUTE</code> | 2 |

### enum `lumen.streaming.v4.ContactPhase`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.ContactPhase.CONTACT_PHASE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.ContactPhase.CONTACT_PHASE_BEGAN</code> | 1 |
| <code>lumen.streaming.v4.ContactPhase.CONTACT_PHASE_ENDED</code> | 2 |
| <code>lumen.streaming.v4.ContactPhase.CONTACT_PHASE_CANCELLED</code> | 3 |

### enum `lumen.streaming.v4.GamepadButton`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_SOUTH</code> | 1 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_EAST</code> | 2 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_WEST</code> | 3 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_NORTH</code> | 4 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_LEFT_BUMPER</code> | 5 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_RIGHT_BUMPER</code> | 6 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_LEFT_STICK</code> | 7 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_RIGHT_STICK</code> | 8 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_BACK</code> | 9 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_START</code> | 10 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_GUIDE</code> | 11 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_DPAD_UP</code> | 12 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_DPAD_DOWN</code> | 13 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_DPAD_LEFT</code> | 14 |
| <code>lumen.streaming.v4.GamepadButton.GAMEPAD_BUTTON_DPAD_RIGHT</code> | 15 |

### enum `lumen.streaming.v4.VideoKeyframeRequestReason`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.VideoKeyframeRequestReason.VIDEO_KEYFRAME_REQUEST_REASON_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.VideoKeyframeRequestReason.VIDEO_KEYFRAME_REQUEST_REASON_INCOMPLETE_UNIT</code> | 1 |
| <code>lumen.streaming.v4.VideoKeyframeRequestReason.VIDEO_KEYFRAME_REQUEST_REASON_DECODER_RECOVERY</code> | 2 |

### enum `lumen.streaming.v4.VideoBootstrapReason`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.VideoBootstrapReason.VIDEO_BOOTSTRAP_REASON_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.VideoBootstrapReason.VIDEO_BOOTSTRAP_REASON_INITIAL</code> | 1 |
| <code>lumen.streaming.v4.VideoBootstrapReason.VIDEO_BOOTSTRAP_REASON_PERIODIC</code> | 2 |
| <code>lumen.streaming.v4.VideoBootstrapReason.VIDEO_BOOTSTRAP_REASON_REPAIR</code> | 3 |
| <code>lumen.streaming.v4.VideoBootstrapReason.VIDEO_BOOTSTRAP_REASON_CONFIGURATION_CHANGE</code> | 4 |

### enum `lumen.streaming.v4.VideoBootstrapResultCode`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.VideoBootstrapResultCode.VIDEO_BOOTSTRAP_RESULT_CODE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.VideoBootstrapResultCode.VIDEO_BOOTSTRAP_RESULT_CODE_DECODED</code> | 1 |
| <code>lumen.streaming.v4.VideoBootstrapResultCode.VIDEO_BOOTSTRAP_RESULT_CODE_DECODER_REJECTED</code> | 2 |
| <code>lumen.streaming.v4.VideoBootstrapResultCode.VIDEO_BOOTSTRAP_RESULT_CODE_STALE</code> | 3 |

### enum `lumen.streaming.v4.ScrollPhase`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.ScrollPhase.SCROLL_PHASE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.ScrollPhase.SCROLL_PHASE_BEGAN</code> | 1 |
| <code>lumen.streaming.v4.ScrollPhase.SCROLL_PHASE_CHANGED</code> | 2 |
| <code>lumen.streaming.v4.ScrollPhase.SCROLL_PHASE_ENDED</code> | 3 |
| <code>lumen.streaming.v4.ScrollPhase.SCROLL_PHASE_CANCELLED</code> | 4 |
| <code>lumen.streaming.v4.ScrollPhase.SCROLL_PHASE_MOMENTUM_BEGAN</code> | 5 |
| <code>lumen.streaming.v4.ScrollPhase.SCROLL_PHASE_MOMENTUM_CHANGED</code> | 6 |
| <code>lumen.streaming.v4.ScrollPhase.SCROLL_PHASE_MOMENTUM_ENDED</code> | 7 |

### enum `lumen.streaming.v4.InputFailureCode`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.InputFailureCode.INPUT_FAILURE_CODE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.InputFailureCode.INPUT_FAILURE_CODE_PLATFORM_REJECTED</code> | 1 |

### enum `lumen.streaming.v4.DisplayReconfigurationResultCode`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.DisplayReconfigurationResultCode.DISPLAY_RECONFIGURATION_RESULT_CODE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.DisplayReconfigurationResultCode.DISPLAY_RECONFIGURATION_RESULT_CODE_APPLIED</code> | 1 |
| <code>lumen.streaming.v4.DisplayReconfigurationResultCode.DISPLAY_RECONFIGURATION_RESULT_CODE_REJECTED</code> | 2 |
| <code>lumen.streaming.v4.DisplayReconfigurationResultCode.DISPLAY_RECONFIGURATION_RESULT_CODE_SUPERSEDED</code> | 3 |

### enum `lumen.streaming.v4.MediaParkState`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.MediaParkState.MEDIA_PARK_STATE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.MediaParkState.MEDIA_PARK_STATE_ACTIVE</code> | 1 |
| <code>lumen.streaming.v4.MediaParkState.MEDIA_PARK_STATE_PARKING</code> | 2 |
| <code>lumen.streaming.v4.MediaParkState.MEDIA_PARK_STATE_PARKED</code> | 3 |
| <code>lumen.streaming.v4.MediaParkState.MEDIA_PARK_STATE_RESUMING</code> | 4 |

### enum `lumen.streaming.v4.MediaParkResultCode`

| Name | Number |
| --- | ---: |
| <code>lumen.streaming.v4.MediaParkResultCode.MEDIA_PARK_RESULT_CODE_UNSPECIFIED</code> | 0 |
| <code>lumen.streaming.v4.MediaParkResultCode.MEDIA_PARK_RESULT_CODE_APPLIED</code> | 1 |
| <code>lumen.streaming.v4.MediaParkResultCode.MEDIA_PARK_RESULT_CODE_IDEMPOTENT</code> | 2 |
| <code>lumen.streaming.v4.MediaParkResultCode.MEDIA_PARK_RESULT_CODE_SUPERSEDED</code> | 3 |
| <code>lumen.streaming.v4.MediaParkResultCode.MEDIA_PARK_RESULT_CODE_REJECTED</code> | 4 |

### message `lumen.streaming.v4.VideoFormat`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.VideoFormat.codec</code> | <code>codec</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.VideoCodec</code> | — | no |
| 2 | <code>lumen.streaming.v4.VideoFormat.profile</code> | <code>profile</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.VideoProfile</code> | — | no |
| 3 | <code>lumen.streaming.v4.VideoFormat.chroma_subsampling</code> | <code>chromaSubsampling</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.ChromaSubsampling</code> | — | no |
| 4 | <code>lumen.streaming.v4.VideoFormat.bit_depth</code> | <code>bitDepth</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.VideoFormat.dynamic_range</code> | <code>dynamicRange</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.DynamicRange</code> | — | no |
| 6 | <code>lumen.streaming.v4.VideoFormat.color_range</code> | <code>colorRange</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.ColorRange</code> | — | no |

### message `lumen.streaming.v4.VideoCapability`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 7 | <code>lumen.streaming.v4.VideoCapability.format</code> | <code>format</code> | singular | <code>message</code> | <code>lumen.streaming.v4.VideoFormat</code> | — | no |
| 8 | <code>lumen.streaming.v4.VideoCapability.max_width</code> | <code>maxWidth</code> | singular | <code>uint32</code> | — | — | no |
| 9 | <code>lumen.streaming.v4.VideoCapability.max_height</code> | <code>maxHeight</code> | singular | <code>uint32</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.VideoCapability.max_refresh_millihz</code> | <code>maxRefreshMillihz</code> | singular | <code>uint32</code> | — | — | no |
| 11 | <code>lumen.streaming.v4.VideoCapability.hardware_accelerated</code> | <code>hardwareAccelerated</code> | optional | <code>bool</code> | — | <code>_hardware_accelerated</code> | yes |

Oneof declarations:

| Name | Kind | Members |
| --- | --- | --- |
| <code>lumen.streaming.v4.VideoCapability._hardware_accelerated</code> | synthetic optional | <code>lumen.streaming.v4.VideoCapability.hardware_accelerated</code> |

Reserved tags: <code>1..&lt;2</code>, <code>2..&lt;3</code>, <code>3..&lt;4</code>, <code>4..&lt;5</code>, <code>5..&lt;6</code>, <code>6..&lt;7</code>.

### message `lumen.streaming.v4.ClientSessionHello`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.ClientSessionHello.minimum_protocol_version</code> | <code>minimumProtocolVersion</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.ClientSessionHello.maximum_protocol_version</code> | <code>maximumProtocolVersion</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.ClientSessionHello.width</code> | <code>width</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.ClientSessionHello.height</code> | <code>height</code> | singular | <code>uint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.ClientSessionHello.refresh_millihz</code> | <code>refreshMillihz</code> | singular | <code>uint32</code> | — | — | no |
| 7 | <code>lumen.streaming.v4.ClientSessionHello.video_capabilities</code> | <code>videoCapabilities</code> | repeated | <code>message</code> | <code>lumen.streaming.v4.VideoCapability</code> | — | no |
| 9 | <code>lumen.streaming.v4.ClientSessionHello.requested_policy</code> | <code>requestedPolicy</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.PolicyMode</code> | — | no |
| 10 | <code>lumen.streaming.v4.ClientSessionHello.maximum_datagram_payload</code> | <code>maximumDatagramPayload</code> | singular | <code>uint32</code> | — | — | no |
| 11 | <code>lumen.streaming.v4.ClientSessionHello.receive_memory_bytes</code> | <code>receiveMemoryBytes</code> | singular | <code>uint64</code> | — | — | no |
| 12 | <code>lumen.streaming.v4.ClientSessionHello.opus_channel_counts</code> | <code>opusChannelCounts</code> | repeated | <code>uint32</code> | — | — | no |
| 14 | <code>lumen.streaming.v4.ClientSessionHello.device_id</code> | <code>deviceId</code> | singular | <code>string</code> | — | — | no |
| 15 | <code>lumen.streaming.v4.ClientSessionHello.access_token</code> | <code>accessToken</code> | singular | <code>string</code> | — | — | no |
| 16 | <code>lumen.streaming.v4.ClientSessionHello.application_id</code> | <code>applicationId</code> | singular | <code>uint32</code> | — | — | no |
| 17 | <code>lumen.streaming.v4.ClientSessionHello.resume</code> | <code>resume</code> | singular | <code>bool</code> | — | — | no |
| 18 | <code>lumen.streaming.v4.ClientSessionHello.bitrate_kbps</code> | <code>bitrateKbps</code> | singular | <code>uint32</code> | — | — | no |
| 19 | <code>lumen.streaming.v4.ClientSessionHello.play_audio_on_host</code> | <code>playAudioOnHost</code> | singular | <code>bool</code> | — | — | no |
| 20 | <code>lumen.streaming.v4.ClientSessionHello.virtual_display</code> | <code>virtualDisplay</code> | singular | <code>bool</code> | — | — | no |
| 21 | <code>lumen.streaming.v4.ClientSessionHello.sink_hidpi</code> | <code>sinkHidpi</code> | singular | <code>bool</code> | — | — | no |
| 22 | <code>lumen.streaming.v4.ClientSessionHello.sink_scale_explicit</code> | <code>sinkScaleExplicit</code> | singular | <code>bool</code> | — | — | no |
| 23 | <code>lumen.streaming.v4.ClientSessionHello.sink_mode_is_logical</code> | <code>sinkModeIsLogical</code> | singular | <code>bool</code> | — | — | no |
| 24 | <code>lumen.streaming.v4.ClientSessionHello.sink_scale_percent</code> | <code>sinkScalePercent</code> | singular | <code>uint32</code> | — | — | no |
| 25 | <code>lumen.streaming.v4.ClientSessionHello.sink_gamut</code> | <code>sinkGamut</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.DisplayGamut</code> | — | no |
| 26 | <code>lumen.streaming.v4.ClientSessionHello.sink_transfer</code> | <code>sinkTransfer</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.DisplayTransfer</code> | — | no |
| 27 | <code>lumen.streaming.v4.ClientSessionHello.sink_current_edr_headroom</code> | <code>sinkCurrentEdrHeadroom</code> | singular | <code>float</code> | — | — | no |
| 28 | <code>lumen.streaming.v4.ClientSessionHello.sink_potential_edr_headroom</code> | <code>sinkPotentialEdrHeadroom</code> | singular | <code>float</code> | — | — | no |
| 29 | <code>lumen.streaming.v4.ClientSessionHello.sink_current_peak_luminance_nits</code> | <code>sinkCurrentPeakLuminanceNits</code> | singular | <code>uint32</code> | — | — | no |
| 30 | <code>lumen.streaming.v4.ClientSessionHello.sink_potential_peak_luminance_nits</code> | <code>sinkPotentialPeakLuminanceNits</code> | singular | <code>uint32</code> | — | — | no |
| 31 | <code>lumen.streaming.v4.ClientSessionHello.sink_supports_frame_gated_hdr</code> | <code>sinkSupportsFrameGatedHdr</code> | singular | <code>bool</code> | — | — | no |
| 32 | <code>lumen.streaming.v4.ClientSessionHello.sink_supports_hdr_tile_overlay</code> | <code>sinkSupportsHdrTileOverlay</code> | singular | <code>bool</code> | — | — | no |
| 33 | <code>lumen.streaming.v4.ClientSessionHello.sink_supports_per_frame_hdr_metadata</code> | <code>sinkSupportsPerFrameHdrMetadata</code> | singular | <code>bool</code> | — | — | no |
| 34 | <code>lumen.streaming.v4.ClientSessionHello.requested_audio_quality</code> | <code>requestedAudioQuality</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.AudioQuality</code> | — | no |
| 35 | <code>lumen.streaming.v4.ClientSessionHello.requested_audio_channel_mode</code> | <code>requestedAudioChannelMode</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.AudioChannelMode</code> | — | no |
| 36 | <code>lumen.streaming.v4.ClientSessionHello.streaming_profile_revision</code> | <code>streamingProfileRevision</code> | singular | <code>uint64</code> | — | — | no |
| 37 | <code>lumen.streaming.v4.ClientSessionHello.requested_video_format</code> | <code>requestedVideoFormat</code> | singular | <code>message</code> | <code>lumen.streaming.v4.VideoFormat</code> | — | no |
| 38 | <code>lumen.streaming.v4.ClientSessionHello.media_capabilities</code> | <code>mediaCapabilities</code> | singular | <code>uint64</code> | — | — | no |

Reserved tags: <code>3..&lt;4</code>, <code>8..&lt;9</code>, <code>13..&lt;14</code>.

### message `lumen.streaming.v4.HostSessionPlan`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.HostSessionPlan.protocol_version</code> | <code>protocolVersion</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.HostSessionPlan.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.HostSessionPlan.encoded_width</code> | <code>encodedWidth</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.HostSessionPlan.encoded_height</code> | <code>encodedHeight</code> | singular | <code>uint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.HostSessionPlan.refresh_millihz</code> | <code>refreshMillihz</code> | singular | <code>uint32</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.HostSessionPlan.policy</code> | <code>policy</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.PolicyMode</code> | — | no |
| 11 | <code>lumen.streaming.v4.HostSessionPlan.maximum_datagram_payload</code> | <code>maximumDatagramPayload</code> | singular | <code>uint32</code> | — | — | no |
| 12 | <code>lumen.streaming.v4.HostSessionPlan.maximum_presentable_frames</code> | <code>maximumPresentableFrames</code> | singular | <code>uint32</code> | — | — | no |
| 14 | <code>lumen.streaming.v4.HostSessionPlan.policy_revision</code> | <code>policyRevision</code> | singular | <code>uint32</code> | — | — | no |
| 15 | <code>lumen.streaming.v4.HostSessionPlan.opus_channel_count</code> | <code>opusChannelCount</code> | singular | <code>uint32</code> | — | — | no |
| 16 | <code>lumen.streaming.v4.HostSessionPlan.opus_packet_duration_microseconds</code> | <code>opusPacketDurationMicroseconds</code> | singular | <code>uint32</code> | — | — | no |
| 17 | <code>lumen.streaming.v4.HostSessionPlan.bitrate_kbps</code> | <code>bitrateKbps</code> | singular | <code>uint32</code> | — | — | no |
| 18 | <code>lumen.streaming.v4.HostSessionPlan.sink_scale_percent</code> | <code>sinkScalePercent</code> | singular | <code>uint32</code> | — | — | no |
| 19 | <code>lumen.streaming.v4.HostSessionPlan.sink_gamut</code> | <code>sinkGamut</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.DisplayGamut</code> | — | no |
| 20 | <code>lumen.streaming.v4.HostSessionPlan.sink_transfer</code> | <code>sinkTransfer</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.DisplayTransfer</code> | — | no |
| 21 | <code>lumen.streaming.v4.HostSessionPlan.sink_current_edr_headroom</code> | <code>sinkCurrentEdrHeadroom</code> | singular | <code>float</code> | — | — | no |
| 22 | <code>lumen.streaming.v4.HostSessionPlan.sink_potential_edr_headroom</code> | <code>sinkPotentialEdrHeadroom</code> | singular | <code>float</code> | — | — | no |
| 23 | <code>lumen.streaming.v4.HostSessionPlan.sink_current_peak_luminance_nits</code> | <code>sinkCurrentPeakLuminanceNits</code> | singular | <code>uint32</code> | — | — | no |
| 24 | <code>lumen.streaming.v4.HostSessionPlan.sink_potential_peak_luminance_nits</code> | <code>sinkPotentialPeakLuminanceNits</code> | singular | <code>uint32</code> | — | — | no |
| 25 | <code>lumen.streaming.v4.HostSessionPlan.sink_supports_frame_gated_hdr</code> | <code>sinkSupportsFrameGatedHdr</code> | singular | <code>bool</code> | — | — | no |
| 26 | <code>lumen.streaming.v4.HostSessionPlan.sink_supports_hdr_tile_overlay</code> | <code>sinkSupportsHdrTileOverlay</code> | singular | <code>bool</code> | — | — | no |
| 27 | <code>lumen.streaming.v4.HostSessionPlan.sink_supports_per_frame_hdr_metadata</code> | <code>sinkSupportsPerFrameHdrMetadata</code> | singular | <code>bool</code> | — | — | no |
| 28 | <code>lumen.streaming.v4.HostSessionPlan.enhanced_audio_quality</code> | <code>enhancedAudioQuality</code> | singular | <code>bool</code> | — | — | no |
| 29 | <code>lumen.streaming.v4.HostSessionPlan.dynamic_range_transport</code> | <code>dynamicRangeTransport</code> | singular | <code>uint32</code> | — | — | no |
| 30 | <code>lumen.streaming.v4.HostSessionPlan.sink_hidpi</code> | <code>sinkHidpi</code> | singular | <code>bool</code> | — | — | no |
| 31 | <code>lumen.streaming.v4.HostSessionPlan.sink_scale_explicit</code> | <code>sinkScaleExplicit</code> | singular | <code>bool</code> | — | — | no |
| 32 | <code>lumen.streaming.v4.HostSessionPlan.sink_mode_is_logical</code> | <code>sinkModeIsLogical</code> | singular | <code>bool</code> | — | — | no |
| 33 | <code>lumen.streaming.v4.HostSessionPlan.streaming_profile_revision</code> | <code>streamingProfileRevision</code> | singular | <code>uint64</code> | — | — | no |
| 34 | <code>lumen.streaming.v4.HostSessionPlan.opus_stream_count</code> | <code>opusStreamCount</code> | singular | <code>uint32</code> | — | — | no |
| 35 | <code>lumen.streaming.v4.HostSessionPlan.opus_coupled_stream_count</code> | <code>opusCoupledStreamCount</code> | singular | <code>uint32</code> | — | — | no |
| 36 | <code>lumen.streaming.v4.HostSessionPlan.opus_mapping</code> | <code>opusMapping</code> | singular | <code>bytes</code> | — | — | no |
| 37 | <code>lumen.streaming.v4.HostSessionPlan.video_stream_id</code> | <code>videoStreamId</code> | singular | <code>uint32</code> | — | — | no |
| 38 | <code>lumen.streaming.v4.HostSessionPlan.audio_stream_id</code> | <code>audioStreamId</code> | singular | <code>uint32</code> | — | — | no |
| 39 | <code>lumen.streaming.v4.HostSessionPlan.input_motion_stream_id</code> | <code>inputMotionStreamId</code> | singular | <code>uint32</code> | — | — | no |
| 40 | <code>lumen.streaming.v4.HostSessionPlan.video_configuration_id</code> | <code>videoConfigurationId</code> | singular | <code>uint32</code> | — | — | no |
| 41 | <code>lumen.streaming.v4.HostSessionPlan.maximum_data_shards</code> | <code>maximumDataShards</code> | singular | <code>uint32</code> | — | — | no |
| 42 | <code>lumen.streaming.v4.HostSessionPlan.maximum_parity_shards</code> | <code>maximumParityShards</code> | singular | <code>uint32</code> | — | — | no |
| 43 | <code>lumen.streaming.v4.HostSessionPlan.initial_parity_percentage</code> | <code>initialParityPercentage</code> | singular | <code>uint32</code> | — | — | no |
| 44 | <code>lumen.streaming.v4.HostSessionPlan.selected_video_capability</code> | <code>selectedVideoCapability</code> | singular | <code>message</code> | <code>lumen.streaming.v4.VideoCapability</code> | — | no |
| 45 | <code>lumen.streaming.v4.HostSessionPlan.maximum_object_delay_us</code> | <code>maximumObjectDelayUs</code> | singular | <code>uint32</code> | — | — | no |
| 46 | <code>lumen.streaming.v4.HostSessionPlan.media_capabilities</code> | <code>mediaCapabilities</code> | singular | <code>uint64</code> | — | — | no |

Reserved tags: <code>3..&lt;4</code>, <code>7..&lt;8</code>, <code>8..&lt;9</code>, <code>9..&lt;10</code>, <code>13..&lt;14</code>.

### message `lumen.streaming.v4.CodecConfiguration`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.CodecConfiguration.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.CodecConfiguration.stream_id</code> | <code>streamId</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.CodecConfiguration.configuration_id</code> | <code>configurationId</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.CodecConfiguration.codec</code> | <code>codec</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.VideoCodec</code> | — | no |
| 5 | <code>lumen.streaming.v4.CodecConfiguration.decoder_configuration_record</code> | <code>decoderConfigurationRecord</code> | singular | <code>bytes</code> | — | — | no |

### message `lumen.streaming.v4.CodecConfigurationAck`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.CodecConfigurationAck.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.CodecConfigurationAck.stream_id</code> | <code>streamId</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.CodecConfigurationAck.configuration_id</code> | <code>configurationId</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.VideoKeyframeRequest`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.VideoKeyframeRequest.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.VideoKeyframeRequest.stream_id</code> | <code>streamId</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.VideoKeyframeRequest.after_frame_id</code> | <code>afterFrameId</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.VideoKeyframeRequest.reason</code> | <code>reason</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.VideoKeyframeRequestReason</code> | — | no |
| 5 | <code>lumen.streaming.v4.VideoKeyframeRequest.generation_id</code> | <code>generationId</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.VideoBootstrap`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.VideoBootstrap.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.VideoBootstrap.stream_id</code> | <code>streamId</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.VideoBootstrap.configuration_id</code> | <code>configurationId</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.VideoBootstrap.generation_id</code> | <code>generationId</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.VideoBootstrap.frame_id</code> | <code>frameId</code> | singular | <code>uint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.VideoBootstrap.capture_timestamp_us</code> | <code>captureTimestampUs</code> | singular | <code>uint32</code> | — | — | no |
| 7 | <code>lumen.streaming.v4.VideoBootstrap.reason</code> | <code>reason</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.VideoBootstrapReason</code> | — | no |
| 8 | <code>lumen.streaming.v4.VideoBootstrap.access_unit</code> | <code>accessUnit</code> | singular | <code>bytes</code> | — | — | no |

### message `lumen.streaming.v4.VideoBootstrapResult`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.VideoBootstrapResult.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.VideoBootstrapResult.stream_id</code> | <code>streamId</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.VideoBootstrapResult.configuration_id</code> | <code>configurationId</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.VideoBootstrapResult.generation_id</code> | <code>generationId</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.VideoBootstrapResult.frame_id</code> | <code>frameId</code> | singular | <code>uint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.VideoBootstrapResult.result</code> | <code>result</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.VideoBootstrapResultCode</code> | — | no |
| 7 | <code>lumen.streaming.v4.VideoBootstrapResult.message</code> | <code>message</code> | singular | <code>string</code> | — | — | no |

### message `lumen.streaming.v4.MediaFeedback`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.MediaFeedback.stream_id</code> | <code>streamId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.MediaFeedback.highest_datagram_sequence</code> | <code>highestDatagramSequence</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.MediaFeedback.received_datagrams</code> | <code>receivedDatagrams</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.MediaFeedback.recovered_shards</code> | <code>recoveredShards</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.MediaFeedback.unrecoverable_objects</code> | <code>unrecoverableObjects</code> | singular | <code>uint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.MediaFeedback.late_objects</code> | <code>lateObjects</code> | singular | <code>uint32</code> | — | — | no |
| 7 | <code>lumen.streaming.v4.MediaFeedback.reordered_datagrams</code> | <code>reorderedDatagrams</code> | singular | <code>uint32</code> | — | — | no |
| 8 | <code>lumen.streaming.v4.MediaFeedback.estimated_jitter_us</code> | <code>estimatedJitterUs</code> | singular | <code>uint32</code> | — | — | no |
| 9 | <code>lumen.streaming.v4.MediaFeedback.decoder_queue_depth</code> | <code>decoderQueueDepth</code> | singular | <code>uint32</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.MediaFeedback.presentation_drops</code> | <code>presentationDrops</code> | singular | <code>uint32</code> | — | — | no |
| 11 | <code>lumen.streaming.v4.MediaFeedback.window_milliseconds</code> | <code>windowMilliseconds</code> | singular | <code>uint32</code> | — | — | no |
| 12 | <code>lumen.streaming.v4.MediaFeedback.first_datagram_sequence</code> | <code>firstDatagramSequence</code> | singular | <code>uint32</code> | — | — | no |
| 13 | <code>lumen.streaming.v4.MediaFeedback.decoder_submissions</code> | <code>decoderSubmissions</code> | singular | <code>uint32</code> | — | — | no |
| 14 | <code>lumen.streaming.v4.MediaFeedback.decoded_frames</code> | <code>decodedFrames</code> | singular | <code>uint32</code> | — | — | no |
| 15 | <code>lumen.streaming.v4.MediaFeedback.presented_frames</code> | <code>presentedFrames</code> | singular | <code>uint32</code> | — | — | no |
| 16 | <code>lumen.streaming.v4.MediaFeedback.decoder_drops</code> | <code>decoderDrops</code> | singular | <code>uint32</code> | — | — | no |
| 17 | <code>lumen.streaming.v4.MediaFeedback.feedback_window_id</code> | <code>feedbackWindowId</code> | singular | <code>uint64</code> | — | — | no |
| 18 | <code>lumen.streaming.v4.MediaFeedback.packet_arrival_reference_time_us</code> | <code>packetArrivalReferenceTimeUs</code> | singular | <code>uint64</code> | — | — | no |
| 19 | <code>lumen.streaming.v4.MediaFeedback.packet_arrival_runs</code> | <code>packetArrivalRuns</code> | singular | <code>bytes</code> | — | — | no |

### message `lumen.streaming.v4.ClientTelemetryEnvelope`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.ClientTelemetryEnvelope.sequence</code> | <code>sequence</code> | singular | <code>uint64</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.ClientTelemetryEnvelope.media_feedback</code> | <code>mediaFeedback</code> | singular | <code>message</code> | <code>lumen.streaming.v4.MediaFeedback</code> | <code>payload</code> | no |

Oneof declarations:

| Name | Kind | Members |
| --- | --- | --- |
| <code>lumen.streaming.v4.ClientTelemetryEnvelope.payload</code> | explicit | <code>lumen.streaming.v4.ClientTelemetryEnvelope.media_feedback</code> |

### message `lumen.streaming.v4.KeyboardInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.KeyboardInput.hid_usage</code> | <code>hidUsage</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.KeyboardInput.pressed</code> | <code>pressed</code> | singular | <code>bool</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.KeyboardInput.modifiers</code> | <code>modifiers</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.KeyboardInput.repeat</code> | <code>repeat</code> | singular | <code>bool</code> | — | — | no |

### message `lumen.streaming.v4.TextInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.TextInput.text_utf8</code> | <code>textUtf8</code> | singular | <code>string</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.TextInput.composition_id</code> | <code>compositionId</code> | singular | <code>uint64</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.TextInput.commit</code> | <code>commit</code> | singular | <code>bool</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.TextInput.selection_start_utf8</code> | <code>selectionStartUtf8</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.TextInput.selection_length_utf8</code> | <code>selectionLengthUtf8</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.PointerButtonInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.PointerButtonInput.pointer_id</code> | <code>pointerId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.PointerButtonInput.button</code> | <code>button</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.PointerButtonInput.pressed</code> | <code>pressed</code> | singular | <code>bool</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.PointerButtonInput.normalized_x</code> | <code>normalizedX</code> | optional | <code>float</code> | — | <code>_normalized_x</code> | yes |
| 5 | <code>lumen.streaming.v4.PointerButtonInput.normalized_y</code> | <code>normalizedY</code> | optional | <code>float</code> | — | <code>_normalized_y</code> | yes |

Oneof declarations:

| Name | Kind | Members |
| --- | --- | --- |
| <code>lumen.streaming.v4.PointerButtonInput._normalized_x</code> | synthetic optional | <code>lumen.streaming.v4.PointerButtonInput.normalized_x</code> |
| <code>lumen.streaming.v4.PointerButtonInput._normalized_y</code> | synthetic optional | <code>lumen.streaming.v4.PointerButtonInput.normalized_y</code> |

### message `lumen.streaming.v4.GamepadConnectionInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.GamepadConnectionInput.gamepad_id</code> | <code>gamepadId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.GamepadConnectionInput.connected</code> | <code>connected</code> | singular | <code>bool</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.GamepadConnectionInput.capabilities</code> | <code>capabilities</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.GamepadButtonInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.GamepadButtonInput.gamepad_id</code> | <code>gamepadId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.GamepadButtonInput.button</code> | <code>button</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.GamepadButton</code> | — | no |
| 3 | <code>lumen.streaming.v4.GamepadButtonInput.pressed</code> | <code>pressed</code> | singular | <code>bool</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.GamepadButtonInput.analog_value</code> | <code>analogValue</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.TouchContactInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.TouchContactInput.contact_id</code> | <code>contactId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.TouchContactInput.phase</code> | <code>phase</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.ContactPhase</code> | — | no |
| 3 | <code>lumen.streaming.v4.TouchContactInput.normalized_x</code> | <code>normalizedX</code> | singular | <code>float</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.TouchContactInput.normalized_y</code> | <code>normalizedY</code> | singular | <code>float</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.TouchContactInput.pressure</code> | <code>pressure</code> | singular | <code>float</code> | — | — | no |

### message `lumen.streaming.v4.PenContactInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.PenContactInput.pointer_id</code> | <code>pointerId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.PenContactInput.phase</code> | <code>phase</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.ContactPhase</code> | — | no |
| 3 | <code>lumen.streaming.v4.PenContactInput.buttons</code> | <code>buttons</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.PenContactInput.normalized_x</code> | <code>normalizedX</code> | singular | <code>float</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.PenContactInput.normalized_y</code> | <code>normalizedY</code> | singular | <code>float</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.PenContactInput.pressure</code> | <code>pressure</code> | singular | <code>float</code> | — | — | no |

### message `lumen.streaming.v4.RumbleAck`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.RumbleAck.command_sequence</code> | <code>commandSequence</code> | singular | <code>uint64</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.RumbleAck.gamepad_id</code> | <code>gamepadId</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.RumbleAck.accepted</code> | <code>accepted</code> | singular | <code>bool</code> | — | — | no |

### message `lumen.streaming.v4.ClientInputEnvelope`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.ClientInputEnvelope.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.ClientInputEnvelope.event_sequence</code> | <code>eventSequence</code> | singular | <code>uint64</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.ClientInputEnvelope.keyboard</code> | <code>keyboard</code> | singular | <code>message</code> | <code>lumen.streaming.v4.KeyboardInput</code> | <code>payload</code> | no |
| 11 | <code>lumen.streaming.v4.ClientInputEnvelope.text</code> | <code>text</code> | singular | <code>message</code> | <code>lumen.streaming.v4.TextInput</code> | <code>payload</code> | no |
| 12 | <code>lumen.streaming.v4.ClientInputEnvelope.pointer_button</code> | <code>pointerButton</code> | singular | <code>message</code> | <code>lumen.streaming.v4.PointerButtonInput</code> | <code>payload</code> | no |
| 13 | <code>lumen.streaming.v4.ClientInputEnvelope.gamepad_connection</code> | <code>gamepadConnection</code> | singular | <code>message</code> | <code>lumen.streaming.v4.GamepadConnectionInput</code> | <code>payload</code> | no |
| 14 | <code>lumen.streaming.v4.ClientInputEnvelope.gamepad_button</code> | <code>gamepadButton</code> | singular | <code>message</code> | <code>lumen.streaming.v4.GamepadButtonInput</code> | <code>payload</code> | no |
| 15 | <code>lumen.streaming.v4.ClientInputEnvelope.touch_contact</code> | <code>touchContact</code> | singular | <code>message</code> | <code>lumen.streaming.v4.TouchContactInput</code> | <code>payload</code> | no |
| 16 | <code>lumen.streaming.v4.ClientInputEnvelope.pen_contact</code> | <code>penContact</code> | singular | <code>message</code> | <code>lumen.streaming.v4.PenContactInput</code> | <code>payload</code> | no |
| 17 | <code>lumen.streaming.v4.ClientInputEnvelope.rumble_ack</code> | <code>rumbleAck</code> | singular | <code>message</code> | <code>lumen.streaming.v4.RumbleAck</code> | <code>payload</code> | no |

Oneof declarations:

| Name | Kind | Members |
| --- | --- | --- |
| <code>lumen.streaming.v4.ClientInputEnvelope.payload</code> | explicit | <code>lumen.streaming.v4.ClientInputEnvelope.keyboard</code>, <code>lumen.streaming.v4.ClientInputEnvelope.text</code>, <code>lumen.streaming.v4.ClientInputEnvelope.pointer_button</code>, <code>lumen.streaming.v4.ClientInputEnvelope.gamepad_connection</code>, <code>lumen.streaming.v4.ClientInputEnvelope.gamepad_button</code>, <code>lumen.streaming.v4.ClientInputEnvelope.touch_contact</code>, <code>lumen.streaming.v4.ClientInputEnvelope.pen_contact</code>, <code>lumen.streaming.v4.ClientInputEnvelope.rumble_ack</code> |

### message `lumen.streaming.v4.PointerMotionInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.PointerMotionInput.pointer_id</code> | <code>pointerId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.PointerMotionInput.mode</code> | <code>mode</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.PointerMotionMode</code> | — | no |
| 3 | <code>lumen.streaming.v4.PointerMotionInput.delta_x</code> | <code>deltaX</code> | singular | <code>sint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.PointerMotionInput.delta_y</code> | <code>deltaY</code> | singular | <code>sint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.PointerMotionInput.normalized_x</code> | <code>normalizedX</code> | singular | <code>float</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.PointerMotionInput.normalized_y</code> | <code>normalizedY</code> | singular | <code>float</code> | — | — | no |

### message `lumen.streaming.v4.ScrollInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.ScrollInput.pointer_id</code> | <code>pointerId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.ScrollInput.delta_x_1024_points</code> | <code>deltaX1024Points</code> | singular | <code>sint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.ScrollInput.delta_y_1024_points</code> | <code>deltaY1024Points</code> | singular | <code>sint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.ScrollInput.phase</code> | <code>phase</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.ScrollPhase</code> | — | no |
| 5 | <code>lumen.streaming.v4.ScrollInput.velocity_x_1024_points_per_second</code> | <code>velocityX1024PointsPerSecond</code> | singular | <code>sint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.ScrollInput.velocity_y_1024_points_per_second</code> | <code>velocityY1024PointsPerSecond</code> | singular | <code>sint32</code> | — | — | no |
| 7 | <code>lumen.streaming.v4.ScrollInput.continuous_precision</code> | <code>continuousPrecision</code> | singular | <code>bool</code> | — | — | no |

### message `lumen.streaming.v4.TouchMotionInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.TouchMotionInput.contact_id</code> | <code>contactId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.TouchMotionInput.normalized_x</code> | <code>normalizedX</code> | singular | <code>float</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.TouchMotionInput.normalized_y</code> | <code>normalizedY</code> | singular | <code>float</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.TouchMotionInput.pressure</code> | <code>pressure</code> | singular | <code>float</code> | — | — | no |

### message `lumen.streaming.v4.PenMotionInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.PenMotionInput.pointer_id</code> | <code>pointerId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.PenMotionInput.normalized_x</code> | <code>normalizedX</code> | singular | <code>float</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.PenMotionInput.normalized_y</code> | <code>normalizedY</code> | singular | <code>float</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.PenMotionInput.pressure</code> | <code>pressure</code> | singular | <code>float</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.PenMotionInput.tilt_x_degrees</code> | <code>tiltXDegrees</code> | singular | <code>float</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.PenMotionInput.tilt_y_degrees</code> | <code>tiltYDegrees</code> | singular | <code>float</code> | — | — | no |
| 7 | <code>lumen.streaming.v4.PenMotionInput.rotation_degrees</code> | <code>rotationDegrees</code> | singular | <code>float</code> | — | — | no |

### message `lumen.streaming.v4.GamepadMotionInput`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.GamepadMotionInput.gamepad_id</code> | <code>gamepadId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.GamepadMotionInput.left_stick_x</code> | <code>leftStickX</code> | singular | <code>sint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.GamepadMotionInput.left_stick_y</code> | <code>leftStickY</code> | singular | <code>sint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.GamepadMotionInput.right_stick_x</code> | <code>rightStickX</code> | singular | <code>sint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.GamepadMotionInput.right_stick_y</code> | <code>rightStickY</code> | singular | <code>sint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.GamepadMotionInput.left_trigger</code> | <code>leftTrigger</code> | singular | <code>uint32</code> | — | — | no |
| 7 | <code>lumen.streaming.v4.GamepadMotionInput.right_trigger</code> | <code>rightTrigger</code> | singular | <code>uint32</code> | — | — | no |
| 8 | <code>lumen.streaming.v4.GamepadMotionInput.gyro_x</code> | <code>gyroX</code> | singular | <code>float</code> | — | — | no |
| 9 | <code>lumen.streaming.v4.GamepadMotionInput.gyro_y</code> | <code>gyroY</code> | singular | <code>float</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.GamepadMotionInput.gyro_z</code> | <code>gyroZ</code> | singular | <code>float</code> | — | — | no |
| 11 | <code>lumen.streaming.v4.GamepadMotionInput.acceleration_x</code> | <code>accelerationX</code> | singular | <code>float</code> | — | — | no |
| 12 | <code>lumen.streaming.v4.GamepadMotionInput.acceleration_y</code> | <code>accelerationY</code> | singular | <code>float</code> | — | — | no |
| 13 | <code>lumen.streaming.v4.GamepadMotionInput.acceleration_z</code> | <code>accelerationZ</code> | singular | <code>float</code> | — | — | no |

### message `lumen.streaming.v4.ClientMotionEnvelope`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.ClientMotionEnvelope.motion_sequence</code> | <code>motionSequence</code> | singular | <code>uint32</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.ClientMotionEnvelope.pointer_motion</code> | <code>pointerMotion</code> | singular | <code>message</code> | <code>lumen.streaming.v4.PointerMotionInput</code> | <code>payload</code> | no |
| 11 | <code>lumen.streaming.v4.ClientMotionEnvelope.scroll</code> | <code>scroll</code> | singular | <code>message</code> | <code>lumen.streaming.v4.ScrollInput</code> | <code>payload</code> | no |
| 12 | <code>lumen.streaming.v4.ClientMotionEnvelope.touch_motion</code> | <code>touchMotion</code> | singular | <code>message</code> | <code>lumen.streaming.v4.TouchMotionInput</code> | <code>payload</code> | no |
| 13 | <code>lumen.streaming.v4.ClientMotionEnvelope.pen_motion</code> | <code>penMotion</code> | singular | <code>message</code> | <code>lumen.streaming.v4.PenMotionInput</code> | <code>payload</code> | no |
| 14 | <code>lumen.streaming.v4.ClientMotionEnvelope.gamepad_motion</code> | <code>gamepadMotion</code> | singular | <code>message</code> | <code>lumen.streaming.v4.GamepadMotionInput</code> | <code>payload</code> | no |

Oneof declarations:

| Name | Kind | Members |
| --- | --- | --- |
| <code>lumen.streaming.v4.ClientMotionEnvelope.payload</code> | explicit | <code>lumen.streaming.v4.ClientMotionEnvelope.pointer_motion</code>, <code>lumen.streaming.v4.ClientMotionEnvelope.scroll</code>, <code>lumen.streaming.v4.ClientMotionEnvelope.touch_motion</code>, <code>lumen.streaming.v4.ClientMotionEnvelope.pen_motion</code>, <code>lumen.streaming.v4.ClientMotionEnvelope.gamepad_motion</code> |

### message `lumen.streaming.v4.InputAck`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.InputAck.highest_contiguous_event_sequence</code> | <code>highestContiguousEventSequence</code> | singular | <code>uint64</code> | — | — | no |

### message `lumen.streaming.v4.InputFailure`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.InputFailure.event_sequence</code> | <code>eventSequence</code> | singular | <code>uint64</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.InputFailure.code</code> | <code>code</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.InputFailureCode</code> | — | no |
| 3 | <code>lumen.streaming.v4.InputFailure.message</code> | <code>message</code> | singular | <code>string</code> | — | — | no |

### message `lumen.streaming.v4.InputReset`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.InputReset.reason</code> | <code>reason</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.RumbleCommand`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.RumbleCommand.gamepad_id</code> | <code>gamepadId</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.RumbleCommand.low_frequency_motor</code> | <code>lowFrequencyMotor</code> | singular | <code>uint32</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.RumbleCommand.high_frequency_motor</code> | <code>highFrequencyMotor</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.RumbleCommand.left_trigger_motor</code> | <code>leftTriggerMotor</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.RumbleCommand.right_trigger_motor</code> | <code>rightTriggerMotor</code> | singular | <code>uint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.RumbleCommand.duration_milliseconds</code> | <code>durationMilliseconds</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.HostInputEnvelope`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.HostInputEnvelope.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.HostInputEnvelope.command_sequence</code> | <code>commandSequence</code> | singular | <code>uint64</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.HostInputEnvelope.ack</code> | <code>ack</code> | singular | <code>message</code> | <code>lumen.streaming.v4.InputAck</code> | <code>payload</code> | no |
| 11 | <code>lumen.streaming.v4.HostInputEnvelope.reset</code> | <code>reset</code> | singular | <code>message</code> | <code>lumen.streaming.v4.InputReset</code> | <code>payload</code> | no |
| 12 | <code>lumen.streaming.v4.HostInputEnvelope.rumble</code> | <code>rumble</code> | singular | <code>message</code> | <code>lumen.streaming.v4.RumbleCommand</code> | <code>payload</code> | no |
| 13 | <code>lumen.streaming.v4.HostInputEnvelope.failure</code> | <code>failure</code> | singular | <code>message</code> | <code>lumen.streaming.v4.InputFailure</code> | <code>payload</code> | no |

Oneof declarations:

| Name | Kind | Members |
| --- | --- | --- |
| <code>lumen.streaming.v4.HostInputEnvelope.payload</code> | explicit | <code>lumen.streaming.v4.HostInputEnvelope.ack</code>, <code>lumen.streaming.v4.HostInputEnvelope.reset</code>, <code>lumen.streaming.v4.HostInputEnvelope.rumble</code>, <code>lumen.streaming.v4.HostInputEnvelope.failure</code> |

### message `lumen.streaming.v4.ProtocolError`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.ProtocolError.code</code> | <code>code</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.ProtocolError.message</code> | <code>message</code> | singular | <code>string</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.ProtocolError.negotiation_failure</code> | <code>negotiationFailure</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.NegotiationFailure</code> | — | no |

### message `lumen.streaming.v4.StartSessionAck`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.StartSessionAck.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.StopSession`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.StopSession.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.SessionStopped`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.SessionStopped.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.SessionStarted`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.SessionStarted.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.DisplayReconfigurationRequest`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.revision</code> | <code>revision</code> | singular | <code>uint64</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.width</code> | <code>width</code> | singular | <code>uint32</code> | — | — | no |
| 4 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.height</code> | <code>height</code> | singular | <code>uint32</code> | — | — | no |
| 5 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.refresh_millihz</code> | <code>refreshMillihz</code> | singular | <code>uint32</code> | — | — | no |
| 6 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.sink_hidpi</code> | <code>sinkHidpi</code> | singular | <code>bool</code> | — | — | no |
| 7 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.sink_scale_explicit</code> | <code>sinkScaleExplicit</code> | singular | <code>bool</code> | — | — | no |
| 8 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.sink_mode_is_logical</code> | <code>sinkModeIsLogical</code> | singular | <code>bool</code> | — | — | no |
| 9 | <code>lumen.streaming.v4.DisplayReconfigurationRequest.sink_scale_percent</code> | <code>sinkScalePercent</code> | singular | <code>uint32</code> | — | — | no |

### message `lumen.streaming.v4.DisplayReconfigurationResult`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.DisplayReconfigurationResult.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.DisplayReconfigurationResult.revision</code> | <code>revision</code> | singular | <code>uint64</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.DisplayReconfigurationResult.result</code> | <code>result</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.DisplayReconfigurationResultCode</code> | — | no |
| 4 | <code>lumen.streaming.v4.DisplayReconfigurationResult.plan</code> | <code>plan</code> | singular | <code>message</code> | <code>lumen.streaming.v4.HostSessionPlan</code> | — | no |
| 5 | <code>lumen.streaming.v4.DisplayReconfigurationResult.message</code> | <code>message</code> | singular | <code>string</code> | — | — | no |

### message `lumen.streaming.v4.MediaParkRequest`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.MediaParkRequest.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.MediaParkRequest.revision</code> | <code>revision</code> | singular | <code>uint64</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.MediaParkRequest.park</code> | <code>park</code> | singular | <code>bool</code> | — | — | no |

### message `lumen.streaming.v4.MediaParkResult`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.MediaParkResult.session_epoch</code> | <code>sessionEpoch</code> | singular | <code>uint32</code> | — | — | no |
| 2 | <code>lumen.streaming.v4.MediaParkResult.revision</code> | <code>revision</code> | singular | <code>uint64</code> | — | — | no |
| 3 | <code>lumen.streaming.v4.MediaParkResult.state</code> | <code>state</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.MediaParkState</code> | — | no |
| 4 | <code>lumen.streaming.v4.MediaParkResult.result</code> | <code>result</code> | singular | <code>enum</code> | <code>lumen.streaming.v4.MediaParkResultCode</code> | — | no |
| 5 | <code>lumen.streaming.v4.MediaParkResult.message</code> | <code>message</code> | singular | <code>string</code> | — | — | no |

### message `lumen.streaming.v4.ClientControlEnvelope`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.ClientControlEnvelope.request_id</code> | <code>requestId</code> | singular | <code>uint64</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.ClientControlEnvelope.hello</code> | <code>hello</code> | singular | <code>message</code> | <code>lumen.streaming.v4.ClientSessionHello</code> | <code>payload</code> | no |
| 11 | <code>lumen.streaming.v4.ClientControlEnvelope.start_session</code> | <code>startSession</code> | singular | <code>message</code> | <code>lumen.streaming.v4.StartSessionAck</code> | <code>payload</code> | no |
| 13 | <code>lumen.streaming.v4.ClientControlEnvelope.stop_session</code> | <code>stopSession</code> | singular | <code>message</code> | <code>lumen.streaming.v4.StopSession</code> | <code>payload</code> | no |
| 14 | <code>lumen.streaming.v4.ClientControlEnvelope.codec_configuration_ack</code> | <code>codecConfigurationAck</code> | singular | <code>message</code> | <code>lumen.streaming.v4.CodecConfigurationAck</code> | <code>payload</code> | no |
| 15 | <code>lumen.streaming.v4.ClientControlEnvelope.video_keyframe_request</code> | <code>videoKeyframeRequest</code> | singular | <code>message</code> | <code>lumen.streaming.v4.VideoKeyframeRequest</code> | <code>payload</code> | no |
| 16 | <code>lumen.streaming.v4.ClientControlEnvelope.video_bootstrap_result</code> | <code>videoBootstrapResult</code> | singular | <code>message</code> | <code>lumen.streaming.v4.VideoBootstrapResult</code> | <code>payload</code> | no |
| 17 | <code>lumen.streaming.v4.ClientControlEnvelope.display_reconfiguration</code> | <code>displayReconfiguration</code> | singular | <code>message</code> | <code>lumen.streaming.v4.DisplayReconfigurationRequest</code> | <code>payload</code> | no |
| 18 | <code>lumen.streaming.v4.ClientControlEnvelope.media_park</code> | <code>mediaPark</code> | singular | <code>message</code> | <code>lumen.streaming.v4.MediaParkRequest</code> | <code>payload</code> | no |

Oneof declarations:

| Name | Kind | Members |
| --- | --- | --- |
| <code>lumen.streaming.v4.ClientControlEnvelope.payload</code> | explicit | <code>lumen.streaming.v4.ClientControlEnvelope.hello</code>, <code>lumen.streaming.v4.ClientControlEnvelope.start_session</code>, <code>lumen.streaming.v4.ClientControlEnvelope.stop_session</code>, <code>lumen.streaming.v4.ClientControlEnvelope.codec_configuration_ack</code>, <code>lumen.streaming.v4.ClientControlEnvelope.video_keyframe_request</code>, <code>lumen.streaming.v4.ClientControlEnvelope.video_bootstrap_result</code>, <code>lumen.streaming.v4.ClientControlEnvelope.display_reconfiguration</code>, <code>lumen.streaming.v4.ClientControlEnvelope.media_park</code> |

Reserved tags: <code>12..&lt;13</code>.

### message `lumen.streaming.v4.HostControlEnvelope`

| Tag | Protobuf field | JSON field | Label | Type kind | Type name | Oneof | Proto3 optional |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | <code>lumen.streaming.v4.HostControlEnvelope.request_id</code> | <code>requestId</code> | singular | <code>uint64</code> | — | — | no |
| 10 | <code>lumen.streaming.v4.HostControlEnvelope.session_plan</code> | <code>sessionPlan</code> | singular | <code>message</code> | <code>lumen.streaming.v4.HostSessionPlan</code> | <code>payload</code> | no |
| 12 | <code>lumen.streaming.v4.HostControlEnvelope.session_stopped</code> | <code>sessionStopped</code> | singular | <code>message</code> | <code>lumen.streaming.v4.SessionStopped</code> | <code>payload</code> | no |
| 13 | <code>lumen.streaming.v4.HostControlEnvelope.error</code> | <code>error</code> | singular | <code>message</code> | <code>lumen.streaming.v4.ProtocolError</code> | <code>payload</code> | no |
| 15 | <code>lumen.streaming.v4.HostControlEnvelope.session_started</code> | <code>sessionStarted</code> | singular | <code>message</code> | <code>lumen.streaming.v4.SessionStarted</code> | <code>payload</code> | no |
| 16 | <code>lumen.streaming.v4.HostControlEnvelope.display_reconfiguration</code> | <code>displayReconfiguration</code> | singular | <code>message</code> | <code>lumen.streaming.v4.DisplayReconfigurationResult</code> | <code>payload</code> | no |
| 17 | <code>lumen.streaming.v4.HostControlEnvelope.media_park</code> | <code>mediaPark</code> | singular | <code>message</code> | <code>lumen.streaming.v4.MediaParkResult</code> | <code>payload</code> | no |

Oneof declarations:

| Name | Kind | Members |
| --- | --- | --- |
| <code>lumen.streaming.v4.HostControlEnvelope.payload</code> | explicit | <code>lumen.streaming.v4.HostControlEnvelope.session_plan</code>, <code>lumen.streaming.v4.HostControlEnvelope.session_stopped</code>, <code>lumen.streaming.v4.HostControlEnvelope.error</code>, <code>lumen.streaming.v4.HostControlEnvelope.session_started</code>, <code>lumen.streaming.v4.HostControlEnvelope.display_reconfiguration</code>, <code>lumen.streaming.v4.HostControlEnvelope.media_park</code> |

Reserved tags: <code>11..&lt;12</code>, <code>14..&lt;15</code>.

## Native QUIC transport

This is the non-protobuf authority for the single QUIC v1/TLS 1.3 connection, fixed stream roles, QUIC DATAGRAM media plane, native headers, FEC, capabilities, validation, and typed transport failures.

| Property | Value |
| --- | --- |
| `protocol` | <code>lumen-stream</code> |
| `transportName` | <code>Lumen Object Transport</code> |
| `version` | <code>4</code> |
| `alpn` | <code>lumen-stream/4</code> |
| `sessionProtocolVersion` | <code>4</code> |
| `controlTransport` | <code>quic-v1-tls-1.3</code> |
| `mediaPlane` | <code>quic-datagram</code> |
| `applicationMediaEncryption` | <code>false</code> |
| `directMediaUdp` | <code>false</code> |

### Fixed QUIC stream roles

| Direction | Role | Raw stream ID or rule |
| --- | --- | ---: |
| client bidirectional | `control` | <code>0</code> |
| client bidirectional | `reliableInput` | <code>4</code> |
| client bidirectional | `telemetry` | <code>8</code> |
| host unidirectional | `clientMinimumCredit` | <code>8</code> |
| host unidirectional | `codecConfiguration` | <code>3</code> |
| host unidirectional | `firstVideoBootstrap` | <code>7</code> |
| host unidirectional | `videoBootstrapStride` | <code>4</code> |

### Message limits

| Property | Value |
| --- | --- |
| <code>codecConfigurationBytes</code> | <code>32768</code> |
| <code>controlBytes</code> | <code>32768</code> |
| <code>inputBytes</code> | <code>32768</code> |
| <code>telemetryBytes</code> | <code>32768</code> |
| <code>videoBootstrapBytes</code> | <code>16777216</code> |

### HostSessionPlan field tags

| Property | Value |
| --- | --- |
| <code>maximumObjectDelayUsField</code> | <code>45</code> |
| <code>mediaCapabilitiesField</code> | <code>46</code> |
| <code>selectedVideoCapabilityField</code> | <code>44</code> |

### Video bootstrap

| Property | Value |
| --- | --- |
| <code>deltaAdmission</code> | <code>after-hardware-decoded-result</code> |
| <code>initialGenerationId</code> | <code>1</code> |
| <code>periodicByDefault</code> | <code>true</code> |
| <code>periodicEncoderResume</code> | <code>only-when-platform-paused</code> |
| <code>resultCodes</code> | <code>{"decoded":1,"decoderRejected":2,"stale":3,"unspecified":0}</code> |
| <code>resultControlTag</code> | <code>16</code> |

### QUIC DATAGRAM media header

Base header bytes: <code>28</code>. Byte order: <code>network</code>.

| Field | Offset | Bytes |
| --- | ---: | ---: |
| `kind` | 0 | 1 |
| `flags` | 1 | 1 |
| `headerBytes` | 2 | 2 |
| `generationId` | 4 | 4 |
| `datagramSequence` | 8 | 4 |
| `objectId` | 12 | 4 |
| `objectBytes` | 16 | 4 |
| `captureTimestampUs` | 20 | 4 |
| `shardIndex` | 24 | 1 |
| `dataShards` | 25 | 1 |
| `parityShards` | 26 | 1 |
| `reserved` | 27 | 1 |

### FEC block extension

Extension bytes: <code>8</code>.

| Field | Offset | Bytes |
| --- | ---: | ---: |
| <code>blockIndex</code> | 28 | 1 |
| <code>blockCount</code> | 29 | 1 |
| <code>reserved</code> | 30 | 2 |
| <code>objectPayloadOffset</code> | 32 | 4 |

### Media, FEC, telemetry, capabilities, and validation

#### `nativeTransport.mediaKinds`

```json
{
  "audio" : 2,
  "inputMotion" : 3,
  "videoDelta" : 1
}
```

#### `nativeTransport.flags`

```json
{
  "fecBlock" : 32,
  "keyframe" : 1,
  "parityShard" : 16
}
```

#### `nativeTransport.fec`

```json
{
  "algorithm" : "systematic-reed-solomon-vandermonde-gf256",
  "compactSingleShardAudio" : "exact-object-bytes-without-padding",
  "fieldPolynomial" : 285,
  "generator" : 2,
  "maximumTotalShardsPerBlock" : 256,
  "padding" : "zero-pad-data-before-parity",
  "scope" : "plaintext-quic-datagram-payload"
}
```

#### `nativeTransport.telemetry`

```json
{
  "envelope" : "ClientTelemetryEnvelope",
  "mediaFeedbackTag" : 10,
  "parityRangePercentage" : [
    5,
    50
  ],
  "parityStepPercentage" : 5,
  "sequence" : "nonzero-contiguous",
  "streamId" : 8
}
```

#### `nativeTransport.mediaCapabilities`

```json
{
  "continuousScroll" : 4,
  "fixedCadenceFeedback" : 2,
  "mediaParkResume" : 32,
  "packetArrivalFeedback" : 16,
  "pairedFeedbackWindows" : 8,
  "requiredMask" : 15,
  "sameGenerationKeyframes" : 1,
  "supportedMask" : 63
}
```

#### `nativeTransport.dynamicRangeTransport`

```json
{
  "frameGatedHdr" : 3,
  "fullFrameHdr" : 2,
  "sdr" : 1,
  "sdrBaseHdrOverlay" : 4,
  "unknown" : 0
}
```

#### `nativeTransport.validation`

```json
{
  "missingRequiredCapability" : "reject-before-capture",
  "reservedFields" : "reject",
  "reservedFlags" : "reject",
  "staleGeneration" : "reject",
  "unknownControlPayload" : "reject",
  "unknownMediaKind" : "reject"
}
```

#### `nativeTransport.transportErrors`

```json
[
  "header-too-short",
  "invalid-header-length",
  "invalid-media-kind",
  "reserved-flags",
  "reserved-field",
  "invalid-generation",
  "invalid-object-length",
  "invalid-shard-plan",
  "invalid-parity-flag",
  "missing-fec-block-extension",
  "invalid-fec-block-extension",
  "invalid-motion-contract"
]
```

#### `nativeTransport.packetArrivalFeedbackErrors`

```json
[
  "packet-arrival-unsupported",
  "packet-arrival-missing-field",
  "packet-arrival-malformed-run",
  "packet-arrival-delta-overflow",
  "packet-arrival-count-mismatch",
  "packet-arrival-payload-too-large",
  "packet-arrival-sequence-range-mismatch",
  "packet-arrival-untracked-datagram",
  "packet-arrival-history-unavailable"
]
```

#### `nativeTransport.forbiddenCompatibilityProtocols`

```json
[
  "lumen-stream/3",
  "direct-media-udp",
  "media-path-probe",
  "exporter-media-key",
  "application-aes-gcm",
  "gamestream",
  "rtsp",
  "sdp",
  "rtp",
  "enet"
]
```


### Complete native transport authority

```json
{
  "alpn" : "lumen-stream/4",
  "applicationMediaEncryption" : false,
  "clientBidirectionalStreams" : {
    "control" : 0,
    "reliableInput" : 4,
    "telemetry" : 8
  },
  "controlTransport" : "quic-v1-tls-1.3",
  "directMediaUdp" : false,
  "dynamicRangeTransport" : {
    "frameGatedHdr" : 3,
    "fullFrameHdr" : 2,
    "sdr" : 1,
    "sdrBaseHdrOverlay" : 4,
    "unknown" : 0
  },
  "fec" : {
    "algorithm" : "systematic-reed-solomon-vandermonde-gf256",
    "compactSingleShardAudio" : "exact-object-bytes-without-padding",
    "fieldPolynomial" : 285,
    "generator" : 2,
    "maximumTotalShardsPerBlock" : 256,
    "padding" : "zero-pad-data-before-parity",
    "scope" : "plaintext-quic-datagram-payload"
  },
  "fecBlockExtension" : {
    "bytes" : 8,
    "fields" : [
      {
        "bytes" : 1,
        "name" : "blockIndex",
        "offset" : 28
      },
      {
        "bytes" : 1,
        "name" : "blockCount",
        "offset" : 29
      },
      {
        "bytes" : 2,
        "name" : "reserved",
        "offset" : 30
      },
      {
        "bytes" : 4,
        "name" : "objectPayloadOffset",
        "offset" : 32
      }
    ]
  },
  "flags" : {
    "fecBlock" : 32,
    "keyframe" : 1,
    "parityShard" : 16
  },
  "forbiddenCompatibilityProtocols" : [
    "lumen-stream/3",
    "direct-media-udp",
    "media-path-probe",
    "exporter-media-key",
    "application-aes-gcm",
    "gamestream",
    "rtsp",
    "sdp",
    "rtp",
    "enet"
  ],
  "hostSessionPlan" : {
    "maximumObjectDelayUsField" : 45,
    "mediaCapabilitiesField" : 46,
    "selectedVideoCapabilityField" : 44
  },
  "hostUnidirectionalStreams" : {
    "clientMinimumCredit" : 8,
    "codecConfiguration" : 3,
    "firstVideoBootstrap" : 7,
    "videoBootstrapStride" : 4
  },
  "mediaCapabilities" : {
    "continuousScroll" : 4,
    "fixedCadenceFeedback" : 2,
    "mediaParkResume" : 32,
    "packetArrivalFeedback" : 16,
    "pairedFeedbackWindows" : 8,
    "requiredMask" : 15,
    "sameGenerationKeyframes" : 1,
    "supportedMask" : 63
  },
  "mediaDatagramHeader" : {
    "byteOrder" : "network",
    "bytes" : 28,
    "fecBlockBytes" : 36,
    "fields" : [
      {
        "bytes" : 1,
        "name" : "kind",
        "offset" : 0
      },
      {
        "bytes" : 1,
        "name" : "flags",
        "offset" : 1
      },
      {
        "bytes" : 2,
        "name" : "headerBytes",
        "offset" : 2
      },
      {
        "bytes" : 4,
        "name" : "generationId",
        "offset" : 4
      },
      {
        "bytes" : 4,
        "name" : "datagramSequence",
        "offset" : 8
      },
      {
        "bytes" : 4,
        "name" : "objectId",
        "offset" : 12
      },
      {
        "bytes" : 4,
        "name" : "objectBytes",
        "offset" : 16
      },
      {
        "bytes" : 4,
        "name" : "captureTimestampUs",
        "offset" : 20
      },
      {
        "bytes" : 1,
        "name" : "shardIndex",
        "offset" : 24
      },
      {
        "bytes" : 1,
        "name" : "dataShards",
        "offset" : 25
      },
      {
        "bytes" : 1,
        "name" : "parityShards",
        "offset" : 26
      },
      {
        "bytes" : 1,
        "name" : "reserved",
        "offset" : 27
      }
    ]
  },
  "mediaKinds" : {
    "audio" : 2,
    "inputMotion" : 3,
    "videoDelta" : 1
  },
  "mediaPlane" : "quic-datagram",
  "messageLimits" : {
    "codecConfigurationBytes" : 32768,
    "controlBytes" : 32768,
    "inputBytes" : 32768,
    "telemetryBytes" : 32768,
    "videoBootstrapBytes" : 16777216
  },
  "packetArrivalFeedbackErrors" : [
    "packet-arrival-unsupported",
    "packet-arrival-missing-field",
    "packet-arrival-malformed-run",
    "packet-arrival-delta-overflow",
    "packet-arrival-count-mismatch",
    "packet-arrival-payload-too-large",
    "packet-arrival-sequence-range-mismatch",
    "packet-arrival-untracked-datagram",
    "packet-arrival-history-unavailable"
  ],
  "protocol" : "lumen-stream",
  "sessionProtocolVersion" : 4,
  "telemetry" : {
    "envelope" : "ClientTelemetryEnvelope",
    "mediaFeedbackTag" : 10,
    "parityRangePercentage" : [
      5,
      50
    ],
    "parityStepPercentage" : 5,
    "sequence" : "nonzero-contiguous",
    "streamId" : 8
  },
  "transportErrors" : [
    "header-too-short",
    "invalid-header-length",
    "invalid-media-kind",
    "reserved-flags",
    "reserved-field",
    "invalid-generation",
    "invalid-object-length",
    "invalid-shard-plan",
    "invalid-parity-flag",
    "missing-fec-block-extension",
    "invalid-fec-block-extension",
    "invalid-motion-contract"
  ],
  "transportName" : "Lumen Object Transport",
  "validation" : {
    "missingRequiredCapability" : "reject-before-capture",
    "reservedFields" : "reject",
    "reservedFlags" : "reject",
    "staleGeneration" : "reject",
    "unknownControlPayload" : "reject",
    "unknownMediaKind" : "reject"
  },
  "version" : 4,
  "videoBootstrap" : {
    "deltaAdmission" : "after-hardware-decoded-result",
    "initialGenerationId" : 1,
    "periodicByDefault" : true,
    "periodicEncoderResume" : "only-when-platform-paused",
    "resultCodes" : {
      "decoded" : 1,
      "decoderRejected" : 2,
      "stale" : 3,
      "unspecified" : 0
    },
    "resultControlTag" : 16
  }
}
```

## HTTPS authentication API

### Authentication routes

| Route identifier | Method | Path | Authentication behavior |
| --- | --- | --- | --- |
| <code>enroll</code> | <code>POST</code> | <code>/api/v1/auth/enroll</code> | declared authentication route |
| <code>enrollmentChallenge</code> | <code>POST</code> | <code>/api/v1/auth/enrollment-challenge</code> | declared authentication route |
| <code>revokeDevice</code> | <code>POST</code> | <code>/api/v1/auth/revoke</code> | declared authentication route |
| <code>tokenExchange</code> | <code>POST</code> | <code>/api/v1/auth/token</code> | declared authentication route |
| <code>tokenExchangeChallenge</code> | <code>POST</code> | <code>/api/v1/auth/token-challenge</code> | declared authentication route |
| <code>controlDiscoveryHost</code> | <code>GET</code> | <code>/api/discovery/host</code> | conditional |
| <code>controlDiscoveryApps</code> | <code>GET</code> | <code>/api/discovery/apps</code> | device authentication required |
| <code>streamCancel</code> | <code>GET</code> | <code>/cancel</code> | device authentication required |
| <code>streamClipboardRead</code> | <code>GET</code> | <code>/actions/clipboard</code> | device authentication required |
| <code>streamClipboardWrite</code> | <code>POST</code> | <code>/actions/clipboard</code> | device authentication required |
| <code>streamLaunch</code> | <code>GET</code> | <code>/launch</code> | device authentication required |
| <code>streamResume</code> | <code>GET</code> | <code>/resume</code> | device authentication required |

### authentication operation `enroll`

Request shape:

```json
{
  "challengeId" : "opaque-id",
  "challengeSignature" : "base64url-asn1-der-signature",
  "deviceName" : "Living Room Tablet",
  "ownerPassword" : "one-time-owner-secret",
  "ownerUsername" : "owner",
  "platform" : "ios",
  "publicKey" : "base64url-x9.63-public-key"
}
```

Response shape:

```json
{
  "credentialType" : "lumen-device-refresh",
  "deviceId" : "opaque-device-id",
  "refreshToken" : "one-time-refresh-token"
}
```

### authentication operation `enrollmentChallenge`

Request shape:

```json
{
  "publicKey" : "base64url-x9.63-public-key"
}
```

Response shape:

```json
{
  "algorithm" : "p256-ecdsa-sha256",
  "challenge" : "base64url-random-32-bytes",
  "challengeId" : "opaque-id",
  "expiresAtUnixSeconds" : 1700000300,
  "purpose" : "enrollment"
}
```

### authentication operation `exchangeRefreshToken`

Request shape:

```json
{
  "challengeId" : "opaque-id",
  "challengeSignature" : "base64url-asn1-der-signature",
  "deviceId" : "opaque-device-id",
  "refreshToken" : "current-refresh-token"
}
```

Response shape:

```json
{
  "accessToken" : "short-lived-access-token",
  "deviceId" : "opaque-device-id",
  "expiresAtUnixSeconds" : 1700000900,
  "refreshToken" : "rotated-refresh-token",
  "tokenType" : "Bearer"
}
```

### authentication operation `revokeDevice`

Request shape:

```json
{
  "deviceId" : "opaque-device-id",
  "ownerPassword" : "owner-secret",
  "ownerUsername" : "owner"
}
```

Response shape:

```json
{
  "revoked" : true
}
```

### authentication operation `tokenExchangeChallenge`

Request shape:

```json
{
  "deviceId" : "opaque-device-id"
}
```

Response shape:

```json
{
  "algorithm" : "p256-ecdsa-sha256",
  "challenge" : "base64url-random-32-bytes",
  "challengeId" : "opaque-id",
  "deviceId" : "opaque-device-id",
  "expiresAtUnixSeconds" : 1700000300,
  "purpose" : "token-exchange"
}
```

### authentication operation `verifyAccessToken`

Request shape:

```json
{
  "accessToken" : "short-lived-access-token",
  "deviceId" : "opaque-device-id"
}
```

Response shape:

```json
{
  "authorized" : true
}
```

### authentication authority `accessRequestAuthentication`

```json
{
  "authorizationHeader" : "Authorization: Bearer <accessToken>",
  "authorizationHeaderName" : {
    "matching" : "ascii-case-insensitive",
    "name" : "Authorization"
  },
  "authorizationScheme" : {
    "matching" : "ascii-case-insensitive",
    "name" : "Bearer",
    "tokenMatching" : "opaque-exact"
  },
  "basicAuthentication" : "forbidden",
  "cookies" : "forbidden",
  "deviceIdHeader" : {
    "matching" : "ascii-case-insensitive",
    "name" : "Lumen-Device-ID",
    "valueMatching" : "opaque-exact"
  },
  "queryParameters" : "forbidden"
}
```

### authentication authority `credentialPolicy`

```json
{
  "accessTokenLifetimeSeconds" : 900,
  "accessTokenPersistence" : "sha256-hash-only",
  "activeAccessTokensPerDevice" : 1,
  "factoryReset" : "invalidate-all",
  "refreshTokenPersistence" : "sha256-hash-only",
  "refreshTokenRotation" : "required",
  "revocation" : "immediate"
}
```

### authentication authority `deviceEnrollmentPolicy`

```json
{
  "configKey" : "device_enrollment_enabled",
  "disabledError" : "device-enrollment-disabled",
  "existingDeviceAuthentication" : "unaffected",
  "scope" : "network-reachable-host"
}
```

### authentication authority `idempotency`

```json
{
  "key" : "operation-plus-requestId",
  "maximumRetainedResponses" : 256,
  "requestIdCollision" : "invalid-request",
  "retention" : "bounded-in-memory",
  "retryMatch" : "exact-request-body"
}
```

### authentication authority `possessionProof`

```json
{
  "algorithm" : "p256-ecdsa-sha256",
  "challengeLength" : 32,
  "challengeLifetimeSeconds" : 300,
  "challengeUse" : "single-use",
  "publicKeyEncoding" : "ansi-x9.63-uncompressed",
  "publicKeyLength" : 65,
  "publicKeyTransportEncoding" : "base64url-no-pad",
  "signatureEncoding" : "asn1-der",
  "signatureTransportEncoding" : "base64url-no-pad",
  "signingMessages" : {
    "enrollment" : {
      "components" : [
        "ascii:LUMEN-AUTH-ENROLLMENT-V1",
        "hex:00",
        "base64url-decoded-challenge"
      ],
      "encoding" : "binary-concatenation"
    },
    "tokenExchange" : {
      "components" : [
        "ascii:LUMEN-AUTH-TOKEN-EXCHANGE-V1",
        "hex:00",
        "utf8-device-id",
        "hex:00",
        "base64url-decoded-challenge"
      ],
      "encoding" : "binary-concatenation"
    }
  }
}
```

### authentication authority `envelopes`

```json
{
  "error" : {
    "error" : {
      "code" : "revoked",
      "message" : "The device credential has been revoked.",
      "retryable" : false
    },
    "requestId" : "stable-request-id",
    "schemaVersion" : 1
  },
  "request" : {
    "request" : {

    },
    "requestId" : "stable-request-id",
    "schemaVersion" : 1
  },
  "success" : {
    "requestId" : "stable-request-id",
    "result" : {

    },
    "schemaVersion" : 1
  }
}
```

### Authentication error codes

- `invalid-request`
- `device-enrollment-disabled`
- `invalid-owner-credentials`
- `invalid-challenge`
- `challenge-expired`
- `invalid-signature`
- `invalid-device-credential`
- `access-token-expired`
- `revoked`
- `storage-unavailable`
- `corrupt-authority`

### Complete authentication authority

```json
{
  "accessRequestAuthentication" : {
    "authorizationHeader" : "Authorization: Bearer <accessToken>",
    "authorizationHeaderName" : {
      "matching" : "ascii-case-insensitive",
      "name" : "Authorization"
    },
    "authorizationScheme" : {
      "matching" : "ascii-case-insensitive",
      "name" : "Bearer",
      "tokenMatching" : "opaque-exact"
    },
    "basicAuthentication" : "forbidden",
    "cookies" : "forbidden",
    "deviceIdHeader" : {
      "matching" : "ascii-case-insensitive",
      "name" : "Lumen-Device-ID",
      "valueMatching" : "opaque-exact"
    },
    "queryParameters" : "forbidden"
  },
  "conditionalRoutes" : {
    "controlDiscoveryHost" : {
      "method" : "GET",
      "path" : "/api/discovery/host",
      "withInvalidDeviceAuthentication" : "authentication-error",
      "withoutAuthentication" : "public-host-identity",
      "withValidDeviceAuthentication" : "authenticated-host-descriptor"
    }
  },
  "credentialPolicy" : {
    "accessTokenLifetimeSeconds" : 900,
    "accessTokenPersistence" : "sha256-hash-only",
    "activeAccessTokensPerDevice" : 1,
    "factoryReset" : "invalidate-all",
    "refreshTokenPersistence" : "sha256-hash-only",
    "refreshTokenRotation" : "required",
    "revocation" : "immediate"
  },
  "deviceEnrollmentPolicy" : {
    "configKey" : "device_enrollment_enabled",
    "disabledError" : "device-enrollment-disabled",
    "existingDeviceAuthentication" : "unaffected",
    "scope" : "network-reachable-host"
  },
  "envelopes" : {
    "error" : {
      "error" : {
        "code" : "revoked",
        "message" : "The device credential has been revoked.",
        "retryable" : false
      },
      "requestId" : "stable-request-id",
      "schemaVersion" : 1
    },
    "request" : {
      "request" : {

      },
      "requestId" : "stable-request-id",
      "schemaVersion" : 1
    },
    "success" : {
      "requestId" : "stable-request-id",
      "result" : {

      },
      "schemaVersion" : 1
    }
  },
  "errorCodes" : [
    "invalid-request",
    "device-enrollment-disabled",
    "invalid-owner-credentials",
    "invalid-challenge",
    "challenge-expired",
    "invalid-signature",
    "invalid-device-credential",
    "access-token-expired",
    "revoked",
    "storage-unavailable",
    "corrupt-authority"
  ],
  "idempotency" : {
    "key" : "operation-plus-requestId",
    "maximumRetainedResponses" : 256,
    "requestIdCollision" : "invalid-request",
    "retention" : "bounded-in-memory",
    "retryMatch" : "exact-request-body"
  },
  "networkTransport" : {
    "contentType" : "application/json",
    "maximumRequestBytes" : 32768,
    "method" : "POST",
    "routes" : {
      "enroll" : "/api/v1/auth/enroll",
      "enrollmentChallenge" : "/api/v1/auth/enrollment-challenge",
      "revokeDevice" : "/api/v1/auth/revoke",
      "tokenExchange" : "/api/v1/auth/token",
      "tokenExchangeChallenge" : "/api/v1/auth/token-challenge"
    },
    "scheme" : "https"
  },
  "operations" : {
    "enroll" : {
      "request" : {
        "challengeId" : "opaque-id",
        "challengeSignature" : "base64url-asn1-der-signature",
        "deviceName" : "Living Room Tablet",
        "ownerPassword" : "one-time-owner-secret",
        "ownerUsername" : "owner",
        "platform" : "ios",
        "publicKey" : "base64url-x9.63-public-key"
      },
      "response" : {
        "credentialType" : "lumen-device-refresh",
        "deviceId" : "opaque-device-id",
        "refreshToken" : "one-time-refresh-token"
      }
    },
    "enrollmentChallenge" : {
      "request" : {
        "publicKey" : "base64url-x9.63-public-key"
      },
      "response" : {
        "algorithm" : "p256-ecdsa-sha256",
        "challenge" : "base64url-random-32-bytes",
        "challengeId" : "opaque-id",
        "expiresAtUnixSeconds" : 1700000300,
        "purpose" : "enrollment"
      }
    },
    "exchangeRefreshToken" : {
      "request" : {
        "challengeId" : "opaque-id",
        "challengeSignature" : "base64url-asn1-der-signature",
        "deviceId" : "opaque-device-id",
        "refreshToken" : "current-refresh-token"
      },
      "response" : {
        "accessToken" : "short-lived-access-token",
        "deviceId" : "opaque-device-id",
        "expiresAtUnixSeconds" : 1700000900,
        "refreshToken" : "rotated-refresh-token",
        "tokenType" : "Bearer"
      }
    },
    "revokeDevice" : {
      "request" : {
        "deviceId" : "opaque-device-id",
        "ownerPassword" : "owner-secret",
        "ownerUsername" : "owner"
      },
      "response" : {
        "revoked" : true
      }
    },
    "tokenExchangeChallenge" : {
      "request" : {
        "deviceId" : "opaque-device-id"
      },
      "response" : {
        "algorithm" : "p256-ecdsa-sha256",
        "challenge" : "base64url-random-32-bytes",
        "challengeId" : "opaque-id",
        "deviceId" : "opaque-device-id",
        "expiresAtUnixSeconds" : 1700000300,
        "purpose" : "token-exchange"
      }
    },
    "verifyAccessToken" : {
      "request" : {
        "accessToken" : "short-lived-access-token",
        "deviceId" : "opaque-device-id"
      },
      "response" : {
        "authorized" : true
      }
    }
  },
  "possessionProof" : {
    "algorithm" : "p256-ecdsa-sha256",
    "challengeLength" : 32,
    "challengeLifetimeSeconds" : 300,
    "challengeUse" : "single-use",
    "publicKeyEncoding" : "ansi-x9.63-uncompressed",
    "publicKeyLength" : 65,
    "publicKeyTransportEncoding" : "base64url-no-pad",
    "signatureEncoding" : "asn1-der",
    "signatureTransportEncoding" : "base64url-no-pad",
    "signingMessages" : {
      "enrollment" : {
        "components" : [
          "ascii:LUMEN-AUTH-ENROLLMENT-V1",
          "hex:00",
          "base64url-decoded-challenge"
        ],
        "encoding" : "binary-concatenation"
      },
      "tokenExchange" : {
        "components" : [
          "ascii:LUMEN-AUTH-TOKEN-EXCHANGE-V1",
          "hex:00",
          "utf8-device-id",
          "hex:00",
          "base64url-decoded-challenge"
        ],
        "encoding" : "binary-concatenation"
      }
    }
  },
  "protectedRoutes" : {
    "controlDiscoveryApps" : {
      "method" : "GET",
      "path" : "/api/discovery/apps"
    },
    "streamCancel" : {
      "method" : "GET",
      "path" : "/cancel"
    },
    "streamClipboardRead" : {
      "method" : "GET",
      "path" : "/actions/clipboard"
    },
    "streamClipboardWrite" : {
      "method" : "POST",
      "path" : "/actions/clipboard"
    },
    "streamLaunch" : {
      "method" : "GET",
      "path" : "/launch"
    },
    "streamResume" : {
      "method" : "GET",
      "path" : "/resume"
    }
  },
  "protocolName" : "lumen-auth",
  "schemaVersion" : 1,
  "transport" : "source-neutral"
}
```

## HTTPS settings API

### Settings routes

| Operation | Method | Path |
| --- | --- | --- |
| `events` | `GET` | `/api/v1/settings/events` |
| `patch` | `PATCH` | `/api/v1/settings` |
| `snapshot` | `GET` | `/api/v1/settings` |

### Settings envelope members

| Envelope | Declared members |
| --- | --- |
| <code>event</code> | <code>schemaVersion</code>, <code>revision</code>, <code>settings</code>, <code>effective</code>, <code>applyState</code> |
| <code>patchRequest</code> | <code>schemaVersion</code>, <code>baseRevision</code>, <code>requestId</code>, <code>changes</code> |
| <code>patchResponse</code> | <code>schemaVersion</code>, <code>revision</code>, <code>accepted</code>, <code>effective</code>, <code>applyState</code>, <code>requires</code> |
| <code>snapshot</code> | <code>schemaVersion</code>, <code>revision</code>, <code>settings</code>, <code>effective</code>, <code>applyState</code>, <code>capabilities</code> |

### Settings fields

| Order | Key | Title | Section | Type | Editor | Apply class | Availability | Constraints |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | <code>general.name</code> | <code>Name</code> | <code>general</code> | <code>string</code> | <code>text</code> | <code>live</code> | <code>all</code> | <code>{"maxLength":64}</code> |
| 20 | <code>network.fecPercentage</code> | <code>Forward error correction</code> | <code>network</code> | <code>integer</code> | <code>integer-menu</code> | <code>next-session</code> | <code>all</code> | <code>{"maximum":255,"minimum":1,"presets":[5,10,15,20,25,30,40,50],"step":1,"valueLabels":{"5":"5%","10":"10%","15":"15%","20":"20%","25":"25%","30":"30%","40":"40%","50":"50%"}}</code> |
| 30 | <code>commands.prep</code> | <code>Preparation commands</code> | <code>commands</code> | <code>command-list</code> | <code>prep-command-list</code> | <code>next-session</code> | <code>host-capability</code> | <code>{"values":["user","administrator"]}</code> |
| 40 | <code>commands.state</code> | <code>State commands</code> | <code>commands</code> | <code>command-list</code> | <code>prep-command-list</code> | <code>next-session</code> | <code>host-capability</code> | <code>{"values":["user","administrator"]}</code> |
| 50 | <code>commands.server</code> | <code>Server commands</code> | <code>commands</code> | <code>command-list</code> | <code>server-command-list</code> | <code>next-session</code> | <code>host-capability</code> | <code>{"values":["user","administrator"]}</code> |

### settings authority `applyStates`

```json
[
  "applied",
  "pending-next-session",
  "pending-worker-restart"
]
```

### settings authority `applyClasses`

```json
[
  "live",
  "next-session",
  "worker-restart"
]
```

### settings authority `requires`

```json
[
  "none",
  "next-session",
  "worker-restart"
]
```

### settings authority `requestId`

```json
{
  "encoding" : "non-whitespace-ascii",
  "maximumLength" : 128,
  "minimumLength" : 1
}
```

### settings authority `retention`

```json
{
  "events" : 128,
  "idempotencyRecords" : 256
}
```

### settings authority `commandContract`

```json
{
  "execution" : "argv-without-shell",
  "maximumArgumentLength" : 1024,
  "maximumArgumentsPerInvocation" : 64,
  "maximumEntriesPerList" : 64,
  "privileges" : [
    "user",
    "administrator"
  ],
  "programPattern" : "^[A-Za-z0-9._-]+$"
}
```

### settings authority `forbiddenRemoteKeys`

```json
[
  "applicationsFilePath",
  "accessToken",
  "certificatePath",
  "controlLocation",
  "credentialsFilePath",
  "logFilePath",
  "ownerPassword",
  "deviceEnrollmentEnabled",
  "privateKeyPath",
  "refreshToken",
  "remoteSettingsAllowed",
  "stateFilePath",
  "systemAuthenticationEnabled"
]
```

### settings authority `platformCapabilities`

```json
{
  "macos" : {
    "commandPrivileges" : [
      "user"
    ]
  },
  "windows" : {
    "commandPrivileges" : [
      "user",
      "administrator"
    ]
  }
}
```

### Settings error codes

- `unsupported-schema`
- `invalid-request`
- `unknown-field`
- `forbidden-field`
- `unavailable-field`
- `invalid-value`
- `stale-revision`
- `request-id-conflict`
- `revision-not-retained`
- `storage-error`
- `corrupt-data`

### Complete settings authority

```json
{
  "applyClasses" : [
    "live",
    "next-session",
    "worker-restart"
  ],
  "applyStates" : [
    "applied",
    "pending-next-session",
    "pending-worker-restart"
  ],
  "commandContract" : {
    "execution" : "argv-without-shell",
    "maximumArgumentLength" : 1024,
    "maximumArgumentsPerInvocation" : 64,
    "maximumEntriesPerList" : 64,
    "privileges" : [
      "user",
      "administrator"
    ],
    "programPattern" : "^[A-Za-z0-9._-]+$"
  },
  "envelopes" : {
    "event" : [
      "schemaVersion",
      "revision",
      "settings",
      "effective",
      "applyState"
    ],
    "patchRequest" : [
      "schemaVersion",
      "baseRevision",
      "requestId",
      "changes"
    ],
    "patchResponse" : [
      "schemaVersion",
      "revision",
      "accepted",
      "effective",
      "applyState",
      "requires"
    ],
    "snapshot" : [
      "schemaVersion",
      "revision",
      "settings",
      "effective",
      "applyState",
      "capabilities"
    ]
  },
  "errorCodes" : [
    "unsupported-schema",
    "invalid-request",
    "unknown-field",
    "forbidden-field",
    "unavailable-field",
    "invalid-value",
    "stale-revision",
    "request-id-conflict",
    "revision-not-retained",
    "storage-error",
    "corrupt-data"
  ],
  "fields" : [
    {
      "applyClass" : "live",
      "availability" : "all",
      "editor" : "text",
      "key" : "general.name",
      "maxLength" : 64,
      "order" : 10,
      "sectionId" : "general",
      "sectionTitle" : "General",
      "title" : "Name",
      "type" : "string"
    },
    {
      "applyClass" : "next-session",
      "availability" : "all",
      "editor" : "integer-menu",
      "key" : "network.fecPercentage",
      "maximum" : 255,
      "minimum" : 1,
      "order" : 20,
      "presets" : [
        5,
        10,
        15,
        20,
        25,
        30,
        40,
        50
      ],
      "sectionId" : "network",
      "sectionTitle" : "Network",
      "step" : 1,
      "title" : "Forward error correction",
      "type" : "integer",
      "valueLabels" : {
        "5" : "5%",
        "10" : "10%",
        "15" : "15%",
        "20" : "20%",
        "25" : "25%",
        "30" : "30%",
        "40" : "40%",
        "50" : "50%"
      }
    },
    {
      "applyClass" : "next-session",
      "availability" : "host-capability",
      "editor" : "prep-command-list",
      "key" : "commands.prep",
      "order" : 30,
      "sectionId" : "commands",
      "sectionTitle" : "Commands",
      "title" : "Preparation commands",
      "type" : "command-list",
      "values" : [
        "user",
        "administrator"
      ]
    },
    {
      "applyClass" : "next-session",
      "availability" : "host-capability",
      "editor" : "prep-command-list",
      "key" : "commands.state",
      "order" : 40,
      "sectionId" : "commands",
      "sectionTitle" : "Commands",
      "title" : "State commands",
      "type" : "command-list",
      "values" : [
        "user",
        "administrator"
      ]
    },
    {
      "applyClass" : "next-session",
      "availability" : "host-capability",
      "editor" : "server-command-list",
      "key" : "commands.server",
      "order" : 50,
      "sectionId" : "commands",
      "sectionTitle" : "Commands",
      "title" : "Server commands",
      "type" : "command-list",
      "values" : [
        "user",
        "administrator"
      ]
    }
  ],
  "forbiddenRemoteKeys" : [
    "applicationsFilePath",
    "accessToken",
    "certificatePath",
    "controlLocation",
    "credentialsFilePath",
    "logFilePath",
    "ownerPassword",
    "deviceEnrollmentEnabled",
    "privateKeyPath",
    "refreshToken",
    "remoteSettingsAllowed",
    "stateFilePath",
    "systemAuthenticationEnabled"
  ],
  "networkTransport" : {
    "authentication" : "lumen-device-bearer-v1",
    "contentType" : "application/json",
    "maximumRequestBytes" : 32768,
    "routes" : {
      "events" : {
        "method" : "GET",
        "path" : "/api/v1/settings/events",
        "resumeQuery" : "afterRevision"
      },
      "patch" : {
        "method" : "PATCH",
        "path" : "/api/v1/settings"
      },
      "snapshot" : {
        "method" : "GET",
        "path" : "/api/v1/settings"
      }
    },
    "scheme" : "https"
  },
  "platformCapabilities" : {
    "macos" : {
      "commandPrivileges" : [
        "user"
      ]
    },
    "windows" : {
      "commandPrivileges" : [
        "user",
        "administrator"
      ]
    }
  },
  "protocol" : "lumen-settings",
  "requestId" : {
    "encoding" : "non-whitespace-ascii",
    "maximumLength" : 128,
    "minimumLength" : 1
  },
  "requires" : [
    "none",
    "next-session",
    "worker-restart"
  ],
  "retention" : {
    "events" : 128,
    "idempotencyRecords" : 256
  },
  "schemaVersion" : 1
}
```

## Session lifecycle

### Codec bootstrap sequence

1. `host-codec-configuration`
2. `client-codec-configuration-ack`
3. `host-video-bootstrap`
4. `client-hardware-decode`
5. `client-video-bootstrap-result-decoded`
6. `host-video-delta-admission`

### Generation, stop, reconfiguration, and fallback

- Initial generation: <code>1</code>.
- Stop handshake: <code>StopSession</code> must complete with <code>SessionStopped</code> for the matching session epoch.
- Display reconfiguration: <code>DisplayReconfigurationRequest</code> produces <code>DisplayReconfigurationResult</code> under a strictly increasing revision.
- `legacyProtocol`: <code>false</code>.
- `silentFormatDowngrade`: <code>false</code>.
- An implementation must fail closed; it must not infer or introduce a fallback outside this authority.

### Complete lifecycle authority

```json
{
  "codecBootstrapSequence" : [
    "host-codec-configuration",
    "client-codec-configuration-ack",
    "host-video-bootstrap",
    "client-hardware-decode",
    "client-video-bootstrap-result-decoded",
    "host-video-delta-admission"
  ],
  "displayReconfiguration" : {
    "request" : "DisplayReconfigurationRequest",
    "response" : "DisplayReconfigurationResult",
    "resultCodes" : [
      "applied",
      "rejected",
      "superseded"
    ],
    "strictlyIncreasingRevision" : true
  },
  "fallback" : {
    "legacyProtocol" : false,
    "silentFormatDowngrade" : false
  },
  "generation" : {
    "configurationChangeCreatesGeneration" : true,
    "explicitRepairCreatesGeneration" : true,
    "initial" : 1,
    "periodicKeyframeRetainsGeneration" : true,
    "staleRepairRequest" : "ignore"
  },
  "mediaParkResume" : {
    "capabilityBit" : 32,
    "idempotentCurrentTarget" : true,
    "request" : "MediaParkRequest",
    "response" : "MediaParkResult",
    "resumeRequiresFreshBootstrap" : true,
    "staleResult" : "superseded",
    "states" : [
      "active",
      "parking",
      "parked",
      "resuming"
    ],
    "stopFromParked" : "SessionStopped",
    "strictlyIncreasingRevision" : true
  },
  "sessionStop" : {
    "matchingSessionEpochRequired" : true,
    "request" : "StopSession",
    "response" : "SessionStopped",
    "responseRequiredBeforeClientCompletion" : true
  }
}
```

## Contract limitations

- The authentication route identifier `tokenExchange` and operation identifier `exchangeRefreshToken` are different declarations. This reference does not infer a mapping between them.
- `verifyAccessToken` has no declared HTTP route.
- Conditional and protected routes do not declare request or response schemas.
- Authentication operation shapes do not declare required fields, nullability, or HTTP status codes.
- Settings envelopes list member names but do not declare complete types, nesting, or HTTP status codes.
- Raw media payload detail and timing or retry semantics remain in `lumen-streaming-protocol.md` and `lumen-settings-protocol.md` where the structured contract is not authoritative.
- Implementations must not infer route mappings, field semantics, downgrade behavior, or fallback protocols that are absent from the contract.

## Implementation checklist

- Negotiate QUIC v1 with TLS 1.3 and ALPN `lumen-stream/4` only.
- Generate protobuf bindings from `lumen-streaming-v4.proto`; preserve field tags, enum numbers, reservations, oneofs, and presence.
- Enforce fixed stream roles, message limits, DATAGRAM layouts, FEC bounds, capability masks, and validation failures exactly.
- Implement authentication routes and operation shapes as separate declared authorities; do not guess missing mappings or HTTP behavior.
- Apply settings revisions, idempotency, availability, apply classes, command bounds, and forbidden keys before mutating host state.
- Admit video deltas only after the codec configuration and decoded bootstrap sequence completes.
- Complete `StopSession` only after the matching `SessionStopped` response.
- Reject legacy protocols and silent format downgrade; fail closed when required authority is unavailable.
- Run `lumen-contract-tool check` and the handwritten protocol gates before publishing an implementation.
