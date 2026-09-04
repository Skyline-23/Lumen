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

struct LumenEncodedFrameContext: @unchecked Sendable {
    let sequenceNumber: UInt64
    let displayTime: UInt64
    let submissionMachTime: UInt64
    let mediaEpoch: UInt64
    let bootstrapReason: LumenVideoBootstrapReason?
    /// Internal ownership only; the public frame ABI intentionally remains
    /// the two existing booleans (`requiresBootstrapAcknowledgement` and
    /// `isRepairKeyFrame`).
    let requiresBootstrapAcknowledgement: Bool
    // The SkyLight callback's IOSurface use-count lease must remain alive
    // until VideoToolbox emits (or cancels) this submission. Keeping it in the
    // output lifecycle context prevents the compositor surface from being
    // recycled while the hardware encoder still reads it.
    let sourceSurfaceLease: LumenMacSkyLightDisplayStreamFrameLease?
}

enum LumenVideoBootstrapReason: Equatable, Sendable {
    case initial
    case periodic
    case repair

    var requiresAcknowledgement: Bool { true }
    var isRepair: Bool { self == .repair }
}

enum LumenVideoBootstrapAdmissionDecision: Equatable, Sendable {
    case submitInitialKeyFrame
    case coalesceUntilAcknowledged
    case submitControlledKeyFrame(LumenVideoBootstrapReason)
    case coalesceControlledKeyFrame(LumenVideoBootstrapReason)
    case submit
}

enum LumenAutomaticKeyFrameAdmissionDecision: Equatable, Sendable {
    case promote(LumenVideoBootstrapReason)
    case discard
}

struct LumenVideoBootstrapAdmissionGate: Equatable, Sendable {
    private(set) var isAwaitingAcknowledgement = false
    private(set) var isOpen = false
    private(set) var pendingReason: LumenVideoBootstrapReason?

    var isAwaitingPeriodicAcknowledgement: Bool {
        isAwaitingAcknowledgement && pendingReason == .periodic
    }

    var hasPeriodicGenerationPending: Bool {
        pendingReason == .periodic
    }

    mutating func admitSourceFrame() -> LumenVideoBootstrapAdmissionDecision {
        if isOpen {
            return .submit
        }
        if isAwaitingAcknowledgement {
            if let pendingReason {
                if pendingReason == .initial {
                    return .coalesceUntilAcknowledged
                }
                return .coalesceControlledKeyFrame(pendingReason)
            }
            return .coalesceUntilAcknowledged
        }
        if let pendingReason {
            isAwaitingAcknowledgement = true
            if pendingReason == .initial {
                return .submitInitialKeyFrame
            }
            return .submitControlledKeyFrame(pendingReason)
        }
        isAwaitingAcknowledgement = true
        pendingReason = .initial
        return .submitInitialKeyFrame
    }

    mutating func acknowledgeConfiguration() -> Bool {
        guard isAwaitingAcknowledgement, !isOpen else { return false }
        isOpen = true
        isAwaitingAcknowledgement = false
        pendingReason = nil
        return true
    }

    mutating func beginBootstrapGeneration() -> Bool {
        beginBootstrapGeneration(reason: .repair)
    }

    mutating func beginBootstrapGeneration(
        reason: LumenVideoBootstrapReason
    ) -> Bool {
        guard isOpen else { return false }
        isOpen = false
        pendingReason = reason
        isAwaitingAcknowledgement = false
        return true
    }

    mutating func beginPeriodicBootstrapGeneration() -> Bool {
        beginBootstrapGeneration(reason: .periodic)
    }

    /// VideoToolbox can still emit a watchdog IDR without a host request. If
    /// no controlled generation owns the gate, classify it as repair so any
    /// already-encoded dependent delta causes one bounded post-ACK recovery.
    /// If a controlled generation is armed but not yet submitted, the IDR may
    /// satisfy that exact reason. Once a controlled submission is in flight,
    /// a second automatic IDR is discarded and the forced IDR remains owner.
    mutating func admitAutomaticKeyFrame()
        -> LumenAutomaticKeyFrameAdmissionDecision
    {
        if isOpen {
            isOpen = false
            isAwaitingAcknowledgement = true
            pendingReason = .repair
            return .promote(.repair)
        }
        if let pendingReason, !isAwaitingAcknowledgement {
            isAwaitingAcknowledgement = true
            return .promote(pendingReason)
        }
        return .discard
    }

    mutating func retryBootstrapSubmission() -> Bool {
        guard !isOpen, pendingReason != nil else { return false }
        isAwaitingAcknowledgement = false
        return true
    }

    mutating func cancelBootstrapSubmission() {
        guard !isOpen else { return }
        let wasInitial = pendingReason == .initial
        isAwaitingAcknowledgement = false
        pendingReason = nil
        if wasInitial {
            isOpen = false
        } else {
            isOpen = true
        }
    }

