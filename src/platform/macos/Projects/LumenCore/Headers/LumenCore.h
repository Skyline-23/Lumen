#ifndef LUMEN_CORE_H
#define LUMEN_CORE_H

#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum LumenCoreCaptureCodec {
  LumenCoreCaptureCodecUnknown = -1,
  LumenCoreCaptureCodecH264 = 0,
  LumenCoreCaptureCodecHEVC = 1,
  LumenCoreCaptureCodecProResProxy = 2
} LumenCoreCaptureCodec;

typedef enum LumenCoreCapturePreprocessStrategy {
  LumenCoreCapturePreprocessStrategyNone = 0,
  LumenCoreCapturePreprocessStrategyDownscale2x = 1
} LumenCoreCapturePreprocessStrategy;

typedef enum LumenCoreCaptureQueueProfile {
  LumenCoreCaptureQueueProfileQ1 = 0,
  LumenCoreCaptureQueueProfileQ2 = 1,
  LumenCoreCaptureQueueProfileQ3 = 2,
  LumenCoreCaptureQueueProfileQ4 = 3,
  LumenCoreCaptureQueueProfileAuto = 4
} LumenCoreCaptureQueueProfile;

typedef enum LumenCoreDynamicRangeTransport {
  LumenCoreDynamicRangeTransportUnknown = 0,
  LumenCoreDynamicRangeTransportSDR = 1,
  LumenCoreDynamicRangeTransportFullFrameHDR = 2,
  LumenCoreDynamicRangeTransportFrameGatedHDR = 3,
  LumenCoreDynamicRangeTransportSDRBaseHDROverlay = 4
} LumenCoreDynamicRangeTransport;

typedef struct LumenCoreSinkMode {
  bool hidpi;
  bool scale_explicit;
  bool mode_is_logical;
  int32_t scale_percent;
} LumenCoreSinkMode;

typedef struct LumenCoreSinkCapability {
  int32_t gamut;
  int32_t transfer;
  float current_edr_headroom;
  float potential_edr_headroom;
  int32_t current_peak_luminance_nits;
  int32_t potential_peak_luminance_nits;
  bool supports_frame_gated_hdr;
  bool supports_hdr_tile_overlay;
  bool supports_per_frame_hdr_metadata;
} LumenCoreSinkCapability;

typedef struct LumenCoreSinkRequest {
  LumenCoreSinkMode mode;
  LumenCoreSinkCapability capability;
  LumenCoreDynamicRangeTransport dynamic_range_transport;
} LumenCoreSinkRequest;

typedef enum LumenCoreAudioCaptureSourceKind {
  LumenCoreAudioCaptureSourceKindUnknown = -1,
  LumenCoreAudioCaptureSourceKindMicrophone = 0,
  LumenCoreAudioCaptureSourceKindSystemOutput = 1
} LumenCoreAudioCaptureSourceKind;

typedef enum LumenCoreCaptureEventKind {
  LumenCoreCaptureEventKindUnknown = -1,
  LumenCoreCaptureEventKindStarted = 0,
  LumenCoreCaptureEventKindStopped = 1,
  LumenCoreCaptureEventKindRestarted = 2,
  LumenCoreCaptureEventKindFailed = 3,
  LumenCoreCaptureEventKindDroppedFrame = 4
} LumenCoreCaptureEventKind;

typedef struct LumenCoreHDRStaticMetadata {
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
} LumenCoreHDRStaticMetadata;

typedef struct LumenCoreEffectiveDisplayState {
  int32_t gamut;
  int32_t transfer;
  bool has_hdr_static_metadata;
  LumenCoreHDRStaticMetadata hdr_static_metadata;
} LumenCoreEffectiveDisplayState;

typedef struct LumenCoreEncodedCaptureIngress LumenCoreEncodedCaptureIngress;
typedef struct LumenCoreAudioCaptureIngress LumenCoreAudioCaptureIngress;

