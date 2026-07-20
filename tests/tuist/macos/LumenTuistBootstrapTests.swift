@testable import LumenMacBridge
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import XCTest

final class LumenTuistBootstrapTests: XCTestCase {
    func testBootstrapGateSubmitsOneKeyFrameThenCoalescesUntilDecoded() {
        var gate = LumenVideoBootstrapAdmissionGate()

        XCTAssertEqual(gate.admitSourceFrame(), .submitInitialKeyFrame)
        XCTAssertEqual(gate.admitSourceFrame(), .coalesceUntilAcknowledged)
        XCTAssertEqual(gate.admitSourceFrame(), .coalesceUntilAcknowledged)
        XCTAssertTrue(gate.isAwaitingAcknowledgement)
        XCTAssertFalse(gate.isOpen)

        XCTAssertTrue(gate.acknowledgeConfiguration())
        XCTAssertFalse(gate.isAwaitingAcknowledgement)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.admitSourceFrame(), .submit)
        XCTAssertFalse(gate.acknowledgeConfiguration())

        gate.beginBootstrapGeneration()
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(gate.isAwaitingAcknowledgement)
        XCTAssertEqual(gate.admitSourceFrame(), .submitInitialKeyFrame)
    }

    func testSystemAudioJoinsTheActiveVideoStreamForTheSameDisplay() throws {
        let configuration = LumenMacAudioCaptureConfiguration.systemOutput(displayID: 118)

        let route = try LumenSystemAudioCaptureRoute.resolve(
            configuration: configuration,
            activeVideoDisplayID: 118
        )

        XCTAssertEqual(route, .sharedVideoStream)
    }

    func testSystemAudioRejectsASecondStreamForAnotherActiveVideoDisplay() {
        let configuration = LumenMacAudioCaptureConfiguration.systemOutput(displayID: 119)

        XCTAssertThrowsError(
            try LumenSystemAudioCaptureRoute.resolve(
                configuration: configuration,
                activeVideoDisplayID: 118
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "System audio display 119 does not match active video display 118."
            )
        }
    }

    func testSharedAudioRegistrationPreservesVideoOutputOwnershipForLaterFrames() throws {
        var ownership = LumenScreenCaptureOutputOwnership()

        ownership.registerScreenOutput(streamIdentity: 0x118)
        try ownership.attachSharedAudioOutput(streamIdentity: 0x118)
        try ownership.markCaptureStarted(streamIdentity: 0x118)
        try ownership.recordScreenSample(streamIdentity: 0x118)
        try ownership.recordScreenSample(streamIdentity: 0x118)
        try ownership.recordScreenSample(streamIdentity: 0x118)

        XCTAssertEqual(ownership.stage, .sharedAudioRegistered)
        XCTAssertEqual(ownership.screenSampleCount, 3)
        XCTAssertThrowsError(
            try ownership.attachSharedAudioOutput(streamIdentity: 0x119)
        ) { error in
            XCTAssertEqual(
                error as? LumenScreenCaptureOutputOwnershipError,
                .streamIdentityMismatch
            )
        }
    }

    func testSharedSystemAudioIsConfiguredBeforeScreenCaptureStarts() throws {
        let audio = LumenMacAudioCaptureConfiguration.systemOutput(
            displayID: 120,
            sampleRate: 48_000,
            channelCount: 2,
            frameSize: 240,
            excludesCurrentProcessAudio: true
        )
        let preparation = try LumenScreenCaptureSystemAudioPreparation(
            configuration: audio,
            videoDisplayID: 120
        )
        let streamConfiguration = SCStreamConfiguration()

        preparation.apply(to: streamConfiguration)

        XCTAssertTrue(streamConfiguration.capturesAudio)
        XCTAssertEqual(streamConfiguration.sampleRate, 48_000)
        XCTAssertEqual(streamConfiguration.channelCount, 2)
        XCTAssertTrue(streamConfiguration.excludesCurrentProcessAudio)
        XCTAssertTrue(preparation.accepts(audio))
        XCTAssertFalse(preparation.accepts(.systemOutput(displayID: 120, channelCount: 6)))
    }

    func testLegacyVisualFirstCoordinatorStillPreservesTypedBoundaries() async throws {
        let probe = LumenCaptureStartupOrderProbe()

        try await LumenBridgeCaptureStartupCoordinator.startVisualFirst(
            video: {
                await probe.append(.videoStarted)
                try await Task.sleep(for: .milliseconds(50))
                await probe.append(.videoReady)
            },
            launchAudio: {
                await probe.append(.audioScheduled)
            }
        )

        let events = await probe.events
        XCTAssertEqual(events, [.videoStarted, .videoReady, .audioScheduled])
    }

    func testBridgeCaptureStartupPreservesTheFailingBoundary() async {
        do {
            try await LumenBridgeCaptureStartupCoordinator.startVisualFirst(
                video: { throw LumenConcurrentCaptureStartupTestError.failed },
                launchAudio: {}
            )
            XCTFail("Expected video startup to fail")
        } catch let error as LumenBridgeCaptureStartupError {
            XCTAssertEqual(error.source, .video)
            XCTAssertTrue(error.message.contains("test failure"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWorkspaceStopFallsBackToDurableRecovery() async throws {
        let result = try await LumenWorkspaceStopRecoveryCoordinator.stop(
            stop: { throw LumenConcurrentCaptureStartupTestError.failed },
            recover: { true }
        )

        XCTAssertTrue(result.usedDurableRecovery)
        XCTAssertTrue(result.stopFailureMessage?.contains("test failure") == true)
    }

    func testBridgeExposesBootstrapStatus() async {
        let status = await LumenBridgeRuntime.shared.statusSnapshot()

        XCTAssertTrue(status.coreVersion.hasPrefix("Rust ABI "))
        XCTAssertEqual(status.runtimeDescription, "Rust host with Swift macOS capture adapters")
        XCTAssertFalse(status.integrationStatus.isEmpty)
    }

    func testBridgeBuildsPanelNativeScreenCaptureKitConfiguration() async {
        let configuration = await LumenBridgeRuntime.shared.preferredCaptureConfiguration(
            displayID: 7
        )

        XCTAssertEqual(configuration.displayID, 7)
        XCTAssertTrue(LumenCaptureCodec.allCases.contains(configuration.codec))
        XCTAssertEqual(configuration.preprocessStrategy, .none)
        XCTAssertTrue(LumenCaptureQueueProfile.allCases.contains(configuration.queueProfile))
        XCTAssertEqual(configuration.targetFrameRate, 120)
        XCTAssertNil(configuration.requestedWidth)
        XCTAssertNil(configuration.requestedHeight)
        XCTAssertFalse(configuration.usesHDRTransport)
    }

    func testScreenCaptureKitConfigurationAlwaysIncludesCursor() {
        XCTAssertTrue(
            LumenCaptureStreamConfigurationFactory.make(usesHDRTransport: false).showsCursor
        )
        XCTAssertTrue(
            LumenCaptureStreamConfigurationFactory.make(usesHDRTransport: true).showsCursor
        )
    }

    func testBridgeIgnoresImmediateKeyFrameRequestsWithoutActiveSession() async {
        await LumenBridgeRuntime.shared.requestImmediateCaptureKeyFrame()
        let status = await LumenBridgeRuntime.shared.statusSnapshot()
        XCTAssertFalse(status.captureSessionRunning)
    }

    func testBridgeCaptureLifecycleKeepsProducerInactiveDuringStartup() async {
        let lifecycle = LumenBridgeCaptureLifecycle()

        await lifecycle.beginStartup()

        let shouldExposeProducer = await lifecycle.shouldExposeProducer
        let shouldRequestImmediateKeyFrame = await lifecycle.shouldRequestImmediateKeyFrame

        XCTAssertFalse(shouldExposeProducer)
        XCTAssertFalse(shouldRequestImmediateKeyFrame)
    }

    func testBridgeCaptureLifecycleAllowsKeyFramesOnlyWhileRunning() async {
        let lifecycle = LumenBridgeCaptureLifecycle()

        await lifecycle.beginStartup()
        await lifecycle.finishStartup()
        let runningShouldExposeProducer = await lifecycle.shouldExposeProducer
        let runningShouldRequestImmediateKeyFrame = await lifecycle.shouldRequestImmediateKeyFrame
        XCTAssertTrue(runningShouldExposeProducer)
        XCTAssertTrue(runningShouldRequestImmediateKeyFrame)

        await lifecycle.beginStop()
        let stoppingShouldExposeProducer = await lifecycle.shouldExposeProducer
        let stoppingShouldRequestImmediateKeyFrame = await lifecycle.shouldRequestImmediateKeyFrame
        XCTAssertFalse(stoppingShouldExposeProducer)
        XCTAssertFalse(stoppingShouldRequestImmediateKeyFrame)
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
        let configuration = LumenMacCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
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
        let configuration = LumenMacCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            targetFrameRate: 120,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
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

    func testCaptureColorContractAcceptsConvertedHDR10InputWithoutRetagging() throws {
        let color = LumenVideoHDRConfiguration(
            sourceColorPrimaries: .p3D65,
            colorPrimaries: .ituR2020,
            transferFunction: .smpteSt2084PQ,
            yCbCrMatrix: .ituR2020
        )
        let contract = LumenCaptureColorContract(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            color: color
        )
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)

        XCTAssertNil(contract.mismatchDescription(for: imageBuffer))
    }

    func testCaptureColorContractRejectsDisplayP3PixelsRetaggedAsBT2020() throws {
        let color = LumenVideoHDRConfiguration(
            sourceColorPrimaries: .p3D65,
            colorPrimaries: .ituR2020,
            transferFunction: .smpteSt2084PQ,
            yCbCrMatrix: .ituR2020
        )
        let contract = LumenCaptureColorContract(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            color: color
        )
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        XCTAssertEqual(
            contract.mismatchDescription(for: imageBuffer),
            "primaries expected=ITU_R_2020 actual=P3_D65"
        )
    }

    func testHDRCaptureUsesSDRPreservingHDR10OutputContract() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("The SDR-preserving HDR10 ScreenCaptureKit preset requires macOS 26")
        }

        let configuration = LumenCaptureStreamConfigurationFactory.make(usesHDRTransport: true)
        XCTAssertEqual(configuration.captureDynamicRange, .hdrCanonicalDisplay)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(configuration.colorSpaceName as String, CGColorSpace.itur_2100_PQ as String)
        XCTAssertEqual(configuration.colorMatrix as String, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
    }

    func testBridgeNegotiatesFrameGatedHDRAgainstSinkCapabilities() {
        let unsupportedSink = LumenMacCaptureConfiguration(
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
            )
        )

        XCTAssertEqual(unsupportedSink.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportSDR)
        XCTAssertFalse(unsupportedSink.usesHDRTransport)
        XCTAssertEqual(unsupportedSink.negotiatedQueueProfile, .q2)
    }

    func testBridgeNegotiatesOverlayFallbackAndAutoQueueProfile() {
        let fallbackOverlay = LumenMacCaptureConfiguration(
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            )
        )
        let overlayRequestedSink = LumenMacCaptureConfiguration(
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            )
        )

        XCTAssertEqual(fallbackOverlay.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportFrameGatedHDR)
        XCTAssertTrue(fallbackOverlay.usesHDRTransport)
        XCTAssertTrue(fallbackOverlay.prefersRealtimeHDRMetadata)
        XCTAssertEqual(fallbackOverlay.negotiatedQueueProfile, .q3)

        XCTAssertEqual(overlayRequestedSink.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportSDRBaseHDROverlay)
        XCTAssertFalse(overlayRequestedSink.usesHDRTransport)
        XCTAssertTrue(overlayRequestedSink.prefersRealtimeHDRMetadata)
        XCTAssertEqual(overlayRequestedSink.negotiatedQueueProfile, .q4)
    }

    func testRecommendedVideoForwardingFrameCapacityStaysLowLatency() {
        let q2 = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 120
        )
        let auto = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .auto,
            targetFrameRate: 120
        )
        let q4 = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q4,
            targetFrameRate: 120
        )
        let q2NinetyFps = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 90
        )
        let q2SixtyFps = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 60
        )
        let q2ThirtyFps = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 30
        )

        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q2), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: auto), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q4), 3)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q2NinetyFps), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q2SixtyFps), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q2ThirtyFps), 2)
    }

    func testBridgePreservesRequested120HzWithoutImplicitDownscaleFor4KOverlay() {
        let configuration = LumenMacCaptureConfiguration(
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        XCTAssertEqual(configuration.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportSDRBaseHDROverlay)
        XCTAssertEqual(configuration.effectiveTargetFrameRate, 120)
        XCTAssertEqual(configuration.effectivePreprocessStrategy, .none)
        XCTAssertEqual(configuration.negotiatedQueueProfile, .q3)
        XCTAssertEqual(configuration.negotiatedQueueProfile.queueDepthHint, 3)
        XCTAssertEqual(configuration.forwardingQueueDepthReserve, 2)
        XCTAssertEqual(configuration.effectiveTargetFrameRate, 120)
        XCTAssertEqual(configuration.requestedWidth, 3512)
        XCTAssertEqual(configuration.requestedHeight, 2290)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: configuration), 3)
    }

    func testLumenProtocolKeepsEveryClientVisiblePresentationSingleFrame() {
        let capabilities = [
            LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: true
            ),
            LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: false,
                supportsPerFrameHDRMetadata: true
            ),
            LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: false
            ),
        ]

        for capability in capabilities {
            let contract = LumenProtocolPresentationContract.resolve(
                requestedTransport: .sdrBaseHDROverlay,
                sinkCapability: capability
            )
            XCTAssertEqual(contract, .singleFrame)
            XCTAssertEqual(contract.wireName, "single-frame")
            XCTAssertEqual(contract.completionRule, .fullFrame)
        }
    }

    func testMacBridgeDerivesPresentationContractFromLumenProtocol() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        XCTAssertEqual(configuration.lumenProtocolPresentationContract, .singleFrame)
        XCTAssertEqual(configuration.presentationContractName, "single-frame")
        XCTAssertEqual(configuration.presentationCompletionName, "full-frame")
    }

    func testMacProtocolAdapterMapsConfigurationToLumenProtocolSignals() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        let adapter = configuration.lumenProtocolAdapter

        XCTAssertEqual(adapter.requestedTransport, .sdrBaseHDROverlay)
        XCTAssertEqual(adapter.negotiatedTransport, .sdrBaseHDROverlay)
        XCTAssertEqual(
            adapter.sinkCapability,
            LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: true
            )
        )
        XCTAssertEqual(adapter.presentationContract, .singleFrame)
    }

    func testMacProtocolAdapterExposesSourceNeutralPresentationSignal() {
        let adapter = LumenMacProtocolAdapter(
            requestedTransport: .sdrBaseHDROverlay,
            negotiatedTransport: .sdrBaseHDROverlay,
            sinkCapability: LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: true
            )
        )

        XCTAssertEqual(
            adapter.presentationSignal,
            LumenProtocolPresentationSignal(
                requestedTransport: .sdrBaseHDROverlay,
                negotiatedTransport: .sdrBaseHDROverlay,
                sinkCapability: LumenProtocolSinkCapability(
                    prefersHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                )
            )
        )
        XCTAssertEqual(adapter.presentationContract, .singleFrame)
    }

    func testMacProtocolAdapterUsesSharedProtocolAdapterOutputShape() {
        let output = LumenProtocolAdapterOutput(
            requestedTransport: .sdrBaseHDROverlay,
            negotiatedTransport: .sdrBaseHDROverlay,
            sinkCapability: LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: true
            )
        )
        let adapter = LumenMacProtocolAdapter(output: output)

        XCTAssertEqual(adapter.output, output)
        XCTAssertEqual(adapter.presentationContract, .singleFrame)
    }

    func testBridgePrefersTenBitEncoderInputForPartialHDROverlay() {
        let configuration = LumenMacCaptureConfiguration(
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        XCTAssertEqual(configuration.effectiveEncoderInputStrategy, .yuv420v10)
        XCTAssertEqual(configuration.effectiveCapturePixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.effectiveCapturePixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.encodedHDRConfigurationSnapshot?.transferFunction, "smpteSt2084PQ")
    }

    func testBridgeDoesNotForceHDRTransportForBatterySavingSDRMode() {
        let configuration = LumenMacCaptureConfiguration(
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
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .sdr
            )
        )

        XCTAssertFalse(configuration.usesHDRTransport)
        XCTAssertEqual(configuration.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportSDR)
        XCTAssertFalse(configuration.prefersRealtimeHDRMetadata)
        XCTAssertEqual(configuration.effectiveCapturePixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertNil(configuration.encodedHDRConfigurationSnapshot)
    }

    func testBridgeForwardsSyntheticSampleBufferIntoSwiftIngress() async throws {
        let runtime = LumenBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        let sampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0xAA, 0xBB, 0xCC]),
            codecType: kCMVideoCodecType_HEVC,
            colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            transferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
            notSync: true
        )
        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: sampleBuffer,
            codec: .hevc,
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

        let snapshot = await runtime.videoForwardingSnapshot()
        XCTAssertEqual(snapshot.frameCount, 1)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.lastFrameCodec, .hevc)
        XCTAssertEqual(snapshot.lastFramePayloadSize, 3)
        XCTAssertEqual(snapshot.lastFrameSourceSequenceNumber, 7)
        XCTAssertEqual(snapshot.lastFrameSourceDisplayTime, 9)
        XCTAssertTrue(snapshot.hasLastSampleBuffer)
        XCTAssertFalse(snapshot.lastFrameIsKeyFrame)
        XCTAssertTrue(snapshot.lastFrameIsHDRSignaled)
        XCTAssertEqual(snapshot.lastEventKind, .droppedFrame)
    }

    func testBridgeForwardingRequiresFreshKeyFrameAfterCapacityOverflow() async throws {
        let runtime = LumenBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        await runtime.configureVideoForwarding(frameCapacity: 1, eventCapacity: 1)

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

        let snapshot = await runtime.videoForwardingSnapshot()
        XCTAssertEqual(snapshot.frameCount, 2)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.queuedFrameCount, 0)
        XCTAssertEqual(snapshot.queuedEventCount, 1)
        XCTAssertEqual(snapshot.droppedFrameCount, 2)
        XCTAssertEqual(snapshot.lastEventKind, .droppedFrame)

        let discardedFrame = await runtime.drainNextVideoForwardedFrame()
        XCTAssertNil(discardedFrame)

        let drainedEvent = await runtime.drainNextVideoForwardedEvent()
        XCTAssertEqual(drainedEvent?.kind, .droppedFrame)
        XCTAssertEqual(drainedEvent?.message, "core-forwarder-overflow")
        XCTAssertEqual(drainedEvent?.sourceDisplayTime, 10)
    }

    func testBridgeForwardingDropsDependentsUntilRecoveryKeyFrame() async throws {
        let runtime = LumenBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        await runtime.configureVideoForwarding(frameCapacity: 1, eventCapacity: 2)

        for (sequence, keyFrame) in [(1, true), (2, false), (3, false), (4, true)] {
            await runtime.debugForwardSyntheticFrame(
                sampleBuffer: try Self.makeEncodedSampleBuffer(
                    payload: Data([UInt8(sequence)]),
                    codecType: kCMVideoCodecType_HEVC
                ),
                codec: .hevc,
                sourceSequenceNumber: UInt64(sequence),
                sourceDisplayTime: UInt64(sequence * 10),
                isKeyFrame: keyFrame,
                isHDRSignaled: true
            )
        }

        let recoveredFrame = await runtime.drainNextVideoForwardedFrame()
        let recovered = try XCTUnwrap(recoveredFrame)
        XCTAssertEqual(recovered.sourceSequenceNumber, 4)
        XCTAssertTrue(recovered.isKeyFrame)
        XCTAssertEqual(try Self.payloadBytes(from: recovered.sampleBuffer), Data([0x04]))

        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: try Self.makeEncodedSampleBuffer(
                payload: Data([0x05]),
                codecType: kCMVideoCodecType_HEVC
            ),
            codec: .hevc,
            sourceSequenceNumber: 5,
            sourceDisplayTime: 50,
            isKeyFrame: false,
            isHDRSignaled: true
        )

        let snapshot = await runtime.videoForwardingSnapshot()
        XCTAssertEqual(snapshot.frameCount, 5)
        XCTAssertEqual(snapshot.droppedFrameCount, 3)
        XCTAssertEqual(snapshot.queuedFrameCount, 1)
        let dependent = await runtime.drainNextVideoForwardedFrame()
        XCTAssertEqual(dependent?.sourceSequenceNumber, 5)
    }

}

private enum LumenConcurrentCaptureStartupTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "test failure"
    }
}

private enum LumenCaptureStartupOrderEvent: Equatable {
    case videoStarted
    case videoReady
    case audioScheduled
}

private actor LumenCaptureStartupOrderProbe {
    private(set) var events: [LumenCaptureStartupOrderEvent] = []

    func append(_ event: LumenCaptureStartupOrderEvent) {
        events.append(event)
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
