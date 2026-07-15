import CoreMedia
import Foundation
import Synchronization

public struct LumenBridgeVideoForwardingSnapshot: Equatable, Sendable {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let hasLastSampleBuffer: Bool
    public let lastFrameCodec: LumenCaptureCodec?
    public let lastFramePayloadSize: Int
    public let lastFrameSourceSequenceNumber: UInt64?
    public let lastFrameSourceDisplayTime: UInt64?
    public let lastFrameIsKeyFrame: Bool
    public let lastFrameIsHDRSignaled: Bool
    public let lastEventKind: LumenBridgeCaptureEventKind?
}

public struct LumenBridgeDrainedVideoFrame: Sendable {
    public let codec: LumenCaptureCodec
    public let payloadSize: Int
    public let sourceSequenceNumber: UInt64
    public let sourceDisplayTime: UInt64
    public let outputCallbackLatencyMilliseconds: Double?
    public let isKeyFrame: Bool
    public let isHDRSignaled: Bool
    public let isReplay: Bool
    private let sampleBufferHandle: LumenSampleBufferHandle

    public var sampleBuffer: CMSampleBuffer { sampleBufferHandle.value }

    init(
        codec: LumenCaptureCodec,
        payloadSize: Int,
        sourceSequenceNumber: UInt64,
        sourceDisplayTime: UInt64,
        outputCallbackLatencyMilliseconds: Double?,
        isKeyFrame: Bool,
        isHDRSignaled: Bool,
        isReplay: Bool,
        sampleBuffer: CMSampleBuffer
    ) {
        self.codec = codec
        self.payloadSize = payloadSize
        self.sourceSequenceNumber = sourceSequenceNumber
        self.sourceDisplayTime = sourceDisplayTime
        self.outputCallbackLatencyMilliseconds = outputCallbackLatencyMilliseconds
        self.isKeyFrame = isKeyFrame
        self.isHDRSignaled = isHDRSignaled
        self.isReplay = isReplay
        sampleBufferHandle = LumenSampleBufferHandle(retaining: sampleBuffer)
    }
}

public struct LumenBridgeDrainedVideoEvent: Equatable, Sendable {
    public let kind: LumenBridgeCaptureEventKind
    public let message: String?
    public let stopStatus: Int32?
    public let automaticRestartCount: UInt64?
    public let sourceDisplayTime: UInt64?
}

private struct LumenVideoIngressState: Sendable {
    var frames: [LumenBridgeDrainedVideoFrame] = []
    var events: [LumenBridgeDrainedVideoEvent] = []
    var frameCapacity = 3
    var eventCapacity = 64
    var frameCount: UInt64 = 0
    var eventCount: UInt64 = 0
    var droppedFrameCount: UInt64 = 0
    var droppedEventCount: UInt64 = 0
    var lastFrame: LumenBridgeDrainedVideoFrame?
    var lastEvent: LumenBridgeDrainedVideoEvent?
    var producerActive = false
}

/// Synchronous capture callbacks cannot hop to an actor without adding a frame of
/// latency. This bounded mutex is therefore intentionally limited to copying queue
/// metadata and retained sample-buffer handles at the VideoToolbox callback boundary.
final class LumenVideoCaptureForwarder: Sendable {
    private let state = Mutex(LumenVideoIngressState())

    func reset() {
        state.withLock { value in
            let frameCapacity = value.frameCapacity
            let eventCapacity = value.eventCapacity
            value = LumenVideoIngressState()
            value.frameCapacity = frameCapacity
            value.eventCapacity = eventCapacity
        }
    }

    func setFrameCapacity(_ capacity: Int) {
        state.withLock { value in
            value.frameCapacity = max(capacity, 1)
            trimOldest(&value.frames, capacity: value.frameCapacity) {
                value.droppedFrameCount &+= UInt64($0)
            }
        }
    }

    func setEventCapacity(_ capacity: Int) {
        state.withLock { value in
            value.eventCapacity = max(capacity, 1)
            trimOldest(&value.events, capacity: value.eventCapacity) {
                value.droppedEventCount &+= UInt64($0)
            }
        }
    }

    func setProducerActive(_ active: Bool) {
        state.withLock { $0.producerActive = active }
    }

