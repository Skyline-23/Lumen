import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OSLog
import ScreenCaptureKit
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

private struct LumenEncodedFrameContext {
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

private struct LumenPendingVideoBootstrapSource {
    let imageBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let displayTime: UInt64
    let duration: CMTime
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

    init(
        ownerToken: UInt?,
        isOnline: Bool,
        isActive: Bool,
        hasCurrentMode: Bool,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) {
        self.ownerToken = ownerToken
        self.isOnline = isOnline
        self.isActive = isActive
        self.hasCurrentMode = hasCurrentMode
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
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
            // pixel geometry while CGDisplayCopyDisplayMode remains unavailable.
            return pixelWidth > 0 && pixelHeight > 0
        case .exactExternal:
            return false
        }
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
        if let owner, currentOwner === owner.display {
            ownerToken = owner.ownerToken
        } else {
            ownerToken = currentOwner.map {
                UInt(bitPattern: ObjectIdentifier($0))
            }
        }
        return LumenScreenCaptureDisplayReadinessSnapshot(
            ownerToken: ownerToken,
            isOnline: CGDisplayIsOnline(displayID) != 0,
            isActive: CGDisplayIsActive(displayID) != 0,
            hasCurrentMode: CGDisplayCopyDisplayMode(displayID) != nil,
            pixelWidth: CGDisplayPixelsWide(displayID),
            pixelHeight: CGDisplayPixelsHigh(displayID)
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
            "stage=display-readiness-begin display-id=\(displayID) authority=\(authorityLabel) owner-token=\(ownerToken) online=\(initialSnapshot.isOnline) active=\(initialSnapshot.isActive) current-mode=\(initialSnapshot.hasCurrentMode) pixel-size=\(initialSnapshot.pixelWidth)x\(initialSnapshot.pixelHeight) mode-ready=\(initialModeReady)"
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
                "stage=display-readiness-failed display-id=\(displayID) authority=\(authorityLabel) owner-token=\(ownerToken) online=\(failureSnapshot.isOnline) active=\(failureSnapshot.isActive) current-mode=\(failureSnapshot.hasCurrentMode) pixel-size=\(failureSnapshot.pixelWidth)x\(failureSnapshot.pixelHeight) mode-ready=\(failureModeReady) elapsed-ms=\(elapsedMilliseconds(since: startedAt)) error=\(String(describing: error))"
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
        guard before.isModeReady(for: authority) else {
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
              after.isModeReady(for: authority) else {
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
    case sharedAudioRegistered = "screen-and-audio-registered"
    case stopped
}

struct LumenScreenCaptureSystemAudioPreparation: Equatable, Sendable {
    let configuration: LumenMacAudioCaptureConfiguration

    init(
        configuration: LumenMacAudioCaptureConfiguration,
        videoDisplayID: UInt32
    ) throws {
        guard case .systemOutput(let audioDisplayID, _) = configuration.source else {
            throw LumenAudioCaptureError.invalidSource
        }
        guard audioDisplayID == videoDisplayID else {
            throw LumenAudioCaptureError.activeVideoDisplayMismatch(
                audioDisplayID: audioDisplayID,
                videoDisplayID: videoDisplayID
            )
        }
        self.configuration = configuration
    }

    func apply(to streamConfiguration: SCStreamConfiguration) {
        guard case .systemOutput(_, let excludesCurrentProcessAudio) = configuration.source else {
            return
        }
        streamConfiguration.capturesAudio = true
        streamConfiguration.sampleRate = configuration.sampleRate
        streamConfiguration.channelCount = configuration.channelCount
        streamConfiguration.excludesCurrentProcessAudio = excludesCurrentProcessAudio
    }

    func accepts(_ configuration: LumenMacAudioCaptureConfiguration) -> Bool {
        self.configuration == configuration
    }
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
        if stage != .sharedAudioRegistered {
            stage = .captureStarted
        }
    }

    mutating func attachSharedAudioOutput(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        stage = .sharedAudioRegistered
    }

    mutating func recordScreenSample(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        screenSampleCount &+= 1
    }

    mutating func detachSharedAudioOutput(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        stage = .captureStarted
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

/// Safety: ScreenCaptureKit and VideoToolbox callbacks enter through `queue`.
/// Mutable encode state is initialized before capture starts and is otherwise
/// read or mutated only on that serial queue; lifecycle teardown synchronizes
/// with the queue before releasing the compression session.
private final class LumenScreenCaptureVideoRuntime: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let startupLogger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )
    private let configuration: LumenMacCaptureConfiguration
    private let systemAudioPreparation: LumenScreenCaptureSystemAudioPreparation?
    private let preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks?
    private let frameHandler: @Sendable (LumenEncodedFrame) -> Void
    private let eventHandler: @Sendable (LumenEncodedCaptureSessionEvent) -> Void
    private let statisticsHandler: @Sendable (LumenEncodedCaptureSessionStatistics) -> Void
    private let terminationHandler: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.sck.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "dev.skyline23.lumen.sck.shared-audio", qos: .userInteractive)
    private var stream: SCStream?
    private var sharedAudioOutput: LumenSystemAudioCaptureOutput?
    private var compressionSession: VTCompressionSession?
    private var encodingPlan: LumenVideoToolboxEncodingPlan?
    private var sourceContract: LumenExactCaptureSourceContract?
    private var outputContract: LumenExactEncodedOutputContract?
    private var sequenceNumber: UInt64 = 0
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

    init(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?,
        preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks?,
        callbacks: LumenEncodedCaptureCallbacks,
        statisticsHandler: @escaping @Sendable (LumenEncodedCaptureSessionStatistics) -> Void,
        terminationHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        self.configuration = configuration
        self.systemAudioPreparation = try preconfiguredSystemAudio.map {
            try LumenScreenCaptureSystemAudioPreparation(
                configuration: $0,
                videoDisplayID: configuration.displayID
            )
        }
        self.preconfiguredSystemAudioCallbacks = preconfiguredSystemAudioCallbacks
        self.frameHandler = callbacks.frameHandler
        self.eventHandler = { callbacks.eventHandler?($0) }
        self.statisticsHandler = statisticsHandler
        self.terminationHandler = terminationHandler
        super.init()
    }

    func start() async throws {
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
        displayAdmissionMode = admission.mode
        displayAdmissionDurationMilliseconds = Self.elapsedMilliseconds(since: admissionStart)
        Self.startupLogger.notice(
            "stage=display-admission-complete display-id=\(displayID, privacy: .public) mode=\(admission.mode.rawValue, privacy: .public) elapsed-ms=\(self.displayAdmissionDurationMilliseconds, privacy: .public)"
        )
        let display = admission.value.value

        let width = configuration.requestedWidth ?? display.width
        let height = configuration.requestedHeight ?? display.height
        outputWidth = configuration.effectivePreprocessStrategy == .downscale2x ? max(width / 2, 1) : width
        outputHeight = configuration.effectivePreprocessStrategy == .downscale2x ? max(height / 2, 1) : height

        let plan = try await resolveEncodingPlan()
        encodingPlan = plan
        sourceContract = try LumenExactCaptureSourceContract(
            configuration: configuration,
            width: outputWidth,
            height: outputHeight
        )
        outputContract = try LumenExactEncodedOutputContract(configuration: configuration)

        let streamConfiguration = LumenCaptureStreamConfigurationFactory.make(
            configuration: configuration
        )
        streamConfiguration.width = outputWidth
        streamConfiguration.height = outputHeight
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.effectiveTargetFrameRate))
        streamConfiguration.queueDepth = configuration.negotiatedQueueProfile.queueDepthHint
        streamConfiguration.pixelFormat = plan.pixelFormat
        if configuration.chromaSubsampling == .yuv444, configuration.dynamicRange == .sdr {
            streamConfiguration.colorSpaceName = CGColorSpace.itur_709
            streamConfiguration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        streamConfiguration.scalesToFit = false
        streamConfiguration.preservesAspectRatio = true
        systemAudioPreparation?.apply(to: streamConfiguration)
        try createCompressionSession(width: outputWidth, height: outputHeight)

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        let streamIdentity = Self.identity(of: stream)
        queue.sync {
            outputOwnership.registerScreenOutput(streamIdentity: streamIdentity)
        }
        do {
            if systemAudioPreparation != nil,
               let preconfiguredSystemAudioCallbacks {
                let audioOutput = LumenSystemAudioCaptureOutput(
                    callbacks: preconfiguredSystemAudioCallbacks
                )
                do {
                    try stream.addStreamOutput(
                        audioOutput,
                        type: .audio,
                        sampleHandlerQueue: audioQueue
                    )
                } catch {
                    throw LumenBridgeCaptureStartupError(
                        source: .audio,
                        message: (error as NSError).localizedDescription
                    )
                }
                sharedAudioOutput = audioOutput
                queue.sync {
                    try? outputOwnership.attachSharedAudioOutput(streamIdentity: streamIdentity)
                }
            }
            let streamStart = DispatchTime.now().uptimeNanoseconds
            try await stream.startCapture()
            streamStartDurationMilliseconds = Self.elapsedMilliseconds(since: streamStart)
            Self.startupLogger.notice(
                "stage=stream-start-complete display-id=\(displayID, privacy: .public) stream=\(streamIdentity, privacy: .public) elapsed-ms=\(self.streamStartDurationMilliseconds, privacy: .public) source-queue-depth=\(streamConfiguration.queueDepth, privacy: .public) audio-pre-registered=\(self.sharedAudioOutput != nil, privacy: .public)"
            )
        } catch {
            if let sharedAudioOutput {
                try? stream.removeStreamOutput(sharedAudioOutput, type: .audio)
                self.sharedAudioOutput = nil
            }
            try? stream.removeStreamOutput(self, type: .screen)
            if self.stream === stream {
                self.stream = nil
            }
            throw error
        }
        queue.sync {
            try? outputOwnership.markCaptureStarted(streamIdentity: streamIdentity)
        }
        statistics.isRunning = true
        statistics.notes = makeStatisticsNotes(width: outputWidth, height: outputHeight)
        statisticsHandler(statistics)
        if let preconfiguredSystemAudioCallbacks {
            preconfiguredSystemAudioCallbacks.eventHandler?(.init(
                kind: .started,
                message: "ScreenCaptureKit system audio started with pre-registered shared stream=\(streamIdentity)"
            ))
        }
        eventHandler(.init(
            kind: .started,
            message: "ScreenCaptureKit capture started stream=\(streamIdentity) output-registration=\(outputOwnership.stage.rawValue) system-audio-preconfigured=\(systemAudioPreparation != nil) display-admission=\(displayAdmissionMode.rawValue) display-admission-ms=\(displayAdmissionDurationMilliseconds) stream-start-ms=\(streamStartDurationMilliseconds)"
        ))
    }

