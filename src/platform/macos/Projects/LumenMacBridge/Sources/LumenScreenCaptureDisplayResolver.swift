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

private actor LumenScreenCaptureCompletedQueryStore<Value: Sendable> {
    struct Entry: @unchecked Sendable {
        let generation: UInt64
        let outcome: LumenScreenCaptureTimedQueryOutcome<Value>
    }

    private var entries: [Entry] = []

    func append(
        generation: UInt64,
        outcome: LumenScreenCaptureTimedQueryOutcome<Value>
    ) {
        entries.append(Entry(generation: generation, outcome: outcome))
    }

    func takeFirst() -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }
}

enum LumenScreenCaptureDisplayResolver {
    typealias MonotonicNow = @Sendable () async -> UInt64
    typealias MonotonicSleep = @Sendable (UInt64) async -> Void

    struct Environment<Value: Sendable> {
        let now: MonotonicNow
        let sleepUntil: MonotonicSleep
        let readiness:
            @Sendable () async -> LumenCaptureDisplayReadinessSnapshot
        let lookup:
            @Sendable (_ generation: UInt64) async throws -> Value?
    }

    private struct AcceptanceContext<Value: Sendable> {
        let displayID: UInt32
        let authority: LumenScreenCaptureDisplayAuthority
        let overallDeadline: UInt64
        let environment: Environment<Value>
    }

    private struct ResolutionContext<Value: Sendable> {
        let displayID: UInt32
        let authority: LumenScreenCaptureDisplayAuthority
        let timing: LumenScreenCaptureDisplayReadinessTiming
        let queryBudget: LumenScreenCaptureQueryBudget
        let overallDeadline: UInt64
        let environment: Environment<Value>
        let completedQueries: LumenScreenCaptureCompletedQueryStore<Value>
    }

    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )

    static func resolve<Value: Sendable>(
        displayID: UInt32,
        authority: LumenScreenCaptureDisplayAuthority,
        timing: LumenScreenCaptureDisplayReadinessTiming,
        queryBudget: LumenScreenCaptureQueryBudget,
        environment: Environment<Value>
    ) async throws -> Value {
        let startedAt = await environment.now()
        let overallDeadline = addingClamped(
            startedAt,
            timing.overallDeadlineNanoseconds
        )
        let context = ResolutionContext(
            displayID: displayID,
            authority: authority,
            timing: timing,
            queryBudget: queryBudget,
            overallDeadline: overallDeadline,
            environment: environment,
            completedQueries: LumenScreenCaptureCompletedQueryStore()
        )
        while true {
            if let value = try await resolveNext(context) {
                return value
            }
        }
    }

    private static func resolveNext<Value: Sendable>(
        _ context: ResolutionContext<Value>
    ) async throws -> Value? {
        try Task.checkCancellation()
        let currentTime = try await timeWithinDeadline(
            displayID: context.displayID,
            deadline: context.overallDeadline,
            environment: context.environment
        )
        let acceptanceContext = AcceptanceContext(
            displayID: context.displayID,
            authority: context.authority,
            overallDeadline: context.overallDeadline,
            environment: context.environment
        )
        while let completed = await context.completedQueries.takeFirst() {
            logCompletedQueryAdopted(
                displayID: context.displayID,
                generation: completed.generation
            )
            if let value = try await acceptedValue(
                completed.outcome,
                generation: completed.generation,
                context: acceptanceContext
            ) {
                return value
            }
        }
        guard try await modeIsReady(
            displayID: context.displayID,
            authority: context.authority,
            environment: context.environment
        ), let generation = await context.queryBudget.begin() else {
            try await waitForRetry(
                context,
                currentTime: currentTime
            )
            return nil
        }
        let queryDeadline = min(
            addingClamped(
                currentTime,
                context.timing.queryTimeoutNanoseconds
            ),
            context.overallDeadline
        )
        logQueryStart(displayID: context.displayID, generation: generation)
        let outcome = await performTimedQuery(
            displayID: context.displayID,
            generation: generation,
            deadline: queryDeadline,
            overallDeadline: context.overallDeadline,
            queryBudget: context.queryBudget,
            environment: context.environment,
            completedQueries: context.completedQueries
        )
        if let value = try await acceptedValue(
            outcome,
            generation: generation,
            context: acceptanceContext
        ) {
            return value
        }
        try await waitForRetry(
            context,
            currentTime: await context.environment.now()
        )
        return nil
    }

    static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }
}

extension LumenScreenCaptureDisplayResolver {
    private static func timeWithinDeadline<Value: Sendable>(
        displayID: UInt32,
        deadline: UInt64,
        environment: Environment<Value>
    ) async throws -> UInt64 {
        let currentTime = await environment.now()
        guard currentTime <= deadline else {
            throw LumenScreenCaptureError.displayUnavailable(displayID)
        }
        return currentTime
    }