    /// Retire all ownership from the previous media epoch. The next controlled
    /// request can claim a fresh bootstrap even when a previous request was
    /// still awaiting its codec acknowledgement.
    mutating func resetForMediaEpoch() {
        isAwaitingAcknowledgement = false
        // Leave the fresh epoch open for the next controlled IDR request;
        // beginBootstrapGeneration(.repair) closes it and becomes the new
        // acknowledgement owner before VideoToolbox emits that key frame.
        isOpen = true
        pendingReason = nil
    }
}

struct LumenPendingVideoBootstrapSource: @unchecked Sendable {
    let imageBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let displayTime: UInt64
    let duration: CMTime
    let sequenceNumber: UInt64
    let sourceSurfaceLease: LumenMacSkyLightDisplayStreamFrameLease?
}

enum LumenEncoderSubmissionAttempt<Result: Sendable>: Sendable {
    case cancelled
    case submitted(Result)
}

/// Keeps VideoToolbox from turning hardware backpressure into a stale-frame
/// queue. ScreenCaptureKit retains its independently negotiated source queue;
/// the encoder owns at most two pipelined frames while admission coalesces one
/// latest source. The second slot preserves asynchronous hardware throughput
/// without restoring the old negotiated-depth backlog.
enum LumenRealtimeVideoEncoderAdmissionPolicy {
    static let maximumInflightFrameCount = 2

    static func hasCapacity(inflightFrameCount: Int) -> Bool {
        inflightFrameCount < maximumInflightFrameCount
    }
}

/// Keeps the synchronous VideoToolbox admission call off the ScreenCaptureKit
/// callback queue without invoking one non-Sendable compression session from
/// multiple threads. One source may be submitting and one latest source may
/// wait; newer waiting sources replace the older one.
final class LumenLatestFrameSerialEncoderAdmission<Source: Sendable, Result: Sendable>: @unchecked Sendable {
    private let ownerQueue: DispatchQueue
    private let submissionQueue: DispatchQueue
    private let hasSubmissionCapacity: @Sendable () -> Bool
    private let entryHandler: @Sendable (Source) -> Void
    private let submit:
        @Sendable (Source, @Sendable () -> Bool) ->
        LumenEncoderSubmissionAttempt<Result>
    private let completion: @Sendable (Source, Result) -> Void
    private var nextEntryID: UInt64 = 0
    private var activeEntryID: UInt64?
    private var activeSource: Source?
    private var activeSourceEnteredSubmission = false
    private var pendingSource: Source?
    private var stopping = false

    init(
        ownerQueue: DispatchQueue,
        submissionQueue: DispatchQueue,
        hasSubmissionCapacity: @escaping @Sendable () -> Bool = { true },
        entryHandler: @escaping @Sendable (Source) -> Void = { _ in },
        submit: @escaping @Sendable (
            Source,
            @Sendable () -> Bool
        ) -> LumenEncoderSubmissionAttempt<Result>,
        completion: @escaping @Sendable (Source, Result) -> Void
    ) {
        self.ownerQueue = ownerQueue
        self.submissionQueue = submissionQueue
        self.hasSubmissionCapacity = hasSubmissionCapacity
        self.entryHandler = entryHandler
        self.submit = submit
        self.completion = completion
    }

    /// Returns the older pending source replaced by `source`, if any.
    @discardableResult
    func offer(_ source: Source) -> Source? {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !stopping else {
            return source
        }
        promotePendingIfPossible()
        guard activeEntryID == nil,
              hasSubmissionCapacity() else {
            let replacedSource = pendingSource
            pendingSource = source
            return replacedSource
        }
        startSubmission(source)
        return nil
    }

    /// Stops new admission and returns every source that never entered the
    /// injected submit boundary. Calls already at that boundary remain active
    /// and are drained by `waitUntilSubmissionReturns()`.
    @discardableResult
    func beginStopping() -> [Source] {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !stopping else {
            return []
        }
        stopping = true

        var cancelledSources: [Source] = []
        if let activeSource,
           !activeSourceEnteredSubmission {
            cancelledSources.append(activeSource)
            clearActiveSubmission()
        }
        if let pendingSource {
            cancelledSources.append(pendingSource)
            self.pendingSource = nil
        }
        return cancelledSources
    }

    /// Fences all sources that have not entered VideoToolbox at a media epoch
    /// boundary. A source already inside VideoToolbox is retired by its epoch
    /// token when the callback returns.
    @discardableResult
    func resetForMediaEpoch() -> [Source] {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        stopping = true

        var cancelledSources: [Source] = []
        if let activeSource,
           !activeSourceEnteredSubmission {
            cancelledSources.append(activeSource)
            clearActiveSubmission()
        }
        if let pendingSource {
            cancelledSources.append(pendingSource)
            self.pendingSource = nil
        }
        return cancelledSources
    }