    func stop() async {
        await detachSystemAudio()
        queue.sync {
            stopping = true
        }
        guard let stream else {
            queue.sync {
                invalidateCompressionSession()
            }
            return
        }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
        let streamIdentity = Self.identity(of: stream)
        if self.stream === stream {
            self.stream = nil
        }
        queue.sync {
            try? outputOwnership.stop(streamIdentity: streamIdentity)
            if let compressionSession {
                VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            }
            invalidateCompressionSession()
        }
        statistics.isRunning = false
        refreshStatisticsNotes()
        statisticsHandler(statistics)
        eventHandler(.init(
            kind: .stopped,
            message: "ScreenCaptureKit capture stopped output-registration=\(outputOwnership.stage.rawValue) source-samples=\(outputOwnership.screenSampleCount)",
            stopStatus: 0
        ))
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

    func attachSystemAudio(
        configuration: LumenMacAudioCaptureConfiguration,
        callbacks: LumenAudioCaptureCallbacks
    ) async throws {
        guard case .systemOutput(let displayID, _) = configuration.source else {
            throw LumenAudioCaptureError.invalidSource
        }
        guard displayID == self.configuration.displayID else {
            throw LumenAudioCaptureError.activeVideoDisplayMismatch(
                audioDisplayID: displayID,
                videoDisplayID: self.configuration.displayID
            )
        }
        guard sharedAudioOutput == nil,
              let stream else {
            if sharedAudioOutput != nil {
                return
            }
            throw LumenScreenCaptureError.captureNotRunning
        }
        guard systemAudioPreparation?.accepts(configuration) == true else {
            throw LumenScreenCaptureError.systemAudioWasNotPreconfigured
        }

        let output = LumenSystemAudioCaptureOutput(callbacks: callbacks)
        let streamIdentity = Self.identity(of: stream)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        sharedAudioOutput = output
        queue.sync {
            try? outputOwnership.attachSharedAudioOutput(streamIdentity: streamIdentity)
            refreshStatisticsNotes()
            statisticsHandler(statistics)
        }
        callbacks.eventHandler?(.init(
            kind: .started,
            message: "ScreenCaptureKit system audio joined preconfigured video stream=\(streamIdentity) output-registration=\(outputOwnership.stage.rawValue)"
        ))
    }

    func detachSystemAudio() async {
        guard let output = sharedAudioOutput,
              let stream else {
            sharedAudioOutput = nil
            return
        }
        let streamIdentity = Self.identity(of: stream)
        try? stream.removeStreamOutput(output, type: .audio)
        if sharedAudioOutput === output {
            sharedAudioOutput = nil
        }
        queue.sync {
            try? outputOwnership.detachSharedAudioOutput(streamIdentity: streamIdentity)
            refreshStatisticsNotes()
            statisticsHandler(statistics)
        }
        output.emitStopped()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = sampleBuffer.imageBuffer,
              compressionSession != nil else {
            return
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
        let sourceMachTime = mach_absolute_time()
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
            duration: duration
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
        guard let compressionSession else {
            reportTerminalContractFailure(.invalidFormat("VideoToolbox compression session is unavailable"), sourceDisplayTime: source.displayTime)
            return false
        }

        guard inflightFrameCount < maximumPendingFrameCount else {
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
            return false
        }

        sourceColorContractStatus = "verified"
        let context = UnsafeMutablePointer<LumenEncodedFrameContext>.allocate(capacity: 1)
        context.initialize(to: .init(
            sequenceNumber: sequenceNumber,
            displayTime: source.displayTime,
            submissionMachTime: mach_absolute_time(),
            requiresBootstrapAcknowledgement: forceKeyFrame
        ))

        let properties = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: source.imageBuffer,
            presentationTimeStamp: source.presentationTime,
            duration: source.duration,
            frameProperties: properties,
            sourceFrameRefcon: context,
            infoFlagsOut: nil
        )
        if status != noErr {
            context.deinitialize(count: 1)
            context.deallocate()
            statistics.processingFailureCount &+= 1
            statistics.lastErrorDescription = "VTCompressionSessionEncodeFrame failed with OSStatus \(status)"
            statisticsHandler(statistics)
            eventHandler(.init(kind: .failed, message: statistics.lastErrorDescription, stopStatus: status))
            return false
        } else {
            inflightFrameCount += 1
            statistics.submittedFrameCount &+= 1
            statistics.maximumInflightFrameCount = max(statistics.maximumInflightFrameCount, inflightFrameCount)
            refreshStatisticsNotesIfNeeded()
            return true
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
        guard let compressionSession else { return }
        let status = VTSessionSetProperty(compressionSession, key: key, value: value)
        guard status == noErr else {
            throw LumenScreenCaptureError.compressionPropertyFailed(String(describing: key), status)
        }
    }

    private func invalidateCompressionSession() {
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
        return [
            "captureBackend=screen-capture-kit",
            "screenCaptureOutputRegistrationStage=\(outputOwnership.stage.rawValue)",
            "screenCaptureSystemAudioPreconfigured=\(systemAudioPreparation != nil)",
            "screenCaptureDisplayAdmissionMode=\(displayAdmissionMode.rawValue)",
            "screenCaptureDisplayAdmissionMilliseconds=\(displayAdmissionDurationMilliseconds)",
            "screenCaptureStreamStartMilliseconds=\(streamStartDurationMilliseconds)",
            "screenCaptureOwnedSampleCount=\(outputOwnership.screenSampleCount)",
            "sourceCaptureSampleCount=\(statistics.sourceFrameCount)",
            "sourceApproxFrameRate=\(sourceApproxFrameRate)",
            "videoToolboxTargetFrameRateHint=\(configuration.effectiveTargetFrameRate)",
            "videoToolboxEncoderInputPixelFormat=\(capturePixelFormat)",
            "videoToolboxSourcePixelFormat=\(capturePixelFormat)",
            "sourceColorContract=\(sourceColorContractStatus)",
            "videoToolboxStagingMode=direct-cvpixelbuffer",
            "videoToolboxConversionCount=0",
            "videoToolboxProfile=\(encodingPlan?.profile ?? "unresolved")",
            "videoToolboxHardwareRequired=true",
            "videoToolboxAllowOpenGOP=\(statistics.exactCaptureAudit.allowOpenGOP.map { String($0) } ?? "n/a")",
            "videoToolboxConfiguredSourceFrameCount=\(width)x\(height)",
            "videoToolboxSubmittedFrameCount=\(statistics.submittedFrameCount)",
            "videoToolboxPendingAdmissionDropCount=\(statistics.pendingAdmissionDropCount)",
            "videoToolboxBootstrapGateOpen=\(videoBootstrapAdmission.isOpen)",
            "videoToolboxBootstrapPendingSource=\(pendingVideoBootstrapSource != nil)",
            "videoToolboxMaxInflightStagingSlots=\(statistics.maximumInflightFrameCount)",
            "videoToolboxOutputApproxFrameRate=\(outputApproxFrameRate)"
        ]
    }

    private static func identity(of stream: SCStream) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(stream).toOpaque())
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
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
        contextPointer: UnsafeMutableRawPointer?
    ) {
        let sampleBufferAddress = sampleBuffer.map {
            UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())
        }
        let contextAddress = contextPointer.map(UInt.init(bitPattern:))
        queue.async { [weak self] in
            let retainedSampleBuffer = sampleBufferAddress.flatMap { address -> CMSampleBuffer? in
                guard let pointer = UnsafeRawPointer(bitPattern: address) else {
                    return nil
                }
                return Unmanaged<CMSampleBuffer>.fromOpaque(pointer).takeRetainedValue()
            }
            let retainedContextPointer = contextAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
            guard let self else {
                if let retainedContextPointer {
                    let typedContext = retainedContextPointer.assumingMemoryBound(
                        to: LumenEncodedFrameContext.self
                    )
                    typedContext.deinitialize(count: 1)
                    typedContext.deallocate()
                }
                return
            }
            self.didEncode(
                status: status,
                infoFlags: infoFlags,
                sampleBuffer: retainedSampleBuffer,
                contextPointer: retainedContextPointer
            )
        }
    }

