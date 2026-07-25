import Foundation
import OSLog

extension LumenBridgeRuntime {
    func makeDefaultMicrophoneAudioConfigurationImpl() -> LumenMacAudioCaptureConfiguration {
        .microphone()
    }

    func makeSystemOutputAudioConfigurationImpl(
        displayID: UInt32
    ) -> LumenMacAudioCaptureConfiguration {
        .systemOutput(displayID: displayID)
    }

    func startAudioCaptureImpl(
        configuration: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startAudioCapture(
            configuration: configuration,
            waitForStartupCompletion: true
        )
    }

    func startAudioCaptureAsynchronouslyImpl(
        configuration: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startAudioCapture(
            configuration: configuration,
            waitForStartupCompletion: false
        )
    }

    func stopAudioCaptureImpl() async {
        _ = await stopAudioCapture(resetRequestGeneration: true)
    }
}

extension LumenBridgeRuntime {
    func makeAudioCaptureCallbacks(
        generation: UInt64
    ) -> LumenAudioCaptureCallbacks {
        let runtime = self
        return LumenAudioCaptureCallbacks(
            frameHandler: { frame in
                Task {
                    await runtime.recordAudioFrame(
                        frame,
                        generation: generation
                    )
                }
            },
            eventHandler: { event in
                Task {
                    await runtime.recordAudioCaptureEvent(
                        event,
                        generation: generation
                    )
                }
            }
        )
    }

    func stopAudioCapture(
        resetRequestGeneration _: Bool
    ) async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        audioCaptureGeneration &+= 1
        audioCaptureStartupTask?.cancel()
        audioCaptureStartupTask = nil
        if audioCaptureIsHostedByEncodedSession {
            return await stopEncodedSessionHostedAudio()
        }
        guard let session = audioCaptureSession else {
            clearStandaloneAudioCaptureState()
            return []
        }
        return await stopStandaloneAudioCapture(session)
    }

    func clearEncodedSessionHostedAudioState() {
        guard audioCaptureIsHostedByEncodedSession else {
            return
        }
        audioCaptureIsHostedByEncodedSession = false
        activeAudioCaptureConfiguration = nil
        audioForwarder.setProducerActive(false)
        audioForwarder.reset()
    }

    func recordAudioCaptureEvent(
        _ event: LumenAudioCaptureSessionEvent,
        generation: UInt64
    ) {
        guard generation == audioCaptureGeneration,
              audioCaptureSession != nil || audioCaptureIsHostedByEncodedSession else {
            return
        }
        audioForwarder.consume(event: event)
        logger.notice(
            """
            Mac bridge audio capture event kind=\(event.kind.rawValue, privacy: .public) \
            message=\(event.message ?? "n/a", privacy: .public) \
            automatic-restarts=\(event.automaticRestartCount ?? 0, privacy: .public) \
            source-sequence=\(event.sourceSequenceNumber ?? 0, privacy: .public)
            """
        )
        publishStatusDidChange()
    }
}

private extension LumenBridgeRuntime {
    func startAudioCapture(
        configuration: LumenMacAudioCaptureConfiguration,
        waitForStartupCompletion: Bool
    ) async throws {
        let previousCleanupFailures = await stopAudioCapture(
            resetRequestGeneration: false
        )
        guard previousCleanupFailures.isEmpty else {
            throw LumenSystemAudioCaptureLifecycleError(
                underlyingError: LumenAudioCaptureError.captureStartCancelled,
                cleanupFailures: previousCleanupFailures
            )
        }

        audioCaptureGeneration &+= 1
        let session = try makeAudioCaptureSession(configuration: configuration)
        let callbacks = makeAudioCaptureCallbacks(
            generation: audioCaptureGeneration
        )
        activeAudioCaptureConfiguration = configuration
        audioCaptureSession = session
        audioForwarder.setProducerActive(true)
        publishStatusDidChange(immediate: true)

        let startupTask = makeAudioCaptureStartupTask(
            session: session,
            callbacks: callbacks
        )
        audioCaptureStartupTask = startupTask
        if waitForStartupCompletion {
            try await waitForAudioCaptureStartup(startupTask)
        }
    }

