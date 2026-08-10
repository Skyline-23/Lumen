import CoreMedia
import Foundation
import LumenEngineBridge
import OSLog

extension LumenBridgeRuntime {
    func captureSnapshotImpl() async -> LumenBridgeCaptureSnapshot? {
        guard let session = encodedCaptureSession,
              let configuration = activeCaptureConfiguration else {
            return nil
        }

        return LumenBridgeCaptureSnapshot(
            configuration: configuration,
            statistics: await session.statisticsSnapshot(),
            latestFrame: latestFrame,
            recentEvents: recentEvents,
            videoForwarding: videoForwarder.snapshot()
        )
    }

    nonisolated func videoForwardingSnapshotImpl() -> LumenBridgeVideoForwardingSnapshot {
        videoForwarder.snapshot()
    }

    func captureDiagnosticsStringImpl() async -> String {
        guard let session = encodedCaptureSession else {
            return "n/a"
        }

        return Self.captureDiagnosticsSnippet(
            from: await session.statisticsSnapshot(),
            configuration: activeCaptureConfiguration
        )
    }

    nonisolated func configureVideoForwardingImpl(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        videoForwarder.setFrameCapacity(frameCapacity)
        videoForwarder.setEventCapacity(eventCapacity)
    }

    nonisolated func configureAudioForwardingImpl(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        audioForwarder.setFrameCapacity(frameCapacity)
        audioForwarder.setEventCapacity(eventCapacity)
    }

    nonisolated func drainNextVideoForwardedFrameImpl() -> LumenBridgeDrainedVideoFrame? {
        videoForwarder.popNextFrame()
    }

    nonisolated func drainNextVideoForwardedEventImpl() -> LumenBridgeDrainedVideoEvent? {
        videoForwarder.popNextEvent()
    }

    nonisolated func audioForwardingSnapshotImpl() -> LumenBridgeAudioForwardingSnapshot {
        audioForwarder.snapshot()
    }

    nonisolated func drainNextVideoForwardedAudioFrameImpl() -> LumenBridgeDrainedAudioFrame? {
        audioForwarder.popNextFrame()
    }

    nonisolated func drainNextVideoForwardedAudioEventImpl() -> LumenBridgeDrainedAudioEvent? {
        audioForwarder.popNextEvent()
    }

    func statusSnapshotImpl() -> LumenBridgeStatus {
        let integrationStatus =
            "ScreenCaptureKit and VideoToolbox feed bounded Swift ingress queues " +
            "while Rust owns session, transport, packetization, and encryption."
        return LumenBridgeStatus(
            coreVersion: "Rust ABI \(LumenEngineBridgeABIVersion())",
            runtimeDescription: "Rust host with Swift macOS capture adapters",
            integrationStatus: integrationStatus,
            captureSessionRunning: encodedCaptureSession != nil,
            audioCaptureSessionRunning:
                audioCaptureSession != nil || audioCaptureIsHostedByEncodedSession,
            automaticCaptureOrchestrationRunning: false
        )
    }
}

extension LumenBridgeRuntime {
    func recordEncodedFrame(
        _ frame: LumenEncodedFrame,
        generation: UInt64
    ) async {
        guard activeCaptureGeneration == generation else {
            return
        }
        latestFrame = LumenBridgeEncodedFrameSnapshot(frame: frame)
        await encodedFrameReadiness.resolve(
            generation: generation,
            sequenceNumber: frame.sourceSequenceNumber
        )
        logEncodedFrameDiagnosticsIfNeeded(frame, captureStatistics: nil)
    }

