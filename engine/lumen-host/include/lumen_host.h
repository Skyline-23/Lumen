#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum LumenHostPlatformVideoCodec {
  LumenHostPlatformVideoCodecH264 = 0,
  LumenHostPlatformVideoCodecHEVC = 1,
  LumenHostPlatformVideoCodecAV1 = 2,
} LumenHostPlatformVideoCodec;

typedef enum LumenHostPlatformVideoProfile {
  LumenHostPlatformVideoProfileH264Main = 0,
  LumenHostPlatformVideoProfileH264High = 1,
  LumenHostPlatformVideoProfileH264High444Predictive = 2,
  LumenHostPlatformVideoProfileHEVCMain = 3,
  LumenHostPlatformVideoProfileHEVCMain10 = 4,
  LumenHostPlatformVideoProfileHEVCMain444 = 5,
  LumenHostPlatformVideoProfileHEVCMain44410 = 6,
  LumenHostPlatformVideoProfileAV1Main = 7,
} LumenHostPlatformVideoProfile;

typedef enum LumenHostPlatformChromaSubsampling {
  LumenHostPlatformChromaSubsamplingYUV420 = 0,
  LumenHostPlatformChromaSubsamplingYUV444 = 1,
} LumenHostPlatformChromaSubsampling;

typedef enum LumenHostPlatformDynamicRange {
  LumenHostPlatformDynamicRangeSDR = 0,
  LumenHostPlatformDynamicRangeHDR10 = 1,
} LumenHostPlatformDynamicRange;

typedef enum LumenHostPlatformColorRange {
  LumenHostPlatformColorRangeLimited = 0,
  LumenHostPlatformColorRangeFull = 1,
} LumenHostPlatformColorRange;

typedef struct LumenHostPlatformSessionPlan {
  uint32_t width;
  uint32_t height;
  uint32_t frames_per_second;
  uint32_t bitrate_kbps;
  LumenHostPlatformVideoCodec video_codec;
  LumenHostPlatformVideoProfile video_profile;
  LumenHostPlatformChromaSubsampling chroma_subsampling;
  uint8_t bit_depth;
  LumenHostPlatformDynamicRange dynamic_range;
  LumenHostPlatformColorRange color_range;
  uint8_t audio_channels;
  bool enhanced_audio_quality;
  bool play_audio_on_host;
  bool virtual_display;
  uint32_t encoder_csc_mode;
  bool sink_hidpi;
  bool sink_scale_explicit;
  bool sink_mode_is_logical;
  int32_t sink_scale_percent;
  int32_t sink_gamut;
  int32_t sink_transfer;
  float sink_current_edr_headroom;
  float sink_potential_edr_headroom;
  int32_t sink_current_peak_luminance_nits;
  int32_t sink_potential_peak_luminance_nits;
  bool sink_supports_frame_gated_hdr;
  bool sink_supports_hdr_tile_overlay;
  bool sink_supports_per_frame_hdr_metadata;
  uint32_t negotiated_dynamic_range_transport;
} LumenHostPlatformSessionPlan;

typedef struct LumenHostPlatformEncodedVideoFrame {
  size_t payload_size;
  uint32_t presentation_time_90khz;
  bool key_frame;
} LumenHostPlatformEncodedVideoFrame;

typedef struct LumenHostPlatformEncodedAudioPacket {
  size_t payload_size;
  uint32_t presentation_time_48khz;
  uint32_t duration_frames;
} LumenHostPlatformEncodedAudioPacket;

typedef enum LumenHostPlatformControlEventKind {
  LumenHostPlatformControlEventKindRequestIdrFrame = 0,
  LumenHostPlatformControlEventKindInvalidateReferenceFrames = 1,
  LumenHostPlatformControlEventKindResetInput = 2,
  LumenHostPlatformControlEventKindResumeVideoEncodingAfterCodecAck = 3,
} LumenHostPlatformControlEventKind;

typedef struct LumenHostPlatformControlEvent {
  LumenHostPlatformControlEventKind kind;
  uint32_t control_connect_data;
  int64_t first_frame;
  int64_t last_frame;
} LumenHostPlatformControlEvent;

typedef enum LumenHostPlatformRuntimeEventDisposition {
  LumenHostPlatformRuntimeEventDispositionRaised = 0,
  LumenHostPlatformRuntimeEventDispositionCleared = 1,
} LumenHostPlatformRuntimeEventDisposition;

typedef enum LumenHostPlatformRuntimeEventSeverity {
  LumenHostPlatformRuntimeEventSeverityWarning = 0,
  LumenHostPlatformRuntimeEventSeverityError = 1,
} LumenHostPlatformRuntimeEventSeverity;

typedef enum LumenHostPlatformRuntimeEventCode {
  LumenHostPlatformRuntimeEventCodeUpnpGatewayDiscovery = 0,
  LumenHostPlatformRuntimeEventCodeUpnpLocalAddressDiscovery = 1,
  LumenHostPlatformRuntimeEventCodeUpnpPortMapping = 2,
  LumenHostPlatformRuntimeEventCodeUpnpIpv6Pinhole = 3,
  LumenHostPlatformRuntimeEventCodeUpnpPortRemoval = 4,
  LumenHostPlatformRuntimeEventCodeNativeSessionTransport = 5,
  LumenHostPlatformRuntimeEventCodeNativeSessionPlatform = 6,
  LumenHostPlatformRuntimeEventCodeNativeVideoCapturePoll = 7,
  LumenHostPlatformRuntimeEventCodeNativeAudioCapturePoll = 8,
  LumenHostPlatformRuntimeEventCodeNativeVideoPacketizer = 9,
  LumenHostPlatformRuntimeEventCodeNativeAudioPacketizer = 10,
  LumenHostPlatformRuntimeEventCodeNativeVideoUdpSend = 11,
  LumenHostPlatformRuntimeEventCodeNativeAudioUdpSend = 12,
  LumenHostPlatformRuntimeEventCodePhysicalDisplayIsolation = 13,
  LumenHostPlatformRuntimeEventCodeNativeInputMotion = 14,
} LumenHostPlatformRuntimeEventCode;

