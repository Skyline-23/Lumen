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

struct LumenVideoChromaticityPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct LumenVideoMasteringDisplayColorVolume: Equatable, Sendable {
    let redPrimary: LumenVideoChromaticityPoint
    let greenPrimary: LumenVideoChromaticityPoint
    let bluePrimary: LumenVideoChromaticityPoint
    let whitePoint: LumenVideoChromaticityPoint
    let maxLuminance: Double
    let minLuminance: Double

    static func hdr10Default() -> Self {
        Self(
            redPrimary: .init(x: 0.708, y: 0.292),
            greenPrimary: .init(x: 0.170, y: 0.797),
            bluePrimary: .init(x: 0.131, y: 0.046),
            whitePoint: .init(x: 0.3127, y: 0.3290),
            maxLuminance: 1_000,
            minLuminance: 0.001
        )
    }
}

struct LumenVideoContentLightLevelInfo: Equatable, Sendable {
    let maximumContentLightLevel: Int
    let maximumFrameAverageLightLevel: Int

    static func hdr10Default() -> Self {
        Self(maximumContentLightLevel: 1_000, maximumFrameAverageLightLevel: 400)
    }
}

enum LumenVideoColorPrimaries: String, Equatable, Sendable {
    case ituR709
    case p3D65
    case ituR2020

    var coreMediaValue: CFString {
        switch self {
        case .ituR709: return kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case .p3D65: return kCMFormatDescriptionColorPrimaries_P3_D65
        case .ituR2020: return kCMFormatDescriptionColorPrimaries_ITU_R_2020
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case .p3D65: return kCVImageBufferColorPrimaries_P3_D65
        case .ituR2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        }
    }
}

enum LumenVideoTransferFunction: String, Equatable, Sendable {
    case ituR709
    case smpteSt2084PQ
    case ituR2100HLG

    var coreMediaValue: CFString {
        switch self {
        case .ituR709: return kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case .smpteSt2084PQ: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .ituR2100HLG: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709: return kCVImageBufferTransferFunction_ITU_R_709_2
        case .smpteSt2084PQ: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .ituR2100HLG: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }
}

enum LumenVideoYCbCrMatrix: String, Equatable, Sendable {
    case ituR709
    case ituR2020

    var coreMediaValue: CFString {
        switch self {
        case .ituR709: return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case .ituR2020: return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .ituR2020: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
    }
}

struct LumenVideoHDRConfiguration: Equatable, Sendable {
    let sourceColorPrimaries: LumenVideoColorPrimaries
    let colorPrimaries: LumenVideoColorPrimaries
    let transferFunction: LumenVideoTransferFunction
    let yCbCrMatrix: LumenVideoYCbCrMatrix
    let masteringDisplayColorVolume: LumenVideoMasteringDisplayColorVolume?
    let contentLightLevelInfo: LumenVideoContentLightLevelInfo?

    init(
        sourceColorPrimaries: LumenVideoColorPrimaries,
        colorPrimaries: LumenVideoColorPrimaries,
        transferFunction: LumenVideoTransferFunction,
        yCbCrMatrix: LumenVideoYCbCrMatrix,
        metadataInsertionMode: LumenVideoMetadataInsertionMode = .automatic,
        masteringDisplayColorVolume: LumenVideoMasteringDisplayColorVolume? = nil,
        contentLightLevelInfo: LumenVideoContentLightLevelInfo? = nil
    ) {
        _ = metadataInsertionMode
        self.sourceColorPrimaries = sourceColorPrimaries
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
    }

}

struct LumenCaptureColorContract: Equatable, Sendable {
    let pixelFormat: OSType
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String

    init(pixelFormat: OSType, color: LumenVideoHDRConfiguration) {
        self.pixelFormat = pixelFormat
        self.colorPrimaries = color.colorPrimaries.imageBufferValue as String
        self.transferFunction = color.transferFunction.imageBufferValue as String
        self.yCbCrMatrix = color.yCbCrMatrix.imageBufferValue as String
    }

    func mismatchDescription(for imageBuffer: CVImageBuffer) -> String? {
        let actualPixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        guard actualPixelFormat == pixelFormat else {
            return "pixel-format expected=\(fourCC(pixelFormat)) actual=\(fourCC(actualPixelFormat))"
        }

        let expectedAttachments: [(CFString, String, String)] = [
            (kCVImageBufferColorPrimariesKey, colorPrimaries, "primaries"),
            (kCVImageBufferTransferFunctionKey, transferFunction, "transfer"),
            (kCVImageBufferYCbCrMatrixKey, yCbCrMatrix, "matrix")
        ]
        for (key, expected, name) in expectedAttachments {
            let actual = CVBufferCopyAttachment(imageBuffer, key, nil)
            guard let actualString = actual as? String else {
                return "\(name) expected=\(expected) actual=missing"
            }
            guard actualString == expected else {
                return "\(name) expected=\(expected) actual=\(actualString)"
            }
        }
        return nil
    }

    private func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

enum LumenCaptureStreamConfigurationFactory {
    static func make(configuration: LumenMacCaptureConfiguration) -> SCStreamConfiguration {
        if configuration.chromaSubsampling == .yuv444,
           configuration.dynamicRange == .hdr10,
           #available(macOS 15.0, *) {
            let result = SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
            result.captureDynamicRange = .hdrCanonicalDisplay
            result.pixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            result.colorSpaceName = CGColorSpace.itur_2100_PQ
            result.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
            result.showsCursor = true
            return result
        }
        return make(usesHDRTransport: configuration.usesHDRTransport)
    }

    static func make(usesHDRTransport: Bool) -> SCStreamConfiguration {
        let configuration: SCStreamConfiguration
        if !usesHDRTransport {
            configuration = SCStreamConfiguration()
        } else if #available(macOS 26.0, *) {
            configuration = SCStreamConfiguration(preset: .captureHDRRecordingPreservedSDRHDR10)
        } else if #available(macOS 15.0, *) {
            let result = SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
            result.captureDynamicRange = .hdrCanonicalDisplay
            result.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            result.colorSpaceName = CGColorSpace.itur_2100_PQ
            result.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
            configuration = result
        } else {
            configuration = SCStreamConfiguration()
        }

        configuration.showsCursor = true
        return configuration
    }
}

