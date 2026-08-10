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
    public let requiresBootstrapAcknowledgement: Bool
    public let isRepairKeyFrame: Bool
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
        requiresBootstrapAcknowledgement: Bool,
        isRepairKeyFrame: Bool,
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
        self.requiresBootstrapAcknowledgement = requiresBootstrapAcknowledgement
        self.isRepairKeyFrame = isRepairKeyFrame
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
    var frames = LumenFixedCapacityRingBuffer<LumenBridgeDrainedVideoFrame>(
        capacity: 3
    )
    var events = LumenFixedCapacityRingBuffer<LumenBridgeDrainedVideoEvent>(
        capacity: 64
    )
    var frameCount: UInt64 = 0
    var eventCount: UInt64 = 0
    var droppedFrameCount: UInt64 = 0
    var droppedEventCount: UInt64 = 0
    var awaitingRecoveryKeyFrame = false
    var lastFrame: LumenBridgeDrainedVideoFrame?
    var lastEvent: LumenBridgeDrainedVideoEvent?
    var producerActive = false
}

enum LumenVideoForwardingAdmission: Equatable, Sendable {
    case queued
    case recoveryKeyFrameRequired
    case waitingForRecoveryKeyFrame
    case recoveredAtKeyFrame
}

/// Synchronous capture callbacks cannot hop to an actor without adding a frame of
/// latency. This bounded mutex is therefore intentionally limited to copying queue
/// metadata and retained sample-buffer handles at the VideoToolbox callback boundary.
final class LumenVideoCaptureForwarder: Sendable {
    private let state = Mutex(LumenVideoIngressState())

    func reset() {
        state.withLock { value in
            let frameCapacity = value.frames.capacity
            let eventCapacity = value.events.capacity
            value = LumenVideoIngressState()
            value.frames.resize(to: frameCapacity)
            value.events.resize(to: eventCapacity)
        }
    }

    func setFrameCapacity(_ capacity: Int) {
        state.withLock { value in
            let droppedCount = value.frames.resize(to: capacity)
            value.droppedFrameCount &+= UInt64(droppedCount)
        }
    }

    func setEventCapacity(_ capacity: Int) {
        state.withLock { value in
            let droppedCount = value.events.resize(to: capacity)
            value.droppedEventCount &+= UInt64(droppedCount)
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

    @discardableResult
    func consume(frame: LumenEncodedFrame) -> LumenVideoForwardingAdmission {
        consume(
            sampleBuffer: frame.sampleBuffer,
            codec: frame.codec,
            sourceSequenceNumber: frame.sourceSequenceNumber,
            sourceDisplayTime: frame.sourceDisplayTime,
            outputCallbackLatencyMilliseconds: frame.outputCallbackLatencyMilliseconds,
            isKeyFrame: frame.isKeyFrame,
            requiresBootstrapAcknowledgement: frame.requiresBootstrapAcknowledgement,
            isRepairKeyFrame: frame.isRepairKeyFrame,
            isHDRSignaled: frame.isHDRSignaled
        )
    }

    @discardableResult
    func consume(
        sampleBuffer: CMSampleBuffer,
        codec: LumenCaptureCodec,
        sourceSequenceNumber: UInt64,
        sourceDisplayTime: UInt64,
        outputCallbackLatencyMilliseconds: Double? = nil,
        isKeyFrame: Bool,
        requiresBootstrapAcknowledgement: Bool = false,
        isRepairKeyFrame: Bool = false,
        isHDRSignaled: Bool,
        isReplay: Bool = false
    ) -> LumenVideoForwardingAdmission {
        let frame = LumenBridgeDrainedVideoFrame(
            codec: codec,
            payloadSize: sampleBuffer.totalSampleSize,
            sourceSequenceNumber: sourceSequenceNumber,
            sourceDisplayTime: sourceDisplayTime,
            outputCallbackLatencyMilliseconds: outputCallbackLatencyMilliseconds,
            isKeyFrame: isKeyFrame,
            requiresBootstrapAcknowledgement: requiresBootstrapAcknowledgement,
            isRepairKeyFrame: isRepairKeyFrame,
            isHDRSignaled: isHDRSignaled,
            isReplay: isReplay,
            sampleBuffer: sampleBuffer
        )
        return state.withLock { value in
            value.frameCount &+= 1
            value.lastFrame = frame
            if value.awaitingRecoveryKeyFrame {
                guard isKeyFrame,
                      requiresBootstrapAcknowledgement else {
                    value.droppedFrameCount &+= 1
                    return .waitingForRecoveryKeyFrame
                }
                value.awaitingRecoveryKeyFrame = false
                value.frames.removeAll()
                value.frames.appendDroppingOldest(frame)
                return .recoveredAtKeyFrame
            }
            if value.frames.isFull {
                let droppedSourceDisplayTime = value.frames.first?.sourceDisplayTime
                let queuedDropCount = value.frames.count
                value.droppedFrameCount &+= UInt64(queuedDropCount)
                value.frames.removeAll()
                let overflowEvent = LumenBridgeDrainedVideoEvent(
                    kind: .droppedFrame,
                    message: "core-forwarder-overflow",
                    stopStatus: nil,
                    automaticRestartCount: nil,
                    sourceDisplayTime: droppedSourceDisplayTime
                )
                value.eventCount &+= 1
                value.lastEvent = overflowEvent
                if value.events.appendDroppingOldest(overflowEvent) != nil {
                    value.droppedEventCount &+= 1
                }
                if !isKeyFrame {
                    value.droppedFrameCount &+= 1
                    value.awaitingRecoveryKeyFrame = true
                    return .recoveryKeyFrameRequired
                }
                value.frames.appendDroppingOldest(frame)
                return .recoveredAtKeyFrame
            }
            value.frames.appendDroppingOldest(frame)
            return .queued
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
            if value.events.appendDroppingOldest(event) != nil {
                value.droppedEventCount &+= 1
            }
        }
    }

    func popNextFrame() -> LumenBridgeDrainedVideoFrame? {
        state.withLock { value in
            value.frames.popFirst()
        }
    }

    func popNextEvent() -> LumenBridgeDrainedVideoEvent? {
        state.withLock { value in
            value.events.popFirst()
        }
    }
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
