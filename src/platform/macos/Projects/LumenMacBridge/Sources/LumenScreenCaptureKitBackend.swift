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
    let isHDRSignaled: Bool
    let hdrValidationReport: LumenHDRValidationReport

    init(
        sampleBuffer: CMSampleBuffer,
        codec: LumenCaptureCodec,
        sourceSequenceNumber: UInt64,
        sourceDisplayTime: UInt64,
        outputCallbackLatencyMilliseconds: Double?,
        isKeyFrame: Bool,
        isHDRSignaled: Bool,
        hdrValidationReport: LumenHDRValidationReport
    ) {
        sampleBufferHandle = LumenSampleBufferHandle(retaining: sampleBuffer)
        self.codec = codec
        self.sourceSequenceNumber = sourceSequenceNumber
        self.sourceDisplayTime = sourceDisplayTime
        self.outputCallbackLatencyMilliseconds = outputCallbackLatencyMilliseconds
        self.isKeyFrame = isKeyFrame
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
}

private struct LumenEncodedFrameContext {
    let sequenceNumber: UInt64
    let displayTime: UInt64
    let submissionMachTime: UInt64
}

enum LumenCodecAckVideoAdmissionDecision: Equatable, Sendable {
    case submitInitialKeyFrame
    case coalesceUntilAcknowledged
    case submit
}

struct LumenCodecAckVideoAdmissionGate: Equatable, Sendable {
    private(set) var isAwaitingAcknowledgement = false
    private(set) var isOpen = false

    mutating func admitSourceFrame() -> LumenCodecAckVideoAdmissionDecision {
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
}

private struct LumenPendingCodecAckVideoSource {
    let imageBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let displayTime: UInt64
    let duration: CMTime
}

enum LumenScreenCaptureDisplayResolver {
    static func resolve<Value: Sendable>(
        displayID: UInt32,
        attempts: Int,
        delayNanoseconds: UInt64,
        isRetained: @escaping @Sendable () async -> Bool,
        lookup: @escaping @Sendable () async throws -> Value?
    ) async throws -> Value {
        for attempt in 0..<max(attempts, 1) {
            guard await isRetained() else {
                throw LumenScreenCaptureError.displayOwnershipLost(displayID)
            }
            if let value = try await lookup() {
                return value
            }
            if attempt + 1 < max(attempts, 1), delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        throw LumenScreenCaptureError.displayUnavailable(displayID)
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
        isRetained: @escaping @Sendable () async -> Bool,
        enumerateShareableContent: @escaping @Sendable () async throws -> Value
    ) async throws -> LumenScreenCaptureDisplayAdmissionResult<Value> {
        let retainedAtStart = await isRetained()
        let value = try await enumerateShareableContent()
        if retainedAtStart {
            guard await isRetained() else {
                throw LumenScreenCaptureError.displayOwnershipLost(displayID)
            }
            return .init(value: value, mode: .retainedShareableContent)
        }
        return .init(
            value: value,
            mode: .shareableContentEnumeration
        )
    }
}

struct LumenScreenCaptureDisplayHandle: @unchecked Sendable {
    let value: SCDisplay
}

actor LumenSingleFlightDisplayLookup<Value: Sendable> {
    private struct Entry {
        let ownerToken: UInt
        let task: Task<Value?, Error>
    }

    private var entries: [UInt32: Entry] = [:]

    func begin(
        displayID: UInt32,
        ownerToken: UInt,
        lookup: @escaping @Sendable () async throws -> Value?
    ) {
        if entries[displayID]?.ownerToken == ownerToken {
            return
        }
        entries.removeValue(forKey: displayID)?.task.cancel()
        entries[displayID] = Entry(
            ownerToken: ownerToken,
            task: Task { try await lookup() }
        )
    }

    func resolve(displayID: UInt32, ownerToken: UInt) async throws -> Value? {
        guard let entry = entries[displayID], entry.ownerToken == ownerToken else {
            return nil
        }
        defer {
            if entries[displayID]?.ownerToken == ownerToken {
                entries.removeValue(forKey: displayID)
            }
        }
        return try await entry.task.value
    }

    func discard(displayID: UInt32) {
        entries.removeValue(forKey: displayID)?.task.cancel()
    }
}

enum LumenScreenCaptureDisplayPrefetch {
    private static let lookups = LumenSingleFlightDisplayLookup<LumenScreenCaptureDisplayHandle>()
    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )

    static func begin(displayID: UInt32) async {
        guard let ownerToken = retainedOwnerToken(displayID: displayID) else {
            return
        }
        logger.notice(
            "stage=display-prefetch-begin display-id=\(displayID, privacy: .public) owner-token=\(ownerToken, privacy: .public)"
        )
        await lookups.begin(displayID: displayID, ownerToken: ownerToken) {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return content.displays.first(where: {
                UInt32($0.displayID) == displayID
            }).map(LumenScreenCaptureDisplayHandle.init(value:))
        }
    }

