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

private struct LumenDisplayPrefetchContext {
    let owner: LumenRetainedVirtualDisplayReference
    let ownerToken: UInt
    let generation: UInt64
}

private struct LumenResolvedDisplayPrefetch {
    let prepared: LumenScreenCapturePreparedDisplay
    let ownerToken: UInt
    let startedAt: UInt64
}

enum LumenScreenCaptureDisplayPrefetch {
    private static let preparedDisplays =
        LumenPreparedDisplayStore<LumenScreenCapturePreparedDisplay>()
    private static let expectedOwners =
        LumenExpectedDisplayOwnerStore<LumenRetainedVirtualDisplayReference>()
    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )

    static func prepare(
        displayID: UInt32,
        timing: LumenScreenCaptureDisplayReadinessTiming = .production
    ) async throws {
        let context = try await beginPrefetch(displayID: displayID)
        do {
            let handle = try await LumenScreenCaptureDisplayReadiness.resolveOwned(
                displayID: displayID,
                expectedOwner: context.owner,
                timing: timing
            )
            try Task.checkCancellation()
            let completedAt = DispatchTime.now().uptimeNanoseconds
            try Task.checkCancellation()
            try await preparedDisplays.complete(
                displayID: displayID,
                ownerToken: context.ownerToken,
                generation: context.generation,
                value: LumenScreenCapturePreparedDisplay(
                    handle: handle,
                    owner: context.owner
                ),
                expiresAt: prefetchExpiration(
                    after: completedAt,
                    timing: timing
                )
            )
            logPrefetch(
                stage: "display-prefetch-ready",
                displayID: displayID,
                ownerToken: context.ownerToken,
                generation: context.generation,
                writeLog: false
            )
        } catch {
            await preparedDisplays.discard(
                displayID: displayID,
                generation: context.generation
            )
            logPrefetch(
                stage: "display-prefetch-failed",
                displayID: displayID,
                ownerToken: context.ownerToken,
                generation: context.generation,
                error: error,
                writeLog: false
            )
            throw error
        }
    }

    private static func beginPrefetch(
        displayID: UInt32
    ) async throws -> LumenDisplayPrefetchContext {
        guard let retainedDisplay = LumenMacVirtualDisplay.registeredDisplay(
            forDisplayID: displayID
        ) else {
            throw LumenScreenCaptureError.displayOwnershipLost(displayID)
        }
        let owner = LumenRetainedVirtualDisplayReference(
            display: retainedDisplay
        )
        let ownerToken = owner.ownerToken
        await expectedOwners.set(owner, displayID: displayID)
        let generation = await preparedDisplays.begin(
            displayID: displayID,
            ownerToken: ownerToken
        )
        logPrefetch(
            stage: "display-prefetch-begin",
            displayID: displayID,
            ownerToken: ownerToken,
            generation: generation
        )
        return LumenDisplayPrefetchContext(
            owner: owner,
            ownerToken: ownerToken,
            generation: generation
        )
    }

    static func resolve(
        displayID: UInt32
    ) async throws -> LumenScreenCaptureDisplayHandle? {
        guard let context = await takeValidatedPrefetch(
            displayID: displayID
        ) else {
            return nil
        }
        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - context.startedAt
        ) / 1_000_000
        let message = [
            "stage=display-prefetch-resolved",
            "display-id=\(displayID)",
            "owner-token=\(context.ownerToken)",
            "found=true",
            "wait-ms=\(elapsedMilliseconds)"
        ].joined(separator: " ")
        logger.notice("\(message, privacy: .public)")
        return context.prepared.handle
    }

    private static func takeValidatedPrefetch(
        displayID: UInt32
    ) async -> LumenResolvedDisplayPrefetch? {
        guard let ownerToken = await validatedOwnerToken(
            displayID: displayID
        ) else {
            return nil
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let prepared = await preparedDisplays.take(
            displayID: displayID,
            ownerToken: ownerToken,
            now: startedAt
        )
        guard let prepared,
              prepared.owner.ownerToken == ownerToken,
              prepared.owner.isCurrent(displayID: displayID) else {
            logPrefetchRejection(
                displayID: displayID,
                ownerToken: ownerToken,
                reason: "stale-or-expired"
            )
            return nil
        }
        return LumenResolvedDisplayPrefetch(
            prepared: prepared,
            ownerToken: ownerToken,
            startedAt: startedAt
        )
    }

    private static func validatedOwnerToken(
        displayID: UInt32
    ) async -> UInt? {
        guard let owner = await expectedOwners.owner(displayID: displayID),
              owner.isCurrent(displayID: displayID) else {
            await preparedDisplays.discard(displayID: displayID)
            logPrefetchRejection(
                displayID: displayID,
                reason: "owner-not-current"
            )
            return nil
        }
        return owner.ownerToken
    }

    private static func prefetchExpiration(
        after completedAt: UInt64,
        timing: LumenScreenCaptureDisplayReadinessTiming
    ) -> UInt64 {
        LumenScreenCaptureDisplayResolver.addingClamped(
            completedAt,
            timing.overallDeadlineNanoseconds
        )
    }

    private static func logPrefetch(
        stage: String,
        displayID: UInt32,
        ownerToken: UInt,
        generation: UInt64,
        error: Error? = nil,
        writeLog: Bool = true
    ) {
        var fields = [
            "stage=\(stage)",
            "display-id=\(displayID)",
            "owner-token=\(ownerToken)",
            "generation=\(generation)"
        ]
        if let error {
            fields.append("error=\(String(describing: error))")
        }
        let message = fields.joined(separator: " ")
        if writeLog {
            logger.notice("\(message, privacy: .public)")
        }
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func logPrefetchRejection(
        displayID: UInt32,
        ownerToken: UInt? = nil,
        reason: String
    ) {
        var fields = [
            "stage=display-prefetch-rejected",
            "display-id=\(displayID)"
        ]
        if let ownerToken {
            fields.append("owner-token=\(ownerToken)")
        }
        fields.append("reason=\(reason)")
        let message = fields.joined(separator: " ")
        logger.warning("\(message, privacy: .public)")
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
