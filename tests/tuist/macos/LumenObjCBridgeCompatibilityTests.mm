#import <XCTest/XCTest.h>

#import <atomic>
#import <chrono>
#import <thread>

#import <ApolloCore/ApolloCore.h>
#import <LumenMacBridge/LumenMacBridge.h>

@interface LumenObjCBridgeCompatibilityTests : XCTestCase
@end

@implementation LumenObjCBridgeCompatibilityTests

- (void)testApolloMacBridgeCABIStatusAndConfigurationSmoke {
  ApolloMacBridgeController *controller = ApolloMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, nullptr);

  ApolloMacBridgeStatusSnapshot status = ApolloMacBridgeControllerCopyStatusSnapshot(controller);
  XCTAssertGreaterThan(strlen(status.core_version), 0UL);
  XCTAssertGreaterThan(strlen(status.runtime_description), 0UL);
  XCTAssertGreaterThan(strlen(status.integration_status), 0UL);

  ApolloMacBridgeCaptureConfiguration configuration =
    ApolloMacBridgeControllerMakePanelNativeConfiguration(7);
  XCTAssertEqual(configuration.display_id, 7u);
  XCTAssertTrue(configuration.codec == ApolloCoreCaptureCodecH264 ||
                configuration.codec == ApolloCoreCaptureCodecHEVC ||
                configuration.codec == ApolloCoreCaptureCodecProResProxy);
  XCTAssertEqual(configuration.preprocess_strategy, ApolloMacBridgePreprocessStrategyNone);
  XCTAssertTrue((configuration.queue_profile >= ApolloMacBridgeQueueProfileQ1 &&
                 configuration.queue_profile <= ApolloMacBridgeQueueProfileQ4) ||
                configuration.queue_profile == ApolloMacBridgeQueueProfileAuto);
  XCTAssertFalse(configuration.show_cursor);
  XCTAssertEqual(configuration.target_frame_rate, 120);

  ApolloMacBridgeControllerConfigureCoreForwarding(controller, 2, 3);
  ApolloCoreEncodedCaptureIngressSnapshot forwarding =
    ApolloMacBridgeControllerCopyCoreForwardingSnapshot(controller);
  XCTAssertEqual(forwarding.frame_count, 0ULL);
  XCTAssertEqual(forwarding.event_count, 0ULL);
  XCTAssertEqual(forwarding.queued_frame_count, 0ULL);
  XCTAssertEqual(forwarding.queued_event_count, 0ULL);

  ApolloMacBridgeAudioCaptureConfiguration microphoneConfiguration =
    ApolloMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration();
  XCTAssertEqual(microphoneConfiguration.source_kind, ApolloMacBridgeAudioSourceKindMicrophone);
  XCTAssertEqual(microphoneConfiguration.sample_rate, 48000);
  XCTAssertEqual(microphoneConfiguration.channel_count, 2);
  XCTAssertEqual(microphoneConfiguration.frame_size, 480);

  ApolloMacBridgeAudioCaptureConfiguration systemOutputConfiguration =
    ApolloMacBridgeControllerMakeSystemOutputAudioConfiguration(7);
  XCTAssertEqual(systemOutputConfiguration.source_kind, ApolloMacBridgeAudioSourceKindSystemOutput);
  XCTAssertEqual(systemOutputConfiguration.display_id, 7u);
  XCTAssertEqual(systemOutputConfiguration.sample_rate, 48000);

  ApolloMacBridgeControllerConfigureAudioForwarding(controller, 2, 3);
  ApolloMacBridgeAudioForwardingSnapshot audioForwarding =
    ApolloMacBridgeControllerCopyAudioForwardingSnapshot(controller);
  XCTAssertEqual(audioForwarding.frame_count, 0ULL);
  XCTAssertEqual(audioForwarding.event_count, 0ULL);
  XCTAssertEqual(audioForwarding.queued_frame_count, 0ULL);
  XCTAssertEqual(audioForwarding.queued_event_count, 0ULL);

  ApolloMacBridgeControllerStartApolloCoreCaptureAutomation(controller);
  XCTAssertTrue(ApolloMacBridgeControllerIsApolloCoreCaptureAutomationRunning(controller));
  ApolloMacBridgeControllerStopApolloCoreCaptureAutomation(controller);
  XCTAssertFalse(ApolloMacBridgeControllerIsApolloCoreCaptureAutomationRunning(controller));

  ApolloMacBridgeControllerDestroy(controller);
}

