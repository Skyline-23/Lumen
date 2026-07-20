#ifndef LUMEN_MAC_BRIDGE_H
#define LUMEN_MAC_BRIDGE_H

#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, LumenMacVirtualDisplayGamut) {
  LumenMacVirtualDisplayGamutSRGB = 0,
  LumenMacVirtualDisplayGamutDisplayP3 = 1,
  LumenMacVirtualDisplayGamutRec2020 = 2
};

typedef NS_ENUM(NSInteger, LumenMacVirtualDisplayTransfer) {
  LumenMacVirtualDisplayTransferSDR = 0,
  LumenMacVirtualDisplayTransferPQ = 1,
  LumenMacVirtualDisplayTransferHLG = 2
};

NS_SWIFT_NAME(LumenMacVirtualDisplayConfiguration)
@interface LumenMacVirtualDisplayConfiguration : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t serialNumber;
@property(nonatomic) uint32_t backingWidth;
@property(nonatomic) uint32_t backingHeight;
@property(nonatomic) uint32_t logicalWidth;
@property(nonatomic) uint32_t logicalHeight;
@property(nonatomic) double refreshRate;
@property(nonatomic) BOOL highDensity;
@property(nonatomic) BOOL hdrEnabled;
@property(nonatomic) LumenMacVirtualDisplayGamut gamut;
@property(nonatomic) LumenMacVirtualDisplayTransfer transfer;
@property(nonatomic) double currentEDRHeadroom;
@property(nonatomic) double potentialEDRHeadroom;
@property(nonatomic) double currentPeakLuminanceNits;
@property(nonatomic) double potentialPeakLuminanceNits;
@end

NS_SWIFT_NAME(LumenMacVirtualDisplay)
@interface LumenMacVirtualDisplay : NSObject
@property(nonatomic, readonly) uint32_t displayID;
@property(nonatomic, readonly) uint32_t backingWidth;
@property(nonatomic, readonly) uint32_t backingHeight;
@property(nonatomic, readonly) uint32_t logicalWidth;
@property(nonatomic, readonly) uint32_t logicalHeight;

+ (BOOL)isSupported;
+ (instancetype)createRegisteredDisplayForKey:(NSString *)key
                                 configuration:(LumenMacVirtualDisplayConfiguration *)configuration
                                         error:(NSError **)error;
+ (instancetype)registeredDisplayForKey:(NSString *)key;
+ (instancetype)registeredDisplayForDisplayID:(uint32_t)displayID;
+ (BOOL)removeRegisteredDisplayForKey:(NSString *)key;
+ (void)destroyAllRegisteredDisplays;
- (instancetype)initWithConfiguration:(LumenMacVirtualDisplayConfiguration *)configuration
                                 error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (BOOL)updateLogicalWidth:(uint32_t)logicalWidth
             logicalHeight:(uint32_t)logicalHeight
               refreshRate:(double)refreshRate
                      error:(NSError **)error;
- (void)destroy;

- (instancetype)init NS_UNAVAILABLE;
@end
#endif