typedef struct LumenHostPlatformRuntimeEvent {
  LumenHostPlatformRuntimeEventDisposition disposition;
  LumenHostPlatformRuntimeEventSeverity severity;
  LumenHostPlatformRuntimeEventCode code;
  const char *message;
} LumenHostPlatformRuntimeEvent;

typedef enum LumenHostPlatformControlFeedbackKind {
  LumenHostPlatformControlFeedbackKindRumble = 0,
  LumenHostPlatformControlFeedbackKindRumbleTriggers = 1,
  LumenHostPlatformControlFeedbackKindMotionEvent = 2,
  LumenHostPlatformControlFeedbackKindRgbLed = 3,
  LumenHostPlatformControlFeedbackKindAdaptiveTriggers = 4,
} LumenHostPlatformControlFeedbackKind;

typedef struct LumenHostPlatformControlFeedback {
  LumenHostPlatformControlFeedbackKind kind;
  uint32_t control_connect_data;
  uint16_t controller_id;
  uint16_t value_a;
  uint16_t value_b;
  uint16_t report_rate;
  uint8_t motion_type;
  uint8_t red;
  uint8_t green;
  uint8_t blue;
  uint8_t event_flags;
  uint8_t type_left;
  uint8_t type_right;
  uint8_t left[10];
  uint8_t right[10];
} LumenHostPlatformControlFeedback;

typedef enum LumenHostPlatformPollStatus {
  LumenHostPlatformPollStatusError = -1,
  LumenHostPlatformPollStatusEmpty = 0,
  LumenHostPlatformPollStatusReady = 1,
  LumenHostPlatformPollStatusBufferTooSmall = 2,
} LumenHostPlatformPollStatus;

typedef enum LumenHostCommandKind {
  LumenHostCommandKindShutdown = 0,
  LumenHostCommandKindForceStopStream = 1,
  LumenHostCommandKindReloadApplications = 2,
  LumenHostCommandKindRestart = 3,
} LumenHostCommandKind;

typedef enum LumenHostCommandSendStatus {
  LumenHostCommandSendStatusOk = 0,
  LumenHostCommandSendStatusInvalidCommand = 1,
  LumenHostCommandSendStatusUnavailable = 2,
  LumenHostCommandSendStatusPanic = 3,
} LumenHostCommandSendStatus;

// Poll callbacks do not transfer allocation ownership. On BufferTooSmall they
// must report the required payload_size without consuming the pending item;
// Lumen retries once with a bounded Rust-owned buffer. Ready consumes exactly
// one complete decoder-ready Annex-B frame or Opus packet.

typedef enum LumenHostPlatformStartSessionStatus {
  LumenHostPlatformStartSessionStatusReady = 0,
  LumenHostPlatformStartSessionStatusInvalidConfiguration = -1,
  LumenHostPlatformStartSessionStatusDisplayCreationFailed = -2,
  LumenHostPlatformStartSessionStatusAudioEncoderFailed = -3,
  LumenHostPlatformStartSessionStatusVideoCaptureFailed = -4,
  LumenHostPlatformStartSessionStatusAudioCaptureFailed = -5,
} LumenHostPlatformStartSessionStatus;

typedef int32_t (*LumenHostPlatformStartSessionCallback)(
  void *context,
  const LumenHostPlatformSessionPlan *plan
);
typedef int32_t (*LumenHostPlatformStopSessionCallback)(void *context);
typedef int32_t (*LumenHostPlatformPollEncodedVideoCallback)(
  void *context,
  uint8_t *destination,
  size_t destination_capacity,
  LumenHostPlatformEncodedVideoFrame *frame
);
typedef int32_t (*LumenHostPlatformPollEncodedAudioCallback)(
  void *context,
  uint8_t *destination,
  size_t destination_capacity,
  LumenHostPlatformEncodedAudioPacket *packet
);
typedef int32_t (*LumenHostPlatformHandleControlEventCallback)(
  void *context,
  const LumenHostPlatformControlEvent *event
);
typedef int32_t (*LumenHostPlatformPollControlFeedbackCallback)(
  void *context,
  LumenHostPlatformControlFeedback *feedback
);
typedef int32_t (*LumenHostPlatformPublishRuntimeEventCallback)(
  void *context,
  const LumenHostPlatformRuntimeEvent *event
);

typedef struct LumenHostPlatformCallbacks {
  void *context;
  LumenHostPlatformStartSessionCallback start_session;
  LumenHostPlatformStopSessionCallback stop_session;
  LumenHostPlatformPollEncodedVideoCallback poll_encoded_video;
  LumenHostPlatformPollEncodedAudioCallback poll_encoded_audio;
  LumenHostPlatformHandleControlEventCallback handle_control_event;
  LumenHostPlatformPollControlFeedbackCallback poll_control_feedback;
  LumenHostPlatformPublishRuntimeEventCallback publish_runtime_event;
} LumenHostPlatformCallbacks;

int32_t lumen_host_run(int argc, const char *const *argv);
int32_t lumen_windows_service_run(int argc, const char *const *argv);
int32_t lumen_host_run_with_platform(
  int argc,
  const char *const *argv,
  const LumenHostPlatformCallbacks *callbacks
);
LumenHostCommandSendStatus lumen_host_send_command(uint32_t command);

void lumen_host_show_windows_shell(void);
bool lumen_host_take_restart_request(void);

#ifdef __cplusplus
}
#endif
