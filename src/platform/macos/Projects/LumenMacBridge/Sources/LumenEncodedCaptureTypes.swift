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

enum LumenVideoMetadataInsertionMode: Sendable {
    case automatic
}

struct LumenHDRValidationReport: Equatable, Sendable {
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let hasHDRDisplayMetadata: Bool
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
    var completeSourceFrameCount: UInt64 = 0
    var incompleteSourceFrameCount: UInt64 = 0
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

struct LumenCapturePipelineUtilization: Equatable, Sendable {
    let videoToolboxAdmissionPercent: Double?
    let videoToolboxOutputPercent: Double?

    init(statistics: LumenEncodedCaptureSessionStatistics) {
        videoToolboxAdmissionPercent = Self.percent(
            numerator: statistics.submittedFrameCount,
            denominator: statistics.completeSourceFrameCount
        )
        videoToolboxOutputPercent = Self.percent(
            numerator: statistics.emittedFrameCount,
            denominator: statistics.submittedFrameCount
        )
    }

    private static func percent(
        numerator: UInt64,
        denominator: UInt64
    ) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) * 100 / Double(denominator)
    }
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
