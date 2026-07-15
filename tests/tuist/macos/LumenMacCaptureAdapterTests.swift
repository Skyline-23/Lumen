import LumenMacCaptureAdapter
import LumenMacBridge
import XCTest

@MainActor
final class LumenMacCaptureAdapterTests: XCTestCase {
    func testAdapterReflectsBridgeDefaults() {
        let adapter = LumenMacCaptureAdapter()

        let status = adapter.copyStatusSnapshot()
        XCTAssertFalse(status.captureSessionRunning)
        XCTAssertFalse(status.audioCaptureSessionRunning)
        XCTAssertFalse(status.automaticCaptureOrchestrationRunning)
        XCTAssertFalse(status.forwardingPumpRunning)
        XCTAssertGreaterThan(status.coreVersion.count, 0)
        XCTAssertGreaterThan(status.runtimeDescription.count, 0)
        XCTAssertGreaterThan(status.integrationStatus.count, 0)

        let configuration = adapter.makePanelNativeConfiguration(forDisplayID: 9)
        XCTAssertEqual(configuration.display_id, 9)
        XCTAssertTrue(
            configuration.codec == LumenMacCaptureCodecH264 ||
            configuration.codec == LumenMacCaptureCodecHEVC
        )
        XCTAssertTrue(
            configuration.queue_profile == LumenMacBridgeQueueProfileQ1 ||
            configuration.queue_profile == LumenMacBridgeQueueProfileQ2 ||
            configuration.queue_profile == LumenMacBridgeQueueProfileQ3 ||
            configuration.queue_profile == LumenMacBridgeQueueProfileQ4 ||
            configuration.queue_profile == LumenMacBridgeQueueProfileAuto
        )

        let microphoneConfiguration = adapter.makeDefaultMicrophoneAudioConfiguration()
        XCTAssertEqual(microphoneConfiguration.source_kind, LumenMacBridgeAudioSourceKindMicrophone)
        XCTAssertEqual(microphoneConfiguration.sample_rate, 48_000)
        XCTAssertEqual(microphoneConfiguration.channel_count, 2)
        XCTAssertEqual(microphoneConfiguration.frame_size, 480)

        let systemOutputConfiguration = adapter.makeSystemOutputAudioConfiguration(forDisplayID: 9)
        XCTAssertEqual(systemOutputConfiguration.source_kind, LumenMacBridgeAudioSourceKindSystemOutput)
        XCTAssertEqual(systemOutputConfiguration.display_id, 9)
    }

    func testAdapterStartsAndStopsForwardingPump() {
        let adapter = LumenMacCaptureAdapter()
        adapter.configureVideoForwarding(withFrameCapacity: 2, eventCapacity: 2)

        XCTAssertNoThrow(try adapter.startForwardingPump())

        let runningStatus = adapter.copyStatusSnapshot()
        XCTAssertTrue(runningStatus.forwardingPumpRunning)
        XCTAssertGreaterThanOrEqual(runningStatus.forwardedFrameCallbackCount, 0)
        XCTAssertGreaterThanOrEqual(runningStatus.forwardedEventCallbackCount, 0)
        XCTAssertGreaterThanOrEqual(runningStatus.forwardedAudioFrameCallbackCount, 0)
        XCTAssertGreaterThanOrEqual(runningStatus.forwardedAudioEventCallbackCount, 0)

        adapter.stopForwardingPump()

        let stoppedStatus = adapter.copyStatusSnapshot()
        XCTAssertFalse(stoppedStatus.forwardingPumpRunning)
    }

}
