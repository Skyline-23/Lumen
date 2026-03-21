#ifndef APOLLO_CORE_H
#define APOLLO_CORE_H

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

typedef struct ApolloCoreEncodedCaptureConsumer ApolloCoreEncodedCaptureConsumer;

typedef struct ApolloCoreEncodedCaptureConsumerSnapshot {
  uint64_t frame_count;
  uint64_t event_count;
  bool has_last_frame;
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
} ApolloCoreEncodedCaptureConsumerSnapshot;

const char *ApolloCoreBootstrapVersionString(void);
const char *ApolloCoreBootstrapRuntimeDescription(void);

ApolloCoreEncodedCaptureConsumer *ApolloCoreEncodedCaptureConsumerCreate(void);
void ApolloCoreEncodedCaptureConsumerDestroy(ApolloCoreEncodedCaptureConsumer *consumer);
void ApolloCoreEncodedCaptureConsumerReset(ApolloCoreEncodedCaptureConsumer *consumer);
void ApolloCoreEncodedCaptureConsumerConsumeFrame(
  ApolloCoreEncodedCaptureConsumer *consumer,
  ApolloCoreCaptureCodec codec,
  uint64_t source_sequence_number,
  uint64_t source_display_time,
  bool has_output_callback_latency_milliseconds,
  double output_callback_latency_milliseconds,
  bool is_key_frame,
  bool is_hdr_signaled,
  const uint8_t *payload_bytes,
  size_t payload_size
);
void ApolloCoreEncodedCaptureConsumerConsumeEvent(
  ApolloCoreEncodedCaptureConsumer *consumer,
  ApolloCoreCaptureEventKind kind,
  const char *message,
  bool has_stop_status,
  int32_t stop_status,
  bool has_automatic_restart_count,
  uint64_t automatic_restart_count,
  bool has_source_display_time,
  uint64_t source_display_time
);
ApolloCoreEncodedCaptureConsumerSnapshot ApolloCoreEncodedCaptureConsumerCopySnapshot(
  const ApolloCoreEncodedCaptureConsumer *consumer
);
size_t ApolloCoreEncodedCaptureConsumerCopyLastFramePayload(
  const ApolloCoreEncodedCaptureConsumer *consumer,
  uint8_t *destination,
  size_t capacity
);
size_t ApolloCoreEncodedCaptureConsumerCopyLastEventMessage(
  const ApolloCoreEncodedCaptureConsumer *consumer,
  char *destination,
  size_t capacity
);

#ifdef __cplusplus
}
#endif

#endif
