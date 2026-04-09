#import "LumenMacBridge.h"

#import <LumenMacBridge/LumenMacBridge-Swift.h>
#import <CoreFoundation/CoreFoundation.h>
#import <algorithm>
#import <atomic>
#import <chrono>
#import <cstring>
#import <memory>
#import <thread>

class LumenMacBridgeForwardingPump {
 public:
  LumenMacBridgeForwardingPump(
    LumenBridgeObjCFacade *facade,
    LumenMacBridgeForwardingCallbacks callbacks,
    uint32_t idle_sleep_milliseconds
  );

  ~LumenMacBridgeForwardingPump();

  LumenMacBridgeForwardingPump(const LumenMacBridgeForwardingPump &) = delete;
  auto operator=(const LumenMacBridgeForwardingPump &) -> LumenMacBridgeForwardingPump & = delete;

  void stop();

 private:
  LumenBridgeObjCFacade *facade_ = nil;
  LumenMacBridgeForwardingCallbacks callbacks_ {};
  uint32_t idle_sleep_milliseconds_ = 1;
  std::atomic<bool> running_ {false};
  std::thread worker_;

  void run();
};

struct LumenMacBridgeController {
  LumenBridgeObjCFacade *facade = nil;
  std::unique_ptr<LumenMacBridgeForwardingPump> forwarding_pump;
};

namespace {
  LumenCoreEncodedCaptureFrameRecord to_frame_record(LumenBridgeDrainedFrameBox *box) {
    LumenCoreEncodedCaptureFrameRecord record {};
    record.has_value = true;
    record.codec = static_cast<LumenCoreCaptureCodec>(box.codecRawValue);
    record.payload_size = static_cast<size_t>(box.payloadSize);
    record.source_sequence_number = box.sourceSequenceNumber;
    record.source_display_time = box.sourceDisplayTime;
    record.has_output_callback_latency_milliseconds = box.hasOutputCallbackLatencyMilliseconds;
    record.output_callback_latency_milliseconds = box.outputCallbackLatencyMilliseconds;
    record.is_key_frame = box.isKeyFrame;
    record.is_hdr_signaled = box.isHDRSignaled;
    return record;
  }

  LumenCoreEncodedCaptureEventRecord to_event_record(LumenBridgeDrainedEventBox *box) {
    LumenCoreEncodedCaptureEventRecord record {};
    record.has_value = true;
    record.kind = static_cast<LumenCoreCaptureEventKind>(box.kindRawValue);
    record.has_stop_status = box.hasStopStatus;
    record.stop_status = box.stopStatus;
    record.has_automatic_restart_count = box.hasAutomaticRestartCount;
    record.automatic_restart_count = box.automaticRestartCount;
    record.has_source_display_time = box.hasSourceDisplayTime;
    record.source_display_time = box.sourceDisplayTime;
    return record;
  }

  LumenMacBridgeAudioCaptureFrameRecord to_audio_frame_record(LumenBridgeDrainedAudioFrameBox *box) {
    LumenMacBridgeAudioCaptureFrameRecord record {};
    record.has_value = true;
    record.sequence_number = box.sequenceNumber;
    record.host_time_nanoseconds = box.hostTimeNanoseconds;
    record.sample_rate = static_cast<int32_t>(box.sampleRate);
    record.channel_count = static_cast<int32_t>(box.channelCount);
    record.frame_count = static_cast<int32_t>(box.frameCount);
    record.pcm_byte_count = static_cast<size_t>(box.pcmFloat32LE.length);
    return record;
  }

