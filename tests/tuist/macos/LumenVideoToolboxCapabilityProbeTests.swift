import CoreMedia
import CoreVideo
@testable import LumenMacBridge
import VideoToolbox
import XCTest

private final class LumenVTCharacterizationCallbackBox {
    let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }
}

private let lumenVTCharacterizationCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    _,
    sampleBuffer in
    guard let outputCallbackRefCon else { return }
    let callback = Unmanaged<LumenVTCharacterizationCallbackBox>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    XCTAssertEqual(status, noErr)
    XCTAssertNotNil(sampleBuffer)
    callback.expectation.fulfill()
}

final class LumenVideoToolboxCapabilityProbeTests: XCTestCase {
    func testRequiredHardware420ProfilesRemainDiscoverable() throws {
        let h264Profiles = try supportedProfiles(codec: kCMVideoCodecType_H264)
        let hevcProfiles = try supportedProfiles(codec: kCMVideoCodecType_HEVC)

        XCTAssertTrue(h264Profiles.contains("H264_High_AutoLevel"))
        XCTAssertTrue(hevcProfiles.contains("HEVC_Main_AutoLevel"))
        XCTAssertTrue(hevcProfiles.contains("HEVC_Main10_AutoLevel"))
        XCTAssertFalse(h264Profiles.isEmpty)
        XCTAssertFalse(hevcProfiles.isEmpty)
    }

    func testRequiredHardware420OneFrameEncodeUsesHardware() throws {
        try characterizeOneFrameEncode(
            codec: kCMVideoCodecType_H264,
            profile: "H264_High_AutoLevel",
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        try characterizeOneFrameEncode(
            codec: kCMVideoCodecType_HEVC,
            profile: "HEVC_Main10_AutoLevel",
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
    }

    func test444ProfilesAreSelectedOnlyFromSupportedValues() {
        XCTAssertEqual(
            LumenVideoToolboxCapabilityProbe.discoveredProfile(
                containing: "High444Predictive",
                supportedProfiles: ["H264_High_AutoLevel", "H264_High444Predictive_AutoLevel"]
            ),
            "H264_High444Predictive_AutoLevel"
        )
        XCTAssertNil(
            LumenVideoToolboxCapabilityProbe.discoveredProfile(
                containing: "Main44410",
                supportedProfiles: ["HEVC_Main_AutoLevel", "HEVC_Main10_AutoLevel"]
            )
        )
    }

    func testCodecConfigurationParsersExtractExact444Contract() {
        let avcC = Data([1, 244, 0, 52])
        XCTAssertEqual(
            LumenVideoToolboxCodecConfigurationParser.parseAVCC(avcC)?.profileIdc,
            244
        )

        var hvcC = Data(repeating: 0, count: 23)
        hvcC[0] = 1
        hvcC[16] = 0xFC | 3
        hvcC[17] = 0xF8 | 2
        hvcC[18] = 0xF8 | 2
        let parsed = LumenVideoToolboxCodecConfigurationParser.parseHVCC(hvcC)
        XCTAssertEqual(parsed?.chromaFormatIdc, 3)
        XCTAssertEqual(parsed?.lumaBitDepth, 10)
        XCTAssertEqual(parsed?.chromaBitDepth, 10)

        XCTAssertNil(LumenVideoToolboxCodecConfigurationParser.parseAVCC(Data([1])))
        XCTAssertNil(LumenVideoToolboxCodecConfigurationParser.parseHVCC(Data(repeating: 0, count: 22)))
        XCTAssertNil(LumenVideoToolboxCodecConfigurationParser.parseHVCC(Data(repeating: 0, count: 23)))
    }

    func testSuccessfulStatusesDoNotAdvertiseSoftwareOrMalformedOutput() {
        let software = LumenVideoToolboxCapabilityProbe.assess(
            target: .hevcMain44410,
            statuses: .allSuccessful,
            hardwareUsed: false,
            parsedConfiguration: .hevc(chromaFormatIdc: 3, lumaBitDepth: 10, chromaBitDepth: 10)
        )
        XCTAssertFalse(software.advertised)
        XCTAssertEqual(software.rejectionReason, "hardware-encoder-not-used")

        let malformed = LumenVideoToolboxCapabilityProbe.assess(
            target: .h264High444Predictive,
            statuses: .allSuccessful,
            hardwareUsed: true,
            parsedConfiguration: nil
        )
        XCTAssertFalse(malformed.advertised)
        XCTAssertEqual(malformed.rejectionReason, "malformed-codec-configuration")
    }

    func testCacheInvalidatesForOSBuildOrHardwareIdentityOnly() async {
        let cache = LumenVideoToolboxCapabilityProbeCache()
        let counter = ProbeInvocationCounter()
        let firstEnvironment = LumenVideoToolboxProbeEnvironment(
            osBuild: "24A1",
            hardwareIdentity: "Mac-Test-A"
        )
        let newOS = LumenVideoToolboxProbeEnvironment(
            osBuild: "24A2",
            hardwareIdentity: "Mac-Test-A"
        )
        let newHardware = LumenVideoToolboxProbeEnvironment(
            osBuild: "24A2",
            hardwareIdentity: "Mac-Test-B"
        )

        _ = await cache.rows(for: firstEnvironment) {
            await counter.increment()
            return []
        }
        _ = await cache.rows(for: firstEnvironment) {
            XCTFail("same environment should reuse cache")
            return []
        }
        _ = await cache.rows(for: newOS) {
            await counter.increment()
            return []
        }
        _ = await cache.rows(for: newHardware) {
            await counter.increment()
            return []
        }

        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 3)
    }

    func testCacheDoesNotRetainFailedProbe() async {
        let cache = LumenVideoToolboxCapabilityProbeCache()
        let counter = ProbeInvocationCounter()
        let environment = LumenVideoToolboxProbeEnvironment(
            osBuild: "24A1",
            hardwareIdentity: "Mac-Test-A"
        )

        do {
            _ = try await cache.rows(for: environment) {
                await counter.increment()
                throw ProbeFailure.synthetic
            }
            XCTFail("failed probes must throw")
        } catch ProbeFailure.synthetic {
            // Expected. Failed and interrupted probes must not poison the cache.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        _ = await cache.rows(for: environment) {
            await counter.increment()
            return []
        }

        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 2)
    }