    func resumeAfterMediaEpoch() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        stopping = false
        promotePendingIfPossible()
    }

    func waitUntilSubmissionReturns() {
        dispatchPrecondition(condition: .notOnQueue(submissionQueue))
        submissionQueue.sync(flags: .barrier) {}
    }

    func resumePendingIfPossible() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        promotePendingIfPossible()
    }

    /// Removes a not-yet-submitted source from the encoder admission slot.
    /// Callers decide whether an automatic fallback must preserve it or a
    /// controlled request must discard it as older than the requested IDR.
    @discardableResult
    func takePendingSource() -> Source? {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        let source = pendingSource
        pendingSource = nil
        return source
    }

    private func startSubmission(_ source: Source) {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        precondition(activeEntryID == nil)
        nextEntryID &+= 1
        let entryID = nextEntryID
        activeEntryID = entryID
        activeSource = source
        activeSourceEnteredSubmission = false
        submissionQueue.async { [self] in
            let attempt = submit(source) {
                ownerQueue.sync { [self] in
                    didEnterSubmission(source, entryID: entryID)
                }
            }
            switch attempt {
            case .cancelled:
                ownerQueue.async { [self] in
                    finishCancelledSubmission(entryID: entryID)
                }
            case .submitted(let result):
                ownerQueue.async { [self] in
                    finishSubmission(
                        source,
                        entryID: entryID,
                        result: result
                    )
                }
            }
        }
    }

    private func didEnterSubmission(_ source: Source, entryID: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !stopping,
              activeEntryID == entryID else {
            return false
        }
        activeSourceEnteredSubmission = true
        entryHandler(source)
        return true
    }

    private func finishCancelledSubmission(entryID: UInt64) {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard activeEntryID == entryID else {
            return
        }
        clearActiveSubmission()
        promotePendingIfPossible()
    }

    private func finishSubmission(
        _ source: Source,
        entryID: UInt64,
        result: Result
    ) {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard activeEntryID == entryID else {
            return
        }
        completion(source, result)
        clearActiveSubmission()
        promotePendingIfPossible()
    }

    private func promotePendingIfPossible() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !stopping,
              activeEntryID == nil,
              hasSubmissionCapacity(),
              let pendingSource else {
            return
        }
        self.pendingSource = nil
        startSubmission(pendingSource)
    }

    private func clearActiveSubmission() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        activeEntryID = nil
        activeSource = nil
        activeSourceEnteredSubmission = false
    }
}

/// Tracks every accepted frame until its VideoToolbox callback has finished on
/// the runtime owner queue. Stop uses the same lifecycle object to keep
/// invalidation and the `.stopped` event behind all queued output processing.
final class LumenVideoToolboxOutputLifecycle<Context: Sendable>: @unchecked Sendable {
    private let ownerQueue: DispatchQueue
    private let pendingOutputs = DispatchGroup()
    private let notificationQueue = DispatchQueue(
        label: "dev.skyline23.lumen.sck.video.vt-output-drain",
        qos: .userInteractive
    )
    private var contexts: [UInt64: Context] = [:]

    init(ownerQueue: DispatchQueue) {
        self.ownerQueue = ownerQueue
    }

    func registerSubmission(id: UInt64, context: Context) {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        precondition(contexts[id] == nil)
        contexts[id] = context
        pendingOutputs.enter()
    }

    @discardableResult
    func cancelSubmission(id: UInt64) -> Context? {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard let context = contexts.removeValue(forKey: id) else {
            return nil
        }
        pendingOutputs.leave()
        return context
    }

    func enqueueOutput(
        id: UInt64?,
        processing: @escaping @Sendable (Context?) -> Void
    ) {
        ownerQueue.async { [self] in
            let context = id.flatMap { contexts.removeValue(forKey: $0) }
            defer {
                if context != nil {
                    pendingOutputs.leave()
                }
            }
            processing(context)
        }
    }

    func completeAndInvalidate(
        completeFrames: @Sendable () -> OSStatus,
        invalidate: @Sendable () -> Void,
        completionFailure: @Sendable (OSStatus, [Context]) -> Void
    ) async {
        dispatchPrecondition(condition: .notOnQueue(ownerQueue))
        let status = completeFrames()
        guard status == noErr else {
            invalidate()
            let cancelledContexts = ownerQueue.sync { [self] in
                cancelAllSubmissions()
            }
            completionFailure(status, cancelledContexts)
            return
        }
        await withCheckedContinuation { continuation in
            pendingOutputs.notify(queue: notificationQueue) {
                continuation.resume()
            }
        }
        invalidate()
    }

    private func cancelAllSubmissions() -> [Context] {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        let cancelledContexts = Array(contexts.values)
        contexts.removeAll(keepingCapacity: false)
        for _ in cancelledContexts {
            pendingOutputs.leave()
        }
        return cancelledContexts
    }
}

struct LumenVideoEncoderSubmission: Sendable {
    let source: LumenPendingVideoBootstrapSource
    let forceKeyFrame: Bool
    let bootstrapReason: LumenVideoBootstrapReason?
    let mediaEpoch: UInt64
    let offeredMachTime: UInt64
}

struct LumenVideoEncoderSubmissionResult: Sendable {
    let status: OSStatus
    let infoFlags: VTEncodeInfoFlags
    let invocationMilliseconds: Double
}

func writeScreenCaptureStartupDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data("Lumen ScreenCaptureKit \(message)\n".utf8))
}