  LumenMacBridgeAudioCaptureEventRecord to_audio_event_record(LumenBridgeDrainedAudioEventBox *box) {
    LumenMacBridgeAudioCaptureEventRecord record {};
    record.has_value = true;
    record.kind = static_cast<LumenCoreCaptureEventKind>(box.kindRawValue);
    record.has_stop_status = box.hasStopStatus;
    record.stop_status = box.stopStatus;
    record.has_automatic_restart_count = box.hasAutomaticRestartCount;
    record.automatic_restart_count = box.automaticRestartCount;
    record.has_source_sequence_number = box.hasSourceSequenceNumber;
    record.source_sequence_number = box.sourceSequenceNumber;
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

  LumenMacBridgeCaptureConfiguration to_bridge_configuration(
    LumenBridgeConfigurationBox *configuration
  ) {
    LumenMacBridgeCaptureConfiguration result {};
    result.display_id = configuration.displayID;
    result.codec = static_cast<LumenCoreCaptureCodec>(configuration.codecRawValue);
    result.preprocess_strategy =
      static_cast<LumenMacBridgePreprocessStrategy>(configuration.preprocessStrategyRawValue);
    result.queue_profile = static_cast<LumenMacBridgeQueueProfile>(configuration.queueProfileRawValue);
    result.show_cursor = configuration.showCursor;
    result.target_frame_rate = static_cast<int32_t>(configuration.targetFrameRate);
    result.target_video_bitrate_kbps = static_cast<int32_t>(configuration.targetVideoBitRateKbps);
    result.requested_width = static_cast<int32_t>(configuration.requestedWidth);
    result.requested_height = static_cast<int32_t>(configuration.requestedHeight);
    result.sink_request.mode.hidpi = configuration.sinkRequest.mode.hidpi;
    result.sink_request.mode.scale_explicit = configuration.sinkRequest.mode.scaleExplicit;
    result.sink_request.mode.mode_is_logical = configuration.sinkRequest.mode.modeIsLogical;
    result.sink_request.mode.scale_percent = static_cast<int32_t>(configuration.sinkRequest.mode.scalePercent);
    result.sink_request.capability.gamut = static_cast<int32_t>(configuration.sinkRequest.capability.gamutRawValue);
    result.sink_request.capability.transfer = static_cast<int32_t>(configuration.sinkRequest.capability.transferRawValue);
    result.sink_request.capability.current_edr_headroom = configuration.sinkRequest.capability.currentEDRHeadroom;
    result.sink_request.capability.potential_edr_headroom = configuration.sinkRequest.capability.potentialEDRHeadroom;
    result.sink_request.capability.current_peak_luminance_nits = static_cast<int32_t>(configuration.sinkRequest.capability.currentPeakLuminanceNits);
    result.sink_request.capability.potential_peak_luminance_nits = static_cast<int32_t>(configuration.sinkRequest.capability.potentialPeakLuminanceNits);
    result.sink_request.capability.supports_frame_gated_hdr = configuration.sinkRequest.capability.supportsFrameGatedHDR;
    result.sink_request.capability.supports_hdr_tile_overlay = configuration.sinkRequest.capability.supportsHDRTileOverlay;
    result.sink_request.capability.supports_per_frame_hdr_metadata = configuration.sinkRequest.capability.supportsPerFrameHDRMetadata;
    result.sink_request.dynamic_range_transport =
      static_cast<LumenCoreDynamicRangeTransport>(configuration.sinkRequest.dynamicRangeTransportRawValue);
    result.effective_display_state.gamut = static_cast<int32_t>(configuration.effectiveDisplayState.gamutRawValue);
    result.effective_display_state.transfer = static_cast<int32_t>(configuration.effectiveDisplayState.transferRawValue);
    result.effective_display_state.has_hdr_static_metadata = configuration.effectiveDisplayState.hdrStaticMetadata != nil;
    if (configuration.effectiveDisplayState.hdrStaticMetadata) {
      result.effective_display_state.hdr_static_metadata.red_primary_x = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.redPrimaryX);
      result.effective_display_state.hdr_static_metadata.red_primary_y = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.redPrimaryY);
      result.effective_display_state.hdr_static_metadata.green_primary_x = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.greenPrimaryX);
      result.effective_display_state.hdr_static_metadata.green_primary_y = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.greenPrimaryY);
      result.effective_display_state.hdr_static_metadata.blue_primary_x = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.bluePrimaryX);
      result.effective_display_state.hdr_static_metadata.blue_primary_y = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.bluePrimaryY);
      result.effective_display_state.hdr_static_metadata.white_point_x = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.whitePointX);
      result.effective_display_state.hdr_static_metadata.white_point_y = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.whitePointY);
      result.effective_display_state.hdr_static_metadata.max_display_luminance = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.maxDisplayLuminance);
      result.effective_display_state.hdr_static_metadata.min_display_luminance = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.minDisplayLuminance);
      result.effective_display_state.hdr_static_metadata.max_content_light_level = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.maxContentLightLevel);
      result.effective_display_state.hdr_static_metadata.max_frame_average_light_level = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.maxFrameAverageLightLevel);
      result.effective_display_state.hdr_static_metadata.max_full_frame_luminance = static_cast<int32_t>(configuration.effectiveDisplayState.hdrStaticMetadata.maxFullFrameLuminance);
    }
    return result;
  }

  LumenBridgeConfigurationBox *to_configuration_box(
    LumenMacBridgeCaptureConfiguration configuration
  ) {
    LumenBridgeSinkModeBox *sinkMode = [[LumenBridgeSinkModeBox alloc]
      initWithHidpi:configuration.sink_request.mode.hidpi
      scaleExplicit:configuration.sink_request.mode.scale_explicit
      modeIsLogical:configuration.sink_request.mode.mode_is_logical
      scalePercent:static_cast<NSInteger>(configuration.sink_request.mode.scale_percent)];
    LumenBridgeSinkCapabilityBox *sinkCapability = [[LumenBridgeSinkCapabilityBox alloc]
      initWithGamutRawValue:static_cast<NSInteger>(configuration.sink_request.capability.gamut)
      transferRawValue:static_cast<NSInteger>(configuration.sink_request.capability.transfer)
      currentEDRHeadroom:configuration.sink_request.capability.current_edr_headroom
      potentialEDRHeadroom:configuration.sink_request.capability.potential_edr_headroom
      currentPeakLuminanceNits:static_cast<NSInteger>(configuration.sink_request.capability.current_peak_luminance_nits)
      potentialPeakLuminanceNits:static_cast<NSInteger>(configuration.sink_request.capability.potential_peak_luminance_nits)
      supportsFrameGatedHDR:configuration.sink_request.capability.supports_frame_gated_hdr
      supportsHDRTileOverlay:configuration.sink_request.capability.supports_hdr_tile_overlay
      supportsPerFrameHDRMetadata:configuration.sink_request.capability.supports_per_frame_hdr_metadata];
    LumenBridgeSinkRequestBox *sinkRequest = [[LumenBridgeSinkRequestBox alloc]
      initWithMode:sinkMode
      capability:sinkCapability
      dynamicRangeTransportRawValue:static_cast<NSInteger>(configuration.sink_request.dynamic_range_transport)];
    LumenBridgeHDRStaticMetadataBox *hdrStaticMetadata = nil;
    if (configuration.effective_display_state.has_hdr_static_metadata) {
      hdrStaticMetadata = [[LumenBridgeHDRStaticMetadataBox alloc]
        initWithRedPrimaryX:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.red_primary_x)
        redPrimaryY:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.red_primary_y)
        greenPrimaryX:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.green_primary_x)
        greenPrimaryY:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.green_primary_y)
        bluePrimaryX:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.blue_primary_x)
        bluePrimaryY:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.blue_primary_y)
        whitePointX:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.white_point_x)
        whitePointY:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.white_point_y)
        maxDisplayLuminance:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.max_display_luminance)
        minDisplayLuminance:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.min_display_luminance)
        maxContentLightLevel:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.max_content_light_level)
        maxFrameAverageLightLevel:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.max_frame_average_light_level)
        maxFullFrameLuminance:static_cast<NSInteger>(configuration.effective_display_state.hdr_static_metadata.max_full_frame_luminance)];
    }
    LumenBridgeEffectiveDisplayStateBox *effectiveDisplayState = [[LumenBridgeEffectiveDisplayStateBox alloc]
      initWithGamutRawValue:static_cast<NSInteger>(configuration.effective_display_state.gamut)
      transferRawValue:static_cast<NSInteger>(configuration.effective_display_state.transfer)
      hdrStaticMetadata:hdrStaticMetadata];
    return [[LumenBridgeConfigurationBox alloc]
      initWithDisplayID:configuration.display_id
           codecRawValue:static_cast<NSInteger>(configuration.codec)
 preprocessStrategyRawValue:static_cast<NSInteger>(configuration.preprocess_strategy)
     queueProfileRawValue:static_cast<NSInteger>(configuration.queue_profile)
              showCursor:configuration.show_cursor
          targetFrameRate:static_cast<NSInteger>(configuration.target_frame_rate)
     targetVideoBitRateKbps:static_cast<NSInteger>(configuration.target_video_bitrate_kbps)
           requestedWidth:static_cast<NSInteger>(configuration.requested_width)
          requestedHeight:static_cast<NSInteger>(configuration.requested_height)
              sinkRequest:sinkRequest
      effectiveDisplayState:effectiveDisplayState];
  }

  LumenMacBridgeAudioCaptureConfiguration to_audio_bridge_configuration(
    LumenBridgeAudioConfigurationBox *configuration
  ) {
    LumenMacBridgeAudioCaptureConfiguration result {};
    result.source_kind = static_cast<LumenMacBridgeAudioSourceKind>(configuration.sourceKindRawValue);
    result.display_id = configuration.displayID;
    result.excludes_current_process_audio = configuration.excludesCurrentProcessAudio;
    result.sample_rate = static_cast<int32_t>(configuration.sampleRate);
    result.channel_count = static_cast<int32_t>(configuration.channelCount);
    result.frame_size = static_cast<int32_t>(configuration.frameSize);
    copy_string_to_buffer(configuration.inputID ? : @"", result.input_id, sizeof(result.input_id));
    return result;
  }

  LumenBridgeAudioConfigurationBox *to_audio_configuration_box(
    LumenMacBridgeAudioCaptureConfiguration configuration
  ) {
    NSString *inputID = configuration.input_id[0] != '\0' ?
      [NSString stringWithUTF8String:configuration.input_id] :
      nil;
    return [[LumenBridgeAudioConfigurationBox alloc]
      initWithSourceKindRawValue:static_cast<NSInteger>(configuration.source_kind)
                       displayID:configuration.display_id
      excludesCurrentProcessAudio:configuration.excludes_current_process_audio
                         inputID:inputID
                      sampleRate:static_cast<NSInteger>(configuration.sample_rate)
                    channelCount:static_cast<NSInteger>(configuration.channel_count)
                       frameSize:static_cast<NSInteger>(configuration.frame_size)];
  }

}

