#import <XCTest/XCTest.h>

#import <atomic>
#import <chrono>
#import <thread>

#import <ApolloCore/ApolloCore.h>
#import <ApolloMacBridge/ApolloMacBridge.h>

@interface ApolloObjCBridgeCompatibilityTests : XCTestCase
@end

@implementation ApolloObjCBridgeCompatibilityTests

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
  XCTAssertEqual(configuration.codec, ApolloCoreCaptureCodecHEVC);
  XCTAssertEqual(configuration.preprocess_strategy, ApolloMacBridgePreprocessStrategyNone);
  XCTAssertEqual(configuration.queue_profile, ApolloMacBridgeQueueProfileQ2);
  XCTAssertFalse(configuration.show_cursor);
  XCTAssertEqual(configuration.target_frame_rate, 120);

  ApolloMacBridgeControllerConfigureCoreForwarding(controller, 2, 3);
  ApolloCoreEncodedCaptureIngressSnapshot forwarding =
    ApolloMacBridgeControllerCopyCoreForwardingSnapshot(controller);
  XCTAssertEqual(forwarding.frame_count, 0ULL);
  XCTAssertEqual(forwarding.event_count, 0ULL);
  XCTAssertEqual(forwarding.queued_frame_count, 0ULL);
  XCTAssertEqual(forwarding.queued_event_count, 0ULL);

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