private extension LumenVideoMasteringDisplayColorVolume {
    var encodedData: Data {
        var data = Data(capacity: 24)
        [
            redPrimary.x, redPrimary.y,
            greenPrimary.x, greenPrimary.y,
            bluePrimary.x, bluePrimary.y,
            whitePoint.x, whitePoint.y
        ].map(Self.encodeChromaticity).forEach { value in
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        [Self.encodeLuminance(maxLuminance), Self.encodeLuminance(minLuminance)].forEach { value in
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func encodeChromaticity(_ value: Double) -> UInt16 {
        UInt16(clamping: Int((min(max(value, 0), 1) * 50_000).rounded()))
    }

    static func encodeLuminance(_ value: Double) -> UInt32 {
        UInt32(clamping: Int((max(value, 0) * 10_000).rounded()))
    }
}

private extension LumenVideoContentLightLevelInfo {
    var encodedData: Data {
        var data = Data(capacity: 4)
        [maximumContentLightLevel, maximumFrameAverageLightLevel].forEach { value in
            var bigEndian = UInt16(clamping: value).bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

enum LumenVideoMetadataInsertionMode: Sendable {
    case automatic
}

struct LumenHDRValidationReport: Equatable, Sendable {
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let hasMasteringDisplayColorVolume: Bool
    let hasContentLightLevelInfo: Bool
}

struct LumenEncodedFrame: Sendable {
    private let sampleBufferHandle: LumenSampleBufferHandle
    let codec: LumenCaptureCodec
    let sourceSequenceNumber: UInt64
    let sourceDisplayTime: UInt64
    let outputCallbackLatencyMilliseconds: Double?
    let isKeyFrame: Bool
    let requiresBootstrapAcknowledgement: Bool
    let isRepairKeyFrame: Bool
    let isHDRSignaled: Bool
    let hdrValidationReport: LumenHDRValidationReport

    init(
        sampleBuffer: CMSampleBuffer,
        codec: LumenCaptureCodec,
        sourceSequenceNumber: UInt64,
        sourceDisplayTime: UInt64,
        outputCallbackLatencyMilliseconds: Double?,
        isKeyFrame: Bool,
        requiresBootstrapAcknowledgement: Bool,
        isRepairKeyFrame: Bool,
        isHDRSignaled: Bool,
        hdrValidationReport: LumenHDRValidationReport
    ) {
        sampleBufferHandle = LumenSampleBufferHandle(retaining: sampleBuffer)
        self.codec = codec
        self.sourceSequenceNumber = sourceSequenceNumber
        self.sourceDisplayTime = sourceDisplayTime
        self.outputCallbackLatencyMilliseconds = outputCallbackLatencyMilliseconds
        self.isKeyFrame = isKeyFrame
        self.requiresBootstrapAcknowledgement = requiresBootstrapAcknowledgement
        self.isRepairKeyFrame = isRepairKeyFrame
        self.isHDRSignaled = isHDRSignaled
        self.hdrValidationReport = hdrValidationReport
    }

    var sampleBuffer: CMSampleBuffer {
        sampleBufferHandle.value
    }
}

public enum LumenEncodedCaptureSessionEventKind: String, Equatable, Sendable {
    case started
    case stopped
    case restarted
    case failed
    case droppedFrame
    case coalescedFrame
}

public struct LumenEncodedCaptureSessionEvent: Equatable, Sendable {
    let kind: LumenEncodedCaptureSessionEventKind
    let message: String?
    let stopStatus: Int32?
    let automaticRestartCount: UInt64?
    let sourceDisplayTime: UInt64?

    init(
        kind: LumenEncodedCaptureSessionEventKind,
        message: String? = nil,
        stopStatus: Int32? = nil,
        automaticRestartCount: UInt64? = nil,
        sourceDisplayTime: UInt64? = nil
    ) {
        self.kind = kind
        self.message = message
        self.stopStatus = stopStatus
        self.automaticRestartCount = automaticRestartCount
        self.sourceDisplayTime = sourceDisplayTime
    }
}

struct LumenEncodedCaptureCallbacks: Sendable {
    let frameHandler: @Sendable (LumenEncodedFrame) -> Void
    let eventHandler: (@Sendable (LumenEncodedCaptureSessionEvent) -> Void)?
}

public struct LumenEncodedCaptureSessionStatistics: Equatable, Sendable {
    var emittedFrameCount: UInt64 = 0
    var droppedFrameCount: UInt64 = 0
    var processingFailureCount: UInt64 = 0
    var automaticRestartCount: UInt64 = 0
    var sourceFrameCount: UInt64 = 0
    var submittedFrameCount: UInt64 = 0
    var pendingAdmissionDropCount: UInt64 = 0
    var maximumInflightFrameCount: Int = 0
    var lastErrorDescription: String?
    var isRunning = false
    var minOutputCallbackLatencyMilliseconds: Double?
    var maxOutputCallbackLatencyMilliseconds: Double?
    var notes: [String] = []
    var exactCaptureAudit = LumenExactCaptureAuditSnapshot()
}

struct LumenCaptureStageTimingAccumulator: Equatable, Sendable {
    private(set) var sampleCount: UInt64 = 0
    private(set) var totalMilliseconds = 0.0
    private(set) var minimumMilliseconds: Double?
    private(set) var maximumMilliseconds: Double?

    var averageMilliseconds: Double? {
        guard sampleCount > 0 else { return nil }
        return totalMilliseconds / Double(sampleCount)
    }

    mutating func observe(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        sampleCount &+= 1
        totalMilliseconds += milliseconds
        minimumMilliseconds = min(minimumMilliseconds ?? milliseconds, milliseconds)
        maximumMilliseconds = max(maximumMilliseconds ?? milliseconds, milliseconds)
    }
}

struct LumenCaptureIngressTimings: Equatable, Sendable {
    private var previousDisplayMachTime: UInt64?
    private(set) var displayInterval = LumenCaptureStageTimingAccumulator()
    private(set) var displayToCallback = LumenCaptureStageTimingAccumulator()

    mutating func observe(
        displayedMachTime: UInt64?,
        callbackMachTime: UInt64
    ) {
        guard let displayedMachTime,
              displayedMachTime <= callbackMachTime else {
            return
        }
        displayToCallback.observe(
            LumenMachTime.milliseconds(
                from: displayedMachTime,
                to: callbackMachTime
            )
        )
        guard let previousDisplayMachTime else {
            self.previousDisplayMachTime = displayedMachTime
            return
        }
        guard displayedMachTime > previousDisplayMachTime else {
            return
        }
        displayInterval.observe(
            LumenMachTime.milliseconds(
                from: previousDisplayMachTime,
                to: displayedMachTime
            )
        )
        self.previousDisplayMachTime = displayedMachTime
    }

    var diagnosticNotes: [String] {
        var notes = lumenCaptureTimingNotes(
            prefix: "sourceDisplayInterval",
            timing: displayInterval
        )
        notes.append(
            "sourceDisplayApproxFrameRate=\(lumenApproximateFrameRate(displayInterval))"
        )
        notes.append(contentsOf: lumenCaptureTimingNotes(
            prefix: "sourceDisplayToCallback",
            timing: displayToCallback
        ))
        return notes
    }
}

func lumenCaptureTimingNotes(
    prefix: String,
    timing: LumenCaptureStageTimingAccumulator
) -> [String] {
    [
        "\(prefix)SampleCount=\(timing.sampleCount)",
        "\(prefix)AverageMilliseconds=\(lumenFormattedTiming(timing.averageMilliseconds))",
        "\(prefix)MinimumMilliseconds=\(lumenFormattedTiming(timing.minimumMilliseconds))",
        "\(prefix)MaximumMilliseconds=\(lumenFormattedTiming(timing.maximumMilliseconds))"
    ]
}

private func lumenFormattedTiming(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.3f", value)
}

private func lumenApproximateFrameRate(
    _ timing: LumenCaptureStageTimingAccumulator
) -> String {
    guard let averageMilliseconds = timing.averageMilliseconds,
          averageMilliseconds > 0 else {
        return "n/a"
    }
    return String(format: "%.2f", 1_000 / averageMilliseconds)
}

struct LumenExactCaptureAuditSnapshot: Codable, Equatable, Sendable {
    var inputFourCC: String?
    var lumaPlaneWidth: Int?
    var lumaPlaneHeight: Int?
    var chromaPlaneWidth: Int?
    var chromaPlaneHeight: Int?
    var colorPrimaries: String?
    var transferFunction: String?
    var yCbCrMatrix: String?
    var profile: String?
    var hardwareUsed: Bool?
    var configurationAtom: String?
    var profileIdc: Int?
    var chromaFormatIdc: Int?
    var lumaBitDepth: Int?
    var chromaBitDepth: Int?
    var conversionCount: Int = 0
    var allowOpenGOP: Bool?
}

private struct LumenEncodedFrameContext: Sendable {
    let sequenceNumber: UInt64
    let displayTime: UInt64
    let submissionMachTime: UInt64
    let requiresBootstrapAcknowledgement: Bool
}

enum LumenVideoBootstrapAdmissionDecision: Equatable, Sendable {
    case submitInitialKeyFrame
    case coalesceUntilAcknowledged
    case submit
}

struct LumenVideoBootstrapAdmissionGate: Equatable, Sendable {
    private(set) var isAwaitingAcknowledgement = false
    private(set) var isOpen = false

    mutating func admitSourceFrame() -> LumenVideoBootstrapAdmissionDecision {
        if isOpen {
            return .submit
        }
        if isAwaitingAcknowledgement {
            return .coalesceUntilAcknowledged
        }
        isAwaitingAcknowledgement = true
        return .submitInitialKeyFrame
    }

    mutating func acknowledgeConfiguration() -> Bool {
        guard isAwaitingAcknowledgement, !isOpen else { return false }
        isOpen = true
        isAwaitingAcknowledgement = false
        return true
    }

    mutating func beginBootstrapGeneration() -> Bool {
        guard isOpen else { return false }
        isOpen = false
        isAwaitingAcknowledgement = false
        return true
    }

    mutating func cancelBootstrapSubmission() {
        guard isAwaitingAcknowledgement, !isOpen else { return }
        isAwaitingAcknowledgement = false
    }
}

private struct LumenPendingVideoBootstrapSource: @unchecked Sendable {
    let imageBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let displayTime: UInt64
    let duration: CMTime
    let sequenceNumber: UInt64
}

enum LumenEncoderSubmissionAttempt<Result: Sendable>: Sendable {
    case cancelled
    case submitted(Result)
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

    func waitUntilSubmissionReturns() {
        dispatchPrecondition(condition: .notOnQueue(submissionQueue))
        submissionQueue.sync(flags: .barrier) {}
    }

    func resumePendingIfPossible() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        promotePendingIfPossible()
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

private struct LumenVideoEncoderSubmission: Sendable {
    let source: LumenPendingVideoBootstrapSource
    let forceKeyFrame: Bool
    let offeredMachTime: UInt64
}

private struct LumenVideoEncoderSubmissionResult: Sendable {
    let status: OSStatus
    let infoFlags: VTEncodeInfoFlags
    let invocationMilliseconds: Double
}

private func writeScreenCaptureStartupDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data("Lumen ScreenCaptureKit \(message)\n".utf8))
}

struct LumenScreenCaptureDisplayReadinessSnapshot: Equatable, Sendable {
    let ownerToken: UInt?
    let isOnline: Bool
    let isActive: Bool
    let hasCurrentMode: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let configuredPixelWidth: Int
    let configuredPixelHeight: Int

    init(
        ownerToken: UInt?,
        isOnline: Bool,
        isActive: Bool,
        hasCurrentMode: Bool,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        configuredPixelWidth: Int = 0,
        configuredPixelHeight: Int = 0
    ) {
        self.ownerToken = ownerToken
        self.isOnline = isOnline
        self.isActive = isActive
        self.hasCurrentMode = hasCurrentMode
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.configuredPixelWidth = configuredPixelWidth
        self.configuredPixelHeight = configuredPixelHeight
    }

    func isModeReady(
        for authority: LumenScreenCaptureDisplayAuthority
    ) -> Bool {
        guard isOnline, isActive else {
            return false
        }
        if hasCurrentMode {
            return true
        }
        switch authority {
        case .retained:
            // An app-only virtual-display topology can publish active CoreGraphics
            // state while its public mode and pixel geometry remain unavailable.
            // The retained object's nonzero configured geometry is safe to use
            // here because ownership is validated around the exact-ID query.
            return (pixelWidth > 0 && pixelHeight > 0) ||
                (configuredPixelWidth > 0 && configuredPixelHeight > 0)
        case .exactExternal:
            return false
        }
    }

    func isPreparedHandleReady(
        for authority: LumenScreenCaptureDisplayAuthority
    ) -> Bool {
        isModeReady(for: authority)
    }
}

struct LumenScreenCaptureDisplayReadinessTiming: Equatable, Sendable {
    let overallDeadlineNanoseconds: UInt64
    let queryTimeoutNanoseconds: UInt64
    let retryDelayNanoseconds: UInt64
    let maximumOutstandingQueries: Int

    init(
        overallDeadlineNanoseconds: UInt64,
        queryTimeoutNanoseconds: UInt64,
        retryDelayNanoseconds: UInt64,
        maximumOutstandingQueries: Int = 2
    ) {
        self.overallDeadlineNanoseconds = overallDeadlineNanoseconds
        self.queryTimeoutNanoseconds = queryTimeoutNanoseconds
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.maximumOutstandingQueries = max(maximumOutstandingQueries, 1)
    }

    static let production = Self(
        overallDeadlineNanoseconds: 15_000_000_000,
        // Successful publication has taken up to 2.37 seconds in production;
        // failed enumerations have stalled for 16-41 seconds.
        queryTimeoutNanoseconds: 3_000_000_000,
        retryDelayNanoseconds: 100_000_000,
        maximumOutstandingQueries: 2
    )
}

enum LumenScreenCaptureDisplayAuthority: Equatable, Sendable {
    case retained(ownerToken: UInt)
    case exactExternal
}

private enum LumenScreenCaptureTimedQueryOutcome<Value: Sendable>: @unchecked Sendable {
    case value(Value?)
    case failure(any Error)
    case timedOut
}

private actor LumenScreenCaptureTimedQueryRace<Value: Sendable> {
    private let generation: UInt64
    private var outcome: LumenScreenCaptureTimedQueryOutcome<Value>?
    private var continuation: CheckedContinuation<LumenScreenCaptureTimedQueryOutcome<Value>, Never>?

    init(generation: UInt64) {
        self.generation = generation
    }

    func finish(
        generation: UInt64,
        outcome: LumenScreenCaptureTimedQueryOutcome<Value>
    ) {
        guard generation == self.generation, self.outcome == nil else {
            return
        }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func wait() async -> LumenScreenCaptureTimedQueryOutcome<Value> {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

actor LumenScreenCaptureQueryBudget {
    private let maximumOutstandingQueries: Int
    private var nextGeneration: UInt64 = 0
    private var outstandingGenerations: Set<UInt64> = []

    init(maximumOutstandingQueries: Int) {
        self.maximumOutstandingQueries = max(maximumOutstandingQueries, 1)
    }

    func begin() -> UInt64? {
        guard outstandingGenerations.count < maximumOutstandingQueries else {
            return nil
        }
        nextGeneration &+= 1
        outstandingGenerations.insert(nextGeneration)
        return nextGeneration
    }

    func finish(generation: UInt64) {
        outstandingGenerations.remove(generation)
    }

    func outstandingCount() -> Int {
        outstandingGenerations.count
    }
}

enum LumenScreenCaptureDisplayResolver {
    typealias MonotonicNow = @Sendable () async -> UInt64
    typealias MonotonicSleep = @Sendable (UInt64) async -> Void
    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )

    static func resolve<Value: Sendable>(
        displayID: UInt32,
        authority: LumenScreenCaptureDisplayAuthority,
        timing: LumenScreenCaptureDisplayReadinessTiming,
        queryBudget: LumenScreenCaptureQueryBudget,
        now: @escaping MonotonicNow,
        sleepUntil: @escaping MonotonicSleep,
        readiness: @escaping @Sendable () async -> LumenScreenCaptureDisplayReadinessSnapshot,
        lookup: @escaping @Sendable (_ generation: UInt64) async throws -> Value?
    ) async throws -> Value {
        let startedAt = await now()
        let overallDeadline = addingClamped(
            startedAt,
            timing.overallDeadlineNanoseconds
        )
        while true {
            try Task.checkCancellation()
            let currentTime = await now()
            guard currentTime <= overallDeadline else {
                throw LumenScreenCaptureError.displayUnavailable(displayID)
            }

            let beforeQuery = await readiness()
            try validateOwnership(
                beforeQuery,
                displayID: displayID,
                authority: authority
            )
            guard beforeQuery.isModeReady(for: authority) else {
                guard currentTime < overallDeadline else {
                    throw LumenScreenCaptureError.displayUnavailable(displayID)
                }
                await sleepUntil(
                    min(
                        addingClamped(currentTime, timing.retryDelayNanoseconds),
                        overallDeadline
                    )
                )
                continue
            }

            guard let queryGeneration = await queryBudget.begin() else {
                guard currentTime < overallDeadline else {
                    throw LumenScreenCaptureError.displayUnavailable(displayID)
                }
                await sleepUntil(
                    min(
                        addingClamped(currentTime, timing.retryDelayNanoseconds),
                        overallDeadline
                    )
                )
                continue
            }
            let queryDeadline = min(
                addingClamped(currentTime, timing.queryTimeoutNanoseconds),
                overallDeadline
            )
            logger.notice(
                "stage=display-query-generation-start display-id=\(displayID, privacy: .public) generation=\(queryGeneration, privacy: .public)"
            )
            writeScreenCaptureStartupDiagnostic(
                "stage=display-query-generation-start display-id=\(displayID) generation=\(queryGeneration)"
            )
            let outcome = await performTimedQuery(
                displayID: displayID,
                generation: queryGeneration,
                deadline: queryDeadline,
                now: now,
                sleepUntil: sleepUntil,
                queryBudget: queryBudget,
                lookup: lookup
            )

            switch outcome {
            case .value(let value):
                try Task.checkCancellation()
                let completedAt = await now()
                try Task.checkCancellation()
                guard completedAt <= overallDeadline else {
                    throw LumenScreenCaptureError.displayUnavailable(displayID)
                }
                let afterQuery = await readiness()
                try Task.checkCancellation()
                try validateOwnership(
                    afterQuery,
                    displayID: displayID,
                    authority: authority
                )
                guard afterQuery.isModeReady(for: authority) else {
                    continue
                }
                if let value {
                    try Task.checkCancellation()
                    return value
                }
            case .failure(let error):
                let afterQuery = await readiness()
                try Task.checkCancellation()
                try validateOwnership(
                    afterQuery,
                    displayID: displayID,
                    authority: authority
                )
                throw error
            case .timedOut:
                logger.warning(
                    "stage=display-query-timeout display-id=\(displayID, privacy: .public) generation=\(queryGeneration, privacy: .public)"
                )
                writeScreenCaptureStartupDiagnostic(
                    "stage=display-query-timeout display-id=\(displayID) generation=\(queryGeneration)"
                )
                break
            }

            let retryTime = await now()
            guard retryTime < overallDeadline else {
                throw LumenScreenCaptureError.displayUnavailable(displayID)
            }
            await sleepUntil(
                min(
                    addingClamped(retryTime, timing.retryDelayNanoseconds),
                    overallDeadline
                )
            )
        }
    }

    static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }

    private static func validateOwnership(
        _ snapshot: LumenScreenCaptureDisplayReadinessSnapshot,
        displayID: UInt32,
        authority: LumenScreenCaptureDisplayAuthority
    ) throws {
        switch authority {
        case .retained(let ownerToken):
            guard snapshot.ownerToken == ownerToken else {
                throw LumenScreenCaptureError.displayOwnershipLost(displayID)
            }
        case .exactExternal:
            guard snapshot.ownerToken == nil else {
                throw LumenScreenCaptureError.displayUnavailable(displayID)
            }
        }
    }

    private static func performTimedQuery<Value: Sendable>(
        displayID: UInt32,
        generation: UInt64,
        deadline: UInt64,
        now: @escaping MonotonicNow,
        sleepUntil: @escaping MonotonicSleep,
        queryBudget: LumenScreenCaptureQueryBudget,
        lookup: @escaping @Sendable (_ generation: UInt64) async throws -> Value?
    ) async -> LumenScreenCaptureTimedQueryOutcome<Value> {
        let race = LumenScreenCaptureTimedQueryRace<Value>(generation: generation)
        let queryTask = Task {
            let outcome: LumenScreenCaptureTimedQueryOutcome<Value>
            do {
                outcome = .value(try await lookup(generation))
            } catch {
                outcome = .failure(error)
            }
            let completedAt = await now()
            if completedAt <= deadline {
                await race.finish(generation: generation, outcome: outcome)
            } else {
                logger.warning(
                    "stage=display-query-late-result-discarded display-id=\(displayID, privacy: .public) generation=\(generation, privacy: .public)"
                )
                writeScreenCaptureStartupDiagnostic(
                    "stage=display-query-late-result-discarded display-id=\(displayID) generation=\(generation)"
                )
            }
            await queryBudget.finish(generation: generation)
        }
        let timeoutTask = Task {
            // Reserve the exact boundary for a query that completed on time.
            await sleepUntil(addingClamped(deadline, 1))
            await race.finish(generation: generation, outcome: .timedOut)
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            Task {
                await race.finish(
                    generation: generation,
                    outcome: .failure(CancellationError())
                )
            }
        }
        queryTask.cancel()
        timeoutTask.cancel()
        return outcome
    }
}

enum LumenScreenCaptureDisplayAdmissionMode: String, Equatable, Sendable {
    case prefetchedShareableContent = "prefetched-shareable-content"
    case retainedShareableContent = "retained-shareable-content"
    case shareableContentEnumeration = "shareable-content-enumeration"
}

struct LumenScreenCaptureDisplayAdmissionResult<Value: Sendable>: Sendable {
    let value: Value
    let mode: LumenScreenCaptureDisplayAdmissionMode
}

enum LumenScreenCaptureDisplayAdmission {
    static func resolve<Value: Sendable>(
        displayID: UInt32,
        prefetched: @escaping @Sendable () async throws -> Value?,
        enumerateShareableContent: @escaping @Sendable () async throws ->
            LumenScreenCaptureDisplayAdmissionResult<Value>
    ) async throws -> LumenScreenCaptureDisplayAdmissionResult<Value> {
        if let value = try await prefetched() {
            return .init(value: value, mode: .prefetchedShareableContent)
        }
        return try await enumerateShareableContent()
    }
}

struct LumenScreenCaptureDisplayHandle: @unchecked Sendable {
    let value: SCDisplay
}

struct LumenRetainedVirtualDisplayReference: @unchecked Sendable {
    let display: LumenMacVirtualDisplay

    var ownerToken: UInt {
        UInt(bitPattern: ObjectIdentifier(display))
    }

    func isCurrent(displayID: UInt32) -> Bool {
        display.displayID == displayID &&
            LumenMacVirtualDisplay.registeredDisplay(forDisplayID: displayID) === display
    }
}

actor LumenExpectedDisplayOwnerStore<Owner: Sendable> {
    private var owners: [UInt32: Owner] = [:]

    func set(_ owner: Owner, displayID: UInt32) {
        owners[displayID] = owner
    }

    func owner(displayID: UInt32) -> Owner? {
        owners[displayID]
    }

    func discard(displayID: UInt32) {
        owners.removeValue(forKey: displayID)
    }
}

private struct LumenScreenCapturePreparedDisplay: @unchecked Sendable {
    let handle: LumenScreenCaptureDisplayHandle
    let owner: LumenRetainedVirtualDisplayReference
}

actor LumenPreparedDisplayStore<Value: Sendable> {
    private struct Entry {
        let ownerToken: UInt
        let generation: UInt64
        var value: Value?
        var expiresAt: UInt64?
    }

    private var entries: [UInt32: Entry] = [:]
    private var generations: [UInt32: UInt64] = [:]

    func begin(
        displayID: UInt32,
        ownerToken: UInt
    ) -> UInt64 {
        let generation = (generations[displayID] ?? 0) &+ 1
        generations[displayID] = generation
        entries[displayID] = Entry(
            ownerToken: ownerToken,
            generation: generation,
            value: nil,
            expiresAt: nil
        )
        return generation
    }

    func complete(
        displayID: UInt32,
        ownerToken: UInt,
        generation: UInt64,
        value: Value,
        expiresAt: UInt64
    ) throws {
        try Task.checkCancellation()
        guard var entry = entries[displayID],
              entry.ownerToken == ownerToken,
              entry.generation == generation else {
            return
        }
        entry.value = value
        entry.expiresAt = expiresAt
        entries[displayID] = entry
    }

    func take(
        displayID: UInt32,
        ownerToken: UInt,
        now: UInt64
    ) -> Value? {
        guard let entry = entries[displayID] else {
            return nil
        }
        guard entry.ownerToken == ownerToken else {
            entries.removeValue(forKey: displayID)
            return nil
        }
        entries.removeValue(forKey: displayID)
        guard let expiresAt = entry.expiresAt,
              now <= expiresAt else {
            return nil
        }
        return entry.value
    }

    func discard(displayID: UInt32, generation: UInt64? = nil) {
        guard generation == nil || entries[displayID]?.generation == generation else {
            return
        }
        entries.removeValue(forKey: displayID)
    }
}

enum LumenScreenCaptureDisplayReadiness {
    private static let productionQueryBudget = LumenScreenCaptureQueryBudget(
        maximumOutstandingQueries: LumenScreenCaptureDisplayReadinessTiming
            .production
            .maximumOutstandingQueries
    )
    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )

    static func resolveProduction(
        displayID: UInt32
    ) async throws -> LumenScreenCaptureDisplayHandle {
        let expectedOwner = await LumenScreenCaptureDisplayPrefetch.expectedOwner(
            displayID: displayID
        )
        if let expectedOwner {
            return try await resolveOwned(
                displayID: displayID,
                expectedOwner: expectedOwner
            )
        }
        return try await resolveExactExternal(displayID: displayID)
    }

    static func resolveOwned(
        displayID: UInt32,
        expectedOwner: LumenRetainedVirtualDisplayReference? = nil
    ) async throws -> LumenScreenCaptureDisplayHandle {
        let owner: LumenRetainedVirtualDisplayReference
        if let expectedOwner {
            owner = expectedOwner
        } else if let retained = LumenMacVirtualDisplay.registeredDisplay(
            forDisplayID: displayID
        ) {
            owner = LumenRetainedVirtualDisplayReference(display: retained)
        } else {
            throw LumenScreenCaptureError.displayOwnershipLost(displayID)
        }
        guard owner.isCurrent(displayID: displayID) else {
            throw LumenScreenCaptureError.displayOwnershipLost(displayID)
        }
        return try await resolve(
            displayID: displayID,
            authority: .retained(ownerToken: owner.ownerToken),
            readiness: { snapshot(displayID: displayID, owner: owner) }
        )
    }

    static func resolveExactExternal(
        displayID: UInt32
    ) async throws -> LumenScreenCaptureDisplayHandle {
        try await resolve(
            displayID: displayID,
            authority: .exactExternal,
            readiness: { snapshot(displayID: displayID) }
        )
    }

    static func snapshot(
        displayID: UInt32,
        owner: LumenRetainedVirtualDisplayReference? = nil
    ) -> LumenScreenCaptureDisplayReadinessSnapshot {
        let currentOwner = LumenMacVirtualDisplay.registeredDisplay(
            forDisplayID: displayID
        )
        let ownerToken: UInt?
        let configuredOwner: LumenMacVirtualDisplay?
        if let owner, currentOwner === owner.display {
            ownerToken = owner.ownerToken
            configuredOwner = owner.display
        } else {
            ownerToken = currentOwner.map {
                UInt(bitPattern: ObjectIdentifier($0))
            }
            configuredOwner = currentOwner
        }
        return LumenScreenCaptureDisplayReadinessSnapshot(
            ownerToken: ownerToken,
            isOnline: CGDisplayIsOnline(displayID) != 0,
            isActive: CGDisplayIsActive(displayID) != 0,
            hasCurrentMode: CGDisplayCopyDisplayMode(displayID) != nil,
            pixelWidth: CGDisplayPixelsWide(displayID),
            pixelHeight: CGDisplayPixelsHigh(displayID),
            configuredPixelWidth: Int(configuredOwner?.backingWidth ?? 0),
            configuredPixelHeight: Int(configuredOwner?.backingHeight ?? 0)
        )
    }

    private static func resolve(
        displayID: UInt32,
        authority: LumenScreenCaptureDisplayAuthority,
        readiness: @escaping @Sendable () async -> LumenScreenCaptureDisplayReadinessSnapshot
    ) async throws -> LumenScreenCaptureDisplayHandle {
        let authorityLabel: String
        let ownerToken: UInt
        switch authority {
        case .retained(let token):
            authorityLabel = "retained"
            ownerToken = token
        case .exactExternal:
            authorityLabel = "exact-external"
            ownerToken = 0
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let initialSnapshot = await readiness()
        let initialModeReady = initialSnapshot.isModeReady(for: authority)
        writeScreenCaptureStartupDiagnostic(
            "stage=display-readiness-begin display-id=\(displayID) authority=\(authorityLabel) owner-token=\(ownerToken) online=\(initialSnapshot.isOnline) active=\(initialSnapshot.isActive) current-mode=\(initialSnapshot.hasCurrentMode) pixel-size=\(initialSnapshot.pixelWidth)x\(initialSnapshot.pixelHeight) configured-size=\(initialSnapshot.configuredPixelWidth)x\(initialSnapshot.configuredPixelHeight) mode-ready=\(initialModeReady)"
        )
        do {
            let handle: LumenScreenCaptureDisplayHandle = try await
                LumenScreenCaptureDisplayResolver.resolve(
                    displayID: displayID,
                    authority: authority,
                    timing: .production,
                    queryBudget: productionQueryBudget,
                    now: { DispatchTime.now().uptimeNanoseconds },
                    sleepUntil: { deadline in
                        let current = DispatchTime.now().uptimeNanoseconds
                        guard deadline > current else { return }
                        try? await Task.sleep(nanoseconds: deadline - current)
                    },
                    readiness: readiness,
                    lookup: { generation in
                        logger.notice(
                            "stage=display-query-begin display-id=\(displayID, privacy: .public) authority=\(authorityLabel, privacy: .public) owner-token=\(ownerToken, privacy: .public) generation=\(generation, privacy: .public)"
                        )
                        writeScreenCaptureStartupDiagnostic(
                            "stage=display-query-begin display-id=\(displayID) authority=\(authorityLabel) owner-token=\(ownerToken) generation=\(generation)"
                        )
                        let content = try await SCShareableContent.excludingDesktopWindows(
                            false,
                            onScreenWindowsOnly: true
                        )
                        let observedDisplayIDs = content.displays
                            .map { String(UInt32($0.displayID)) }
                            .joined(separator: ",")
                        let target = content.displays.first(where: {
                            UInt32($0.displayID) == displayID
                        })
                        logger.notice(
                            "stage=display-query-complete display-id=\(displayID, privacy: .public) authority=\(authorityLabel, privacy: .public) owner-token=\(ownerToken, privacy: .public) generation=\(generation, privacy: .public) found=\(target != nil, privacy: .public) observed-display-ids=\(observedDisplayIDs, privacy: .public)"
                        )
                        writeScreenCaptureStartupDiagnostic(
                            "stage=display-query-complete display-id=\(displayID) authority=\(authorityLabel) owner-token=\(ownerToken) generation=\(generation) found=\(target != nil) observed-display-ids=\(observedDisplayIDs)"
                        )
                        return target.map(LumenScreenCaptureDisplayHandle.init(value:))
                    }
                )
            logger.notice(
                "stage=display-readiness-complete display-id=\(displayID, privacy: .public) authority=\(authorityLabel, privacy: .public) owner-token=\(ownerToken, privacy: .public) elapsed-ms=\(elapsedMilliseconds(since: startedAt), privacy: .public)"
            )
            writeScreenCaptureStartupDiagnostic(
                "stage=display-readiness-complete display-id=\(displayID) authority=\(authorityLabel) owner-token=\(ownerToken) elapsed-ms=\(elapsedMilliseconds(since: startedAt))"
            )
            return handle
        } catch {
            let failureSnapshot = await readiness()
            let failureModeReady = failureSnapshot.isModeReady(for: authority)
            logger.error(
                "stage=display-readiness-failed display-id=\(displayID, privacy: .public) authority=\(authorityLabel, privacy: .public) owner-token=\(ownerToken, privacy: .public) elapsed-ms=\(elapsedMilliseconds(since: startedAt), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            writeScreenCaptureStartupDiagnostic(
                "stage=display-readiness-failed display-id=\(displayID) authority=\(authorityLabel) owner-token=\(ownerToken) online=\(failureSnapshot.isOnline) active=\(failureSnapshot.isActive) current-mode=\(failureSnapshot.hasCurrentMode) pixel-size=\(failureSnapshot.pixelWidth)x\(failureSnapshot.pixelHeight) configured-size=\(failureSnapshot.configuredPixelWidth)x\(failureSnapshot.configuredPixelHeight) mode-ready=\(failureModeReady) elapsed-ms=\(elapsedMilliseconds(since: startedAt)) error=\(String(describing: error))"
            )
            throw error
        }
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        let current = DispatchTime.now().uptimeNanoseconds
        guard current >= start else { return 0 }
        return Double(current - start) / 1_000_000
    }
}

enum LumenScreenCaptureDisplayPrefetch {
    private static let preparedDisplays = LumenPreparedDisplayStore<LumenScreenCapturePreparedDisplay>()
    private static let expectedOwners = LumenExpectedDisplayOwnerStore<LumenRetainedVirtualDisplayReference>()
    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )

    static func prepare(displayID: UInt32) async throws {
        guard let retainedDisplay = LumenMacVirtualDisplay.registeredDisplay(
            forDisplayID: displayID
        ) else {
            throw LumenScreenCaptureError.displayOwnershipLost(displayID)
        }
        let owner = LumenRetainedVirtualDisplayReference(display: retainedDisplay)
        let ownerToken = owner.ownerToken
        await expectedOwners.set(owner, displayID: displayID)
        let generation = await preparedDisplays.begin(
            displayID: displayID,
            ownerToken: ownerToken
        )
        logger.notice(
            "stage=display-prefetch-begin display-id=\(displayID, privacy: .public) owner-token=\(ownerToken, privacy: .public) generation=\(generation, privacy: .public)"
        )
        writeScreenCaptureStartupDiagnostic(
            "stage=display-prefetch-begin display-id=\(displayID) owner-token=\(ownerToken) generation=\(generation)"
        )
        do {
            let handle = try await LumenScreenCaptureDisplayReadiness.resolveOwned(
                displayID: displayID,
                expectedOwner: owner
            )
            try Task.checkCancellation()
            let completedAt = DispatchTime.now().uptimeNanoseconds
            try Task.checkCancellation()
            try await preparedDisplays.complete(
                displayID: displayID,
                ownerToken: ownerToken,
                generation: generation,
                value: LumenScreenCapturePreparedDisplay(
                    handle: handle,
                    owner: owner
                ),
                expiresAt: LumenScreenCaptureDisplayResolver.addingClamped(
                    completedAt,
                    LumenScreenCaptureDisplayReadinessTiming.production.overallDeadlineNanoseconds
                )
            )
            writeScreenCaptureStartupDiagnostic(
                "stage=display-prefetch-ready display-id=\(displayID) owner-token=\(ownerToken) generation=\(generation)"
            )
        } catch {
            await preparedDisplays.discard(displayID: displayID, generation: generation)
            writeScreenCaptureStartupDiagnostic(
                "stage=display-prefetch-failed display-id=\(displayID) owner-token=\(ownerToken) generation=\(generation) error=\(String(describing: error))"
            )
            throw error
        }
    }

    static func resolve(displayID: UInt32) async throws -> LumenScreenCaptureDisplayHandle? {
        let before = LumenScreenCaptureDisplayReadiness.snapshot(displayID: displayID)
        guard let ownerToken = before.ownerToken else {
            await preparedDisplays.discard(displayID: displayID)
            logger.warning(
                "stage=display-prefetch-rejected display-id=\(displayID, privacy: .public) reason=owner-or-mode-not-ready"
            )
            return nil
        }
        let authority = LumenScreenCaptureDisplayAuthority.retained(
            ownerToken: ownerToken
        )
        guard before.isPreparedHandleReady(for: authority) else {
            await preparedDisplays.discard(displayID: displayID)
            logger.warning(
                "stage=display-prefetch-rejected display-id=\(displayID, privacy: .public) reason=owner-or-mode-not-ready"
            )
            return nil
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let prepared = await preparedDisplays.take(
            displayID: displayID,
            ownerToken: ownerToken,
            now: start
        )
        guard let prepared,
              prepared.owner.ownerToken == ownerToken,
              prepared.owner.isCurrent(displayID: displayID) else {
            logger.warning(
                "stage=display-prefetch-rejected display-id=\(displayID, privacy: .public) owner-token=\(ownerToken, privacy: .public) reason=stale-or-expired"
            )
            return nil
        }
        let after = LumenScreenCaptureDisplayReadiness.snapshot(
            displayID: displayID,
            owner: prepared.owner
        )
        guard after.ownerToken == ownerToken,
              after.isPreparedHandleReady(for: authority) else {
            logger.warning(
                "stage=display-prefetch-rejected display-id=\(displayID, privacy: .public) owner-token=\(ownerToken, privacy: .public) reason=post-take-validation-failed"
            )
            return nil
        }
        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - start
        ) / 1_000_000
        logger.notice(
            "stage=display-prefetch-resolved display-id=\(displayID, privacy: .public) owner-token=\(ownerToken, privacy: .public) found=true wait-ms=\(elapsedMilliseconds, privacy: .public)"
        )
        return prepared.handle
    }

    static func discard(displayID: UInt32) async {
        await preparedDisplays.discard(displayID: displayID)
        await expectedOwners.discard(displayID: displayID)
    }

    static func expectedOwner(
        displayID: UInt32
    ) async -> LumenRetainedVirtualDisplayReference? {
        await expectedOwners.owner(displayID: displayID)
    }
}

enum LumenScreenCaptureOutputRegistrationStage: String, Equatable, Sendable {
    case unregistered
    case screenRegistered = "screen-registered"
    case captureStarted = "capture-started"
    case stopped
}

struct LumenScreenCaptureOutputOwnership: Equatable, Sendable {
    private(set) var streamIdentity: UInt?
    private(set) var stage: LumenScreenCaptureOutputRegistrationStage = .unregistered
    private(set) var screenSampleCount: UInt64 = 0

    mutating func registerScreenOutput(streamIdentity: UInt) {
        self.streamIdentity = streamIdentity
        stage = .screenRegistered
    }

    mutating func markCaptureStarted(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        stage = .captureStarted
    }

    mutating func recordScreenSample(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        screenSampleCount &+= 1
    }

    mutating func stop(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        stage = .stopped
        self.streamIdentity = nil
    }

    private func requireOwner(_ streamIdentity: UInt) throws {
        guard self.streamIdentity == streamIdentity else {
            throw LumenScreenCaptureOutputOwnershipError.streamIdentityMismatch
        }
    }
}

enum LumenScreenCaptureOutputOwnershipError: Error, Equatable {
    case streamIdentityMismatch
}

protocol LumenEncodedCaptureRuntime: AnyObject, Sendable {
    func start() async throws
    func stop() async
    func requestImmediateKeyFrame()
    func resumeVideoEncodingAfterCodecAck() async -> Bool
}

struct LumenEncodedCaptureRuntimeContext: Sendable {
    let configuration: LumenMacCaptureConfiguration
    let callbacks: LumenEncodedCaptureCallbacks
    let statisticsHandler:
        @Sendable (LumenEncodedCaptureSessionStatistics) -> Void
    let terminationHandler: @Sendable (any Error) -> Void
}

actor LumenCaptureStartFlight {
    struct Completion {
        let terminationError: (any Error)?
        let startError: (any Error)?
    }

    private var startCompleted = false
    private var startError: (any Error)?
    private var stopRequested = false
    private var settled = false
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []

    func finishStart(
        terminationError: (any Error)?,
        error: (any Error)? = nil
    ) -> Completion {
        if !startCompleted {
            startCompleted = true
            startError = error
        }
        return Completion(
            terminationError: terminationError,
            startError: startError
        )
    }

    func requestStop() {
        stopRequested = true
    }

    func isStopRequested() -> Bool {
        stopRequested
    }

    func settle() {
        guard !settled else {
            return
        }
        settled = true
        let waiters = settlementWaiters
        settlementWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func waitUntilSettled() async {
        guard !settled else {
            return
        }
        await withCheckedContinuation { continuation in
            if settled {
                continuation.resume()
            } else {
                settlementWaiters.append(continuation)
            }
        }
    }
}

private final class LumenCaptureTerminationLatch: @unchecked Sendable {
    private struct State {
        var startCompleted = false
        var terminationError: (any Error)?
    }

    private let state = Mutex(State())

    func record(_ error: any Error) -> Bool {
        state.withLock { state in
            guard !state.startCompleted else {
                return false
            }
            if state.terminationError == nil {
                state.terminationError = error
            }
            return true
        }
    }

    func complete() -> (any Error)? {
        state.withLock { state in
            state.startCompleted = true
            return state.terminationError
        }
    }
}

final class LumenCaptureCallbackGate: @unchecked Sendable {
    private let accepting = Atomic(true)

    func close() {
        accepting.store(false, ordering: .releasing)
    }

    func isOpen() -> Bool {
        accepting.load(ordering: .acquiring)
    }
}

protocol LumenEncodedCaptureRuntimeFactory: Sendable {
    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime
}

struct LumenProductionEncodedCaptureRuntimeFactory:
    LumenEncodedCaptureRuntimeFactory
{
    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime {
        try LumenScreenCaptureVideoRuntime(
            configuration: context.configuration,
            callbacks: context.callbacks,
            statisticsHandler: context.statisticsHandler,
            terminationHandler: context.terminationHandler
        )
    }
}

/// Safety: ScreenCaptureKit and VideoToolbox callbacks enter through `queue`.
/// Mutable encode state is initialized before capture starts and is otherwise
/// read or mutated only on that serial queue. The separate `encoderQueue` owns
/// ordered synchronous C/VideoToolbox admission calls, which can block in XPC;
/// teardown drains those calls and their queued outputs before invalidation.
private final class LumenScreenCaptureVideoRuntime:
    NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    LumenEncodedCaptureRuntime,
    @unchecked Sendable
{
    private static let startupLogger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )
    private let configuration: LumenMacCaptureConfiguration
    private let frameHandler: @Sendable (LumenEncodedFrame) -> Void
    private let eventHandler: @Sendable (LumenEncodedCaptureSessionEvent) -> Void
    private let statisticsHandler: @Sendable (LumenEncodedCaptureSessionStatistics) -> Void
    private let terminationHandler: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.sck.video", qos: .userInteractive)
    private let encoderQueue = DispatchQueue(
        label: "dev.skyline23.lumen.sck.video.vt-admission",
        qos: .userInteractive
    )
    private var stream: SCStream?
    // Lifecycle transitions are fenced on `queue` because `startCapture` and
    // `stopCapture` suspend at the ScreenCaptureKit callback boundary.
    private var lifecycleStartInFlight = false
    private var lifecycleStopRequested = false
    private var lifecycleSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var compressionSession: VTCompressionSession?
    private var compressionSessionAvailable = false
    private var encodingPlan: LumenVideoToolboxEncodingPlan?
    private var sourceContract: LumenExactCaptureSourceContract?
    private var outputContract: LumenExactEncodedOutputContract?
    private var sequenceNumber: UInt64 = 0
    private var lastQueuedEncoderSequenceNumber: UInt64?
    private var lastQueuedEncoderPresentationTime: CMTime?
    private var videoBootstrapAdmission = LumenVideoBootstrapAdmissionGate()
    private var pendingVideoBootstrapSource: LumenPendingVideoBootstrapSource?
    private var inflightFrameCount = 0
    private var stopping = false
    private var firstSourceMachTime: UInt64?
    private var lastSourceMachTime: UInt64?
    private var lastOutputMachTime: UInt64?
    private var sourceIntervalTotalMilliseconds = 0.0
    private var sourceIntervalSampleCount: UInt64 = 0
    private var outputIntervalTotalMilliseconds = 0.0
    private var outputIntervalSampleCount: UInt64 = 0
    private var captureIngressTimings = LumenCaptureIngressTimings()
    private var sourceCallbackServiceTiming = LumenCaptureStageTimingAccumulator()
    private var encoderAdmissionWaitTiming = LumenCaptureStageTimingAccumulator()
    private var encoderInvocationTiming = LumenCaptureStageTimingAccumulator()
    private var videoToolboxCallbackTiming = LumenCaptureStageTimingAccumulator()
    private var outputOwnerQueueWaitTiming = LumenCaptureStageTimingAccumulator()
    private var outputServiceTiming = LumenCaptureStageTimingAccumulator()
    private var frameHandlerTiming = LumenCaptureStageTimingAccumulator()
    private var outputWidth = 0
    private var outputHeight = 0
    private var sourceColorContractStatus = "not-required"
    private var sourceColorContractFailureReported = false
    private var terminalContractFailureReported = false
    private var statistics = LumenEncodedCaptureSessionStatistics()
    private var outputOwnership = LumenScreenCaptureOutputOwnership()
    private var displayAdmissionMode = LumenScreenCaptureDisplayAdmissionMode.shareableContentEnumeration
    private var displayAdmissionDurationMilliseconds = 0.0
    private var streamStartDurationMilliseconds = 0.0
    private lazy var outputLifecycle =
        LumenVideoToolboxOutputLifecycle<LumenEncodedFrameContext>(
            ownerQueue: queue
        )
    private lazy var encoderAdmission = LumenLatestFrameSerialEncoderAdmission<
        LumenVideoEncoderSubmission,
        LumenVideoEncoderSubmissionResult
    >(
        ownerQueue: queue,
        submissionQueue: encoderQueue,
        hasSubmissionCapacity: { [weak self] in
            guard let self else { return false }
            return self.inflightFrameCount < self.maximumPendingFrameCount
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
    }

    func start() async throws {
        guard beginLifecycleStart() else {
            throw LumenScreenCaptureError.captureAlreadyRunning
        }
        do {
            try await startCapture()
        } catch {
            await finishLifecycleStart()
            throw error
        }
        await finishLifecycleStart()
    }

    private func startCapture() async throws {
        let displayID = configuration.displayID
        let admissionStart = DispatchTime.now().uptimeNanoseconds
        let admission: LumenScreenCaptureDisplayAdmissionResult<LumenScreenCaptureDisplayHandle>
        do {
            admission = try await LumenScreenCaptureDisplayAdmission.resolve(
                displayID: displayID,
                prefetched: {
                    try await LumenScreenCaptureDisplayPrefetch.resolve(
                        displayID: displayID
                    )
                },
                enumerateShareableContent: {
                    let expectedOwner = await LumenScreenCaptureDisplayPrefetch.expectedOwner(
                        displayID: displayID
                    )
                    let handle = try await LumenScreenCaptureDisplayReadiness.resolveProduction(
                        displayID: displayID
                    )
                    return LumenScreenCaptureDisplayAdmissionResult(
                        value: handle,
                        mode: expectedOwner == nil
                            ? .shareableContentEnumeration
                            : .retainedShareableContent
                    )
                }
            )
        } catch {
            let elapsed = Self.elapsedMilliseconds(since: admissionStart)
            Self.startupLogger.error(
                "stage=display-admission-failed display-id=\(displayID, privacy: .public) elapsed-ms=\(elapsed, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
        let displayAdmissionDuration = Self.elapsedMilliseconds(since: admissionStart)
        queue.sync {
            displayAdmissionMode = admission.mode
            displayAdmissionDurationMilliseconds = displayAdmissionDuration
        }
        Self.startupLogger.notice(
            "stage=display-admission-complete display-id=\(displayID, privacy: .public) mode=\(admission.mode.rawValue, privacy: .public) elapsed-ms=\(displayAdmissionDuration, privacy: .public)"
        )
        let display = admission.value.value

        let width = configuration.requestedWidth ?? display.width
        let height = configuration.requestedHeight ?? display.height
        let resolvedOutputWidth = configuration.effectivePreprocessStrategy == .downscale2x ? max(width / 2, 1) : width
        let resolvedOutputHeight = configuration.effectivePreprocessStrategy == .downscale2x ? max(height / 2, 1) : height
        queue.sync {
            outputWidth = resolvedOutputWidth
            outputHeight = resolvedOutputHeight
        }

        let plan = try await resolveEncodingPlan()
        let resolvedSourceContract = try LumenExactCaptureSourceContract(
            configuration: configuration,
            width: resolvedOutputWidth,
            height: resolvedOutputHeight
        )
        let resolvedOutputContract = try LumenExactEncodedOutputContract(configuration: configuration)
        queue.sync {
            encodingPlan = plan
            sourceContract = resolvedSourceContract
            outputContract = resolvedOutputContract
        }

        let streamConfiguration = LumenCaptureStreamConfigurationFactory.make(
            configuration: configuration
        )
        streamConfiguration.width = resolvedOutputWidth
        streamConfiguration.height = resolvedOutputHeight
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.effectiveTargetFrameRate))
        streamConfiguration.queueDepth = configuration.negotiatedQueueProfile.queueDepthHint
        streamConfiguration.pixelFormat = plan.pixelFormat
        if configuration.chromaSubsampling == .yuv444, configuration.dynamicRange == .sdr {
            streamConfiguration.colorSpaceName = CGColorSpace.itur_709
            streamConfiguration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        streamConfiguration.scalesToFit = false
        streamConfiguration.preservesAspectRatio = true
        try encoderQueue.sync {
            try createCompressionSession(width: resolvedOutputWidth, height: resolvedOutputHeight)
        }
        queue.sync {
            compressionSessionAvailable = true
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let streamIdentity = Self.identity(of: stream)
        queue.sync {
            self.stream = stream
            outputOwnership.registerScreenOutput(streamIdentity: streamIdentity)
        }
        do {
            let streamStart = DispatchTime.now().uptimeNanoseconds
            try await stream.startCapture()
            let streamStartDuration = Self.elapsedMilliseconds(since: streamStart)
            let stopRequested = queue.sync {
                streamStartDurationMilliseconds = streamStartDuration
                return lifecycleStopRequested
            }
            Self.startupLogger.notice(
                "stage=stream-start-complete display-id=\(displayID, privacy: .public) stream=\(streamIdentity, privacy: .public) elapsed-ms=\(streamStartDuration, privacy: .public) source-queue-depth=\(streamConfiguration.queueDepth, privacy: .public)"
            )
            if stopRequested {
                try? await stream.stopCapture()
                try? stream.removeStreamOutput(self, type: .screen)
                queue.sync {
                    if self.stream === stream {
                        self.stream = nil
                    }
                    try? outputOwnership.stop(streamIdentity: streamIdentity)
                }
                return
            }
        } catch {
            try? stream.removeStreamOutput(self, type: .screen)
            queue.sync {
                if self.stream === stream {
                    self.stream = nil
                }
                try? outputOwnership.stop(streamIdentity: streamIdentity)
            }
            throw error
        }
        let publishStart = queue.sync { () -> (Bool, String, Double, Double) in
            try? outputOwnership.markCaptureStarted(streamIdentity: streamIdentity)
            let stopRequested = lifecycleStopRequested
            let notes = makeStatisticsNotes(width: outputWidth, height: outputHeight)
            let displayAdmissionMode = self.displayAdmissionMode.rawValue
            let displayAdmissionMilliseconds = self.displayAdmissionDurationMilliseconds
            let streamStartMilliseconds = self.streamStartDurationMilliseconds
            if !stopRequested {
                statistics.isRunning = true
                statistics.notes = notes
            }
            return (
                stopRequested,
                displayAdmissionMode,
                displayAdmissionMilliseconds,
                streamStartMilliseconds
            )
        }
        if publishStart.0 {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            queue.sync {
                if self.stream === stream {
                    self.stream = nil
                }
                try? outputOwnership.stop(streamIdentity: streamIdentity)
            }
            return
        }
        queue.sync {
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .started,
                message: "ScreenCaptureKit capture started stream=\(streamIdentity) output-registration=\(outputOwnership.stage.rawValue) display-admission=\(publishStart.1) display-admission-ms=\(publishStart.2) stream-start-ms=\(publishStart.3)"
            ))
        }
    }

    func stop() async {
        let startWasInFlight = queue.sync {
            lifecycleStopRequested = true
            return lifecycleStartInFlight
        }
        if startWasInFlight {
            await waitForLifecycleStart()
        }
        queue.sync {
            stopping = true
            compressionSessionAvailable = false
            pendingVideoBootstrapSource = nil
            encoderAdmission.beginStopping()
        }
        encoderAdmission.waitUntilSubmissionReturns()
        let stoppedStreamIdentity: UInt?
        let streamToStop = queue.sync { () -> SCStream? in
            let stream = self.stream
            self.stream = nil
            return stream
        }
        if let stream = streamToStop {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            let streamIdentity = Self.identity(of: stream)
            queue.sync {
                try? outputOwnership.stop(streamIdentity: streamIdentity)
            }
            stoppedStreamIdentity = streamIdentity
        } else {
            stoppedStreamIdentity = nil
        }

        await outputLifecycle.completeAndInvalidate(
            completeFrames: { [self] in
                encoderQueue.sync {
                    completeCompressionFrames()
                }
            },
            invalidate: { [self] in
                encoderQueue.sync {
                    invalidateCompressionSession()
                }
            },
            completionFailure: { [self] status, cancelledContexts in
                queue.sync {
                    reportCompressionFrameCompletionFailure(
                        status: status,
                        cancelledContexts: cancelledContexts
                    )
                }
            }
        )

        guard stoppedStreamIdentity != nil else {
            queue.sync {
                lifecycleStopRequested = false
            }
            return
        }
        queue.sync {
            statistics.isRunning = false
            refreshStatisticsNotes()
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .stopped,
                message: "ScreenCaptureKit capture stopped output-registration=\(outputOwnership.stage.rawValue) source-samples=\(outputOwnership.screenSampleCount)",
                stopStatus: 0
            ))
            lifecycleStopRequested = false
        }
    }

    private func beginLifecycleStart() -> Bool {
        queue.sync {
            guard !lifecycleStartInFlight,
                  !lifecycleStopRequested,
                  stream == nil else {
                return false
            }
            lifecycleStartInFlight = true
            stopping = false
            return true
        }
    }

    private func finishLifecycleStart() async {
        let waiters = queue.sync { () -> [CheckedContinuation<Void, Never>] in
            lifecycleStartInFlight = false
            let waiters = lifecycleSettlementWaiters
            lifecycleSettlementWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    private func waitForLifecycleStart() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.lifecycleStartInFlight {
                    self.lifecycleSettlementWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func requestImmediateKeyFrame() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.videoBootstrapAdmission.beginBootstrapGeneration() {
                self.pendingVideoBootstrapSource = nil
            }
        }
    }

    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self,
                      !self.stopping,
                      self.videoBootstrapAdmission.acknowledgeConfiguration() else {
                    continuation.resume(returning: false)
                    return
                }
                let pendingSource = self.pendingVideoBootstrapSource
                self.pendingVideoBootstrapSource = nil
                if let pendingSource {
                    self.submitSource(pendingSource, forceKeyFrame: false)
                }
                self.eventHandler(.init(
                    kind: .started,
                    message: "VideoToolbox encoding resumed after codec acknowledgement coalesced-source=\(pendingSource != nil)"
                ))
                continuation.resume(returning: true)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              !stopping,
              CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = sampleBuffer.imageBuffer,
              compressionSessionAvailable else {
            return
        }

        let callbackEntryMachTime = beginSourceCallback(sampleBuffer)
        defer {
            finishSourceCallback(startedAt: callbackEntryMachTime)
        }

        do {
            try outputOwnership.recordScreenSample(streamIdentity: Self.identity(of: stream))
        } catch {
            let ownershipError = LumenScreenCaptureError.outputOwnershipLost
            statistics.processingFailureCount &+= 1
            statistics.lastErrorDescription = ownershipError.localizedDescription
            refreshStatisticsNotes()
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .failed,
                message: ownershipError.localizedDescription,
                sourceDisplayTime: sampleBuffer.presentationTimeStamp.value >= 0
                    ? UInt64(sampleBuffer.presentationTimeStamp.value)
                    : 0
            ))
            terminationHandler(ownershipError)
            return
        }

        statistics.sourceFrameCount &+= 1
        let sourceMachTime = callbackEntryMachTime
        if firstSourceMachTime == nil {
            firstSourceMachTime = sourceMachTime
        }
        if let lastSourceMachTime {
            sourceIntervalTotalMilliseconds += LumenMachTime.milliseconds(from: lastSourceMachTime, to: sourceMachTime)
            sourceIntervalSampleCount &+= 1
        }
        lastSourceMachTime = sourceMachTime

        if let mismatch = sourceContract?.mismatchDescription(
            for: imageBuffer,
            formatDescription: sampleBuffer.formatDescription
        ) {
            reportTerminalContractFailure(.sourceContractMismatch(mismatch), sourceDisplayTime: nil)
            return
        }
        statistics.exactCaptureAudit.inputFourCC = auditFourCC(
            CVPixelBufferGetPixelFormatType(imageBuffer)
        )
        statistics.exactCaptureAudit.lumaPlaneWidth = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
        statistics.exactCaptureAudit.lumaPlaneHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        statistics.exactCaptureAudit.chromaPlaneWidth = CVPixelBufferGetWidthOfPlane(imageBuffer, 1)
        statistics.exactCaptureAudit.chromaPlaneHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, 1)
        let sourceFormatExtensions = sampleBuffer.formatDescription.flatMap {
            CMFormatDescriptionGetExtensions($0) as? [CFString: Any]
        }
        statistics.exactCaptureAudit.colorPrimaries = (CVBufferCopyAttachment(
            imageBuffer,
            kCVImageBufferColorPrimariesKey,
            nil
        ) as? String) ?? (sourceFormatExtensions?[kCMFormatDescriptionExtension_ColorPrimaries] as? String)
        statistics.exactCaptureAudit.transferFunction = (CVBufferCopyAttachment(
            imageBuffer,
            kCVImageBufferTransferFunctionKey,
            nil
        ) as? String) ?? (sourceFormatExtensions?[kCMFormatDescriptionExtension_TransferFunction] as? String)
        statistics.exactCaptureAudit.yCbCrMatrix = (CVBufferCopyAttachment(
            imageBuffer,
            kCVImageBufferYCbCrMatrixKey,
            nil
        ) as? String) ?? (sourceFormatExtensions?[kCMFormatDescriptionExtension_YCbCrMatrix] as? String)

        guard isCompleteScreenFrame(sampleBuffer) else {
            statistics.droppedFrameCount &+= 1
            refreshStatisticsNotesIfNeeded()
            return
        }

        sequenceNumber &+= 1
        let presentationTime = sampleBuffer.presentationTimeStamp.isValid
            ? sampleBuffer.presentationTimeStamp
            : CMTime(value: CMTimeValue(sequenceNumber), timescale: CMTimeScale(configuration.effectiveTargetFrameRate))
        let displayTime = LumenMachTime.ticks(for: presentationTime) ?? sourceMachTime
        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.effectiveTargetFrameRate))

        let source = LumenPendingVideoBootstrapSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            displayTime: displayTime,
            duration: duration,
            sequenceNumber: sequenceNumber
        )
        switch videoBootstrapAdmission.admitSourceFrame() {
        case .submitInitialKeyFrame:
            if !submitSource(source, forceKeyFrame: true) {
                videoBootstrapAdmission.cancelBootstrapSubmission()
            }
        case .coalesceUntilAcknowledged:
            pendingVideoBootstrapSource = source
            statistics.pendingAdmissionDropCount &+= 1
            refreshStatisticsNotesIfNeeded()
        case .submit:
            submitSource(source, forceKeyFrame: false)
        }
    }

    @discardableResult
    private func submitSource(
        _ source: LumenPendingVideoBootstrapSource,
        forceKeyFrame: Bool
    ) -> Bool {
        guard !stopping else {
            return false
        }
        guard compressionSessionAvailable else {
            reportTerminalContractFailure(.invalidFormat("VideoToolbox compression session is unavailable"), sourceDisplayTime: source.displayTime)
            return false
        }

        if let lastQueuedEncoderSequenceNumber,
           source.sequenceNumber <= lastQueuedEncoderSequenceNumber {
            reportTerminalContractFailure(
                .invalidFormat(
                    "VideoToolbox source sequence must increase previous=\(lastQueuedEncoderSequenceNumber) current=\(source.sequenceNumber)"
                ),
                sourceDisplayTime: source.displayTime
            )
            return false
        }
        if let lastQueuedEncoderPresentationTime,
           CMTimeCompare(source.presentationTime, lastQueuedEncoderPresentationTime) <= 0 {
            reportTerminalContractFailure(
                .invalidFormat(
                    "VideoToolbox presentation timestamp must increase previous=\(lastQueuedEncoderPresentationTime.value)/\(lastQueuedEncoderPresentationTime.timescale) current=\(source.presentationTime.value)/\(source.presentationTime.timescale)"
                ),
                sourceDisplayTime: source.displayTime
            )
            return false
        }
        lastQueuedEncoderSequenceNumber = source.sequenceNumber
        lastQueuedEncoderPresentationTime = source.presentationTime

        sourceColorContractStatus = "verified"
        let submission = LumenVideoEncoderSubmission(
            source: source,
            forceKeyFrame: forceKeyFrame,
            offeredMachTime: mach_absolute_time()
        )
        if let replacedSubmission = encoderAdmission.offer(submission) {
            recordPendingAdmissionDrop(replacedSubmission.source)
        }
        return true
    }

    private func willSubmitToVideoToolbox(_ submission: LumenVideoEncoderSubmission) {
        let source = submission.source
        let submissionMachTime = mach_absolute_time()
        encoderAdmissionWaitTiming.observe(
            LumenMachTime.milliseconds(
                from: submission.offeredMachTime,
                to: submissionMachTime
            )
        )
        outputLifecycle.registerSubmission(
            id: source.sequenceNumber,
            context: .init(
                sequenceNumber: source.sequenceNumber,
                displayTime: source.displayTime,
                submissionMachTime: submissionMachTime,
                requiresBootstrapAcknowledgement: submission.forceKeyFrame
            )
        )
        inflightFrameCount += 1
        statistics.maximumInflightFrameCount = max(
            statistics.maximumInflightFrameCount,
            inflightFrameCount
        )
    }

    private func submitToVideoToolbox(
        _ submission: LumenVideoEncoderSubmission,
        entered: @Sendable () -> Bool
    ) -> LumenEncoderSubmissionAttempt<LumenVideoEncoderSubmissionResult> {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else {
            guard entered() else {
                return .cancelled
            }
            return .submitted(.init(
                status: kVTInvalidSessionErr,
                infoFlags: [],
                invocationMilliseconds: 0
            ))
        }

        let source = submission.source
        let properties = submission.forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        guard entered() else {
            return .cancelled
        }
        var infoFlags: VTEncodeInfoFlags = []
        let invocationStartedMachTime = mach_absolute_time()
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: source.imageBuffer,
            presentationTimeStamp: source.presentationTime,
            duration: source.duration,
            frameProperties: properties,
            sourceFrameRefcon: UnsafeMutableRawPointer(
                bitPattern: UInt(source.sequenceNumber)
            ),
            infoFlagsOut: &infoFlags
        )
        return .submitted(.init(
            status: status,
            infoFlags: infoFlags,
            invocationMilliseconds: LumenMachTime.milliseconds(
                from: invocationStartedMachTime,
                to: mach_absolute_time()
            )
        ))
    }

    private func didSubmitToVideoToolbox(
        _ submission: LumenVideoEncoderSubmission,
        result: LumenVideoEncoderSubmissionResult
    ) {
        encoderInvocationTiming.observe(result.invocationMilliseconds)
        if result.status != noErr {
            if outputLifecycle.cancelSubmission(
                id: submission.source.sequenceNumber
            ) != nil {
                inflightFrameCount = max(inflightFrameCount - 1, 0)
            }
            if submission.forceKeyFrame {
                videoBootstrapAdmission.cancelBootstrapSubmission()
                pendingVideoBootstrapSource = nil
            }
            statistics.processingFailureCount &+= 1
            statistics.lastErrorDescription = "VTCompressionSessionEncodeFrame failed with OSStatus \(result.status)"
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .failed,
                message: statistics.lastErrorDescription,
                stopStatus: result.status,
                sourceDisplayTime: submission.source.displayTime
            ))
        } else if result.infoFlags.contains(.frameDropped) {
            if outputLifecycle.cancelSubmission(
                id: submission.source.sequenceNumber
            ) != nil {
                inflightFrameCount = max(inflightFrameCount - 1, 0)
            }
            if submission.forceKeyFrame {
                videoBootstrapAdmission.cancelBootstrapSubmission()
                pendingVideoBootstrapSource = nil
            }
            statistics.droppedFrameCount &+= 1
            statistics.lastErrorDescription = "VideoToolbox dropped frame during synchronous admission"
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .droppedFrame,
                message: statistics.lastErrorDescription,
                sourceDisplayTime: submission.source.displayTime
            ))
        } else {
            statistics.submittedFrameCount &+= 1
            refreshStatisticsNotesIfNeeded()
        }
    }

    private func recordPendingAdmissionDrop(_ source: LumenPendingVideoBootstrapSource) {
        statistics.droppedFrameCount &+= 1
        statistics.pendingAdmissionDropCount &+= 1
        refreshStatisticsNotesIfNeeded()
        if statistics.pendingAdmissionDropCount == 1 || statistics.pendingAdmissionDropCount % 120 == 0 {
            eventHandler(.init(
                kind: .coalescedFrame,
                message: "Dropped fresh ScreenCaptureKit frame before VT admission to cap pending latency",
                sourceDisplayTime: source.displayTime
            ))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.statistics.isRunning = false
            self.statistics.lastErrorDescription = error.localizedDescription
            self.refreshStatisticsNotes()
            self.statisticsHandler(self.statistics)
            self.eventHandler(.init(kind: .failed, message: error.localizedDescription))
            self.terminationHandler(error)
        }
    }

    private var maximumPendingFrameCount: Int {
        max(configuration.negotiatedQueueProfile.queueDepthHint, 1)
    }

    private func beginSourceCallback(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
        let callbackEntryMachTime = mach_absolute_time()
        captureIngressTimings.observe(
            displayedMachTime: screenFrameDisplayTime(sampleBuffer),
            callbackMachTime: callbackEntryMachTime
        )
        return callbackEntryMachTime
    }

    private func finishSourceCallback(startedAt callbackEntryMachTime: UInt64) {
        sourceCallbackServiceTiming.observe(
            LumenMachTime.milliseconds(
                from: callbackEntryMachTime,
                to: mach_absolute_time()
            )
        )
    }

    private func screenFrameDisplayTime(_ sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let displayTime = attachments.first?[.displayTime] as? NSNumber else {
            return nil
        }
        return displayTime.uint64Value
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let status = attachments.first?[.status] as? NSNumber else {
            return true
        }
        return status.intValue == SCFrameStatus.complete.rawValue
    }

    private var capturePixelFormat: OSType {
        encodingPlan?.pixelFormat ?? configuration.directCapturePixelFormat
    }

    private func sourceColorContractMismatch(for imageBuffer: CVImageBuffer) -> String? {
        guard let color = configuration.encodedColorConfiguration,
              color.transferFunction != .ituR709 else {
            sourceColorContractStatus = "not-required"
            return nil
        }

        let contract = LumenCaptureColorContract(pixelFormat: capturePixelFormat, color: color)
        if let mismatch = contract.mismatchDescription(for: imageBuffer) {
            return mismatch
        }
        sourceColorContractStatus = "verified"
        return nil
    }

    private func createCompressionSession(width: Int, height: Int) throws {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let encodingPlan else {
            throw LumenExactCaptureError.invalidFormat("encoding plan was not resolved")
        }
        let codecType: CMVideoCodecType
        switch configuration.codec {
        case .h264: codecType = kCMVideoCodecType_H264
        case .hevc: codecType = kCMVideoCodecType_HEVC
        }

        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: capturePixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: lumenScreenCaptureCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw LumenScreenCaptureError.compressionSessionCreationFailed(status)
        }
        compressionSession = session

        try setProperty(kVTCompressionPropertyKey_RealTime, value: true as CFBoolean)
        try setProperty(kVTCompressionPropertyKey_AllowFrameReordering, value: false as CFBoolean)
        if configuration.codec == .hevc {
            try setProperty(kVTCompressionPropertyKey_AllowOpenGOP, value: false as CFBoolean)
        }
        try setProperty(kVTCompressionPropertyKey_ExpectedFrameRate, value: configuration.effectiveTargetFrameRate as CFNumber)
        try setProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: configuration.effectiveTargetFrameRate as CFNumber)
        if configuration.targetVideoBitRateKbps > 0 {
            try setProperty(
                kVTCompressionPropertyKey_AverageBitRate,
                value: (configuration.targetVideoBitRateKbps * 1_000) as CFNumber
            )
        }

        try setProperty(
            kVTCompressionPropertyKey_ProfileLevel,
            value: encodingPlan.profile as CFString
        )
        if let color = configuration.encodedColorConfiguration {
            try setProperty(kVTCompressionPropertyKey_ColorPrimaries, value: color.colorPrimaries.coreMediaValue)
            try setProperty(kVTCompressionPropertyKey_TransferFunction, value: color.transferFunction.coreMediaValue)
            try setProperty(kVTCompressionPropertyKey_YCbCrMatrix, value: color.yCbCrMatrix.coreMediaValue)
            if color.transferFunction != .ituR709 {
                try setProperty(kVTCompressionPropertyKey_HDRMetadataInsertionMode, value: kVTHDRMetadataInsertionMode_Auto)
            }
            if let masteringDisplayColorVolume = color.masteringDisplayColorVolume {
                try setProperty(
                    kVTCompressionPropertyKey_MasteringDisplayColorVolume,
                    value: masteringDisplayColorVolume.encodedData as CFData
                )
            }
            if let contentLightLevelInfo = color.contentLightLevelInfo {
                try setProperty(
                    kVTCompressionPropertyKey_ContentLightLevelInfo,
                    value: contentLightLevelInfo.encodedData as CFData
                )
            }
        }
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            throw LumenScreenCaptureError.compressionSessionPreparationFailed(prepareStatus)
        }

        if configuration.codec == .hevc {
            var openGOPValue: CFTypeRef?
            let openGOPStatus = withUnsafeMutablePointer(to: &openGOPValue) { pointer in
                VTSessionCopyProperty(
                    session,
                    key: kVTCompressionPropertyKey_AllowOpenGOP,
                    allocator: kCFAllocatorDefault,
                    valueOut: UnsafeMutableRawPointer(pointer)
                )
            }
            guard openGOPStatus == noErr, openGOPValue as? Bool == false else {
                throw LumenExactCaptureError.invalidFormat(
                    "VideoToolbox did not retain the required closed-GOP HEVC contract"
                )
            }
            statistics.exactCaptureAudit.allowOpenGOP = false
        }

        var hardwareValue: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &hardwareValue) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        guard hardwareStatus == noErr, hardwareValue as? Bool == true else {
            throw LumenExactCaptureError.requiredHardwareEncoderUnavailable
        }
        statistics.exactCaptureAudit.profile = encodingPlan.profile
        statistics.exactCaptureAudit.hardwareUsed = true
    }

    private func resolveEncodingPlan() async throws -> LumenVideoToolboxEncodingPlan {
        var profiles: [LumenVideoToolboxProbeTarget: String] = [:]
        if configuration.requiredHardware444ProbeTarget != nil {
            let rows = await LumenVideoToolboxCapabilityProbe.advertisedRequiredHardware444()
            for row in rows {
                guard let target = LumenVideoToolboxProbeTarget(rawValue: row.requestedProfileFamily),
                      let profile = row.profile else {
                    continue
                }
                profiles[target] = profile
            }
        }
        return try LumenVideoToolboxEncodingPlanResolver.resolve(
            configuration: configuration,
            availableHardware444Profiles: profiles
        )
    }

    private func reportTerminalContractFailure(
        _ error: LumenExactCaptureError,
        sourceDisplayTime: UInt64?
    ) {
        statistics.droppedFrameCount &+= 1
        statistics.processingFailureCount &+= 1
        sourceColorContractStatus = "rejected:\(error.localizedDescription)"
        statistics.lastErrorDescription = error.localizedDescription
        refreshStatisticsNotes()
        statisticsHandler(statistics)
        guard !terminalContractFailureReported else { return }
        terminalContractFailureReported = true
        sourceColorContractFailureReported = true
        eventHandler(.init(
            kind: .failed,
            message: error.localizedDescription,
            sourceDisplayTime: sourceDisplayTime
        ))
        terminationHandler(error)
    }

    private func setProperty(_ key: CFString, value: CFTypeRef) throws {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return }
        let status = VTSessionSetProperty(compressionSession, key: key, value: value)
        guard status == noErr else {
            throw LumenScreenCaptureError.compressionPropertyFailed(String(describing: key), status)
        }
    }

    private func completeCompressionFrames() -> OSStatus {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return noErr }
        return VTCompressionSessionCompleteFrames(
            compressionSession,
            untilPresentationTimeStamp: .invalid
        )
    }

    private func reportCompressionFrameCompletionFailure(
        status: OSStatus,
        cancelledContexts: [LumenEncodedFrameContext]
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let error = LumenScreenCaptureError
            .compressionFrameCompletionFailed(status)
        inflightFrameCount = max(
            inflightFrameCount - cancelledContexts.count,
            0
        )
        statistics.droppedFrameCount &+= UInt64(cancelledContexts.count)
        statistics.processingFailureCount &+= 1
        statistics.lastErrorDescription = error.localizedDescription
        if cancelledContexts.contains(where: \.requiresBootstrapAcknowledgement) {
            videoBootstrapAdmission.cancelBootstrapSubmission()
            pendingVideoBootstrapSource = nil
        }
        refreshStatisticsNotes()
        statisticsHandler(statistics)
        eventHandler(.init(
            kind: .failed,
            message: error.localizedDescription,
            stopStatus: status
        ))
        terminationHandler(error)
    }

    private func invalidateCompressionSession() {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return }
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
    }

    private func makeStatisticsNotes(width: Int, height: Int) -> [String] {
        let sourceApproxFrameRate = averageFrameRate(
            intervalTotalMilliseconds: sourceIntervalTotalMilliseconds,
            sampleCount: sourceIntervalSampleCount
        )
        let outputApproxFrameRate = averageFrameRate(
            intervalTotalMilliseconds: outputIntervalTotalMilliseconds,
            sampleCount: outputIntervalSampleCount
        )
        var notes = [
            "captureBackend=screen-capture-kit",
            "screenCaptureOutputRegistrationStage=\(outputOwnership.stage.rawValue)",
            "screenCaptureDisplayAdmissionMode=\(displayAdmissionMode.rawValue)",
            "screenCaptureDisplayAdmissionMilliseconds=\(displayAdmissionDurationMilliseconds)",
            "screenCaptureStreamStartMilliseconds=\(streamStartDurationMilliseconds)",
            "screenCaptureOwnedSampleCount=\(outputOwnership.screenSampleCount)",
            "sourceCaptureSampleCount=\(statistics.sourceFrameCount)",
            "sourceApproxFrameRate=\(sourceApproxFrameRate)",
            "sourceCallbackApproxFrameRate=\(sourceApproxFrameRate)",
            "videoToolboxTargetFrameRateHint=\(configuration.effectiveTargetFrameRate)",
            "videoToolboxEncoderInputPixelFormat=\(capturePixelFormat)",
            "videoToolboxSourcePixelFormat=\(capturePixelFormat)",
            "sourceColorContract=\(sourceColorContractStatus)",
            "videoToolboxStagingMode=direct-cvpixelbuffer",
            "videoToolboxAdmissionMode=serial-offloaded-latest",
            "videoToolboxPendingSourceBound=1",
            "videoToolboxConversionCount=0",
            "videoToolboxProfile=\(encodingPlan?.profile ?? "unresolved")",
            "videoToolboxHardwareRequired=true",
            "videoToolboxAllowOpenGOP=\(statistics.exactCaptureAudit.allowOpenGOP.map { String($0) } ?? "n/a")",
            "videoToolboxConfiguredSourceFrameCount=\(width)x\(height)",
            "videoToolboxSubmittedFrameCount=\(statistics.submittedFrameCount)",
            "videoToolboxPendingAdmissionDropCount=\(statistics.pendingAdmissionDropCount)",
            "videoToolboxBootstrapGateOpen=\(videoBootstrapAdmission.isOpen)",
            "videoToolboxBootstrapPendingSource=\(pendingVideoBootstrapSource != nil)",
            "videoToolboxCurrentInflightStagingSlots=\(inflightFrameCount)",
            "videoToolboxMaxInflightStagingSlots=\(statistics.maximumInflightFrameCount)",
            "videoToolboxOutputApproxFrameRate=\(outputApproxFrameRate)"
        ]
        notes.append(contentsOf: captureStageTimingNotes())
        return notes
    }

    private static func identity(of stream: SCStream) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(stream).toOpaque())
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func captureStageTimingNotes() -> [String] {
        captureIngressTimings.diagnosticNotes
            + lumenCaptureTimingNotes(
                prefix: "sourceCallbackService",
                timing: sourceCallbackServiceTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxAdmissionWait",
                timing: encoderAdmissionWaitTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxEncodeInvocation",
                timing: encoderInvocationTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxEncodeToCallback",
                timing: videoToolboxCallbackTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxOutputOwnerQueueWait",
                timing: outputOwnerQueueWaitTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxOutputService",
                timing: outputServiceTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxFrameHandler",
                timing: frameHandlerTiming
            )
    }

    private func refreshStatisticsNotesIfNeeded() {
        if statistics.sourceFrameCount == 1 || statistics.sourceFrameCount % 120 == 0 {
            refreshStatisticsNotes()
            statisticsHandler(statistics)
        }
    }

    private func refreshStatisticsNotes() {
        statistics.notes = makeStatisticsNotes(width: outputWidth, height: outputHeight)
    }

    private func averageFrameRate(intervalTotalMilliseconds: Double, sampleCount: UInt64) -> String {
        guard sampleCount > 0, intervalTotalMilliseconds > 0 else { return "0.0" }
        return String(format: "%.2f", Double(sampleCount) * 1_000 / intervalTotalMilliseconds)
    }

    fileprivate func enqueueCompressionOutput(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        contextPointer: UnsafeMutableRawPointer?,
        rawCallbackMachTime: UInt64
    ) {
        let sampleBufferAddress = sampleBuffer.map {
            UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())
        }
        let contextID = contextPointer.map {
            UInt64(UInt(bitPattern: $0))
        }
        outputLifecycle.enqueueOutput(id: contextID) { [weak self] context in
            let retainedSampleBuffer = sampleBufferAddress.flatMap { address -> CMSampleBuffer? in
                guard let pointer = UnsafeRawPointer(bitPattern: address) else {
                    return nil
                }
                return Unmanaged<CMSampleBuffer>.fromOpaque(pointer).takeRetainedValue()
            }
            guard let self,
                  let context else {
                return
            }
            self.didEncode(
                status: status,
                infoFlags: infoFlags,
                sampleBuffer: retainedSampleBuffer,
                context: context,
                rawCallbackMachTime: rawCallbackMachTime
            )
        }
    }

    fileprivate func didEncode(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        context: LumenEncodedFrameContext,
        rawCallbackMachTime: UInt64
    ) {
        let outputServiceStartedMachTime = mach_absolute_time()
        videoToolboxCallbackTiming.observe(
            LumenMachTime.milliseconds(
                from: context.submissionMachTime,
                to: rawCallbackMachTime
            )
        )
        outputOwnerQueueWaitTiming.observe(
            LumenMachTime.milliseconds(
                from: rawCallbackMachTime,
                to: outputServiceStartedMachTime
            )
        )
        defer {
            outputServiceTiming.observe(
                LumenMachTime.milliseconds(
                    from: outputServiceStartedMachTime,
                    to: mach_absolute_time()
                )
            )
        }
        inflightFrameCount = max(inflightFrameCount - 1, 0)

        guard status == noErr,
              !infoFlags.contains(.frameDropped),
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            if context.requiresBootstrapAcknowledgement {
                videoBootstrapAdmission.cancelBootstrapSubmission()
                pendingVideoBootstrapSource = nil
            }
            statistics.droppedFrameCount &+= 1
            statistics.lastErrorDescription = status == noErr ? "VideoToolbox dropped frame" : "VideoToolbox callback OSStatus \(status)"
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .droppedFrame,
                message: statistics.lastErrorDescription,
                stopStatus: status,
                sourceDisplayTime: context.displayTime
            ))
            encoderAdmission.resumePendingIfPossible()
            return
        }

        let configurationData = exactCodecConfigurationData(from: sampleBuffer)
        if let mismatch = outputContract?.mismatchDescription(codecConfigurationData: configurationData) {
            reportTerminalContractFailure(
                .encodedOutputContractMismatch(mismatch),
                sourceDisplayTime: context.displayTime
            )
            return
        }
        switch configuration.codec {
        case .h264:
            let parsed = configurationData.flatMap(LumenVideoToolboxCodecConfigurationParser.parseAVCC)
            statistics.exactCaptureAudit.configurationAtom = "avcC"
            statistics.exactCaptureAudit.profileIdc = parsed?.profileIdc
        case .hevc:
            let parsed = configurationData.flatMap(LumenVideoToolboxCodecConfigurationParser.parseHVCC)
            statistics.exactCaptureAudit.configurationAtom = "hvcC"
            statistics.exactCaptureAudit.chromaFormatIdc = parsed?.chromaFormatIdc
            statistics.exactCaptureAudit.lumaBitDepth = parsed?.lumaBitDepth
            statistics.exactCaptureAudit.chromaBitDepth = parsed?.chromaBitDepth
        }
        statisticsHandler(statistics)

        let latency = LumenMachTime.milliseconds(from: context.submissionMachTime, to: mach_absolute_time())
        let outputMachTime = mach_absolute_time()
        if let lastOutputMachTime {
            outputIntervalTotalMilliseconds += LumenMachTime.milliseconds(from: lastOutputMachTime, to: outputMachTime)
            outputIntervalSampleCount &+= 1
        }
        lastOutputMachTime = outputMachTime
        statistics.emittedFrameCount &+= 1
        statistics.minOutputCallbackLatencyMilliseconds = min(statistics.minOutputCallbackLatencyMilliseconds ?? latency, latency)
        statistics.maxOutputCallbackLatencyMilliseconds = max(statistics.maxOutputCallbackLatencyMilliseconds ?? latency, latency)
        refreshStatisticsNotesIfNeeded()

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        if context.requiresBootstrapAcknowledgement, !isKeyFrame {
            videoBootstrapAdmission.cancelBootstrapSubmission()
            pendingVideoBootstrapSource = nil
            reportTerminalContractFailure(
                .requiredKeyFrameNotProduced,
                sourceDisplayTime: context.displayTime
            )
            return
        }
        encoderAdmission.resumePendingIfPossible()
        let hdr = configuration.encodedColorConfiguration
        let formatExtensions = sampleBuffer.formatDescription.flatMap {
            CMFormatDescriptionGetExtensions($0) as? [String: Any]
        }
        let frameHandlerStartedMachTime = mach_absolute_time()
        frameHandler(
            LumenEncodedFrame(
                sampleBuffer: sampleBuffer,
                codec: configuration.codec,
                sourceSequenceNumber: context.sequenceNumber,
                sourceDisplayTime: context.displayTime,
                outputCallbackLatencyMilliseconds: latency,
                isKeyFrame: isKeyFrame,
                requiresBootstrapAcknowledgement: context.requiresBootstrapAcknowledgement,
                isRepairKeyFrame: context.requiresBootstrapAcknowledgement,
                isHDRSignaled: hdr.map { $0.transferFunction != .ituR709 } ?? false,
                hdrValidationReport: .init(
                    colorPrimaries: formatExtensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? hdr?.colorPrimaries.rawValue,
                    transferFunction: formatExtensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? hdr?.transferFunction.rawValue,
                    yCbCrMatrix: formatExtensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String ?? hdr?.yCbCrMatrix.rawValue,
                    hasMasteringDisplayColorVolume: formatExtensions?[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil,
                    hasContentLightLevelInfo: formatExtensions?[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] != nil
                )
            )
        )
        frameHandlerTiming.observe(
            LumenMachTime.milliseconds(
                from: frameHandlerStartedMachTime,
                to: mach_absolute_time()
            )
        )
    }
}

