@testable import LumenMacBridge
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import XCTest

final class LumenMacBridgePresentationTests: XCTestCase {
    func testCaptureCadenceTelemetrySeparatesOneSecondPipelineRates() throws {
        var telemetry = LumenCaptureCadenceTelemetry()
        var statistics = LumenEncodedCaptureSessionStatistics()
        statistics.sourceFrameCount = 1

        XCTAssertFalse(
            telemetry.observe(
                statistics: statistics,
                atUptimeNanoseconds: 10
            )
        )

        statistics.sourceFrameCount = 121
        statistics.submittedFrameCount = 100
        statistics.emittedFrameCount = 50
        statistics.pendingAdmissionDropCount = 20

        XCTAssertTrue(
            telemetry.observe(
                statistics: statistics,
                atUptimeNanoseconds: 1_000_000_010
            )
        )
        XCTAssertEqual(telemetry.windowDurationMilliseconds, 1_000)
        XCTAssertEqual(telemetry.sourceCallbacksPerSecond, 120)
        XCTAssertEqual(telemetry.videoToolboxSubmissionsPerSecond, 100)
        XCTAssertEqual(telemetry.videoToolboxOutputsPerSecond, 50)
        XCTAssertEqual(telemetry.pendingAdmissionDropsPerSecond, 20)
    }

    func testCaptureCadenceTelemetryKeepsLatestWindowUntilNextSecond() throws {
        var telemetry = LumenCaptureCadenceTelemetry()
        var statistics = LumenEncodedCaptureSessionStatistics()

        XCTAssertFalse(
            telemetry.observe(
                statistics: statistics,
                atUptimeNanoseconds: 100
            )
        )
        statistics.sourceFrameCount = 60
        XCTAssertTrue(
            telemetry.observe(
                statistics: statistics,
                atUptimeNanoseconds: 1_000_000_100
            )
        )

        statistics.sourceFrameCount = 90
        XCTAssertFalse(
            telemetry.observe(
                statistics: statistics,
                atUptimeNanoseconds: 1_500_000_100
            )
        )
        XCTAssertEqual(telemetry.sourceCallbacksPerSecond, 60)
    }

    func testCapturePipelineUtilizationSeparatesSCKAdmissionAndEncoderOutput() {
        var statistics = LumenEncodedCaptureSessionStatistics()
        statistics.sourceFrameCount = 125
        statistics.completeSourceFrameCount = 120
        statistics.incompleteSourceFrameCount = 5
        statistics.submittedFrameCount = 90
        statistics.emittedFrameCount = 81

        let utilization = LumenCapturePipelineUtilization(statistics: statistics)

        XCTAssertEqual(utilization.videoToolboxAdmissionPercent, 75)
        XCTAssertEqual(utilization.videoToolboxOutputPercent, 90)
    }

    func testCapturePipelineUtilizationIsUnavailableBeforeAStageReceivesFrames() {
        let utilization = LumenCapturePipelineUtilization(
            statistics: .init()
        )

        XCTAssertNil(utilization.videoToolboxAdmissionPercent)
        XCTAssertNil(utilization.videoToolboxOutputPercent)
    }

    func testRecommendedVideoForwardingFrameCapacityStaysLowLatency() {
        let cases = [
            LumenForwardingCapacityTestCase(.q2, 120, 2),
            LumenForwardingCapacityTestCase(.auto, 120, 2),
            LumenForwardingCapacityTestCase(.q4, 120, 3),
            LumenForwardingCapacityTestCase(.q2, 90, 2),
            LumenForwardingCapacityTestCase(.q2, 60, 2),
            LumenForwardingCapacityTestCase(.q2, 30, 2)
        ]

        for testCase in cases {
            let configuration = LumenMacCaptureConfiguration(
                displayID: 7,
                queueProfile: testCase.queueProfile,
                targetFrameRate: testCase.targetFrameRate
            )
            XCTAssertEqual(
                LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(
                    for: configuration
                ),
                testCase.expectedCapacity
            )
        }
    }

    func testBridgePreservesRequested120HzWithoutImplicitDownscaleFor4KOverlay() {
        let configuration = Self.makeExplicitHDROverlayConfiguration()

        XCTAssertEqual(
            configuration.negotiatedDynamicRangeTransport,
            LumenMacDynamicRangeTransportSDRBaseHDROverlay
        )
        XCTAssertEqual(configuration.effectiveTargetFrameRate, 120)
        XCTAssertEqual(configuration.effectivePreprocessStrategy, .none)
        XCTAssertEqual(configuration.negotiatedQueueProfile, .q4)
        XCTAssertEqual(configuration.negotiatedQueueProfile.queueDepthHint, 4)
        XCTAssertEqual(configuration.forwardingQueueDepthReserve, 2)
        XCTAssertEqual(configuration.effectiveTargetFrameRate, 120)
        XCTAssertEqual(configuration.requestedWidth, 3512)
        XCTAssertEqual(configuration.requestedHeight, 2290)
        XCTAssertEqual(
            LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(
                for: configuration
            ),
            3
        )
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
            )
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
        let configuration = Self.makeDefaultHDROverlayConfiguration()

        XCTAssertEqual(
            configuration.lumenProtocolPresentationContract,
            .singleFrame
        )
        XCTAssertEqual(configuration.presentationContractName, "single-frame")
        XCTAssertEqual(configuration.presentationCompletionName, "full-frame")
    }

    func testMacProtocolAdapterMapsConfigurationToLumenProtocolSignals() {
        let adapter =
            Self.makeDefaultHDROverlayConfiguration().lumenProtocolAdapter

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
        let configuration = Self.makeEncoderInputHDROverlayConfiguration()

        XCTAssertEqual(configuration.effectiveEncoderInputStrategy, .yuv420v10)
        XCTAssertEqual(
            configuration.effectiveCapturePixelFormat,
            kCVPixelFormatType_32BGRA
        )
        XCTAssertEqual(
            configuration.effectiveCapturePixelFormat,
            kCVPixelFormatType_32BGRA
        )
        XCTAssertEqual(
            configuration.encodedHDRConfigurationSnapshot?.transferFunction,
            "smpteSt2084PQ"
        )
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .sdr
            )
        )

        XCTAssertFalse(configuration.usesHDRTransport)
        XCTAssertEqual(
            configuration.negotiatedDynamicRangeTransport,
            LumenMacDynamicRangeTransportSDR
        )
        XCTAssertFalse(configuration.prefersRealtimeHDRMetadata)
        XCTAssertEqual(
            configuration.effectiveCapturePixelFormat,
            kCVPixelFormatType_32BGRA
        )
        XCTAssertNil(configuration.encodedHDRConfigurationSnapshot)
    }
}

private extension LumenMacBridgePresentationTests {
    static func makeExplicitHDROverlayConfiguration()
        -> LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )
    }

    static func makeDefaultHDROverlayConfiguration()
        -> LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )
    }

    static func makeEncoderInputHDROverlayConfiguration()
        -> LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )
    }
}

private struct LumenForwardingCapacityTestCase {
    let queueProfile: LumenCaptureQueueProfile
    let targetFrameRate: Int
    let expectedCapacity: Int

    init(
        _ queueProfile: LumenCaptureQueueProfile,
        _ targetFrameRate: Int,
        _ expectedCapacity: Int
    ) {
        self.queueProfile = queueProfile
        self.targetFrameRate = targetFrameRate
        self.expectedCapacity = expectedCapacity
    }
}
