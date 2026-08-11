import Foundation
import OSLog

extension LumenBridgeRuntime {
    func preferredCaptureConfigurationImpl(
        displayID: UInt32
    ) -> LumenMacCaptureConfiguration {
        .panelNative(displayID: displayID)
    }

    func startCaptureImpl(
        configuration: LumenMacCaptureConfiguration
    ) async throws {
        try await startCapture(
            configuration: configuration,
            preconfiguredSystemAudio: nil,
            waitForStartupCompletion: true
        )
    }

    func startCaptureImpl(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startCapture(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio,
            waitForStartupCompletion: true
        )
    }

    func stopCaptureImpl() async {
        _ = await stopCapture(resetRequestGeneration: true)
    }

    func restartCaptureImpl(reason: String) async {
        guard let configuration = activeCaptureConfiguration else {
            logger.debug(
                """
                Ignoring ScreenCaptureKit capture restart because no capture session is active \
                reason=\(reason, privacy: .public)
                """
            )
            return
        }
        let preconfiguredSystemAudio = activePreconfiguredSystemAudio

        let now = DispatchTime.now().uptimeNanoseconds
        if lastRestartUptimeNanoseconds != 0 &&
            now - lastRestartUptimeNanoseconds < Self.captureRestartCooldownNanoseconds {
            logger.notice(
                """
                Suppressing ScreenCaptureKit capture restart because the cooldown is active \
                reason=\(reason, privacy: .public)
                """
            )
            return
        }

        lastRestartUptimeNanoseconds = now
        logger.notice(
            """
            Restarting ScreenCaptureKit capture to recover stale external encoded frames \
            reason=\(reason, privacy: .public)
            """
        )
        let cleanupFailures = await stopCapture(resetRequestGeneration: false)
        guard cleanupFailures.isEmpty else {
            return
        }
        try? await startCapture(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio,
            waitForStartupCompletion: false
        )
    }
}

private extension LumenBridgeRuntime {
    func startCapture(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?,
        waitForStartupCompletion: Bool
    ) async throws {
        let generations = try await prepareCaptureStart(
            preconfiguredSystemAudio: preconfiguredSystemAudio
        )
        await prepareVideoForwarding(configuration: configuration)

        let audioCallbacks = preparePreconfiguredSystemAudio(
            preconfiguredSystemAudio,
            generation: generations.audio
        )
        let session = makeEncodedCaptureSession(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio,
            audioCallbacks: audioCallbacks
        )
        let callbacks = makeEncodedCaptureCallbacks(
            captureGeneration: generations.capture
        )

        activeCaptureConfiguration = configuration
        unchangedContentCadenceWakeRelay.activate(
            sessionEpoch: configuration.sessionEpoch
        )
        activePreconfiguredSystemAudio = preconfiguredSystemAudio
        encodedCaptureSession = session
        publishStatusDidChange(immediate: true)

        let startupTask = makeCaptureStartupTask(
            session: session,
            callbacks: callbacks
        )
        encodedCaptureStartupTask = startupTask
        if waitForStartupCompletion {
            try await waitForCaptureStartup(startupTask)
        }
    }

    func prepareCaptureStart(
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?
    ) async throws -> (audio: UInt64, capture: UInt64) {
        if preconfiguredSystemAudio != nil {
            let cleanupFailures = await stopAudioCapture(
                resetRequestGeneration: false
            )
            guard cleanupFailures.isEmpty else {
                throw LumenSystemAudioCaptureLifecycleError(
                    underlyingError: LumenAudioCaptureError.captureStartCancelled,
                    cleanupFailures: cleanupFailures
                )
            }
        }

        let captureCleanupFailures = await stopCapture(
            resetRequestGeneration: false
        )
        guard captureCleanupFailures.isEmpty else {
            throw LumenSystemAudioCaptureLifecycleError(
                underlyingError: LumenAudioCaptureError
                    .systemAudioPlaybackSuppressionCleanupFailed(
                        captureCleanupFailures
                    ),
                cleanupFailures: captureCleanupFailures
            )
        }

        audioCaptureGeneration &+= 1
        let captureGeneration = await encodedFrameReadiness.beginCapture()
        activeCaptureGeneration = captureGeneration
        return (audioCaptureGeneration, captureGeneration)
    }

    func prepareVideoForwarding(
        configuration: LumenMacCaptureConfiguration
    ) async {
        let frameCapacity = Self.recommendedVideoForwardingFrameCapacity(
            for: configuration
        )
        videoForwarder.reset()
        videoForwarder.setFrameCapacity(frameCapacity)
        videoForwarder.setEventCapacity(Self.automaticVideoForwardingEventCapacity)
        videoForwarder.setProducerActive(false)
        await captureLifecycle.beginStartup()
        latestFrame = nil
        recentEvents = []
        resetEncodedFrameDiagnostics()

        logger.notice(
            """
            Starting ScreenCaptureKit capture \
            \(configuration.hdrConfigurationDebugSummary, privacy: .public) \
            forwarding-frame-capacity=\(frameCapacity, privacy: .public)
            """
        )
    }

    func preparePreconfiguredSystemAudio(
        _ configuration: LumenMacAudioCaptureConfiguration?,
        generation: UInt64
    ) -> LumenAudioCaptureCallbacks? {
        guard let configuration else {
            return nil
        }
        audioForwarder.reset()
        audioForwarder.setProducerActive(true)
        activeAudioCaptureConfiguration = configuration
        audioCaptureIsHostedByEncodedSession = true
        return makeAudioCaptureCallbacks(generation: generation)
    }