private func lumenScreenCaptureCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    let rawCallbackMachTime = mach_absolute_time()
    guard let outputCallbackRefCon else { return }
    Unmanaged<LumenScreenCaptureVideoRuntime>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
        .enqueueCompressionOutput(
            status: status,
            infoFlags: infoFlags,
            sampleBuffer: sampleBuffer,
            contextPointer: sourceFrameRefCon,
            rawCallbackMachTime: rawCallbackMachTime
        )
}

private func exactCodecConfigurationData(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any],
          let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
            as? [String: Any] else {
        return nil
    }
    return (atoms["avcC"] as? Data) ?? (atoms["hvcC"] as? Data)
}

private func auditFourCC(_ value: OSType) -> String {
    String(bytes: [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ], encoding: .ascii) ?? String(value)
}

enum LumenMachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard timebase.denom != 0, end >= start else { return 0 }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    static func ticks(for time: CMTime) -> UInt64? {
        guard time.isValid, time.seconds.isFinite, time.seconds >= 0 else { return nil }
        guard timebase.numer != 0 else { return nil }
        let nanoseconds = time.seconds * 1_000_000_000
        return UInt64(nanoseconds * Double(timebase.denom) / Double(timebase.numer))
    }
}

enum LumenScreenCaptureError: Error, LocalizedError {
    case displayUnavailable(UInt32)
    case displayOwnershipLost(UInt32)
    case captureAlreadyRunning
    case captureNotRunning
    case outputOwnershipLost
    case compressionSessionCreationFailed(OSStatus)
    case compressionSessionPreparationFailed(OSStatus)
    case compressionFrameCompletionFailed(OSStatus)
    case compressionPropertyFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable(let displayID): return "ScreenCaptureKit display \(displayID) is unavailable."
        case .displayOwnershipLost(let displayID): return "Retained virtual display \(displayID) was released before ScreenCaptureKit became ready."
        case .captureAlreadyRunning: return "ScreenCaptureKit video stream is already starting or running."
        case .captureNotRunning: return "ScreenCaptureKit video stream is not running."
        case .outputOwnershipLost: return "ScreenCaptureKit delivered a sample from a stream that no longer owns the registered video output."
        case .compressionSessionCreationFailed(let status): return "Unable to create VideoToolbox compression session (OSStatus \(status))."
        case .compressionSessionPreparationFailed(let status): return "Unable to prepare VideoToolbox compression session (OSStatus \(status))."
        case .compressionFrameCompletionFailed(let status): return "Unable to complete pending VideoToolbox frames during teardown (OSStatus \(status))."
        case .compressionPropertyFailed(let key, let status): return "Unable to set VideoToolbox property \(key) (OSStatus \(status))."
        }
    }
}

