@testable import LumenMacBridge
import CoreMedia
import Foundation
import XCTest

final class LumenMacBridgeForwardingTests: XCTestCase {
    func testMediaEpochResetRetiresAwaitingBootstrapBeforeFreshControlledRequest() {
        var gate = LumenVideoBootstrapAdmissionGate()
        XCTAssertEqual(gate.admitSourceFrame(), .submitInitialKeyFrame)
        XCTAssertTrue(gate.isAwaitingAcknowledgement)

        gate.resetForMediaEpoch()
        XCTAssertFalse(gate.isAwaitingAcknowledgement)
        XCTAssertTrue(gate.isOpen)
        XCTAssertTrue(gate.beginBootstrapGeneration(reason: .repair))
        XCTAssertTrue(gate.isAwaitingAcknowledgement)
        XCTAssertEqual(gate.pendingReason, .repair)
    }

    func testBridgeForwardsSyntheticSampleBufferIntoSwiftIngress() async throws {
        let runtime = Self.makeBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        let sampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0xAA, 0xBB, 0xCC]),
            codecType: kCMVideoCodecType_HEVC,
            colorPrimaries:
                kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            transferFunction:
                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                as String,
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
        let runtime = Self.makeBridgeRuntime()
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

    func testMediaEpochResetDropsQueuedVideoUntilFreshBootstrap() async throws {
        let runtime = Self.makeBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        await runtime.configureVideoForwarding(frameCapacity: 2, eventCapacity: 2)

        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: try Self.makeEncodedSampleBuffer(
                payload: Data([0x01]),
                codecType: kCMVideoCodecType_HEVC
            ),
            codec: .hevc,
            sourceSequenceNumber: 1,
            sourceDisplayTime: 10,
            isKeyFrame: true,
            requiresBootstrapAcknowledgement: true,
            isHDRSignaled: false
        )
        await runtime.debugResetMediaQueues()

        let drainedAfterReset = await runtime.drainNextVideoForwardedFrame()
        XCTAssertNil(drainedAfterReset)

        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: try Self.makeEncodedSampleBuffer(
                payload: Data([0x02]),
                codecType: kCMVideoCodecType_HEVC
            ),
            codec: .hevc,
            sourceSequenceNumber: 2,
            sourceDisplayTime: 20,
            isKeyFrame: false,
            isHDRSignaled: false
        )
        let drainedDependent = await runtime.drainNextVideoForwardedFrame()
        XCTAssertNil(drainedDependent)

        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: try Self.makeEncodedSampleBuffer(
                payload: Data([0x03]),
                codecType: kCMVideoCodecType_HEVC
            ),
            codec: .hevc,
            sourceSequenceNumber: 3,
            sourceDisplayTime: 30,
            isKeyFrame: true,
            requiresBootstrapAcknowledgement: true,
            isRepairKeyFrame: true,
            isHDRSignaled: false
        )
        let freshFrame = await runtime.drainNextVideoForwardedFrame()
        let fresh = try XCTUnwrap(freshFrame)
        XCTAssertEqual(fresh.sourceSequenceNumber, 3)
        XCTAssertTrue(fresh.isKeyFrame)
        XCTAssertTrue(fresh.requiresBootstrapAcknowledgement)
    }

    func testAudioMediaEpochResetDropsQueuedFramesWithoutDisablingProducer() {
        let forwarder = LumenAudioCaptureForwarder()
        forwarder.setProducerActive(true)
        forwarder.consume(
            frame: LumenAudioFrame(
                sequenceNumber: 1,
                hostTimeNanoseconds: 10,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 240,
                pcmFloat32LE: Data(repeating: 0, count: 8)
            )
        )

        forwarder.resetForMediaEpoch()
        XCTAssertNil(forwarder.popNextFrame())

        forwarder.consume(
            frame: LumenAudioFrame(
                sequenceNumber: 2,
                hostTimeNanoseconds: 20,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 240,
                pcmFloat32LE: Data(repeating: 1, count: 8)
            )
        )
        XCTAssertEqual(forwarder.popNextFrame()?.sequenceNumber, 2)
    }

    func testBridgeForwardingDropsDependentsUntilRecoveryKeyFrame() async throws {
        let runtime = Self.makeBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        await runtime.configureVideoForwarding(frameCapacity: 1, eventCapacity: 2)

        for (sequence, keyFrame) in [
            (1, true),
            (2, false),
            (3, true),
            (4, true)
        ] {
            await runtime.debugForwardSyntheticFrame(
                sampleBuffer: try Self.makeEncodedSampleBuffer(
                    payload: Data([UInt8(sequence)]),
                    codecType: kCMVideoCodecType_HEVC
                ),
                codec: .hevc,
                sourceSequenceNumber: UInt64(sequence),
                sourceDisplayTime: UInt64(sequence * 10),
                isKeyFrame: keyFrame,
                requiresBootstrapAcknowledgement: sequence == 4,
                isRepairKeyFrame: sequence == 4,
                isHDRSignaled: true
            )
        }

        let recoveredFrame = await runtime.drainNextVideoForwardedFrame()
        let recovered = try XCTUnwrap(recoveredFrame)
        XCTAssertEqual(recovered.sourceSequenceNumber, 4)
        XCTAssertTrue(recovered.isKeyFrame)
        XCTAssertEqual(
            try Self.payloadBytes(from: recovered.sampleBuffer),
            Data([0x04])
        )

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

private extension LumenMacBridgeForwardingTests {
    static func makeBridgeRuntime() -> LumenBridgeRuntime {
        LumenBridgeRuntime(
            systemAudioPlaybackSuppression:
                LumenSystemAudioPlaybackSuppression(
                    hal:
                        LumenCoreAudioSystemAudioPlaybackSuppressionHAL()
                ),
            encodedCaptureRuntimeFactory:
                LumenProductionCaptureRuntimeFactory()
        )
    }

    static func makeEncodedSampleBuffer(
        payload: Data,
        codecType: CMVideoCodecType,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        notSync: Bool = false
    ) throws -> CMSampleBuffer {
        let bytes = [UInt8](payload)
        let blockBuffer = try makeBlockBuffer(bytes: bytes)
        let formatDescription = try makeFormatDescription(
            codecType: codecType,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction
        )
        let sampleBuffer = try makeSampleBuffer(
            blockBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleSize: bytes.count
        )
        if notSync {
            try markSampleNotSync(sampleBuffer)
        }
        return sampleBuffer
    }

    static func makeBlockBuffer(bytes: [UInt8]) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
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
        let unwrappedBlockBuffer = try XCTUnwrap(blockBuffer)

        let appendStatus = bytes.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: unwrappedBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        XCTAssertEqual(appendStatus, noErr)
        return unwrappedBlockBuffer
    }

    static func makeFormatDescription(
        codecType: CMVideoCodecType,
        colorPrimaries: String?,
        transferFunction: String?
    ) throws -> CMFormatDescription {
        var extensions: [CFString: Any] = [:]
        if let colorPrimaries {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] =
                colorPrimaries as CFString
        }
        if let transferFunction {
            extensions[kCMFormatDescriptionExtension_TransferFunction] =
                transferFunction as CFString
        }
        if transferFunction ==
            (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] =
                Data([0, 1, 0, 1]) as CFData
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
        return try XCTUnwrap(formatDescription)
    }

    static func makeSampleBuffer(
        blockBuffer: CMBlockBuffer,
        formatDescription: CMFormatDescription,
        sampleSize: Int
    ) throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: 1, timescale: 120),
            decodeTimeStamp: .invalid
        )
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: [timing],
                sampleSizeEntryCount: 1,
                sampleSizeArray: [sampleSize],
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    static func markSampleNotSync(_ sampleBuffer: CMSampleBuffer) throws {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) else {
            return XCTFail("Sample attachments were unavailable")
        }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(
                kCMSampleAttachmentKey_NotSync
            ).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    static func payloadBytes(from sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw NSError(
                domain: "LumenMacBridgeForwardingTests",
                code: 1
            )
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
