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
    let canAcceptFrame: @Sendable () -> Bool

    init(
        frameHandler: @escaping @Sendable (LumenEncodedFrame) -> Void,
        eventHandler: (@Sendable (LumenEncodedCaptureSessionEvent) -> Void)? = nil,
        canAcceptFrame: @escaping @Sendable () -> Bool = { true }
    ) {
        self.frameHandler = frameHandler
        self.eventHandler = eventHandler
        self.canAcceptFrame = canAcceptFrame
    }
}

public struct LumenEncodedCaptureSessionStatistics: Equatable, Sendable {
    var emittedFrameCount: UInt64 = 0
    var encodedByteCount: UInt64 = 0
    var droppedFrameCount: UInt64 = 0
    var processingFailureCount: UInt64 = 0
    var automaticRestartCount: UInt64 = 0
    var sourceFrameCount: UInt64 = 0
    var completeSourceFrameCount: UInt64 = 0
    var incompleteSourceFrameCount: UInt64 = 0
    var submittedFrameCount: UInt64 = 0
    var pendingAdmissionDropCount: UInt64 = 0
    var intentionalFrameCadenceDropCount: UInt64 = 0
    var maximumInflightFrameCount: Int = 0
    var lastErrorDescription: String?
    var isRunning = false
    var minOutputCallbackLatencyMilliseconds: Double?
    var maxOutputCallbackLatencyMilliseconds: Double?
    var adaptiveTargetFrameRate: Int?
    var appliedVideoBitRateKbps: Int?
    var estimatedOutputBitrateKbps: Double?
    var notes: [String] = []
    var exactCaptureAudit = LumenExactCaptureAuditSnapshot()
}

/// Decides when high-rate encoder diagnostics need to cross the
/// runtime/session boundary. Successful outputs and frame-drop updates are
/// allowed to coalesce for a short interval or bounded event window;
/// lifecycle, terminal error, and control publications are never delayed.
struct LumenEncodedCaptureStatisticsPublicationPolicy: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        static let `default` = Self(
            minimumIntervalNanoseconds: 250_000_000,
            maximumHighRateUpdates: 120
        )

        let minimumIntervalNanoseconds: UInt64
        let maximumHighRateUpdates: UInt64

        init(
            minimumIntervalNanoseconds: UInt64 = 250_000_000,
            maximumHighRateUpdates: UInt64 = 120
        ) {
            self.minimumIntervalNanoseconds = max(
                minimumIntervalNanoseconds,
                1
            )
            self.maximumHighRateUpdates = max(
                maximumHighRateUpdates,
                1
            )
        }
    }

    enum PublicationReason: Equatable, Sendable {
        case highRateUpdate
        case immediate
        case forced
        case terminal
    }

    private let configuration: Configuration
    private var highRateUpdatesSincePublication: UInt64 = 0
    private var lastPublicationUptimeNanoseconds: UInt64?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Returns true when the caller should publish the current statistics.
    /// The clock is supplied by the caller so this policy remains deterministic
    /// in tests and does not own a timer or task.
    mutating func shouldPublish(
        reason: PublicationReason,
        atUptimeNanoseconds uptimeNanoseconds: UInt64
    ) -> Bool {
        switch reason {
        case .highRateUpdate:
            highRateUpdatesSincePublication &+= 1
            guard let lastPublicationUptimeNanoseconds else {
                return recordPublication(at: uptimeNanoseconds)
            }
            let elapsedNanoseconds =
                uptimeNanoseconds >= lastPublicationUptimeNanoseconds
                ? uptimeNanoseconds - lastPublicationUptimeNanoseconds
                : 0
            guard highRateUpdatesSincePublication
                    < configuration.maximumHighRateUpdates,
                  elapsedNanoseconds < configuration.minimumIntervalNanoseconds else {
                return recordPublication(at: uptimeNanoseconds)
            }
            return false
        case .immediate, .forced, .terminal:
            return recordPublication(at: uptimeNanoseconds)
        }
    }

    private mutating func recordPublication(at uptimeNanoseconds: UInt64) -> Bool {
        highRateUpdatesSincePublication = 0
        lastPublicationUptimeNanoseconds = uptimeNanoseconds
        return true
    }
}

