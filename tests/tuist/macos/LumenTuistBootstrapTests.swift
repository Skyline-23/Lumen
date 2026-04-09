@testable import LumenMacBridge
import LumenCore
import CoreMedia
import XCTest

final class LumenTuistBootstrapTests: XCTestCase {
    func testBridgeExposesBootstrapStatus() async {
        let status = await LumenBridgeRuntime.shared.statusSnapshot()

        XCTAssertEqual(status.coreVersion, "LumenCore bootstrap")
        XCTAssertFalse(status.integrationStatus.isEmpty)
    }

    func testBridgeBuildsPanelNativeMacDisplayKitConfiguration() async {
        let configuration = await LumenBridgeRuntime.shared.preferredMacDisplayKitCaptureConfiguration(
            displayID: 7
        )

        XCTAssertEqual(configuration.displayID, 7)
        XCTAssertTrue(LumenCaptureCodec.allCases.contains(configuration.codec))
        XCTAssertEqual(configuration.preprocessStrategy, .none)
        XCTAssertTrue(LumenCaptureQueueProfile.allCases.contains(configuration.queueProfile))
        XCTAssertEqual(configuration.targetFrameRate, 120)
        XCTAssertFalse(configuration.showCursor)
        XCTAssertNil(configuration.requestedWidth)
        XCTAssertNil(configuration.requestedHeight)
        XCTAssertFalse(configuration.usesHDRTransport)
    }

    func testBridgeIgnoresImmediateKeyFrameRequestsWithoutActiveSession() async {
        await LumenBridgeRuntime.shared.requestImmediateCaptureKeyFrame()
        let status = await LumenBridgeRuntime.shared.statusSnapshot()
        XCTAssertFalse(status.captureSessionRunning)
    }

    func testBridgeConfigurationPreferencesParseCodecAndStreamingProfile() {
        let contents = """
        macos_bridge_codec=prores-proxy
        streaming_profile=max-quality
        """

        XCTAssertEqual(
            LumenBridgeConfigurationPreferences.preferredCodec(contents: contents),
            .proResProxy
        )
        XCTAssertEqual(
            LumenBridgeConfigurationPreferences.preferredQueueProfile(contents: contents),
            .q4
        )
        XCTAssertEqual(
            LumenBridgeConfigurationPreferences.preferredQueueProfile(contents: "streaming_profile=low-latency"),
            .q1
        )
        XCTAssertEqual(
            LumenBridgeConfigurationPreferences.preferredQueueProfile(contents: "streaming_profile=balanced"),
            .auto
        )
        XCTAssertEqual(
            LumenBridgeConfigurationPreferences.preferredQueueProfile(contents: "streaming_profile=garbage"),
            .auto
        )
        XCTAssertEqual(
            LumenBridgeConfigurationPreferences.preferredQueueProfile(contents: nil),
            .auto
        )
    }

