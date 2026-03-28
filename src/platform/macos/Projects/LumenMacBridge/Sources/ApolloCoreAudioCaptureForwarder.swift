import ApolloCore
import Foundation
import MacDisplayCaptureKit

final class ApolloCoreAudioCaptureForwarder: @unchecked Sendable {
    private let handle: OpaquePointer

    init() {
        guard let handle = ApolloCoreSharedAudioCaptureIngress() else {
            fatalError("ApolloCoreSharedAudioCaptureIngress returned nil")
        }
        self.handle = handle
    }

    deinit {}

    func reset() {
        ApolloCoreAudioCaptureIngressReset(handle)
    }

    func setFrameCapacity(_ capacity: Int) {
        ApolloCoreAudioCaptureIngressSetFrameCapacity(handle, max(1, capacity))
    }

    func setEventCapacity(_ capacity: Int) {
        ApolloCoreAudioCaptureIngressSetEventCapacity(handle, max(1, capacity))
    }

    func setProducerActive(_ active: Bool) {
        ApolloCoreAudioCaptureIngressSetProducerActive(handle, active)
    }

    func snapshot() -> ApolloBridgeAudioForwardingSnapshot {
        let snapshot = ApolloCoreAudioCaptureIngressCopySnapshot(handle)
        return ApolloBridgeAudioForwardingSnapshot(
            frameCount: snapshot.frame_count,
            eventCount: snapshot.event_count,
            queuedFrameCount: snapshot.queued_frame_count,
            queuedEventCount: snapshot.queued_event_count,
            droppedFrameCount: snapshot.dropped_frame_count,
            droppedEventCount: snapshot.dropped_event_count,
            lastFrameSequenceNumber: snapshot.has_last_frame ? snapshot.last_frame_sequence_number : nil,
            lastFrameHostTimeNanoseconds: snapshot.has_last_frame ? snapshot.last_frame_host_time_nanoseconds : nil,
            lastFrameSampleRate: snapshot.has_last_frame ? Int(snapshot.last_frame_sample_rate) : nil,
            lastFrameChannelCount: snapshot.has_last_frame ? Int(snapshot.last_frame_channel_count) : nil,
            lastFrameFrameCount: snapshot.has_last_frame ? Int(snapshot.last_frame_frame_count) : nil,
            lastFramePCMByteCount: Int(snapshot.last_frame_pcm_byte_count),
            lastEventKind: snapshot.has_last_event ? ApolloBridgeCaptureEventKind(apolloCoreKind: snapshot.last_event_kind) : nil
        )
    }

    func consume(frame: MDKAudioFrame) {
        frame.pcmFloat32LE.withUnsafeBytes { pcmBuffer in
            ApolloCoreAudioCaptureIngressConsumePCMFloat32(
                handle,
                frame.sequenceNumber,
                frame.hostTimeNanoseconds,
                Int32(frame.sampleRate),
                Int32(frame.channelCount),
                Int32(frame.frameCount),
                pcmBuffer.baseAddress,
                pcmBuffer.count
            )
        }
    }

    func consume(event: MDKAudioCaptureSessionEvent) {
        if let message = event.message {
            message.withCString { messagePointer in
                ApolloCoreAudioCaptureIngressConsumeEvent(
                    handle,
                    event.kind.apolloCoreKind,
                    messagePointer,
                    event.stopStatus != nil,
                    event.stopStatus ?? 0,
                    event.automaticRestartCount != nil,
                    event.automaticRestartCount ?? 0,
                    event.sourceSequenceNumber != nil,
                    event.sourceSequenceNumber ?? 0
                )
            }
        } else {
            ApolloCoreAudioCaptureIngressConsumeEvent(
                handle,
                event.kind.apolloCoreKind,
                nil,
                event.stopStatus != nil,
                event.stopStatus ?? 0,
                event.automaticRestartCount != nil,
                event.automaticRestartCount ?? 0,
                event.sourceSequenceNumber != nil,
                event.sourceSequenceNumber ?? 0
            )
        }
    }

    func popNextFrame() -> ApolloBridgeDrainedAudioFrame? {
        let bufferCapacity = 1024 * 1024
        var data = Data(count: bufferCapacity)
        var copiedSize: Int = 0
        let record = data.withUnsafeMutableBytes { rawBuffer in
            ApolloCoreAudioCaptureIngressPopNextFrame(
                handle,
                rawBuffer.baseAddress,
                rawBuffer.count,
                &copiedSize
            )
        }

        guard record.has_value else {
            return nil
        }

        data.count = copiedSize
        return ApolloBridgeDrainedAudioFrame(
            sequenceNumber: record.sequence_number,
            hostTimeNanoseconds: record.host_time_nanoseconds,
            sampleRate: Int(record.sample_rate),
            channelCount: Int(record.channel_count),
            frameCount: Int(record.frame_count),
            pcmFloat32LE: data
        )
    }

    func popNextEvent() -> ApolloBridgeDrainedAudioEvent? {
        var messageBuffer = Array<CChar>(repeating: 0, count: 512)
        let record = messageBuffer.withUnsafeMutableBufferPointer { buffer in
            ApolloCoreAudioCaptureIngressPopNextEvent(
                handle,
                buffer.baseAddress,
                buffer.count
            )
        }
        guard record.has_value,
              let kind = ApolloBridgeCaptureEventKind(apolloCoreKind: record.kind) else {
            return nil
        }

        let message = messageBuffer.first == 0 ? nil : String(cString: messageBuffer)
        return ApolloBridgeDrainedAudioEvent(
            kind: kind,
            message: message,
            stopStatus: record.has_stop_status ? record.stop_status : nil,
            automaticRestartCount: record.has_automatic_restart_count ? record.automatic_restart_count : nil,
            sourceSequenceNumber: record.has_source_sequence_number ? record.source_sequence_number : nil
        )
    }
}

private extension MDKAudioCaptureSessionEventKind {
    var apolloCoreKind: ApolloCoreCaptureEventKind {
        switch self {
        case .started:
            return ApolloCoreCaptureEventKindStarted
        case .stopped:
            return ApolloCoreCaptureEventKindStopped
        case .restarted:
            return ApolloCoreCaptureEventKindRestarted
        case .failed:
            return ApolloCoreCaptureEventKindFailed
        case .droppedFrame:
            return ApolloCoreCaptureEventKindDroppedFrame
        }
    }
}
