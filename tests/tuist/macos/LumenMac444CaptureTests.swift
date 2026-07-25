import CoreGraphics
import CoreMedia
import CoreVideo
@testable import LumenMacBridge
import XCTest

final class LumenMac444CaptureTests: XCTestCase {
    func testBridgeConfigurationRoundTripsExact444Plan() {
        let configuration = makeConfiguration(
            codec: .hevc,
            profile: .hevcMain44410,
            bitDepth: 10,
            dynamicRange: .hdr10,
            colorRange: .limited
        )

        let roundTrip = LumenBridgeConfigurationBox(configuration: configuration).swiftValue

        XCTAssertEqual(roundTrip.videoProfile, .hevcMain44410)
        XCTAssertEqual(roundTrip.chromaSubsampling, .yuv444)
        XCTAssertEqual(roundTrip.bitDepth, 10)
        XCTAssertEqual(roundTrip.dynamicRange, .hdr10)
        XCTAssertEqual(roundTrip.colorRange, .limited)
    }

    func testExact444PlansSelectDirectScreenCaptureKitFormats() {
        let h264 = makeConfiguration(codec: .h264, profile: .h264High444Predictive)
        let hevc = makeConfiguration(codec: .hevc, profile: .hevcMain444)
        let hevc10 = makeConfiguration(
            codec: .hevc,
            profile: .hevcMain44410,
            bitDepth: 10,
            dynamicRange: .hdr10,
            colorRange: .limited
        )

        XCTAssertEqual(h264.effectiveCapturePixelFormat, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(hevc.effectiveCapturePixelFormat, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(hevc10.effectiveCapturePixelFormat, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        let streamConfiguration = LumenCaptureStreamConfigurationFactory.make(configuration: hevc10)
        XCTAssertEqual(streamConfiguration.pixelFormat, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        XCTAssertEqual(streamConfiguration.captureDynamicRange, .hdrCanonicalDisplay)
        XCTAssertTrue(streamConfiguration.showsCursor)
    }

    func test444EncodingPlanUsesOnlyRuntimeProbedHardwareProfile() throws {
        let configuration = makeConfiguration(
            codec: .hevc,
            profile: .hevcMain44410,
            bitDepth: 10,
            dynamicRange: .hdr10,
            colorRange: .limited
        )

        let plan = try LumenVideoToolboxEncodingPlanResolver.resolve(
            configuration: configuration,
            availableHardware444Profiles: [
                .hevcMain44410: "HEVC_Main44410_AutoLevel"
            ]
        )

        XCTAssertEqual(plan.profile, "HEVC_Main44410_AutoLevel")
        XCTAssertEqual(plan.pixelFormat, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        XCTAssertEqual(plan.expectedConfiguration, .hevc(chromaFormatIdc: 3, lumaBitDepth: 10, chromaBitDepth: 10))
        XCTAssertThrowsError(
            try LumenVideoToolboxEncodingPlanResolver.resolve(
                configuration: configuration,
                availableHardware444Profiles: [:]
            )
        ) { error in
            XCTAssertEqual(error as? LumenExactCaptureError, .requiredHardwareProfileUnavailable(.hevcMain44410))
        }
    }

    func test444SourceContractRequiresFullResolutionPlanesAndColorAttachments() throws {
        let configuration = makeConfiguration(codec: .h264, profile: .h264High444Predictive)
        let contract = try LumenExactCaptureSourceContract(
            configuration: configuration,
            width: 16,
            height: 12
        )
        let buffer = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            width: 16,
            height: 12
        )
        attachSDRColor(to: buffer)

        XCTAssertNil(contract.mismatchDescription(for: buffer))
        XCTAssertEqual(CVPixelBufferGetWidthOfPlane(buffer, 1), 16)
        XCTAssertEqual(CVPixelBufferGetHeightOfPlane(buffer, 1), 12)

        let unexpected420 = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            width: 16,
            height: 12
        )
        attachSDRColor(to: unexpected420)
        XCTAssertEqual(
            contract.mismatchDescription(for: unexpected420),
            "pixel-format expected=444f actual=x420"
        )

        let hdrContract = try LumenExactCaptureSourceContract(
            configuration: makeConfiguration(
                codec: .hevc,
                profile: .hevcMain44410,
                bitDepth: 10,
                dynamicRange: .hdr10,
                colorRange: .limited
            ),
            width: 16,
            height: 12
        )
        let missingHDRAttachments = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
            width: 16,
            height: 12
        )
        XCTAssertEqual(
            hdrContract.mismatchDescription(for: missingHDRAttachments),
            "primaries expected=ITU_R_2020 actual=missing"
        )
    }

    func testEncodedOutputContractRejectsMismatchedAVCCAndHVCC() throws {
        let h264 = try LumenExactEncodedOutputContract(
            configuration: makeConfiguration(codec: .h264, profile: .h264High444Predictive)
        )
        XCTAssertNil(h264.mismatchDescription(codecConfigurationData: Data([1, 244, 0, 52])))
        XCTAssertEqual(
            h264.mismatchDescription(codecConfigurationData: Data([1, 100, 0, 52])),
            "AVC profile expected=244 actual=100"
        )

        let hevc = try LumenExactEncodedOutputContract(
            configuration: makeConfiguration(
                codec: .hevc,
                profile: .hevcMain44410,
                bitDepth: 10,
                dynamicRange: .hdr10,
                colorRange: .limited
            )
        )
        XCTAssertNil(hevc.mismatchDescription(codecConfigurationData: hvcc(chroma: 3, depth: 10)))
        XCTAssertEqual(
            hevc.mismatchDescription(codecConfigurationData: hvcc(chroma: 1, depth: 10)),
            "HEVC configuration expected=chroma:3/luma:10/chroma-depth:10 actual=chroma:1/luma:10/chroma-depth:10"
        )
    }

    func testFirstEncodedFrameGateRejectsStaleGenerationAndTimesOut() async throws {
        let gate = LumenFirstEncodedFrameGate()
        let staleGeneration = await gate.beginCapture()
        let activeGeneration = await gate.beginCapture()
        await gate.resolve(generation: staleGeneration)

        do {
            try await gate.wait(for: activeGeneration, timeoutNanoseconds: 5_000_000)
            XCTFail("stale output must not satisfy the active capture")
        } catch {
            XCTAssertEqual(error as? LumenFirstEncodedFrameReadinessError, .timedOut)
        }

        let successfulGeneration = await gate.beginCapture()
        await gate.resolve(generation: successfulGeneration)
        try await gate.wait(for: successfulGeneration, timeoutNanoseconds: 5_000_000)
    }

    private func makeConfiguration(
        codec: LumenCaptureCodec,
        profile: LumenCaptureVideoProfile,
        bitDepth: Int = 8,
        dynamicRange: LumenCaptureDynamicRange = .sdr,
        colorRange: LumenCaptureColorRange = .full,
        targetFrameRate: Int = 120
    ) -> LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
            displayID: CGMainDisplayID(),
            codec: codec,
            videoProfile: profile,
            chromaSubsampling: .yuv444,
            bitDepth: bitDepth,
            dynamicRange: dynamicRange,
            colorRange: colorRange,
            targetFrameRate: targetFrameRate,
            targetVideoBitRateKbps: 20_000,
            requestedWidth: 192,
            requestedHeight: 108,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: dynamicRange == .hdr10 ? .rec2020 : .srgb,
                    transfer: dynamicRange == .hdr10 ? .pq : .sdr,
                    supportsFrameGatedHDR: dynamicRange == .hdr10,
                    supportsPerFrameHDRMetadata: dynamicRange == .hdr10
                ),
                dynamicRangeTransport: dynamicRange == .hdr10
                    ? LumenMacDynamicRangeTransportFullFrameHDR
                    : LumenMacDynamicRangeTransportSDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: dynamicRange == .hdr10 ? .rec2020 : .srgb,
                transfer: dynamicRange == .hdr10 ? .pq : .sdr
            )
        )
    }

    private func makePixelBuffer(
        pixelFormat: OSType,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                pixelFormat,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        return try XCTUnwrap(pixelBuffer)
    }

    private func attachSDRColor(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }

    private func hvcc(chroma: UInt8, depth: UInt8) -> Data {
        var data = Data(repeating: 0, count: 23)
        data[0] = 1
        data[16] = 0xFC | chroma
        data[17] = 0xF8 | (depth - 8)
        data[18] = 0xF8 | (depth - 8)
        return data
    }
}
