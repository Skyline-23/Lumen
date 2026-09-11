import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import ShadowVC3Encoder
import ShadowVCRuntime
import Synchronization

actor LumenShadowVCCaptureRuntime: LumenEncodedCaptureRuntime, LumenShadowVCCaptureSignals {
    private let context: LumenEncodedCaptureRuntimeContext
    private let modelDirectory: URL?
    private let contentCadence: LumenUnchangedContentCadenceController
    private var contentPacer: LumenAdaptiveVideoFramePacer
    private var stream: SCStream?
    private var output: LumenShadowVCStreamOutput?
    private var consumer: Task<Void, Never>?
    private var encoder: Codec?
    private var starting = false
    private var stopping = false
    private var nextFrameID: UInt32 = 0
    private var bootstrapEpoch: UInt64?
    private var statistics = LumenEncodedCaptureSessionStatistics()
    private var totalEncodeMilliseconds = 0.0
    private var lastStatisticsUptimeNanoseconds: UInt64 = 0
    private var downstreamAdmissionDropCount: UInt64 = 0
    private var pixelCadence = LumenPixelFrameCadence()
    private var acceptedPixelWake: UInt64 = 0
    private nonisolated let pixelWakeRequest = Atomic<UInt64>(0)
    private nonisolated let epoch = Atomic<UInt64>(1)
    private nonisolated let acknowledged = Atomic(false)
    private nonisolated let repair = Atomic(false)
    private nonisolated let periodic = Atomic(false)
    private nonisolated let cadenceWakeEpoch = Atomic<UInt64>(0)
    private nonisolated let cadenceActive = Atomic(false)

    private enum Codec {
        case spatial(ShadowVCEncoder)
        case regional(ShadowVC4Encoder)
        case luma16(ShadowVC3Encoder)
        case pixel10(LumenPixelCaptureCodec)
        func encode(
            _ pixel: ShadowVCPixelBuffer, frameID: UInt32, forceKeyframe: Bool, recoveringReference: Bool
        ) async throws -> (bytes: Data, keyframe: Bool, prepared: Bool, hasPixelChanges: Bool) {
            switch self {
            case .pixel10(let codec):
                return try await codec.encode(pixel, frameID: frameID, forceKeyframe: forceKeyframe)
            case .spatial(let encoder):
                return (try await encoder.encode(pixel, frameID: frameID), true, false, true)
            case .regional(let encoder):
                let frame = try await encoder.encode(pixel, frameID: frameID, forceKeyframe: forceKeyframe)
                return (frame.serialized(), frame.isKeyframe, false, true)
            case .luma16(let encoder):
                let packet = try await encoder.preparePacket(
                    pixel, frameID: frameID, forceKeyframe: forceKeyframe,
                    recoveringReference: recoveringReference)
                if packet.isKeyframe || recoveringReference {
                    // Reliable bootstraps already pause admission through ACK.
                    try await encoder.resolvePreparedPacket(frameID: frameID, accepted: true)
                }
                return (
                    packet.data, packet.isKeyframe || recoveringReference,
                    !(packet.isKeyframe || recoveringReference), true
                )
            }
        }
        func retainAcknowledgedReference() async throws {
            if case .luma16(let encoder) = self { try await encoder.retainAcknowledgedReference() }
            if case .pixel10(let codec) = self { try await codec.encoder.retainAcknowledgedReference() }
        }
        func resolve(frameID: UInt32, accepted: Bool) async throws {
            if case .pixel10(let codec) = self {
                try await codec.encoder.resolve(generation: frameID, accepted: accepted)
                return
            }
            guard case .luma16(let encoder) = self else { return }
            try await encoder.resolvePreparedPacket(frameID: frameID, accepted: accepted)
        }
    }
    init(
        context: LumenEncodedCaptureRuntimeContext, modelDirectory: URL?,
        contentCadence: LumenUnchangedContentCadenceController
    ) {
        self.context = context
        self.modelDirectory = modelDirectory
        self.contentCadence = contentCadence
        contentPacer = LumenAdaptiveVideoFramePacer(frameRateCeiling: context.configuration.targetFrameRate)
    }
    func start() async throws {
        guard stream == nil, !starting, !stopping else {
            throw LumenExactCaptureError.invalidFormat("capture already started")
        }
        starting = true
        defer { starting = false }
        cadenceWakeEpoch.store(0, ordering: .releasing)
        pixelCadence = LumenPixelFrameCadence()
        acceptedPixelWake = pixelWakeRequest.load(ordering: .acquiring)
        repair.store(false, ordering: .releasing)
        periodic.store(false, ordering: .releasing)
        let configuration = context.configuration
        try configuration.validateExactVideoFormat()
        guard configuration.preprocessStrategy == .none,
            let width = configuration.requestedWidth, let height = configuration.requestedHeight
        else {
            throw LumenExactCaptureError.invalidFormat("ShadowVC requires explicit native dimensions")
        }
        // On macOS 27 CGDisplayPixelsWide/High may report logical HiDPI
        // dimensions. The selected mode owns the native backing contract.
        guard let mode = CGDisplayCopyDisplayMode(configuration.displayID),
            mode.pixelWidth == width, mode.pixelHeight == height
        else {
            throw LumenExactCaptureError.sourceContractMismatch(
                "ShadowVC requires matching native capture pixels")
        }
        let generation = epoch.load(ordering: .acquiring)
        let encoder: Codec
        if configuration.videoProfile == .shadowVCPixel10 {
            encoder = .pixel10(
                try await LumenPixelCaptureCodec.load(
                    width: width, height: height, hdr: configuration.dynamicRange == .hdr10))
        } else if configuration.videoProfile == .shadowVCLuma16 {
            encoder = .luma16(
                try await ShadowVC3Encoder(
                    configuration: .init(
                        width: width, height: height,
                        dynamicRange: configuration.dynamicRange == .hdr10 ? .hdr10 : .sdr)))
        } else if configuration.videoProfile == .shadowVCRegionalPredictor8 {
            // Bound input error to two 8-bit plane codes while reducing the
            // cost of moving text. SCV2 reconstructs these input codes exactly.
            encoder = .regional(
                try ShadowVC4Encoder(
                    configuration: .init(width: width, height: height),
                    sourceQuantizationStep: 4
                ))
        } else {
            guard configuration.videoProfile == .shadowVCSpatialBase16, let modelDirectory else {
                throw LumenExactCaptureError.invalidFormat(
                    "ShadowVC spatial profile requires its model bundle")
            }
            encoder = .spatial(
                try await ShadowVCEncoder(
                    modelDirectory: modelDirectory, configuration: .init(width: width, height: height)))
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard generation == epoch.load(ordering: .acquiring),
            let display = content.displays.first(where: { $0.displayID == configuration.displayID })
        else {
            throw LumenExactCaptureError.invalidFormat("capture display was retired")
        }
        let settings = LumenCaptureStreamConfigurationFactory.make(
            usesHDRTransport: configuration.dynamicRange == .hdr10)
        settings.width = width
        settings.height = height
        if configuration.dynamicRange == .sdr {
            settings.pixelFormat = kCVPixelFormatType_32BGRA
            settings.colorSpaceName = CGColorSpace.sRGB
            settings.captureDynamicRange = .SDR
        }
        // A nominal 1/120 threshold can skip alternating 120 Hz samples when
        // the compositor interval falls slightly below that rational value.
        // Native cadence avoids that aliasing without exceeding the request
        // when the selected display itself is at or below the requested rate.
        settings.minimumFrameInterval =
            mode.refreshRate > 0
                && mode.refreshRate <= Double(configuration.targetFrameRate)
            ? .zero : CMTime(value: 1, timescale: Int32(configuration.targetFrameRate))
        settings.queueDepth = 3
        settings.showsCursor = true
        let (frames, continuation) = AsyncThrowingStream<LumenShadowVCCapturedFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let output = LumenShadowVCStreamOutput(
            continuation: continuation,
            contentCadence: contentCadence,
            signals: self)
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []), configuration: settings,
            delegate: output)
        // The system callback queue only yields into a bounded AsyncStream.
        // Mutable codec/lifecycle state remains on this actor.
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: nil)
        self.encoder = encoder
        self.output = output
        self.stream = stream
        // Capture conversion and the native plane tasks serve an interactive
        // stream; inherit this priority through the encoder's task group.
        consumer = Task(priority: .userInitiated) { [weak self] in
            do {
                for try await sample in frames {
                    guard !Task.isCancelled else { break }
                    await self?.consume(sample)
                }
            } catch {
                await self?.captureFailed(error, epoch: generation)
            }
        }
        do { try await stream.startCapture() } catch {
            await stop()
            throw error
        }
        guard generation == epoch.load(ordering: .acquiring) else {
            await stop()
            throw CancellationError()
        }
        cadenceActive.store(true, ordering: .releasing)
        statistics.isRunning = true
        context.statisticsHandler(statistics)
        let identity =
            configuration.videoProfile == .shadowVCLuma16
            ? " checkpoint=\(ShadowVC3Configuration.checkpointSHA256) analysis=\(ShadowVC3Models.selectedAnalysisRoute)"
            : ""
        context.callbacks.eventHandler?(
            .init(
                kind: .started,
                message:
                    "ShadowVC capture started profile=\(configuration.videoProfile) range=\(configuration.dynamicRange)\(identity)"
            ))
    }
    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        cadenceActive.store(false, ordering: .releasing)
        _ = epoch.wrappingAdd(1, ordering: .acquiringAndReleasing)
        acknowledged.store(false, ordering: .releasing)
        cadenceWakeEpoch.store(0, ordering: .releasing)
        let stream = self.stream
        self.stream = nil
        output?.finish()
        consumer?.cancel()
        let consumer = self.consumer
        self.consumer = nil
        try? await stream?.stopCapture()
        await consumer?.value
        updateSourceStatistics()
        encoder = nil
        output = nil
        bootstrapEpoch = nil
        statistics.isRunning = false
        context.statisticsHandler(statistics)
        context.callbacks.eventHandler?(.init(kind: .stopped))
    }
    nonisolated func currentCaptureEpoch() -> UInt64 {
        epoch.load(ordering: .acquiring)
    }

    nonisolated func capturePipelineIsStable() -> Bool {
        acknowledged.load(ordering: .acquiring)
            && !repair.load(ordering: .acquiring)
            && !periodic.load(ordering: .acquiring)
    }

    nonisolated func takeCaptureWakeRequest(epoch: UInt64) -> Bool {
        cadenceWakeEpoch.exchange(0, ordering: .acquiringAndReleasing) == epoch
    }

    private func captureFailed(_ error: any Error, epoch generation: UInt64) {
        guard !Task.isCancelled, stream != nil,
            generation == epoch.load(ordering: .acquiring)
        else { return }
        statistics.processingFailureCount &+= 1
        statistics.lastErrorDescription = String(describing: error)
        context.statisticsHandler(statistics)
        context.terminationHandler(error)
    }

    nonisolated func resetMediaEpoch() {
        _ = epoch.wrappingAdd(1, ordering: .acquiringAndReleasing)
        acknowledged.store(false, ordering: .releasing)
    }
    nonisolated func requestImmediateKeyFrame() { repair.store(true, ordering: .releasing) }
    nonisolated func wakeUnchangedContentCadence(sessionEpoch: UInt32) -> Bool {
        guard sessionEpoch == context.configuration.sessionEpoch,
            cadenceActive.load(ordering: .acquiring)
        else { return false }
        // The existing SCK callback applies the coalesced wake before observing
        // the next sample. Input never waits for inference or creates a task.
        cadenceWakeEpoch.store(epoch.load(ordering: .acquiring), ordering: .releasing)
        _ = pixelWakeRequest.wrappingAdd(1, ordering: .acquiringAndReleasing)
        return true
    }
    func requestPeriodicKeyFrame() async -> Bool {
        periodic.store(true, ordering: .releasing)
        return true
    }
    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        guard stream != nil, let encoder else { return false }
        let generation = epoch.load(ordering: .acquiring)
        do { try await encoder.retainAcknowledgedReference() } catch { return false }
        guard stream != nil, generation == epoch.load(ordering: .acquiring) else { return false }
        acknowledged.store(true, ordering: .releasing)
        return true
    }
    private func consume(_ captured: LumenShadowVCCapturedFrame) async {
        let handle = captured.sample
        guard stream != nil, let encoder, let pixel = handle.value.imageBuffer else { return }
        let generation = epoch.load(ordering: .acquiring)
        guard captured.epoch == generation else { return }
        if bootstrapEpoch == generation && !acknowledged.load(ordering: .acquiring) { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(handle.value)
        guard timestamp.isValid, timestamp.isNumeric else { return }
        let target = contentCadence.targetFrameRate ?? context.configuration.targetFrameRate
        if contentPacer.targetFrameRate != target {
            _ = contentPacer.configure(targetFrameRate: target)
        }
        statistics.adaptiveTargetFrameRate = target
        // Only unchanged content is throttled. A wake/damage callback restores
        // native cadence before admission; bootstrap and repair also bypass it.
        if target < context.configuration.targetFrameRate,
            bootstrapEpoch == generation, !repair.load(ordering: .acquiring),
            !periodic.load(ordering: .acquiring),
            !contentPacer.admit(sourcePresentationTime: timestamp, forceKeyFrame: false).isAdmitted
        {
            statistics.intentionalFrameCadenceDropCount &+= 1
            return
        }
        // Discard raw samples under downstream pressure, before encoding can
        // advance the predictive reference. Dropping an encoded P frame would
        // invalidate every following frame and force an expensive repair.
        guard context.callbacks.canAcceptFrame() else {
            downstreamAdmissionDropCount &+= 1
            return
        }
        let begin = DispatchTime.now().uptimeNanoseconds
        let displayTime = LumenMachTime.ticks(for: timestamp) ?? mach_absolute_time()
        var preparedFrameID: UInt32?
        do {
            let hdr = context.configuration.dynamicRange == .hdr10
            if hdr {
                let contract = try LumenExactCaptureSourceContract(
                    configuration: context.configuration,
                    width: context.configuration.requestedWidth!,
                    height: context.configuration.requestedHeight!)
                if let mismatch = contract.mismatchDescription(
                    for: pixel, formatDescription: CMSampleBufferGetFormatDescription(handle.value))
                {
                    throw LumenExactCaptureError.sourceContractMismatch(mismatch)
                }
            }
            guard nextFrameID < UInt32.max else { throw ShadowVCError.invalidFrame }
            let frameID = nextFrameID + 1
            statistics.submittedFrameCount &+= 1
            let bootstrap = bootstrapEpoch != generation
            let requestedRepair = repair.exchange(false, ordering: .acquiringAndReleasing)
            let requestedPeriodic = periodic.exchange(false, ordering: .acquiringAndReleasing)
            let referenceRecovery =
                !bootstrap && !requestedPeriodic && requestedRepair
                && context.configuration.videoProfile == .shadowVCLuma16
            let encoded = try await encoder.encode(
                .init(pixel), frameID: frameID,
                forceKeyframe: bootstrap || requestedPeriodic || (requestedRepair && !referenceRecovery),
                recoveringReference: referenceRecovery)
            preparedFrameID = encoded.prepared ? frameID : nil
            guard generation == epoch.load(ordering: .acquiring), stream != nil else {
                if encoded.prepared { try await encoder.resolve(frameID: frameID, accepted: false) }
                return
            }
            let usesPixelCadence = context.configuration.videoProfile == .shadowVCPixel10
            let sourceTimeSeconds = CMTimeGetSeconds(timestamp)
            let pixelWake = pixelWakeRequest.load(ordering: .acquiring)
            if usesPixelCadence,
                !pixelCadence.shouldEmit(
                    hasPixelChanges: encoded.hasPixelChanges,
                    forceRefresh: bootstrap || requestedRepair || requestedPeriodic || pixelWake != acceptedPixelWake,
                    sourceTimeSeconds: sourceTimeSeconds)
            {
                // A suppressed duplicate must not advance either endpoint's
                // predictive generation. Actual damage is still checked on
                // every admitted source sample and can be sent immediately.
                if encoded.prepared { try await encoder.resolve(frameID: frameID, accepted: false) }
                preparedFrameID = nil
                statistics.intentionalFrameCadenceDropCount &+= 1
                return
            }
            if usesPixelCadence, !encoded.hasPixelChanges {
                statistics.adaptiveTargetFrameRate = 1
            }
            if !encoded.prepared { nextFrameID = frameID }
            let receipt =
                encoded.prepared
                ? LumenPreparedVideoReceipt(
                    sessionEpoch: context.configuration.sessionEpoch, frameID: frameID) : nil
            let bytes = encoded.bytes
            let predictive = context.configuration.videoProfile != .shadowVCSpatialBase16
            let subtype: FourCharCode =
                context.configuration.videoProfile == .shadowVCPixel10
                ? 0x4643_5033
                : context.configuration.videoProfile == .shadowVCLuma16
                    ? 0x5343_5633
                    : predictive ? 0x5343_5632 : 0x5343_5631
            let sample = try Self.sample(
                bytes: bytes, width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel),
                timestamp: timestamp, subtype: subtype)
            let isRepair = requestedRepair && !bootstrap
            let requiresAcknowledgement = bootstrap || (predictive && (isRepair || requestedPeriodic))
            // Pause before publishing a predictive-profile repair. No later P
            // frame may evict the independent repair from a bounded host queue.
            if requiresAcknowledgement { acknowledged.store(false, ordering: .releasing) }
            bootstrapEpoch = generation
            var latency = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6
            context.callbacks.frameHandler(
                .init(
                    sampleBuffer: sample, codec: .shadowVC,
                    sourceSequenceNumber: UInt64(frameID), sourceDisplayTime: displayTime,
                    outputCallbackLatencyMilliseconds: latency, isKeyFrame: encoded.keyframe,
                    requiresBootstrapAcknowledgement: requiresAcknowledgement, isRepairKeyFrame: isRepair,
                    isHDRSignaled: hdr,
                    hdrValidationReport: .init(
                        colorPrimaries: hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 as String : nil,
                        transferFunction: hdr
                            ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String : nil,
                        yCbCrMatrix: hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 as String : nil,
                        hasHDRDisplayMetadata: false, hasContentLightLevelInfo: false),
                    preparedReceipt: receipt))
            // Count every produced packet, including a later zero-wire reject.
            statistics.emittedFrameCount &+= 1
            statistics.encodedByteCount &+= UInt64(bytes.count)
            if let receipt {
                let accepted = await receipt.wait()
                let commitBegin = DispatchTime.now().uptimeNanoseconds
                try await encoder.resolve(frameID: frameID, accepted: accepted)
                latency += Double(DispatchTime.now().uptimeNanoseconds - commitBegin) / 1e6
                preparedFrameID = nil
                guard generation == epoch.load(ordering: .acquiring), stream != nil else { return }
                if accepted {
                    nextFrameID = frameID
                    if usesPixelCadence {
                        pixelCadence.recordEmission(sourceTimeSeconds: sourceTimeSeconds)
                        acceptedPixelWake = pixelWake
                    }
                } else {
                    downstreamAdmissionDropCount &+= 1
                }
            } else if usesPixelCadence {
                pixelCadence.recordEmission(sourceTimeSeconds: sourceTimeSeconds)
                acceptedPixelWake = pixelWake
            }
            totalEncodeMilliseconds += latency
            statistics.minOutputCallbackLatencyMilliseconds = min(
                statistics.minOutputCallbackLatencyMilliseconds ?? latency, latency)
            statistics.maxOutputCallbackLatencyMilliseconds = max(
                statistics.maxOutputCallbackLatencyMilliseconds ?? latency, latency)
            if statistics.emittedFrameCount == 1 || statistics.emittedFrameCount % 120 == 0
                || begin - lastStatisticsUptimeNanoseconds >= 1_000_000_000
            {
                lastStatisticsUptimeNanoseconds = begin
                updateSourceStatistics()
                context.statisticsHandler(statistics)
                let message =
                    "Lumen ShadowVC stage=capture-totals profile=\(context.configuration.videoProfile) source=\(statistics.sourceFrameCount) emitted=\(statistics.emittedFrameCount) admission-drops=\(statistics.pendingAdmissionDropCount) bytes=\(statistics.encodedByteCount) encode-total-ms=\(totalEncodeMilliseconds) last-frame-id=\(frameID) uptime-ns=\(DispatchTime.now().uptimeNanoseconds) cadence-target=\(statistics.adaptiveTargetFrameRate) cadence-drops=\(statistics.intentionalFrameCadenceDropCount) idle-callbacks=\(output?.idleFrames.load(ordering: .relaxed) ?? 0)\n"
                try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            }
        } catch {
            if let preparedFrameID { try? await encoder.resolve(frameID: preparedFrameID, accepted: false) }
            guard generation == epoch.load(ordering: .acquiring), stream != nil else { return }
            statistics.processingFailureCount &+= 1
            statistics.lastErrorDescription = String(describing: error)
            context.statisticsHandler(statistics)
            context.terminationHandler(error)
            output?.finish()
        }
    }
    private func updateSourceStatistics() {
        guard let output else { return }
        statistics.sourceFrameCount = output.completeFrames.load(ordering: .relaxed)
        statistics.completeSourceFrameCount = statistics.sourceFrameCount
        statistics.pendingAdmissionDropCount =
            output.droppedFrames.load(ordering: .relaxed)
            &+ downstreamAdmissionDropCount
        statistics.droppedFrameCount = statistics.pendingAdmissionDropCount
    }
    private static func sample(bytes: Data, width: Int, height: Int, timestamp: CMTime, subtype: FourCharCode)
        throws -> CMSampleBuffer
    {
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes.count,
                flags: 0, blockBufferOut: &block) == noErr, let block
        else { throw ShadowVCError.unavailable }
        let status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw ShadowVCError.unavailable }
        var format: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: subtype,
                width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &format)
                == noErr, let format
        else { throw ShadowVCError.unavailable }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample
        else { throw ShadowVCError.unavailable }
        return sample
    }
}