struct LumenEncodedCaptureStatisticsNotesRefreshGate: Equatable, Sendable {
    private var lastSourceFrameCount: UInt64?

    mutating func shouldRefresh(sourceFrameCount: UInt64) -> Bool {
        guard sourceFrameCount > 0,
              sourceFrameCount == 1 || sourceFrameCount % 120 == 0,
              lastSourceFrameCount != sourceFrameCount else {
            return false
        }
        lastSourceFrameCount = sourceFrameCount
        return true
    }
}

struct LumenEncodedBitrateTelemetry: Equatable, Sendable {
    private static let reportingIntervalNanoseconds: UInt64 = 1_000_000_000

    private(set) var totalEncodedBytes: UInt64 = 0
    private(set) var latestWindowBitrateKbps: Double?
    private var windowStartUptimeNanoseconds: UInt64?
    private var windowEncodedBytes: UInt64 = 0

    mutating func observe(
        encodedByteCount: Int,
        atUptimeNanoseconds uptimeNanoseconds: UInt64
    ) {
        guard encodedByteCount > 0,
              let bytes = UInt64(exactly: encodedByteCount) else {
            return
        }
        totalEncodedBytes = saturatingAdd(totalEncodedBytes, bytes)
        windowEncodedBytes = saturatingAdd(windowEncodedBytes, bytes)
        guard let windowStartUptimeNanoseconds else {
            self.windowStartUptimeNanoseconds = uptimeNanoseconds
            return
        }
        guard uptimeNanoseconds > windowStartUptimeNanoseconds else {
            return
        }
        let elapsedNanoseconds =
            uptimeNanoseconds - windowStartUptimeNanoseconds
        guard elapsedNanoseconds >= Self.reportingIntervalNanoseconds else {
            return
        }
        latestWindowBitrateKbps =
            Double(windowEncodedBytes) * 8_000_000
                / Double(elapsedNanoseconds)
        self.windowStartUptimeNanoseconds = uptimeNanoseconds
        windowEncodedBytes = 0
    }

    private func saturatingAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? .max : result.partialValue
    }
}

struct LumenCaptureCadenceTelemetry: Equatable, Sendable {
    private static let reportingIntervalNanoseconds: UInt64 = 1_000_000_000

    private(set) var windowDurationMilliseconds: Double?
    private(set) var sourceCallbacksPerSecond: Double?
    private(set) var videoToolboxSubmissionsPerSecond: Double?
    private(set) var videoToolboxOutputsPerSecond: Double?
    private(set) var pendingAdmissionDropsPerSecond: Double?

    private var windowStartUptimeNanoseconds: UInt64?
    private var sourceFrameCount: UInt64 = 0
    private var submittedFrameCount: UInt64 = 0
    private var emittedFrameCount: UInt64 = 0
    private var pendingAdmissionDropCount: UInt64 = 0

    mutating func observe(
        statistics: LumenEncodedCaptureSessionStatistics,
        atUptimeNanoseconds uptimeNanoseconds: UInt64
    ) -> Bool {
        guard let windowStartUptimeNanoseconds,
              uptimeNanoseconds >= windowStartUptimeNanoseconds else {
            beginWindow(
                statistics: statistics,
                atUptimeNanoseconds: uptimeNanoseconds
            )
            return false
        }

        let elapsedNanoseconds =
            uptimeNanoseconds - windowStartUptimeNanoseconds
        guard elapsedNanoseconds >= Self.reportingIntervalNanoseconds else {
            return false
        }

        windowDurationMilliseconds = Double(elapsedNanoseconds) / 1_000_000
        sourceCallbacksPerSecond = rate(
            current: statistics.sourceFrameCount,
            previous: sourceFrameCount,
            elapsedNanoseconds: elapsedNanoseconds
        )
        videoToolboxSubmissionsPerSecond = rate(
            current: statistics.submittedFrameCount,
            previous: submittedFrameCount,
            elapsedNanoseconds: elapsedNanoseconds
        )
        videoToolboxOutputsPerSecond = rate(
            current: statistics.emittedFrameCount,
            previous: emittedFrameCount,
            elapsedNanoseconds: elapsedNanoseconds
        )
        pendingAdmissionDropsPerSecond = rate(
            current: statistics.pendingAdmissionDropCount,
            previous: pendingAdmissionDropCount,
            elapsedNanoseconds: elapsedNanoseconds
        )
        beginWindow(
            statistics: statistics,
            atUptimeNanoseconds: uptimeNanoseconds
        )
        return true
    }

