#ifndef APOLLO_MAC_BRIDGE_H
#define APOLLO_MAC_BRIDGE_H

#include <ApolloCore/ApolloCore.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ApolloMacBridgePreprocessStrategy {
  ApolloMacBridgePreprocessStrategyNone = 0,
  ApolloMacBridgePreprocessStrategyDownscale2x = 1
} ApolloMacBridgePreprocessStrategy;

typedef enum ApolloMacBridgeQueueProfile {
  ApolloMacBridgeQueueProfileQ1 = 0,
  ApolloMacBridgeQueueProfileQ2 = 1,
  ApolloMacBridgeQueueProfileQ3 = 2,
  ApolloMacBridgeQueueProfileQ4 = 3
} ApolloMacBridgeQueueProfile;

typedef struct ApolloMacBridgeCaptureConfiguration {
  uint32_t display_id;
  ApolloCoreCaptureCodec codec;
  ApolloMacBridgePreprocessStrategy preprocess_strategy;
  ApolloMacBridgeQueueProfile queue_profile;
  bool show_cursor;
  int32_t target_frame_rate;
  int32_t requested_width;
  int32_t requested_height;
  bool enable_hdr;
  int32_t client_display_gamut;
  int32_t client_display_transfer;
} ApolloMacBridgeCaptureConfiguration;

typedef enum ApolloMacBridgeAudioSourceKind {
  ApolloMacBridgeAudioSourceKindMicrophone = 0,
  ApolloMacBridgeAudioSourceKindSystemOutput = 1
} ApolloMacBridgeAudioSourceKind;

typedef struct ApolloMacBridgeAudioCaptureConfiguration {
  ApolloMacBridgeAudioSourceKind source_kind;
  uint32_t display_id;
  bool excludes_current_process_audio;
  int32_t sample_rate;
  int32_t channel_count;
  int32_t frame_size;
  char input_id[256];
} ApolloMacBridgeAudioCaptureConfiguration;

typedef struct ApolloMacBridgeAudioForwardingSnapshot {
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
} ApolloMacBridgeAudioForwardingSnapshot;

typedef struct ApolloMacBridgeAudioCaptureFrameRecord {
  bool has_value;
  uint64_t sequence_number;
  uint64_t host_time_nanoseconds;
  int32_t sample_rate;
  int32_t channel_count;
  int32_t frame_count;
  size_t pcm_byte_count;
} ApolloMacBridgeAudioCaptureFrameRecord;

typedef struct ApolloMacBridgeAudioCaptureEventRecord {
  bool has_value;
  ApolloCoreCaptureEventKind kind;
  bool has_stop_status;
  int32_t stop_status;
  bool has_automatic_restart_count;
  uint64_t automatic_restart_count;
  bool has_source_sequence_number;
  uint64_t source_sequence_number;
} ApolloMacBridgeAudioCaptureEventRecord;

typedef struct ApolloMacBridgeStatusSnapshot {
  char core_version[128];
  char runtime_description[256];
  char integration_status[512];
  bool capture_session_running;
  bool audio_capture_session_running;
  bool automatic_capture_orchestration_running;
} ApolloMacBridgeStatusSnapshot;

typedef void (*ApolloMacBridgeEncodedFrameHandler)(
  void *context,
  ApolloCoreEncodedCaptureFrameRecord record,
  CMSampleBufferRef retained_sample_buffer
);

typedef void (*ApolloMacBridgeCaptureEventHandler)(
  void *context,
  ApolloCoreEncodedCaptureEventRecord record,
  const char *message
);

typedef void (*ApolloMacBridgeAudioFrameHandler)(
  void *context,
  ApolloMacBridgeAudioCaptureFrameRecord record,
  const void *pcm_float32le,
  size_t pcm_byte_count
);

typedef void (*ApolloMacBridgeAudioCaptureEventHandler)(
  void *context,
  ApolloMacBridgeAudioCaptureEventRecord record,
  const char *message
);

