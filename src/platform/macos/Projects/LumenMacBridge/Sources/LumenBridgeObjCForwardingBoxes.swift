import CoreMedia
import Foundation

@objcMembers
public final class LumenBridgeStatusBox: NSObject {
    public let coreVersion: String
    public let runtimeDescription: String
    public let integrationStatus: String
    public let captureSessionRunning: Bool
    public let audioCaptureSessionRunning: Bool
    public let automaticCaptureOrchestrationRunning: Bool

    init(snapshot: LumenBridgeStatus) {
        self.coreVersion = snapshot.coreVersion
        self.runtimeDescription = snapshot.runtimeDescription
        self.integrationStatus = snapshot.integrationStatus
        self.captureSessionRunning = snapshot.captureSessionRunning
        self.audioCaptureSessionRunning = snapshot.audioCaptureSessionRunning
        self.automaticCaptureOrchestrationRunning = snapshot.automaticCaptureOrchestrationRunning
    }
}

@objcMembers
public final class LumenBridgeAudioForwardingSnapshotBox: NSObject {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let hasLastFrame: Bool
    public let lastFrameSequenceNumber: UInt64
    public let lastFrameHostTimeNanoseconds: UInt64
    public let lastFrameSampleRate: Int
    public let lastFrameChannelCount: Int
    public let lastFrameFrameCount: Int
    public let lastFramePCMByteCount: Int
    public let lastEventKindRawValue: Int

    init(snapshot: LumenBridgeAudioForwardingSnapshot) {
        self.frameCount = snapshot.frameCount
        self.eventCount = snapshot.eventCount
        self.queuedFrameCount = snapshot.queuedFrameCount
        self.queuedEventCount = snapshot.queuedEventCount
        self.droppedFrameCount = snapshot.droppedFrameCount
        self.droppedEventCount = snapshot.droppedEventCount
        self.hasLastFrame = snapshot.lastFrameSequenceNumber != nil
        self.lastFrameSequenceNumber = snapshot.lastFrameSequenceNumber ?? 0
        self.lastFrameHostTimeNanoseconds = snapshot.lastFrameHostTimeNanoseconds ?? 0
        self.lastFrameSampleRate = snapshot.lastFrameSampleRate ?? 0
        self.lastFrameChannelCount = snapshot.lastFrameChannelCount ?? 0
        self.lastFrameFrameCount = snapshot.lastFrameFrameCount ?? 0
        self.lastFramePCMByteCount = snapshot.lastFramePCMByteCount
        self.lastEventKindRawValue = snapshot.lastEventKind.map(LumenBridgeObjCFacade.rawValue(for:)) ?? -1
    }
}

@objcMembers
public final class LumenBridgeVideoForwardingSnapshotBox: NSObject {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let hasLastSampleBuffer: Bool
    public let lastFrameCodecRawValue: Int
    public let lastFramePayloadSize: Int
    public let hasLastFrameSourceSequenceNumber: Bool
    public let lastFrameSourceSequenceNumber: UInt64
    public let hasLastFrameSourceDisplayTime: Bool
    public let lastFrameSourceDisplayTime: UInt64
    public let lastFrameIsKeyFrame: Bool
    public let lastFrameIsHDRSignaled: Bool
    public let lastEventKindRawValue: Int

    init(snapshot: LumenBridgeVideoForwardingSnapshot) {
        self.frameCount = snapshot.frameCount
        self.eventCount = snapshot.eventCount
        self.queuedFrameCount = snapshot.queuedFrameCount
        self.queuedEventCount = snapshot.queuedEventCount
        self.droppedFrameCount = snapshot.droppedFrameCount
        self.droppedEventCount = snapshot.droppedEventCount
        self.hasLastSampleBuffer = snapshot.hasLastSampleBuffer
        self.lastFrameCodecRawValue = snapshot.lastFrameCodec.map(LumenBridgeObjCFacade.rawValue(for:)) ?? -1
        self.lastFramePayloadSize = snapshot.lastFramePayloadSize
        self.hasLastFrameSourceSequenceNumber = snapshot.lastFrameSourceSequenceNumber != nil
        self.lastFrameSourceSequenceNumber = snapshot.lastFrameSourceSequenceNumber ?? 0
        self.hasLastFrameSourceDisplayTime = snapshot.lastFrameSourceDisplayTime != nil
        self.lastFrameSourceDisplayTime = snapshot.lastFrameSourceDisplayTime ?? 0
        self.lastFrameIsKeyFrame = snapshot.lastFrameIsKeyFrame
        self.lastFrameIsHDRSignaled = snapshot.lastFrameIsHDRSignaled
        self.lastEventKindRawValue = snapshot.lastEventKind.map(LumenBridgeObjCFacade.rawValue(for:)) ?? -1
    }
}