    func recordEncodedCaptureEvent(
        _ event: LumenEncodedCaptureSessionEvent
    ) async {
        recentEvents.append(event)
        if recentEvents.count > 16 {
            recentEvents.removeFirst(recentEvents.count - 16)
        }
        let captureStatistics = await encodedCaptureSession?.statisticsSnapshot()
        let minimumLatency = formattedLatency(
            captureStatistics?.minOutputCallbackLatencyMilliseconds
        )
        let maximumLatency = formattedLatency(
            captureStatistics?.maxOutputCallbackLatencyMilliseconds
        )
        let captureDiagnostics = Self.captureDiagnosticsSnippet(
            from: captureStatistics,
            configuration: activeCaptureConfiguration
        )
        logger.notice(
            """
            Mac bridge capture event kind=\(event.kind.rawValue, privacy: .public) \
            message=\(event.message ?? "n/a", privacy: .public) \
            stop-status=\(event.stopStatus ?? 0, privacy: .public) \
            automatic-restarts=\(event.automaticRestartCount ?? 0, privacy: .public) \
            source-display-time=\(event.sourceDisplayTime ?? 0, privacy: .public) \
            capture-emitted=\(captureStatistics?.emittedFrameCount ?? 0, privacy: .public) \
            capture-dropped=\(captureStatistics?.droppedFrameCount ?? 0, privacy: .public) \
            capture-processing-failures=\(captureStatistics?.processingFailureCount ?? 0, privacy: .public) \
            capture-running=\(captureStatistics?.isRunning ?? false, privacy: .public) \
            capture-last-error=\(captureStatistics?.lastErrorDescription ?? "n/a", privacy: .public) \
            capture-min-callback-latency-ms=\(minimumLatency, privacy: .public) \
            capture-max-callback-latency-ms=\(maximumLatency, privacy: .public) \
            capture-vt=\(captureDiagnostics, privacy: .public)
            """
        )
        publishStatusDidChange()
    }

    func publishStatusDidChange(immediate: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let notificationElapsed =
            now - lastStatusNotificationUptimeNanoseconds
        if immediate ||
            notificationElapsed >= Self.statusNotificationCoalescingNanoseconds {
            hasPendingStatusNotification = false
            lastStatusNotificationUptimeNanoseconds = now
            Self.postStatusDidChangeNotificationAsync()
            return
        }

        guard !hasPendingStatusNotification else {
            return
        }

        hasPendingStatusNotification = true
        let delay =
            Self.statusNotificationCoalescingNanoseconds - notificationElapsed
        Task { [delay] in
            try? await Task.sleep(nanoseconds: delay)
            self.flushPendingStatusDidChange()
        }
    }
}

private extension LumenBridgeRuntime {
    func logEncodedFrameDiagnosticsIfNeeded(
        _ frame: LumenEncodedFrame,
        captureStatistics: LumenEncodedCaptureSessionStatistics?
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldLogAnomaly = lastEncodedFrameSourceDisplayTime
            .map { frame.sourceDisplayTime <= $0 } ?? false
        let shouldLogInterval =
            lastDiagnosticsUptimeNanoseconds == 0 ||
            now - lastDiagnosticsUptimeNanoseconds >= Self.diagnosticsIntervalNanoseconds

        if shouldLogAnomaly || shouldLogInterval {
            let sequenceDelta = encodedSequenceDelta(for: frame)
            let displayDeltaText = encodedDisplayDeltaText(for: frame)
            logEncodedFrameDiagnostics(
                frame,
                sequenceDelta: sequenceDelta,
                displayDeltaText: displayDeltaText,
                captureStatistics: captureStatistics
            )
            lastDiagnosticsUptimeNanoseconds = now
        }

        lastEncodedFrameSourceSequenceNumber = frame.sourceSequenceNumber
        lastEncodedFrameSourceDisplayTime = frame.sourceDisplayTime
    }

    func encodedSequenceDelta(for frame: LumenEncodedFrame) -> UInt64 {
        guard let previous = lastEncodedFrameSourceSequenceNumber,
              frame.sourceSequenceNumber >= previous else {
            return 0
        }
        return frame.sourceSequenceNumber - previous
    }

