import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization
import VideoToolbox

final class LumenScreenCaptureVideoRuntime:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    SCStreamOutput,
    SCStreamDelegate,
    LumenEncodedCaptureRuntime,
    @unchecked Sendable {
    static let startupLogger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )
    static let pipelineLogger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "CapturePipeline"
    )
    let configuration: LumenMacCaptureConfiguration
    let captureBackend: LumenVideoCaptureBackend
    let frameHandler: @Sendable (LumenEncodedFrame) -> Void
    let eventHandler: @Sendable (LumenEncodedCaptureSessionEvent) -> Void
    let statisticsHandler: @Sendable (LumenEncodedCaptureSessionStatistics) -> Void
    let terminationHandler: @Sendable (Error) -> Void
    let queue = DispatchQueue(label: "dev.skyline23.lumen.sck.video", qos: .userInteractive)
    let encoderQueue = DispatchQueue(
        label: "dev.skyline23.lumen.sck.video.vt-admission",
        qos: .userInteractive
    )
    let captureControlQueue = DispatchQueue(
        label: "dev.skyline23.lumen.avfoundation.video.session",
        qos: .userInteractive
    )
    var stream: SCStream?
    var avCaptureHandle: LumenAVCaptureSessionHandle?
    var skyLightDisplayStream: LumenSkyLightDisplayStream?
    var skyLightDisplayStreamIdentity: UInt?
    var skyLightStopStatus: Int32?
    var skyLightCaptureFailureReported = false
    // CGDisplayStream supplies compositor display times in mach ticks. Keep a
    // per-stream origin and the last emitted PTS so raw frames preserve real
    // display cadence while still satisfying VideoToolbox's strict ordering
    // contract when the private callback repeats or regresses a timestamp.
    var skyLightFirstDisplayTime: UInt64?
    var skyLightLastPresentationTime: CMTime?
    var didLogSkyLightFirstFrame = false
    // Lifecycle transitions are fenced on `queue` because capture start and
    // stop can suspend while either backend still owns callback delivery.
    var lifecycleStartInFlight = false
    var lifecycleStopRequested = false
    var lifecycleSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    var compressionSession: VTCompressionSession?
    var compressionSessionAvailable = false
    var appliedVideoBitRateKbps: Int?
    var encodingPlan: LumenVideoToolboxEncodingPlan?
    var sourceContract: LumenExactCaptureSourceContract?
    var outputContract: LumenExactEncodedOutputContract?
    var sequenceNumber: UInt64 = 0
    var adaptiveVideoDeliveryPolicy = LumenAdaptiveVideoDeliveryPolicyState()
    var lastQueuedEncoderSequenceNumber: UInt64?
    var lastQueuedEncoderPresentationTime: CMTime?
    var videoBootstrapAdmission = LumenVideoBootstrapAdmissionGate()
    var pendingVideoBootstrapSource: LumenPendingVideoBootstrapSource?
    var inflightFrameCount = 0
    var stopping = false
    var captureCadenceTelemetry = LumenCaptureCadenceTelemetry()
    var captureIngressTimings = LumenCaptureIngressTimings()
    var sourceCallbackServiceTiming = LumenCaptureStageTimingAccumulator()
    var encoderAdmissionWaitTiming = LumenCaptureStageTimingAccumulator()
    var encoderInvocationTiming = LumenCaptureStageTimingAccumulator()
    var videoToolboxCallbackTiming = LumenCaptureStageTimingAccumulator()
    var outputOwnerQueueWaitTiming = LumenCaptureStageTimingAccumulator()
    var outputServiceTiming = LumenCaptureStageTimingAccumulator()
    var frameHandlerTiming = LumenCaptureStageTimingAccumulator()
    var bitrateUpdateQueueWaitTiming = LumenCaptureStageTimingAccumulator()
    var bitrateUpdateApplyTiming = LumenCaptureStageTimingAccumulator()
    var encodedBitrateTelemetry = LumenEncodedBitrateTelemetry()
    var outputWidth = 0
    var outputHeight = 0
    var sourceColorContractStatus = "not-required"
    var sourceColorContractFailureReported = false
    var terminalContractFailureReported = false
    var statistics = LumenEncodedCaptureSessionStatistics()
    var outputOwnership = LumenScreenCaptureOutputOwnership()
    var displayAdmissionMode = LumenScreenCaptureDisplayAdmissionMode.shareableContentEnumeration
    var displayAdmissionDurationMilliseconds = 0.0
    var streamStartDurationMilliseconds = 0.0
    var didLogScreenFrameGeometry = false
    lazy var outputLifecycle =
        LumenVideoToolboxOutputLifecycle<LumenEncodedFrameContext>(
            ownerQueue: queue
        )
    lazy var encoderAdmission = LumenLatestFrameSerialEncoderAdmission<
        LumenVideoEncoderSubmission,
        LumenVideoEncoderSubmissionResult
    >(
        ownerQueue: queue,
        submissionQueue: encoderQueue,
        hasSubmissionCapacity: { [weak self] in
            guard let self else { return false }
            return LumenRealtimeVideoEncoderAdmissionPolicy.hasCapacity(
                inflightFrameCount: self.inflightFrameCount
            )
        },
        entryHandler: { [weak self] submission in
            self?.willSubmitToVideoToolbox(submission)
        },
        submit: { [weak self] submission, entered in
            guard let self else {
                return .cancelled
            }
            return self.submitToVideoToolbox(submission, entered: entered)
        },
        completion: { [weak self] submission, result in
            self?.didSubmitToVideoToolbox(submission, result: result)
        }
    )

    init(
        configuration: LumenMacCaptureConfiguration,
        callbacks: LumenEncodedCaptureCallbacks,
        statisticsHandler: @escaping @Sendable (LumenEncodedCaptureSessionStatistics) -> Void,
        terminationHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        self.configuration = configuration
        captureBackend = LumenVideoCaptureBackend.preferred(
            for: configuration,
            skyLightDisplayStreamAvailable: LumenSkyLightDisplayStream.isSupported()
        )
        self.frameHandler = callbacks.frameHandler
        self.eventHandler = { callbacks.eventHandler?($0) }
        self.statisticsHandler = statisticsHandler
        self.terminationHandler = terminationHandler
        super.init()
    }

}