enum LumenEncodedCaptureStartupError: Error, LocalizedError {
    case runtimeTerminated(any Error)

    var underlyingError: any Error {
        switch self {
        case .runtimeTerminated(let error):
            return error
        }
    }

    var errorDescription: String? {
        switch self {
        case .runtimeTerminated(let error):
            return "ScreenCaptureKit runtime terminated during startup: \(error.localizedDescription)"
        }
    }
}

actor LumenEncodedCaptureSession {
    let configuration: LumenMacCaptureConfiguration
    private let preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?
    private let preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks?
    private let systemAudioPlaybackSuppression:
        LumenSystemAudioPlaybackSuppression?
    private let runtimeFactory: any LumenEncodedCaptureRuntimeFactory
    private var activeSystemAudio:
        LumenMacAudioCaptureConfiguration?
    private var activeSystemAudioCallbacks: LumenAudioCaptureCallbacks?
    private var activeSystemAudioIsActivated = false
    private var runtime: (any LumenEncodedCaptureRuntime)?
    private var startFlight: LumenCaptureStartFlight?
    private var callbackGate: LumenCaptureCallbackGate?
    private var systemAudioAttachFlight: LumenCaptureStartFlight?
    private var systemAudioAttachGate: LumenCaptureCallbackGate?
    private struct RuntimeStopRecord {
        let runtime: any LumenEncodedCaptureRuntime
        let task: Task<Void, Never>
    }
    private var runtimeStopRecords: [ObjectIdentifier: RuntimeStopRecord] = [:]
    private var statistics = LumenEncodedCaptureSessionStatistics()
    private var callbacks: LumenEncodedCaptureCallbacks?
    private var runtimeGeneration: UInt64 = 0
    private var recoveryInProgressGeneration: UInt64?
    private var isStopping = false
    private let maximumAutomaticRestartCount: UInt64 = 2

    init(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration? = nil,
        preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks? = nil,
        systemAudioPlaybackSuppression:
            LumenSystemAudioPlaybackSuppression? = nil,
        runtimeFactory: any LumenEncodedCaptureRuntimeFactory
    ) {
        self.configuration = configuration
        self.preconfiguredSystemAudio = preconfiguredSystemAudio
        self.preconfiguredSystemAudioCallbacks = preconfiguredSystemAudioCallbacks
        self.systemAudioPlaybackSuppression =
            systemAudioPlaybackSuppression
        self.runtimeFactory = runtimeFactory
        activeSystemAudio = preconfiguredSystemAudio
        activeSystemAudioCallbacks =
            preconfiguredSystemAudioCallbacks
    }

    func start(callbacks: LumenEncodedCaptureCallbacks) async throws {
        guard runtime == nil,
              startFlight == nil,
              systemAudioAttachFlight == nil else {
            throw LumenScreenCaptureError.captureAlreadyRunning
        }
        callbackGate?.close()
        self.callbacks = callbacks
        isStopping = false
        recoveryInProgressGeneration = nil
        runtimeGeneration &+= 1
        try await startRuntime(
            callbacks: callbacks,
            generation: runtimeGeneration,
            recoveryOwnerGeneration: nil
        )
    }

    @discardableResult
    func stop() async
        -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        isStopping = true
        runtimeGeneration &+= 1
        recoveryInProgressGeneration = nil
        callbacks = nil
        callbackGate?.close()
        let inFlight = self.startFlight
        let audioAttachInFlight = self.systemAudioAttachFlight
        systemAudioAttachGate?.close()
        let runtimeToStop = runtime
        self.runtime = nil
        await inFlight?.requestStop()
        await audioAttachInFlight?.requestStop()
        let runtimeStopTask = runtimeToStop.map { runtime in
            Task { await self.stopRuntimeOnce(runtime) }
        }
        await inFlight?.waitUntilSettled()
        await audioAttachInFlight?.waitUntilSettled()
        await runtimeStopTask?.value
        var cleanupFailures: [LumenSystemAudioPlaybackSuppressionCleanupFailure] = []
        if activeSystemAudioIsActivated,
           let systemAudioPlaybackSuppression {
            let audioCallbacks = activeSystemAudioCallbacks
            activeSystemAudioIsActivated = false
            let failures = await systemAudioPlaybackSuppression
                .deactivate()
            cleanupFailures = failures
            reportSystemAudioPlaybackSuppressionCleanupFailures(
                failures,
                callbacks: audioCallbacks
            )
            if failures.isEmpty {
                activeSystemAudio = nil
                activeSystemAudioCallbacks = nil
            } else {
                activeSystemAudioIsActivated = true
            }
        }
        return cleanupFailures
    }

    func requestImmediateKeyFrame() {
        runtime?.requestImmediateKeyFrame()
    }

    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        guard let runtime else { return false }
        return await runtime.resumeVideoEncodingAfterCodecAck()
    }

    func attachSystemAudio(
        configuration: LumenMacAudioCaptureConfiguration,
        callbacks: LumenAudioCaptureCallbacks
    ) async throws {
        guard runtime != nil, !isStopping else {
            throw LumenScreenCaptureError.captureNotRunning
        }
        try validateSystemAudioConfiguration(configuration)
        guard activeSystemAudio == nil else {
            throw LumenSystemAudioPlaybackSuppressionError
                .activationFailed(
                    stage: .createProcessTap,
                    status: nil,
                    message: "This encoded session already owns system audio.",
                    cleanupFailures: []
                )
        }
        guard let systemAudioPlaybackSuppression else {
            throw LumenAudioCaptureError
                .systemAudioPlaybackSuppressionDependencyMissing
        }
        let attachGeneration = runtimeGeneration
        let attachFlight = LumenCaptureStartFlight()
        let attachGate = LumenCaptureCallbackGate()
        systemAudioAttachFlight = attachFlight
        systemAudioAttachGate = attachGate
        let guardedCallbacks = LumenAudioCaptureCallbacks(
            frameHandler: { frame in
                guard attachGate.isOpen() else { return }
                callbacks.frameHandler(frame)
            },
            eventHandler: { event in
                guard attachGate.isOpen() else { return }
                callbacks.eventHandler?(event)
            }
        )
        var audioWasActivated = false
        do {
            guard !isStopping,
                  runtime != nil,
                  runtimeGeneration == attachGeneration,
                  !(await attachFlight.isStopRequested()) else {
                throw LumenAudioCaptureError.captureStartCancelled
            }
            try await systemAudioPlaybackSuppression.activate(
                configuration: configuration,
                callbacks: guardedCallbacks
            )
            audioWasActivated = true
            guard !isStopping,
                  runtime != nil,
                  runtimeGeneration == attachGeneration,
                  !(await attachFlight.isStopRequested()) else {
                throw LumenAudioCaptureError.captureStartCancelled
            }
            activeSystemAudio = configuration
            activeSystemAudioCallbacks = callbacks
            activeSystemAudioIsActivated = true
            await finishSystemAudioAttach(attachFlight)
        } catch let error
            as LumenSystemAudioPlaybackSuppressionError {
            if audioWasActivated {
                attachGate.close()
                let cleanupFailures = await systemAudioPlaybackSuppression
                    .deactivate()
                if !cleanupFailures.isEmpty {
                    await finishSystemAudioAttach(attachFlight)
                    throw LumenSystemAudioCaptureLifecycleError(
                        underlyingError: error,
                        cleanupFailures: cleanupFailures
                    )
                }
            }
            await finishSystemAudioAttach(attachFlight)
            throw LumenAudioCaptureError
                .systemAudioPlaybackSuppressionUnavailable(error)
        } catch {
            if audioWasActivated {
                attachGate.close()
                let cleanupFailures = await systemAudioPlaybackSuppression
                    .deactivate()
                if !cleanupFailures.isEmpty {
                    await finishSystemAudioAttach(attachFlight)
                    throw LumenSystemAudioCaptureLifecycleError(
                        underlyingError: error,
                        cleanupFailures: cleanupFailures
                    )
                }
            }
            await finishSystemAudioAttach(attachFlight)
            throw error
        }
    }

    @discardableResult
    func detachSystemAudio() async
        -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        systemAudioAttachGate?.close()
        let attachInFlight = systemAudioAttachFlight
        await attachInFlight?.requestStop()
        await attachInFlight?.waitUntilSettled()
        guard activeSystemAudioIsActivated,
              let systemAudioPlaybackSuppression else {
            systemAudioAttachGate = nil
            return []
        }
        let callbacks = activeSystemAudioCallbacks
        activeSystemAudioIsActivated = false
        systemAudioAttachGate = nil
        let failures = await systemAudioPlaybackSuppression.deactivate()
        reportSystemAudioPlaybackSuppressionCleanupFailures(
            failures,
            callbacks: callbacks
        )
        if failures.isEmpty {
            activeSystemAudio = nil
            activeSystemAudioCallbacks = nil
        } else {
            activeSystemAudioIsActivated = true
        }
        return failures
    }

    private func finishSystemAudioAttach(_ flight: LumenCaptureStartFlight) async {
        if systemAudioAttachFlight === flight {
            systemAudioAttachFlight = nil
        }
        _ = await flight.finishStart(terminationError: nil)
        await flight.settle()
    }

    func statisticsSnapshot() -> LumenEncodedCaptureSessionStatistics {
        statistics
    }

    private func updateStatistics(_ statistics: LumenEncodedCaptureSessionStatistics) {
        var statistics = statistics
        statistics.automaticRestartCount = max(
            statistics.automaticRestartCount,
            self.statistics.automaticRestartCount
        )
        self.statistics = statistics
    }

    private func startRuntime(
        callbacks: LumenEncodedCaptureCallbacks,
        generation: UInt64,
        recoveryOwnerGeneration: UInt64?
    ) async throws {
        guard startRuntimeIsCurrent(
            generation: generation,
            runtime: nil,
            recoveryOwnerGeneration: recoveryOwnerGeneration,
            requireRuntimeIdentity: false
        ) else {
            return
        }
        let owner = self
        let flight = LumenCaptureStartFlight()
        let callbackGate = LumenCaptureCallbackGate()
        let terminationLatch = LumenCaptureTerminationLatch()
        self.startFlight = flight
        self.callbackGate = callbackGate

        let guardedCallbacks = LumenEncodedCaptureCallbacks(
            frameHandler: { frame in
                guard callbackGate.isOpen() else { return }
                callbacks.frameHandler(frame)
            },
            eventHandler: { event in
                guard callbackGate.isOpen() else { return }
                callbacks.eventHandler?(event)
            }
        )
        let runtime: any LumenEncodedCaptureRuntime
        do {
            runtime = try runtimeFactory.makeRuntime(
                context: .init(
                    configuration: configuration,
                    callbacks: guardedCallbacks,
                    statisticsHandler: { statistics in
                        guard callbackGate.isOpen() else { return }
                        Task { await owner.updateStatistics(statistics) }
                    },
                    terminationHandler: { error in
                        let wasDuringStart = terminationLatch.record(error)
                        guard !wasDuringStart else {
                            return
                        }
                        Task {
                            await owner.handleUnexpectedTermination(
                                generation: generation,
                                error: error
                            )
                        }
                    }
                )
            )
        } catch {
            await finishStartFlight(flight)
            throw error
        }
        self.runtime = runtime
        var audioWasActivated = false
        var activatedAudioCallbacks: LumenAudioCaptureCallbacks?
        var runtimeStartWasAttempted = false
        var failureHandled = false
        var cleanupFailures: [LumenSystemAudioPlaybackSuppressionCleanupFailure] = []
        do {
            if let activeSystemAudio {
                try validateSystemAudioConfiguration(
                    activeSystemAudio
                )
                guard let activeSystemAudioCallbacks else {
                    throw LumenAudioCaptureError
                        .systemAudioPlaybackSuppressionDependencyMissing
                }
                guard let systemAudioPlaybackSuppression else {
                    throw LumenAudioCaptureError
                        .systemAudioPlaybackSuppressionDependencyMissing
                }
                let audioCallbacks = activeSystemAudioCallbacks
                let guardedAudioCallbacks = LumenAudioCaptureCallbacks(
                    frameHandler: { frame in
                        guard callbackGate.isOpen() else { return }
                        audioCallbacks.frameHandler(frame)
                    },
                    eventHandler: { event in
                        guard callbackGate.isOpen() else { return }
                        audioCallbacks.eventHandler?(event)
                    }
                )
                try await systemAudioPlaybackSuppression.activate(
                    configuration: activeSystemAudio,
                    callbacks: guardedAudioCallbacks
                )
                audioWasActivated = true
                activatedAudioCallbacks = activeSystemAudioCallbacks
                activeSystemAudioIsActivated = true
            }

            let stopRequestedBeforeStart = await flight.isStopRequested()
            guard !stopRequestedBeforeStart,
                  startRuntimeIsCurrent(
                      generation: generation,
                      runtime: runtime,
                      recoveryOwnerGeneration: recoveryOwnerGeneration,
                      requireRuntimeIdentity: true
                  ) else {
                failureHandled = true
                cleanupFailures = await stopRuntimeAfterStartFailure(
                    runtime: runtime,
                    flight: flight,
                    callbackGate: callbackGate,
                    audioWasActivated: audioWasActivated,
                    activatedAudioCallbacks: activatedAudioCallbacks,
                    stopRuntime: true
                )
                return
            }
            runtimeStartWasAttempted = true
            try await runtime.start()
            let completion = await flight.finishStart(
                terminationError: terminationLatch.complete()
            )
            if let terminationError = completion.terminationError {
                failureHandled = true
                cleanupFailures = await stopRuntimeAfterStartFailure(
                    runtime: runtime,
                    flight: flight,
                    callbackGate: callbackGate,
                    audioWasActivated: audioWasActivated,
                    activatedAudioCallbacks: activatedAudioCallbacks,
                    stopRuntime: true
                )
                if recoveryOwnerGeneration == nil {
                    throw LumenEncodedCaptureStartupError
                        .runtimeTerminated(terminationError)
                }
                throw terminationError
            }
            let stopRequestedAfterStart = await flight.isStopRequested()
            guard !stopRequestedAfterStart,
                  startRuntimeIsCurrent(
                      generation: generation,
                      runtime: runtime,
                      recoveryOwnerGeneration: recoveryOwnerGeneration,
                      requireRuntimeIdentity: true
                  ) else {
                failureHandled = true
                cleanupFailures = await stopRuntimeAfterStartFailure(
                    runtime: runtime,
                    flight: flight,
                    callbackGate: callbackGate,
                    audioWasActivated: audioWasActivated,
                    activatedAudioCallbacks: activatedAudioCallbacks,
                    stopRuntime: true
                )
                return
            }
            await finishStartFlight(flight)
        } catch {
            let completion = await flight.finishStart(
                terminationError: terminationLatch.complete(),
                error: error
            )
            if !failureHandled {
                let stopRequestedAfterFailure = await flight.isStopRequested()
                cleanupFailures = await stopRuntimeAfterStartFailure(
                    runtime: runtime,
                    flight: flight,
                    callbackGate: callbackGate,
                    audioWasActivated: audioWasActivated,
                    activatedAudioCallbacks: activatedAudioCallbacks,
                    stopRuntime: runtimeStartWasAttempted || stopRequestedAfterFailure
                )
            }
            let failure = completion.terminationError
                ?? completion.startError
                ?? error
            if recoveryOwnerGeneration == nil,
               completion.terminationError != nil {
                let startupFailure = LumenEncodedCaptureStartupError
                    .runtimeTerminated(failure)
                if !cleanupFailures.isEmpty {
                    throw LumenSystemAudioCaptureLifecycleError(
                        underlyingError: startupFailure,
                        cleanupFailures: cleanupFailures
                    )
                }
                throw startupFailure
            }
            if !cleanupFailures.isEmpty {
                throw LumenSystemAudioCaptureLifecycleError(
                    underlyingError: failure,
                    cleanupFailures: cleanupFailures
                )
            }
            let typedError = Self.typedSystemAudioError(failure)
            throw typedError
        }
    }

    private func finishStartFlight(_ flight: LumenCaptureStartFlight) async {
        if self.startFlight === flight {
            self.startFlight = nil
        }
        await flight.settle()
    }

    private func stopRuntimeOnce(
        _ runtime: any LumenEncodedCaptureRuntime
    ) async {
        let identity = ObjectIdentifier(runtime)
        if let existing = runtimeStopRecords[identity],
           existing.runtime === runtime {
            await existing.task.value
            return
        }
        let task = Task { await runtime.stop() }
        runtimeStopRecords[identity] = .init(runtime: runtime, task: task)
        await task.value
    }

    private func stopRuntimeAfterStartFailure(
        runtime: any LumenEncodedCaptureRuntime,
        flight: LumenCaptureStartFlight,
        callbackGate: LumenCaptureCallbackGate,
        audioWasActivated: Bool,
        activatedAudioCallbacks: LumenAudioCaptureCallbacks?,
        stopRuntime: Bool
    ) async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        callbackGate.close()
        if stopRuntime {
            await stopRuntimeOnce(runtime)
        }
        if audioWasActivated,
           let systemAudioPlaybackSuppression {
            activeSystemAudioIsActivated = false
            let cleanupFailures = await systemAudioPlaybackSuppression
                .deactivate()
            reportSystemAudioPlaybackSuppressionCleanupFailures(
                cleanupFailures,
                callbacks: activatedAudioCallbacks
            )
            activeSystemAudioIsActivated = !cleanupFailures.isEmpty
            if self.runtime === runtime {
                self.runtime = nil
            }
            await finishStartFlight(flight)
            return cleanupFailures
        }
        if self.runtime === runtime {
            self.runtime = nil
        }
        await finishStartFlight(flight)
        return []
    }

    private func handleUnexpectedTermination(
        generation: UInt64,
        error: Error
    ) async {
        guard !isStopping,
              generation == runtimeGeneration,
              recoveryInProgressGeneration == nil,
              let callbacks else {
            return
        }
        recoveryInProgressGeneration = generation
        runtimeGeneration &+= 1
        let replacementGeneration = runtimeGeneration
        callbackGate?.close()

        let failedRuntime = runtime
        runtime = nil
        if let failedRuntime {
            await stopRuntimeOnce(failedRuntime)
        }
        guard recoveryIsCurrent(
            failedGeneration: generation,
            replacementGeneration: replacementGeneration
        ) else {
            clearRecoveryIfOwned(by: generation)
            return
        }
        let cleanupFailures:
            [LumenSystemAudioPlaybackSuppressionCleanupFailure]
        if activeSystemAudioIsActivated,
           let systemAudioPlaybackSuppression {
            activeSystemAudioIsActivated = false
            cleanupFailures = await systemAudioPlaybackSuppression
                .deactivate()
            activeSystemAudioIsActivated = !cleanupFailures.isEmpty
        } else {
            cleanupFailures = []
        }
        guard recoveryIsCurrent(
            failedGeneration: generation,
            replacementGeneration: replacementGeneration
        ) else {
            clearRecoveryIfOwned(by: generation)
            return
        }
        if !cleanupFailures.isEmpty {
            clearRecoveryIfOwned(by: generation)
            reportSystemAudioPlaybackSuppressionCleanupFailures(
                cleanupFailures,
                callbacks: activeSystemAudioCallbacks
            )
            statistics.isRunning = false
            statistics.lastErrorDescription =
                LumenAudioCaptureError
                .systemAudioPlaybackSuppressionCleanupFailed(
                    cleanupFailures
                )
                .localizedDescription
            callbacks.eventHandler?(.init(
                kind: .failed,
                message: statistics.lastErrorDescription,
                automaticRestartCount:
                    statistics.automaticRestartCount
            ))
            return
        }

        if error is LumenExactCaptureError {
            clearRecoveryIfOwned(by: generation)
            statistics.isRunning = false
            statistics.lastErrorDescription = error.localizedDescription
            callbacks.eventHandler?(.init(
                kind: .failed,
                message: error.localizedDescription,
                automaticRestartCount: statistics.automaticRestartCount
            ))
            return
        }

        guard statistics.automaticRestartCount < maximumAutomaticRestartCount else {
            clearRecoveryIfOwned(by: generation)
            statistics.isRunning = false
            statistics.lastErrorDescription = error.localizedDescription
            callbacks.eventHandler?(.init(
                kind: .failed,
                message: "ScreenCaptureKit exhausted automatic restarts: \(error.localizedDescription)",
                automaticRestartCount: statistics.automaticRestartCount
            ))
            return
        }

        statistics.automaticRestartCount &+= 1
        let restartCount = statistics.automaticRestartCount
        callbacks.eventHandler?(.init(
            kind: .restarted,
            message: "Restarting ScreenCaptureKit after unexpected termination",
            automaticRestartCount: restartCount
        ))

        try? await Task.sleep(nanoseconds: 150_000_000)
        guard recoveryIsCurrent(
            failedGeneration: generation,
            replacementGeneration: replacementGeneration
        ) else {
            clearRecoveryIfOwned(by: generation)
            return
        }
        do {
            try await startRuntime(
                callbacks: callbacks,
                generation: replacementGeneration,
                recoveryOwnerGeneration: generation
            )
            clearRecoveryIfOwned(by: generation)
        } catch {
            guard !isStopping,
                  replacementGeneration == runtimeGeneration else {
                clearRecoveryIfOwned(by: generation)
                return
            }
            clearRecoveryIfOwned(by: generation)
            await handleUnexpectedTermination(
                generation: replacementGeneration,
                error: error
            )
        }
    }

    private func startRuntimeIsCurrent(
        generation: UInt64,
        runtime: (any LumenEncodedCaptureRuntime)?,
        recoveryOwnerGeneration: UInt64?,
        requireRuntimeIdentity: Bool
    ) -> Bool {
        guard !isStopping,
              runtimeGeneration == generation else {
            return false
        }
        if requireRuntimeIdentity,
           let runtime,
           self.runtime !== runtime {
            return false
        }
        guard let recoveryOwnerGeneration else {
            return recoveryInProgressGeneration == nil
        }
        return recoveryInProgressGeneration == recoveryOwnerGeneration
    }

    private func recoveryIsCurrent(
        failedGeneration: UInt64,
        replacementGeneration: UInt64
    ) -> Bool {
        !isStopping &&
            recoveryInProgressGeneration == failedGeneration &&
            runtimeGeneration == replacementGeneration
    }

    private func clearRecoveryIfOwned(by generation: UInt64) {
        if recoveryInProgressGeneration == generation {
            recoveryInProgressGeneration = nil
        }
    }

    private func reportSystemAudioPlaybackSuppressionCleanupFailures(
        _ failures: [LumenSystemAudioPlaybackSuppressionCleanupFailure],
        callbacks: LumenAudioCaptureCallbacks?
    ) {
        guard !failures.isEmpty else {
            return
        }
        callbacks?.eventHandler?(.init(
            kind: .failed,
            message: LumenAudioCaptureError
                .systemAudioPlaybackSuppressionCleanupFailed(failures)
                .localizedDescription
        ))
    }

    private func validateSystemAudioConfiguration(
        _ configuration: LumenMacAudioCaptureConfiguration
    ) throws {
        guard case .systemOutput(let displayID, _) =
            configuration.source else {
            throw LumenAudioCaptureError.invalidSource
        }
        guard displayID == self.configuration.displayID else {
            throw LumenAudioCaptureError
                .activeVideoDisplayMismatch(
                    audioDisplayID: displayID,
                    videoDisplayID: self.configuration.displayID
                )
        }
    }

    private nonisolated static func typedSystemAudioError(
        _ error: any Error
    ) -> any Error {
        if let error =
            error as? LumenSystemAudioPlaybackSuppressionError {
            return LumenAudioCaptureError
                .systemAudioPlaybackSuppressionUnavailable(error)
        }
        if error is CancellationError {
            return LumenAudioCaptureError
                .systemAudioPlaybackSuppressionCancelled
        }
        return error
    }
}
