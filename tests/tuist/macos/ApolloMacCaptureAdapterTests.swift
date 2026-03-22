import ApolloMacCaptureAdapter
import XCTest

final class ApolloMacCaptureAdapterTests: XCTestCase {
    func testAdapterReflectsBridgeDefaults() {
        let adapter = ApolloMacCaptureAdapter()

        let status = adapter.copyStatusSnapshot()
        XCTAssertFalse(status.captureSessionRunning)
        XCTAssertFalse(status.audioCaptureSessionRunning)
        XCTAssertFalse(status.forwardingPumpRunning)
        XCTAssertGreaterThan(status.coreVersion.count, 0)
        XCTAssertGreaterThan(status.runtimeDescription.count, 0)
        XCTAssertGreaterThan(status.integrationStatus.count, 0)

        let configuration = adapter.makePanelNativeConfiguration(forDisplayID: 9)
        XCTAssertEqual(configuration.display_id, 9)
        XCTAssertEqual(configuration.codec, ApolloCoreCaptureCodecHEVC)
        XCTAssertEqual(configuration.queue_profile.rawValue, 1)

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
        let adapter = ApolloMacCaptureAdapter()
        adapter.configureCoreForwarding(withFrameCapacity: 2, eventCapacity: 2)

        XCTAssertNoThrow(try adapter.startForwardingPump())

        let runningStatus = adapter.copyStatusSnapshot()
        XCTAssertTrue(runningStatus.forwardingPumpRunning)
        XCTAssertEqual(runningStatus.forwardedFrameCallbackCount, 0)
        XCTAssertEqual(runningStatus.forwardedEventCallbackCount, 0)
        XCTAssertEqual(runningStatus.forwardedAudioFrameCallbackCount, 0)
        XCTAssertEqual(runningStatus.forwardedAudioEventCallbackCount, 0)

        adapter.stopForwardingPump()

        let stoppedStatus = adapter.copyStatusSnapshot()
        XCTAssertFalse(stoppedStatus.forwardingPumpRunning)
    }
}
