import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

struct LumenAudioFrame: Equatable, Sendable {
    let sequenceNumber: UInt64
    let hostTimeNanoseconds: UInt64
    let sampleRate: Int
    let channelCount: Int
    let frameCount: Int
    let pcmFloat32LE: Data
}

enum LumenAudioCaptureSessionEventKind: String, Equatable, Sendable {
    case started
    case stopped
    case restarted
    case failed
    case droppedFrame
}

struct LumenAudioCaptureSessionEvent: Equatable, Sendable {
    let kind: LumenAudioCaptureSessionEventKind
    let message: String?
    let stopStatus: Int32?
    let automaticRestartCount: UInt64?
    let sourceSequenceNumber: UInt64?

    init(
        kind: LumenAudioCaptureSessionEventKind,
        message: String? = nil,
        stopStatus: Int32? = nil,
        automaticRestartCount: UInt64? = nil,
        sourceSequenceNumber: UInt64? = nil
    ) {
        self.kind = kind
        self.message = message
        self.stopStatus = stopStatus
        self.automaticRestartCount = automaticRestartCount
        self.sourceSequenceNumber = sourceSequenceNumber
    }
}

struct LumenAudioCaptureCallbacks: Sendable {
    let frameHandler: @Sendable (LumenAudioFrame) -> Void
    let eventHandler: (@Sendable (LumenAudioCaptureSessionEvent) -> Void)?
}

private protocol LumenAudioCaptureRuntime: Sendable {
    func start() async throws
    func stop() async
}

private actor LumenSystemAudioCaptureRuntime: LumenAudioCaptureRuntime {
    private let configuration: LumenMacAudioCaptureConfiguration
    private let callbacks: LumenAudioCaptureCallbacks
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.sck.audio", qos: .userInteractive)
    private let output: LumenSystemAudioCaptureOutput
    private var stream: SCStream?

    init(configuration: LumenMacAudioCaptureConfiguration, callbacks: LumenAudioCaptureCallbacks) {
        self.configuration = configuration
        self.callbacks = callbacks
        output = LumenSystemAudioCaptureOutput(callbacks: callbacks)
    }

    func start() async throws {
        guard case .systemOutput(let displayID, let excludesCurrentProcessAudio) = configuration.source else {
            throw LumenAudioCaptureError.invalidSource
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { UInt32($0.displayID) == displayID }) else {
            throw LumenAudioCaptureError.displayUnavailable(displayID)
        }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = 2
        streamConfiguration.height = 2
        streamConfiguration.minimumFrameInterval = .zero
        streamConfiguration.queueDepth = 2
        streamConfiguration.capturesAudio = true
        streamConfiguration.sampleRate = configuration.sampleRate
        streamConfiguration.channelCount = configuration.channelCount
        streamConfiguration.excludesCurrentProcessAudio = excludesCurrentProcessAudio

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            try? stream.removeStreamOutput(output, type: .audio)
            if self.stream === stream {
                self.stream = nil
            }
            throw error
        }
        callbacks.eventHandler?(.init(kind: .started, message: "ScreenCaptureKit system audio capture started"))
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(output, type: .audio)
        if self.stream === stream {
            self.stream = nil
        }
        callbacks.eventHandler?(.init(kind: .stopped, message: "ScreenCaptureKit system audio capture stopped", stopStatus: 0))
    }

}

private final class LumenSystemAudioCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let callbacks: LumenAudioCaptureCallbacks
    private var sequenceNumber: UInt64 = 0

    init(callbacks: LumenAudioCaptureCallbacks) {
        self.callbacks = callbacks
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        do {
            sequenceNumber &+= 1
            callbacks.frameHandler(try makeAudioFrame(sequenceNumber: sequenceNumber, sampleBuffer: sampleBuffer))
        } catch {
            callbacks.eventHandler?(.init(kind: .droppedFrame, message: error.localizedDescription))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        callbacks.eventHandler?(.init(kind: .failed, message: error.localizedDescription))
    }
}

private final class LumenAudioSequenceCounter: Sendable {
    private let value = Mutex<UInt64>(0)

    func next() -> UInt64 {
        value.withLock { value in
            value &+= 1
            return value
        }
    }
}

private actor LumenMicrophoneCaptureRuntime: LumenAudioCaptureRuntime {
    private let configuration: LumenMacAudioCaptureConfiguration
    private let callbacks: LumenAudioCaptureCallbacks
    private let engine = AVAudioEngine()
    private let sequenceNumber = LumenAudioSequenceCounter()

    init(configuration: LumenMacAudioCaptureConfiguration, callbacks: LumenAudioCaptureCallbacks) {
        self.configuration = configuration
        self.callbacks = callbacks
    }

    func start() async throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LumenAudioCaptureError.microphoneUnavailable
        }
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(configuration.sampleRate),
            channels: AVAudioChannelCount(configuration.channelCount),
            interleaved: true
        )
        guard let outputFormat,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw LumenAudioCaptureError.audioConversionUnavailable
        }
        let callbacks = callbacks
        let sequenceNumber = sequenceNumber

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(configuration.frameSize), format: inputFormat) { buffer, time in
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            do {
                try converter.convert(to: converted, from: buffer)
            } catch {
                callbacks.eventHandler?(.init(kind: .droppedFrame, message: error.localizedDescription))
                return
            }
            guard let data = converted.interleavedFloat32Data else {
                callbacks.eventHandler?(.init(kind: .droppedFrame, message: "Converted audio has no interleaved Float32 payload"))
                return
            }
            let nextSequenceNumber = sequenceNumber.next()
            callbacks.frameHandler(
                LumenAudioFrame(
                    sequenceNumber: nextSequenceNumber,
                    hostTimeNanoseconds: time.hostTime == 0 ? systemUptimeNanoseconds() : AVAudioTime.seconds(forHostTime: time.hostTime).nanoseconds,
                    sampleRate: Int(outputFormat.sampleRate),
                    channelCount: Int(outputFormat.channelCount),
                    frameCount: Int(converted.frameLength),
                    pcmFloat32LE: data
                )
            )
        }
        try engine.start()
        callbacks.eventHandler?(.init(kind: .started, message: "AVAudioEngine microphone capture started"))
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        callbacks.eventHandler?(.init(kind: .stopped, message: "AVAudioEngine microphone capture stopped", stopStatus: 0))
    }
}