    func snapshot() -> LumenBridgeVideoForwardingSnapshot {
        state.withLock { value in
            LumenBridgeVideoForwardingSnapshot(
                frameCount: value.frameCount,
                eventCount: value.eventCount,
                queuedFrameCount: UInt64(value.frames.count),
                queuedEventCount: UInt64(value.events.count),
                droppedFrameCount: value.droppedFrameCount,
                droppedEventCount: value.droppedEventCount,
                hasLastSampleBuffer: value.lastFrame != nil,
                lastFrameCodec: value.lastFrame?.codec,
                lastFramePayloadSize: value.lastFrame?.payloadSize ?? 0,
                lastFrameSourceSequenceNumber: value.lastFrame?.sourceSequenceNumber,
                lastFrameSourceDisplayTime: value.lastFrame?.sourceDisplayTime,
                lastFrameIsKeyFrame: value.lastFrame?.isKeyFrame ?? false,
                lastFrameIsHDRSignaled: value.lastFrame?.isHDRSignaled ?? false,
                lastEventKind: value.lastEvent?.kind
            )
        }
    }

    func consume(frame: LumenEncodedFrame) {
        consume(
            sampleBuffer: frame.sampleBuffer,
            codec: frame.codec,
            sourceSequenceNumber: frame.sourceSequenceNumber,
            sourceDisplayTime: frame.sourceDisplayTime,
            outputCallbackLatencyMilliseconds: frame.outputCallbackLatencyMilliseconds,
            isKeyFrame: frame.isKeyFrame,
            isHDRSignaled: frame.isHDRSignaled
        )
    }

    func consume(
        sampleBuffer: CMSampleBuffer,
        codec: LumenCaptureCodec,
        sourceSequenceNumber: UInt64,
        sourceDisplayTime: UInt64,
        outputCallbackLatencyMilliseconds: Double? = nil,
        isKeyFrame: Bool,
        isHDRSignaled: Bool,
        isReplay: Bool = false
    ) {
        let frame = LumenBridgeDrainedVideoFrame(
            codec: codec,
            payloadSize: sampleBuffer.totalSampleSize,
            sourceSequenceNumber: sourceSequenceNumber,
            sourceDisplayTime: sourceDisplayTime,
            outputCallbackLatencyMilliseconds: outputCallbackLatencyMilliseconds,
            isKeyFrame: isKeyFrame,
            isHDRSignaled: isHDRSignaled,
            isReplay: isReplay,
            sampleBuffer: sampleBuffer
        )
        state.withLock { value in
            value.frameCount &+= 1
            value.lastFrame = frame
            if value.frames.count >= value.frameCapacity {
                let droppedSourceDisplayTime = value.frames.first?.sourceDisplayTime
                value.droppedFrameCount &+= UInt64(value.frames.count)
                value.frames.removeAll(keepingCapacity: true)
                let overflowEvent = LumenBridgeDrainedVideoEvent(
                    kind: .droppedFrame,
                    message: "core-forwarder-overflow",
                    stopStatus: nil,
                    automaticRestartCount: nil,
                    sourceDisplayTime: droppedSourceDisplayTime
                )
                value.eventCount &+= 1
                value.lastEvent = overflowEvent
                if value.events.count >= value.eventCapacity {
                    value.events.removeFirst()
                    value.droppedEventCount &+= 1
                }
                value.events.append(overflowEvent)
            }
            value.frames.append(frame)
        }
    }

    func consume(event: LumenEncodedCaptureSessionEvent) {
        let event = LumenBridgeDrainedVideoEvent(
            kind: event.kind.bridgeKind,
            message: event.message,
            stopStatus: event.stopStatus,
            automaticRestartCount: event.automaticRestartCount,
            sourceDisplayTime: event.sourceDisplayTime
        )
        state.withLock { value in
            value.eventCount &+= 1
            value.lastEvent = event
            if value.events.count >= value.eventCapacity {
                value.events.removeFirst()
                value.droppedEventCount &+= 1
            }
            value.events.append(event)
        }
    }

    func popNextFrame() -> LumenBridgeDrainedVideoFrame? {
        state.withLock { value in
            guard !value.frames.isEmpty else { return nil }
            return value.frames.removeFirst()
        }
    }

    func popNextEvent() -> LumenBridgeDrainedVideoEvent? {
        state.withLock { value in
            guard !value.events.isEmpty else { return nil }
            return value.events.removeFirst()
        }
    }
}

private func trimOldest<Element>(
    _ values: inout [Element],
    capacity: Int,
    didDrop: (Int) -> Void
) {
    let overflow = max(values.count - capacity, 0)
    guard overflow > 0 else { return }
    values.removeFirst(overflow)
    didDrop(overflow)
}

private extension LumenEncodedCaptureSessionEventKind {
    var bridgeKind: LumenBridgeCaptureEventKind {
        switch self {
        case .started: .started
        case .stopped: .stopped
        case .restarted: .restarted
        case .failed: .failed
        case .droppedFrame: .droppedFrame
        case .coalescedFrame: .coalescedFrame
        }
    }
}
