#import <XCTest/XCTest.h>

#import <ApolloCore/ApolloCore.h>
#import <ApolloMacBridge/ApolloMacBridge.h>

@interface ApolloObjCBridgeCompatibilityTests : XCTestCase
@end

@implementation ApolloObjCBridgeCompatibilityTests

- (void)testApolloMacBridgeCABIStatusAndConfigurationSmoke {
  ApolloMacBridgeController *controller = ApolloMacBridgeControllerCreate();
  XCTAssertNotEqual(controller, nullptr);

  ApolloMacBridgeStatusSnapshot status = ApolloMacBridgeControllerCopyStatusSnapshot(controller);
  XCTAssertEqual(status.preferred_capture_backend, ApolloMacBridgeCaptureBackendMacDisplayKit);
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

@end
