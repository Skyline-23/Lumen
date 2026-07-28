import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
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

private struct LumenScreenCaptureTimedQueryContext<Value: Sendable> {
    let displayID: UInt32
    let generation: UInt64
    let deadline: UInt64
    let overallDeadline: UInt64
    let queryBudget: LumenScreenCaptureQueryBudget
    let environment: LumenScreenCaptureDisplayResolver.Environment<Value>
    let completedQueries: LumenScreenCaptureCompletedQueryStore<Value>
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
            @Sendable (_ generation: UInt64) async throws ->
                LumenScreenCaptureQueryCompletion<Value>
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
        let acceptanceContext = AcceptanceContext(
            displayID: context.displayID,
            authority: context.authority,
            overallDeadline: context.overallDeadline,
            environment: context.environment
        )
        if let completedValue = try await takeCompletedValue(
            context,
            acceptanceContext: acceptanceContext
        ) {
            return completedValue
        }
        let currentTime = await context.environment.now()
        if currentTime > context.overallDeadline {
            if let boundaryValue = try await takeBoundaryValue(
                context,
                acceptanceContext: acceptanceContext
            ) {
                return boundaryValue
            }
            throw LumenScreenCaptureError.displayUnavailable(context.displayID)
        }
        guard let generation = try await beginQueryIfReady(context) else {
            try await waitForRetry(
                context,
                currentTime: currentTime
            )
            return nil
        }
        let outcome = await performNextQuery(
            context,
            generation: generation,
            currentTime: currentTime
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
    private static func beginQueryIfReady<Value: Sendable>(
        _ context: ResolutionContext<Value>
    ) async throws -> UInt64? {
        guard try await modeIsReady(
            displayID: context.displayID,
            authority: context.authority,
            environment: context.environment
        ) else {
            return nil
        }
        return await context.queryBudget.begin()
    }

    private static func takeBoundaryValue<Value: Sendable>(
        _ context: ResolutionContext<Value>,
        acceptanceContext: AcceptanceContext<Value>
    ) async throws -> Value? {
        // Do not extend the publication deadline. Yield only so an SCK callback
        // that already fired can finish publishing its stamped result.
        for _ in 0 ..< 3 {
            await Task.yield()
            if let value = try await takeCompletedValue(
                context,
                acceptanceContext: acceptanceContext
            ) {
                return value
            }
        }
        return nil
    }

    private static func performNextQuery<Value: Sendable>(
        _ context: ResolutionContext<Value>,
        generation: UInt64,
        currentTime: UInt64
    ) async -> LumenScreenCaptureTimedQueryOutcome<Value> {
        let queryDeadline = min(
            addingClamped(currentTime, context.timing.queryTimeoutNanoseconds),
            context.overallDeadline
        )
        logQueryStart(displayID: context.displayID, generation: generation)
        return await performTimedQuery(
            .init(
                displayID: context.displayID,
                generation: generation,
                deadline: queryDeadline,
                overallDeadline: context.overallDeadline,
                queryBudget: context.queryBudget,
                environment: context.environment,
                completedQueries: context.completedQueries
            )
        )
    }

    private static func takeCompletedValue<Value: Sendable>(
        _ context: ResolutionContext<Value>,
        acceptanceContext: AcceptanceContext<Value>
    ) async throws -> Value? {
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
        return nil
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
        case .value(let value, let completedAtNanoseconds):
            try Task.checkCancellation()
            guard completedAtNanoseconds <= context.overallDeadline else {
                return nil
            }
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
        case .failure(let error, let completedAtNanoseconds):
            try Task.checkCancellation()
            if error is CancellationError {
                throw error
            }
            guard completedAtNanoseconds <= context.overallDeadline else {
                return nil
            }
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

    private static func performTimedQuery<Value: Sendable>(
        _ context: LumenScreenCaptureTimedQueryContext<Value>
    ) async -> LumenScreenCaptureTimedQueryOutcome<Value> {
        let race = LumenScreenCaptureTimedQueryRace<Value>(
            generation: context.generation
        )
        let queryTask = Task {
            await performLookup(context, race: race)
        }
        let timeoutTask = Task {
            // Reserve the exact boundary for a query that completed on time.
            await context.environment.sleepUntil(addingClamped(context.deadline, 1))
            await race.finish(
                generation: context.generation,
                outcome: .timedOut
            )
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            Task {
                await race.finish(
                    generation: context.generation,
                    outcome: .failure(
                        CancellationError(),
                        completedAtNanoseconds: UInt64.max
                    )
                )
            }
        }
        queryTask.cancel()
        timeoutTask.cancel()
        return outcome
    }

    private static func performLookup<Value: Sendable>(
        _ context: LumenScreenCaptureTimedQueryContext<Value>,
        race: LumenScreenCaptureTimedQueryRace<Value>
    ) async {
        let outcome: LumenScreenCaptureTimedQueryOutcome<Value>
        do {
            let completion = try await context.environment.lookup(context.generation)
            outcome = .value(
                completion.value,
                completedAtNanoseconds: completion.completedAtNanoseconds
            )
        } catch {
            outcome = .failure(
                error,
                completedAtNanoseconds: await context.environment.now()
            )
        }
        await publishLookupOutcome(outcome, context: context, race: race)
        await context.queryBudget.finish(generation: context.generation)
    }

    private static func publishLookupOutcome<Value: Sendable>(
        _ outcome: LumenScreenCaptureTimedQueryOutcome<Value>,
        context: LumenScreenCaptureTimedQueryContext<Value>,
        race: LumenScreenCaptureTimedQueryRace<Value>
    ) async {
        let completedAt = outcome.completedAtNanoseconds ?? UInt64.max
        if completedAt <= context.deadline {
            await race.finish(generation: context.generation, outcome: outcome)
        } else if completedAt <= context.overallDeadline {
            await context.completedQueries.append(
                generation: context.generation,
                outcome: outcome
            )
            logLateQueryResultAvailable(
                displayID: context.displayID,
                generation: context.generation
            )
        } else {
            logLateQueryResultDiscarded(
                displayID: context.displayID,
                generation: context.generation
            )
        }
    }
}
