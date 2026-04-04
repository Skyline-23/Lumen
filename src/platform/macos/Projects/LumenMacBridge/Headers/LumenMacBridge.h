#ifndef LUMEN_MAC_BRIDGE_H
#define LUMEN_MAC_BRIDGE_H

#include <LumenCore/LumenCore.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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

typedef struct LumenMacBridgeCaptureConfiguration {
  uint32_t display_id;
  LumenCoreCaptureCodec codec;
  LumenMacBridgePreprocessStrategy preprocess_strategy;
  LumenMacBridgeQueueProfile queue_profile;
  bool show_cursor;
  int32_t target_frame_rate;
  int32_t target_video_bitrate_kbps;
  int32_t requested_width;
  int32_t requested_height;
  LumenCoreSinkRequest sink_request;
  LumenCoreEffectiveDisplayState effective_display_state;
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
  LumenCoreCaptureEventKind last_event_kind;
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
  LumenCoreCaptureEventKind kind;
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

typedef void (*LumenMacBridgeEncodedFrameHandler)(
  void *context,
  LumenCoreEncodedCaptureFrameRecord record,
  CMSampleBufferRef retained_sample_buffer
);

typedef void (*LumenMacBridgeCaptureEventHandler)(
  void *context,
  LumenCoreEncodedCaptureEventRecord record,
  const char *message
);

typedef void (*LumenMacBridgeAudioFrameHandler)(
  void *context,
  LumenMacBridgeAudioCaptureFrameRecord record,
  const void *pcm_float32le,
  size_t pcm_byte_count
);

typedef void (*LumenMacBridgeAudioCaptureEventHandler)(
  void *context,
  LumenMacBridgeAudioCaptureEventRecord record,
  const char *message
);

typedef struct LumenMacBridgeForwardingCallbacks {
  void *context;
  /* The bridge releases retained_sample_buffer after the callback returns. */
  LumenMacBridgeEncodedFrameHandler encoded_frame_handler;
  LumenMacBridgeCaptureEventHandler capture_event_handler;
  LumenMacBridgeAudioFrameHandler audio_frame_handler;
  LumenMacBridgeAudioCaptureEventHandler audio_capture_event_handler;
} LumenMacBridgeForwardingCallbacks;

typedef struct LumenMacBridgeController LumenMacBridgeController;

LumenMacBridgeController *LumenMacBridgeControllerCreate(void);
void LumenMacBridgeControllerDestroy(LumenMacBridgeController *controller);

LumenMacBridgeCaptureConfiguration LumenMacBridgeControllerMakePanelNativeConfiguration(
  uint32_t display_id
);

LumenMacBridgeAudioCaptureConfiguration LumenMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration(
  void
);

LumenMacBridgeAudioCaptureConfiguration LumenMacBridgeControllerMakeSystemOutputAudioConfiguration(
  uint32_t display_id
);

bool LumenMacBridgeControllerStartMacDisplayKitCapture(
  LumenMacBridgeController *controller,
  LumenMacBridgeCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
);

void LumenMacBridgeControllerStopMacDisplayKitCapture(
  LumenMacBridgeController *controller
);

void LumenMacBridgeRequestImmediateCaptureKeyFrame(void);
void LumenMacBridgeRestartMacDisplayKitCapture(const char *reason);

bool LumenMacBridgeControllerStartMacDisplayKitAudioCapture(
  LumenMacBridgeController *controller,
  LumenMacBridgeAudioCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
);

void LumenMacBridgeControllerStopMacDisplayKitAudioCapture(
  LumenMacBridgeController *controller
);

void LumenMacBridgeControllerStartLumenCoreCaptureAutomation(
  LumenMacBridgeController *controller
);

void LumenMacBridgeControllerStopLumenCoreCaptureAutomation(
  LumenMacBridgeController *controller
);

bool LumenMacBridgeControllerIsLumenCoreCaptureAutomationRunning(
  LumenMacBridgeController *controller
);

LumenMacBridgeStatusSnapshot LumenMacBridgeControllerCopyStatusSnapshot(
  LumenMacBridgeController *controller
);

void LumenMacBridgeControllerConfigureCoreForwarding(
  LumenMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
);

LumenCoreEncodedCaptureIngressSnapshot LumenMacBridgeControllerCopyCoreForwardingSnapshot(
  LumenMacBridgeController *controller
);

void LumenMacBridgeControllerConfigureAudioForwarding(
  LumenMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
);

LumenMacBridgeAudioForwardingSnapshot LumenMacBridgeControllerCopyAudioForwardingSnapshot(
  LumenMacBridgeController *controller
);

LumenCoreEncodedCaptureFrameRecord LumenMacBridgeControllerPopNextForwardedFrame(
  LumenMacBridgeController *controller,
  CMSampleBufferRef *retained_sample_buffer_out
);

LumenCoreEncodedCaptureEventRecord LumenMacBridgeControllerPopNextForwardedEvent(
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

bool LumenMacBridgeControllerStartCoreForwardingPump(
  LumenMacBridgeController *controller,
  LumenMacBridgeForwardingCallbacks callbacks,
  uint32_t idle_sleep_milliseconds,
  char *error_destination,
  size_t error_capacity
);

void LumenMacBridgeControllerStopCoreForwardingPump(
  LumenMacBridgeController *controller
);

#ifdef __cplusplus
}
#endif

#endif
