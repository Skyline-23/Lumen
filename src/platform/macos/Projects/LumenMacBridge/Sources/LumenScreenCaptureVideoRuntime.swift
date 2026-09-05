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
    static let captureQueueSpecificKey = DispatchSpecificKey<Void>()
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
    // The private SkyLight callback submits at most two asynchronous Metal
    // blits. These resources and counters are queue-owned; no extra
    // coordination primitive is needed at the C callback boundary.
    var skyLightMetalStagingResources:
        LumenSkyLightMetalStagingResources?
    var skyLightMetalStagingAdmission =
        LumenSkyLightMetalStagingAdmission()
    var skyLightMetalStagingGeneration =
        LumenSkyLightMetalStagingGeneration()
    var skyLightMetalStagingReleaseRequested = false
    var skyLightMetalCopyDrainWaiters: [CheckedContinuation<Void, Never>] = []
    var skyLightMetalStageSubmissionCount: UInt64 = 0
    var skyLightMetalStageCompletionCount: UInt64 = 0
    var skyLightMetalStageBusyDropCount: UInt64 = 0
    var skyLightMetalStagePoolAllocationFailureCount: UInt64 = 0
    var skyLightMetalStageTextureFailureCount: UInt64 = 0
    var skyLightMetalStageCommandBufferFailureCount: UInt64 = 0
    var skyLightMetalStageValidationFailureCount: UInt64 = 0
    var skyLightMetalStageTiming = LumenCaptureStageTimingAccumulator()
    var skyLightMetalStageLastError: String?
    // Lifecycle transitions are fenced on `queue` because capture start and
    // stop can suspend while either backend still owns callback delivery.
    var lifecycleStartInFlight = false
    var lifecycleStopRequested = false
    var lifecycleSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    var compressionSession: VTCompressionSession?
    var compressionSessionAvailable = false
    var appliedVideoBitRateKbps: Int?
    var encodingPlan: LumenVideoToolboxEncodingPlan?
    var prioritizesEncodingSpeedOverQuality = false
    var configuredThroughputMode: Int?
    var sourceContract: LumenExactCaptureSourceContract?
    var outputContract: LumenExactEncodedOutputContract?
    var sequenceNumber: UInt64 = 0
    /// Internal capture epoch used to retire VideoToolbox callbacks that were
    /// admitted before a park/resume queue boundary.
    var mediaEpoch: UInt64 = 0
    var mediaEpochAdmissionReset = false
    var adaptiveVideoDeliveryPolicy = LumenAdaptiveVideoDeliveryPolicyState()
    /// A capture-queue gate for unchanged-content cadence. It drops stale
    /// source samples before they enter the pending encoder queue; the
    /// VideoToolbox pacer remains the authoritative second boundary for
    /// encoder-pressure and client-divisor targets.
    var unchangedContentIngressPacer = LumenAdaptiveVideoFramePacer()
    /// Rust owns the adaptive decision window; Swift keeps the controller
    /// alive for the capture runtime and applies changed targets on
    /// `encoderQueue` only.
    var adaptiveFrameCadenceController: LumenAdaptiveFrameCadenceController?
    /// Rust owns the metadata-driven unchanged-content confirmation window.
    /// The target is composed with encoder-pressure adaptation at the pacer;
    /// no capture/configuration or decoder generation is restarted on a wake.
    var unchangedContentCadenceController:
        LumenUnchangedContentCadenceController?
    /// Queue-owned mirror of the last Rust content target. This avoids taking
    /// the controller mutex for every already-parked static callback.
    var unchangedContentTargetFrameRate = 0
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
    var captureCadenceTelemetry = LumenCaptureCadenceTelemetry()
    var encoderActivityWakeGate = LumenEncoderActivityWakeGate()
    var captureIngressTimings = LumenCaptureIngressTimings()
#if DEBUG
    // Opt-in, timing-only diagnostic on the existing capture callback queue.
    // Collect once per runtime; log only after the bounded sample is complete.
    let recordsLiveSourceArrivals =
        ProcessInfo.processInfo.environment["LUMEN_TRACE_SOURCE_ARRIVALS"] == "1"
    var liveSourceSlowWindows = 0
    var liveSourceArrivalOrigin: UInt64?
    var liveSourceArrivalOffsets: [UInt64] = []
    var liveSourcePresentationOrigin: CMTime?
    var liveSourcePresentationOffsets: [Int64] = []
#endif
    var outputOccupancyTimings = LumenCaptureOutputOccupancyTimings()
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
    var statisticsPublicationPolicy =
        LumenEncodedCaptureStatisticsPublicationPolicy()
    var dropEventPublicationPolicy =
        LumenEncodedCaptureStatisticsPublicationPolicy()
    var statisticsNotesRefreshGate =
        LumenEncodedCaptureStatisticsNotesRefreshGate()
    var outputOwnership = LumenScreenCaptureOutputOwnership()
    var displayAdmissionMode = LumenScreenCaptureDisplayAdmissionMode.shareableContentEnumeration
    var displayAdmissionDurationMilliseconds = 0.0
    var streamStartDurationMilliseconds = 0.0
    var didLogScreenFrameGeometry = false
    lazy var outputLifecycle =
        LumenVideoToolboxOutputLifecycle<LumenEncodedFrameContext>(
            ownerQueue: queue
        )
    let encoderOverlapClock = LumenEncoderOverlapClock()
    var encoderOverlapEnabled = true
    var encoderOverlapEpoch: UInt64?
    var encoderOverlapLastOutput: UInt64?
    var encoderOverlapIntervalMilliseconds: Double?
    var encoderOverlapNotBefore: ContinuousClock.Instant?
    var encoderOverlapWakeScheduled = false
    lazy var encoderAdmission = LumenLatestFrameSerialEncoderAdmission<
        LumenVideoEncoderSubmission,
        LumenVideoEncoderSubmissionResult
    >(
        ownerQueue: queue,
        submissionQueue: encoderQueue,
        hasSubmissionCapacity: { [weak self] in
            guard let self else { return false }
            return self.hasFreshEncoderSubmissionCapacity()
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
        queue.setSpecific(key: Self.captureQueueSpecificKey, value: ())
        unchangedContentIngressPacer = LumenAdaptiveVideoFramePacer(
            frameRateCeiling: configuration.effectiveTargetFrameRate
        )
        adaptiveFrameCadenceController = LumenAdaptiveFrameCadenceController(
            requestedFrameRate: configuration.effectiveTargetFrameRate
        )
        unchangedContentCadenceController =
            LumenUnchangedContentCadenceController(
                requestedFrameRate: configuration.effectiveTargetFrameRate
            )
        unchangedContentTargetFrameRate =
            configuration.effectiveTargetFrameRate
    }

}