LumenMacBridgeForwardingPump::LumenMacBridgeForwardingPump(
  LumenBridgeObjCFacade *facade,
  LumenMacBridgeForwardingCallbacks callbacks,
  uint32_t idle_sleep_milliseconds
):
    facade_(facade),
    callbacks_(callbacks),
    idle_sleep_milliseconds_(std::max<uint32_t>(1, idle_sleep_milliseconds)),
    running_(true),
    worker_([this]() { run(); }) {
}

LumenMacBridgeForwardingPump::~LumenMacBridgeForwardingPump() {
  stop();
}

void LumenMacBridgeForwardingPump::stop() {
  if (!running_.exchange(false)) {
    return;
  }
  if (worker_.joinable()) {
    worker_.join();
  }
}

void LumenMacBridgeForwardingPump::run() {
  while (running_.load(std::memory_order_acquire)) {
    bool delivered = false;

    @autoreleasepool {
      if (callbacks_.encoded_frame_handler) {
        LumenBridgeDrainedFrameBox *frame_box = [facade_ popNextCoreForwardedFrameSync];
        if (frame_box) {
          LumenCoreEncodedCaptureFrameRecord record = to_frame_record(frame_box);
          CMSampleBufferRef retained_sample_buffer =
            reinterpret_cast<CMSampleBufferRef>(const_cast<void *>(CFRetain(frame_box.sampleBuffer)));
          callbacks_.encoded_frame_handler(callbacks_.context, record, retained_sample_buffer);
          CFRelease(retained_sample_buffer);
          delivered = true;
        }
      }

      if (callbacks_.capture_event_handler) {
        LumenBridgeDrainedEventBox *event_box = [facade_ popNextCoreForwardedEventSync];
        if (event_box) {
          LumenCoreEncodedCaptureEventRecord record = to_event_record(event_box);
          const char *message = event_box.message.UTF8String ?: "";
          callbacks_.capture_event_handler(callbacks_.context, record, message);
          delivered = true;
        }
      }

      if (callbacks_.audio_frame_handler) {
        LumenBridgeDrainedAudioFrameBox *audio_frame_box = [facade_ popNextCoreForwardedAudioFrameSync];
        if (audio_frame_box) {
          LumenMacBridgeAudioCaptureFrameRecord record = to_audio_frame_record(audio_frame_box);
          callbacks_.audio_frame_handler(
            callbacks_.context,
            record,
            audio_frame_box.pcmFloat32LE.bytes,
            static_cast<size_t>(audio_frame_box.pcmFloat32LE.length)
          );
          delivered = true;
        }
      }

      if (callbacks_.audio_capture_event_handler) {
        LumenBridgeDrainedAudioEventBox *audio_event_box = [facade_ popNextCoreForwardedAudioEventSync];
        if (audio_event_box) {
          LumenMacBridgeAudioCaptureEventRecord record = to_audio_event_record(audio_event_box);
          const char *message = audio_event_box.message.UTF8String ?: "";
          callbacks_.audio_capture_event_handler(callbacks_.context, record, message);
          delivered = true;
        }
      }
    }

    if (!delivered) {
      std::this_thread::sleep_for(std::chrono::milliseconds(idle_sleep_milliseconds_));
    }
  }
}

