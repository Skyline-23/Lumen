#import "ApolloMacBridge.h"

#import <ApolloMacBridge/ApolloMacBridge-Swift.h>
#import <CoreFoundation/CoreFoundation.h>
#import <algorithm>
#import <atomic>
#import <chrono>
#import <cstring>
#import <memory>
#import <thread>

class ApolloMacBridgeForwardingPump {
 public:
  ApolloMacBridgeForwardingPump(
    ApolloBridgeObjCFacade *facade,
    ApolloMacBridgeForwardingCallbacks callbacks,
    uint32_t idle_sleep_milliseconds
  );

  ~ApolloMacBridgeForwardingPump();

  ApolloMacBridgeForwardingPump(const ApolloMacBridgeForwardingPump &) = delete;
  auto operator=(const ApolloMacBridgeForwardingPump &) -> ApolloMacBridgeForwardingPump & = delete;

  void stop();

 private:
  ApolloBridgeObjCFacade *facade_ = nil;
  ApolloMacBridgeForwardingCallbacks callbacks_ {};
  uint32_t idle_sleep_milliseconds_ = 1;
  std::atomic<bool> running_ {false};
  std::thread worker_;

  void run();
};

struct ApolloMacBridgeController {
  ApolloBridgeObjCFacade *facade = nil;
  std::unique_ptr<ApolloMacBridgeForwardingPump> forwarding_pump;
};

namespace {
  ApolloCoreEncodedCaptureFrameRecord to_frame_record(ApolloBridgeDrainedFrameBox *box) {
    ApolloCoreEncodedCaptureFrameRecord record {};
    record.has_value = true;
    record.codec = static_cast<ApolloCoreCaptureCodec>(box.codecRawValue);
    record.payload_size = static_cast<size_t>(box.payloadSize);
    record.source_sequence_number = box.sourceSequenceNumber;
    record.source_display_time = box.sourceDisplayTime;
    record.has_output_callback_latency_milliseconds = box.hasOutputCallbackLatencyMilliseconds;
    record.output_callback_latency_milliseconds = box.outputCallbackLatencyMilliseconds;
    record.is_key_frame = box.isKeyFrame;
    record.is_hdr_signaled = box.isHDRSignaled;
    return record;
  }

  ApolloCoreEncodedCaptureEventRecord to_event_record(ApolloBridgeDrainedEventBox *box) {
    ApolloCoreEncodedCaptureEventRecord record {};
    record.has_value = true;
    record.kind = static_cast<ApolloCoreCaptureEventKind>(box.kindRawValue);
    record.has_stop_status = box.hasStopStatus;
    record.stop_status = box.stopStatus;
    record.has_automatic_restart_count = box.hasAutomaticRestartCount;
    record.automatic_restart_count = box.automaticRestartCount;
    record.has_source_display_time = box.hasSourceDisplayTime;
    record.source_display_time = box.sourceDisplayTime;
    return record;
  }

  void copy_string_to_buffer(NSString *string, char *destination, std::size_t capacity) {
    if (!destination || capacity == 0) {
      return;
    }

    destination[0] = '\0';
    if (!string) {
      return;
    }

    const char *utf8 = string.UTF8String;
    if (!utf8) {
      return;
    }

    std::strncpy(destination, utf8, capacity - 1);
    destination[capacity - 1] = '\0';
  }

  ApolloMacBridgeCaptureConfiguration to_bridge_configuration(
    ApolloBridgeConfigurationBox *configuration
  ) {
    ApolloMacBridgeCaptureConfiguration result {};
    result.display_id = configuration.displayID;
    result.codec = static_cast<ApolloCoreCaptureCodec>(configuration.codecRawValue);
    result.preprocess_strategy =
      static_cast<ApolloMacBridgePreprocessStrategy>(configuration.preprocessStrategyRawValue);
    result.queue_profile = static_cast<ApolloMacBridgeQueueProfile>(configuration.queueProfileRawValue);
    result.show_cursor = configuration.showCursor;
    result.target_frame_rate = static_cast<int32_t>(configuration.targetFrameRate);
    return result;
  }

  ApolloBridgeConfigurationBox *to_configuration_box(
    ApolloMacBridgeCaptureConfiguration configuration
  ) {
    return [[ApolloBridgeConfigurationBox alloc]
      initWithDisplayID:configuration.display_id
           codecRawValue:static_cast<NSInteger>(configuration.codec)
 preprocessStrategyRawValue:static_cast<NSInteger>(configuration.preprocess_strategy)
     queueProfileRawValue:static_cast<NSInteger>(configuration.queue_profile)
              showCursor:configuration.show_cursor
          targetFrameRate:static_cast<NSInteger>(configuration.target_frame_rate)];
  }

}

ApolloMacBridgeForwardingPump::ApolloMacBridgeForwardingPump(
  ApolloBridgeObjCFacade *facade,
  ApolloMacBridgeForwardingCallbacks callbacks,
  uint32_t idle_sleep_milliseconds
):
    facade_(facade),
    callbacks_(callbacks),
    idle_sleep_milliseconds_(std::max<uint32_t>(1, idle_sleep_milliseconds)),
    running_(true),
    worker_([this]() { run(); }) {
}

