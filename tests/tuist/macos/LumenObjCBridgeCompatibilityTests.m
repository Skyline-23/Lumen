#import <XCTest/XCTest.h>

#import <LumenMacBridge/LumenMacBridge.h>

static BOOL LumenDisplayExistedBeforeModeCreation = NO;

@interface LumenVirtualDisplayConstructionOrderProbe : LumenMacVirtualDisplay
@end

@implementation LumenVirtualDisplayConstructionOrderProbe

- (BOOL)createModeWithLogicalWidth:(uint32_t)logicalWidth
                     logicalHeight:(uint32_t)logicalHeight
                       refreshRate:(double)refreshRate
                          transfer:(LumenMacVirtualDisplayTransfer)transfer
                        hdrEnabled:(BOOL)hdrEnabled
                             error:(NSError **)error {
  (void)logicalWidth;
  (void)logicalHeight;
  (void)refreshRate;
  (void)transfer;
  (void)hdrEnabled;
  (void)error;
  LumenDisplayExistedBeforeModeCreation = [self valueForKey:@"display"] != nil;
  return NO;
}

@end

@interface LumenObjCBridgeCompatibilityTests : XCTestCase
@end

@implementation LumenObjCBridgeCompatibilityTests

- (void)testWorkspaceActivationResultHasStableRustCompatibleLayout {
  XCTAssertEqual(sizeof(LumenMacWorkspaceActivationResult), 8UL);
  XCTAssertEqual(offsetof(LumenMacWorkspaceActivationResult, activated), 0UL);
  XCTAssertEqual(offsetof(LumenMacWorkspaceActivationResult, isolation_status), 4UL);
}

- (void)testWorkspaceSessionRequestHasStableRustCompatibleLayout {
  XCTAssertEqual(sizeof(LumenMacWorkspaceSessionRequest), 72UL);
  XCTAssertEqual(offsetof(LumenMacWorkspaceSessionRequest, display_key), 0UL);
  XCTAssertEqual(offsetof(LumenMacWorkspaceSessionRequest, refresh_rate), 32UL);
  XCTAssertEqual(offsetof(LumenMacWorkspaceSessionRequest, sink_gamut), 44UL);
  XCTAssertEqual(
    offsetof(LumenMacWorkspaceSessionRequest, desktop_mirror_source_display_id),
    68UL
  );
}

- (void)testVirtualDisplayExistsBeforeModeCreation {
  if (![LumenMacVirtualDisplay isSupported]) {
    XCTSkip(@"CGVirtualDisplay is unavailable on this runtime");
  }

  LumenMacVirtualDisplayConfiguration *configuration =
    [[LumenMacVirtualDisplayConfiguration alloc] init];
  configuration.name = @"Lumen Construction Order Probe";
  configuration.backingWidth = 1280;
  configuration.backingHeight = 720;
  configuration.logicalWidth = 640;
  configuration.logicalHeight = 360;
  configuration.refreshRate = 60;

  LumenDisplayExistedBeforeModeCreation = NO;
  NSError *error = nil;
  LumenVirtualDisplayConstructionOrderProbe *display =
    [[LumenVirtualDisplayConstructionOrderProbe alloc]
      initWithConfiguration:configuration
                      error:&error];

  XCTAssertNil(display);
  XCTAssertTrue(LumenDisplayExistedBeforeModeCreation);
}