LumenMacBridgeController *LumenMacBridgeControllerCreate(void) {
  auto *controller = new LumenMacBridgeController();
  controller->facade = [[LumenBridgeObjCFacade alloc] init];
  return controller;
}

void LumenMacBridgeControllerDestroy(LumenMacBridgeController *controller) {
  if (!controller) {
    return;
  }

  controller->forwarding_pump.reset();
  controller->facade = nil;
  delete controller;
}

LumenMacBridgeCaptureConfiguration LumenMacBridgeControllerMakePanelNativeConfiguration(
  uint32_t display_id
) {
  LumenBridgeObjCFacade *facade = [[LumenBridgeObjCFacade alloc] init];
  return to_bridge_configuration([facade makePanelNativeConfigurationWithDisplayID:display_id]);
}

LumenMacBridgeAudioCaptureConfiguration LumenMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration(
  void
) {
  LumenBridgeObjCFacade *facade = [[LumenBridgeObjCFacade alloc] init];
  return to_audio_bridge_configuration([facade makeDefaultMicrophoneAudioConfiguration]);
}

LumenMacBridgeAudioCaptureConfiguration LumenMacBridgeControllerMakeSystemOutputAudioConfiguration(
  uint32_t display_id
) {
  LumenBridgeObjCFacade *facade = [[LumenBridgeObjCFacade alloc] init];
  return to_audio_bridge_configuration([facade makeSystemOutputAudioConfigurationWithDisplayID:display_id]);
}