    func testCurrentHardware444ProbeWritesAuditArtifactWhenRequested() async throws {
        guard let artifactPath = ProcessInfo.processInfo.environment["LUMEN_VT444_ARTIFACT_PATH"] else {
            throw XCTSkip("Set LUMEN_VT444_ARTIFACT_PATH for the real hardware probe")
        }

        let auditRows = await LumenVideoToolboxCapabilityProbe.auditRequiredHardware444(timeout: 5)
        try LumenVideoToolboxCapabilityProbe.writeArtifact(
            auditRows,
            to: URL(fileURLWithPath: artifactPath)
        )
        XCTAssertEqual(auditRows.count, 3)
        XCTAssertFalse(auditRows.filter(\.advertised).isEmpty)
    }

    private func supportedProfiles(codec: CMVideoCodecType) throws -> [String] {
        var encoderID: CFString?
        var supportedProperties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 192,
            height: 108,
            codecType: codec,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &supportedProperties
        )
        XCTAssertEqual(status, noErr)
        XCTAssertNotNil(encoderID)
        guard status == noErr,
              let properties = supportedProperties as? [CFString: Any],
              let profile = properties[kVTCompressionPropertyKey_ProfileLevel] as? [CFString: Any],
              let values = profile[kVTPropertySupportedValueListKey] as? [String] else {
            throw CharacterizationError.missingSupportedProfiles
        }
        return values
    }

    private func characterizeOneFrameEncode(
        codec: CMVideoCodecType,
        profile: String,
        pixelFormat: OSType
    ) throws {
        let expectation = expectation(description: "VideoToolbox callback for \(profile)")
        let callback = LumenVTCharacterizationCallbackBox(expectation: expectation)
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: 192,
            kCVPixelBufferHeightKey: 108,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 192,
            height: 108,
            codecType: codec,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: lumenVTCharacterizationCallback,
            refcon: Unmanaged.passUnretained(callback).toOpaque(),
            compressionSessionOut: &session
        )
        XCTAssertEqual(createStatus, noErr)
        guard createStatus == noErr, let session else {
            throw CharacterizationError.sessionCreationFailed(createStatus)
        }
        defer { VTCompressionSessionInvalidate(session) }

        XCTAssertEqual(
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: profile as CFString
            ),
            noErr
        )
        XCTAssertEqual(
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse
            ),
            noErr
        )
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        XCTAssertEqual(prepareStatus, noErr)

        var hardwareValue: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &hardwareValue) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        XCTAssertEqual(hardwareStatus, noErr)
        XCTAssertEqual(hardwareValue as? Bool, true)

        var pixelBuffer: CVPixelBuffer?
        let pixelBufferStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            192,
            108,
            pixelFormat,
            imageAttributes as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(pixelBufferStatus, kCVReturnSuccess)
        guard let pixelBuffer else {
            throw CharacterizationError.pixelBufferCreationFailed(pixelBufferStatus)
        }

        var infoFlags: VTEncodeInfoFlags = []
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true
            ] as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        XCTAssertEqual(encodeStatus, noErr)
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        wait(for: [expectation], timeout: 5)
    }

    private enum CharacterizationError: Error {
        case missingSupportedProfiles
        case sessionCreationFailed(OSStatus)
        case pixelBufferCreationFailed(CVReturn)
    }
}

private actor ProbeInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private enum ProbeFailure: Error {
    case synthetic
}