    func encodedDisplayDeltaText(for frame: LumenEncodedFrame) -> String {
        guard let previous = lastEncodedFrameSourceDisplayTime else {
            return "n/a"
        }
        let delta = frame.sourceDisplayTime >= previous
            ? frame.sourceDisplayTime - previous
            : 0
        return String(
            format: "%.3f",
            Self.displayTimeDeltaMilliseconds(delta)
        )
    }

    func logEncodedFrameDiagnostics(
        _ frame: LumenEncodedFrame,
        sequenceDelta: UInt64,
        displayDeltaText: String,
        captureStatistics: LumenEncodedCaptureSessionStatistics?
    ) {
        let configuration = activeCaptureConfiguration
        let targetWidth = configuration?.requestedWidth ?? 0
        let targetHeight = configuration?.requestedHeight ?? 0
        let targetFrameRate = configuration?.effectiveTargetFrameRate ?? 0
        let queueProfile = configuration?.queueProfile.rawValue ?? "unknown"
        let displayID = configuration?.displayID ?? 0
        let ingressSnapshot = videoForwarder.snapshot()
        let hdrValidation = frame.hdrValidationReport
        let diagnostics = makeCaptureLatencyDiagnostics(
            frame: frame,
            statistics: captureStatistics,
            configuration: configuration
        )

        logger.notice(
            """
            Mac bridge frame callback display-id=\(displayID, privacy: .public) \
            codec=\(frame.codec.rawValue, privacy: .public) \
            seq=\(frame.sourceSequenceNumber, privacy: .public) \
            seq-delta=\(sequenceDelta, privacy: .public) \
            display-time=\(frame.sourceDisplayTime, privacy: .public) \
            display-delta-ms=\(displayDeltaText, privacy: .public) \
            callback-latency-ms=\(diagnostics.callbackLatency, privacy: .public) \
            key=\(frame.isKeyFrame, privacy: .public) \
            hdr=\(frame.isHDRSignaled, privacy: .public) \
            hdr-primaries=\(hdrValidation.colorPrimaries ?? "n/a", privacy: .public) \
            hdr-transfer=\(hdrValidation.transferFunction ?? "n/a", privacy: .public) \
            hdr-matrix=\(hdrValidation.yCbCrMatrix ?? "n/a", privacy: .public) \
            hdr-mastering=\(hdrValidation.hasHDRDisplayMetadata, privacy: .public) \
            hdr-cll=\(hdrValidation.hasContentLightLevelInfo, privacy: .public) \
            target-fps=\(targetFrameRate, privacy: .public) \
            target-size=\(targetWidth, privacy: .public)x\(targetHeight, privacy: .public) \
            queue=\(queueProfile, privacy: .public) \
            capture-emitted=\(captureStatistics?.emittedFrameCount ?? 0, privacy: .public) \
            capture-dropped=\(captureStatistics?.droppedFrameCount ?? 0, privacy: .public) \
            capture-processing-failures=\(captureStatistics?.processingFailureCount ?? 0, privacy: .public) \
            capture-restarts=\(captureStatistics?.automaticRestartCount ?? 0, privacy: .public) \
            capture-running=\(captureStatistics?.isRunning ?? false, privacy: .public) \
            capture-last-error=\(diagnostics.lastError, privacy: .public) \
            capture-min-callback-latency-ms=\(diagnostics.minimumLatency, privacy: .public) \
            capture-max-callback-latency-ms=\(diagnostics.maximumLatency, privacy: .public) \
            capture-vt=\(diagnostics.details, privacy: .public) \
            core-frame-count=\(ingressSnapshot.frameCount, privacy: .public) \
            core-queued=\(ingressSnapshot.queuedFrameCount, privacy: .public) \
            core-dropped=\(ingressSnapshot.droppedFrameCount, privacy: .public) \
            core-last-seq=\(ingressSnapshot.lastFrameSourceSequenceNumber ?? 0, privacy: .public)
            """
        )
    }