ApolloMacBridgeForwardingPump::~ApolloMacBridgeForwardingPump() {
  stop();
}

void ApolloMacBridgeForwardingPump::stop() {
  if (!running_.exchange(false)) {
    return;
  }
  if (worker_.joinable()) {
    worker_.join();
  }
}

void ApolloMacBridgeForwardingPump::run() {
  while (running_.load(std::memory_order_acquire)) {
    bool delivered = false;

    @autoreleasepool {
      if (callbacks_.encoded_frame_handler) {
        ApolloBridgeDrainedFrameBox *frame_box = [facade_ popNextCoreForwardedFrameSync];
        if (frame_box) {
          ApolloCoreEncodedCaptureFrameRecord record = to_frame_record(frame_box);
          CMSampleBufferRef retained_sample_buffer =
            reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(frame_box.sampleBuffer)));
          callbacks_.encoded_frame_handler(callbacks_.context, record, retained_sample_buffer);
          CFRelease(retained_sample_buffer);
          delivered = true;
        }
      }

      if (callbacks_.capture_event_handler) {
        ApolloBridgeDrainedEventBox *event_box = [facade_ popNextCoreForwardedEventSync];
        if (event_box) {
          ApolloCoreEncodedCaptureEventRecord record = to_event_record(event_box);
          const char *message = event_box.message.UTF8String ?: "";
          callbacks_.capture_event_handler(callbacks_.context, record, message);
          delivered = true;
        }
      }
    }

    if (!delivered) {
      std::this_thread::sleep_for(std::chrono::milliseconds(idle_sleep_milliseconds_));
    }
  }
}

ApolloMacBridgeController *ApolloMacBridgeControllerCreate(void) {
  auto *controller = new ApolloMacBridgeController();
  controller->facade = [[ApolloBridgeObjCFacade alloc] init];
  return controller;
}

void ApolloMacBridgeControllerDestroy(ApolloMacBridgeController *controller) {
  if (!controller) {
    return;
  }

  controller->forwarding_pump.reset();
  controller->facade = nil;
  delete controller;
}

ApolloMacBridgeCaptureConfiguration ApolloMacBridgeControllerMakePanelNativeConfiguration(
  uint32_t display_id
) {
  ApolloBridgeObjCFacade *facade = [[ApolloBridgeObjCFacade alloc] init];
  return to_bridge_configuration([facade makePanelNativeConfigurationWithDisplayID:display_id]);
}

bool ApolloMacBridgeControllerStartMacDisplayKitCapture(
  ApolloMacBridgeController *controller,
  ApolloMacBridgeCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
) {
  if (!controller) {
    copy_string_to_buffer(@"ApolloMacBridgeControllerStartMacDisplayKitCapture called with a null controller.",
                          error_destination,
                          error_capacity);
    return false;
  }

  NSError *error = nil;
  const BOOL started = [controller->facade startMacDisplayKitCaptureSync:to_configuration_box(configuration)
                                                                   error:&error];
  copy_string_to_buffer(error.localizedDescription, error_destination, error_capacity);
  return started == YES;
}

void ApolloMacBridgeControllerStopMacDisplayKitCapture(
  ApolloMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  [controller->facade stopMacDisplayKitCaptureSync];
}

ApolloMacBridgeStatusSnapshot ApolloMacBridgeControllerCopyStatusSnapshot(
  ApolloMacBridgeController *controller
) {
  ApolloMacBridgeStatusSnapshot snapshot {};
  if (!controller) {
    return snapshot;
  }

  ApolloBridgeStatusBox *box = [controller->facade copyStatusSnapshotSync];
  copy_string_to_buffer(box.coreVersion, snapshot.core_version, sizeof(snapshot.core_version));
  copy_string_to_buffer(box.runtimeDescription,
                        snapshot.runtime_description,
                        sizeof(snapshot.runtime_description));
  copy_string_to_buffer(box.integrationStatus,
                        snapshot.integration_status,
                        sizeof(snapshot.integration_status));
  return snapshot;
}

void ApolloMacBridgeControllerConfigureCoreForwarding(
  ApolloMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
) {
  if (!controller) {
    return;
  }

  [controller->facade configureCoreForwardingSyncWithFrameCapacity:static_cast<NSInteger>(frame_capacity)
                                                     eventCapacity:static_cast<NSInteger>(event_capacity)];
}

