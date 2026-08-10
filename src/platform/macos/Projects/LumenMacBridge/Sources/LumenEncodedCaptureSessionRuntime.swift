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

struct LumenRuntimeStartResources {
    let runtime: any LumenEncodedCaptureRuntime
    let flight: LumenCaptureStartFlight
    let callbackGate: LumenCaptureCallbackGate
    let terminationLatch: LumenCaptureTerminationLatch
}

struct LumenRuntimeAudioActivation {
    let wasActivated: Bool
    let callbacks: LumenAudioCaptureCallbacks?

    static let inactive = Self(
        wasActivated: false,
        callbacks: nil
    )
}

struct LumenRuntimeStartCleanupRequest {
    let resources: LumenRuntimeStartResources
    let audioActivation: LumenRuntimeAudioActivation
    let stopRuntime: Bool
}

extension LumenEncodedCaptureSession {
    func startRuntime(
        callbacks: LumenEncodedCaptureCallbacks,
        generation: UInt64,
        recoveryOwnerGeneration: UInt64?
    ) async throws {
        guard startRuntimeIsCurrent(
            generation: generation,
            runtime: nil,
            recoveryOwnerGeneration: recoveryOwnerGeneration,
            requireRuntimeIdentity: false
        ) else {
            return
        }
        let resources = try await makeRuntimeStartResources(
            callbacks: callbacks,
            generation: generation
        )
        var audioActivation = LumenRuntimeAudioActivation.inactive
        var runtimeStartWasAttempted = false
        do {
            audioActivation = try await activateConfiguredSystemAudio(
                callbackGate: resources.callbackGate
            )
            guard await runtimeStartMayProceed(
                resources: resources,
                generation: generation,
                recoveryOwnerGeneration: recoveryOwnerGeneration
            ) else {
                _ = await cleanUpFailedRuntimeStart(.init(
                    resources: resources,
                    audioActivation: audioActivation,
                    stopRuntime: true
                ))
                return
            }
            runtimeStartWasAttempted = true
            try await resources.runtime.start()
        } catch {
            try await handleRuntimeStartFailure(
                error,
                resources: resources,
                audioActivation: audioActivation,
                runtimeStartWasAttempted: runtimeStartWasAttempted,
                recoveryOwnerGeneration: recoveryOwnerGeneration
            )
        }

        try await completeRuntimeStart(
            resources: resources,
            generation: generation,
            recoveryOwnerGeneration: recoveryOwnerGeneration,
            audioActivation: audioActivation
        )
    }

    func completeRuntimeStart(
        resources: LumenRuntimeStartResources,
        generation: UInt64,
        recoveryOwnerGeneration: UInt64?,
        audioActivation: LumenRuntimeAudioActivation
    ) async throws {
        let completion = await resources.flight.finishStart(
            terminationError: resources.terminationLatch.complete()
        )
        if let terminationError = completion.terminationError {
            let cleanupFailures = await cleanUpFailedRuntimeStart(.init(
                resources: resources,
                audioActivation: audioActivation,
                stopRuntime: true
            ))
            try throwRuntimeStartFailure(
                terminationError,
                terminationDuringStart: true,
                recoveryOwnerGeneration: recoveryOwnerGeneration,
                cleanupFailures: cleanupFailures
            )
        }
        guard await runtimeStartMayProceed(
            resources: resources,
            generation: generation,
            recoveryOwnerGeneration: recoveryOwnerGeneration
        ) else {
            _ = await cleanUpFailedRuntimeStart(.init(
                resources: resources,
                audioActivation: audioActivation,
                stopRuntime: true
            ))
            return
        }
        await finishStartFlight(resources.flight)
    }

    func makeRuntimeStartResources(
        callbacks: LumenEncodedCaptureCallbacks,
        generation: UInt64
    ) async throws -> LumenRuntimeStartResources {
        let owner = self
        let flight = LumenCaptureStartFlight()
        let callbackGate = LumenCaptureCallbackGate()
        let terminationLatch = LumenCaptureTerminationLatch()
        startFlight = flight
        self.callbackGate = callbackGate
        let guardedCallbacks = guardedVideoCallbacks(
            callbacks,
            gate: callbackGate
        )
        do {
            let runtime = try runtimeFactory.makeRuntime(
                context: .init(
                    configuration: configuration,
                    callbacks: guardedCallbacks,
                    statisticsHandler: { statistics in
                        guard callbackGate.isOpen() else { return }
                        // The macOS runtime coalesces successful-output
                        // diagnostics before this boundary. Lifecycle,
                        // control, and terminal publications remain immediate.
                        Task {
                            await owner.updateStatistics(statistics)
                        }
                    },
                    terminationHandler: { error in
                        let wasDuringStart = terminationLatch.record(error)
                        guard !wasDuringStart else {
                            return
                        }
                        Task {
                            await owner.handleUnexpectedTermination(
                                generation: generation,
                                error: error
                            )
                        }
                    }
                )
            )
            self.runtime = runtime
            return LumenRuntimeStartResources(
                runtime: runtime,
                flight: flight,
                callbackGate: callbackGate,
                terminationLatch: terminationLatch
            )
        } catch {
            await finishStartFlight(flight)
            throw error
        }
    }

