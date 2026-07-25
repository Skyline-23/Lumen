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

extension LumenEncodedCaptureSession {
    func start(callbacks: LumenEncodedCaptureCallbacks) async throws {
        guard runtime == nil,
              startFlight == nil,
              systemAudioAttachFlight == nil else {
            throw LumenScreenCaptureError.captureAlreadyRunning
        }
        callbackGate?.close()
        self.callbacks = callbacks
        isStopping = false
        recoveryInProgressGeneration = nil
        runtimeGeneration &+= 1
        try await startRuntime(
            callbacks: callbacks,
            generation: runtimeGeneration,
            recoveryOwnerGeneration: nil
        )
    }

    @discardableResult
    func stop() async
        -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        isStopping = true
        runtimeGeneration &+= 1
        recoveryInProgressGeneration = nil
        callbacks = nil
        callbackGate?.close()
        let inFlight = self.startFlight
        let audioAttachInFlight = self.systemAudioAttachFlight
        systemAudioAttachGate?.close()
        let runtimeToStop = runtime
        self.runtime = nil
        await inFlight?.requestStop()
        await audioAttachInFlight?.requestStop()
        let runtimeStopTask = runtimeToStop.map { runtime in
            Task { await self.stopRuntimeOnce(runtime) }
        }
        await inFlight?.waitUntilSettled()
        await audioAttachInFlight?.waitUntilSettled()
        await runtimeStopTask?.value
        var cleanupFailures: [LumenSystemAudioPlaybackSuppressionCleanupFailure] = []
        if activeSystemAudioIsActivated,
           let systemAudioPlaybackSuppression {
            let audioCallbacks = activeSystemAudioCallbacks
            activeSystemAudioIsActivated = false
            let failures = await systemAudioPlaybackSuppression
                .deactivate()
            cleanupFailures = failures
            reportSystemAudioPlaybackSuppressionCleanupFailures(
                failures,
                callbacks: audioCallbacks
            )
            if failures.isEmpty {
                activeSystemAudio = nil
                activeSystemAudioCallbacks = nil
            } else {
                activeSystemAudioIsActivated = true
            }
        }
        return cleanupFailures
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
        let systemAudioPlaybackSuppression =
            try requireSystemAudioAttachmentAvailable(configuration)
        let attachGeneration = runtimeGeneration
        let attachFlight = LumenCaptureStartFlight()
        let attachGate = LumenCaptureCallbackGate()
        systemAudioAttachFlight = attachFlight
        systemAudioAttachGate = attachGate
        let guardedCallbacks = guardedSystemAudioCallbacks(
            callbacks,
            gate: attachGate
        )
        var audioWasActivated = false
        do {
            try await requireCurrentSystemAudioAttach(
                generation: attachGeneration,
                flight: attachFlight
            )
            try await systemAudioPlaybackSuppression.activate(
                configuration: configuration,
                callbacks: guardedCallbacks
            )
            audioWasActivated = true
            try await requireCurrentSystemAudioAttach(
                generation: attachGeneration,
                flight: attachFlight
            )
            activeSystemAudio = configuration
            activeSystemAudioCallbacks = callbacks
            activeSystemAudioIsActivated = true
            await finishSystemAudioAttach(attachFlight)
        } catch {
            try await failSystemAudioAttach(
                error: error,
                audioWasActivated: audioWasActivated,
                suppression: systemAudioPlaybackSuppression,
                gate: attachGate,
                flight: attachFlight
            )
        }
    }

    func requireSystemAudioAttachmentAvailable(
        _ configuration: LumenMacAudioCaptureConfiguration
    ) throws -> LumenSystemAudioPlaybackSuppression {
        guard runtime != nil, !isStopping else {
            throw LumenScreenCaptureError.captureNotRunning
        }
        try validateSystemAudioConfiguration(configuration)
        guard activeSystemAudio == nil else {
            throw LumenSystemAudioPlaybackSuppressionError.activationFailed(
                stage: .createProcessTap,
                status: nil,
                message: "This encoded session already owns system audio.",
                cleanupFailures: []
            )
        }
        guard let systemAudioPlaybackSuppression else {
            throw LumenAudioCaptureError
                .systemAudioPlaybackSuppressionDependencyMissing
        }
        return systemAudioPlaybackSuppression
    }

    func guardedSystemAudioCallbacks(
        _ callbacks: LumenAudioCaptureCallbacks,
        gate: LumenCaptureCallbackGate
    ) -> LumenAudioCaptureCallbacks {
        LumenAudioCaptureCallbacks(
            frameHandler: { frame in
                guard gate.isOpen() else { return }
                callbacks.frameHandler(frame)
            },
            eventHandler: { event in
                guard gate.isOpen() else { return }
                callbacks.eventHandler?(event)
            }
        )
    }

    func requireCurrentSystemAudioAttach(
        generation: UInt64,
        flight: LumenCaptureStartFlight
    ) async throws {
        guard !isStopping,
              runtime != nil,
              runtimeGeneration == generation,
              !(await flight.isStopRequested()) else {
            throw LumenAudioCaptureError.captureStartCancelled
        }
    }

    func failSystemAudioAttach(
        error: any Error,
        audioWasActivated: Bool,
        suppression: LumenSystemAudioPlaybackSuppression,
        gate: LumenCaptureCallbackGate,
        flight: LumenCaptureStartFlight
    ) async throws -> Never {
        if audioWasActivated {
            gate.close()
            let cleanupFailures = await suppression.deactivate()
            if !cleanupFailures.isEmpty {
                await finishSystemAudioAttach(flight)
                throw LumenSystemAudioCaptureLifecycleError(
                    underlyingError: error,
                    cleanupFailures: cleanupFailures
                )
            }
        }
        await finishSystemAudioAttach(flight)
        if let suppressionError =
            error as? LumenSystemAudioPlaybackSuppressionError {
            throw LumenAudioCaptureError
                .systemAudioPlaybackSuppressionUnavailable(suppressionError)
        }
        throw error
    }

    @discardableResult
    func detachSystemAudio() async
        -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        systemAudioAttachGate?.close()
        let attachInFlight = systemAudioAttachFlight
        await attachInFlight?.requestStop()
        await attachInFlight?.waitUntilSettled()
        guard activeSystemAudioIsActivated,
              let systemAudioPlaybackSuppression else {
            systemAudioAttachGate = nil
            return []
        }
        let callbacks = activeSystemAudioCallbacks
        activeSystemAudioIsActivated = false
        systemAudioAttachGate = nil
        let failures = await systemAudioPlaybackSuppression.deactivate()
        reportSystemAudioPlaybackSuppressionCleanupFailures(
            failures,
            callbacks: callbacks
        )
        if failures.isEmpty {
            activeSystemAudio = nil
            activeSystemAudioCallbacks = nil
        } else {
            activeSystemAudioIsActivated = true
        }
        return failures
    }

    func finishSystemAudioAttach(_ flight: LumenCaptureStartFlight) async {
        if systemAudioAttachFlight === flight {
            systemAudioAttachFlight = nil
        }
        _ = await flight.finishStart(terminationError: nil)
        await flight.settle()
    }

    func statisticsSnapshot() -> LumenEncodedCaptureSessionStatistics {
        statistics
    }

    func updateStatistics(_ statistics: LumenEncodedCaptureSessionStatistics) {
        var statistics = statistics
        statistics.automaticRestartCount = max(
            statistics.automaticRestartCount,
            self.statistics.automaticRestartCount
        )
        self.statistics = statistics
    }

}
