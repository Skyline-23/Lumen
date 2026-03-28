import LumenCore
import CoreMedia
import Foundation
import MacDisplayCaptureKit

public struct LumenBridgeCoreForwardingSnapshot: Equatable, Sendable {
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

    init(snapshot: ApolloCoreEncodedCaptureIngressSnapshot) {
        self.frameCount = snapshot.frame_count
        self.eventCount = snapshot.event_count
        self.queuedFrameCount = snapshot.queued_frame_count
        self.queuedEventCount = snapshot.queued_event_count
        self.droppedFrameCount = snapshot.dropped_frame_count
        self.droppedEventCount = snapshot.dropped_event_count
        self.hasLastSampleBuffer = snapshot.has_last_sample_buffer
        self.lastFrameCodec = snapshot.has_last_frame ? LumenCaptureCodec(apolloCoreCodec: snapshot.last_frame_codec) : nil
        self.lastFramePayloadSize = Int(snapshot.last_frame_payload_size)
        self.lastFrameSourceSequenceNumber = snapshot.has_last_frame ? snapshot.last_frame_source_sequence_number : nil
        self.lastFrameSourceDisplayTime = snapshot.has_last_frame ? snapshot.last_frame_source_display_time : nil
        self.lastFrameIsKeyFrame = snapshot.last_frame_is_key_frame
        self.lastFrameIsHDRSignaled = snapshot.last_frame_is_hdr_signaled
        self.lastEventKind = snapshot.has_last_event ? LumenBridgeCaptureEventKind(apolloCoreKind: snapshot.last_event_kind) : nil
    }
}

public struct LumenBridgeCoreDrainedFrame: @unchecked Sendable {
    public let codec: LumenCaptureCodec
    public let payloadSize: Int
    public let sourceSequenceNumber: UInt64
    public let sourceDisplayTime: UInt64
    public let outputCallbackLatencyMilliseconds: Double?
    public let isKeyFrame: Bool
    public let isHDRSignaled: Bool
    public let sampleBuffer: CMSampleBuffer
}

public struct LumenBridgeCoreDrainedEvent: Equatable, Sendable {
    public let kind: LumenBridgeCaptureEventKind
    public let message: String?
    public let stopStatus: Int32?
    public let automaticRestartCount: UInt64?
    public let sourceDisplayTime: UInt64?
}

final class LumenCoreCaptureForwarder: @unchecked Sendable {
    private let handle: OpaquePointer

    init() {
        guard let handle = ApolloCoreSharedEncodedCaptureIngress() else {
            fatalError("ApolloCoreSharedEncodedCaptureIngress returned nil")
        }
        self.handle = handle
    }

    deinit {}

    func reset() {
        ApolloCoreEncodedCaptureIngressReset(handle)
    }

    func setFrameCapacity(_ capacity: Int) {
        ApolloCoreEncodedCaptureIngressSetFrameCapacity(handle, max(1, capacity))
    }

    func setEventCapacity(_ capacity: Int) {
        ApolloCoreEncodedCaptureIngressSetEventCapacity(handle, max(1, capacity))
    }

    func setProducerActive(_ active: Bool) {
        ApolloCoreEncodedCaptureIngressSetProducerActive(handle, active)
    }

    func snapshot() -> LumenBridgeCoreForwardingSnapshot {
        LumenBridgeCoreForwardingSnapshot(
            snapshot: ApolloCoreEncodedCaptureIngressCopySnapshot(handle)
        )
    }

