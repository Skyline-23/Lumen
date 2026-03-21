@testable import ApolloMacBridge
import ApolloCore
import XCTest

final class ApolloTuistBootstrapTests: XCTestCase {
    func testBridgeDefaultsToMacDisplayKitBackend() async {
        let status = await ApolloBridgeRuntime.shared.statusSnapshot()

        XCTAssertEqual(status.preferredCaptureBackend, .macDisplayKit)
        XCTAssertEqual(status.coreVersion, "ApolloCore bootstrap")
        XCTAssertFalse(status.integrationStatus.isEmpty)
    }

    func testBridgeBuildsPanelNativeMacDisplayKitConfiguration() async {
        let configuration = await ApolloBridgeRuntime.shared.preferredMacDisplayKitCaptureConfiguration(
            displayID: 7
        )

        XCTAssertEqual(configuration.displayID, 7)
        XCTAssertEqual(configuration.codec, .hevc)
        XCTAssertEqual(configuration.preprocessStrategy, .none)
        XCTAssertEqual(configuration.queueProfile, .q2)
        XCTAssertEqual(configuration.targetFrameRate, 120)
        XCTAssertFalse(configuration.showCursor)
    }

    func testApolloCoreEncodedCaptureConsumerStoresPayloadMetadata() {
        guard let consumer = ApolloCoreEncodedCaptureConsumerCreate() else {
            return XCTFail("ApolloCoreEncodedCaptureConsumerCreate returned nil")
        }
        defer {
            ApolloCoreEncodedCaptureConsumerDestroy(consumer)
        }

        let payload = Data([0x01, 0x02, 0x03, 0x04])
        payload.withUnsafeBytes { rawBuffer in
            ApolloCoreEncodedCaptureConsumerConsumeFrame(
                consumer,
                ApolloCoreCaptureCodecHEVC,
                41,
                42,
                true,
                1.25,
                true,
                false,
                rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                rawBuffer.count
            )
        }
        ApolloCoreEncodedCaptureConsumerConsumeEvent(
            consumer,
            ApolloCoreCaptureEventKindRestarted,
            "restart",
            false,
            0,
            true,
            2,
            false,
            0
        )

        let snapshot = ApolloCoreEncodedCaptureConsumerCopySnapshot(consumer)
        XCTAssertEqual(snapshot.frame_count, 1)
        XCTAssertEqual(snapshot.event_count, 1)
        XCTAssertTrue(snapshot.has_last_frame)
        XCTAssertEqual(snapshot.last_frame_codec, ApolloCoreCaptureCodecHEVC)
        XCTAssertEqual(snapshot.last_frame_payload_size, payload.count)
        XCTAssertEqual(snapshot.last_frame_source_sequence_number, 41)
        XCTAssertEqual(snapshot.last_frame_source_display_time, 42)
        XCTAssertTrue(snapshot.last_frame_is_key_frame)
        XCTAssertFalse(snapshot.last_frame_is_hdr_signaled)
        XCTAssertTrue(snapshot.has_last_event)
        XCTAssertEqual(snapshot.last_event_kind, ApolloCoreCaptureEventKindRestarted)
        XCTAssertTrue(snapshot.last_event_has_automatic_restart_count)
        XCTAssertEqual(snapshot.last_event_automatic_restart_count, 2)

        var copiedPayload = Data(count: payload.count)
        let copiedCount = copiedPayload.withUnsafeMutableBytes { rawBuffer in
            ApolloCoreEncodedCaptureConsumerCopyLastFramePayload(
                consumer,
                rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                rawBuffer.count
            )
        }
        XCTAssertEqual(copiedCount, payload.count)
        XCTAssertEqual(copiedPayload, payload)
    }

    func testBridgeForwardsSyntheticPayloadIntoApolloCoreConsumer() async {
        let runtime = ApolloBridgeRuntime()
        await runtime.debugResetCoreForwarding()
        await runtime.debugForwardSyntheticFrame(
            payload: Data([0xAA, 0xBB, 0xCC]),
            codec: .proResProxy,
            sourceSequenceNumber: 7,
            sourceDisplayTime: 9,
            outputCallbackLatencyMilliseconds: 2.75,
            isKeyFrame: false,
            isHDRSignaled: true
        )
        await runtime.debugForwardSyntheticEvent(
            kind: .droppedFrame,
            message: "synthetic-drop",
            sourceDisplayTime: 9
        )

        let snapshot = await runtime.coreForwardingSnapshot()
        XCTAssertEqual(snapshot.frameCount, 1)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.lastFrameCodec, .proResProxy)
        XCTAssertEqual(snapshot.lastFramePayloadSize, 3)
        XCTAssertEqual(snapshot.lastFrameSourceSequenceNumber, 7)
        XCTAssertEqual(snapshot.lastFrameSourceDisplayTime, 9)
        XCTAssertFalse(snapshot.lastFrameIsKeyFrame)
        XCTAssertTrue(snapshot.lastFrameIsHDRSignaled)
        XCTAssertEqual(snapshot.lastEventKind, .droppedFrame)
        let forwardedPayload = await runtime.debugLastForwardedPayload()
        XCTAssertEqual(forwardedPayload, Data([0xAA, 0xBB, 0xCC]))
    }
}
