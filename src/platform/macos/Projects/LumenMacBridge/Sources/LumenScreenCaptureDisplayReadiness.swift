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

struct LumenCaptureDisplayReadinessSnapshot: Equatable, Sendable {
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
        guard isOnline else {
            return false
        }
        switch authority {
        case .retained:
            if hasCurrentMode, pixelWidth > 0, pixelHeight > 0 {
                return true
            }
            guard isActive else {
                return false
            }
            if hasCurrentMode {
                return true
            }
            return (pixelWidth > 0 && pixelHeight > 0) ||
                (configuredPixelWidth > 0 && configuredPixelHeight > 0)
        case .exactExternal:
            return isActive && hasCurrentMode
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
        maximumOutstandingQueries: 1
    )

    static let reconfiguration = Self(
        // An active session must reject and roll back promptly instead of
        // freezing video behind the cold-start publication allowance.
        overallDeadlineNanoseconds: 3_000_000_000,
        queryTimeoutNanoseconds: 3_000_000_000,
        retryDelayNanoseconds: 50_000_000,
        maximumOutstandingQueries: 1
    )
}

enum LumenScreenCaptureDisplayAuthority: Equatable, Sendable {
    case retained(ownerToken: UInt)
    case exactExternal
}

enum LumenScreenCaptureTimedQueryOutcome<Value: Sendable>: @unchecked Sendable {
    case value(Value?, completedAtNanoseconds: UInt64)
    case failure(any Error, completedAtNanoseconds: UInt64)
    case timedOut

    var completedAtNanoseconds: UInt64? {
        switch self {
        case .value(_, let completedAtNanoseconds),
             .failure(_, let completedAtNanoseconds):
            completedAtNanoseconds
        case .timedOut:
            nil
        }
    }
}

struct LumenScreenCaptureQueryCompletion<Value: Sendable>: Sendable {
    let value: Value?
    let completedAtNanoseconds: UInt64
}

actor LumenScreenCaptureTimedQueryRace<Value: Sendable> {
    private let generation: UInt64
    private var outcome: LumenScreenCaptureTimedQueryOutcome<Value>?
    private var continuation: CheckedContinuation<LumenScreenCaptureTimedQueryOutcome<Value>, Never>?

    init(generation: UInt64) {
        self.generation = generation
    }

    @discardableResult
    func finish(
        generation: UInt64,
        outcome: LumenScreenCaptureTimedQueryOutcome<Value>
    ) -> Bool {
        guard generation == self.generation, self.outcome == nil else {
            return false
        }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
        return true
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