    func makeEncodedCaptureSession(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?,
        audioCallbacks: LumenAudioCaptureCallbacks?
    ) -> LumenEncodedCaptureSession {
        LumenEncodedCaptureSession(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio,
            preconfiguredSystemAudioCallbacks: audioCallbacks,
            systemAudioPlaybackSuppression: systemAudioPlaybackSuppression,
            runtimeFactory: encodedCaptureRuntimeFactory
        )
    }

    func makeEncodedCaptureCallbacks(
        captureGeneration: UInt64
    ) -> LumenEncodedCaptureCallbacks {
        let runtime = self
        let videoForwarder = self.videoForwarder
        return LumenEncodedCaptureCallbacks(
            frameHandler: { frame in
                let admission = videoForwarder.consume(frame: frame)
                Task {
                    if admission == .recoveryKeyFrameRequired {
                        await runtime.requestImmediateCaptureKeyFrame()
                    }
                    await runtime.recordEncodedFrame(
                        frame,
                        generation: captureGeneration
                    )
                }
            },
            eventHandler: { event in
                videoForwarder.consume(event: event)
                Task {
                    await runtime.recordEncodedCaptureEvent(event)
                }
            }
        )
    }

    func makeCaptureStartupTask(
        session: LumenEncodedCaptureSession,
        callbacks: LumenEncodedCaptureCallbacks
    ) -> Task<Void, Error> {
        let runtime = self
        return Task<Void, Error> {
            do {
                try await session.start(callbacks: callbacks)
                await runtime.handleEncodedCaptureStartupFinished(for: session)
            } catch {
                await runtime.handleEncodedCaptureStartupFailure(
                    for: session,
                    error: error
                )
                throw error
            }
        }
    }

    func waitForCaptureStartup(_ startupTask: Task<Void, Error>) async throws {
        do {
            try await startupTask.value
        } catch {
            if encodedCaptureStartupTask?.isCancelled == true {
                encodedCaptureStartupTask = nil
            }
            throw error
        }
    }

    func stopCapture(
        resetRequestGeneration _: Bool
    ) async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        encodedCaptureStartupTask?.cancel()
        encodedCaptureStartupTask = nil
        if let activeCaptureGeneration {
            await encodedFrameReadiness.stop(generation: activeCaptureGeneration)
            self.activeCaptureGeneration = nil
        }
        videoForwarder.setProducerActive(false)
        await captureLifecycle.beginStop()

        guard let session = encodedCaptureSession else {
            clearVideoCaptureState()
            await captureLifecycle.finishStop()
            clearEncodedSessionHostedAudioState()
            return []
        }

        let audioCleanupFailures = await session.stop()
        if audioCleanupFailures.isEmpty {
            encodedCaptureSession = nil
        }
        clearActiveCaptureConfiguration()
        await captureLifecycle.finishStop()
        handleCaptureAudioCleanupFailures(audioCleanupFailures)
        publishStatusDidChange(immediate: true)
        return audioCleanupFailures
    }

    func clearVideoCaptureState() {
        encodedCaptureSession = nil
        clearActiveCaptureConfiguration()
        latestFrame = nil
        recentEvents = []
    }

    func clearActiveCaptureConfiguration() {
        unchangedContentCadenceWakeRelay.deactivate()
        activeCaptureConfiguration = nil
        activePreconfiguredSystemAudio = nil
        resetEncodedFrameDiagnostics()
    }

    func resetEncodedFrameDiagnostics() {
        lastDiagnosticsUptimeNanoseconds = 0
        lastEncodedFrameSourceSequenceNumber = nil
        lastEncodedFrameSourceDisplayTime = nil
    }

    func handleCaptureAudioCleanupFailures(
        _ cleanupFailures: [LumenSystemAudioPlaybackSuppressionCleanupFailure]
    ) {
        if cleanupFailures.isEmpty {
            clearEncodedSessionHostedAudioState()
            return
        }

        recordAudioCaptureEvent(
            .init(
                kind: .failed,
                message: LumenAudioCaptureError
                    .systemAudioPlaybackSuppressionCleanupFailed(cleanupFailures)
                    .localizedDescription
            ),
            generation: audioCaptureGeneration,
            mediaEpoch: audioMediaEpochToken.load()
        )
        audioForwarder.setProducerActive(false)
    }

    func handleEncodedCaptureStartupFinished(
        for session: LumenEncodedCaptureSession
    ) async {
        guard encodedCaptureSession === session else {
            return
        }
        await captureLifecycle.finishStartup()
        guard encodedCaptureSession === session else {
            await captureLifecycle.finishStop()
            return
        }
        encodedCaptureStartupTask = nil
        videoForwarder.setProducerActive(true)
        publishStatusDidChange(immediate: true)
    }

    func handleEncodedCaptureStartupFailure(
        for session: LumenEncodedCaptureSession,
        error: Error
    ) async {
        guard encodedCaptureSession === session else {
            return
        }
        encodedCaptureStartupTask = nil
        let cleanupFailures = (error as? LumenSystemAudioCaptureLifecycleError)?
            .cleanupFailures ?? []
        if cleanupFailures.isEmpty {
            encodedCaptureSession = nil
        }
        clearActiveCaptureConfiguration()
        if let activeCaptureGeneration {
            await encodedFrameReadiness.stop(generation: activeCaptureGeneration)
            self.activeCaptureGeneration = nil
        }
        videoForwarder.setProducerActive(false)
        await captureLifecycle.failStartup()
        handleCaptureAudioCleanupFailures(cleanupFailures)
        latestFrame = nil
        recentEvents = []
        logger.error(
            """
            ScreenCaptureKit video startup failed: \
            \(String(describing: error), privacy: .public)
            """
        )
        publishStatusDidChange(immediate: true)
    }
}