@objcMembers
public final class LumenBridgeDrainedAudioFrameBox: NSObject {
    public let sequenceNumber: UInt64
    public let hostTimeNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let pcmFloat32LE: NSData

    init(frame: LumenBridgeDrainedAudioFrame) {
        self.sequenceNumber = frame.sequenceNumber
        self.hostTimeNanoseconds = frame.hostTimeNanoseconds
        self.sampleRate = frame.sampleRate
        self.channelCount = frame.channelCount
        self.frameCount = frame.frameCount
        self.pcmFloat32LE = frame.pcmFloat32LE as NSData
    }
}

@objcMembers
public final class LumenBridgeDrainedFrameBox: NSObject {
    public let codecRawValue: Int
    public let payloadSize: Int
    public let sourceSequenceNumber: UInt64
    public let sourceDisplayTime: UInt64
    public let hasOutputCallbackLatencyMilliseconds: Bool
    public let outputCallbackLatencyMilliseconds: Double
    public let isKeyFrame: Bool
    public let requiresBootstrapAcknowledgement: Bool
    public let isRepairKeyFrame: Bool
    public let isHDRSignaled: Bool
    public let isReplay: Bool
    public let sampleBuffer: CMSampleBuffer

    init(frame: LumenBridgeDrainedVideoFrame) {
        self.codecRawValue = LumenBridgeObjCFacade.rawValue(for: frame.codec)
        self.payloadSize = frame.payloadSize
        self.sourceSequenceNumber = frame.sourceSequenceNumber
        self.sourceDisplayTime = frame.sourceDisplayTime
        self.hasOutputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds != nil
        self.outputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds ?? 0
        self.isKeyFrame = frame.isKeyFrame
        self.requiresBootstrapAcknowledgement = frame.requiresBootstrapAcknowledgement
        self.isRepairKeyFrame = frame.isRepairKeyFrame
        self.isHDRSignaled = frame.isHDRSignaled
        self.isReplay = frame.isReplay
        self.sampleBuffer = frame.sampleBuffer
    }
}

@objcMembers
public final class LumenBridgeDrainedAudioEventBox: NSObject {
    public let kindRawValue: Int
    public let message: String?
    public let hasStopStatus: Bool
    public let stopStatus: Int32
    public let hasAutomaticRestartCount: Bool
    public let automaticRestartCount: UInt64
    public let hasSourceSequenceNumber: Bool
    public let sourceSequenceNumber: UInt64

    init(event: LumenBridgeDrainedAudioEvent) {
        self.kindRawValue = LumenBridgeObjCFacade.rawValue(for: event.kind)
        self.message = event.message
        self.hasStopStatus = event.stopStatus != nil
        self.stopStatus = event.stopStatus ?? 0
        self.hasAutomaticRestartCount = event.automaticRestartCount != nil
        self.automaticRestartCount = event.automaticRestartCount ?? 0
        self.hasSourceSequenceNumber = event.sourceSequenceNumber != nil
        self.sourceSequenceNumber = event.sourceSequenceNumber ?? 0
    }
}

@objcMembers
public final class LumenBridgeDrainedEventBox: NSObject {
    public let kindRawValue: Int
    public let message: String?
    public let hasStopStatus: Bool
    public let stopStatus: Int32
    public let hasAutomaticRestartCount: Bool
    public let automaticRestartCount: UInt64
    public let hasSourceDisplayTime: Bool
    public let sourceDisplayTime: UInt64

    init(event: LumenBridgeDrainedVideoEvent) {
        self.kindRawValue = LumenBridgeObjCFacade.rawValue(for: event.kind)
        self.message = event.message
        self.hasStopStatus = event.stopStatus != nil
        self.stopStatus = event.stopStatus ?? 0
        self.hasAutomaticRestartCount = event.automaticRestartCount != nil
        self.automaticRestartCount = event.automaticRestartCount ?? 0
        self.hasSourceDisplayTime = event.sourceDisplayTime != nil
        self.sourceDisplayTime = event.sourceDisplayTime ?? 0
    }
}