typedef struct LumenCoreEncodedCaptureIngressSnapshot {
  uint64_t frame_count;
  uint64_t event_count;
  uint64_t queued_frame_count;
  uint64_t queued_event_count;
  uint64_t dropped_frame_count;
  uint64_t dropped_event_count;
  bool has_last_frame;
  bool has_last_sample_buffer;
  LumenCoreCaptureCodec last_frame_codec;
  size_t last_frame_payload_size;
  uint64_t last_frame_source_sequence_number;
  uint64_t last_frame_source_display_time;
  bool last_frame_is_key_frame;
  bool last_frame_is_hdr_signaled;
  bool has_last_event;
  LumenCoreCaptureEventKind last_event_kind;
  bool last_event_has_stop_status;
  int32_t last_event_stop_status;
  bool last_event_has_automatic_restart_count;
  uint64_t last_event_automatic_restart_count;
  bool last_event_has_source_display_time;
  uint64_t last_event_source_display_time;
} LumenCoreEncodedCaptureIngressSnapshot;

typedef struct LumenCoreEncodedCaptureFrameRecord {
  bool has_value;
  LumenCoreCaptureCodec codec;
  size_t payload_size;
  uint64_t source_sequence_number;
  uint64_t source_display_time;
  bool has_output_callback_latency_milliseconds;
  double output_callback_latency_milliseconds;
  bool is_key_frame;
  bool is_hdr_signaled;
  bool is_replay;
  bool has_source_dirty_rect;
  int32_t source_dirty_rect_x;
  int32_t source_dirty_rect_y;
  int32_t source_dirty_rect_width;
  int32_t source_dirty_rect_height;
} LumenCoreEncodedCaptureFrameRecord;

typedef struct LumenCoreEncodedCaptureEventRecord {
  bool has_value;
  LumenCoreCaptureEventKind kind;
  bool has_stop_status;
  int32_t stop_status;
  bool has_automatic_restart_count;
  uint64_t automatic_restart_count;
  bool has_source_display_time;
  uint64_t source_display_time;
} LumenCoreEncodedCaptureEventRecord;

const char *LumenCoreBootstrapVersionString(void);
const char *LumenCoreBootstrapRuntimeDescription(void);

LumenCoreEncodedCaptureIngress *LumenCoreEncodedCaptureIngressCreate(void);
void LumenCoreEncodedCaptureIngressDestroy(LumenCoreEncodedCaptureIngress *ingress);
void LumenCoreEncodedCaptureIngressReset(LumenCoreEncodedCaptureIngress *ingress);
void LumenCoreEncodedCaptureIngressSetFrameCapacity(
  LumenCoreEncodedCaptureIngress *ingress,
  size_t capacity
);
void LumenCoreEncodedCaptureIngressSetEventCapacity(
  LumenCoreEncodedCaptureIngress *ingress,
  size_t capacity
);
void LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
  LumenCoreEncodedCaptureIngress *ingress,
  LumenCoreCaptureCodec codec,
  uint64_t source_sequence_number,
  uint64_t source_display_time,
  bool has_output_callback_latency_milliseconds,
  double output_callback_latency_milliseconds,
  bool is_key_frame,
  bool is_hdr_signaled,
  bool is_replay,
  bool has_source_dirty_rect,
  int32_t source_dirty_rect_x,
  int32_t source_dirty_rect_y,
  int32_t source_dirty_rect_width,
  int32_t source_dirty_rect_height,
  CMSampleBufferRef sample_buffer
);
void LumenCoreEncodedCaptureIngressConsumeEvent(
  LumenCoreEncodedCaptureIngress *ingress,
  LumenCoreCaptureEventKind kind,
  const char *message,
  bool has_stop_status,
  int32_t stop_status,
  bool has_automatic_restart_count,
  uint64_t automatic_restart_count,
  bool has_source_display_time,
  uint64_t source_display_time
);
LumenCoreEncodedCaptureIngressSnapshot LumenCoreEncodedCaptureIngressCopySnapshot(
  const LumenCoreEncodedCaptureIngress *ingress
);
CMSampleBufferRef LumenCoreEncodedCaptureIngressCreateRetainedLastSampleBuffer(
  const LumenCoreEncodedCaptureIngress *ingress
);
LumenCoreEncodedCaptureFrameRecord LumenCoreEncodedCaptureIngressPopNextFrame(
  LumenCoreEncodedCaptureIngress *ingress,
  CMSampleBufferRef *retained_sample_buffer_out
);
LumenCoreEncodedCaptureEventRecord LumenCoreEncodedCaptureIngressPopNextEvent(
  LumenCoreEncodedCaptureIngress *ingress,
  char *message_destination,
  size_t message_capacity
);
size_t LumenCoreEncodedCaptureIngressCopyLastEventMessage(
  const LumenCoreEncodedCaptureIngress *ingress,
  char *destination,
  size_t capacity
);
LumenCoreEncodedCaptureIngress *LumenCoreSharedEncodedCaptureIngress(void);
void LumenCoreEncodedCaptureIngressSetProducerActive(
  LumenCoreEncodedCaptureIngress *ingress,
  bool active
);
bool LumenCoreEncodedCaptureIngressIsProducerActive(
  const LumenCoreEncodedCaptureIngress *ingress
);
bool LumenCoreEncodedCaptureIngressWaitForData(
  LumenCoreEncodedCaptureIngress *ingress,
  uint32_t timeout_milliseconds
);
bool LumenCoreEncodedCaptureIngressWaitForProducerActive(
  LumenCoreEncodedCaptureIngress *ingress,
  uint32_t timeout_milliseconds
);