ApolloCoreEncodedCaptureIngressSnapshot ApolloMacBridgeControllerCopyCoreForwardingSnapshot(
  ApolloMacBridgeController *controller
) {
  ApolloCoreEncodedCaptureIngressSnapshot snapshot {};
  if (!controller) {
    return snapshot;
  }

  ApolloBridgeCoreForwardingSnapshotBox *box = [controller->facade copyCoreForwardingSnapshotSync];
  snapshot.frame_count = box.frameCount;
  snapshot.event_count = box.eventCount;
  snapshot.queued_frame_count = box.queuedFrameCount;
  snapshot.queued_event_count = box.queuedEventCount;
  snapshot.dropped_frame_count = box.droppedFrameCount;
  snapshot.dropped_event_count = box.droppedEventCount;
  snapshot.has_last_sample_buffer = box.hasLastSampleBuffer;
  snapshot.has_last_frame = box.lastFrameCodecRawValue >= 0;
  snapshot.last_frame_codec = static_cast<ApolloCoreCaptureCodec>(box.lastFrameCodecRawValue);
  snapshot.last_frame_payload_size = static_cast<size_t>(box.lastFramePayloadSize);
  snapshot.last_frame_source_sequence_number = box.lastFrameSourceSequenceNumber;
  snapshot.last_frame_source_display_time = box.lastFrameSourceDisplayTime;
  snapshot.last_frame_is_key_frame = box.lastFrameIsKeyFrame;
  snapshot.last_frame_is_hdr_signaled = box.lastFrameIsHDRSignaled;
  snapshot.has_last_event = box.lastEventKindRawValue >= 0;
  snapshot.last_event_kind = static_cast<ApolloCoreCaptureEventKind>(box.lastEventKindRawValue);
  return snapshot;
}

ApolloCoreEncodedCaptureFrameRecord ApolloMacBridgeControllerPopNextForwardedFrame(
  ApolloMacBridgeController *controller,
  CMSampleBufferRef *retained_sample_buffer_out
) {
  ApolloCoreEncodedCaptureFrameRecord record {};
  if (retained_sample_buffer_out) {
    *retained_sample_buffer_out = nullptr;
  }
  if (!controller) {
    return record;
  }

  ApolloBridgeDrainedFrameBox *box = [controller->facade popNextCoreForwardedFrameSync];
  if (!box) {
    return record;
  }

  record.has_value = true;
  record.codec = static_cast<ApolloCoreCaptureCodec>(box.codecRawValue);
  record.payload_size = static_cast<size_t>(box.payloadSize);
  record.source_sequence_number = box.sourceSequenceNumber;
  record.source_display_time = box.sourceDisplayTime;
  record.has_output_callback_latency_milliseconds = box.hasOutputCallbackLatencyMilliseconds;
  record.output_callback_latency_milliseconds = box.outputCallbackLatencyMilliseconds;
  record.is_key_frame = box.isKeyFrame;
  record.is_hdr_signaled = box.isHDRSignaled;

  if (retained_sample_buffer_out) {
    *retained_sample_buffer_out =
      reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(box.sampleBuffer)));
  }

  return record;
}

ApolloCoreEncodedCaptureEventRecord ApolloMacBridgeControllerPopNextForwardedEvent(
  ApolloMacBridgeController *controller,
  char *message_destination,
  size_t message_capacity
) {
  ApolloCoreEncodedCaptureEventRecord record {};
  if (!controller) {
    return record;
  }

  ApolloBridgeDrainedEventBox *box = [controller->facade popNextCoreForwardedEventSync];
  if (!box) {
    copy_string_to_buffer(nil, message_destination, message_capacity);
    return record;
  }

  record.has_value = true;
  record.kind = static_cast<ApolloCoreCaptureEventKind>(box.kindRawValue);
  record.has_stop_status = box.hasStopStatus;
  record.stop_status = box.stopStatus;
  record.has_automatic_restart_count = box.hasAutomaticRestartCount;
  record.automatic_restart_count = box.automaticRestartCount;
  record.has_source_display_time = box.hasSourceDisplayTime;
  record.source_display_time = box.sourceDisplayTime;
  copy_string_to_buffer(box.message, message_destination, message_capacity);
  return record;
}

bool ApolloMacBridgeControllerStartCoreForwardingPump(
  ApolloMacBridgeController *controller,
  ApolloMacBridgeForwardingCallbacks callbacks,
  uint32_t idle_sleep_milliseconds,
  char *error_destination,
  size_t error_capacity
) {
  copy_string_to_buffer(nil, error_destination, error_capacity);

  if (!controller) {
    copy_string_to_buffer(@"ApolloMacBridgeControllerStartCoreForwardingPump called with a null controller.",
                          error_destination,
                          error_capacity);
    return false;
  }

  if (!callbacks.encoded_frame_handler && !callbacks.capture_event_handler) {
    copy_string_to_buffer(@"ApolloMacBridgeControllerStartCoreForwardingPump requires at least one callback.",
                          error_destination,
                          error_capacity);
    return false;
  }

  controller->forwarding_pump.reset();
  controller->forwarding_pump = std::make_unique<ApolloMacBridgeForwardingPump>(
    controller->facade,
    callbacks,
    idle_sleep_milliseconds
  );
  return true;
}

void ApolloMacBridgeControllerStopCoreForwardingPump(
  ApolloMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  controller->forwarding_pump.reset();
}