    func makeCaptureLatencyDiagnostics(
        frame: LumenEncodedFrame,
        statistics: LumenEncodedCaptureSessionStatistics?,
        configuration: LumenMacCaptureConfiguration?
    ) -> LumenCaptureLatencyDiagnostics {
        LumenCaptureLatencyDiagnostics(
            callbackLatency:
                formattedLatency(frame.outputCallbackLatencyMilliseconds),
            lastError: statistics?.lastErrorDescription ?? "n/a",
            minimumLatency: formattedLatency(
                statistics?.minOutputCallbackLatencyMilliseconds
            ),
            maximumLatency: formattedLatency(
                statistics?.maxOutputCallbackLatencyMilliseconds
            ),
            details: Self.captureDiagnosticsSnippet(
                from: statistics,
                configuration: configuration
            )
        )
    }

    func formattedLatency(_ value: Double?) -> String {
        guard let value else {
            return "n/a"
        }
        return String(format: "%.3f", value)
    }

    nonisolated static func captureDiagnosticsSnippet(
        from statistics: LumenEncodedCaptureSessionStatistics?,
        configuration _: LumenMacCaptureConfiguration? = nil
    ) -> String {
        guard let statistics else {
            return "n/a"
        }
        let notes = statistics.notes.filter { note in
            lumenCaptureDiagnosticPrefixes.contains { note.hasPrefix($0) }
        }
        guard !notes.isEmpty else {
            return "n/a"
        }
        return notes.joined(separator: ";")
    }

    func flushPendingStatusDidChange() {
        guard hasPendingStatusNotification else {
            return
        }

        hasPendingStatusNotification = false
        lastStatusNotificationUptimeNanoseconds =
            DispatchTime.now().uptimeNanoseconds
        Self.postStatusDidChangeNotificationAsync()
    }
}

extension LumenBridgeRuntime {
    func debugResetVideoForwarding() {
        videoForwarder.reset()
    }

    func debugSetVideoForwardingCapacities(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        configureVideoForwarding(
            frameCapacity: frameCapacity,
            eventCapacity: eventCapacity
        )
    }

    func debugForwardSyntheticFrame(
        sampleBuffer: CMSampleBuffer,
        codec: LumenCaptureCodec = .hevc,
        sourceSequenceNumber: UInt64 = 1,
        sourceDisplayTime: UInt64 = 1,
        outputCallbackLatencyMilliseconds: Double? = nil,
        isKeyFrame: Bool = true,
        requiresBootstrapAcknowledgement: Bool = false,
        isRepairKeyFrame: Bool = false,
        isHDRSignaled: Bool = false
    ) {
        videoForwarder.consume(
            sampleBuffer: sampleBuffer,
            codec: codec,
            sourceSequenceNumber: sourceSequenceNumber,
            sourceDisplayTime: sourceDisplayTime,
            outputCallbackLatencyMilliseconds:
                outputCallbackLatencyMilliseconds,
            isKeyFrame: isKeyFrame,
            requiresBootstrapAcknowledgement:
                requiresBootstrapAcknowledgement,
            isRepairKeyFrame: isRepairKeyFrame,
            isHDRSignaled: isHDRSignaled
        )
    }

    func debugForwardSyntheticEvent(
        kind: LumenEncodedCaptureSessionEventKind,
        message: String? = nil,
        stopStatus: Int32? = nil,
        automaticRestartCount: UInt64? = nil,
        sourceDisplayTime: UInt64? = nil
    ) {
        let event = LumenEncodedCaptureSessionEvent(
            kind: kind,
            message: message,
            stopStatus: stopStatus,
            automaticRestartCount: automaticRestartCount,
            sourceDisplayTime: sourceDisplayTime
        )
        videoForwarder.consume(event: event)
    }

    func debugDrainNextForwardedFrame() -> LumenBridgeDrainedVideoFrame? {
        drainNextVideoForwardedFrame()
    }

    func debugDrainNextForwardedEvent() -> LumenBridgeDrainedVideoEvent? {
        drainNextVideoForwardedEvent()
    }
}
