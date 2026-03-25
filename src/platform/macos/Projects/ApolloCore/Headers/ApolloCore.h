#ifndef APOLLO_CORE_H
#define APOLLO_CORE_H

#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ApolloCoreCaptureCodec {
  ApolloCoreCaptureCodecUnknown = -1,
  ApolloCoreCaptureCodecH264 = 0,
  ApolloCoreCaptureCodecHEVC = 1,
  ApolloCoreCaptureCodecProResProxy = 2
} ApolloCoreCaptureCodec;

typedef enum ApolloCoreCapturePreprocessStrategy {
  ApolloCoreCapturePreprocessStrategyNone = 0,
  ApolloCoreCapturePreprocessStrategyDownscale2x = 1
} ApolloCoreCapturePreprocessStrategy;

typedef enum ApolloCoreCaptureQueueProfile {
  ApolloCoreCaptureQueueProfileQ1 = 0,
  ApolloCoreCaptureQueueProfileQ2 = 1,
  ApolloCoreCaptureQueueProfileQ3 = 2,
  ApolloCoreCaptureQueueProfileQ4 = 3,
  ApolloCoreCaptureQueueProfileAuto = 4
} ApolloCoreCaptureQueueProfile;

typedef enum ApolloCoreAudioCaptureSourceKind {
  ApolloCoreAudioCaptureSourceKindUnknown = -1,
  ApolloCoreAudioCaptureSourceKindMicrophone = 0,
  ApolloCoreAudioCaptureSourceKindSystemOutput = 1
} ApolloCoreAudioCaptureSourceKind;

typedef enum ApolloCoreCaptureEventKind {
  ApolloCoreCaptureEventKindUnknown = -1,
  ApolloCoreCaptureEventKindStarted = 0,
  ApolloCoreCaptureEventKindStopped = 1,
  ApolloCoreCaptureEventKindRestarted = 2,
  ApolloCoreCaptureEventKindFailed = 3,
  ApolloCoreCaptureEventKindDroppedFrame = 4
} ApolloCoreCaptureEventKind;

typedef struct ApolloCoreHDRStaticMetadata {
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
} ApolloCoreHDRStaticMetadata;

typedef struct ApolloCoreEncodedCaptureIngress ApolloCoreEncodedCaptureIngress;
typedef struct ApolloCoreAudioCaptureIngress ApolloCoreAudioCaptureIngress;

typedef struct ApolloCoreEncodedCaptureIngressSnapshot {
  uint64_t frame_count;
  uint64_t event_count;
  uint64_t queued_frame_count;
  uint64_t queued_event_count;
  uint64_t dropped_frame_count;
  uint64_t dropped_event_count;
  bool has_last_frame;
  bool has_last_sample_buffer;
  ApolloCoreCaptureCodec last_frame_codec;
  size_t last_frame_payload_size;
  uint64_t last_frame_source_sequence_number;
  uint64_t last_frame_source_display_time;
  bool last_frame_is_key_frame;
  bool last_frame_is_hdr_signaled;
  bool has_last_event;
  ApolloCoreCaptureEventKind last_event_kind;
  bool last_event_has_stop_status;
  int32_t last_event_stop_status;
  bool last_event_has_automatic_restart_count;
  uint64_t last_event_automatic_restart_count;
  bool last_event_has_source_display_time;
  uint64_t last_event_source_display_time;
} ApolloCoreEncodedCaptureIngressSnapshot;

typedef struct ApolloCoreEncodedCaptureFrameRecord {
  bool has_value;
  ApolloCoreCaptureCodec codec;
  size_t payload_size;
  uint64_t source_sequence_number;
  uint64_t source_display_time;
  bool has_output_callback_latency_milliseconds;
  double output_callback_latency_milliseconds;
  bool is_key_frame;
  bool is_hdr_signaled;
} ApolloCoreEncodedCaptureFrameRecord;

typedef struct ApolloCoreEncodedCaptureEventRecord {
  bool has_value;
  ApolloCoreCaptureEventKind kind;
  bool has_stop_status;
  int32_t stop_status;
  bool has_automatic_restart_count;
  uint64_t automatic_restart_count;
  bool has_source_display_time;
  uint64_t source_display_time;
} ApolloCoreEncodedCaptureEventRecord;

const char *ApolloCoreBootstrapVersionString(void);
const char *ApolloCoreBootstrapRuntimeDescription(void);

