import Foundation
import Synchronization

private struct LumenAudioIngressState: Sendable {
    var frames: [LumenBridgeDrainedAudioFrame] = []
    var events: [LumenBridgeDrainedAudioEvent] = []
    var frameCapacity = 8
    var eventCapacity = 64
    var frameCount: UInt64 = 0
    var eventCount: UInt64 = 0
    var droppedFrameCount: UInt64 = 0
    var droppedEventCount: UInt64 = 0
    var lastFrame: LumenBridgeDrainedAudioFrame?
    var lastEvent: LumenBridgeDrainedAudioEvent?
    var producerActive = false
}

/// ScreenCaptureKit audio callbacks require a synchronous, bounded handoff. The
/// mutex owns only value-semantic PCM packets and queue counters at that boundary.
final class LumenAudioCaptureForwarder: Sendable {
    private let state = Mutex(LumenAudioIngressState())

    func reset() {
        state.withLock { value in
            let frameCapacity = value.frameCapacity
            let eventCapacity = value.eventCapacity
            value = LumenAudioIngressState()
            value.frameCapacity = frameCapacity
            value.eventCapacity = eventCapacity
        }
    }

    func setFrameCapacity(_ capacity: Int) {
        state.withLock { value in
            value.frameCapacity = max(capacity, 1)
            let overflow = max(value.frames.count - value.frameCapacity, 0)
            if overflow > 0 {
                value.frames.removeFirst(overflow)
                value.droppedFrameCount &+= UInt64(overflow)
            }
        }
    }

    func setEventCapacity(_ capacity: Int) {
        state.withLock { value in
            value.eventCapacity = max(capacity, 1)
            let overflow = max(value.events.count - value.eventCapacity, 0)
            if overflow > 0 {
                value.events.removeFirst(overflow)
                value.droppedEventCount &+= UInt64(overflow)
            }
        }
    }

    func setProducerActive(_ active: Bool) {
        state.withLock { $0.producerActive = active }
    }

    func snapshot() -> LumenBridgeAudioForwardingSnapshot {
        state.withLock { value in
            LumenBridgeAudioForwardingSnapshot(
                frameCount: value.frameCount,
                eventCount: value.eventCount,
                queuedFrameCount: UInt64(value.frames.count),
                queuedEventCount: UInt64(value.events.count),
                droppedFrameCount: value.droppedFrameCount,
                droppedEventCount: value.droppedEventCount,
                lastFrameSequenceNumber: value.lastFrame?.sequenceNumber,
                lastFrameHostTimeNanoseconds: value.lastFrame?.hostTimeNanoseconds,
                lastFrameSampleRate: value.lastFrame?.sampleRate,
                lastFrameChannelCount: value.lastFrame?.channelCount,
                lastFrameFrameCount: value.lastFrame?.frameCount,
                lastFramePCMByteCount: value.lastFrame?.pcmFloat32LE.count ?? 0,
                lastEventKind: value.lastEvent?.kind
            )
        }
    }

    func consume(frame: LumenAudioFrame) {
        let frame = LumenBridgeDrainedAudioFrame(
            sequenceNumber: frame.sequenceNumber,
            hostTimeNanoseconds: frame.hostTimeNanoseconds,
            sampleRate: frame.sampleRate,
            channelCount: frame.channelCount,
            frameCount: frame.frameCount,
            pcmFloat32LE: frame.pcmFloat32LE
        )
        state.withLock { value in
            value.frameCount &+= 1
            value.lastFrame = frame
            if value.frames.count >= value.frameCapacity {
                value.frames.removeFirst()
                value.droppedFrameCount &+= 1
            }
            value.frames.append(frame)
        }
    }

    func consume(event: LumenAudioCaptureSessionEvent) {
        let event = LumenBridgeDrainedAudioEvent(
            kind: event.kind.bridgeKind,
            message: event.message,
            stopStatus: event.stopStatus,
            automaticRestartCount: event.automaticRestartCount,
            sourceSequenceNumber: event.sourceSequenceNumber
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

    func popNextFrame() -> LumenBridgeDrainedAudioFrame? {
        state.withLock { value in
            guard !value.frames.isEmpty else { return nil }
            return value.frames.removeFirst()
        }
    }

    func popNextEvent() -> LumenBridgeDrainedAudioEvent? {
        state.withLock { value in
            guard !value.events.isEmpty else { return nil }
            return value.events.removeFirst()
        }
    }
}

private extension LumenAudioCaptureSessionEventKind {
    var bridgeKind: LumenBridgeCaptureEventKind {
        switch self {
        case .started: .started
        case .stopped: .stopped
        case .restarted: .restarted
        case .failed: .failed
        case .droppedFrame: .droppedFrame
        }
    }
}
