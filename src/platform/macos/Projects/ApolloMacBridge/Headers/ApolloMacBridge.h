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
} ApolloMacBridgeCaptureConfiguration;

typedef struct ApolloMacBridgeStatusSnapshot {
  char core_version[128];
  char runtime_description[256];
  char integration_status[512];
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

typedef struct ApolloMacBridgeForwardingCallbacks {
  void *context;
  /* The bridge releases retained_sample_buffer after the callback returns. */
  ApolloMacBridgeEncodedFrameHandler encoded_frame_handler;
  ApolloMacBridgeCaptureEventHandler capture_event_handler;
} ApolloMacBridgeForwardingCallbacks;

typedef struct ApolloMacBridgeController ApolloMacBridgeController;

ApolloMacBridgeController *ApolloMacBridgeControllerCreate(void);
void ApolloMacBridgeControllerDestroy(ApolloMacBridgeController *controller);

ApolloMacBridgeCaptureConfiguration ApolloMacBridgeControllerMakePanelNativeConfiguration(
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

ApolloCoreEncodedCaptureFrameRecord ApolloMacBridgeControllerPopNextForwardedFrame(
  ApolloMacBridgeController *controller,
  CMSampleBufferRef *retained_sample_buffer_out
);

ApolloCoreEncodedCaptureEventRecord ApolloMacBridgeControllerPopNextForwardedEvent(
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