ApolloCoreEncodedCaptureIngress *ApolloCoreEncodedCaptureIngressCreate(void);
void ApolloCoreEncodedCaptureIngressDestroy(ApolloCoreEncodedCaptureIngress *ingress);
void ApolloCoreEncodedCaptureIngressReset(ApolloCoreEncodedCaptureIngress *ingress);
void ApolloCoreEncodedCaptureIngressSetFrameCapacity(
  ApolloCoreEncodedCaptureIngress *ingress,
  size_t capacity
);
void ApolloCoreEncodedCaptureIngressSetEventCapacity(
  ApolloCoreEncodedCaptureIngress *ingress,
  size_t capacity
);
void ApolloCoreEncodedCaptureIngressConsumeSampleBuffer(
  ApolloCoreEncodedCaptureIngress *ingress,
  ApolloCoreCaptureCodec codec,
  uint64_t source_sequence_number,
  uint64_t source_display_time,
  bool has_output_callback_latency_milliseconds,
  double output_callback_latency_milliseconds,
  bool is_key_frame,
  bool is_hdr_signaled,
  CMSampleBufferRef sample_buffer
);
void ApolloCoreEncodedCaptureIngressConsumeEvent(
  ApolloCoreEncodedCaptureIngress *ingress,
  ApolloCoreCaptureEventKind kind,
  const char *message,
  bool has_stop_status,
  int32_t stop_status,
  bool has_automatic_restart_count,
  uint64_t automatic_restart_count,
  bool has_source_display_time,
  uint64_t source_display_time
);
ApolloCoreEncodedCaptureIngressSnapshot ApolloCoreEncodedCaptureIngressCopySnapshot(
  const ApolloCoreEncodedCaptureIngress *ingress
);
CMSampleBufferRef ApolloCoreEncodedCaptureIngressCreateRetainedLastSampleBuffer(
  const ApolloCoreEncodedCaptureIngress *ingress
);
ApolloCoreEncodedCaptureFrameRecord ApolloCoreEncodedCaptureIngressPopNextFrame(
  ApolloCoreEncodedCaptureIngress *ingress,
  CMSampleBufferRef *retained_sample_buffer_out
);
ApolloCoreEncodedCaptureEventRecord ApolloCoreEncodedCaptureIngressPopNextEvent(
  ApolloCoreEncodedCaptureIngress *ingress,
  char *message_destination,
  size_t message_capacity
);
size_t ApolloCoreEncodedCaptureIngressCopyLastEventMessage(
  const ApolloCoreEncodedCaptureIngress *ingress,
  char *destination,
  size_t capacity
);
ApolloCoreEncodedCaptureIngress *ApolloCoreSharedEncodedCaptureIngress(void);
void ApolloCoreEncodedCaptureIngressSetProducerActive(
  ApolloCoreEncodedCaptureIngress *ingress,
  bool active
);
bool ApolloCoreEncodedCaptureIngressIsProducerActive(
  const ApolloCoreEncodedCaptureIngress *ingress
);
bool ApolloCoreEncodedCaptureIngressWaitForData(
  ApolloCoreEncodedCaptureIngress *ingress,
  uint32_t timeout_milliseconds
);
bool ApolloCoreEncodedCaptureIngressWaitForProducerActive(
  ApolloCoreEncodedCaptureIngress *ingress,
  uint32_t timeout_milliseconds
);

typedef struct ApolloCoreAudioCaptureIngressSnapshot {
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
  ApolloCoreCaptureEventKind last_event_kind;
  bool last_event_has_stop_status;
  int32_t last_event_stop_status;
  bool last_event_has_automatic_restart_count;
  uint64_t last_event_automatic_restart_count;
  bool last_event_has_source_sequence_number;
  uint64_t last_event_source_sequence_number;
} ApolloCoreAudioCaptureIngressSnapshot;

typedef struct ApolloCoreAudioCaptureFrameRecord {
  bool has_value;
  uint64_t sequence_number;
  uint64_t host_time_nanoseconds;
  int32_t sample_rate;
  int32_t channel_count;
  int32_t frame_count;
  size_t pcm_byte_count;
} ApolloCoreAudioCaptureFrameRecord;

typedef struct ApolloCoreAudioCaptureEventRecord {
  bool has_value;
  ApolloCoreCaptureEventKind kind;
  bool has_stop_status;
  int32_t stop_status;
  bool has_automatic_restart_count;
  uint64_t automatic_restart_count;
  bool has_source_sequence_number;
  uint64_t source_sequence_number;
} ApolloCoreAudioCaptureEventRecord;

typedef struct ApolloCoreCaptureRequestSnapshot {
  uint64_t generation;
  uint64_t video_generation;
  uint64_t audio_generation;
  bool video_requested;
  bool audio_requested;
  uint32_t display_id;
  ApolloCoreCaptureCodec codec;
  ApolloCoreCapturePreprocessStrategy preprocess_strategy;
  ApolloCoreCaptureQueueProfile queue_profile;
  bool show_cursor;
  int32_t target_frame_rate;
  int32_t requested_width;
  int32_t requested_height;
  int32_t dynamic_range;
  int32_t client_display_gamut;
  int32_t client_display_transfer;
  int32_t effective_display_gamut;
  int32_t effective_display_transfer;
  bool has_effective_hdr_metadata;
  ApolloCoreHDRStaticMetadata effective_hdr_metadata;
  ApolloCoreAudioCaptureSourceKind audio_source_kind;
  bool audio_excludes_current_process;
  int32_t audio_sample_rate;
  int32_t audio_channel_count;
  int32_t audio_frame_size;
} ApolloCoreCaptureRequestSnapshot;