    private static func modeIsReady<Value: Sendable>(
        displayID: UInt32,
        authority: LumenScreenCaptureDisplayAuthority,
        environment: Environment<Value>
    ) async throws -> Bool {
        let snapshot = await environment.readiness()
        try validateOwnership(
            snapshot,
            displayID: displayID,
            authority: authority
        )
        return snapshot.isModeReady(for: authority)
    }

    private static func waitForRetry<Value: Sendable>(
        _ context: ResolutionContext<Value>,
        currentTime: UInt64
    ) async throws {
        guard currentTime < context.overallDeadline else {
            throw LumenScreenCaptureError.displayUnavailable(
                context.displayID
            )
        }
        await context.environment.sleepUntil(
            min(
                addingClamped(
                    currentTime,
                    context.timing.retryDelayNanoseconds
                ),
                context.overallDeadline
            )
        )
    }

    private static func acceptedValue<Value: Sendable>(
        _ outcome: LumenScreenCaptureTimedQueryOutcome<Value>,
        generation: UInt64,
        context: AcceptanceContext<Value>
    ) async throws -> Value? {
        switch outcome {
        case .value(let value):
            try Task.checkCancellation()
            _ = try await timeWithinDeadline(
                displayID: context.displayID,
                deadline: context.overallDeadline,
                environment: context.environment
            )
            try Task.checkCancellation()
            guard try await modeIsReady(
                displayID: context.displayID,
                authority: context.authority,
                environment: context.environment
            ) else {
                return nil
            }
            try Task.checkCancellation()
            return value
        case .failure(let error):
            _ = try await modeIsReady(
                displayID: context.displayID,
                authority: context.authority,
                environment: context.environment
            )
            throw error
        case .timedOut:
            logQueryTimeout(
                displayID: context.displayID,
                generation: generation
            )
            return nil
        }
    }

    private static func validateOwnership(
        _ snapshot: LumenCaptureDisplayReadinessSnapshot,
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

    private static func logQueryStart(
        displayID: UInt32,
        generation: UInt64
    ) {
        let message = [
            "stage=display-query-generation-start",
            "display-id=\(displayID)",
            "generation=\(generation)"
        ].joined(separator: " ")
        logger.notice("\(message, privacy: .public)")
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func logQueryTimeout(
        displayID: UInt32,
        generation: UInt64
    ) {
        let message = [
            "stage=display-query-timeout",
            "display-id=\(displayID)",
            "generation=\(generation)"
        ].joined(separator: " ")
        logger.warning("\(message, privacy: .public)")
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func performTimedQuery<Value: Sendable>(
        displayID: UInt32,
        generation: UInt64,
        deadline: UInt64,
        overallDeadline: UInt64,
        queryBudget: LumenScreenCaptureQueryBudget,
        environment: Environment<Value>,
        completedQueries: LumenScreenCaptureCompletedQueryStore<Value>
    ) async -> LumenScreenCaptureTimedQueryOutcome<Value> {
        let race = LumenScreenCaptureTimedQueryRace<Value>(
            generation: generation
        )
        let queryTask = Task {
            let outcome: LumenScreenCaptureTimedQueryOutcome<Value>
            do {
                outcome = .value(
                    try await environment.lookup(generation)
                )
            } catch {
                outcome = .failure(error)
            }
            let completedAt = await environment.now()
            if completedAt <= deadline {
                await race.finish(
                    generation: generation,
                    outcome: outcome
                )
            } else if completedAt <= overallDeadline {
                await completedQueries.append(
                    generation: generation,
                    outcome: outcome
                )
                logLateQueryResultAvailable(
                    displayID: displayID,
                    generation: generation
                )
            } else {
                logLateQueryResultDiscarded(
                    displayID: displayID,
                    generation: generation
                )
            }
            await queryBudget.finish(generation: generation)
        }
        let timeoutTask = Task {
            // Reserve the exact boundary for a query that completed on time.
            await environment.sleepUntil(addingClamped(deadline, 1))
            await race.finish(
                generation: generation,
                outcome: .timedOut
            )
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

    private static func logLateQueryResultAvailable(
        displayID: UInt32,
        generation: UInt64
    ) {
        let message = [
            "stage=display-query-late-result-available",
            "display-id=\(displayID)",
            "generation=\(generation)"
        ].joined(separator: " ")
        logger.notice("\(message, privacy: .public)")
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func logCompletedQueryAdopted(
        displayID: UInt32,
        generation: UInt64
    ) {
        let message = [
            "stage=display-query-completed-result-adopted",
            "display-id=\(displayID)",
            "generation=\(generation)"
        ].joined(separator: " ")
        logger.notice("\(message, privacy: .public)")
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func logLateQueryResultDiscarded(
        displayID: UInt32,
        generation: UInt64
    ) {
        let message = [
            "stage=display-query-late-result-discarded",
            "display-id=\(displayID)",
            "generation=\(generation)"
        ].joined(separator: " ")
        logger.warning("\(message, privacy: .public)")
        writeScreenCaptureStartupDiagnostic(message)
    }
}
