import Foundation
import Synchronization

private struct LumenAudioIngressState: Sendable {
    var frames = LumenFixedCapacityRingBuffer<LumenBridgeDrainedAudioFrame>(
        capacity: 8
    )
    var events = LumenFixedCapacityRingBuffer<LumenBridgeDrainedAudioEvent>(
        capacity: 64
    )
    var frameCount: UInt64 = 0
    var eventCount: UInt64 = 0
    var droppedFrameCount: UInt64 = 0
    var droppedEventCount: UInt64 = 0
    var lastFrame: LumenBridgeDrainedAudioFrame?
    var lastEvent: LumenBridgeDrainedAudioEvent?
    var producerActive = false
}

/// Core Audio and microphone callbacks require a synchronous, bounded handoff. The
/// mutex owns only value-semantic PCM packets and queue counters at that boundary.
final class LumenAudioCaptureForwarder: Sendable {
    private let state = Mutex(LumenAudioIngressState())

    func reset() {
        state.withLock { value in
            let frameCapacity = value.frames.capacity
            let eventCapacity = value.events.capacity
            value = LumenAudioIngressState()
            value.frames.resize(to: frameCapacity)
            value.events.resize(to: eventCapacity)
        }
    }

    /// Drops queued PCM frames and capture events at a media park/resume
    /// boundary without disabling the active capture producer.
    func resetForMediaEpoch() {
        state.withLock { value in
            value.droppedFrameCount &+= UInt64(value.frames.count)
            value.droppedEventCount &+= UInt64(value.events.count)
            value.frames.removeAll()
            value.events.removeAll()
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
            guard value.producerActive else { return }
            value.frameCount &+= 1
            value.lastFrame = frame
            if value.frames.appendDroppingOldest(frame) != nil {
                value.droppedFrameCount &+= 1
            }
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
            guard value.producerActive else { return }
            value.eventCount &+= 1
            value.lastEvent = event
            if value.events.appendDroppingOldest(event) != nil {
                value.droppedEventCount &+= 1
            }
        }
    }

    func popNextFrame() -> LumenBridgeDrainedAudioFrame? {
        state.withLock { value in
            value.frames.popFirst()
        }
    }

    func popNextEvent() -> LumenBridgeDrainedAudioEvent? {
        state.withLock { value in
            value.events.popFirst()
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
