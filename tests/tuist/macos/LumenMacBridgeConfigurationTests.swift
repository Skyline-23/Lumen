@testable import LumenMacBridge
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import XCTest

final class LumenMacBridgeConfigurationTests: XCTestCase {
    func testBridgeConfigurationBoxRoundTripsRequestedOutputAndHDR() {
        let hdrStaticMetadata = Self.makeHDRStaticMetadata()
        let configuration = Self.makeRoundTripConfiguration(
            hdrStaticMetadata: hdrStaticMetadata
        )

        let roundTrip = LumenBridgeConfigurationBox(
            configuration: configuration
        ).swiftValue
        XCTAssertEqual(roundTrip.displayID, 11)
        XCTAssertEqual(roundTrip.sessionEpoch, 42)
        XCTAssertEqual(roundTrip.policyRevision, 7)
        XCTAssertEqual(roundTrip.codec, .hevc)
        XCTAssertEqual(roundTrip.targetFrameRate, 120)
        XCTAssertEqual(roundTrip.targetVideoBitRateKbps, 41_000)
        XCTAssertEqual(roundTrip.requestedWidth, 3512)
        XCTAssertEqual(roundTrip.requestedHeight, 2290)
        XCTAssertTrue(roundTrip.usesHDRTransport)
        XCTAssertEqual(
            roundTrip.effectiveDisplayState.hdrStaticMetadata,
            hdrStaticMetadata
        )
        XCTAssertEqual(roundTrip.sinkRequest.capability.currentEDRHeadroom, 2.8)
        XCTAssertEqual(
            roundTrip.sinkRequest.capability.potentialEDRHeadroom,
            8.4
        )
        XCTAssertEqual(
            roundTrip.sinkRequest.capability.currentPeakLuminanceNits,
            800
        )
        XCTAssertEqual(
            roundTrip.sinkRequest.capability.potentialPeakLuminanceNits,
            1600
        )
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportFrameGatedHDR
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
        let imageBuffer = try Self.makeTenBitImageBuffer()
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )

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
        let imageBuffer = try Self.makeTenBitImageBuffer()
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_P3_D65,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )

        XCTAssertEqual(
            contract.mismatchDescription(for: imageBuffer),
            "primaries expected=ITU_R_2020 actual=P3_D65"
        )
    }

    func testHDRCaptureUsesSDRPreservingHDR10OutputContract() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip(
                "The SDR-preserving HDR10 ScreenCaptureKit preset requires macOS 26"
            )
        }

        let configuration = LumenCaptureStreamConfigurationFactory.make(
            usesHDRTransport: true
        )
        XCTAssertEqual(configuration.captureDynamicRange, .hdrCanonicalDisplay)
        XCTAssertEqual(
            configuration.pixelFormat,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            configuration.colorSpaceName as String,
            CGColorSpace.itur_2100_PQ as String
        )
        XCTAssertEqual(
            configuration.colorMatrix as String,
            kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        )
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportFrameGatedHDR
            )
        )

        XCTAssertEqual(
            unsupportedSink.negotiatedDynamicRangeTransport,
            LumenMacDynamicRangeTransportSDR
        )
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportSDRBaseHDROverlay
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportSDRBaseHDROverlay
            )
        )

        XCTAssertEqual(
            fallbackOverlay.negotiatedDynamicRangeTransport,
            LumenMacDynamicRangeTransportFrameGatedHDR
        )
        XCTAssertTrue(fallbackOverlay.usesHDRTransport)
        XCTAssertTrue(fallbackOverlay.prefersRealtimeHDRMetadata)
        XCTAssertEqual(fallbackOverlay.negotiatedQueueProfile, .q3)

        XCTAssertEqual(
            overlayRequestedSink.negotiatedDynamicRangeTransport,
            LumenMacDynamicRangeTransportSDRBaseHDROverlay
        )
        XCTAssertFalse(overlayRequestedSink.usesHDRTransport)
        XCTAssertTrue(overlayRequestedSink.prefersRealtimeHDRMetadata)
        XCTAssertEqual(overlayRequestedSink.negotiatedQueueProfile, .q4)
    }
}

private extension LumenMacBridgeConfigurationTests {
    static func makeHDRStaticMetadata() -> LumenHDRStaticMetadata {
        LumenHDRStaticMetadata(
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
    }

    static func makeRoundTripConfiguration(
        hdrStaticMetadata: LumenHDRStaticMetadata
    ) -> LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
            displayID: 11,
            sessionEpoch: 42,
            policyRevision: 7,
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
                dynamicRangeTransport:
                    LumenMacDynamicRangeTransportFrameGatedHDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq,
                hdrStaticMetadata: hdrStaticMetadata
            )
        )
    }

    static func makeTenBitImageBuffer() throws -> CVPixelBuffer {
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
        return try XCTUnwrap(pixelBuffer)
    }
}