ApolloCoreAudioCaptureIngress *ApolloCoreAudioCaptureIngressCreate(void);
void ApolloCoreAudioCaptureIngressDestroy(ApolloCoreAudioCaptureIngress *ingress);
void ApolloCoreAudioCaptureIngressReset(ApolloCoreAudioCaptureIngress *ingress);
void ApolloCoreAudioCaptureIngressSetFrameCapacity(
  ApolloCoreAudioCaptureIngress *ingress,
  size_t capacity
);
void ApolloCoreAudioCaptureIngressSetEventCapacity(
  ApolloCoreAudioCaptureIngress *ingress,
  size_t capacity
);
void ApolloCoreAudioCaptureIngressConsumePCMFloat32(
  ApolloCoreAudioCaptureIngress *ingress,
  uint64_t sequence_number,
  uint64_t host_time_nanoseconds,
  int32_t sample_rate,
  int32_t channel_count,
  int32_t frame_count,
  const void *pcm_float32le,
  size_t pcm_byte_count
);
void ApolloCoreAudioCaptureIngressConsumeEvent(
  ApolloCoreAudioCaptureIngress *ingress,
  ApolloCoreCaptureEventKind kind,
  const char *message,
  bool has_stop_status,
  int32_t stop_status,
  bool has_automatic_restart_count,
  uint64_t automatic_restart_count,
  bool has_source_sequence_number,
  uint64_t source_sequence_number
);
ApolloCoreAudioCaptureIngressSnapshot ApolloCoreAudioCaptureIngressCopySnapshot(
  const ApolloCoreAudioCaptureIngress *ingress
);
ApolloCoreAudioCaptureFrameRecord ApolloCoreAudioCaptureIngressPopNextFrame(
  ApolloCoreAudioCaptureIngress *ingress,
  void *pcm_destination,
  size_t pcm_capacity,
  size_t *copied_size_out
);
ApolloCoreAudioCaptureEventRecord ApolloCoreAudioCaptureIngressPopNextEvent(
  ApolloCoreAudioCaptureIngress *ingress,
  char *message_destination,
  size_t message_capacity
);
size_t ApolloCoreAudioCaptureIngressCopyLastEventMessage(
  const ApolloCoreAudioCaptureIngress *ingress,
  char *destination,
  size_t capacity
);
ApolloCoreAudioCaptureIngress *ApolloCoreSharedAudioCaptureIngress(void);
void ApolloCoreAudioCaptureIngressSetProducerActive(
  ApolloCoreAudioCaptureIngress *ingress,
  bool active
);
bool ApolloCoreAudioCaptureIngressIsProducerActive(
  const ApolloCoreAudioCaptureIngress *ingress
);
bool ApolloCoreAudioCaptureIngressWaitForData(
  ApolloCoreAudioCaptureIngress *ingress,
  uint32_t timeout_milliseconds
);
bool ApolloCoreAudioCaptureIngressWaitForProducerActive(
  ApolloCoreAudioCaptureIngress *ingress,
  uint32_t timeout_milliseconds
);

ApolloCoreCaptureRequestSnapshot ApolloCoreCaptureRequestCopySnapshot(void);
bool ApolloCoreCaptureRequestWaitForGenerationChange(
  uint64_t observed_generation,
  uint32_t timeout_milliseconds
);
void ApolloCoreCaptureRequestPublishVideo(
  uint32_t display_id,
  ApolloCoreCaptureCodec codec,
  ApolloCoreCapturePreprocessStrategy preprocess_strategy,
  ApolloCoreCaptureQueueProfile queue_profile,
  bool show_cursor,
  int32_t target_frame_rate,
  int32_t requested_width,
  int32_t requested_height,
  int32_t dynamic_range,
  int32_t client_display_gamut,
  int32_t client_display_transfer,
  int32_t effective_display_gamut,
  int32_t effective_display_transfer,
  bool has_effective_hdr_metadata,
  ApolloCoreHDRStaticMetadata effective_hdr_metadata
);
void ApolloCoreCaptureRequestPublishAudio(
  ApolloCoreAudioCaptureSourceKind source_kind,
  uint32_t display_id,
  bool excludes_current_process_audio,
  int32_t sample_rate,
  int32_t channel_count,
  int32_t frame_size
);
void ApolloCoreCaptureRequestClear(void);

#ifdef __cplusplus
}
#endif

#endif
