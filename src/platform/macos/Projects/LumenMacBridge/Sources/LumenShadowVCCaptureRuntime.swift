import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import ShadowVCRuntime
import Synchronization

@available(macOS 27, *)
actor LumenShadowVCCaptureRuntime: LumenEncodedCaptureRuntime {
    private let context: LumenEncodedCaptureRuntimeContext
    private let modelDirectory: URL
    private var stream: SCStream?
    private var output: LumenShadowVCStreamOutput?
    private var consumer: Task<Void, Never>?
    private var encoder: ShadowVCEncoder?
    private var starting = false
    private var stopping = false
    private var nextFrameID: UInt32 = 0
    private var bootstrapEpoch: UInt64?
    private var statistics = LumenEncodedCaptureSessionStatistics()
    private nonisolated let epoch = Atomic<UInt64>(1)
    private nonisolated let acknowledged = Atomic(false)
    private nonisolated let repair = Atomic(false)

    init(context: LumenEncodedCaptureRuntimeContext, modelDirectory: URL) {
        self.context = context; self.modelDirectory = modelDirectory
    }
    func start() async throws {
        guard stream == nil, !starting, !stopping else { throw LumenExactCaptureError.invalidFormat("capture already started") }
        starting = true
        defer { starting = false }
        let configuration = context.configuration
        try configuration.validateExactVideoFormat()
        guard configuration.preprocessStrategy == .none,
              let width = configuration.requestedWidth, let height = configuration.requestedHeight else {
            throw LumenExactCaptureError.invalidFormat("ShadowVC requires explicit native dimensions")
        }
        let codecConfiguration = try ShadowVCConfiguration(width: width, height: height)
        // On macOS 27 CGDisplayPixelsWide/High may report logical HiDPI
        // dimensions. The selected mode owns the native backing contract.
        guard let mode = CGDisplayCopyDisplayMode(configuration.displayID),
              mode.pixelWidth == width, mode.pixelHeight == height else {
            throw LumenExactCaptureError.sourceContractMismatch("ShadowVC requires matching native capture pixels")
        }
        let generation = epoch.load(ordering: .acquiring)
        let encoder = try await ShadowVCEncoder(modelDirectory: modelDirectory, configuration: codecConfiguration)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard generation == epoch.load(ordering: .acquiring),
              let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
            throw LumenExactCaptureError.invalidFormat("capture display was retired")
        }
        let settings = SCStreamConfiguration()
        settings.width = width; settings.height = height
        settings.pixelFormat = kCVPixelFormatType_32BGRA
        settings.colorSpaceName = CGColorSpace.sRGB
        settings.captureDynamicRange = .SDR
        settings.minimumFrameInterval = CMTime(value: 1, timescale: Int32(configuration.targetFrameRate))
        settings.queueDepth = 3; settings.showsCursor = true
        let (frames, continuation) = AsyncStream<LumenShadowVCCapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = LumenShadowVCStreamOutput(continuation: continuation,
            currentEpoch: { [weak self] in self?.epoch.load(ordering: .acquiring) ?? 0 }, failed: context.terminationHandler)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: settings, delegate: output)
        // The system callback queue only yields into a bounded AsyncStream.
        // Mutable codec/lifecycle state remains on this actor.
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: nil)
        self.encoder = encoder; self.output = output; self.stream = stream
        consumer = Task { [weak self] in
            for await sample in frames {
                guard !Task.isCancelled else { break }
                await self?.consume(sample)
            }
        }
        do { try await stream.startCapture() }
        catch { await stop(); throw error }
        guard generation == epoch.load(ordering: .acquiring) else { await stop(); throw CancellationError() }
        statistics.isRunning = true
        context.statisticsHandler(statistics)
        context.callbacks.eventHandler?(.init(kind: .started, message: "ShadowVC Core AI capture started"))
    }
    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        _ = epoch.wrappingAdd(1, ordering: .acquiringAndReleasing)
        acknowledged.store(false, ordering: .releasing)
        let stream = self.stream; self.stream = nil
        output?.finish(); consumer?.cancel()
        let consumer = self.consumer; self.consumer = nil
        try? await stream?.stopCapture()
        await consumer?.value
        updateSourceStatistics()
        encoder = nil; output = nil; bootstrapEpoch = nil
        statistics.isRunning = false; context.statisticsHandler(statistics)
        context.callbacks.eventHandler?(.init(kind: .stopped))
    }
    nonisolated func resetMediaEpoch() {
        _ = epoch.wrappingAdd(1, ordering: .acquiringAndReleasing)
        acknowledged.store(false, ordering: .releasing)
    }
    nonisolated func requestImmediateKeyFrame() { repair.store(true, ordering: .releasing) }
    func requestPeriodicKeyFrame() async -> Bool { requestImmediateKeyFrame(); return true }
    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        guard stream != nil else { return false }
        acknowledged.store(true, ordering: .releasing); return true
    }
    private func consume(_ captured: LumenShadowVCCapturedFrame) async {
        let handle = captured.sample
        guard stream != nil, let encoder, let pixel = handle.value.imageBuffer else { return }
        let generation = epoch.load(ordering: .acquiring)
        guard captured.epoch == generation else { return }
        if bootstrapEpoch == generation && !acknowledged.load(ordering: .acquiring) { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(handle.value)
        guard timestamp.isValid, timestamp.isNumeric else { return }
        let begin = DispatchTime.now().uptimeNanoseconds
        let displayTime = LumenMachTime.ticks(for: timestamp) ?? mach_absolute_time()
        do {
            guard nextFrameID < UInt32.max else { throw ShadowVCError.invalidFrame }
            nextFrameID += 1
            let frameID = nextFrameID
            statistics.submittedFrameCount &+= 1
            let bytes = try await encoder.encode(.init(pixel), frameID: frameID)
            guard generation == epoch.load(ordering: .acquiring), stream != nil else { return }
            let sample = try Self.sample(bytes: bytes, width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel), timestamp: timestamp)
            let bootstrap = bootstrapEpoch != generation
            let isRepair = repair.exchange(false, ordering: .acquiringAndReleasing) && !bootstrap
            bootstrapEpoch = generation
            let latency = Double(DispatchTime.now().uptimeNanoseconds-begin)/1e6
            context.callbacks.frameHandler(.init(sampleBuffer: sample, codec: .shadowVC,
                sourceSequenceNumber: UInt64(frameID), sourceDisplayTime: displayTime,
                outputCallbackLatencyMilliseconds: latency, isKeyFrame: true,
                requiresBootstrapAcknowledgement: bootstrap, isRepairKeyFrame: isRepair,
                isHDRSignaled: false, hdrValidationReport: .init(colorPrimaries: nil, transferFunction: nil,
                    yCbCrMatrix: nil, hasHDRDisplayMetadata: false, hasContentLightLevelInfo: false)))
            statistics.emittedFrameCount &+= 1
            statistics.encodedByteCount &+= UInt64(bytes.count)
            statistics.minOutputCallbackLatencyMilliseconds = min(statistics.minOutputCallbackLatencyMilliseconds ?? latency, latency)
            statistics.maxOutputCallbackLatencyMilliseconds = max(statistics.maxOutputCallbackLatencyMilliseconds ?? latency, latency)
            if statistics.emittedFrameCount % 120 == 0 { updateSourceStatistics(); context.statisticsHandler(statistics) }
        } catch {
            guard generation == epoch.load(ordering: .acquiring), stream != nil else { return }
            statistics.processingFailureCount &+= 1; statistics.lastErrorDescription = String(describing: error)
            context.statisticsHandler(statistics)
            context.terminationHandler(error)
            output?.finish()
        }
    }
    private func updateSourceStatistics() {
        guard let output else { return }
        statistics.sourceFrameCount = output.completeFrames.load(ordering: .relaxed)
        statistics.completeSourceFrameCount = statistics.sourceFrameCount
        statistics.pendingAdmissionDropCount = output.droppedFrames.load(ordering: .relaxed)
        statistics.droppedFrameCount = statistics.pendingAdmissionDropCount
    }
    private static func sample(bytes: Data, width: Int, height: Int, timestamp: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw ShadowVCError.unavailable }
        let status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard status == noErr else { throw ShadowVCError.unavailable }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: 0x53435631,
            width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw ShadowVCError.unavailable }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var size = bytes.count; var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw ShadowVCError.unavailable }
        return sample
    }
}

private struct LumenShadowVCCapturedFrame: Sendable {
    let sample: LumenSampleBufferHandle
    let epoch: UInt64
}

private final class LumenShadowVCStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let continuation: AsyncStream<LumenShadowVCCapturedFrame>.Continuation
    let currentEpoch: @Sendable () -> UInt64
    let completeFrames = Atomic<UInt64>(0)
    let droppedFrames = Atomic<UInt64>(0)
    let failed: @Sendable (any Error) -> Void
    init(continuation: AsyncStream<LumenShadowVCCapturedFrame>.Continuation,
         currentEpoch: @escaping @Sendable () -> UInt64, failed: @escaping @Sendable (any Error) -> Void) {
        self.continuation = continuation; self.currentEpoch = currentEpoch; self.failed = failed
    }
    func finish() { continuation.finish() }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { failed(error); finish() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), sampleBuffer.imageBuffer != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        _ = completeFrames.wrappingAdd(1, ordering: .relaxed)
        if case .dropped = continuation.yield(.init(sample: LumenSampleBufferHandle(retaining: sampleBuffer), epoch: currentEpoch())) {
            _ = droppedFrames.wrappingAdd(1, ordering: .relaxed)
        }
    }
}