    func consume(frame: MDKEncodedFrame) {
        consume(
            sampleBuffer: frame.sampleBuffer,
            codec: LumenCaptureCodec(mdkCodec: frame.codec),
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
        isHDRSignaled: Bool
    ) {
        ApolloCoreEncodedCaptureIngressConsumeSampleBuffer(
            handle,
            codec.apolloCoreCodec,
            sourceSequenceNumber,
            sourceDisplayTime,
            outputCallbackLatencyMilliseconds != nil,
            outputCallbackLatencyMilliseconds ?? 0,
            isKeyFrame,
            isHDRSignaled,
            sampleBuffer
        )
    }

    func consume(event: MDKEncodedCaptureSessionEvent) {
        if let message = event.message {
            message.withCString { messagePointer in
                ApolloCoreEncodedCaptureIngressConsumeEvent(
                    handle,
                    event.kind.apolloCoreKind,
                    messagePointer,
                    event.stopStatus != nil,
                    event.stopStatus ?? 0,
                    event.automaticRestartCount != nil,
                    event.automaticRestartCount ?? 0,
                    event.sourceDisplayTime != nil,
                    event.sourceDisplayTime ?? 0
                )
            }
        } else {
            ApolloCoreEncodedCaptureIngressConsumeEvent(
                handle,
                event.kind.apolloCoreKind,
                nil,
                event.stopStatus != nil,
                event.stopStatus ?? 0,
                event.automaticRestartCount != nil,
                event.automaticRestartCount ?? 0,
                event.sourceDisplayTime != nil,
                event.sourceDisplayTime ?? 0
            )
        }
    }

    func popNextFrame() -> LumenBridgeCoreDrainedFrame? {
        var sampleBuffer: Unmanaged<CMSampleBuffer>?
        let record = withUnsafeMutablePointer(to: &sampleBuffer) { sampleBufferPointer in
            ApolloCoreEncodedCaptureIngressPopNextFrame(handle, sampleBufferPointer)
        }
        guard record.has_value, let sampleBuffer else {
            return nil
        }

        return LumenBridgeCoreDrainedFrame(
            codec: LumenCaptureCodec(apolloCoreCodec: record.codec),
            payloadSize: Int(record.payload_size),
            sourceSequenceNumber: record.source_sequence_number,
            sourceDisplayTime: record.source_display_time,
            outputCallbackLatencyMilliseconds: record.has_output_callback_latency_milliseconds ? record.output_callback_latency_milliseconds : nil,
            isKeyFrame: record.is_key_frame,
            isHDRSignaled: record.is_hdr_signaled,
            sampleBuffer: sampleBuffer.takeRetainedValue()
        )
    }

    func popNextEvent() -> LumenBridgeCoreDrainedEvent? {
        var messageBuffer = Array<CChar>(repeating: 0, count: 512)
        let record = messageBuffer.withUnsafeMutableBufferPointer { buffer in
            ApolloCoreEncodedCaptureIngressPopNextEvent(
                handle,
                buffer.baseAddress,
                buffer.count
            )
        }
        guard record.has_value,
              let kind = LumenBridgeCaptureEventKind(apolloCoreKind: record.kind) else {
            return nil
        }

        let message = messageBuffer.first == 0 ? nil : String(cString: messageBuffer)
        return LumenBridgeCoreDrainedEvent(
            kind: kind,
            message: message,
            stopStatus: record.has_stop_status ? record.stop_status : nil,
            automaticRestartCount: record.has_automatic_restart_count ? record.automatic_restart_count : nil,
            sourceDisplayTime: record.has_source_display_time ? record.source_display_time : nil
        )
    }
}

extension LumenCaptureCodec {
    init(mdkCodec: MDKVideoEncoderCodec) {
        switch mdkCodec {
        case .h264:
            self = .h264
        case .hevc:
            self = .hevc
        case .proResProxy:
            self = .proResProxy
        }
    }

    init(apolloCoreCodec: ApolloCoreCaptureCodec) {
        switch apolloCoreCodec {
        case ApolloCoreCaptureCodecH264:
            self = .h264
        case ApolloCoreCaptureCodecHEVC:
            self = .hevc
        case ApolloCoreCaptureCodecProResProxy:
            self = .proResProxy
        default:
            self = .hevc
        }
    }

    var apolloCoreCodec: ApolloCoreCaptureCodec {
        switch self {
        case .h264:
            return ApolloCoreCaptureCodecH264
        case .hevc:
            return ApolloCoreCaptureCodecHEVC
        case .proResProxy:
            return ApolloCoreCaptureCodecProResProxy
        }
    }
}

extension MDKVideoEncoderCodec {
    var apolloCoreCodec: ApolloCoreCaptureCodec {
        switch self {
        case .h264:
            return ApolloCoreCaptureCodecH264
        case .hevc:
            return ApolloCoreCaptureCodecHEVC
        case .proResProxy:
            return ApolloCoreCaptureCodecProResProxy
        }
    }
}

extension LumenBridgeCaptureEventKind {
    init?(apolloCoreKind: ApolloCoreCaptureEventKind) {
        switch apolloCoreKind {
        case ApolloCoreCaptureEventKindStarted:
            self = .started
        case ApolloCoreCaptureEventKindStopped:
            self = .stopped
        case ApolloCoreCaptureEventKindRestarted:
            self = .restarted
        case ApolloCoreCaptureEventKindFailed:
            self = .failed
        case ApolloCoreCaptureEventKindDroppedFrame:
            self = .droppedFrame
        default:
            return nil
        }
    }
}

private extension MDKEncodedCaptureSessionEventKind {
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
