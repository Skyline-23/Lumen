#import "LumenMacBridge.h"

#import <LumenMacBridge/LumenMacBridge-Swift.h>
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <stdlib.h>

static NSString *const LumenRuntimeEventNotification = @"LumenRuntimeEventNotification";

struct LumenMacBridgeController {
  void *facade;
};

static LumenBridgeObjCFacade *LumenMacBridgeFacade(LumenMacBridgeController *controller) {
  return controller ? (__bridge LumenBridgeObjCFacade *) controller->facade : nil;
}

  LumenMacEncodedCaptureFrameRecord to_frame_record(LumenBridgeDrainedFrameBox *box) {
    LumenMacEncodedCaptureFrameRecord record = {0};
    record.has_value = true;
    record.codec = (LumenMacCaptureCodec) (box.codecRawValue);
    record.payload_size = (size_t) (box.payloadSize);
    record.source_sequence_number = box.sourceSequenceNumber;
    record.source_display_time = box.sourceDisplayTime;
    record.has_output_callback_latency_milliseconds = box.hasOutputCallbackLatencyMilliseconds;
    record.output_callback_latency_milliseconds = box.outputCallbackLatencyMilliseconds;
    record.is_key_frame = box.isKeyFrame;
    record.is_hdr_signaled = box.isHDRSignaled;
    record.is_replay = box.isReplay;
    return record;
  }

  LumenMacEncodedCaptureEventRecord to_event_record(LumenBridgeDrainedEventBox *box) {
    LumenMacEncodedCaptureEventRecord record = {0};
    record.has_value = true;
    record.kind = (LumenMacCaptureEventKind) (box.kindRawValue);
    record.has_stop_status = box.hasStopStatus;
    record.stop_status = box.stopStatus;
    record.has_automatic_restart_count = box.hasAutomaticRestartCount;
    record.automatic_restart_count = box.automaticRestartCount;
    record.has_source_display_time = box.hasSourceDisplayTime;
    record.source_display_time = box.sourceDisplayTime;
    return record;
  }

  LumenMacBridgeAudioCaptureFrameRecord to_audio_frame_record(LumenBridgeDrainedAudioFrameBox *box) {
    LumenMacBridgeAudioCaptureFrameRecord record = {0};
    record.has_value = true;
    record.sequence_number = box.sequenceNumber;
    record.host_time_nanoseconds = box.hostTimeNanoseconds;
    record.sample_rate = (int32_t) (box.sampleRate);
    record.channel_count = (int32_t) (box.channelCount);
    record.frame_count = (int32_t) (box.frameCount);
    record.pcm_byte_count = (size_t) (box.pcmFloat32LE.length);
    return record;
  }

  LumenMacBridgeAudioCaptureEventRecord to_audio_event_record(LumenBridgeDrainedAudioEventBox *box) {
    LumenMacBridgeAudioCaptureEventRecord record = {0};
    record.has_value = true;
    record.kind = (LumenMacCaptureEventKind) (box.kindRawValue);
    record.has_stop_status = box.hasStopStatus;
    record.stop_status = box.stopStatus;
    record.has_automatic_restart_count = box.hasAutomaticRestartCount;
    record.automatic_restart_count = box.automaticRestartCount;
    record.has_source_sequence_number = box.hasSourceSequenceNumber;
    record.source_sequence_number = box.sourceSequenceNumber;
    return record;
  }

  void copy_string_to_buffer(NSString *string, char *destination, size_t capacity) {
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

    strncpy(destination, utf8, capacity - 1);
    destination[capacity - 1] = '\0';
  }

  LumenMacBridgeCaptureConfiguration to_bridge_configuration(
    LumenBridgeConfigurationBox *configuration
  ) {
    LumenMacBridgeCaptureConfiguration result = {0};
    result.display_id = configuration.displayID;
    result.codec = (LumenMacCaptureCodec) (configuration.codecRawValue);
    result.video_profile = (LumenMacCaptureVideoProfile) (configuration.videoProfileRawValue);
    result.chroma_subsampling =
      (LumenMacCaptureChromaSubsampling) (configuration.chromaSubsamplingRawValue);
    result.bit_depth = (uint8_t) (configuration.bitDepth);
    result.dynamic_range = (LumenMacCaptureDynamicRange) (configuration.dynamicRangeRawValue);
    result.color_range = (LumenMacCaptureColorRange) (configuration.colorRangeRawValue);
    result.preprocess_strategy =
      (LumenMacBridgePreprocessStrategy) (configuration.preprocessStrategyRawValue);
    result.queue_profile = (LumenMacBridgeQueueProfile) (configuration.queueProfileRawValue);
    result.target_frame_rate = (int32_t) (configuration.targetFrameRate);
    result.target_video_bitrate_kbps = (int32_t) (configuration.targetVideoBitRateKbps);
    result.requested_width = (int32_t) (configuration.requestedWidth);
    result.requested_height = (int32_t) (configuration.requestedHeight);
    result.sink_request.mode.hidpi = configuration.sinkRequest.mode.hidpi;
    result.sink_request.mode.scale_explicit = configuration.sinkRequest.mode.scaleExplicit;
    result.sink_request.mode.mode_is_logical = configuration.sinkRequest.mode.modeIsLogical;
    result.sink_request.mode.scale_percent = (int32_t) (configuration.sinkRequest.mode.scalePercent);
    result.sink_request.capability.gamut = (int32_t) (configuration.sinkRequest.capability.gamutRawValue);
    result.sink_request.capability.transfer = (int32_t) (configuration.sinkRequest.capability.transferRawValue);
    result.sink_request.capability.current_edr_headroom = configuration.sinkRequest.capability.currentEDRHeadroom;
    result.sink_request.capability.potential_edr_headroom = configuration.sinkRequest.capability.potentialEDRHeadroom;
    result.sink_request.capability.current_peak_luminance_nits = (int32_t) (configuration.sinkRequest.capability.currentPeakLuminanceNits);
    result.sink_request.capability.potential_peak_luminance_nits = (int32_t) (configuration.sinkRequest.capability.potentialPeakLuminanceNits);
    result.sink_request.capability.supports_frame_gated_hdr = configuration.sinkRequest.capability.supportsFrameGatedHDR;
    result.sink_request.capability.supports_hdr_tile_overlay = configuration.sinkRequest.capability.supportsHDRTileOverlay;
    result.sink_request.capability.supports_per_frame_hdr_metadata = configuration.sinkRequest.capability.supportsPerFrameHDRMetadata;
    result.sink_request.dynamic_range_transport =
      (LumenMacDynamicRangeTransport) (configuration.sinkRequest.dynamicRangeTransportRawValue);
    result.effective_display_state.gamut = (int32_t) (configuration.effectiveDisplayState.gamutRawValue);
    result.effective_display_state.transfer = (int32_t) (configuration.effectiveDisplayState.transferRawValue);
    result.effective_display_state.has_hdr_static_metadata = configuration.effectiveDisplayState.hdrStaticMetadata != nil;
    if (configuration.effectiveDisplayState.hdrStaticMetadata) {
      result.effective_display_state.hdr_static_metadata.red_primary_x = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.redPrimaryX);
      result.effective_display_state.hdr_static_metadata.red_primary_y = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.redPrimaryY);
      result.effective_display_state.hdr_static_metadata.green_primary_x = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.greenPrimaryX);
      result.effective_display_state.hdr_static_metadata.green_primary_y = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.greenPrimaryY);
      result.effective_display_state.hdr_static_metadata.blue_primary_x = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.bluePrimaryX);
      result.effective_display_state.hdr_static_metadata.blue_primary_y = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.bluePrimaryY);
      result.effective_display_state.hdr_static_metadata.white_point_x = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.whitePointX);
      result.effective_display_state.hdr_static_metadata.white_point_y = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.whitePointY);
      result.effective_display_state.hdr_static_metadata.max_display_luminance = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.maxDisplayLuminance);
      result.effective_display_state.hdr_static_metadata.min_display_luminance = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.minDisplayLuminance);
      result.effective_display_state.hdr_static_metadata.max_content_light_level = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.maxContentLightLevel);
      result.effective_display_state.hdr_static_metadata.max_frame_average_light_level = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.maxFrameAverageLightLevel);
      result.effective_display_state.hdr_static_metadata.max_full_frame_luminance = (int32_t) (configuration.effectiveDisplayState.hdrStaticMetadata.maxFullFrameLuminance);
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
      scalePercent:(NSInteger) (configuration.sink_request.mode.scale_percent)];
    LumenBridgeSinkCapabilityBox *sinkCapability = [[LumenBridgeSinkCapabilityBox alloc]
      initWithGamutRawValue:(NSInteger) (configuration.sink_request.capability.gamut)
      transferRawValue:(NSInteger) (configuration.sink_request.capability.transfer)
      currentEDRHeadroom:configuration.sink_request.capability.current_edr_headroom
      potentialEDRHeadroom:configuration.sink_request.capability.potential_edr_headroom
      currentPeakLuminanceNits:(NSInteger) (configuration.sink_request.capability.current_peak_luminance_nits)
      potentialPeakLuminanceNits:(NSInteger) (configuration.sink_request.capability.potential_peak_luminance_nits)
      supportsFrameGatedHDR:configuration.sink_request.capability.supports_frame_gated_hdr
      supportsHDRTileOverlay:configuration.sink_request.capability.supports_hdr_tile_overlay
      supportsPerFrameHDRMetadata:configuration.sink_request.capability.supports_per_frame_hdr_metadata];
    LumenBridgeSinkRequestBox *sinkRequest = [[LumenBridgeSinkRequestBox alloc]
      initWithMode:sinkMode
      capability:sinkCapability
      dynamicRangeTransportRawValue:(NSInteger) (configuration.sink_request.dynamic_range_transport)];
    LumenBridgeHDRStaticMetadataBox *hdrStaticMetadata = nil;
    if (configuration.effective_display_state.has_hdr_static_metadata) {
      hdrStaticMetadata = [[LumenBridgeHDRStaticMetadataBox alloc]
        initWithRedPrimaryX:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.red_primary_x)
        redPrimaryY:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.red_primary_y)
        greenPrimaryX:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.green_primary_x)
        greenPrimaryY:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.green_primary_y)
        bluePrimaryX:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.blue_primary_x)
        bluePrimaryY:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.blue_primary_y)
        whitePointX:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.white_point_x)
        whitePointY:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.white_point_y)
        maxDisplayLuminance:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.max_display_luminance)
        minDisplayLuminance:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.min_display_luminance)
        maxContentLightLevel:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.max_content_light_level)
        maxFrameAverageLightLevel:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.max_frame_average_light_level)
        maxFullFrameLuminance:(NSInteger) (configuration.effective_display_state.hdr_static_metadata.max_full_frame_luminance)];
    }
    LumenBridgeEffectiveDisplayStateBox *effectiveDisplayState = [[LumenBridgeEffectiveDisplayStateBox alloc]
      initWithGamutRawValue:(NSInteger) (configuration.effective_display_state.gamut)
      transferRawValue:(NSInteger) (configuration.effective_display_state.transfer)
      hdrStaticMetadata:hdrStaticMetadata];
    return [[LumenBridgeConfigurationBox alloc]
      initWithDisplayID:configuration.display_id
           codecRawValue:(NSInteger) (configuration.codec)
    videoProfileRawValue:(NSInteger) (configuration.video_profile)
chromaSubsamplingRawValue:(NSInteger) (configuration.chroma_subsampling)
                bitDepth:(NSInteger) (configuration.bit_depth)
    dynamicRangeRawValue:(NSInteger) (configuration.dynamic_range)
      colorRangeRawValue:(NSInteger) (configuration.color_range)
 preprocessStrategyRawValue:(NSInteger) (configuration.preprocess_strategy)
     queueProfileRawValue:(NSInteger) (configuration.queue_profile)
          targetFrameRate:(NSInteger) (configuration.target_frame_rate)
     targetVideoBitRateKbps:(NSInteger) (configuration.target_video_bitrate_kbps)
           requestedWidth:(NSInteger) (configuration.requested_width)
          requestedHeight:(NSInteger) (configuration.requested_height)
              sinkRequest:sinkRequest
      effectiveDisplayState:effectiveDisplayState];
  }

  LumenMacBridgeAudioCaptureConfiguration to_audio_bridge_configuration(
    LumenBridgeAudioConfigurationBox *configuration
  ) {
    LumenMacBridgeAudioCaptureConfiguration result = {0};
    result.source_kind = (LumenMacBridgeAudioSourceKind) (configuration.sourceKindRawValue);
    result.display_id = configuration.displayID;
    result.excludes_current_process_audio = configuration.excludesCurrentProcessAudio;
    result.sample_rate = (int32_t) (configuration.sampleRate);
    result.channel_count = (int32_t) (configuration.channelCount);
    result.frame_size = (int32_t) (configuration.frameSize);
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
      initWithSourceKindRawValue:(NSInteger) (configuration.source_kind)
                       displayID:configuration.display_id
      excludesCurrentProcessAudio:configuration.excludes_current_process_audio
                         inputID:inputID
                      sampleRate:(NSInteger) (configuration.sample_rate)
                    channelCount:(NSInteger) (configuration.channel_count)
                       frameSize:(NSInteger) (configuration.frame_size)];
  }