    fileprivate func didEncode(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        contextPointer: UnsafeMutableRawPointer?
    ) {
        guard let contextPointer else { return }
        let typedContext = contextPointer.assumingMemoryBound(to: LumenEncodedFrameContext.self)
        let context = typedContext.move()
        typedContext.deallocate()
        inflightFrameCount = max(inflightFrameCount - 1, 0)

        guard status == noErr,
              !infoFlags.contains(.frameDropped),
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            if context.requiresBootstrapAcknowledgement {
                videoBootstrapAdmission.cancelBootstrapSubmission()
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
            reportTerminalContractFailure(
                .requiredKeyFrameNotProduced,
                sourceDisplayTime: context.displayTime
            )
            return
        }
        let hdr = configuration.encodedColorConfiguration
        let formatExtensions = sampleBuffer.formatDescription.flatMap {
            CMFormatDescriptionGetExtensions($0) as? [String: Any]
        }
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
    }
}

private func lumenScreenCaptureCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else { return }
    Unmanaged<LumenScreenCaptureVideoRuntime>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
        .enqueueCompressionOutput(
            status: status,
            infoFlags: infoFlags,
            sampleBuffer: sampleBuffer,
            contextPointer: sourceFrameRefCon
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

private enum LumenMachTime {
    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom != 0, end >= start else { return 0 }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    static func ticks(for time: CMTime) -> UInt64? {
        guard time.isValid, time.seconds.isFinite, time.seconds >= 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.numer != 0 else { return nil }
        let nanoseconds = time.seconds * 1_000_000_000
        return UInt64(nanoseconds * Double(timebase.denom) / Double(timebase.numer))
    }
}

enum LumenScreenCaptureError: Error, LocalizedError {
    case displayUnavailable(UInt32)
    case displayOwnershipLost(UInt32)
    case captureNotRunning
    case outputOwnershipLost
    case systemAudioWasNotPreconfigured
    case compressionSessionCreationFailed(OSStatus)
    case compressionSessionPreparationFailed(OSStatus)
    case compressionPropertyFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable(let displayID): return "ScreenCaptureKit display \(displayID) is unavailable."
        case .displayOwnershipLost(let displayID): return "Retained virtual display \(displayID) was released before ScreenCaptureKit became ready."
        case .captureNotRunning: return "ScreenCaptureKit video stream is not running."
        case .outputOwnershipLost: return "ScreenCaptureKit delivered a sample from a stream that no longer owns the registered video output."
        case .systemAudioWasNotPreconfigured: return "System audio must be configured before the shared ScreenCaptureKit video stream starts."
        case .compressionSessionCreationFailed(let status): return "Unable to create VideoToolbox compression session (OSStatus \(status))."
        case .compressionSessionPreparationFailed(let status): return "Unable to prepare VideoToolbox compression session (OSStatus \(status))."
        case .compressionPropertyFailed(let key, let status): return "Unable to set VideoToolbox property \(key) (OSStatus \(status))."
        }
    }
}

