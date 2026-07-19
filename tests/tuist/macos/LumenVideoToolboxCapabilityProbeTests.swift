import CoreMedia
import CoreVideo
import Foundation
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

/// VideoToolbox enters this test helper through a C callback. A private serial
/// queue owns the retained sample list; production coordination remains actor based.
private final class LumenVTReferenceChainCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.tests.vt-reference-chain")
    private let signal = DispatchSemaphore(value: 0)
    private var samples: [CMSampleBuffer] = []

    func append(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else { return }
        queue.sync { samples.append(sampleBuffer) }
        signal.signal()
    }

    func waitForSamples(_ count: Int, timeout: TimeInterval) -> [CMSampleBuffer] {
        let deadline = DispatchTime.now() + timeout
        while queue.sync(execute: { samples.count }) < count {
            if signal.wait(timeout: deadline) == .timedOut { break }
        }
        return queue.sync { samples }
    }
}

private let lumenVTReferenceChainCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    _,
    sampleBuffer in
    guard let outputCallbackRefCon else { return }
    Unmanaged<LumenVTReferenceChainCollector>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
        .append(status: status, sampleBuffer: sampleBuffer)
}

private final class LumenVTDecodeStatusCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.tests.vt-decode-status")
    private var statuses: [OSStatus] = []

    func append(_ status: OSStatus) {
        queue.sync { statuses.append(status) }
    }

    var values: [OSStatus] { queue.sync { statuses } }
}

final class LumenVideoToolboxCapabilityProbeTests: XCTestCase {
    func testMain10ReferenceChainRemainsDecodableWhenAdmissionWaitsForCodecAck() throws {
        let width = 3_512
        let height = 2_420
        let collector = LumenVTReferenceChainCollector()
        let session = try makeMain10CompressionSession(
            width: width,
            height: height,
            collector: collector
        )
        defer { VTCompressionSessionInvalidate(session) }

        let first = try makeMain10PixelBuffer(width: width, height: height, luma: 128)
        try encode(
            first,
            session: session,
            timestamp: .zero,
            forceKeyFrame: true
        )
        XCTAssertEqual(
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .zero),
            noErr
        )
        XCTAssertEqual(collector.waitForSamples(1, timeout: 5).count, 1)