typedef struct LumenCoreAudioCaptureIngressSnapshot {
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
  LumenCoreCaptureEventKind last_event_kind;
  bool last_event_has_stop_status;
  int32_t last_event_stop_status;
  bool last_event_has_automatic_restart_count;
  uint64_t last_event_automatic_restart_count;
  bool last_event_has_source_sequence_number;
  uint64_t last_event_source_sequence_number;
} LumenCoreAudioCaptureIngressSnapshot;

typedef struct LumenCoreAudioCaptureFrameRecord {
  bool has_value;
  uint64_t sequence_number;
  uint64_t host_time_nanoseconds;
  int32_t sample_rate;
  int32_t channel_count;
  int32_t frame_count;
  size_t pcm_byte_count;
} LumenCoreAudioCaptureFrameRecord;

typedef struct LumenCoreAudioCaptureEventRecord {
  bool has_value;
  LumenCoreCaptureEventKind kind;
  bool has_stop_status;
  int32_t stop_status;
  bool has_automatic_restart_count;
  uint64_t automatic_restart_count;
  bool has_source_sequence_number;
  uint64_t source_sequence_number;
} LumenCoreAudioCaptureEventRecord;

typedef struct LumenCoreCaptureRequestSnapshot {
  uint64_t generation;
  uint64_t video_generation;
  uint64_t audio_generation;
  bool video_requested;
  bool audio_requested;
  uint32_t display_id;
  LumenCoreCaptureCodec codec;
  LumenCoreCapturePreprocessStrategy preprocess_strategy;
  LumenCoreCaptureQueueProfile queue_profile;
  bool show_cursor;
  int32_t target_frame_rate;
  int32_t target_video_bitrate_kbps;
  int32_t requested_width;
  int32_t requested_height;
  LumenCoreSinkRequest sink_request;
  LumenCoreEffectiveDisplayState effective_display_state;
  LumenCoreAudioCaptureSourceKind audio_source_kind;
  bool audio_excludes_current_process;
  int32_t audio_sample_rate;
  int32_t audio_channel_count;
  int32_t audio_frame_size;
} LumenCoreCaptureRequestSnapshot;