    private mutating func beginWindow(
        statistics: LumenEncodedCaptureSessionStatistics,
        atUptimeNanoseconds uptimeNanoseconds: UInt64
    ) {
        windowStartUptimeNanoseconds = uptimeNanoseconds
        sourceFrameCount = statistics.sourceFrameCount
        submittedFrameCount = statistics.submittedFrameCount
        emittedFrameCount = statistics.emittedFrameCount
        pendingAdmissionDropCount = statistics.pendingAdmissionDropCount
    }

    private func rate(
        current: UInt64,
        previous: UInt64,
        elapsedNanoseconds: UInt64
    ) -> Double {
        let delta = current >= previous ? current - previous : 0
        return Double(delta) * 1_000_000_000 / Double(elapsedNanoseconds)
    }
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
    private(set) var latestMilliseconds: Double?

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
        latestMilliseconds = milliseconds
    }
}

struct LumenCaptureIngressTimings: Equatable, Sendable {
    private var previousDisplayMachTime: UInt64?
    private var previousCallbackMachTime: UInt64?
    private(set) var displayInterval = LumenCaptureStageTimingAccumulator()
    private(set) var displayToCallback = LumenCaptureStageTimingAccumulator()
    private(set) var callbackInterval = LumenCaptureStageTimingAccumulator()
    private(set) var scheduledDisplayLead = LumenCaptureStageTimingAccumulator()

    mutating func observe(
        displayedMachTime: UInt64?,
        callbackMachTime: UInt64
    ) {
        if let previousCallbackMachTime, callbackMachTime > previousCallbackMachTime {
            callbackInterval.observe(LumenMachTime.milliseconds(
                from: previousCallbackMachTime, to: callbackMachTime
            ))
        }
        previousCallbackMachTime = callbackMachTime
        guard let displayedMachTime else { return }
        // CGDisplayStream reports when the frame was TO BE displayed, which
        // can legitimately be after callback entry. Keep its cadence sample;
        // report display lead separately instead of inventing negative latency.
        if displayedMachTime <= callbackMachTime {
            displayToCallback.observe(LumenMachTime.milliseconds(
                from: displayedMachTime, to: callbackMachTime
            ))
        } else {
            scheduledDisplayLead.observe(LumenMachTime.milliseconds(
                from: callbackMachTime, to: displayedMachTime
            ))
        }
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
        notes.append(contentsOf: lumenCaptureTimingNotes(
            prefix: "sourceCallbackInterval", timing: callbackInterval
        ))
        notes.append(contentsOf: lumenCaptureTimingNotes(
            prefix: "sourceScheduledDisplayLead", timing: scheduledDisplayLead
        ))
        return notes
    }
}

struct LumenCaptureOutputOccupancyTimings: Equatable, Sendable {
    private var previousOutput: (time: UInt64, epoch: UInt64)?
    private(set) var interval = LumenCaptureStageTimingAccumulator()
    private(set) var outputs: UInt64 = 0
    private(set) var singleFlightOutputs: UInt64 = 0

    mutating func observe(inflightCount: Int, callbackMachTime: UInt64, epoch: UInt64) {
        outputs &+= 1
        if inflightCount == 1 { singleFlightOutputs &+= 1 }
        if let previousOutput, previousOutput.epoch == epoch,
           callbackMachTime > previousOutput.time {
            interval.observe(LumenMachTime.milliseconds(
                from: previousOutput.time, to: callbackMachTime
            ))
        }
        previousOutput = (callbackMachTime, epoch)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.previousOutput?.time == rhs.previousOutput?.time &&
        lhs.previousOutput?.epoch == rhs.previousOutput?.epoch &&
        lhs.interval == rhs.interval && lhs.outputs == rhs.outputs &&
        lhs.singleFlightOutputs == rhs.singleFlightOutputs
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
