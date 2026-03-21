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

#include <CoreFoundation/CoreFoundation.h>
#include <optional>
#include <string>
#include <utility>

namespace apollo::macbridge {

struct StartCaptureResult {
  bool started = false;
  std::string error_message;
};

struct DrainedFrame {
  ApolloCoreEncodedCaptureFrameRecord record {};
  CMSampleBufferRef sample_buffer = nullptr;

  DrainedFrame() = default;
  DrainedFrame(ApolloCoreEncodedCaptureFrameRecord frame_record, CMSampleBufferRef retained_sample_buffer):
      record(frame_record),
      sample_buffer(retained_sample_buffer) {
  }

  DrainedFrame(const DrainedFrame &) = delete;
  auto operator=(const DrainedFrame &) -> DrainedFrame & = delete;

  DrainedFrame(DrainedFrame &&other) noexcept:
      record(other.record),
      sample_buffer(other.sample_buffer) {
    other.record = {};
    other.sample_buffer = nullptr;
  }

  auto operator=(DrainedFrame &&other) noexcept -> DrainedFrame & {
    if (this != &other) {
      reset();
      record = other.record;
      sample_buffer = other.sample_buffer;
      other.record = {};
      other.sample_buffer = nullptr;
    }
    return *this;
  }

  ~DrainedFrame() {
    reset();
  }

  void reset() {
    if (sample_buffer) {
      CFRelease(sample_buffer);
      sample_buffer = nullptr;
    }
    record = {};
  }
};

struct DrainedEvent {
  ApolloCoreEncodedCaptureEventRecord record {};
  std::string message;
};

class Controller {
 public:
  Controller():
      controller_(ApolloMacBridgeControllerCreate()) {
  }

  ~Controller() {
    ApolloMacBridgeControllerDestroy(controller_);
  }

  Controller(const Controller &) = delete;
  auto operator=(const Controller &) -> Controller & = delete;

  Controller(Controller &&other) noexcept:
      controller_(other.controller_) {
    other.controller_ = nullptr;
  }

  auto operator=(Controller &&other) noexcept -> Controller & {
    if (this != &other) {
      ApolloMacBridgeControllerDestroy(controller_);
      controller_ = other.controller_;
      other.controller_ = nullptr;
    }
    return *this;
  }

  [[nodiscard]] auto raw_controller() const -> ApolloMacBridgeController * {
    return controller_;
  }

  void set_preferred_capture_backend(ApolloMacBridgeCaptureBackend backend) const {
    ApolloMacBridgeControllerSetPreferredCaptureBackend(controller_, backend);
  }

  [[nodiscard]] static auto make_panel_native_configuration(uint32_t display_id)
    -> ApolloMacBridgeCaptureConfiguration {
    return ApolloMacBridgeControllerMakePanelNativeConfiguration(display_id);
  }

  [[nodiscard]] auto start_mac_display_kit_capture(
    ApolloMacBridgeCaptureConfiguration configuration
  ) const -> StartCaptureResult {
    char error_buffer[512] = {};
    const bool started = ApolloMacBridgeControllerStartMacDisplayKitCapture(
      controller_,
      configuration,
      error_buffer,
      sizeof(error_buffer)
    );
    return {
      started,
      std::string(error_buffer)
    };
  }

  void stop_mac_display_kit_capture() const {
    ApolloMacBridgeControllerStopMacDisplayKitCapture(controller_);
  }

  [[nodiscard]] auto copy_status_snapshot() const -> ApolloMacBridgeStatusSnapshot {
    return ApolloMacBridgeControllerCopyStatusSnapshot(controller_);
  }

  void configure_core_forwarding(size_t frame_capacity, size_t event_capacity) const {
    ApolloMacBridgeControllerConfigureCoreForwarding(controller_, frame_capacity, event_capacity);
  }

  [[nodiscard]] auto copy_core_forwarding_snapshot() const
    -> ApolloCoreEncodedCaptureIngressSnapshot {
    return ApolloMacBridgeControllerCopyCoreForwardingSnapshot(controller_);
  }

  [[nodiscard]] auto pop_next_forwarded_frame() const -> std::optional<DrainedFrame> {
    CMSampleBufferRef retained_sample_buffer = nullptr;
    ApolloCoreEncodedCaptureFrameRecord record = ApolloMacBridgeControllerPopNextForwardedFrame(
      controller_,
      &retained_sample_buffer
    );
    if (!record.has_value) {
      return std::nullopt;
    }
    return DrainedFrame(record, retained_sample_buffer);
  }

  [[nodiscard]] auto pop_next_forwarded_event() const -> std::optional<DrainedEvent> {
    char message_buffer[1024] = {};
    ApolloCoreEncodedCaptureEventRecord record = ApolloMacBridgeControllerPopNextForwardedEvent(
      controller_,
      message_buffer,
      sizeof(message_buffer)
    );
    if (!record.has_value) {
      return std::nullopt;
    }
    return DrainedEvent {
      record,
      std::string(message_buffer)
    };
  }

  [[nodiscard]] auto start_core_forwarding_pump(
    ApolloMacBridgeForwardingCallbacks callbacks,
    uint32_t idle_sleep_milliseconds = 1
  ) const -> StartCaptureResult {
    char error_buffer[512] = {};
    const bool started = ApolloMacBridgeControllerStartCoreForwardingPump(
      controller_,
      callbacks,
      idle_sleep_milliseconds,
      error_buffer,
      sizeof(error_buffer)
    );
    return {
      started,
      std::string(error_buffer)
    };
  }

  void stop_core_forwarding_pump() const {
    ApolloMacBridgeControllerStopCoreForwardingPump(controller_);
  }

 private:
  ApolloMacBridgeController *controller_ = nullptr;
};

}  // namespace apollo::macbridge
#endif

#endif