actor LumenEncodedCaptureSession {
    let configuration: LumenMacCaptureConfiguration
    private let preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?
    private let preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks?
    private var runtime: LumenScreenCaptureVideoRuntime?
    private var statistics = LumenEncodedCaptureSessionStatistics()
    private var callbacks: LumenEncodedCaptureCallbacks?
    private var runtimeGeneration: UInt64 = 0
    private var isStopping = false
    private let maximumAutomaticRestartCount: UInt64 = 2

    init(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration? = nil,
        preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks? = nil
    ) {
        self.configuration = configuration
        self.preconfiguredSystemAudio = preconfiguredSystemAudio
        self.preconfiguredSystemAudioCallbacks = preconfiguredSystemAudioCallbacks
    }

    func start(callbacks: LumenEncodedCaptureCallbacks) async throws {
        self.callbacks = callbacks
        isStopping = false
        runtimeGeneration &+= 1
        try await startRuntime(callbacks: callbacks, generation: runtimeGeneration)
    }

    func stop() async {
        isStopping = true
        runtimeGeneration &+= 1
        callbacks = nil
        guard let runtime else { return }
        self.runtime = nil
        await runtime.stop()
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
        guard let runtime else {
            throw LumenScreenCaptureError.captureNotRunning
        }
        try await runtime.attachSystemAudio(
            configuration: configuration,
            callbacks: callbacks
        )
    }

    func detachSystemAudio() async {
        await runtime?.detachSystemAudio()
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
        generation: UInt64
    ) async throws {
        let owner = self
        let runtime = try LumenScreenCaptureVideoRuntime(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio,
            preconfiguredSystemAudioCallbacks: preconfiguredSystemAudioCallbacks,
            callbacks: callbacks,
            statisticsHandler: { statistics in
                Task { await owner.updateStatistics(statistics) }
            },
            terminationHandler: { error in
                Task { await owner.handleUnexpectedTermination(generation: generation, error: error) }
            }
        )
        self.runtime = runtime
        do {
            try await runtime.start()
        } catch {
            if self.runtime === runtime {
                self.runtime = nil
            }
            throw error
        }
    }

    private func handleUnexpectedTermination(generation: UInt64, error: Error) async {
        guard !isStopping,
              generation == runtimeGeneration,
              let callbacks else {
            return
        }

        let failedRuntime = runtime
        runtime = nil
        await failedRuntime?.stop()

        if error is LumenExactCaptureError {
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
        guard !isStopping, generation == runtimeGeneration else { return }
        do {
            try await startRuntime(callbacks: callbacks, generation: generation)
        } catch {
            await handleUnexpectedTermination(generation: generation, error: error)
        }
    }
}
