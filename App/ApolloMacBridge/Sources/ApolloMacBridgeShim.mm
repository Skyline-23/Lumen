#import "ApolloMacBridge.h"

#import <ApolloMacBridge/ApolloMacBridge-Swift.h>
#import <CoreFoundation/CoreFoundation.h>
#import <cstring>

struct ApolloMacBridgeController {
  ApolloBridgeObjCFacade *facade = nil;
};

namespace {
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

ApolloMacBridgeController *ApolloMacBridgeControllerCreate(void) {
  auto *controller = new ApolloMacBridgeController();
  controller->facade = [[ApolloBridgeObjCFacade alloc] init];
  return controller;
}

void ApolloMacBridgeControllerDestroy(ApolloMacBridgeController *controller) {
  if (!controller) {
    return;
  }

  controller->facade = nil;
  delete controller;
}

void ApolloMacBridgeControllerSetPreferredCaptureBackend(
  ApolloMacBridgeController *controller,
  ApolloMacBridgeCaptureBackend backend
) {
  if (!controller) {
    return;
  }

  [controller->facade setPreferredCaptureBackendRawValue:static_cast<NSInteger>(backend)];
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
  snapshot.preferred_capture_backend =
    static_cast<ApolloMacBridgeCaptureBackend>(box.preferredCaptureBackendRawValue);
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
