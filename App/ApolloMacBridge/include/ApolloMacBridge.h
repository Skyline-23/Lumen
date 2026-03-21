#ifndef APOLLO_MAC_BRIDGE_H
#define APOLLO_MAC_BRIDGE_H

#include <ApolloCore/ApolloCore.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ApolloMacBridgeCaptureBackend {
  ApolloMacBridgeCaptureBackendLegacyApollo = 0,
  ApolloMacBridgeCaptureBackendMacDisplayKit = 1
} ApolloMacBridgeCaptureBackend;

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
  ApolloMacBridgeCaptureBackend preferred_capture_backend;
  char core_version[128];
  char runtime_description[256];
  char integration_status[512];
} ApolloMacBridgeStatusSnapshot;

typedef struct ApolloMacBridgeController ApolloMacBridgeController;

ApolloMacBridgeController *ApolloMacBridgeControllerCreate(void);
void ApolloMacBridgeControllerDestroy(ApolloMacBridgeController *controller);

void ApolloMacBridgeControllerSetPreferredCaptureBackend(
  ApolloMacBridgeController *controller,
  ApolloMacBridgeCaptureBackend backend
);

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

#ifdef __cplusplus
}
#endif

#endif