    func makeAudioCaptureSession(
        configuration: LumenMacAudioCaptureConfiguration
    ) throws -> LumenAudioCaptureSession {
        audioForwarder.reset()
        audioForwarder.setProducerActive(false)
        let activeVideoDisplayID = encodedCaptureSession == nil
            ? nil
            : activeCaptureConfiguration?.displayID
        let audioRoute = try LumenSystemAudioCaptureRoute.resolve(
            configuration: configuration,
            activeVideoDisplayID: activeVideoDisplayID
        )
        let sharedVideoSession: LumenEncodedCaptureSession? = switch audioRoute {
        case .sharedVideoStream:
            encodedCaptureSession
        case .standaloneStream:
            nil
        }

        logger.notice(
            """
            Starting audio capture source=\(configuration.source.kind.rawValue, privacy: .public) \
            route=\(String(describing: audioRoute), privacy: .public) \
            sample-rate=\(configuration.sampleRate, privacy: .public) \
            channels=\(configuration.channelCount, privacy: .public) \
            frame-size=\(configuration.frameSize, privacy: .public)
            """
        )
        return LumenAudioCaptureSession(
            configuration: configuration,
            sharedVideoSession: sharedVideoSession,
            systemAudioPlaybackSuppression: systemAudioPlaybackSuppression
        )
    }

    func makeAudioCaptureStartupTask(
        session: LumenAudioCaptureSession,
        callbacks: LumenAudioCaptureCallbacks
    ) -> Task<Void, Error> {
        let runtime = self
        return Task<Void, Error> {
            do {
                try await session.start(callbacks: callbacks)
                await runtime.handleAudioCaptureStartupFinished(for: session)
            } catch {
                await runtime.handleAudioCaptureStartupFailure(
                    for: session,
                    error: error
                )
                throw error
            }
        }
    }

    func waitForAudioCaptureStartup(
        _ startupTask: Task<Void, Error>
    ) async throws {
        do {
            try await startupTask.value
        } catch {
            if audioCaptureStartupTask?.isCancelled == true {
                audioCaptureStartupTask = nil
            }
            throw error
        }
    }

    func stopEncodedSessionHostedAudio() async
        -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        let cleanupFailures = await encodedCaptureSession?
            .detachSystemAudio() ?? []
        if cleanupFailures.isEmpty {
            clearEncodedSessionHostedAudioState()
        } else {
            recordAudioCleanupFailures(cleanupFailures)
        }
        publishStatusDidChange(immediate: true)
        return cleanupFailures
    }

    func stopStandaloneAudioCapture(
        _ session: LumenAudioCaptureSession
    ) async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        let cleanupFailures = await session.stop()
        if cleanupFailures.isEmpty {
            audioCaptureSession = nil
            activeAudioCaptureConfiguration = nil
        } else {
            recordAudioCleanupFailures(cleanupFailures)
        }
        audioForwarder.setProducerActive(false)
        publishStatusDidChange(immediate: true)
        return cleanupFailures
    }

    func clearStandaloneAudioCaptureState() {
        audioCaptureSession = nil
        activeAudioCaptureConfiguration = nil
        audioForwarder.reset()
        audioForwarder.setProducerActive(false)
    }

    func recordAudioCleanupFailures(
        _ cleanupFailures: [LumenSystemAudioPlaybackSuppressionCleanupFailure]
    ) {
        recordAudioCaptureEvent(
            .init(
                kind: .failed,
                message: LumenAudioCaptureError
                    .systemAudioPlaybackSuppressionCleanupFailed(cleanupFailures)
                    .localizedDescription
            ),
            generation: audioCaptureGeneration
        )
        audioForwarder.setProducerActive(false)
    }

    func handleAudioCaptureStartupFinished(
        for session: LumenAudioCaptureSession
    ) {
        guard audioCaptureSession === session else {
            return
        }
        audioCaptureStartupTask = nil
    }

    func handleAudioCaptureStartupFailure(
        for session: LumenAudioCaptureSession,
        error: Error
    ) {
        guard audioCaptureSession === session else {
            return
        }
        audioCaptureStartupTask = nil
        let cleanupFailures = (error as? LumenSystemAudioCaptureLifecycleError)?
            .cleanupFailures ?? []
        recordAudioCaptureEvent(
            .init(
                kind: .failed,
                message: error.localizedDescription
            ),
            generation: audioCaptureGeneration
        )
        if cleanupFailures.isEmpty {
            audioCaptureSession = nil
            activeAudioCaptureConfiguration = nil
        }
        audioForwarder.setProducerActive(false)
        logger.error(
            """
            Audio capture startup failed: \
            \(String(describing: error), privacy: .public)
            """
        )
        publishStatusDidChange(immediate: true)
    }

    func recordAudioFrame(
        _ frame: LumenAudioFrame,
        generation: UInt64
    ) {
        guard generation == audioCaptureGeneration,
              audioCaptureSession != nil || audioCaptureIsHostedByEncodedSession else {
            return
        }
        audioForwarder.consume(frame: frame)
        publishStatusDidChange()
    }
}