LumenMacBridgeController *LumenMacBridgeControllerCreate(void) {
  LumenMacBridgeController *controller = calloc(1, sizeof(*controller));
  if (!controller) {
    return NULL;
  }
  controller->facade = (void *) CFBridgingRetain([[LumenBridgeObjCFacade alloc] init]);
  return controller;
}

void LumenMacBridgeControllerDestroy(LumenMacBridgeController *controller) {
  if (!controller) {
    return;
  }
  CFBridgingRelease(controller->facade);
  free(controller);
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

bool LumenMacBridgeControllerStartCapture(
  LumenMacBridgeController *controller,
  LumenMacBridgeCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
) {
  if (!controller) {
    copy_string_to_buffer(@"LumenMacBridgeControllerStartCapture called with a null controller.",
                          error_destination,
                          error_capacity);
    return false;
  }

  NSError *error = nil;
  const BOOL started = [LumenMacBridgeFacade(controller) startCaptureSync:to_configuration_box(configuration)
                                                                   error:&error];
  copy_string_to_buffer(error.localizedDescription, error_destination, error_capacity);
  return started == YES;
}

LumenMacBridgeCapturePairStartStatus LumenMacBridgeControllerStartCapturePair(
  LumenMacBridgeController *controller,
  LumenMacBridgeCaptureConfiguration video_configuration,
  LumenMacBridgeAudioCaptureConfiguration audio_configuration,
  char *error_destination,
  size_t error_capacity
) {
  if (!controller) {
    copy_string_to_buffer(@"LumenMacBridgeControllerStartCapturePair called with a null controller.",
                          error_destination,
                          error_capacity);
    return LumenMacBridgeCapturePairStartStatusUnknownFailed;
  }

  NSError *error = nil;
  const NSInteger status = [LumenMacBridgeFacade(controller)
    startCapturePairSync:to_configuration_box(video_configuration)
    audioConfiguration:to_audio_configuration_box(audio_configuration)
    error:&error];
  copy_string_to_buffer(error.localizedDescription, error_destination, error_capacity);
  return (LumenMacBridgeCapturePairStartStatus) status;
}

void LumenMacBridgeControllerStopCapture(
  LumenMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  [LumenMacBridgeFacade(controller) stopCaptureSync];
}

void LumenMacBridgeRequestImmediateCaptureKeyFrame(void) {
  [LumenBridgeObjCFacade requestImmediateCaptureKeyFrameSharedSync];
}

void LumenMacBridgeRestartCapture(const char *reason) {
  NSString *restartReason =
    reason != NULL ?
      [NSString stringWithUTF8String:reason] :
      @"external-encoded-capture-restart";
  if (!restartReason) {
    restartReason = @"external-encoded-capture-restart";
  }
  [LumenBridgeObjCFacade restartCaptureSharedSync:restartReason];
}

bool LumenMacBridgeControllerStartAudioCapture(
  LumenMacBridgeController *controller,
  LumenMacBridgeAudioCaptureConfiguration configuration,
  char *error_destination,
  size_t error_capacity
) {
  if (!controller) {
    copy_string_to_buffer(@"LumenMacBridgeControllerStartAudioCapture called with a null controller.",
                          error_destination,
                          error_capacity);
    return false;
  }

  NSError *error = nil;
  const BOOL started = [LumenMacBridgeFacade(controller) startAudioCaptureSync:to_audio_configuration_box(configuration)
                                                                        error:&error];
  copy_string_to_buffer(error.localizedDescription, error_destination, error_capacity);
  return started == YES;
}

void LumenMacBridgeControllerStopAudioCapture(
  LumenMacBridgeController *controller
) {
  if (!controller) {
    return;
  }

  [LumenMacBridgeFacade(controller) stopAudioCaptureSync];
}

LumenMacBridgeStatusSnapshot LumenMacBridgeControllerCopyStatusSnapshot(
  LumenMacBridgeController *controller
) {
  LumenMacBridgeStatusSnapshot snapshot = {0};
  if (!controller) {
    return snapshot;
  }

  LumenBridgeStatusBox *box = [LumenMacBridgeFacade(controller) copyStatusSnapshotSync];
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

void LumenMacBridgeControllerConfigureVideoForwarding(
  LumenMacBridgeController *controller,
  size_t frame_capacity,
  size_t event_capacity
) {
  if (!controller) {
    return;
  }

  [LumenMacBridgeFacade(controller) configureVideoForwardingSyncWithFrameCapacity:(NSInteger) (frame_capacity)
                                                     eventCapacity:(NSInteger) (event_capacity)];
}

LumenMacEncodedCaptureIngressSnapshot LumenMacBridgeControllerCopyVideoForwardingSnapshot(
  LumenMacBridgeController *controller
) {
  LumenMacEncodedCaptureIngressSnapshot snapshot = {0};
  if (!controller) {
    return snapshot;
  }

  LumenBridgeVideoForwardingSnapshotBox *box = [LumenMacBridgeFacade(controller) copyVideoForwardingSnapshotSync];
  snapshot.frame_count = box.frameCount;
  snapshot.event_count = box.eventCount;
  snapshot.queued_frame_count = box.queuedFrameCount;
  snapshot.queued_event_count = box.queuedEventCount;
  snapshot.dropped_frame_count = box.droppedFrameCount;
  snapshot.dropped_event_count = box.droppedEventCount;
  snapshot.has_last_sample_buffer = box.hasLastSampleBuffer;
  snapshot.has_last_frame = box.lastFrameCodecRawValue >= 0;
  snapshot.last_frame_codec = (LumenMacCaptureCodec) (box.lastFrameCodecRawValue);
  snapshot.last_frame_payload_size = (size_t) (box.lastFramePayloadSize);
  snapshot.last_frame_source_sequence_number = box.lastFrameSourceSequenceNumber;
  snapshot.last_frame_source_display_time = box.lastFrameSourceDisplayTime;
  snapshot.last_frame_is_key_frame = box.lastFrameIsKeyFrame;
  snapshot.last_frame_is_hdr_signaled = box.lastFrameIsHDRSignaled;
  snapshot.has_last_event = box.lastEventKindRawValue >= 0;
  snapshot.last_event_kind = (LumenMacCaptureEventKind) (box.lastEventKindRawValue);
  return snapshot;
}

bool LumenMacBridgeControllerCopyCaptureDiagnostics(
  LumenMacBridgeController *controller,
  char *diagnostics_destination,
  size_t diagnostics_capacity
) {
  if (controller == NULL || LumenMacBridgeFacade(controller) == nil) {
    copy_string_to_buffer(@"n/a", diagnostics_destination, diagnostics_capacity);
    return false;
  }

  NSString *diagnostics = [LumenMacBridgeFacade(controller) copyCaptureDiagnosticsSync];
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

  [LumenMacBridgeFacade(controller) configureAudioForwardingSyncWithFrameCapacity:(NSInteger) (frame_capacity)
                                                      eventCapacity:(NSInteger) (event_capacity)];
}

LumenMacBridgeAudioForwardingSnapshot LumenMacBridgeControllerCopyAudioForwardingSnapshot(
  LumenMacBridgeController *controller
) {
  LumenMacBridgeAudioForwardingSnapshot snapshot = {0};
  if (!controller) {
    return snapshot;
  }

  LumenBridgeAudioForwardingSnapshotBox *box = [LumenMacBridgeFacade(controller) copyAudioForwardingSnapshotSync];
  snapshot.frame_count = box.frameCount;
  snapshot.event_count = box.eventCount;
  snapshot.queued_frame_count = box.queuedFrameCount;
  snapshot.queued_event_count = box.queuedEventCount;
  snapshot.dropped_frame_count = box.droppedFrameCount;
  snapshot.dropped_event_count = box.droppedEventCount;
  snapshot.has_last_frame = box.hasLastFrame;
  snapshot.last_frame_sequence_number = box.lastFrameSequenceNumber;
  snapshot.last_frame_host_time_nanoseconds = box.lastFrameHostTimeNanoseconds;
  snapshot.last_frame_sample_rate = (int32_t) (box.lastFrameSampleRate);
  snapshot.last_frame_channel_count = (int32_t) (box.lastFrameChannelCount);
  snapshot.last_frame_frame_count = (int32_t) (box.lastFrameFrameCount);
  snapshot.last_frame_pcm_byte_count = (size_t) (box.lastFramePCMByteCount);
  snapshot.has_last_event = box.lastEventKindRawValue >= 0;
  snapshot.last_event_kind = (LumenMacCaptureEventKind) (box.lastEventKindRawValue);
  return snapshot;
}

LumenMacEncodedCaptureFrameRecord LumenMacBridgeControllerPopNextForwardedFrame(
  LumenMacBridgeController *controller,
  CMSampleBufferRef *retained_sample_buffer_out
) {
  LumenMacEncodedCaptureFrameRecord record = {0};
  if (retained_sample_buffer_out) {
    *retained_sample_buffer_out = NULL;
  }
  if (!controller) {
    return record;
  }

  LumenBridgeDrainedFrameBox *box = [LumenMacBridgeFacade(controller) popNextVideoForwardedFrameSync];
  if (!box) {
    return record;
  }

  record.has_value = true;
  record.codec = (LumenMacCaptureCodec) (box.codecRawValue);
  record.payload_size = (size_t) (box.payloadSize);
  record.source_sequence_number = box.sourceSequenceNumber;
  record.source_display_time = box.sourceDisplayTime;
  record.has_output_callback_latency_milliseconds = box.hasOutputCallbackLatencyMilliseconds;
  record.output_callback_latency_milliseconds = box.outputCallbackLatencyMilliseconds;
  record.is_key_frame = box.isKeyFrame;
  record.is_hdr_signaled = box.isHDRSignaled;
  record.is_replay = box.isReplay;

  if (retained_sample_buffer_out) {
    *retained_sample_buffer_out =
      (CMSampleBufferRef) CFRetain(box.sampleBuffer);
  }

  return record;
}

LumenMacEncodedCaptureEventRecord LumenMacBridgeControllerPopNextForwardedEvent(
  LumenMacBridgeController *controller,
  char *message_destination,
  size_t message_capacity
) {
  LumenMacEncodedCaptureEventRecord record = {0};
  if (!controller) {
    return record;
  }

  LumenBridgeDrainedEventBox *box = [LumenMacBridgeFacade(controller) popNextVideoForwardedEventSync];
  if (!box) {
    copy_string_to_buffer(nil, message_destination, message_capacity);
    return record;
  }

  record.has_value = true;
  record.kind = (LumenMacCaptureEventKind) (box.kindRawValue);
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
  LumenMacBridgeAudioCaptureFrameRecord record = {0};
  if (copied_size_out) {
    *copied_size_out = 0;
  }
  if (!controller) {
    return record;
  }

  LumenBridgeDrainedAudioFrameBox *box = [LumenMacBridgeFacade(controller) popNextVideoForwardedAudioFrameSync];
  if (!box) {
    return record;
  }

  record = to_audio_frame_record(box);
  if (pcm_destination && pcm_capacity > 0) {
    const size_t copy_size = MIN(pcm_capacity, (size_t) (box.pcmFloat32LE.length));
    memcpy(pcm_destination, box.pcmFloat32LE.bytes, copy_size);
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
  LumenMacBridgeAudioCaptureEventRecord record = {0};
  if (!controller) {
    return record;
  }

  LumenBridgeDrainedAudioEventBox *box = [LumenMacBridgeFacade(controller) popNextVideoForwardedAudioEventSync];
  if (!box) {
    copy_string_to_buffer(nil, message_destination, message_capacity);
    return record;
  }

  record = to_audio_event_record(box);
  copy_string_to_buffer(box.message, message_destination, message_capacity);
  return record;
}

uint32_t LumenMacWorkspacePrepareSession(
  LumenMacWorkspaceSessionRequest request,
  char *error_destination,
  size_t error_capacity
) {
  LumenMacWorkspaceSessionRequestBox *box = [[LumenMacWorkspaceSessionRequestBox alloc] init];
  box.displayKey = request.display_key ? [NSString stringWithUTF8String:request.display_key] : @"";
  box.displayName = request.display_name ? [NSString stringWithUTF8String:request.display_name] : @"Lumen Display";
  box.width = request.width;
  box.height = request.height;
  box.scalePercent = request.scale_percent;
  box.dimensionsAreLogical = request.dimensions_are_logical;
  box.refreshRate = request.refresh_rate;
  box.hdrEnabled = request.hdr_enabled;
  box.clientSinkGamutRawValue = request.sink_gamut;
  box.clientSinkTransferRawValue = request.sink_transfer;
  box.currentEDRHeadroom = request.current_edr_headroom;
  box.potentialEDRHeadroom = request.potential_edr_headroom;
  box.currentPeakLuminanceNits = request.current_peak_luminance_nits;
  box.potentialPeakLuminanceNits = request.potential_peak_luminance_nits;
  NSError *error = nil;
  uint32_t displayID = [LumenMacWorkspaceSessionFacade.shared prepareSessionSync:box error:&error];
  copy_string_to_buffer(error.localizedDescription, error_destination, error_capacity);
  return displayID;
}

LumenMacWorkspaceActivationResult LumenMacWorkspaceActivateSession(
  const char *display_key,
  char *status_destination,
  size_t status_capacity
) {
  NSString *key = display_key ? [NSString stringWithUTF8String:display_key] : @"";
  NSError *error = nil;
  LumenMacWorkspaceActivationOutcomeBox *outcome = [LumenMacWorkspaceSessionFacade.shared
    activateSessionSyncWithDisplayKey:key
    error:&error];
  NSString *status = outcome ? outcome.warningMessage : error.localizedDescription;
  copy_string_to_buffer(status, status_destination, status_capacity);
  return (LumenMacWorkspaceActivationResult) {
    .activated = outcome != nil,
    .isolation_status = outcome ? outcome.isolationStatusRawValue : 0,
  };
}

bool LumenMacWorkspaceStopSession(
  const char *display_key,
  char *error_destination,
  size_t error_capacity
) {
  NSString *key = display_key ? [NSString stringWithUTF8String:display_key] : @"";
  NSError *error = nil;
  BOOL stopped = [LumenMacWorkspaceSessionFacade.shared
    stopSessionSyncWithDisplayKey:key
    error:&error];
  copy_string_to_buffer(error.localizedDescription, error_destination, error_capacity);
  return stopped == YES;
}

void LumenMacBridgePublishRuntimeEvent(
  uint32_t disposition,
  uint32_t severity,
  uint32_t code,
  const char *message
) {
  NSString *body = message ? [NSString stringWithUTF8String:message] : @"";
  NSDictionary *userInfo = @{
    @"identifier": [NSString stringWithFormat:@"runtime-event-%u", code],
    @"disposition": @(disposition),
    @"severity": @(severity),
    @"code": @(code),
    @"body": body ?: @"",
    @"launchPath": @"/diagnostics",
  };
  [[NSDistributedNotificationCenter defaultCenter]
    postNotificationName:LumenRuntimeEventNotification
    object:nil
    userInfo:userInfo
    deliverImmediately:YES];
}
