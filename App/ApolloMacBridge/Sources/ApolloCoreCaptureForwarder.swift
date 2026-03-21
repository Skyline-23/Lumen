import ApolloCore
import CoreMedia
import Foundation
import MacDisplayCaptureKit

public struct ApolloBridgeCoreForwardingSnapshot: Equatable, Sendable {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let hasLastSampleBuffer: Bool
    public let lastFrameCodec: ApolloCaptureCodec?
    public let lastFramePayloadSize: Int
    public let lastFrameSourceSequenceNumber: UInt64?
    public let lastFrameSourceDisplayTime: UInt64?
    public let lastFrameIsKeyFrame: Bool
    public let lastFrameIsHDRSignaled: Bool
    public let lastEventKind: ApolloBridgeCaptureEventKind?

    init(snapshot: ApolloCoreEncodedCaptureIngressSnapshot) {
        self.frameCount = snapshot.frame_count
        self.eventCount = snapshot.event_count
        self.queuedFrameCount = snapshot.queued_frame_count
        self.queuedEventCount = snapshot.queued_event_count
        self.droppedFrameCount = snapshot.dropped_frame_count
        self.droppedEventCount = snapshot.dropped_event_count
        self.hasLastSampleBuffer = snapshot.has_last_sample_buffer
        self.lastFrameCodec = snapshot.has_last_frame ? ApolloCaptureCodec(apolloCoreCodec: snapshot.last_frame_codec) : nil
        self.lastFramePayloadSize = Int(snapshot.last_frame_payload_size)
        self.lastFrameSourceSequenceNumber = snapshot.has_last_frame ? snapshot.last_frame_source_sequence_number : nil
        self.lastFrameSourceDisplayTime = snapshot.has_last_frame ? snapshot.last_frame_source_display_time : nil
        self.lastFrameIsKeyFrame = snapshot.last_frame_is_key_frame
        self.lastFrameIsHDRSignaled = snapshot.last_frame_is_hdr_signaled
        self.lastEventKind = snapshot.has_last_event ? ApolloBridgeCaptureEventKind(apolloCoreKind: snapshot.last_event_kind) : nil
    }
}

struct ApolloBridgeCoreDrainedFrame: @unchecked Sendable {
    let codec: ApolloCaptureCodec
    let payloadSize: Int
    let sourceSequenceNumber: UInt64
    let sourceDisplayTime: UInt64
    let outputCallbackLatencyMilliseconds: Double?
    let isKeyFrame: Bool
    let isHDRSignaled: Bool
    let sampleBuffer: CMSampleBuffer
}

struct ApolloBridgeCoreDrainedEvent: Equatable, Sendable {
    let kind: ApolloBridgeCaptureEventKind
    let message: String?
    let stopStatus: Int32?
    let automaticRestartCount: UInt64?
    let sourceDisplayTime: UInt64?
}

final class ApolloCoreCaptureForwarder: @unchecked Sendable {
    private let handle: OpaquePointer

    init() {
        guard let handle = ApolloCoreEncodedCaptureIngressCreate() else {
            fatalError("ApolloCoreEncodedCaptureIngressCreate returned nil")
        }
        self.handle = handle
    }

    deinit {
        ApolloCoreEncodedCaptureIngressDestroy(handle)
    }

    func reset() {
        ApolloCoreEncodedCaptureIngressReset(handle)
    }

    func setFrameCapacity(_ capacity: Int) {
        ApolloCoreEncodedCaptureIngressSetFrameCapacity(handle, max(1, capacity))
    }

    func setEventCapacity(_ capacity: Int) {
        ApolloCoreEncodedCaptureIngressSetEventCapacity(handle, max(1, capacity))
    }

    func snapshot() -> ApolloBridgeCoreForwardingSnapshot {
        ApolloBridgeCoreForwardingSnapshot(
            snapshot: ApolloCoreEncodedCaptureIngressCopySnapshot(handle)
        )
    }

    func consume(frame: MDKEncodedFrame) {
        consume(
            sampleBuffer: frame.sampleBuffer,
            codec: ApolloCaptureCodec(mdkCodec: frame.codec),
            sourceSequenceNumber: frame.sourceSequenceNumber,
            sourceDisplayTime: frame.sourceDisplayTime,
            outputCallbackLatencyMilliseconds: frame.outputCallbackLatencyMilliseconds,
            isKeyFrame: frame.isKeyFrame,
            isHDRSignaled: frame.isHDRSignaled
        )
    }

    func consume(
        sampleBuffer: CMSampleBuffer,
        codec: ApolloCaptureCodec,
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

    func popNextFrame() -> ApolloBridgeCoreDrainedFrame? {
        var sampleBuffer: Unmanaged<CMSampleBuffer>?
        let record = withUnsafeMutablePointer(to: &sampleBuffer) { sampleBufferPointer in
            ApolloCoreEncodedCaptureIngressPopNextFrame(handle, sampleBufferPointer)
        }
        guard record.has_value, let sampleBuffer else {
            return nil
        }

        return ApolloBridgeCoreDrainedFrame(
            codec: ApolloCaptureCodec(apolloCoreCodec: record.codec),
            payloadSize: Int(record.payload_size),
            sourceSequenceNumber: record.source_sequence_number,
            sourceDisplayTime: record.source_display_time,
            outputCallbackLatencyMilliseconds: record.has_output_callback_latency_milliseconds ? record.output_callback_latency_milliseconds : nil,
            isKeyFrame: record.is_key_frame,
            isHDRSignaled: record.is_hdr_signaled,
            sampleBuffer: sampleBuffer.takeRetainedValue()
        )
    }

    func popNextEvent() -> ApolloBridgeCoreDrainedEvent? {
        var messageBuffer = Array<CChar>(repeating: 0, count: 512)
        let record = messageBuffer.withUnsafeMutableBufferPointer { buffer in
            ApolloCoreEncodedCaptureIngressPopNextEvent(
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
        return ApolloBridgeCoreDrainedEvent(
            kind: kind,
            message: message,
            stopStatus: record.has_stop_status ? record.stop_status : nil,
            automaticRestartCount: record.has_automatic_restart_count ? record.automatic_restart_count : nil,
            sourceDisplayTime: record.has_source_display_time ? record.source_display_time : nil
        )
    }
}

private extension ApolloCaptureCodec {
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

private extension MDKVideoEncoderCodec {
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

private extension ApolloBridgeCaptureEventKind {
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