    func guardedVideoCallbacks(
        _ callbacks: LumenEncodedCaptureCallbacks,
        gate: LumenCaptureCallbackGate
    ) -> LumenEncodedCaptureCallbacks {
        LumenEncodedCaptureCallbacks(
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

    func activateConfiguredSystemAudio(
        callbackGate: LumenCaptureCallbackGate
    ) async throws -> LumenRuntimeAudioActivation {
        guard let activeSystemAudio else {
            return .inactive
        }
        try validateSystemAudioConfiguration(activeSystemAudio)
        guard let activeSystemAudioCallbacks,
              let systemAudioPlaybackSuppression else {
            throw LumenAudioCaptureError
                .systemAudioPlaybackSuppressionDependencyMissing
        }
        let guardedCallbacks = guardedSystemAudioCallbacks(
            activeSystemAudioCallbacks,
            gate: callbackGate
        )
        try await systemAudioPlaybackSuppression.activate(
            configuration: activeSystemAudio,
            callbacks: guardedCallbacks
        )
        activeSystemAudioIsActivated = true
        return LumenRuntimeAudioActivation(
            wasActivated: true,
            callbacks: activeSystemAudioCallbacks
        )
    }

    func runtimeStartMayProceed(
        resources: LumenRuntimeStartResources,
        generation: UInt64,
        recoveryOwnerGeneration: UInt64?
    ) async -> Bool {
        guard !(await resources.flight.isStopRequested()) else {
            return false
        }
        return startRuntimeIsCurrent(
            generation: generation,
            runtime: resources.runtime,
            recoveryOwnerGeneration: recoveryOwnerGeneration,
            requireRuntimeIdentity: true
        )
    }

    func handleRuntimeStartFailure(
        _ error: any Error,
        resources: LumenRuntimeStartResources,
        audioActivation: LumenRuntimeAudioActivation,
        runtimeStartWasAttempted: Bool,
        recoveryOwnerGeneration: UInt64?
    ) async throws -> Never {
        let completion = await resources.flight.finishStart(
            terminationError: resources.terminationLatch.complete(),
            error: error
        )
        let stopRequested = await resources.flight.isStopRequested()
        let cleanupFailures = await cleanUpFailedRuntimeStart(.init(
            resources: resources,
            audioActivation: audioActivation,
            stopRuntime: runtimeStartWasAttempted || stopRequested
        ))
        let failure = completion.terminationError
            ?? completion.startError
            ?? error
        try throwRuntimeStartFailure(
            failure,
            terminationDuringStart: completion.terminationError != nil,
            recoveryOwnerGeneration: recoveryOwnerGeneration,
            cleanupFailures: cleanupFailures
        )
    }

    func throwRuntimeStartFailure(
        _ failure: any Error,
        terminationDuringStart: Bool,
        recoveryOwnerGeneration: UInt64?,
        cleanupFailures:
            [LumenSystemAudioPlaybackSuppressionCleanupFailure]
    ) throws -> Never {
        if recoveryOwnerGeneration == nil, terminationDuringStart {
            let startupFailure = LumenEncodedCaptureStartupError
                .runtimeTerminated(failure)
            if !cleanupFailures.isEmpty {
                throw LumenSystemAudioCaptureLifecycleError(
                    underlyingError: startupFailure,
                    cleanupFailures: cleanupFailures
                )
            }
            throw startupFailure
        }
        if !cleanupFailures.isEmpty {
            throw LumenSystemAudioCaptureLifecycleError(
                underlyingError: failure,
                cleanupFailures: cleanupFailures
            )
        }
        throw Self.typedSystemAudioError(failure)
    }

    func finishStartFlight(_ flight: LumenCaptureStartFlight) async {
        if self.startFlight === flight {
            self.startFlight = nil
        }
        await flight.settle()
    }

    func stopRuntimeOnce(
        _ runtime: any LumenEncodedCaptureRuntime
    ) async {
        let identity = ObjectIdentifier(runtime)
        if let existing = runtimeStopRecords[identity],
           existing.runtime === runtime {
            await existing.task.value
            return
        }
        let task = Task { await runtime.stop() }
        runtimeStopRecords[identity] = .init(runtime: runtime, task: task)
        await task.value
    }

    func cleanUpFailedRuntimeStart(
        _ request: LumenRuntimeStartCleanupRequest
    ) async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        request.resources.callbackGate.close()
        if request.stopRuntime {
            await stopRuntimeOnce(request.resources.runtime)
        }
        let cleanupFailures = await deactivateRuntimeStartAudio(
            request.audioActivation
        )
        if runtime === request.resources.runtime {
            runtime = nil
        }
        await finishStartFlight(request.resources.flight)
        return cleanupFailures
    }

    func deactivateRuntimeStartAudio(
        _ activation: LumenRuntimeAudioActivation
    ) async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        guard activation.wasActivated,
              let systemAudioPlaybackSuppression else {
            return []
        }
        activeSystemAudioIsActivated = false
        let cleanupFailures = await systemAudioPlaybackSuppression.deactivate()
        reportSystemAudioPlaybackSuppressionCleanupFailures(
            cleanupFailures,
            callbacks: activation.callbacks
        )
        activeSystemAudioIsActivated = !cleanupFailures.isEmpty
        return cleanupFailures
    }

}