bool LumenMacBridgeControllerStartMacDisplayKitCapture(
  LumenMacBridgeController *controller,
  LumenMacBridgeCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
) {
  if (!controller) {
    copy_string_to_buffer(@"LumenMacBridgeControllerStartMacDisplayKitCapture called with a null controller.",
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

void LumenMacBridgeControllerStopMacDisplayKitCapture(
  LumenMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  [controller->facade stopMacDisplayKitCaptureSync];
}

void LumenMacBridgeRequestImmediateCaptureKeyFrame(void) {
  [LumenBridgeObjCFacade requestImmediateCaptureKeyFrameSharedSync];
}

void LumenMacBridgeRestartMacDisplayKitCapture(const char *reason) {
  NSString *restartReason =
    reason != nullptr ?
      [NSString stringWithUTF8String:reason] :
      @"external-encoded-capture-restart";
  if (!restartReason) {
    restartReason = @"external-encoded-capture-restart";
  }
  [LumenBridgeObjCFacade restartMacDisplayKitCaptureSharedSync:restartReason];
}

bool LumenMacBridgeControllerStartMacDisplayKitAudioCapture(
  LumenMacBridgeController *controller,
  LumenMacBridgeAudioCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
) {
  if (!controller) {
    copy_string_to_buffer(@"LumenMacBridgeControllerStartMacDisplayKitAudioCapture called with a null controller.",
                          error_destination,
                          error_capacity);
    return false;
  }

  NSError *error = nil;
  const BOOL started = [controller->facade startMacDisplayKitAudioCaptureSync:to_audio_configuration_box(configuration)
                                                                        error:&error];
  copy_string_to_buffer(error.localizedDescription, error_destination, error_capacity);
  return started == YES;
}

void LumenMacBridgeControllerStopMacDisplayKitAudioCapture(
  LumenMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  [controller->facade stopMacDisplayKitAudioCaptureSync];
}

void LumenMacBridgeControllerStartLumenCoreCaptureAutomation(
  LumenMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  [controller->facade startLumenCoreCaptureAutomationSync];
}

void LumenMacBridgeControllerStopLumenCoreCaptureAutomation(
  LumenMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  [controller->facade stopLumenCoreCaptureAutomationSync];
}

bool LumenMacBridgeControllerIsLumenCoreCaptureAutomationRunning(
  LumenMacBridgeController *controller
) {
  if (!controller) {
    return false;
  }

  return [controller->facade isLumenCoreCaptureAutomationRunningSync] == YES;
}

LumenMacBridgeStatusSnapshot LumenMacBridgeControllerCopyStatusSnapshot(
  LumenMacBridgeController *controller
) {
  LumenMacBridgeStatusSnapshot snapshot {};
  if (!controller) {
    return snapshot;
  }

  LumenBridgeStatusBox *box = [controller->facade copyStatusSnapshotSync];
  copy_string_to_buffer(box.coreVersion, snapshot.core_version, sizeof(snapshot.core_version));
  copy_string_to_buffer(box.runtimeDescription,
                        snapshot.runtime_description,
                        sizeof(snapshot.runtime_description));
  copy_string_to_buffer(box.integrationStatus,
                        snapshot.integration_status,
                        sizeof(snapshot.integration_status));
  snapshot.capture_session_running = box.captureSessionRunning;
  snapshot.audio_capture_session_running = box.audioCaptureSessionRunning;
  snapshot.automatic_capture_orchestration_running = box.automaticCaptureOrchestrationRunning;
  return snapshot;
}

void LumenMacBridgeControllerConfigureCoreForwarding(
  LumenMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
) {
  if (!controller) {
    return;
  }

  [controller->facade configureCoreForwardingSyncWithFrameCapacity:static_cast<NSInteger>(frame_capacity)
                                                     eventCapacity:static_cast<NSInteger>(event_capacity)];
}

LumenCoreEncodedCaptureIngressSnapshot LumenMacBridgeControllerCopyCoreForwardingSnapshot(
  LumenMacBridgeController *controller
) {
  LumenCoreEncodedCaptureIngressSnapshot snapshot {};
  if (!controller) {
    return snapshot;
  }

  LumenBridgeCoreForwardingSnapshotBox *box = [controller->facade copyCoreForwardingSnapshotSync];
  snapshot.frame_count = box.frameCount;
  snapshot.event_count = box.eventCount;
  snapshot.queued_frame_count = box.queuedFrameCount;
  snapshot.queued_event_count = box.queuedEventCount;
  snapshot.dropped_frame_count = box.droppedFrameCount;
  snapshot.dropped_event_count = box.droppedEventCount;
  snapshot.has_last_sample_buffer = box.hasLastSampleBuffer;
  snapshot.has_last_frame = box.lastFrameCodecRawValue >= 0;
  snapshot.last_frame_codec = static_cast<LumenCoreCaptureCodec>(box.lastFrameCodecRawValue);
  snapshot.last_frame_payload_size = static_cast<size_t>(box.lastFramePayloadSize);
  snapshot.last_frame_source_sequence_number = box.lastFrameSourceSequenceNumber;
  snapshot.last_frame_source_display_time = box.lastFrameSourceDisplayTime;
  snapshot.last_frame_is_key_frame = box.lastFrameIsKeyFrame;
  snapshot.last_frame_is_hdr_signaled = box.lastFrameIsHDRSignaled;
  snapshot.has_last_event = box.lastEventKindRawValue >= 0;
  snapshot.last_event_kind = static_cast<LumenCoreCaptureEventKind>(box.lastEventKindRawValue);
  return snapshot;
}

extern "C" bool LumenMacBridgeControllerCopyCaptureDiagnostics(
  LumenMacBridgeController *controller,
  char *diagnostics_destination,
  size_t diagnostics_capacity
) {
  if (controller == nullptr || controller->facade == nil) {
    copy_string_to_buffer(@"n/a", diagnostics_destination, diagnostics_capacity);
    return false;
  }

  NSString *diagnostics = [controller->facade copyCaptureDiagnosticsSync];
  copy_string_to_buffer(diagnostics, diagnostics_destination, diagnostics_capacity);
  return diagnostics.length > 0 && ![diagnostics isEqualToString:@"n/a"];
}

void LumenMacBridgeControllerConfigureAudioForwarding(
  LumenMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
) {
  if (!controller) {
    return;
  }

  [controller->facade configureAudioForwardingSyncWithFrameCapacity:static_cast<NSInteger>(frame_capacity)
                                                      eventCapacity:static_cast<NSInteger>(event_capacity)];
}

LumenMacBridgeAudioForwardingSnapshot LumenMacBridgeControllerCopyAudioForwardingSnapshot(
  LumenMacBridgeController *controller
) {
  LumenMacBridgeAudioForwardingSnapshot snapshot {};
  if (!controller) {
    return snapshot;
  }

  LumenBridgeAudioForwardingSnapshotBox *box = [controller->facade copyAudioForwardingSnapshotSync];
  snapshot.frame_count = box.frameCount;
  snapshot.event_count = box.eventCount;
  snapshot.queued_frame_count = box.queuedFrameCount;
  snapshot.queued_event_count = box.queuedEventCount;
  snapshot.dropped_frame_count = box.droppedFrameCount;
  snapshot.dropped_event_count = box.droppedEventCount;
  snapshot.has_last_frame = box.hasLastFrame;
  snapshot.last_frame_sequence_number = box.lastFrameSequenceNumber;
  snapshot.last_frame_host_time_nanoseconds = box.lastFrameHostTimeNanoseconds;
  snapshot.last_frame_sample_rate = static_cast<int32_t>(box.lastFrameSampleRate);
  snapshot.last_frame_channel_count = static_cast<int32_t>(box.lastFrameChannelCount);
  snapshot.last_frame_frame_count = static_cast<int32_t>(box.lastFrameFrameCount);
  snapshot.last_frame_pcm_byte_count = static_cast<size_t>(box.lastFramePCMByteCount);
  snapshot.has_last_event = box.lastEventKindRawValue >= 0;
  snapshot.last_event_kind = static_cast<LumenCoreCaptureEventKind>(box.lastEventKindRawValue);
  return snapshot;
}

LumenCoreEncodedCaptureFrameRecord LumenMacBridgeControllerPopNextForwardedFrame(
  LumenMacBridgeController *controller,
  CMSampleBufferRef *retained_sample_buffer_out
) {
  LumenCoreEncodedCaptureFrameRecord record {};
  if (retained_sample_buffer_out) {
    *retained_sample_buffer_out = nullptr;
  }
  if (!controller) {
    return record;
  }

  LumenBridgeDrainedFrameBox *box = [controller->facade popNextCoreForwardedFrameSync];
  if (!box) {
    return record;
  }

  record.has_value = true;
  record.codec = static_cast<LumenCoreCaptureCodec>(box.codecRawValue);
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

LumenCoreEncodedCaptureEventRecord LumenMacBridgeControllerPopNextForwardedEvent(
  LumenMacBridgeController *controller,
  char *message_destination,
  size_t message_capacity
) {
  LumenCoreEncodedCaptureEventRecord record {};
  if (!controller) {
    return record;
  }

  LumenBridgeDrainedEventBox *box = [controller->facade popNextCoreForwardedEventSync];
  if (!box) {
    copy_string_to_buffer(nil, message_destination, message_capacity);
    return record;
  }

  record.has_value = true;
  record.kind = static_cast<LumenCoreCaptureEventKind>(box.kindRawValue);
  record.has_stop_status = box.hasStopStatus;
  record.stop_status = box.stopStatus;
  record.has_automatic_restart_count = box.hasAutomaticRestartCount;
  record.automatic_restart_count = box.automaticRestartCount;
  record.has_source_display_time = box.hasSourceDisplayTime;
  record.source_display_time = box.sourceDisplayTime;
  copy_string_to_buffer(box.message, message_destination, message_capacity);
  return record;
}

LumenMacBridgeAudioCaptureFrameRecord LumenMacBridgeControllerPopNextForwardedAudioFrame(
  LumenMacBridgeController *controller,
  void *pcm_destination,
  size_t pcm_capacity,
  size_t *copied_size_out
) {
  LumenMacBridgeAudioCaptureFrameRecord record {};
  if (copied_size_out) {
    *copied_size_out = 0;
  }
  if (!controller) {
    return record;
  }

  LumenBridgeDrainedAudioFrameBox *box = [controller->facade popNextCoreForwardedAudioFrameSync];
  if (!box) {
    return record;
  }

  record = to_audio_frame_record(box);
  if (pcm_destination && pcm_capacity > 0) {
    const size_t copy_size = std::min(pcm_capacity, static_cast<size_t>(box.pcmFloat32LE.length));
    std::memcpy(pcm_destination, box.pcmFloat32LE.bytes, copy_size);
    if (copied_size_out) {
      *copied_size_out = copy_size;
    }
  }
  return record;
}

LumenMacBridgeAudioCaptureEventRecord LumenMacBridgeControllerPopNextForwardedAudioEvent(
  LumenMacBridgeController *controller,
  char *message_destination,
  size_t message_capacity
) {
  LumenMacBridgeAudioCaptureEventRecord record {};
  if (!controller) {
    return record;
  }

  LumenBridgeDrainedAudioEventBox *box = [controller->facade popNextCoreForwardedAudioEventSync];
  if (!box) {
    copy_string_to_buffer(nil, message_destination, message_capacity);
    return record;
  }

  record = to_audio_event_record(box);
  copy_string_to_buffer(box.message, message_destination, message_capacity);
  return record;
}

bool LumenMacBridgeControllerStartCoreForwardingPump(
  LumenMacBridgeController *controller,
  LumenMacBridgeForwardingCallbacks callbacks,
  uint32_t idle_sleep_milliseconds,
  char *error_destination,
  size_t error_capacity
) {
  copy_string_to_buffer(nil, error_destination, error_capacity);

  if (!controller) {
    copy_string_to_buffer(@"LumenMacBridgeControllerStartCoreForwardingPump called with a null controller.",
                          error_destination,
                          error_capacity);
    return false;
  }

  if (!callbacks.encoded_frame_handler && !callbacks.capture_event_handler) {
    if (!callbacks.audio_frame_handler && !callbacks.audio_capture_event_handler) {
      copy_string_to_buffer(@"LumenMacBridgeControllerStartCoreForwardingPump requires at least one callback.",
                          error_destination,
                          error_capacity);
      return false;
    }
  }

  controller->forwarding_pump.reset();
  controller->forwarding_pump = std::make_unique<LumenMacBridgeForwardingPump>(
    controller->facade,
    callbacks,
    idle_sleep_milliseconds
  );
  return true;
}

void LumenMacBridgeControllerStopCoreForwardingPump(
  LumenMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  controller->forwarding_pump.reset();
}