- (void)testLumenMacBridgeCABIStatusAndConfigurationSmoke {
  LumenMacBridgeController *controller = LumenMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, NULL);

  LumenMacBridgeStatusSnapshot status = LumenMacBridgeControllerCopyStatusSnapshot(controller);
  XCTAssertGreaterThan(strlen(status.core_version), 0UL);
  XCTAssertGreaterThan(strlen(status.runtime_description), 0UL);
  XCTAssertGreaterThan(strlen(status.integration_status), 0UL);

  LumenMacBridgeCaptureConfiguration configuration =
    LumenMacBridgeControllerMakePanelNativeConfiguration(7);
  XCTAssertEqual(configuration.display_id, 7u);
  XCTAssertTrue(configuration.codec == LumenMacCaptureCodecH264 ||
                configuration.codec == LumenMacCaptureCodecHEVC);
  XCTAssertEqual(configuration.preprocess_strategy, LumenMacBridgePreprocessStrategyNone);
  XCTAssertTrue((configuration.queue_profile >= LumenMacBridgeQueueProfileQ1 &&
                 configuration.queue_profile <= LumenMacBridgeQueueProfileQ4) ||
                configuration.queue_profile == LumenMacBridgeQueueProfileAuto);
  XCTAssertEqual(configuration.target_frame_rate, 120);

  LumenMacBridgeControllerConfigureVideoForwarding(controller, 2, 3);
  LumenMacEncodedCaptureIngressSnapshot forwarding =
    LumenMacBridgeControllerCopyVideoForwardingSnapshot(controller);
  XCTAssertEqual(forwarding.frame_count, 0ULL);
  XCTAssertEqual(forwarding.event_count, 0ULL);
  XCTAssertEqual(forwarding.queued_frame_count, 0ULL);
  XCTAssertEqual(forwarding.queued_event_count, 0ULL);

  LumenMacBridgeAudioCaptureConfiguration microphoneConfiguration =
    LumenMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration();
  XCTAssertEqual(microphoneConfiguration.source_kind, LumenMacBridgeAudioSourceKindMicrophone);
  XCTAssertEqual(microphoneConfiguration.sample_rate, 48000);
  XCTAssertEqual(microphoneConfiguration.channel_count, 2);
  XCTAssertEqual(microphoneConfiguration.frame_size, 480);

  LumenMacBridgeAudioCaptureConfiguration systemOutputConfiguration =
    LumenMacBridgeControllerMakeSystemOutputAudioConfiguration(7);
  XCTAssertEqual(systemOutputConfiguration.source_kind, LumenMacBridgeAudioSourceKindSystemOutput);
  XCTAssertEqual(systemOutputConfiguration.display_id, 7u);
  XCTAssertEqual(systemOutputConfiguration.sample_rate, 48000);

  LumenMacBridgeControllerConfigureAudioForwarding(controller, 2, 3);
  LumenMacBridgeAudioForwardingSnapshot audioForwarding =
    LumenMacBridgeControllerCopyAudioForwardingSnapshot(controller);
  XCTAssertEqual(audioForwarding.frame_count, 0ULL);
  XCTAssertEqual(audioForwarding.event_count, 0ULL);
  XCTAssertEqual(audioForwarding.queued_frame_count, 0ULL);
  XCTAssertEqual(audioForwarding.queued_event_count, 0ULL);

  LumenMacBridgeControllerDestroy(controller);
}

- (void)testLumenMacBridgeCABIEmptyDrainReturnsNoValues {
  LumenMacBridgeController *controller = LumenMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, NULL);

  CMSampleBufferRef drainedSampleBuffer = NULL;
  LumenMacEncodedCaptureFrameRecord frame =
    LumenMacBridgeControllerPopNextForwardedFrame(controller, &drainedSampleBuffer);
  XCTAssertFalse(frame.has_value);
  XCTAssertEqual(drainedSampleBuffer, NULL);

  char message[64] = {0};
  LumenMacEncodedCaptureEventRecord event =
    LumenMacBridgeControllerPopNextForwardedEvent(controller, message, sizeof(message));
  XCTAssertFalse(event.has_value);
  XCTAssertEqual(strcmp(message, ""), 0);

  uint8_t pcm[256] = {0};
  size_t copiedPCMBytes = 0;
  LumenMacBridgeAudioCaptureFrameRecord audioFrame =
    LumenMacBridgeControllerPopNextForwardedAudioFrame(controller, pcm, sizeof(pcm), &copiedPCMBytes);
  XCTAssertFalse(audioFrame.has_value);
  XCTAssertEqual(copiedPCMBytes, 0UL);

  LumenMacBridgeAudioCaptureEventRecord audioEvent =
    LumenMacBridgeControllerPopNextForwardedAudioEvent(controller, message, sizeof(message));
  XCTAssertFalse(audioEvent.has_value);
  XCTAssertEqual(strcmp(message, ""), 0);

  LumenMacBridgeControllerDestroy(controller);
}

@end