LumenCoreAudioCaptureIngress *LumenCoreAudioCaptureIngressCreate(void);
void LumenCoreAudioCaptureIngressDestroy(LumenCoreAudioCaptureIngress *ingress);
void LumenCoreAudioCaptureIngressReset(LumenCoreAudioCaptureIngress *ingress);
void LumenCoreAudioCaptureIngressSetFrameCapacity(
  LumenCoreAudioCaptureIngress *ingress,
  size_t capacity
);
void LumenCoreAudioCaptureIngressSetEventCapacity(
  LumenCoreAudioCaptureIngress *ingress,
  size_t capacity
);
void LumenCoreAudioCaptureIngressConsumePCMFloat32(
  LumenCoreAudioCaptureIngress *ingress,
  uint64_t sequence_number,
  uint64_t host_time_nanoseconds,
  int32_t sample_rate,
  int32_t channel_count,
  int32_t frame_count,
  const void *pcm_float32le,
  size_t pcm_byte_count
);
void LumenCoreAudioCaptureIngressConsumeEvent(
  LumenCoreAudioCaptureIngress *ingress,
  LumenCoreCaptureEventKind kind,
  const char *message,
  bool has_stop_status,
  int32_t stop_status,
  bool has_automatic_restart_count,
  uint64_t automatic_restart_count,
  bool has_source_sequence_number,
  uint64_t source_sequence_number
);
LumenCoreAudioCaptureIngressSnapshot LumenCoreAudioCaptureIngressCopySnapshot(
  const LumenCoreAudioCaptureIngress *ingress
);
LumenCoreAudioCaptureFrameRecord LumenCoreAudioCaptureIngressPopNextFrame(
  LumenCoreAudioCaptureIngress *ingress,
  void *pcm_destination,
  size_t pcm_capacity,
  size_t *copied_size_out
);
LumenCoreAudioCaptureEventRecord LumenCoreAudioCaptureIngressPopNextEvent(
  LumenCoreAudioCaptureIngress *ingress,
  char *message_destination,
  size_t message_capacity
);
size_t LumenCoreAudioCaptureIngressCopyLastEventMessage(
  const LumenCoreAudioCaptureIngress *ingress,
  char *destination,
  size_t capacity
);
LumenCoreAudioCaptureIngress *LumenCoreSharedAudioCaptureIngress(void);
void LumenCoreAudioCaptureIngressSetProducerActive(
  LumenCoreAudioCaptureIngress *ingress,
  bool active
);
bool LumenCoreAudioCaptureIngressIsProducerActive(
  const LumenCoreAudioCaptureIngress *ingress
);
bool LumenCoreAudioCaptureIngressWaitForData(
  LumenCoreAudioCaptureIngress *ingress,
  uint32_t timeout_milliseconds
);
bool LumenCoreAudioCaptureIngressWaitForProducerActive(
  LumenCoreAudioCaptureIngress *ingress,
  uint32_t timeout_milliseconds
);

LumenCoreCaptureRequestSnapshot LumenCoreCaptureRequestCopySnapshot(void);
bool LumenCoreCaptureRequestWaitForGenerationChange(
  uint64_t observed_generation,
  uint32_t timeout_milliseconds
);
void LumenCoreCaptureRequestPublishVideo(
  uint32_t display_id,
  LumenCoreCaptureCodec codec,
  LumenCoreCapturePreprocessStrategy preprocess_strategy,
  LumenCoreCaptureQueueProfile queue_profile,
  bool show_cursor,
  int32_t target_frame_rate,
  int32_t target_video_bitrate_kbps,
  int32_t requested_width,
  int32_t requested_height,
  LumenCoreSinkRequest sink_request,
  LumenCoreEffectiveDisplayState effective_display_state
);
void LumenCoreCaptureRequestPublishAudio(
  LumenCoreAudioCaptureSourceKind source_kind,
  uint32_t display_id,
  bool excludes_current_process_audio,
  int32_t sample_rate,
  int32_t channel_count,
  int32_t frame_size
);
void LumenCoreCaptureRequestClear(void);

#ifdef __cplusplus
}
#endif

#endif
