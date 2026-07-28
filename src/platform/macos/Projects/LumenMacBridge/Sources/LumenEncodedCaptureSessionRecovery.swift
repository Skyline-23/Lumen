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

struct LumenRuntimeRecoveryContext {
    let callbacks: LumenEncodedCaptureCallbacks
    let replacementGeneration: UInt64
}

extension LumenEncodedCaptureSession {
    func handleUnexpectedTermination(
        generation: UInt64,
        error: Error
    ) async {
        guard let recovery = beginUnexpectedTerminationRecovery(
            generation: generation
        ) else {
            return
        }

        if let failedRuntime = runtime {
            runtime = nil
            await stopRuntimeOnce(failedRuntime)
        }
        guard keepRecoveryIfCurrent(
            failedGeneration: generation,
            replacementGeneration: recovery.replacementGeneration
        ) else {
            return
        }

        let cleanupFailures = await deactivateAudioForRecovery()
        guard keepRecoveryIfCurrent(
            failedGeneration: generation,
            replacementGeneration: recovery.replacementGeneration
        ) else {
            return
        }
        guard cleanupFailures.isEmpty else {
            reportRecoveryCleanupFailure(
                cleanupFailures,
                generation: generation,
                callbacks: recovery.callbacks
            )
            return
        }
        guard shouldRestartAfterUnexpectedTermination(
            error,
            generation: generation,
            callbacks: recovery.callbacks
        ) else {
            return
        }

        statistics.automaticRestartCount &+= 1
        recovery.callbacks.eventHandler?(.init(
            kind: .restarted,
            message: "Restarting ScreenCaptureKit after unexpected termination",
            automaticRestartCount: statistics.automaticRestartCount
        ))
        await restartRecoveredRuntime(
            failedGeneration: generation,
            replacementGeneration: recovery.replacementGeneration,
            callbacks: recovery.callbacks
        )
    }

    func beginUnexpectedTerminationRecovery(
        generation: UInt64
    ) -> LumenRuntimeRecoveryContext? {
        guard !isStopping,
              generation == runtimeGeneration,
              recoveryInProgressGeneration == nil,
              let callbacks else {
            return nil
        }
        recoveryInProgressGeneration = generation
        runtimeGeneration &+= 1
        callbackGate?.close()
        return LumenRuntimeRecoveryContext(
            callbacks: callbacks,
            replacementGeneration: runtimeGeneration
        )
    }

    func shouldRestartAfterUnexpectedTermination(
        _ error: Error,
        generation: UInt64,
        callbacks: LumenEncodedCaptureCallbacks
    ) -> Bool {
        guard !(error is LumenExactCaptureError) else {
            reportTerminalRecoveryFailure(
                error,
                generation: generation,
                callbacks: callbacks
            )
            return false
        }
        guard statistics.automaticRestartCount
                < maximumAutomaticRestartCount else {
            reportTerminalRecoveryFailure(
                error,
                generation: generation,
                callbacks: callbacks,
                message: "ScreenCaptureKit exhausted automatic restarts: " +
                    error.localizedDescription
            )
            return false
        }
        return true
    }

    func keepRecoveryIfCurrent(
        failedGeneration: UInt64,
        replacementGeneration: UInt64
    ) -> Bool {
        guard recoveryIsCurrent(
            failedGeneration: failedGeneration,
            replacementGeneration: replacementGeneration
        ) else {
            clearRecoveryIfOwned(by: failedGeneration)
            return false
        }
        return true
    }

    func deactivateAudioForRecovery() async
        -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        guard activeSystemAudioIsActivated,
              let systemAudioPlaybackSuppression else {
            return []
        }
        activeSystemAudioIsActivated = false
        let failures = await systemAudioPlaybackSuppression.deactivate()
        activeSystemAudioIsActivated = !failures.isEmpty
        return failures
    }

    func reportRecoveryCleanupFailure(
        _ cleanupFailures:
            [LumenSystemAudioPlaybackSuppressionCleanupFailure],
        generation: UInt64,
        callbacks: LumenEncodedCaptureCallbacks
    ) {
        clearRecoveryIfOwned(by: generation)
        reportSystemAudioPlaybackSuppressionCleanupFailures(
            cleanupFailures,
            callbacks: activeSystemAudioCallbacks
        )
        let error = LumenAudioCaptureError
            .systemAudioPlaybackSuppressionCleanupFailed(cleanupFailures)
        statistics.isRunning = false
        statistics.lastErrorDescription = error.localizedDescription
        callbacks.eventHandler?(.init(
            kind: .failed,
            message: statistics.lastErrorDescription,
            automaticRestartCount: statistics.automaticRestartCount
        ))
    }

    func reportTerminalRecoveryFailure(
        _ error: any Error,
        generation: UInt64,
        callbacks: LumenEncodedCaptureCallbacks,
        message: String? = nil
    ) {
        clearRecoveryIfOwned(by: generation)
        statistics.isRunning = false
        statistics.lastErrorDescription = error.localizedDescription
        callbacks.eventHandler?(.init(
            kind: .failed,
            message: message ?? error.localizedDescription,
            automaticRestartCount: statistics.automaticRestartCount
        ))
    }

    func restartRecoveredRuntime(
        failedGeneration: UInt64,
        replacementGeneration: UInt64,
        callbacks: LumenEncodedCaptureCallbacks
    ) async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard keepRecoveryIfCurrent(
            failedGeneration: failedGeneration,
            replacementGeneration: replacementGeneration
        ) else {
            return
        }
        do {
            try await startRuntime(
                callbacks: callbacks,
                generation: replacementGeneration,
                recoveryOwnerGeneration: failedGeneration
            )
            clearRecoveryIfOwned(by: failedGeneration)
        } catch {
            guard !isStopping,
                  replacementGeneration == runtimeGeneration else {
                clearRecoveryIfOwned(by: failedGeneration)
                return
            }
            clearRecoveryIfOwned(by: failedGeneration)
            await handleUnexpectedTermination(
                generation: replacementGeneration,
                error: error
            )
        }
    }

    func startRuntimeIsCurrent(
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

    func recoveryIsCurrent(
        failedGeneration: UInt64,
        replacementGeneration: UInt64
    ) -> Bool {
        !isStopping &&
            recoveryInProgressGeneration == failedGeneration &&
            runtimeGeneration == replacementGeneration
    }

    func clearRecoveryIfOwned(by generation: UInt64) {
        if recoveryInProgressGeneration == generation {
            recoveryInProgressGeneration = nil
        }
    }

    func reportSystemAudioPlaybackSuppressionCleanupFailures(
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

    func validateSystemAudioConfiguration(
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

    nonisolated static func typedSystemAudioError(
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
