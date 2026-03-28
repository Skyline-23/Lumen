#import <XCTest/XCTest.h>

#import <atomic>
#import <chrono>
#import <thread>

#import <LumenCore/LumenCore.h>
#import <LumenMacBridge/LumenMacBridge.h>

@interface LumenObjCBridgeCompatibilityTests : XCTestCase
@end

@implementation LumenObjCBridgeCompatibilityTests

- (void)testLumenMacBridgeCABIStatusAndConfigurationSmoke {
  LumenMacBridgeController *controller = LumenMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, nullptr);

  LumenMacBridgeStatusSnapshot status = LumenMacBridgeControllerCopyStatusSnapshot(controller);
  XCTAssertGreaterThan(strlen(status.core_version), 0UL);
  XCTAssertGreaterThan(strlen(status.runtime_description), 0UL);
  XCTAssertGreaterThan(strlen(status.integration_status), 0UL);

  LumenMacBridgeCaptureConfiguration configuration =
    LumenMacBridgeControllerMakePanelNativeConfiguration(7);
  XCTAssertEqual(configuration.display_id, 7u);
  XCTAssertTrue(configuration.codec == LumenCoreCaptureCodecH264 ||
                configuration.codec == LumenCoreCaptureCodecHEVC ||
                configuration.codec == LumenCoreCaptureCodecProResProxy);
  XCTAssertEqual(configuration.preprocess_strategy, LumenMacBridgePreprocessStrategyNone);
  XCTAssertTrue((configuration.queue_profile >= LumenMacBridgeQueueProfileQ1 &&
                 configuration.queue_profile <= LumenMacBridgeQueueProfileQ4) ||
                configuration.queue_profile == LumenMacBridgeQueueProfileAuto);
  XCTAssertFalse(configuration.show_cursor);
  XCTAssertEqual(configuration.target_frame_rate, 120);

  LumenMacBridgeControllerConfigureCoreForwarding(controller, 2, 3);
  LumenCoreEncodedCaptureIngressSnapshot forwarding =
    LumenMacBridgeControllerCopyCoreForwardingSnapshot(controller);
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

  LumenMacBridgeControllerStartLumenCoreCaptureAutomation(controller);
  XCTAssertTrue(LumenMacBridgeControllerIsLumenCoreCaptureAutomationRunning(controller));
  LumenMacBridgeControllerStopLumenCoreCaptureAutomation(controller);
  XCTAssertFalse(LumenMacBridgeControllerIsLumenCoreCaptureAutomationRunning(controller));

  LumenMacBridgeControllerDestroy(controller);
}

- (void)testLumenMacBridgeCABIEmptyDrainReturnsNoValues {
  LumenMacBridgeController *controller = LumenMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, nullptr);

  CMSampleBufferRef drainedSampleBuffer = nullptr;
  LumenCoreEncodedCaptureFrameRecord frame =
    LumenMacBridgeControllerPopNextForwardedFrame(controller, &drainedSampleBuffer);
  XCTAssertFalse(frame.has_value);
  XCTAssertEqual(drainedSampleBuffer, nullptr);

  char message[64] = {};
  LumenCoreEncodedCaptureEventRecord event =
    LumenMacBridgeControllerPopNextForwardedEvent(controller, message, sizeof(message));
  XCTAssertFalse(event.has_value);
  XCTAssertEqual(strcmp(message, ""), 0);

  uint8_t pcm[256] = {};
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

- (void)testLumenMacBridgeForwardingPumpSmoke {
  LumenMacBridgeController *controller = LumenMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, nullptr);

  struct CallbackCounts {
    std::atomic<int> frame_count {0};
    std::atomic<int> event_count {0};
  } callbackCounts;

  LumenMacBridgeForwardingCallbacks callbacks {};
  callbacks.context = &callbackCounts;
  callbacks.encoded_frame_handler = [](void *context,
                                       LumenCoreEncodedCaptureFrameRecord,
                                       CMSampleBufferRef) {
    auto *counts = static_cast<CallbackCounts *>(context);
    counts->frame_count.fetch_add(1, std::memory_order_relaxed);
  };
  callbacks.capture_event_handler = [](void *context,
                                       LumenCoreEncodedCaptureEventRecord,
                                       const char *) {
    auto *counts = static_cast<CallbackCounts *>(context);
    counts->event_count.fetch_add(1, std::memory_order_relaxed);
  };
  callbacks.audio_frame_handler = [](void *context,
                                     LumenMacBridgeAudioCaptureFrameRecord,
                                     const void *,
                                     size_t) {
    auto *counts = static_cast<CallbackCounts *>(context);
    counts->frame_count.fetch_add(1, std::memory_order_relaxed);
  };
  callbacks.audio_capture_event_handler = [](void *context,
                                             LumenMacBridgeAudioCaptureEventRecord,
                                             const char *) {
    auto *counts = static_cast<CallbackCounts *>(context);
    counts->event_count.fetch_add(1, std::memory_order_relaxed);
  };

  char error[256] = {};
  XCTAssertTrue(LumenMacBridgeControllerStartCoreForwardingPump(
    controller,
    callbacks,
    1,
    error,
    sizeof(error)
  ));
  XCTAssertEqual(strcmp(error, ""), 0);

  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  LumenMacBridgeControllerStopCoreForwardingPump(controller);

  XCTAssertEqual(callbackCounts.frame_count.load(std::memory_order_relaxed), 0);
  XCTAssertEqual(callbackCounts.event_count.load(std::memory_order_relaxed), 0);

  LumenMacBridgeControllerDestroy(controller);
}

@end