    func testBridgeConfigurationBoxRoundTripsRequestedOutputAndHDR() {
        let hdrStaticMetadata = LumenHDRStaticMetadata(
            redPrimaryX: 34_000,
            redPrimaryY: 16_000,
            greenPrimaryX: 13_250,
            greenPrimaryY: 34_500,
            bluePrimaryX: 7_500,
            bluePrimaryY: 3_000,
            whitePointX: 15_635,
            whitePointY: 16_450,
            maxDisplayLuminance: 1_000,
            minDisplayLuminance: 10,
            maxContentLightLevel: 1_000,
            maxFrameAverageLightLevel: 400,
            maxFullFrameLuminance: 1_000
        )
        let configuration = LumenMacDisplayKitCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            showCursor: true,
            targetFrameRate: 120,
            targetVideoBitRateKbps: 41_000,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    currentEDRHeadroom: 2.8,
                    potentialEDRHeadroom: 8.4,
                    currentPeakLuminanceNits: 800,
                    potentialPeakLuminanceNits: 1600,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportFrameGatedHDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq,
                hdrStaticMetadata: hdrStaticMetadata
            )
        )

        let roundTrip = LumenBridgeConfigurationBox(configuration: configuration).swiftValue
        XCTAssertEqual(roundTrip.displayID, 11)
        XCTAssertEqual(roundTrip.codec, .hevc)
        XCTAssertTrue(roundTrip.showCursor)
        XCTAssertEqual(roundTrip.targetFrameRate, 120)
        XCTAssertEqual(roundTrip.targetVideoBitRateKbps, 41_000)
        XCTAssertEqual(roundTrip.requestedWidth, 3512)
        XCTAssertEqual(roundTrip.requestedHeight, 2290)
        XCTAssertTrue(roundTrip.usesHDRTransport)
        XCTAssertEqual(roundTrip.effectiveDisplayState.hdrStaticMetadata, hdrStaticMetadata)
        XCTAssertEqual(roundTrip.sinkRequest.capability.currentEDRHeadroom, 2.8)
        XCTAssertEqual(roundTrip.sinkRequest.capability.potentialEDRHeadroom, 8.4)
        XCTAssertEqual(roundTrip.sinkRequest.capability.currentPeakLuminanceNits, 800)
        XCTAssertEqual(roundTrip.sinkRequest.capability.potentialPeakLuminanceNits, 1600)
    }

    func testBridgeHDRConfigurationSeparatesDisplayGamutFromSignalPrimaries() {
        let configuration = LumenMacDisplayKitCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            showCursor: false,
            targetFrameRate: 120,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportFrameGatedHDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        let snapshot = configuration.encodedHDRConfigurationSnapshot
        XCTAssertEqual(snapshot?.signalColorPrimaries, "ituR2020")
        XCTAssertEqual(snapshot?.transferFunction, "smpteSt2084PQ")
        XCTAssertEqual(snapshot?.signalYCbCrMatrix, "ituR2020")
        XCTAssertEqual(snapshot?.staticMetadataSource, "display-p3-default")
    }

    func testBridgeNegotiatesFrameGatedHDRAgainstSinkCapabilities() {
        let unsupportedSink = LumenMacDisplayKitCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 60,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportFrameGatedHDR
            )
        )

        XCTAssertEqual(unsupportedSink.negotiatedDynamicRangeTransport, LumenCoreDynamicRangeTransportSDR)
        XCTAssertFalse(unsupportedSink.usesHDRTransport)
        XCTAssertEqual(unsupportedSink.negotiatedQueueProfile, .q3)
    }

    func testBridgeNegotiatesOverlayFallbackAndAutoQueueProfile() {
        let fallbackOverlay = LumenMacDisplayKitCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 60,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportSDRBaseHDROverlay
            )
        )
        let overlayRequestedSink = LumenMacDisplayKitCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 60,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportSDRBaseHDROverlay
            )
        )

        XCTAssertEqual(fallbackOverlay.negotiatedDynamicRangeTransport, LumenCoreDynamicRangeTransportFrameGatedHDR)
        XCTAssertTrue(fallbackOverlay.usesHDRTransport)
        XCTAssertTrue(fallbackOverlay.prefersRealtimeHDRMetadata)
        XCTAssertEqual(fallbackOverlay.negotiatedQueueProfile, .q3)

        XCTAssertEqual(overlayRequestedSink.negotiatedDynamicRangeTransport, LumenCoreDynamicRangeTransportSDRBaseHDROverlay)
        XCTAssertFalse(overlayRequestedSink.usesHDRTransport)
        XCTAssertTrue(overlayRequestedSink.prefersRealtimeHDRMetadata)
        XCTAssertEqual(overlayRequestedSink.negotiatedQueueProfile, .q4)
    }

    func testRecommendedCoreForwardingFrameCapacityStaysLowLatency() {
        let q2 = LumenMacDisplayKitCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 120
        )
        let auto = LumenMacDisplayKitCaptureConfiguration(
            displayID: 7,
            queueProfile: .auto,
            targetFrameRate: 120
        )
        let q4 = LumenMacDisplayKitCaptureConfiguration(
            displayID: 7,
            queueProfile: .q4,
            targetFrameRate: 120
        )
        let q2NinetyFps = LumenMacDisplayKitCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 90
        )
        let q2SixtyFps = LumenMacDisplayKitCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 60
        )
        let q2ThirtyFps = LumenMacDisplayKitCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 30
        )

        XCTAssertEqual(LumenBridgeRuntime.recommendedCoreForwardingFrameCapacity(for: q2), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedCoreForwardingFrameCapacity(for: auto), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedCoreForwardingFrameCapacity(for: q4), 3)
        XCTAssertEqual(LumenBridgeRuntime.recommendedCoreForwardingFrameCapacity(for: q2NinetyFps), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedCoreForwardingFrameCapacity(for: q2SixtyFps), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedCoreForwardingFrameCapacity(for: q2ThirtyFps), 2)
    }

    func testBridgePreservesRequested120HzWithoutImplicitDownscaleFor4KOverlay() {
        let configuration = LumenMacDisplayKitCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        XCTAssertEqual(configuration.negotiatedDynamicRangeTransport, LumenCoreDynamicRangeTransportSDRBaseHDROverlay)
        XCTAssertEqual(configuration.effectiveTargetFrameRate, 120)
        XCTAssertEqual(configuration.effectivePreprocessStrategy, .none)
        XCTAssertEqual(configuration.negotiatedQueueProfile, .q1)
        XCTAssertEqual(configuration.mdkValue.targetFrameRate, 120)
        XCTAssertEqual(configuration.mdkValue.streamConfiguration.outputWidth, 3512)
        XCTAssertEqual(configuration.mdkValue.streamConfiguration.outputHeight, 2290)
    }

    func testBridgePrefersTenBitEncoderInputForPartialHDROverlay() {
        let configuration = LumenMacDisplayKitCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        XCTAssertEqual(configuration.effectiveEncoderInputStrategy, .yuv420v8)
        XCTAssertEqual(configuration.effectiveCapturePixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(configuration.mdkValue.capturePixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(configuration.encodedHDRConfigurationSnapshot?.transferFunction, "ituR709")
    }

    func testBridgeDoesNotForceHDRTransportForBatterySavingSDRMode() {
        let configuration = LumenMacDisplayKitCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .sdr,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .sdr
            )
        )

        XCTAssertFalse(configuration.usesHDRTransport)
        XCTAssertEqual(configuration.negotiatedDynamicRangeTransport, LumenCoreDynamicRangeTransportSDR)
        XCTAssertFalse(configuration.prefersRealtimeHDRMetadata)
        XCTAssertEqual(configuration.effectiveCapturePixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertNil(configuration.encodedHDRConfigurationSnapshot)
    }

    func testAutoresearchStreamScoringSnapshot() {
        let overlayConfiguration = LumenMacDisplayKitCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )
        let batterySavingConfiguration = LumenMacDisplayKitCaptureConfiguration(
            displayID: 43,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .sdr,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenCoreDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .sdr
            )
        )

        var score = 0.0
        if overlayConfiguration.negotiatedDynamicRangeTransport == LumenCoreDynamicRangeTransportSDRBaseHDROverlay {
            score += 20.0
        }
        if overlayConfiguration.effectiveTargetFrameRate == 120 &&
            overlayConfiguration.mdkValue.targetFrameRate == 120 {
            score += 20.0
        }
        if overlayConfiguration.effectivePreprocessStrategy == .none {
            score += 20.0
        }
        if overlayConfiguration.effectiveEncoderInputStrategy == .yuv420v8 &&
            overlayConfiguration.effectiveCapturePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            overlayConfiguration.encodedHDRConfigurationSnapshot?.transferFunction == "ituR709" {
            score += 10.0
        }
        if overlayConfiguration.negotiatedQueueProfile == .q1 {
            score += 10.0
        }
        if LumenBridgeRuntime.recommendedCoreForwardingFrameCapacity(for: overlayConfiguration) <= 2 {
            score += 10.0
        }
        if batterySavingConfiguration.negotiatedDynamicRangeTransport == LumenCoreDynamicRangeTransportSDR {
            score += 10.0
        }

        print(String(format: "AUTORESEARCH_SYNTHETIC_SCORE=%.2f", score))
        XCTAssertGreaterThan(score, 0.0)
    }

    func testLumenCoreEncodedCaptureIngressStoresSampleBufferMetadata() throws {
        guard let ingress = LumenCoreEncodedCaptureIngressCreate() else {
            return XCTFail("LumenCoreEncodedCaptureIngressCreate returned nil")
        }
        defer {
            LumenCoreEncodedCaptureIngressDestroy(ingress)
        }

        let sampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x01, 0x02, 0x03, 0x04]),
            codecType: kCMVideoCodecType_HEVC,
            colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            transferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
            notSync: true
        )

        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            41,
            42,
            true,
            1.25,
            false,
            true,
            false,
            sampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeEvent(
            ingress,
            LumenCoreCaptureEventKindRestarted,
            "restart",
            false,
            0,
            true,
            2,
            false,
            0
        )

        let snapshot = LumenCoreEncodedCaptureIngressCopySnapshot(ingress)
        XCTAssertEqual(snapshot.frame_count, 1)
        XCTAssertEqual(snapshot.event_count, 1)
        XCTAssertTrue(snapshot.has_last_frame)
        XCTAssertTrue(snapshot.has_last_sample_buffer)
        XCTAssertEqual(snapshot.last_frame_codec, LumenCoreCaptureCodecHEVC)
        XCTAssertEqual(snapshot.last_frame_payload_size, 4)
        XCTAssertEqual(snapshot.last_frame_source_sequence_number, 41)
        XCTAssertEqual(snapshot.last_frame_source_display_time, 42)
        XCTAssertFalse(snapshot.last_frame_is_key_frame)
        XCTAssertTrue(snapshot.last_frame_is_hdr_signaled)
        XCTAssertTrue(snapshot.has_last_event)
        XCTAssertEqual(snapshot.last_event_kind, LumenCoreCaptureEventKindRestarted)
        XCTAssertTrue(snapshot.last_event_has_automatic_restart_count)
        XCTAssertEqual(snapshot.last_event_automatic_restart_count, 2)
    }

    func testLumenCoreEncodedCaptureIngressQueuesFramesAndEventsInOrder() throws {
        guard let ingress = LumenCoreEncodedCaptureIngressCreate() else {
            return XCTFail("LumenCoreEncodedCaptureIngressCreate returned nil")
        }
        defer {
            LumenCoreEncodedCaptureIngressDestroy(ingress)
        }

        LumenCoreEncodedCaptureIngressSetFrameCapacity(ingress, 4)
        LumenCoreEncodedCaptureIngressSetEventCapacity(ingress, 4)

        let firstFrame = try Self.makeEncodedSampleBuffer(
            payload: Data([0x10, 0x11]),
            codecType: kCMVideoCodecType_HEVC
        )
        let secondFrame = try Self.makeEncodedSampleBuffer(
            payload: Data([0x20, 0x21, 0x22]),
            codecType: kCMVideoCodecType_HEVC
        )

        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            1,
            101,
            false,
            0,
            true,
            false,
            false,
            firstFrame
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            2,
            202,
            false,
            0,
            false,
            true,
            false,
            secondFrame
        )
        LumenCoreEncodedCaptureIngressConsumeEvent(
            ingress,
            LumenCoreCaptureEventKindStarted,
            "started",
            false,
            0,
            false,
            0,
            false,
            0
        )
        LumenCoreEncodedCaptureIngressConsumeEvent(
            ingress,
            LumenCoreCaptureEventKindDroppedFrame,
            "dropped",
            false,
            0,
            false,
            0,
            true,
            202
        )

        let snapshot = LumenCoreEncodedCaptureIngressCopySnapshot(ingress)
        XCTAssertEqual(snapshot.queued_frame_count, 2)
        XCTAssertEqual(snapshot.queued_event_count, 2)
        XCTAssertEqual(snapshot.dropped_frame_count, 0)
        XCTAssertEqual(snapshot.dropped_event_count, 0)

        var drainedSampleBuffer: Unmanaged<CMSampleBuffer>?
        let firstRecord = withUnsafeMutablePointer(to: &drainedSampleBuffer) { pointer in
            LumenCoreEncodedCaptureIngressPopNextFrame(ingress, pointer)
        }
        XCTAssertTrue(firstRecord.has_value)
        XCTAssertEqual(firstRecord.source_sequence_number, 1)
        XCTAssertEqual(
            try Self.payloadBytes(from: try XCTUnwrap(drainedSampleBuffer).takeRetainedValue()),
            Data([0x10, 0x11])
        )

        drainedSampleBuffer = nil
        let secondRecord = withUnsafeMutablePointer(to: &drainedSampleBuffer) { pointer in
            LumenCoreEncodedCaptureIngressPopNextFrame(ingress, pointer)
        }
        XCTAssertTrue(secondRecord.has_value)
        XCTAssertEqual(secondRecord.source_sequence_number, 2)
        XCTAssertEqual(
            try Self.payloadBytes(from: try XCTUnwrap(drainedSampleBuffer).takeRetainedValue()),
            Data([0x20, 0x21, 0x22])
        )

        var messageBuffer = Array<CChar>(repeating: 0, count: 128)
        let firstEvent = messageBuffer.withUnsafeMutableBufferPointer { buffer in
            LumenCoreEncodedCaptureIngressPopNextEvent(ingress, buffer.baseAddress, buffer.count)
        }
        XCTAssertTrue(firstEvent.has_value)
        XCTAssertEqual(firstEvent.kind, LumenCoreCaptureEventKindStarted)
        XCTAssertEqual(String(cString: messageBuffer), "started")

        messageBuffer = Array<CChar>(repeating: 0, count: 128)
        let secondEvent = messageBuffer.withUnsafeMutableBufferPointer { buffer in
            LumenCoreEncodedCaptureIngressPopNextEvent(ingress, buffer.baseAddress, buffer.count)
        }
        XCTAssertTrue(secondEvent.has_value)
        XCTAssertEqual(secondEvent.kind, LumenCoreCaptureEventKindDroppedFrame)
        XCTAssertEqual(String(cString: messageBuffer), "dropped")
    }

    func testBridgeForwardsSyntheticSampleBufferIntoLumenCoreIngress() async throws {
        let runtime = LumenBridgeRuntime()
        await runtime.debugResetCoreForwarding()
        let sampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0xAA, 0xBB, 0xCC]),
            codecType: kCMVideoCodecType_AppleProRes422Proxy,
            colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            transferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
            notSync: true
        )
        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: sampleBuffer,
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
        XCTAssertTrue(snapshot.hasLastSampleBuffer)
        XCTAssertFalse(snapshot.lastFrameIsKeyFrame)
        XCTAssertTrue(snapshot.lastFrameIsHDRSignaled)
        XCTAssertEqual(snapshot.lastEventKind, .droppedFrame)
    }

    func testBridgeForwardingDropsOldestFramesWhenCapacityIsExceeded() async throws {
        let runtime = LumenBridgeRuntime()
        await runtime.debugResetCoreForwarding()
        await runtime.configureCoreForwarding(frameCapacity: 1, eventCapacity: 1)

        let firstSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x01]),
            codecType: kCMVideoCodecType_HEVC
        )
        let secondSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x02]),
            codecType: kCMVideoCodecType_HEVC
        )

        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: firstSampleBuffer,
            codec: .hevc,
            sourceSequenceNumber: 1,
            sourceDisplayTime: 10,
            isKeyFrame: true,
            isHDRSignaled: false
        )
        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: secondSampleBuffer,
            codec: .hevc,
            sourceSequenceNumber: 2,
            sourceDisplayTime: 20,
            isKeyFrame: false,
            isHDRSignaled: true
        )

        let snapshot = await runtime.coreForwardingSnapshot()
        XCTAssertEqual(snapshot.frameCount, 2)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.queuedFrameCount, 1)
        XCTAssertEqual(snapshot.queuedEventCount, 1)
        XCTAssertEqual(snapshot.droppedFrameCount, 1)
        XCTAssertEqual(snapshot.lastEventKind, .droppedFrame)

        let drainedFrame = await runtime.drainNextCoreForwardedFrame()
        XCTAssertEqual(drainedFrame?.sourceSequenceNumber, 2)
        XCTAssertEqual(try Self.payloadBytes(from: try XCTUnwrap(drainedFrame?.sampleBuffer)), Data([0x02]))

        let drainedEvent = await runtime.drainNextCoreForwardedEvent()
        XCTAssertEqual(drainedEvent?.kind, .droppedFrame)
        XCTAssertEqual(drainedEvent?.message, "core-forwarder-overflow")
        XCTAssertEqual(drainedEvent?.sourceDisplayTime, 10)
    }

    func testLumenCoreEncodedIngressCollapsesTinyBacklogAfterOverflow() throws {
        guard let ingress = LumenCoreEncodedCaptureIngressCreate() else {
            return XCTFail("LumenCoreEncodedCaptureIngressCreate returned nil")
        }
        defer {
            LumenCoreEncodedCaptureIngressDestroy(ingress)
        }

        LumenCoreEncodedCaptureIngressSetFrameCapacity(ingress, 2)

        let firstSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x11]),
            codecType: kCMVideoCodecType_HEVC
        )
        let secondSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x22]),
            codecType: kCMVideoCodecType_HEVC
        )
        let thirdSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x33]),
            codecType: kCMVideoCodecType_HEVC
        )

        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            1,
            10,
            false,
            0,
            false,
            false,
            false,
            firstSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            2,
            20,
            false,
            0,
            false,
            false,
            false,
            secondSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            3,
            30,
            false,
            0,
            true,
            false,
            false,
            thirdSampleBuffer
        )

        let snapshot = LumenCoreEncodedCaptureIngressCopySnapshot(ingress)
        XCTAssertEqual(snapshot.frame_count, 3)
        XCTAssertEqual(snapshot.queued_frame_count, 1)
        XCTAssertEqual(snapshot.dropped_frame_count, 2)
        XCTAssertEqual(snapshot.event_count, 2)
        XCTAssertEqual(snapshot.queued_event_count, 2)

        var drainedSampleBuffer: Unmanaged<CMSampleBuffer>?
        let record = withUnsafeMutablePointer(to: &drainedSampleBuffer) { pointer in
            LumenCoreEncodedCaptureIngressPopNextFrame(ingress, pointer)
        }
        XCTAssertTrue(record.has_value)
        XCTAssertEqual(record.source_sequence_number, 3)
        XCTAssertEqual(
            try Self.payloadBytes(from: try XCTUnwrap(drainedSampleBuffer).takeRetainedValue()),
            Data([0x33])
        )
    }

    func testLumenCoreEncodedIngressCollapsesThreeFrameBacklogAfterOverflow() throws {
        guard let ingress = LumenCoreEncodedCaptureIngressCreate() else {
            return XCTFail("LumenCoreEncodedCaptureIngressCreate returned nil")
        }
        defer {
            LumenCoreEncodedCaptureIngressDestroy(ingress)
        }

        LumenCoreEncodedCaptureIngressSetFrameCapacity(ingress, 3)

        let firstSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x41]),
            codecType: kCMVideoCodecType_HEVC
        )
        let secondSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x42]),
            codecType: kCMVideoCodecType_HEVC
        )
        let thirdSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x43]),
            codecType: kCMVideoCodecType_HEVC
        )
        let fourthSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x44]),
            codecType: kCMVideoCodecType_HEVC
        )

        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            1,
            10,
            false,
            0,
            false,
            false,
            false,
            firstSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            2,
            20,
            false,
            0,
            false,
            false,
            false,
            secondSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            3,
            30,
            false,
            0,
            false,
            false,
            false,
            thirdSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            4,
            40,
            false,
            0,
            true,
            false,
            false,
            fourthSampleBuffer
        )

        let snapshot = LumenCoreEncodedCaptureIngressCopySnapshot(ingress)
        XCTAssertEqual(snapshot.frame_count, 4)
        XCTAssertEqual(snapshot.queued_frame_count, 1)
        XCTAssertEqual(snapshot.dropped_frame_count, 3)
        XCTAssertEqual(snapshot.event_count, 3)
        XCTAssertEqual(snapshot.queued_event_count, 3)

        var drainedSampleBuffer: Unmanaged<CMSampleBuffer>?
        let record = withUnsafeMutablePointer(to: &drainedSampleBuffer) { pointer in
            LumenCoreEncodedCaptureIngressPopNextFrame(ingress, pointer)
        }
        XCTAssertTrue(record.has_value)
        XCTAssertEqual(record.source_sequence_number, 4)
        XCTAssertEqual(
            try Self.payloadBytes(from: try XCTUnwrap(drainedSampleBuffer).takeRetainedValue()),
            Data([0x44])
        )
    }

    func testLumenCoreEncodedIngressCollapsesOverflowedBacklogWhenNewestFrameIsKeyFrame() throws {
        guard let ingress = LumenCoreEncodedCaptureIngressCreate() else {
            return XCTFail("LumenCoreEncodedCaptureIngressCreate returned nil")
        }
        defer {
            LumenCoreEncodedCaptureIngressDestroy(ingress)
        }

        LumenCoreEncodedCaptureIngressSetFrameCapacity(ingress, 4)

        let firstSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x51]),
            codecType: kCMVideoCodecType_HEVC
        )
        let secondSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x52]),
            codecType: kCMVideoCodecType_HEVC
        )
        let thirdSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x53]),
            codecType: kCMVideoCodecType_HEVC
        )
        let fourthSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x54]),
            codecType: kCMVideoCodecType_HEVC
        )
        let fifthSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x55]),
            codecType: kCMVideoCodecType_HEVC
        )

        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            1,
            10,
            false,
            0,
            false,
            false,
            false,
            firstSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            2,
            20,
            false,
            0,
            false,
            false,
            false,
            secondSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            3,
            30,
            false,
            0,
            false,
            false,
            false,
            thirdSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            4,
            40,
            false,
            0,
            false,
            false,
            false,
            fourthSampleBuffer
        )
        LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
            ingress,
            LumenCoreCaptureCodecHEVC,
            5,
            50,
            false,
            0,
            true,
            false,
            false,
            fifthSampleBuffer
        )

        let snapshot = LumenCoreEncodedCaptureIngressCopySnapshot(ingress)
        XCTAssertEqual(snapshot.frame_count, 5)
        XCTAssertEqual(snapshot.queued_frame_count, 1)
        XCTAssertEqual(snapshot.dropped_frame_count, 4)
        XCTAssertEqual(snapshot.event_count, 4)
        XCTAssertEqual(snapshot.queued_event_count, 4)

        var drainedSampleBuffer: Unmanaged<CMSampleBuffer>?
        let record = withUnsafeMutablePointer(to: &drainedSampleBuffer) { pointer in
            LumenCoreEncodedCaptureIngressPopNextFrame(ingress, pointer)
        }
        XCTAssertTrue(record.has_value)
        XCTAssertEqual(record.source_sequence_number, 5)
        XCTAssertEqual(
            try Self.payloadBytes(from: try XCTUnwrap(drainedSampleBuffer).takeRetainedValue()),
            Data([0x55])
        )
    }

    func testLumenCoreSharedEncodedCaptureIngressWaitsForSharedProducerData() throws {
        guard let ingress = LumenCoreSharedEncodedCaptureIngress() else {
            return XCTFail("LumenCoreSharedEncodedCaptureIngress returned nil")
        }

        LumenCoreEncodedCaptureIngressReset(ingress)
        LumenCoreEncodedCaptureIngressSetProducerActive(ingress, true)
        defer {
            LumenCoreEncodedCaptureIngressSetProducerActive(ingress, false)
            LumenCoreEncodedCaptureIngressReset(ingress)
        }

        let sampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x31, 0x32, 0x33]),
            codecType: kCMVideoCodecType_HEVC
        )

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            LumenCoreEncodedCaptureIngressConsumeSampleBuffer(
                ingress,
                LumenCoreCaptureCodecHEVC,
                99,
                199,
                false,
                0,
                true,
                false,
                false,
                sampleBuffer
            )
        }

        XCTAssertTrue(LumenCoreEncodedCaptureIngressWaitForData(ingress, 500))

        var drainedSampleBuffer: Unmanaged<CMSampleBuffer>?
        let record = withUnsafeMutablePointer(to: &drainedSampleBuffer) { pointer in
            LumenCoreEncodedCaptureIngressPopNextFrame(ingress, pointer)
        }
        XCTAssertTrue(record.has_value)
        XCTAssertEqual(record.source_sequence_number, 99)
        XCTAssertEqual(
            try Self.payloadBytes(from: try XCTUnwrap(drainedSampleBuffer).takeRetainedValue()),
            Data([0x31, 0x32, 0x33])
        )
    }

    func testLumenCoreSharedEncodedCaptureIngressWaitsForProducerActivation() {
        guard let ingress = LumenCoreSharedEncodedCaptureIngress() else {
            return XCTFail("LumenCoreSharedEncodedCaptureIngress returned nil")
        }

        LumenCoreEncodedCaptureIngressReset(ingress)
        LumenCoreEncodedCaptureIngressSetProducerActive(ingress, false)
        defer {
            LumenCoreEncodedCaptureIngressSetProducerActive(ingress, false)
            LumenCoreEncodedCaptureIngressReset(ingress)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            LumenCoreEncodedCaptureIngressSetProducerActive(ingress, true)
        }

        XCTAssertTrue(LumenCoreEncodedCaptureIngressWaitForProducerActive(ingress, 500))
    }

    func testLumenCoreCaptureRequestPublishesAndWaitsForGenerationChanges() {
        let snapshotBeforeClear = LumenCoreCaptureRequestCopySnapshot()
        LumenCoreCaptureRequestClear()

        let initialSnapshot = LumenCoreCaptureRequestCopySnapshot()
        XCTAssertEqual(initialSnapshot.generation, snapshotBeforeClear.generation + 1)
        XCTAssertEqual(initialSnapshot.video_generation, snapshotBeforeClear.video_generation + 1)
        XCTAssertEqual(initialSnapshot.audio_generation, snapshotBeforeClear.audio_generation + 1)
        XCTAssertFalse(initialSnapshot.video_requested)
        XCTAssertFalse(initialSnapshot.audio_requested)
        XCTAssertEqual(initialSnapshot.codec, LumenCoreCaptureCodecUnknown)
        XCTAssertEqual(initialSnapshot.audio_source_kind, LumenCoreAudioCaptureSourceKindUnknown)
        XCTAssertEqual(initialSnapshot.queue_profile, LumenCoreCaptureQueueProfileAuto)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            var hdrStaticMetadata = LumenCoreHDRStaticMetadata()
            hdrStaticMetadata.red_primary_x = 34_000
            hdrStaticMetadata.red_primary_y = 16_000
            hdrStaticMetadata.green_primary_x = 13_250
            hdrStaticMetadata.green_primary_y = 34_500
            hdrStaticMetadata.blue_primary_x = 7_500
            hdrStaticMetadata.blue_primary_y = 3_000
            hdrStaticMetadata.white_point_x = 15_635
            hdrStaticMetadata.white_point_y = 16_450
            hdrStaticMetadata.max_display_luminance = 1_000
            hdrStaticMetadata.min_display_luminance = 10
            hdrStaticMetadata.max_content_light_level = 1_000
            hdrStaticMetadata.max_frame_average_light_level = 400
            hdrStaticMetadata.max_full_frame_luminance = 1_000
            var sinkMode = LumenCoreSinkMode()
            sinkMode.hidpi = true
            sinkMode.scale_explicit = true
            sinkMode.mode_is_logical = true
            sinkMode.scale_percent = 200
            var sinkCapability = LumenCoreSinkCapability()
            sinkCapability.gamut = 2
            sinkCapability.transfer = 2
            sinkCapability.current_edr_headroom = 2.8
            sinkCapability.potential_edr_headroom = 8.4
            sinkCapability.current_peak_luminance_nits = 800
            sinkCapability.potential_peak_luminance_nits = 1600
            sinkCapability.supports_frame_gated_hdr = true
            sinkCapability.supports_hdr_tile_overlay = false
            sinkCapability.supports_per_frame_hdr_metadata = true
            var sinkRequest = LumenCoreSinkRequest()
            sinkRequest.mode = sinkMode
            sinkRequest.capability = sinkCapability
            sinkRequest.dynamic_range_transport = LumenCoreDynamicRangeTransportFrameGatedHDR
            var effectiveDisplayState = LumenCoreEffectiveDisplayState()
            effectiveDisplayState.gamut = 2
            effectiveDisplayState.transfer = 2
            effectiveDisplayState.has_hdr_static_metadata = true
            effectiveDisplayState.hdr_static_metadata = hdrStaticMetadata
            LumenCoreCaptureRequestPublishVideo(
                17,
                LumenCoreCaptureCodecHEVC,
                LumenCoreCapturePreprocessStrategyNone,
                LumenCoreCaptureQueueProfileAuto,
                false,
                120,
                41_000,
                3840,
                2160,
                sinkRequest,
                effectiveDisplayState
            )
            LumenCoreCaptureRequestPublishAudio(
                LumenCoreAudioCaptureSourceKindSystemOutput,
                17,
                false,
                48_000,
                2,
                480
            )
        }

        XCTAssertTrue(LumenCoreCaptureRequestWaitForGenerationChange(initialSnapshot.generation, 500))

        let updatedSnapshot = LumenCoreCaptureRequestCopySnapshot()
        XCTAssertGreaterThan(updatedSnapshot.generation, initialSnapshot.generation)
        XCTAssertGreaterThan(updatedSnapshot.video_generation, initialSnapshot.video_generation)
        XCTAssertGreaterThan(updatedSnapshot.audio_generation, initialSnapshot.audio_generation)
        XCTAssertTrue(updatedSnapshot.video_requested)
        XCTAssertTrue(updatedSnapshot.audio_requested)
        XCTAssertEqual(updatedSnapshot.display_id, 17)
        XCTAssertEqual(updatedSnapshot.codec, LumenCoreCaptureCodecHEVC)
        XCTAssertEqual(updatedSnapshot.queue_profile, LumenCoreCaptureQueueProfileAuto)
        XCTAssertEqual(updatedSnapshot.target_frame_rate, 120)
        XCTAssertEqual(updatedSnapshot.target_video_bitrate_kbps, 41_000)
        XCTAssertEqual(updatedSnapshot.requested_width, 3840)
        XCTAssertEqual(updatedSnapshot.requested_height, 2160)
        XCTAssertTrue(updatedSnapshot.sink_request.mode.hidpi)
        XCTAssertTrue(updatedSnapshot.sink_request.mode.scale_explicit)
        XCTAssertTrue(updatedSnapshot.sink_request.mode.mode_is_logical)
        XCTAssertEqual(updatedSnapshot.sink_request.mode.scale_percent, 200)
        XCTAssertEqual(updatedSnapshot.sink_request.capability.gamut, 2)
        XCTAssertEqual(updatedSnapshot.sink_request.capability.transfer, 2)
        XCTAssertEqual(updatedSnapshot.effective_display_state.gamut, 2)
        XCTAssertEqual(updatedSnapshot.effective_display_state.transfer, 2)
        XCTAssertTrue(updatedSnapshot.effective_display_state.has_hdr_static_metadata)
        XCTAssertEqual(updatedSnapshot.effective_display_state.hdr_static_metadata.max_display_luminance, 1_000)
        XCTAssertEqual(updatedSnapshot.effective_display_state.hdr_static_metadata.max_frame_average_light_level, 400)
        XCTAssertEqual(updatedSnapshot.sink_request.capability.current_edr_headroom, 2.8)
        XCTAssertEqual(updatedSnapshot.sink_request.capability.potential_edr_headroom, 8.4)
        XCTAssertEqual(updatedSnapshot.sink_request.capability.current_peak_luminance_nits, 800)
        XCTAssertEqual(updatedSnapshot.sink_request.capability.potential_peak_luminance_nits, 1600)
        XCTAssertEqual(updatedSnapshot.sink_request.dynamic_range_transport, LumenCoreDynamicRangeTransportFrameGatedHDR)
        XCTAssertTrue(updatedSnapshot.sink_request.capability.supports_frame_gated_hdr)
        XCTAssertFalse(updatedSnapshot.sink_request.capability.supports_hdr_tile_overlay)
        XCTAssertTrue(updatedSnapshot.sink_request.capability.supports_per_frame_hdr_metadata)
        XCTAssertEqual(updatedSnapshot.audio_source_kind, LumenCoreAudioCaptureSourceKindSystemOutput)
        XCTAssertEqual(updatedSnapshot.audio_frame_size, 480)

        LumenCoreCaptureRequestClear()
    }

    func testMirroredCaptureRequestSnapshotLoadsFromPropertyList() throws {
        let propertyList: [String: Any] = [
            "generation": 9,
            "videoGeneration": 10,
            "audioGeneration": 11,
            "videoRequested": true,
            "audioRequested": true,
            "displayID": 19,
            "codec": 1,
            "preprocessStrategy": 1,
            "queueProfile": 2,
            "showCursor": false,
            "targetFrameRate": 120,
            "targetVideoBitrateKbps": 41_000,
            "requestedWidth": 3840,
            "requestedHeight": 2160,
            "sinkRequest": [
                "mode": [
                    "hidpi": false,
                    "scaleExplicit": false,
                    "modeIsLogical": false,
                    "scalePercent": 100,
                ],
                "capability": [
                    "gamut": 2,
                    "transfer": 2,
                    "currentEDRHeadroom": 2.8,
                    "potentialEDRHeadroom": 8.4,
                    "currentPeakLuminanceNits": 800,
                    "potentialPeakLuminanceNits": 1600,
                    "supportsFrameGatedHDR": true,
                    "supportsHDRTileOverlay": false,
                    "supportsPerFrameHDRMetadata": true,
                ],
                "dynamicRangeTransport": 3,
            ],
            "effectiveDisplayState": [
                "gamut": 2,
                "transfer": 2,
                "hdrStaticMetadata": [
                    "redPrimaryX": 34_000,
                    "redPrimaryY": 16_000,
                    "greenPrimaryX": 13_250,
                    "greenPrimaryY": 34_500,
                    "bluePrimaryX": 7_500,
                    "bluePrimaryY": 3_000,
                    "whitePointX": 15_635,
                    "whitePointY": 16_450,
                    "maxDisplayLuminance": 1_000,
                    "minDisplayLuminance": 10,
                    "maxContentLightLevel": 1_000,
                    "maxFrameAverageLightLevel": 400,
                    "maxFullFrameLuminance": 1_000,
                ],
            ],
            "audioSourceKind": 1,
            "audioExcludesCurrentProcess": true,
            "audioSampleRate": 48_000,
            "audioChannelCount": 2,
            "audioFrameSize": 480,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let snapshot = try XCTUnwrap(LumenBridgeMirroredCaptureRequestSnapshot.load(from: url))
        XCTAssertEqual(snapshot.generation, 9)
        XCTAssertEqual(snapshot.videoGeneration, 10)
        XCTAssertEqual(snapshot.audioGeneration, 11)
        XCTAssertTrue(snapshot.videoRequested)
        XCTAssertTrue(snapshot.audioRequested)
        XCTAssertEqual(snapshot.displayID, 19)
        XCTAssertEqual(snapshot.codec, LumenCoreCaptureCodecHEVC)
        XCTAssertEqual(snapshot.preprocessStrategy, LumenCoreCapturePreprocessStrategyDownscale2x)
        XCTAssertEqual(snapshot.queueProfile, LumenCoreCaptureQueueProfileQ3)
        XCTAssertEqual(snapshot.targetVideoBitrateKbps, 41_000)
        XCTAssertEqual(snapshot.sinkRequest.capability.gamut, 2)
        XCTAssertEqual(snapshot.sinkRequest.capability.transfer, 2)
        XCTAssertEqual(snapshot.effectiveDisplayState.gamut, 2)
        XCTAssertEqual(snapshot.effectiveDisplayState.transfer, 2)
        XCTAssertEqual(snapshot.sinkRequest.capability.currentEDRHeadroom, 2.8)
        XCTAssertEqual(snapshot.sinkRequest.capability.potentialEDRHeadroom, 8.4)
        XCTAssertEqual(snapshot.sinkRequest.capability.currentPeakLuminanceNits, 800)
        XCTAssertEqual(snapshot.sinkRequest.capability.potentialPeakLuminanceNits, 1600)
        XCTAssertEqual(snapshot.sinkRequest.dynamicRangeTransport, LumenCoreDynamicRangeTransportFrameGatedHDR)
        XCTAssertTrue(snapshot.sinkRequest.capability.supportsFrameGatedHDR)
        XCTAssertFalse(snapshot.sinkRequest.capability.supportsHDRTileOverlay)
        XCTAssertTrue(snapshot.sinkRequest.capability.supportsPerFrameHDRMetadata)
        XCTAssertEqual(snapshot.effectiveDisplayState.hdrStaticMetadata?.maxDisplayLuminance, 1_000)
        XCTAssertEqual(snapshot.effectiveDisplayState.hdrStaticMetadata?.maxFrameAverageLightLevel, 400)
        XCTAssertEqual(snapshot.audioSourceKind, LumenCoreAudioCaptureSourceKindSystemOutput)
        XCTAssertTrue(snapshot.audioExcludesCurrentProcess)
        XCTAssertEqual(snapshot.audioSampleRate, 48_000)
        XCTAssertEqual(snapshot.audioChannelCount, 2)
        XCTAssertEqual(snapshot.audioFrameSize, 480)
    }

    func testMirroredCaptureRequestSnapshotLoadsAutoQueueProfileFromPropertyList() throws {
        let propertyList: [String: Any] = [
            "generation": 12,
            "videoGeneration": 12,
            "audioGeneration": 12,
            "videoRequested": true,
            "audioRequested": false,
            "displayID": 27,
            "codec": 1,
            "preprocessStrategy": 0,
            "queueProfile": 4,
            "showCursor": false,
            "targetFrameRate": 120,
            "targetVideoBitrateKbps": 41_000,
            "requestedWidth": 3512,
            "requestedHeight": 2290,
            "sinkRequest": [
                "mode": [
                    "hidpi": false,
                    "scaleExplicit": false,
                    "modeIsLogical": false,
                    "scalePercent": 100,
                ],
                "capability": [
                    "gamut": 3,
                    "transfer": 2,
                    "currentEDRHeadroom": 2.2,
                    "potentialEDRHeadroom": 7.8,
                    "currentPeakLuminanceNits": 700,
                    "potentialPeakLuminanceNits": 1500,
                    "supportsFrameGatedHDR": true,
                    "supportsHDRTileOverlay": false,
                    "supportsPerFrameHDRMetadata": true,
                ],
                "dynamicRangeTransport": 3,
            ],
            "effectiveDisplayState": [
                "gamut": 3,
                "transfer": 2,
            ],
            "audioSourceKind": 0,
            "audioExcludesCurrentProcess": false,
            "audioSampleRate": 48_000,
            "audioChannelCount": 2,
            "audioFrameSize": 480,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let snapshot = try XCTUnwrap(LumenBridgeMirroredCaptureRequestSnapshot.load(from: url))
        XCTAssertEqual(snapshot.queueProfile, LumenCoreCaptureQueueProfileAuto)
        XCTAssertEqual(snapshot.targetVideoBitrateKbps, 41_000)
        XCTAssertEqual(snapshot.sinkRequest.capability.gamut, 3)
        XCTAssertEqual(snapshot.effectiveDisplayState.gamut, 3)
        XCTAssertEqual(snapshot.sinkRequest.capability.currentEDRHeadroom, 2.2)
        XCTAssertEqual(snapshot.sinkRequest.capability.potentialPeakLuminanceNits, 1500)
        XCTAssertEqual(snapshot.sinkRequest.dynamicRangeTransport, LumenCoreDynamicRangeTransportFrameGatedHDR)
        XCTAssertTrue(snapshot.sinkRequest.capability.supportsFrameGatedHDR)
        XCTAssertFalse(snapshot.sinkRequest.capability.supportsHDRTileOverlay)
        XCTAssertTrue(snapshot.sinkRequest.capability.supportsPerFrameHDRMetadata)
    }

    func testMirroredCaptureRequestSnapshotDefaultsMissingTargetBitrateForOlderStateFiles() throws {
        let propertyList: [String: Any] = [
            "generation": 13,
            "videoGeneration": 13,
            "audioGeneration": 13,
            "videoRequested": true,
            "audioRequested": false,
            "displayID": 27,
            "codec": 1,
            "preprocessStrategy": 0,
            "queueProfile": 4,
            "showCursor": false,
            "targetFrameRate": 120,
            "requestedWidth": 3512,
            "requestedHeight": 2290,
            "sinkRequest": [
                "mode": [
                    "hidpi": false,
                    "scaleExplicit": false,
                    "modeIsLogical": false,
                    "scalePercent": 100,
                ],
                "capability": [
                    "gamut": 3,
                    "transfer": 2,
                    "currentEDRHeadroom": 2.2,
                    "potentialEDRHeadroom": 7.8,
                    "currentPeakLuminanceNits": 700,
                    "potentialPeakLuminanceNits": 1500,
                    "supportsFrameGatedHDR": true,
                    "supportsHDRTileOverlay": false,
                    "supportsPerFrameHDRMetadata": true,
                ],
                "dynamicRangeTransport": 3,
            ],
            "effectiveDisplayState": [
                "gamut": 3,
                "transfer": 2,
            ],
            "audioSourceKind": 0,
            "audioExcludesCurrentProcess": false,
            "audioSampleRate": 48_000,
            "audioChannelCount": 2,
            "audioFrameSize": 480,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let snapshot = try XCTUnwrap(LumenBridgeMirroredCaptureRequestSnapshot.load(from: url))
        XCTAssertEqual(snapshot.targetVideoBitrateKbps, 0)
    }

    func testMirroredCaptureRequestSemanticStateIgnoresGenerationOnlyChanges() {
        let baseline = LumenBridgeMirroredCaptureRequestSnapshot(
            [
                "generation": 12,
                "videoGeneration": 12,
                "audioGeneration": 12,
                "videoRequested": true,
                "audioRequested": true,
                "displayID": 27,
                "codec": 1,
                "preprocessStrategy": 0,
                "queueProfile": 4,
                "showCursor": false,
                "targetFrameRate": 120,
                "targetVideoBitrateKbps": 41_000,
                "requestedWidth": 3512,
                "requestedHeight": 2290,
                "sinkRequest": [
                    "mode": [
                        "hidpi": false,
                        "scaleExplicit": false,
                        "modeIsLogical": false,
                        "scalePercent": 100,
                    ],
                    "capability": [
                        "gamut": 3,
                        "transfer": 2,
                        "currentEDRHeadroom": 2.2,
                        "potentialEDRHeadroom": 7.8,
                        "currentPeakLuminanceNits": 700,
                        "potentialPeakLuminanceNits": 1500,
                        "supportsFrameGatedHDR": true,
                        "supportsHDRTileOverlay": false,
                        "supportsPerFrameHDRMetadata": true,
                    ],
                    "dynamicRangeTransport": 3,
                ],
                "effectiveDisplayState": [
                    "gamut": 3,
                    "transfer": 2,
                ],
                "audioSourceKind": 1,
                "audioExcludesCurrentProcess": false,
                "audioSampleRate": 48_000,
                "audioChannelCount": 2,
                "audioFrameSize": 480,
            ]
        )
        let generationOnlyUpdate = LumenBridgeMirroredCaptureRequestSnapshot(
            [
                "generation": 21,
                "videoGeneration": 22,
                "audioGeneration": 23,
                "videoRequested": true,
                "audioRequested": true,
                "displayID": 27,
                "codec": 1,
                "preprocessStrategy": 0,
                "queueProfile": 4,
                "showCursor": false,
                "targetFrameRate": 120,
                "targetVideoBitrateKbps": 41_000,
                "requestedWidth": 3512,
                "requestedHeight": 2290,
                "sinkRequest": [
                    "mode": [
                        "hidpi": false,
                        "scaleExplicit": false,
                        "modeIsLogical": false,
                        "scalePercent": 100,
                    ],
                    "capability": [
                        "gamut": 3,
                        "transfer": 2,
                        "currentEDRHeadroom": 2.2,
                        "potentialEDRHeadroom": 7.8,
                        "currentPeakLuminanceNits": 700,
                        "potentialPeakLuminanceNits": 1500,
                        "supportsFrameGatedHDR": true,
                        "supportsHDRTileOverlay": false,
                        "supportsPerFrameHDRMetadata": true,
                    ],
                    "dynamicRangeTransport": 3,
                ],
                "effectiveDisplayState": [
                    "gamut": 3,
                    "transfer": 2,
                ],
                "audioSourceKind": 1,
                "audioExcludesCurrentProcess": false,
                "audioSampleRate": 48_000,
                "audioChannelCount": 2,
                "audioFrameSize": 480,
            ]
        )

        XCTAssertEqual(baseline?.semanticState, generationOnlyUpdate?.semanticState)
    }

    func testShouldApplyAutomationRequestSkipsGenerationOnlyChangesForStableConfiguration() {
        let configuration = LumenMacDisplayKitCaptureConfiguration(
            displayID: 17,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            showCursor: false,
            targetFrameRate: 120,
            targetVideoBitRateKbps: 41_000,
            requestedWidth: 3840,
            requestedHeight: 2160,
            sinkRequest: LumenBridgeSinkRequest(
                dynamicRangeTransport: LumenCoreDynamicRangeTransportFrameGatedHDR
            )
        )

        XCTAssertTrue(
            LumenBridgeRuntime.shouldApplyAutomationRequest(
                requestedConfiguration: configuration,
                activeConfiguration: nil,
                sessionIsActive: false,
                lastAppliedGeneration: nil
            )
        )
        XCTAssertFalse(
            LumenBridgeRuntime.shouldApplyAutomationRequest(
                requestedConfiguration: configuration,
                activeConfiguration: configuration,
                sessionIsActive: true,
                lastAppliedGeneration: 41
            )
        )
        XCTAssertTrue(
            LumenBridgeRuntime.shouldApplyAutomationRequest(
                requestedConfiguration: configuration,
                activeConfiguration: configuration,
                sessionIsActive: true,
                lastAppliedGeneration: nil
            )
        )
        XCTAssertTrue(
            LumenBridgeRuntime.shouldApplyAutomationRequest(
                requestedConfiguration: configuration,
                activeConfiguration: configuration,
                sessionIsActive: false,
                lastAppliedGeneration: 41
            )
        )
        XCTAssertTrue(
            LumenBridgeRuntime.shouldApplyAutomationRequest(
                requestedConfiguration: nil as LumenMacDisplayKitCaptureConfiguration?,
                activeConfiguration: configuration,
                sessionIsActive: true,
                lastAppliedGeneration: 41
            )
        )
        XCTAssertFalse(
            LumenBridgeRuntime.shouldApplyAutomationRequest(
                requestedConfiguration: nil as LumenMacDisplayKitCaptureConfiguration?,
                activeConfiguration: nil,
                sessionIsActive: false,
                lastAppliedGeneration: nil
            )
        )
    }

    func testLumenCoreAudioCaptureIngressStoresPCMAndEvents() {
        guard let ingress = LumenCoreSharedAudioCaptureIngress() else {
            return XCTFail("LumenCoreSharedAudioCaptureIngress returned nil")
        }

        LumenCoreAudioCaptureIngressReset(ingress)
        LumenCoreAudioCaptureIngressSetProducerActive(ingress, true)
        LumenCoreAudioCaptureIngressSetFrameCapacity(ingress, 2)
        LumenCoreAudioCaptureIngressSetEventCapacity(ingress, 2)
        defer {
            LumenCoreAudioCaptureIngressSetProducerActive(ingress, false)
            LumenCoreAudioCaptureIngressReset(ingress)
        }

        let pcmValues: [Float] = [0.25, -0.5, 0.75, -1.0]
        pcmValues.withUnsafeBytes { rawBuffer in
            LumenCoreAudioCaptureIngressConsumePCMFloat32(
                ingress,
                17,
                123_456,
                48_000,
                2,
                2,
                rawBuffer.baseAddress,
                rawBuffer.count
            )
        }
        LumenCoreAudioCaptureIngressConsumeEvent(
            ingress,
            LumenCoreCaptureEventKindRestarted,
            "audio-restarted",
            false,
            0,
            true,
            3,
            true,
            17
        )

        let snapshot = LumenCoreAudioCaptureIngressCopySnapshot(ingress)
        XCTAssertEqual(snapshot.frame_count, 1)
        XCTAssertEqual(snapshot.event_count, 1)
        XCTAssertEqual(snapshot.last_frame_sequence_number, 17)
        XCTAssertEqual(snapshot.last_frame_host_time_nanoseconds, 123_456)
        XCTAssertEqual(snapshot.last_frame_pcm_byte_count, pcmValues.count * MemoryLayout<Float>.size)
        XCTAssertEqual(snapshot.last_event_kind, LumenCoreCaptureEventKindRestarted)
        XCTAssertEqual(snapshot.last_event_automatic_restart_count, 3)

        var copiedSize = 0
        var drainedPCM = Data(count: pcmValues.count * MemoryLayout<Float>.size)
        let frameRecord = drainedPCM.withUnsafeMutableBytes { rawBuffer in
            LumenCoreAudioCaptureIngressPopNextFrame(
                ingress,
                rawBuffer.baseAddress,
                rawBuffer.count,
                &copiedSize
            )
        }
        XCTAssertTrue(frameRecord.has_value)
        XCTAssertEqual(frameRecord.sequence_number, 17)
        XCTAssertEqual(copiedSize, drainedPCM.count)
        let drainedValues = drainedPCM.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
        XCTAssertEqual(drainedValues, pcmValues)

        var messageBuffer = Array<CChar>(repeating: 0, count: 128)
        let eventRecord = messageBuffer.withUnsafeMutableBufferPointer { buffer in
            LumenCoreAudioCaptureIngressPopNextEvent(ingress, buffer.baseAddress, buffer.count)
        }
        XCTAssertTrue(eventRecord.has_value)
        XCTAssertEqual(eventRecord.kind, LumenCoreCaptureEventKindRestarted)
        XCTAssertEqual(String(cString: messageBuffer), "audio-restarted")
    }

    func testLumenCoreSharedAudioCaptureIngressWaitsForProducerActivation() {
        guard let ingress = LumenCoreSharedAudioCaptureIngress() else {
            return XCTFail("LumenCoreSharedAudioCaptureIngress returned nil")
        }

        LumenCoreAudioCaptureIngressReset(ingress)
        LumenCoreAudioCaptureIngressSetProducerActive(ingress, false)
        defer {
            LumenCoreAudioCaptureIngressSetProducerActive(ingress, false)
            LumenCoreAudioCaptureIngressReset(ingress)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            LumenCoreAudioCaptureIngressSetProducerActive(ingress, true)
        }

        XCTAssertTrue(LumenCoreAudioCaptureIngressWaitForProducerActive(ingress, 500))
    }
}

private extension LumenTuistBootstrapTests {
    static func makeEncodedSampleBuffer(
        payload: Data,
        codecType: CMVideoCodecType,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        notSync: Bool = false
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let bytes = [UInt8](payload)
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(status, noErr)

        let appendStatus = bytes.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        XCTAssertEqual(appendStatus, noErr)

        var extensions: [CFString: Any] = [:]
        if let colorPrimaries {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = colorPrimaries as CFString
        }
        if let transferFunction {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transferFunction as CFString
        }
        if transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = Data([0, 1, 0, 1]) as CFData
        }

        var formatDescription: CMFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codecType,
                width: 3840,
                height: 2160,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: 1, timescale: 120),
            decodeTimeStamp: .invalid
        )
        let sampleSize = [bytes.count]
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: [timing],
                sampleSizeEntryCount: 1,
                sampleSizeArray: sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )

        if notSync,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
            try XCTUnwrap(sampleBuffer),
            createIfNecessary: true
           ) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return try XCTUnwrap(sampleBuffer)
    }

    static func payloadBytes(from sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw NSError(domain: "LumenTuistBootstrapTests", code: 1)
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: rawBuffer.baseAddress!
            )
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        return bytes
    }
}
