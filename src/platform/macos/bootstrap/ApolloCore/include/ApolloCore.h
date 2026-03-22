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

typedef enum ApolloCoreCaptureEventKind {
  ApolloCoreCaptureEventKindUnknown = -1,
  ApolloCoreCaptureEventKindStarted = 0,
  ApolloCoreCaptureEventKindStopped = 1,
  ApolloCoreCaptureEventKindRestarted = 2,
  ApolloCoreCaptureEventKindFailed = 3,
  ApolloCoreCaptureEventKindDroppedFrame = 4
} ApolloCoreCaptureEventKind;

typedef struct ApolloCoreEncodedCaptureIngress ApolloCoreEncodedCaptureIngress;

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

#ifdef __cplusplus
}
#endif

#endif
