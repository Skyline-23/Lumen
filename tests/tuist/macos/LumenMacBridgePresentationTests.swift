@testable import LumenMacBridge
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import XCTest

final class LumenMacBridgePresentationTests: XCTestCase {
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

    func testSuccessfulOutputStatisticsPublicationIsBoundedAndTerminalFlushIsFresh() {
        var policy = LumenEncodedCaptureStatisticsPublicationPolicy()
        var statistics = LumenEncodedCaptureSessionStatistics()
        var publicationCount = 0
        var publishedOutputCounts: [UInt64] = []
        var deliveredFrameCount: UInt64 = 0

        if policy.shouldPublish(reason: .immediate, atUptimeNanoseconds: 0) {
            publishedOutputCounts.append(statistics.emittedFrameCount)
        }
        for output in 1...1_000 {
            statistics.emittedFrameCount = UInt64(output)
            deliveredFrameCount &+= 1
            if policy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 1
            ) {
                publicationCount += 1
                publishedOutputCounts.append(statistics.emittedFrameCount)
            }
        }

        XCTAssertEqual(deliveredFrameCount, 1_000)
        XCTAssertEqual(publicationCount, 8)
        XCTAssertEqual(
            Array(publishedOutputCounts.dropFirst()),
            [120, 240, 360, 480, 600, 720, 840, 960]
        )
        XCTAssertNotEqual(publishedOutputCounts.last, statistics.emittedFrameCount)

        if policy.shouldPublish(reason: .terminal, atUptimeNanoseconds: 2) {
            publishedOutputCounts.append(statistics.emittedFrameCount)
        }

        XCTAssertEqual(publishedOutputCounts.last, 1_000)
    }

    func testForcedStatisticsPublicationFlushesPendingSuccessfulOutputCounters() {
        var policy = LumenEncodedCaptureStatisticsPublicationPolicy()
        var statistics = LumenEncodedCaptureSessionStatistics()
        var publishedOutputCounts: [UInt64] = []
        if policy.shouldPublish(reason: .immediate, atUptimeNanoseconds: 0) {
            publishedOutputCounts.append(statistics.emittedFrameCount)
        }

        for output in 1...7 {
            statistics.emittedFrameCount = UInt64(output)
            XCTAssertFalse(
                policy.shouldPublish(
                    reason: .highRateUpdate,
                    atUptimeNanoseconds: 1
                )
            )
        }

        if policy.shouldPublish(reason: .forced, atUptimeNanoseconds: 2) {
            publishedOutputCounts.append(statistics.emittedFrameCount)
        }
        XCTAssertEqual(publishedOutputCounts.last, 7)
    }

    func testSuccessfulOutputStatisticsPublicationHonorsTimeBoundary() {
        var policy = LumenEncodedCaptureStatisticsPublicationPolicy(
            configuration: .init(
                minimumIntervalNanoseconds: 250,
                maximumHighRateUpdates: 120
            )
        )

        XCTAssertTrue(
            policy.shouldPublish(
                reason: .immediate,
                atUptimeNanoseconds: 0
            )
        )
        XCTAssertFalse(
            policy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 249
            )
        )
        XCTAssertTrue(
            policy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 250
            )
        )
    }

    func testDropEventPublicationIsIndependentFromOutputStatistics() {
        let configuration =
            LumenEncodedCaptureStatisticsPublicationPolicy.Configuration(
                minimumIntervalNanoseconds: 250,
                maximumHighRateUpdates: 3
            )
        var outputPolicy = LumenEncodedCaptureStatisticsPublicationPolicy(
            configuration: configuration
        )
        var dropEventPolicy = LumenEncodedCaptureStatisticsPublicationPolicy(
            configuration: configuration
        )

        XCTAssertTrue(
            outputPolicy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 0
            )
        )
        XCTAssertTrue(
            dropEventPolicy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 1
            )
        )
        XCTAssertFalse(
            dropEventPolicy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 2
            )
        )
        XCTAssertFalse(
            dropEventPolicy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 3
            )
        )
        XCTAssertTrue(
            dropEventPolicy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 4
            )
        )
        XCTAssertTrue(
            dropEventPolicy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 254
            )
        )
        XCTAssertTrue(
            dropEventPolicy.shouldPublish(
                reason: .terminal,
                atUptimeNanoseconds: 255
            )
        )
        XCTAssertFalse(
            dropEventPolicy.shouldPublish(
                reason: .highRateUpdate,
                atUptimeNanoseconds: 256
            )
        )
    }

    func testStatisticsNotesRefreshGatePublishesEachBoundaryOnce() {
        var gate = LumenEncodedCaptureStatisticsNotesRefreshGate()

        XCTAssertFalse(gate.shouldRefresh(sourceFrameCount: 0))
        XCTAssertTrue(gate.shouldRefresh(sourceFrameCount: 1))
        XCTAssertFalse(gate.shouldRefresh(sourceFrameCount: 1))
        XCTAssertFalse(gate.shouldRefresh(sourceFrameCount: 119))
        XCTAssertTrue(gate.shouldRefresh(sourceFrameCount: 120))
        XCTAssertFalse(gate.shouldRefresh(sourceFrameCount: 120))
        XCTAssertFalse(gate.shouldRefresh(sourceFrameCount: 121))
        XCTAssertTrue(gate.shouldRefresh(sourceFrameCount: 240))
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
        XCTAssertEqual(configuration.negotiatedQueueProfile, .q3)
        XCTAssertEqual(configuration.negotiatedQueueProfile.queueDepthHint, 3)
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
