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

private struct LumenDisplayQueryContext {
    let displayID: UInt32
    let authorityLabel: String
    let ownerToken: UInt
    let generation: UInt64
}

private struct LumenDisplayQueryResult: Sendable {
    let target: LumenScreenCaptureDisplayHandle?
    let observedDisplayIDs: String
}

private struct LumenDisplayReadinessContext {
    let displayID: UInt32
    let authorityLabel: String
    let ownerToken: UInt
    let startedAt: UInt64
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
    ) -> LumenCaptureDisplayReadinessSnapshot {
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
        return LumenCaptureDisplayReadinessSnapshot(
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
        readiness: @escaping @Sendable () async -> LumenCaptureDisplayReadinessSnapshot
    ) async throws -> LumenScreenCaptureDisplayHandle {
        let context = makeReadinessContext(
            displayID: displayID,
            authority: authority
        )
        let initialSnapshot = await readiness()
        logReadinessBegin(
            context,
            snapshot: initialSnapshot,
            authority: authority
        )
        do {
            let handle = try await resolveHandle(
                context: context,
                authority: authority,
                readiness: readiness
            )
            logReadinessComplete(context)
            return handle
        } catch {
            let failureSnapshot = await readiness()
            logReadinessFailure(
                context,
                snapshot: failureSnapshot,
                authority: authority,
                error: error
            )
            throw error
        }
    }

    private static func makeReadinessContext(
        displayID: UInt32,
        authority: LumenScreenCaptureDisplayAuthority
    ) -> LumenDisplayReadinessContext {
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
        return LumenDisplayReadinessContext(
            displayID: displayID,
            authorityLabel: authorityLabel,
            ownerToken: ownerToken,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
    }

    private static func resolveHandle(
        context: LumenDisplayReadinessContext,
        authority: LumenScreenCaptureDisplayAuthority,
        readiness: @escaping @Sendable () async -> LumenCaptureDisplayReadinessSnapshot
    ) async throws -> LumenScreenCaptureDisplayHandle {
        try await LumenScreenCaptureDisplayResolver.resolve(
            displayID: context.displayID,
            authority: authority,
            timing: .production,
            queryBudget: productionQueryBudget,
            environment: .init(
                now: {
                    DispatchTime.now().uptimeNanoseconds
                },
                sleepUntil: { deadline in
                    let current = DispatchTime.now().uptimeNanoseconds
                    guard deadline > current else { return }
                    try? await Task.sleep(nanoseconds: deadline - current)
                },
                readiness: readiness,
                lookup: { generation in
                    try await queryDisplay(
                        displayID: context.displayID,
                        authorityLabel: context.authorityLabel,
                        ownerToken: context.ownerToken,
                        generation: generation
                    )
                }
            )
        )
    }

    private static func logReadinessBegin(
        _ context: LumenDisplayReadinessContext,
        snapshot: LumenCaptureDisplayReadinessSnapshot,
        authority: LumenScreenCaptureDisplayAuthority
    ) {
        let message = [
            "stage=display-readiness-begin",
            "display-id=\(context.displayID)",
            "authority=\(context.authorityLabel)",
            "owner-token=\(context.ownerToken)",
            "online=\(snapshot.isOnline)",
            "active=\(snapshot.isActive)",
            "current-mode=\(snapshot.hasCurrentMode)",
            "pixel-size=\(snapshot.pixelWidth)x\(snapshot.pixelHeight)",
            "configured-size=\(snapshot.configuredPixelWidth)x\(snapshot.configuredPixelHeight)",
            "mode-ready=\(snapshot.isModeReady(for: authority))"
        ].joined(separator: " ")
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func logReadinessComplete(
        _ context: LumenDisplayReadinessContext
    ) {
        let message = [
            "stage=display-readiness-complete",
            "display-id=\(context.displayID)",
            "authority=\(context.authorityLabel)",
            "owner-token=\(context.ownerToken)",
            "elapsed-ms=\(elapsedMilliseconds(since: context.startedAt))"
        ].joined(separator: " ")
        logger.notice("\(message, privacy: .public)")
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func logReadinessFailure(
        _ context: LumenDisplayReadinessContext,
        snapshot: LumenCaptureDisplayReadinessSnapshot,
        authority: LumenScreenCaptureDisplayAuthority,
        error: Error
    ) {
        let elapsed = elapsedMilliseconds(since: context.startedAt)
        let summary = [
            "stage=display-readiness-failed",
            "display-id=\(context.displayID)",
            "authority=\(context.authorityLabel)",
            "owner-token=\(context.ownerToken)",
            "elapsed-ms=\(elapsed)",
            "error=\(String(describing: error))"
        ].joined(separator: " ")
        logger.error("\(summary, privacy: .public)")
        let diagnostic = [
            "stage=display-readiness-failed",
            "display-id=\(context.displayID)",
            "authority=\(context.authorityLabel)",
            "owner-token=\(context.ownerToken)",
            "online=\(snapshot.isOnline)",
            "active=\(snapshot.isActive)",
            "current-mode=\(snapshot.hasCurrentMode)",
            "pixel-size=\(snapshot.pixelWidth)x\(snapshot.pixelHeight)",
            "configured-size=\(snapshot.configuredPixelWidth)x\(snapshot.configuredPixelHeight)",
            "mode-ready=\(snapshot.isModeReady(for: authority))",
            "elapsed-ms=\(elapsed)",
            "error=\(String(describing: error))"
        ].joined(separator: " ")
        writeScreenCaptureStartupDiagnostic(diagnostic)
    }
}

private extension LumenScreenCaptureDisplayReadiness {
    private static func queryDisplay(
        displayID: UInt32,
        authorityLabel: String,
        ownerToken: UInt,
        generation: UInt64
    ) async throws -> LumenScreenCaptureDisplayHandle? {
        let context = LumenDisplayQueryContext(
            displayID: displayID,
            authorityLabel: authorityLabel,
            ownerToken: ownerToken,
            generation: generation
        )
        logDisplayQueryBegin(context)
        let result = try await getShareableContentExcludingDesktopWindows(
            displayID: displayID
        )
        logDisplayQueryComplete(
            context,
            found: result.target != nil,
            observedDisplayIDs: result.observedDisplayIDs
        )
        return result.target
    }

    private static func getShareableContentExcludingDesktopWindows(
        displayID: UInt32
    ) async throws -> LumenDisplayQueryResult
    {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    let observedDisplayIDs = content.displays
                        .map { String(UInt32($0.displayID)) }
                        .joined(separator: ",")
                    let target = content.displays.first {
                        UInt32($0.displayID) == displayID
                    }
                    continuation.resume(
                        returning: LumenDisplayQueryResult(
                            target: target.map(
                                LumenScreenCaptureDisplayHandle.init(value:)
                            ),
                            observedDisplayIDs: observedDisplayIDs
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: LumenScreenCaptureError.shareableContentUnavailable
                    )
                }
            }
        }
    }

    private static func logDisplayQueryBegin(
        _ context: LumenDisplayQueryContext
    ) {
        let message = [
            "stage=display-query-begin",
            "display-id=\(context.displayID)",
            "authority=\(context.authorityLabel)",
            "owner-token=\(context.ownerToken)",
            "generation=\(context.generation)"
        ].joined(separator: " ")
        logger.notice("\(message, privacy: .public)")
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func logDisplayQueryComplete(
        _ context: LumenDisplayQueryContext,
        found: Bool,
        observedDisplayIDs: String
    ) {
        let message = [
            "stage=display-query-complete",
            "display-id=\(context.displayID)",
            "authority=\(context.authorityLabel)",
            "owner-token=\(context.ownerToken)",
            "generation=\(context.generation)",
            "found=\(found)",
            "observed-display-ids=\(observedDisplayIDs)"
        ].joined(separator: " ")
        logger.notice("\(message, privacy: .public)")
        writeScreenCaptureStartupDiagnostic(message)
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        let current = DispatchTime.now().uptimeNanoseconds
        guard current >= start else { return 0 }
        return Double(current - start) / 1_000_000
    }
}