actor LumenAudioCaptureSession {
    let configuration: LumenMacAudioCaptureConfiguration
    private var runtime: (any LumenAudioCaptureRuntime)?

    init(configuration: LumenMacAudioCaptureConfiguration) {
        self.configuration = configuration
    }

    func start(callbacks: LumenAudioCaptureCallbacks) async throws {
        let runtime: any LumenAudioCaptureRuntime
        switch configuration.source {
        case .microphone:
            runtime = LumenMicrophoneCaptureRuntime(configuration: configuration, callbacks: callbacks)
        case .systemOutput:
            runtime = LumenSystemAudioCaptureRuntime(configuration: configuration, callbacks: callbacks)
        }
        self.runtime = runtime
        do {
            try await runtime.start()
        } catch {
            self.runtime = nil
            throw error
        }
    }

    func stop() async {
        guard let runtime else { return }
        self.runtime = nil
        await runtime.stop()
    }
}

private enum LumenAudioCaptureError: Error, LocalizedError {
    case invalidSource
    case displayUnavailable(UInt32)
    case microphoneUnavailable
    case audioConversionUnavailable
    case invalidSampleBuffer
    case unsupportedPCM

    var errorDescription: String? {
        switch self {
        case .invalidSource: return "Invalid audio capture source."
        case .displayUnavailable(let displayID): return "ScreenCaptureKit display \(displayID) is unavailable for audio capture."
        case .microphoneUnavailable: return "The default microphone is unavailable."
        case .audioConversionUnavailable: return "The requested microphone PCM conversion is unavailable."
        case .invalidSampleBuffer: return "The audio sample buffer is invalid."
        case .unsupportedPCM: return "The audio sample buffer uses an unsupported PCM layout."
        }
    }
}

private func makeAudioFrame(sequenceNumber: UInt64, sampleBuffer: CMSampleBuffer) throws -> LumenAudioFrame {
    guard let formatDescription = sampleBuffer.formatDescription,
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
        throw LumenAudioCaptureError.invalidSampleBuffer
    }
    let frameCount = sampleBuffer.numSamples
    let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)
    var retainedBlockBuffer: CMBlockBuffer?
    var bufferListSize = 0
    var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &bufferListSize,
        bufferListOut: nil,
        bufferListSize: 0,
        blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil,
        flags: 0,
        blockBufferOut: &retainedBlockBuffer
    )
    guard status == kCMSampleBufferError_ArrayTooSmall || status == noErr else {
        throw LumenAudioCaptureError.invalidSampleBuffer
    }
    let storage = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    let audioBufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: audioBufferList,
        bufferListSize: bufferListSize,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
        blockBufferOut: &retainedBlockBuffer
    )
    guard status == noErr else { throw LumenAudioCaptureError.invalidSampleBuffer }

    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let isFloat32 = streamDescription.mBitsPerChannel == 32 && (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    guard isFloat32 else { throw LumenAudioCaptureError.unsupportedPCM }
    let isNonInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    var data = Data(count: frameCount * channelCount * MemoryLayout<Float>.size)
    data.withUnsafeMutableBytes { output in
        let samples = output.bindMemory(to: Float.self)
        if !isNonInterleaved, let buffer = buffers.first, let source = buffer.mData {
            memcpy(output.baseAddress, source, min(output.count, Int(buffer.mDataByteSize)))
            return
        }
        for frame in 0..<frameCount {
            for channel in 0..<channelCount where channel < buffers.count {
                let source = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                samples[(frame * channelCount) + channel] = source[frame]
            }
        }
    }
    let pts = sampleBuffer.presentationTimeStamp
    let hostTime = pts.isValid && pts.seconds.isFinite ? max(pts.seconds, 0).nanoseconds : systemUptimeNanoseconds()
    return LumenAudioFrame(
        sequenceNumber: sequenceNumber,
        hostTimeNanoseconds: hostTime,
        sampleRate: Int(streamDescription.mSampleRate.rounded()),
        channelCount: channelCount,
        frameCount: frameCount,
        pcmFloat32LE: data
    )
}

private func systemUptimeNanoseconds() -> UInt64 {
    ProcessInfo.processInfo.systemUptime.nanoseconds
}

private extension Double {
    var nanoseconds: UInt64 { UInt64(max(self, 0) * 1_000_000_000) }
}

private extension AVAudioPCMBuffer {
    var interleavedFloat32Data: Data? {
        guard format.commonFormat == .pcmFormatFloat32,
              format.isInterleaved,
              let audioBuffer = mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        return Data(bytes: audioBuffer, count: Int(mutableAudioBufferList.pointee.mBuffers.mDataByteSize))
    }
}
