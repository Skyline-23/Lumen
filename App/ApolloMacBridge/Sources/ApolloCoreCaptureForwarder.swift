import ApolloCore
import Foundation
import MacDisplayCaptureKit

public struct ApolloBridgeCoreForwardingSnapshot: Equatable, Sendable {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let lastFrameCodec: ApolloCaptureCodec?
    public let lastFramePayloadSize: Int
    public let lastFrameSourceSequenceNumber: UInt64?
    public let lastFrameSourceDisplayTime: UInt64?
    public let lastFrameIsKeyFrame: Bool
    public let lastFrameIsHDRSignaled: Bool
    public let lastEventKind: ApolloBridgeCaptureEventKind?

    init(snapshot: ApolloCoreEncodedCaptureConsumerSnapshot) {
        self.frameCount = snapshot.frame_count
        self.eventCount = snapshot.event_count
        self.lastFrameCodec = snapshot.has_last_frame ? ApolloCaptureCodec(apolloCoreCodec: snapshot.last_frame_codec) : nil
        self.lastFramePayloadSize = Int(snapshot.last_frame_payload_size)
        self.lastFrameSourceSequenceNumber = snapshot.has_last_frame ? snapshot.last_frame_source_sequence_number : nil
        self.lastFrameSourceDisplayTime = snapshot.has_last_frame ? snapshot.last_frame_source_display_time : nil
        self.lastFrameIsKeyFrame = snapshot.last_frame_is_key_frame
        self.lastFrameIsHDRSignaled = snapshot.last_frame_is_hdr_signaled
        self.lastEventKind = snapshot.has_last_event ? ApolloBridgeCaptureEventKind(apolloCoreKind: snapshot.last_event_kind) : nil
    }
}

final class ApolloCoreCaptureForwarder: @unchecked Sendable {
    private let handle: OpaquePointer

    init() {
        guard let handle = ApolloCoreEncodedCaptureConsumerCreate() else {
            fatalError("ApolloCoreEncodedCaptureConsumerCreate returned nil")
        }
        self.handle = handle
    }

    deinit {
        ApolloCoreEncodedCaptureConsumerDestroy(handle)
    }

    func reset() {
        ApolloCoreEncodedCaptureConsumerReset(handle)
    }

    func snapshot() -> ApolloBridgeCoreForwardingSnapshot {
        ApolloBridgeCoreForwardingSnapshot(
            snapshot: ApolloCoreEncodedCaptureConsumerCopySnapshot(handle)
        )
    }

    func copyLastFramePayload() -> Data {
        let snapshot = ApolloCoreEncodedCaptureConsumerCopySnapshot(handle)
        guard snapshot.has_last_frame, snapshot.last_frame_payload_size > 0 else {
            return Data()
        }

        var payload = Data(count: Int(snapshot.last_frame_payload_size))
        let copied = payload.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return Int(
                ApolloCoreEncodedCaptureConsumerCopyLastFramePayload(
                    handle,
                    baseAddress,
                    rawBuffer.count
                )
            )
        }
        if copied < payload.count {
            payload.removeSubrange(copied..<payload.count)
        }
        return payload
    }

    func consume(frame: MDKEncodedFrame) throws {
        let payload = try frame.contiguousData()
        payload.withUnsafeBytes { rawBuffer in
            let payloadPointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            ApolloCoreEncodedCaptureConsumerConsumeFrame(
                handle,
                frame.codec.apolloCoreCodec,
                frame.sourceSequenceNumber,
                frame.sourceDisplayTime,
                frame.outputCallbackLatencyMilliseconds != nil,
                frame.outputCallbackLatencyMilliseconds ?? 0,
                frame.isKeyFrame,
                frame.isHDRSignaled,
                payloadPointer,
                rawBuffer.count
            )
        }
    }

    func consume(
        codec: ApolloCaptureCodec,
        payload: Data,
        sourceSequenceNumber: UInt64,
        sourceDisplayTime: UInt64,
        outputCallbackLatencyMilliseconds: Double? = nil,
        isKeyFrame: Bool,
        isHDRSignaled: Bool
    ) {
        payload.withUnsafeBytes { rawBuffer in
            let payloadPointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            ApolloCoreEncodedCaptureConsumerConsumeFrame(
                handle,
                codec.apolloCoreCodec,
                sourceSequenceNumber,
                sourceDisplayTime,
                outputCallbackLatencyMilliseconds != nil,
                outputCallbackLatencyMilliseconds ?? 0,
                isKeyFrame,
                isHDRSignaled,
                payloadPointer,
                rawBuffer.count
            )
        }
    }

    func consume(event: MDKEncodedCaptureSessionEvent) {
        if let message = event.message {
            message.withCString { messagePointer in
                ApolloCoreEncodedCaptureConsumerConsumeEvent(
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
            ApolloCoreEncodedCaptureConsumerConsumeEvent(
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
}

private extension ApolloCaptureCodec {
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