- (void)testApolloMacBridgeCABIEmptyDrainReturnsNoValues {
  ApolloMacBridgeController *controller = ApolloMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, nullptr);

  CMSampleBufferRef drainedSampleBuffer = nullptr;
  ApolloCoreEncodedCaptureFrameRecord frame =
    ApolloMacBridgeControllerPopNextForwardedFrame(controller, &drainedSampleBuffer);
  XCTAssertFalse(frame.has_value);
  XCTAssertEqual(drainedSampleBuffer, nullptr);

  char message[64] = {};
  ApolloCoreEncodedCaptureEventRecord event =
    ApolloMacBridgeControllerPopNextForwardedEvent(controller, message, sizeof(message));
  XCTAssertFalse(event.has_value);
  XCTAssertEqual(strcmp(message, ""), 0);

  uint8_t pcm[256] = {};
  size_t copiedPCMBytes = 0;
  ApolloMacBridgeAudioCaptureFrameRecord audioFrame =
    ApolloMacBridgeControllerPopNextForwardedAudioFrame(controller, pcm, sizeof(pcm), &copiedPCMBytes);
  XCTAssertFalse(audioFrame.has_value);
  XCTAssertEqual(copiedPCMBytes, 0UL);

  ApolloMacBridgeAudioCaptureEventRecord audioEvent =
    ApolloMacBridgeControllerPopNextForwardedAudioEvent(controller, message, sizeof(message));
  XCTAssertFalse(audioEvent.has_value);
  XCTAssertEqual(strcmp(message, ""), 0);

  ApolloMacBridgeControllerDestroy(controller);
}

- (void)testApolloMacBridgeForwardingPumpSmoke {
  ApolloMacBridgeController *controller = ApolloMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, nullptr);

  struct CallbackCounts {
    std::atomic<int> frame_count {0};
    std::atomic<int> event_count {0};
  } callbackCounts;

  ApolloMacBridgeForwardingCallbacks callbacks {};
  callbacks.context = &callbackCounts;
  callbacks.encoded_frame_handler = [](void *context,
                                       ApolloCoreEncodedCaptureFrameRecord,
                                       CMSampleBufferRef) {
    auto *counts = static_cast<CallbackCounts *>(context);
    counts->frame_count.fetch_add(1, std::memory_order_relaxed);
  };
  callbacks.capture_event_handler = [](void *context,
                                       ApolloCoreEncodedCaptureEventRecord,
                                       const char *) {
    auto *counts = static_cast<CallbackCounts *>(context);
    counts->event_count.fetch_add(1, std::memory_order_relaxed);
  };
  callbacks.audio_frame_handler = [](void *context,
                                     ApolloMacBridgeAudioCaptureFrameRecord,
                                     const void *,
                                     size_t) {
    auto *counts = static_cast<CallbackCounts *>(context);
    counts->frame_count.fetch_add(1, std::memory_order_relaxed);
  };
  callbacks.audio_capture_event_handler = [](void *context,
                                             ApolloMacBridgeAudioCaptureEventRecord,
                                             const char *) {
    auto *counts = static_cast<CallbackCounts *>(context);
    counts->event_count.fetch_add(1, std::memory_order_relaxed);
  };

  char error[256] = {};
  XCTAssertTrue(ApolloMacBridgeControllerStartCoreForwardingPump(
    controller,
    callbacks,
    1,
    error,
    sizeof(error)
  ));
  XCTAssertEqual(strcmp(error, ""), 0);

  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  ApolloMacBridgeControllerStopCoreForwardingPump(controller);

  XCTAssertEqual(callbackCounts.frame_count.load(std::memory_order_relaxed), 0);
  XCTAssertEqual(callbackCounts.event_count.load(std::memory_order_relaxed), 0);

  ApolloMacBridgeControllerDestroy(controller);
}

@end