        // This is the codec-ack wait: no additional frame is admitted to VT,
        // so the hardware encoder cannot advance a hidden reference chain.
        let second = try makeMain10PixelBuffer(width: width, height: height, luma: 256)
        let third = try makeMain10PixelBuffer(width: width, height: height, luma: 384)
        try encode(second, session: session, timestamp: CMTime(value: 1, timescale: 120))
        try encode(third, session: session, timestamp: CMTime(value: 2, timescale: 120))
        XCTAssertEqual(
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid),
            noErr
        )
        let samples = collector.waitForSamples(3, timeout: 10)
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(isKeyFrame(samples[0]))
        XCTAssertFalse(isKeyFrame(samples[1]))
        XCTAssertFalse(isKeyFrame(samples[2]))
        try assertHardwareDecode(samples)
        let artifactDirectory = try writeReferenceChainArtifactsIfRequested(samples)
        try assertSerializedReferenceChainHardwareDecode(at: artifactDirectory)
    }

    func testPeriodicMain10KeyFrameStartsAnIndependentHardwareDecodableGOP() throws {
        let width = 3_512
        let height = 2_420
        let collector = LumenVTReferenceChainCollector()
        let session = try makeMain10CompressionSession(
            width: width,
            height: height,
            collector: collector,
            maximumKeyFrameInterval: 3
        )
        defer { VTCompressionSessionInvalidate(session) }

        for frameIndex in 0 ..< 6 {
            let frame = try makeMain10PixelBuffer(
                width: width,
                height: height,
                luma: UInt16(128 + frameIndex * 64)
            )
            try encode(
                frame,
                session: session,
                timestamp: CMTime(value: CMTimeValue(frameIndex), timescale: 120),
                forceKeyFrame: frameIndex == 0
            )
        }
        XCTAssertEqual(
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid),
            noErr
        )
        let samples = collector.waitForSamples(6, timeout: 15)
        XCTAssertEqual(samples.count, 6)
        let periodicKeyFrameIndex = try XCTUnwrap(
            samples.indices.dropFirst().first(where: { isKeyFrame(samples[$0]) })
        )
        XCTAssertLessThanOrEqual(periodicKeyFrameIndex + 2, samples.count - 1)

        let recoveryChain = Array(samples[periodicKeyFrameIndex ... periodicKeyFrameIndex + 2])
        XCTAssertTrue(isKeyFrame(recoveryChain[0]))
        XCTAssertFalse(isKeyFrame(recoveryChain[1]))
        XCTAssertFalse(isKeyFrame(recoveryChain[2]))
        try assertHardwareDecode(recoveryChain)
    }

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

    private func makeMain10CompressionSession(
        width: Int,
        height: Int,
        collector: LumenVTReferenceChainCollector,
        maximumKeyFrameInterval: Int = 120
    ) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: lumenVTReferenceChainCallback,
            refcon: Unmanaged.passUnretained(collector).toOpaque(),
            compressionSessionOut: &session
        )
        XCTAssertEqual(status, noErr)
        let resolved = try XCTUnwrap(session)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_RealTime, value: true as CFBoolean), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_AllowFrameReordering, value: false as CFBoolean), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_AllowOpenGOP, value: false as CFBoolean), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 120 as CFNumber), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: maximumKeyFrameInterval as CFNumber), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_AverageBitRate, value: 20_000_000 as CFNumber), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_ProfileLevel, value: "HEVC_Main10_AutoLevel" as CFString), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCMFormatDescriptionColorPrimaries_ITU_R_2020), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_TransferFunction, value: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ), noErr)
        XCTAssertEqual(VTSessionSetProperty(resolved, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020), noErr)
        XCTAssertEqual(VTCompressionSessionPrepareToEncodeFrames(resolved), noErr)
        return resolved
    }

    private func makeMain10PixelBuffer(width: Int, height: Int, luma: UInt16) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let resolved = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(resolved, [])
        defer { CVPixelBufferUnlockBaseAddress(resolved, []) }
        fillPlane(resolved, plane: 0, value: luma << 6)
        fillPlane(resolved, plane: 1, value: 512 << 6)
        CVBufferSetAttachment(resolved, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(resolved, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(resolved, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return resolved
    }

    private func fillPlane(_ pixelBuffer: CVPixelBuffer, plane: Int, value: UInt16) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { return }
        let count = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) / MemoryLayout<UInt16>.size
        base.assumingMemoryBound(to: UInt16.self).update(repeating: value, count: count)
    }

    private func encode(
        _ pixelBuffer: CVPixelBuffer,
        session: VTCompressionSession,
        timestamp: CMTime,
        forceKeyFrame: Bool = false
    ) throws {
        let properties = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        XCTAssertEqual(
            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: timestamp,
                duration: CMTime(value: 1, timescale: 120),
                frameProperties: properties,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            ),
            noErr
        )
    }

    private func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        return (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private func assertHardwareDecode(_ samples: [CMSampleBuffer]) throws {
        let format = try XCTUnwrap(samples.first.flatMap(CMSampleBufferGetFormatDescription))
        let statuses = LumenVTDecodeStatusCollector()
        var session: VTDecompressionSession?
        XCTAssertEqual(
            VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: format,
                decoderSpecification: [
                    kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
                ] as CFDictionary,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &session
            ),
            noErr
        )
        let resolved = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(resolved) }
        for sample in samples {
            XCTAssertEqual(
                VTDecompressionSessionDecodeFrame(
                    resolved,
                    sampleBuffer: sample,
                    flags: [._EnableAsynchronousDecompression],
                    infoFlagsOut: nil,
                    completionHandler: { status, _, _, _, _, _ in
                        statuses.append(status)
                    }
                ),
                noErr
            )
        }
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(resolved), noErr)
        XCTAssertEqual(statuses.values, Array(repeating: noErr, count: samples.count))
    }

    private func writeReferenceChainArtifactsIfRequested(_ samples: [CMSampleBuffer]) throws -> URL {
        let path = ProcessInfo.processInfo.environment["LUMEN_CODEC_ACK_REFERENCE_ARTIFACT_DIR"]
            ?? "/tmp/LumenCodecAckReferenceChain-latest"
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, sample) in samples.enumerated() {
            let data = try sampleData(sample)
            try data.write(to: directory.appendingPathComponent("frame-\(index + 1).bin"), options: .atomic)
        }
        let format = try XCTUnwrap(samples.first.flatMap(CMSampleBufferGetFormatDescription))
        let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any]
        let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any]
        let hvcC = try XCTUnwrap(atoms?["hvcC"] as? Data)
        try hvcC.write(to: directory.appendingPathComponent("configuration.hvcc"), options: .atomic)
        try annexBStream(samples: samples, format: format)
            .write(to: directory.appendingPathComponent("stream.hevc"), options: .atomic)
        return directory
    }

    private func assertSerializedReferenceChainHardwareDecode(at directory: URL) throws {
        let hvcC = try Data(contentsOf: directory.appendingPathComponent("configuration.hvcc"))
        let frames = try (1 ... 3).map { index in
            try Data(contentsOf: directory.appendingPathComponent("frame-\(index).bin"))
        }
        XCTAssertGreaterThan(hvcC.count, 23)
        XCTAssertEqual(frames.count, 3)

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3_512,
            height: 2_420,
            extensions: [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["hvcC": hvcC],
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
                kCMFormatDescriptionExtension_FullRangeVideo: false
            ] as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(formatStatus, noErr)
        let format = try XCTUnwrap(formatDescription)

        let samples = try frames.enumerated().map { index, frame in
            try makeSerializedSampleBuffer(
                data: frame,
                format: format,
                frameIndex: index,
                isKeyFrame: index == 0
            )
        }
        let statuses = LumenVTDecodeStatusCollector()
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferWidthKey: 3_512,
                kCVPixelBufferHeightKey: 2_420,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        XCTAssertEqual(createStatus, noErr)
        let resolved = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(resolved) }

        var hardwareValue: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &hardwareValue) { pointer in
            VTSessionCopyProperty(
                resolved,
                key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        XCTAssertEqual(hardwareStatus, noErr)
        let hardwareAccelerated = hardwareValue as? Bool == true
        XCTAssertTrue(hardwareAccelerated)

        for sample in samples {
            XCTAssertEqual(
                VTDecompressionSessionDecodeFrame(
                    resolved,
                    sampleBuffer: sample,
                    flags: [._EnableAsynchronousDecompression],
                    infoFlagsOut: nil,
                    completionHandler: { status, _, imageBuffer, _, _, _ in
                        XCTAssertNotNil(imageBuffer)
                        statuses.append(status)
                    }
                ),
                noErr
            )
        }
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(resolved), noErr)
        let callbackStatuses = statuses.values
        XCTAssertEqual(callbackStatuses, [noErr, noErr, noErr])

        let proof = try JSONSerialization.data(
            withJSONObject: [
                "codec": "hevc",
                "profile": "main10",
                "chroma": "yuv420",
                "bitDepth": 10,
                "dynamicRange": "hdr10",
                "colorRange": "limited",
                "width": 3_512,
                "height": 2_420,
                "frameRate": 120,
                "hvcCBytes": hvcC.count,
                "frameBytes": frames.map(\.count),
                "hardwareDecoder": hardwareAccelerated,
                "callbackStatuses": callbackStatuses
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try proof.write(
            to: directory.appendingPathComponent("mac-hardware-decode-proof.json"),
            options: .atomic
        )
        print(
            "serialized-hardware-decode-passed hardware=\(hardwareAccelerated) "
                + "callbacks=\(callbackStatuses) frame-bytes=\(frames.map(\.count))"
        )
    }

    private func makeSerializedSampleBuffer(
        data: Data,
        format: CMVideoFormatDescription,
        frameIndex: Int,
        isKeyFrame: Bool
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let resolvedBlock = try XCTUnwrap(blockBuffer)
        let copyStatus = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: resolvedBlock,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        XCTAssertEqual(copyStatus, kCMBlockBufferNoErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: 120),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: resolvedBlock,
                formatDescription: format,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        let resolvedSample = try XCTUnwrap(sampleBuffer)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(
            resolvedSample,
            createIfNecessary: true
        ))
        let attachment = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        let dependencyValue = isKeyFrame ? kCFBooleanFalse! : kCFBooleanTrue!
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(dependencyValue).toOpaque()
        )
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
            Unmanaged.passUnretained(dependencyValue).toOpaque()
        )
        return resolvedSample
    }

    private func sampleData(_ sample: CMSampleBuffer) throws -> Data {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        return data
    }

    private func annexBStream(
        samples: [CMSampleBuffer],
        format: CMFormatDescription
    ) throws -> Data {
        var output = Data()
        var count = 0
        var headerLength: Int32 = 0
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        XCTAssertEqual(
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &headerLength
            ),
            noErr
        )
        for index in 0 ..< count {
            XCTAssertEqual(
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                ),
                noErr
            )
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(pointer!, count: size)
        }
        XCTAssertEqual(headerLength, 4)
        for sample in samples {
            let data = try sampleData(sample)
            var offset = 0
            while offset < data.count {
                let length = data[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                offset += 4
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(data[offset ..< offset + length])
                offset += length
            }
        }
        return output
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