typedef struct ApolloMacBridgeForwardingCallbacks {
  void *context;
  /* The bridge releases retained_sample_buffer after the callback returns. */
  ApolloMacBridgeEncodedFrameHandler encoded_frame_handler;
  ApolloMacBridgeCaptureEventHandler capture_event_handler;
  ApolloMacBridgeAudioFrameHandler audio_frame_handler;
  ApolloMacBridgeAudioCaptureEventHandler audio_capture_event_handler;
} ApolloMacBridgeForwardingCallbacks;

typedef struct ApolloMacBridgeController ApolloMacBridgeController;

ApolloMacBridgeController *ApolloMacBridgeControllerCreate(void);
void ApolloMacBridgeControllerDestroy(ApolloMacBridgeController *controller);

ApolloMacBridgeCaptureConfiguration ApolloMacBridgeControllerMakePanelNativeConfiguration(
  uint32_t display_id
);

ApolloMacBridgeAudioCaptureConfiguration ApolloMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration(
  void
);

ApolloMacBridgeAudioCaptureConfiguration ApolloMacBridgeControllerMakeSystemOutputAudioConfiguration(
  uint32_t display_id
);

bool ApolloMacBridgeControllerStartMacDisplayKitCapture(
  ApolloMacBridgeController *controller,
  ApolloMacBridgeCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
);

void ApolloMacBridgeControllerStopMacDisplayKitCapture(
  ApolloMacBridgeController *controller
);

bool ApolloMacBridgeControllerStartMacDisplayKitAudioCapture(
  ApolloMacBridgeController *controller,
  ApolloMacBridgeAudioCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
);

void ApolloMacBridgeControllerStopMacDisplayKitAudioCapture(
  ApolloMacBridgeController *controller
);

void ApolloMacBridgeControllerStartApolloCoreCaptureAutomation(
  ApolloMacBridgeController *controller
);

void ApolloMacBridgeControllerStopApolloCoreCaptureAutomation(
  ApolloMacBridgeController *controller
);

bool ApolloMacBridgeControllerIsApolloCoreCaptureAutomationRunning(
  ApolloMacBridgeController *controller
);

ApolloMacBridgeStatusSnapshot ApolloMacBridgeControllerCopyStatusSnapshot(
  ApolloMacBridgeController *controller
);

void ApolloMacBridgeControllerConfigureCoreForwarding(
  ApolloMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
);

ApolloCoreEncodedCaptureIngressSnapshot ApolloMacBridgeControllerCopyCoreForwardingSnapshot(
  ApolloMacBridgeController *controller
);

void ApolloMacBridgeControllerConfigureAudioForwarding(
  ApolloMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
);

ApolloMacBridgeAudioForwardingSnapshot ApolloMacBridgeControllerCopyAudioForwardingSnapshot(
  ApolloMacBridgeController *controller
);

ApolloCoreEncodedCaptureFrameRecord ApolloMacBridgeControllerPopNextForwardedFrame(
  ApolloMacBridgeController *controller,
  CMSampleBufferRef *retained_sample_buffer_out
);

ApolloCoreEncodedCaptureEventRecord ApolloMacBridgeControllerPopNextForwardedEvent(
  ApolloMacBridgeController *controller,
  char *message_destination,
  size_t message_capacity
);

ApolloMacBridgeAudioCaptureFrameRecord ApolloMacBridgeControllerPopNextForwardedAudioFrame(
  ApolloMacBridgeController *controller,
  void *pcm_destination,
  size_t pcm_capacity,
  size_t *copied_size_out
);

ApolloMacBridgeAudioCaptureEventRecord ApolloMacBridgeControllerPopNextForwardedAudioEvent(
  ApolloMacBridgeController *controller,
  char *message_destination,
  size_t message_capacity
);

bool ApolloMacBridgeControllerStartCoreForwardingPump(
  ApolloMacBridgeController *controller,
  ApolloMacBridgeForwardingCallbacks callbacks,
  uint32_t idle_sleep_milliseconds,
  char *error_destination,
  size_t error_capacity
);

void ApolloMacBridgeControllerStopCoreForwardingPump(
  ApolloMacBridgeController *controller
);

#ifdef __cplusplus
}
#endif

#endif
