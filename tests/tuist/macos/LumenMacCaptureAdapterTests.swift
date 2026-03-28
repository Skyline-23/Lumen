import LumenMacCaptureAdapter
import ApolloMacBridge
import ApolloCore
import XCTest

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
            configuration.codec == ApolloCoreCaptureCodecH264 ||
            configuration.codec == ApolloCoreCaptureCodecHEVC ||
            configuration.codec == ApolloCoreCaptureCodecProResProxy
        )
        XCTAssertTrue(
            configuration.queue_profile == ApolloMacBridgeQueueProfileQ1 ||
            configuration.queue_profile == ApolloMacBridgeQueueProfileQ2 ||
            configuration.queue_profile == ApolloMacBridgeQueueProfileQ3 ||
            configuration.queue_profile == ApolloMacBridgeQueueProfileQ4 ||
            configuration.queue_profile == ApolloMacBridgeQueueProfileAuto
        )

        let microphoneConfiguration = adapter.makeDefaultMicrophoneAudioConfiguration()
        XCTAssertEqual(microphoneConfiguration.source_kind, ApolloMacBridgeAudioSourceKindMicrophone)
        XCTAssertEqual(microphoneConfiguration.sample_rate, 48_000)
        XCTAssertEqual(microphoneConfiguration.channel_count, 2)
        XCTAssertEqual(microphoneConfiguration.frame_size, 480)

        let systemOutputConfiguration = adapter.makeSystemOutputAudioConfiguration(forDisplayID: 9)
        XCTAssertEqual(systemOutputConfiguration.source_kind, ApolloMacBridgeAudioSourceKindSystemOutput)
        XCTAssertEqual(systemOutputConfiguration.display_id, 9)
    }

    func testAdapterStartsAndStopsForwardingPump() {
        let adapter = LumenMacCaptureAdapter()
        adapter.configureCoreForwarding(withFrameCapacity: 2, eventCapacity: 2)

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

    func testAdapterStartsAndStopsAutomaticCaptureOrchestration() {
        let adapter = LumenMacCaptureAdapter()

        adapter.startAutomaticCoreCaptureOrchestration()
        XCTAssertTrue(adapter.copyStatusSnapshot().automaticCaptureOrchestrationRunning)

        adapter.stopAutomaticCoreCaptureOrchestration()
        XCTAssertFalse(adapter.copyStatusSnapshot().automaticCaptureOrchestrationRunning)
    }
}