    static func resolve(displayID: UInt32) async throws -> LumenScreenCaptureDisplayHandle? {
        guard let ownerToken = retainedOwnerToken(displayID: displayID) else {
            return nil
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await lookups.resolve(displayID: displayID, ownerToken: ownerToken)
        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - start
        ) / 1_000_000
        logger.notice(
            "stage=display-prefetch-resolved display-id=\(displayID, privacy: .public) owner-token=\(ownerToken, privacy: .public) found=\(result != nil, privacy: .public) wait-ms=\(elapsedMilliseconds, privacy: .public)"
        )
        return result
    }

    static func discard(displayID: UInt32) async {
        await lookups.discard(displayID: displayID)
    }

    private static func retainedOwnerToken(displayID: UInt32) -> UInt? {
        LumenMacVirtualDisplay.registeredDisplay(forDisplayID: displayID).map {
            UInt(bitPattern: ObjectIdentifier($0))
        }
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
    private var forceKeyFrame = false
    private var codecAckAdmission = LumenCodecAckVideoAdmissionGate()
    private var pendingCodecAckSource: LumenPendingCodecAckVideoSource?
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
            if let prefetched = try await LumenScreenCaptureDisplayPrefetch.resolve(
                displayID: displayID
            ) {
                admission = .init(value: prefetched, mode: .prefetchedShareableContent)
            } else {
                admission = try await LumenScreenCaptureDisplayAdmission.resolve(
                    displayID: displayID,
                    isRetained: {
                        LumenMacVirtualDisplay.registeredDisplay(forDisplayID: displayID) != nil
                    },
                    enumerateShareableContent: {
                        let retainedIdentity = LumenMacVirtualDisplay.registeredDisplay(
                            forDisplayID: displayID
                        ).map(ObjectIdentifier.init)
                        return try await LumenScreenCaptureDisplayResolver.resolve(
                            displayID: displayID,
                            attempts: retainedIdentity == nil ? 1 : 3,
                            delayNanoseconds: 250_000_000,
                            isRetained: {
                                guard let retainedIdentity else { return true }
                                guard let current = LumenMacVirtualDisplay.registeredDisplay(
                                    forDisplayID: displayID
                                ) else {
                                    return false
                                }
                                return ObjectIdentifier(current) == retainedIdentity
                            },
                            lookup: {
                                let content = try await SCShareableContent.excludingDesktopWindows(
                                    false,
                                    onScreenWindowsOnly: true
                                )
                                guard let target = content.displays.first(where: {
                                    UInt32($0.displayID) == displayID
                                }) else {
                                    return nil
                                }
                                return LumenScreenCaptureDisplayHandle(value: target)
                            }
                        )
                    }
                )
            }
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
            self?.forceKeyFrame = true
        }
    }

    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self,
                      self.codecAckAdmission.acknowledgeConfiguration() else {
                    continuation.resume(returning: false)
                    return
                }
                let pendingSource = self.pendingCodecAckSource
                self.pendingCodecAckSource = nil
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
              let compressionSession else {
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

        let source = LumenPendingCodecAckVideoSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            displayTime: displayTime,
            duration: duration
        )
        switch codecAckAdmission.admitSourceFrame() {
        case .submitInitialKeyFrame:
            submitSource(source, forceKeyFrame: true)
        case .coalesceUntilAcknowledged:
            pendingCodecAckSource = source
            statistics.pendingAdmissionDropCount &+= 1
            refreshStatisticsNotesIfNeeded()
        case .submit:
            let forceKeyFrame = forceKeyFrame
            self.forceKeyFrame = false
            submitSource(source, forceKeyFrame: forceKeyFrame)
        }
    }

    private func submitSource(
        _ source: LumenPendingCodecAckVideoSource,
        forceKeyFrame: Bool
    ) {
        guard let compressionSession else {
            reportTerminalContractFailure(.invalidFormat("VideoToolbox compression session is unavailable"), sourceDisplayTime: source.displayTime)
            return
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
            return
        }

        sourceColorContractStatus = "verified"
        let context = UnsafeMutablePointer<LumenEncodedFrameContext>.allocate(capacity: 1)
        context.initialize(to: .init(
            sequenceNumber: sequenceNumber,
            displayTime: source.displayTime,
            submissionMachTime: mach_absolute_time()
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
        } else {
            inflightFrameCount += 1
            statistics.submittedFrameCount &+= 1
            statistics.maximumInflightFrameCount = max(statistics.maximumInflightFrameCount, inflightFrameCount)
            refreshStatisticsNotesIfNeeded()
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
            "videoToolboxConfiguredSourceFrameCount=\(width)x\(height)",
            "videoToolboxSubmittedFrameCount=\(statistics.submittedFrameCount)",
            "videoToolboxPendingAdmissionDropCount=\(statistics.pendingAdmissionDropCount)",
            "videoToolboxCodecAckGateOpen=\(codecAckAdmission.isOpen)",
            "videoToolboxCodecAckPendingSource=\(pendingCodecAckSource != nil)",
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
