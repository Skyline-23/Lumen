import OSLog

extension LumenBridgeRuntime {
    func waitForFirstEncodedFrameImpl(timeoutNanoseconds: UInt64) async throws {
        guard let activeCaptureGeneration else {
            throw LumenFirstEncodedFrameReadinessError.captureNotRunning
        }
        try await encodedFrameReadiness.wait(
            for: activeCaptureGeneration,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func currentEncodedFrameSequenceNumberImpl() -> UInt64? {
        latestFrame?.sourceSequenceNumber
    }

    func waitForEncodedFrameImpl(
        after sequenceNumber: UInt64,
        timeoutNanoseconds: UInt64
    ) async throws {
        guard let activeCaptureGeneration else {
            throw LumenFirstEncodedFrameReadinessError.captureNotRunning
        }
        try await encodedFrameReadiness.wait(
            for: activeCaptureGeneration,
            after: sequenceNumber,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func verifyEncodedFrameContinuityImpl(
        timeoutNanoseconds: UInt64
    ) async throws {
        guard let sequenceNumber = latestFrame?.sourceSequenceNumber else {
            try await waitForFirstEncodedFrame(
                timeoutNanoseconds: timeoutNanoseconds
            )
            return
        }
        try await waitForEncodedFrame(
            after: sequenceNumber,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func requestImmediateCaptureKeyFrameImpl() async {
        guard await captureLifecycle.shouldRequestImmediateKeyFrame else {
            logger.debug(
                "Ignoring immediate keyframe request because ScreenCaptureKit capture is not running"
            )
            return
        }

        guard let encodedCaptureSession else {
            logger.debug(
                "Ignoring immediate keyframe request because no ScreenCaptureKit capture session is active"
            )
            return
        }

        logger.notice(
            "Requesting an immediate ScreenCaptureKit keyframe for external encoded capture resync"
        )
        await encodedCaptureSession.requestImmediateKeyFrame()
    }

    func requestPeriodicCaptureKeyFrameImpl() async -> Bool {
        guard await captureLifecycle.shouldRequestImmediateKeyFrame else {
            logger.debug(
                "Ignoring periodic ScreenCaptureKit keyframe request because capture is not running"
            )
            return false
        }

        guard let encodedCaptureSession else {
            logger.debug(
                "Ignoring periodic ScreenCaptureKit keyframe request because no capture session is active"
            )
            return false
        }

        let armed = await encodedCaptureSession.requestPeriodicKeyFrame()
        if !armed {
            logger.debug(
                "Periodic ScreenCaptureKit keyframe request was coalesced by the bootstrap gate"
            )
        }
        return armed
    }

    func resumeVideoEncodingAfterCodecAckImpl() async -> Bool {
        guard await captureLifecycle.shouldRequestImmediateKeyFrame,
              let encodedCaptureSession else {
            logger.error(
                "Rejecting codec acknowledgement because ScreenCaptureKit capture is not running"
            )
            return false
        }
        let resumed = await encodedCaptureSession.resumeVideoEncodingAfterCodecAck()
        if resumed {
            logger.notice(
                "Resumed VideoToolbox encoding after codec configuration acknowledgement"
            )
        } else {
            logger.error(
                "Codec acknowledgement did not match a paused VideoToolbox admission boundary"
            )
        }
        return resumed
    }

    func setVideoBitRateKbpsImpl(_ bitrateKbps: Int) async -> Bool {
        guard bitrateKbps > 0,
              await captureLifecycle.shouldRequestImmediateKeyFrame,
              let encodedCaptureSession else {
            logger.error(
                "Rejecting adaptive bitrate because ScreenCaptureKit capture is not running"
            )
            return false
        }
        let applied = await encodedCaptureSession.setVideoBitRateKbps(
            bitrateKbps
        )
        if applied {
            logger.debug(
                "Applied adaptive VideoToolbox bitrate \(bitrateKbps, privacy: .public) kbps"
            )
        } else {
            logger.error(
                "VideoToolbox rejected adaptive bitrate \(bitrateKbps, privacy: .public) kbps"
            )
        }
        return applied
    }

    func setVideoDeliveryPolicyImpl(
        sessionEpoch: UInt32,
        policyRevision: UInt32,
        bitrateKbps: Int,
        admissionDivisor: Int
    ) async -> Bool {
        guard bitrateKbps > 0,
              (1 ... 4).contains(admissionDivisor),
              await captureLifecycle.shouldRequestImmediateKeyFrame else {
            logger.error(
                "Rejecting adaptive delivery policy because ScreenCaptureKit capture is not running"
            )
            return false
        }
        guard let configuration = activeCaptureConfiguration,
              configuration.sessionEpoch == sessionEpoch,
              configuration.policyRevision == policyRevision,
              let session = encodedCaptureSession else {
            logger.notice(
                "Rejecting stale adaptive delivery policy session-epoch=\(sessionEpoch, privacy: .public) policy-revision=\(policyRevision, privacy: .public)"
            )
            return false
        }
        return await session.setVideoDeliveryPolicy(
            bitrateKbps: bitrateKbps,
            admissionDivisor: admissionDivisor
        )
    }

    func wakeUnchangedContentCadenceImpl(
        sessionEpoch: UInt32,
        expectedRelayGeneration: UInt64? = nil
    ) async -> Bool {
        guard await captureLifecycle.shouldRequestImmediateKeyFrame else {
            return false
        }
        if let expectedRelayGeneration,
           !unchangedContentCadenceWakeRelay.isActive(
               generation: expectedRelayGeneration,
               sessionEpoch: sessionEpoch
           ) {
            return false
        }
        guard
              let configuration = activeCaptureConfiguration,
              configuration.sessionEpoch == sessionEpoch,
              let encodedCaptureSession else {
            logger.notice(
                "Rejecting stale unchanged-content cadence wake session-epoch=\(sessionEpoch, privacy: .public)"
            )
            return false
        }
        return await encodedCaptureSession.wakeUnchangedContentCadence(
            sessionEpoch: sessionEpoch
        )
    }
}
