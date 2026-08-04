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
    SCStreamOutput,
    SCStreamDelegate,
    LumenEncodedCaptureRuntime,
    @unchecked Sendable {
    static let startupLogger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )
    let configuration: LumenMacCaptureConfiguration
    let frameHandler: @Sendable (LumenEncodedFrame) -> Void
    let eventHandler: @Sendable (LumenEncodedCaptureSessionEvent) -> Void
    let statisticsHandler: @Sendable (LumenEncodedCaptureSessionStatistics) -> Void
    let terminationHandler: @Sendable (Error) -> Void
    let queue = DispatchQueue(label: "dev.skyline23.lumen.sck.video", qos: .userInteractive)
    let encoderQueue = DispatchQueue(
        label: "dev.skyline23.lumen.sck.video.vt-admission",
        qos: .userInteractive
    )
    var stream: SCStream?
    // Lifecycle transitions are fenced on `queue` because `startCapture` and
    // `stopCapture` suspend at the ScreenCaptureKit callback boundary.
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
    /// Rust owns the adaptive decision window; Swift keeps the controller
    /// alive for the capture runtime and applies changed targets on
    /// `encoderQueue` only.
    var adaptiveFrameCadenceController: LumenAdaptiveFrameCadenceController?
    /// This is deliberately narrower than the public pending-admission
    /// diagnostic.  Only latest-frame replacement and VideoToolbox drops are
    /// fed to Rust; source samples skipped by the intentional pacer are not
    /// encoder pressure.
    var encoderPendingDropCount: UInt64 = 0
    var lastQueuedEncoderSequenceNumber: UInt64?
    var lastQueuedEncoderPresentationTime: CMTime?
    var videoBootstrapAdmission = LumenVideoBootstrapAdmissionGate()
    var pendingVideoBootstrapSource: LumenPendingVideoBootstrapSource?
    var inflightFrameCount = 0
    var stopping = false
    var firstSourceMachTime: UInt64?
    var lastSourceMachTime: UInt64?
    var lastOutputMachTime: UInt64?
    var sourceIntervalTotalMilliseconds = 0.0
    var sourceIntervalSampleCount: UInt64 = 0
    var outputIntervalTotalMilliseconds = 0.0
    var outputIntervalSampleCount: UInt64 = 0
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
        self.frameHandler = callbacks.frameHandler
        self.eventHandler = { callbacks.eventHandler?($0) }
        self.statisticsHandler = statisticsHandler
        self.terminationHandler = terminationHandler
        super.init()
        adaptiveFrameCadenceController = LumenAdaptiveFrameCadenceController(
            requestedFrameRate: configuration.effectiveTargetFrameRate
        )
    }

}