#ifdef __cplusplus
extern "C" {
#endif

int32_t LumenMacDirectCGSConfigureDisplayEnabled(
  CGDisplayConfigRef configuration,
  CGDirectDisplayID display_id,
  bool enabled
);

// Stable C shapes used only at the Swift/Objective-C platform boundary. Shared
// policy and the packaged host runtime are Rust-owned; these records carry
// native media metadata without restoring a C++ authority.
typedef enum LumenMacCaptureCodec {
  LumenMacCaptureCodecUnknown = -1,
  LumenMacCaptureCodecH264 = 0,
  LumenMacCaptureCodecHEVC = 1
} LumenMacCaptureCodec;

typedef enum LumenMacCaptureVideoProfile {
  LumenMacCaptureVideoProfileH264Main = 0,
  LumenMacCaptureVideoProfileH264High = 1,
  LumenMacCaptureVideoProfileH264High444Predictive = 2,
  LumenMacCaptureVideoProfileHEVCMain = 3,
  LumenMacCaptureVideoProfileHEVCMain10 = 4,
  LumenMacCaptureVideoProfileHEVCMain444 = 5,
  LumenMacCaptureVideoProfileHEVCMain44410 = 6
} LumenMacCaptureVideoProfile;

typedef enum LumenMacCaptureChromaSubsampling {
  LumenMacCaptureChromaSubsamplingYUV420 = 0,
  LumenMacCaptureChromaSubsamplingYUV444 = 1
} LumenMacCaptureChromaSubsampling;

typedef enum LumenMacCaptureDynamicRange {
  LumenMacCaptureDynamicRangeSDR = 0,
  LumenMacCaptureDynamicRangeHDR10 = 1
} LumenMacCaptureDynamicRange;

typedef enum LumenMacCaptureColorRange {
  LumenMacCaptureColorRangeLimited = 0,
  LumenMacCaptureColorRangeFull = 1
} LumenMacCaptureColorRange;

typedef enum LumenMacDynamicRangeTransport {
  LumenMacDynamicRangeTransportUnknown = 0,
  LumenMacDynamicRangeTransportSDR = 1,
  LumenMacDynamicRangeTransportFullFrameHDR = 2,
  LumenMacDynamicRangeTransportFrameGatedHDR = 3,
  LumenMacDynamicRangeTransportSDRBaseHDROverlay = 4
} LumenMacDynamicRangeTransport;

typedef struct LumenMacSinkMode {
  bool hidpi;
  bool scale_explicit;
  bool mode_is_logical;
  int32_t scale_percent;
} LumenMacSinkMode;

typedef struct LumenMacSinkCapability {
  int32_t gamut;
  int32_t transfer;
  float current_edr_headroom;
  float potential_edr_headroom;
  int32_t current_peak_luminance_nits;
  int32_t potential_peak_luminance_nits;
  bool supports_frame_gated_hdr;
  bool supports_hdr_tile_overlay;
  bool supports_per_frame_hdr_metadata;
} LumenMacSinkCapability;

typedef struct LumenMacSinkRequest {
  LumenMacSinkMode mode;
  LumenMacSinkCapability capability;
  LumenMacDynamicRangeTransport dynamic_range_transport;
} LumenMacSinkRequest;

typedef enum LumenMacCaptureEventKind {
  LumenMacCaptureEventKindUnknown = -1,
  LumenMacCaptureEventKindStarted = 0,
  LumenMacCaptureEventKindStopped = 1,
  LumenMacCaptureEventKindRestarted = 2,
  LumenMacCaptureEventKindFailed = 3,
  LumenMacCaptureEventKindDroppedFrame = 4,
  LumenMacCaptureEventKindCoalescedFrame = 5
} LumenMacCaptureEventKind;

typedef struct LumenMacHDRStaticMetadata {
  int32_t red_primary_x;
  int32_t red_primary_y;
  int32_t green_primary_x;
  int32_t green_primary_y;
  int32_t blue_primary_x;
  int32_t blue_primary_y;
  int32_t white_point_x;
  int32_t white_point_y;
  int32_t max_display_luminance;
  int32_t min_display_luminance;
  int32_t max_content_light_level;
  int32_t max_frame_average_light_level;
  int32_t max_full_frame_luminance;
} LumenMacHDRStaticMetadata;

typedef struct LumenMacEffectiveDisplayState {
  int32_t gamut;
  int32_t transfer;
  bool has_hdr_static_metadata;
  LumenMacHDRStaticMetadata hdr_static_metadata;
} LumenMacEffectiveDisplayState;

typedef struct LumenMacEncodedCaptureIngressSnapshot {
  uint64_t frame_count;
  uint64_t event_count;
  uint64_t queued_frame_count;
  uint64_t queued_event_count;
  uint64_t dropped_frame_count;
  uint64_t dropped_event_count;
  bool has_last_frame;
  bool has_last_sample_buffer;
  LumenMacCaptureCodec last_frame_codec;
  size_t last_frame_payload_size;
  uint64_t last_frame_source_sequence_number;
  uint64_t last_frame_source_display_time;
  bool last_frame_is_key_frame;
  bool last_frame_is_hdr_signaled;
  bool has_last_event;
  LumenMacCaptureEventKind last_event_kind;
  bool last_event_has_stop_status;
  int32_t last_event_stop_status;
  bool last_event_has_automatic_restart_count;
  uint64_t last_event_automatic_restart_count;
  bool last_event_has_source_display_time;
  uint64_t last_event_source_display_time;
} LumenMacEncodedCaptureIngressSnapshot;

typedef struct LumenMacEncodedCaptureFrameRecord {
  bool has_value;
  LumenMacCaptureCodec codec;
  size_t payload_size;
  uint64_t source_sequence_number;
  uint64_t source_display_time;
  bool has_output_callback_latency_milliseconds;
  double output_callback_latency_milliseconds;
  bool is_key_frame;
  bool requires_bootstrap_acknowledgement;
  bool repair_key_frame;
  bool is_hdr_signaled;
  bool is_replay;
} LumenMacEncodedCaptureFrameRecord;

typedef struct LumenMacEncodedCaptureEventRecord {
  bool has_value;
  LumenMacCaptureEventKind kind;
  bool has_stop_status;
  int32_t stop_status;
  bool has_automatic_restart_count;
  uint64_t automatic_restart_count;
  bool has_source_display_time;
  uint64_t source_display_time;
} LumenMacEncodedCaptureEventRecord;

typedef enum LumenMacBridgePreprocessStrategy {
  LumenMacBridgePreprocessStrategyNone = 0,
  LumenMacBridgePreprocessStrategyDownscale2x = 1
} LumenMacBridgePreprocessStrategy;

typedef enum LumenMacBridgeQueueProfile {
  LumenMacBridgeQueueProfileQ1 = 0,
  LumenMacBridgeQueueProfileQ2 = 1,
  LumenMacBridgeQueueProfileQ3 = 2,
  LumenMacBridgeQueueProfileQ4 = 3,
  LumenMacBridgeQueueProfileAuto = 4
} LumenMacBridgeQueueProfile;

typedef enum LumenMacBridgeCapturePairStartStatus {
  LumenMacBridgeCapturePairStartStatusReady = 0,
  LumenMacBridgeCapturePairStartStatusVideoFailed = 1,
  LumenMacBridgeCapturePairStartStatusAudioFailed = 2,
  LumenMacBridgeCapturePairStartStatusUnknownFailed = 3
} LumenMacBridgeCapturePairStartStatus;

typedef struct LumenMacBridgeCaptureConfiguration {
  uint32_t display_id;
  LumenMacCaptureCodec codec;
  LumenMacCaptureVideoProfile video_profile;
  LumenMacCaptureChromaSubsampling chroma_subsampling;
  uint8_t bit_depth;
  LumenMacCaptureDynamicRange dynamic_range;
  LumenMacCaptureColorRange color_range;
  LumenMacBridgePreprocessStrategy preprocess_strategy;
  LumenMacBridgeQueueProfile queue_profile;
  int32_t target_frame_rate;
  int32_t target_video_bitrate_kbps;
  int32_t requested_width;
  int32_t requested_height;
  LumenMacSinkRequest sink_request;
  LumenMacEffectiveDisplayState effective_display_state;
} LumenMacBridgeCaptureConfiguration;

typedef enum LumenMacBridgeAudioSourceKind {
  LumenMacBridgeAudioSourceKindMicrophone = 0,
  LumenMacBridgeAudioSourceKindSystemOutput = 1
} LumenMacBridgeAudioSourceKind;

typedef struct LumenMacBridgeAudioCaptureConfiguration {
  LumenMacBridgeAudioSourceKind source_kind;
  uint32_t display_id;
  bool excludes_current_process_audio;
  int32_t sample_rate;
  int32_t channel_count;
  int32_t frame_size;
  char input_id[256];
} LumenMacBridgeAudioCaptureConfiguration;

typedef struct LumenMacWorkspaceSessionRequest {
  const char *display_key;
  const char *display_name;
  uint32_t width;
  uint32_t height;
  uint32_t scale_percent;
  bool dimensions_are_logical;
  double refresh_rate;
  bool hdr_enabled;
  int32_t sink_gamut;
  int32_t sink_transfer;
  float current_edr_headroom;
  float potential_edr_headroom;
  int32_t current_peak_luminance_nits;
  int32_t potential_peak_luminance_nits;
} LumenMacWorkspaceSessionRequest;

typedef struct LumenMacWorkspaceActivationResult {
  bool activated;
  uint32_t isolation_status;
} LumenMacWorkspaceActivationResult;

typedef struct LumenMacBridgeAudioForwardingSnapshot {
  uint64_t frame_count;
  uint64_t event_count;
  uint64_t queued_frame_count;
  uint64_t queued_event_count;
  uint64_t dropped_frame_count;
  uint64_t dropped_event_count;
  bool has_last_frame;
  uint64_t last_frame_sequence_number;
  uint64_t last_frame_host_time_nanoseconds;
  int32_t last_frame_sample_rate;
  int32_t last_frame_channel_count;
  int32_t last_frame_frame_count;
  size_t last_frame_pcm_byte_count;
  bool has_last_event;
  LumenMacCaptureEventKind last_event_kind;
} LumenMacBridgeAudioForwardingSnapshot;

typedef struct LumenMacBridgeAudioCaptureFrameRecord {
  bool has_value;
  uint64_t sequence_number;
  uint64_t host_time_nanoseconds;
  int32_t sample_rate;
  int32_t channel_count;
  int32_t frame_count;
  size_t pcm_byte_count;
} LumenMacBridgeAudioCaptureFrameRecord;

typedef struct LumenMacBridgeAudioCaptureEventRecord {
  bool has_value;
  LumenMacCaptureEventKind kind;
  bool has_stop_status;
  int32_t stop_status;
  bool has_automatic_restart_count;
  uint64_t automatic_restart_count;
  bool has_source_sequence_number;
  uint64_t source_sequence_number;
} LumenMacBridgeAudioCaptureEventRecord;

typedef struct LumenMacBridgeStatusSnapshot {
  char core_version[128];
  char runtime_description[256];
  char integration_status[512];
  bool capture_session_running;
  bool audio_capture_session_running;
  bool automatic_capture_orchestration_running;
} LumenMacBridgeStatusSnapshot;

typedef struct LumenMacBridgeController LumenMacBridgeController;
typedef struct LumenMacOpusEncoder LumenMacOpusEncoder;

LumenMacBridgeController *LumenMacBridgeControllerCreate(void);
void LumenMacBridgeControllerDestroy(LumenMacBridgeController *controller);

LumenMacOpusEncoder *LumenMacOpusEncoderCreate(
  int32_t sample_rate,
  int32_t channel_count,
  int32_t stream_count,
  int32_t coupled_stream_count,
  const uint8_t *mapping,
  int32_t bit_rate,
  bool enhanced_quality,
  char *error_destination,
  size_t error_capacity
);

bool LumenMacOpusEncoderEncodeFloat32(
  LumenMacOpusEncoder *encoder,
  const float *samples,
  int32_t frame_count,
  uint8_t *packet_destination,
  size_t packet_capacity,
  size_t *packet_size_out,
  char *error_destination,
  size_t error_capacity
);

void LumenMacOpusEncoderDestroy(LumenMacOpusEncoder *encoder);

LumenMacBridgeCaptureConfiguration LumenMacBridgeControllerMakePanelNativeConfiguration(
  uint32_t display_id
);

LumenMacBridgeAudioCaptureConfiguration LumenMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration(
  void
);

LumenMacBridgeAudioCaptureConfiguration LumenMacBridgeControllerMakeSystemOutputAudioConfiguration(
  uint32_t display_id
);

bool LumenMacBridgeControllerStartCapture(
  LumenMacBridgeController *controller,
  LumenMacBridgeCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
);

LumenMacBridgeCapturePairStartStatus LumenMacBridgeControllerStartCapturePair(
  LumenMacBridgeController *controller,
  LumenMacBridgeCaptureConfiguration video_configuration,
  LumenMacBridgeAudioCaptureConfiguration audio_configuration,
  char *error_destination,
  size_t error_capacity
);

void LumenMacBridgeControllerStopCapture(
  LumenMacBridgeController *controller
);

void LumenMacBridgeRequestImmediateCaptureKeyFrame(void);
bool LumenMacBridgeResumeVideoEncodingAfterCodecAck(void);
void LumenMacBridgeRestartCapture(const char *reason);

bool LumenMacBridgeControllerStartAudioCapture(
  LumenMacBridgeController *controller,
  LumenMacBridgeAudioCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
);

bool LumenMacBridgeControllerStartAudioCaptureAsynchronously(
  LumenMacBridgeController *controller,
  LumenMacBridgeAudioCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
);

void LumenMacBridgeControllerStopAudioCapture(
  LumenMacBridgeController *controller
);

LumenMacBridgeStatusSnapshot LumenMacBridgeControllerCopyStatusSnapshot(
  LumenMacBridgeController *controller
);

void LumenMacBridgeControllerConfigureVideoForwarding(
  LumenMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
);

LumenMacEncodedCaptureIngressSnapshot LumenMacBridgeControllerCopyVideoForwardingSnapshot(
  LumenMacBridgeController *controller
);

bool LumenMacBridgeControllerCopyCaptureDiagnostics(
  LumenMacBridgeController *controller,
  char *diagnostics_destination,
  size_t diagnostics_capacity
);

void LumenMacBridgeControllerConfigureAudioForwarding(
  LumenMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
);

LumenMacBridgeAudioForwardingSnapshot LumenMacBridgeControllerCopyAudioForwardingSnapshot(
  LumenMacBridgeController *controller
);

LumenMacEncodedCaptureFrameRecord LumenMacBridgeControllerPopNextForwardedFrame(
  LumenMacBridgeController *controller,
  CMSampleBufferRef *retained_sample_buffer_out
);

LumenMacEncodedCaptureEventRecord LumenMacBridgeControllerPopNextForwardedEvent(
  LumenMacBridgeController *controller,
  char *message_destination,
  size_t message_capacity
);

LumenMacBridgeAudioCaptureFrameRecord LumenMacBridgeControllerPopNextForwardedAudioFrame(
  LumenMacBridgeController *controller,
  void *pcm_destination,
  size_t pcm_capacity,
  size_t *copied_size_out
);

LumenMacBridgeAudioCaptureEventRecord LumenMacBridgeControllerPopNextForwardedAudioEvent(
  LumenMacBridgeController *controller,
  char *message_destination,
  size_t message_capacity
);

uint32_t LumenMacWorkspacePrepareSession(
  LumenMacWorkspaceSessionRequest request,
  char *error_destination,
  size_t error_capacity
);

LumenMacWorkspaceActivationResult LumenMacWorkspaceActivateSession(
  const char *display_key,
  char *status_destination,
  size_t status_capacity
);

bool LumenMacWorkspaceStopSession(
  const char *display_key,
  char *error_destination,
  size_t error_capacity
);

void LumenMacBridgePublishRuntimeEvent(
  uint32_t disposition,
  uint32_t severity,
  uint32_t code,
  const char *message
);

#ifdef __cplusplus
}
#endif

#endif
