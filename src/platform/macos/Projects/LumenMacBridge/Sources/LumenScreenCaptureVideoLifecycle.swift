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

struct LumenRegisteredCaptureStream {
    let stream: SCStream
    let identity: UInt
}

struct LumenCaptureStartPublication {
    let stopRequested: Bool
    let displayAdmissionMode: String
    let displayAdmissionMilliseconds: Double
    let streamStartMilliseconds: Double
}

struct LumenPreparedVideoCapture {
    let width: Int
    let height: Int
    let plan: LumenVideoToolboxEncodingPlan
}

extension LumenScreenCaptureVideoRuntime {
    func start() async throws {
        guard beginLifecycleStart() else {
            throw LumenScreenCaptureError.captureAlreadyRunning
        }
        do {
            try await startCapture()
        } catch {
            await finishLifecycleStart()
            throw error
        }
        await finishLifecycleStart()
    }

    func startCapture() async throws {
        switch captureBackend {
        case .avFoundationScreenInput:
            try await startAVFoundationCapture()
            return
        case .skyLightDisplayStream:
            try await startSkyLightDisplayStreamCapture()
            return
        case .screenCaptureKit:
            break
        }

        let display = try await resolveCaptureDisplay()
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let streamConfiguration = try await prepareCaptureStreamConfiguration(
            for: display
        )
        Self.startupLogger.notice(
            "stage=stream-geometry display-id=\(display.displayID, privacy: .public) display-bounds=\(self.filterGeometryDescription(CGDisplayBounds(display.displayID)), privacy: .public) display-mode=\(self.displayModeGeometryDescription(display.displayID), privacy: .public) filter-content=\(self.filterGeometryDescription(filter.contentRect), privacy: .public) output=\(streamConfiguration.width, privacy: .public)x\(streamConfiguration.height, privacy: .public) explicit-scaling=true"
        )
        let registeredStream = try registerCaptureStream(
            filter: filter,
            configuration: streamConfiguration
        )
        guard try await startRegisteredCapture(
            registeredStream,
            configuration: streamConfiguration
        ) else {
            return
        }

        let publication = publishCaptureStart(
            streamIdentity: registeredStream.identity
        )
        guard !publication.stopRequested else {
            await discardRegisteredCapture(
                registeredStream,
                stopCapture: true
            )
            return
        }
        reportCaptureStarted(
            streamIdentity: registeredStream.identity,
            publication: publication
        )
    }

    func resolveCaptureDisplay() async throws -> SCDisplay {
        let displayID = configuration.displayID
        let admissionStart = DispatchTime.now().uptimeNanoseconds
        let admission: LumenScreenCaptureDisplayAdmissionResult<
            LumenScreenCaptureDisplayHandle
        >
        do {
            admission = try await LumenScreenCaptureDisplayAdmission.resolve(
                displayID: displayID,
                prefetched: {
                    try await LumenScreenCaptureDisplayPrefetch.resolve(
                        displayID: displayID
                    )
                },
                enumerateShareableContent: {
                    let owner = await LumenScreenCaptureDisplayPrefetch
                        .expectedOwner(displayID: displayID)
                    let handle = try await LumenScreenCaptureDisplayReadiness
                        .resolveProduction(displayID: displayID)
                    return LumenScreenCaptureDisplayAdmissionResult(
                        value: handle,
                        mode: owner == nil
                            ? .shareableContentEnumeration
                            : .retainedShareableContent
                    )
                }
            )
        } catch {
            logDisplayAdmissionFailure(
                error,
                displayID: displayID,
                startedAt: admissionStart
            )
            throw error
        }

        let duration = Self.elapsedMilliseconds(since: admissionStart)
        recordDisplayAdmission(
            admission,
            displayID: displayID,
            duration: duration
        )
        return admission.value.value
    }

    func recordDisplayAdmission(
        _ admission: LumenScreenCaptureDisplayAdmissionResult<
            LumenScreenCaptureDisplayHandle
        >,
        displayID: UInt32,
        duration: Double
    ) {
        queue.sync {
            displayAdmissionMode = admission.mode
            displayAdmissionDurationMilliseconds = duration
        }
        let message = [
            "stage=display-admission-complete",
            "display-id=\(displayID)",
            "mode=\(admission.mode.rawValue)",
            "elapsed-ms=\(duration)"
        ].joined(separator: " ")
        Self.startupLogger.notice("\(message, privacy: .public)")
    }

    func logDisplayAdmissionFailure(
        _ error: Error,
        displayID: UInt32,
        startedAt: UInt64
    ) {
        let message = [
            "stage=display-admission-failed",
            "display-id=\(displayID)",
            "elapsed-ms=\(Self.elapsedMilliseconds(since: startedAt))",
            "error=\(String(describing: error))"
        ].joined(separator: " ")
        Self.startupLogger.error("\(message, privacy: .public)")
    }

    func prepareCaptureStreamConfiguration(
        for display: SCDisplay
    ) async throws -> SCStreamConfiguration {
        let sourceWidth = configuration.requestedWidth ?? display.width
        let sourceHeight = configuration.requestedHeight ?? display.height
        let prepared = try await prepareVideoCapture(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        let streamConfiguration = LumenCaptureStreamConfigurationFactory.make(
            configuration: configuration
        )
        streamConfiguration.width = prepared.width
        streamConfiguration.height = prepared.height
        streamConfiguration.minimumFrameInterval =
            LumenScreenCaptureCadence.minimumFrameInterval(
                targetFrameRate: configuration.effectiveTargetFrameRate
            )
        streamConfiguration.queueDepth =
            configuration.negotiatedQueueProfile.queueDepthHint
        streamConfiguration.pixelFormat = prepared.plan.pixelFormat
        configureSDRColorSpaceIfNeeded(streamConfiguration)
        LumenScreenCaptureGeometry.applyFullDisplayMapping(
            to: streamConfiguration,
            sourceWidth: CGFloat(display.width),
            sourceHeight: CGFloat(display.height),
            outputWidth: prepared.width,
            outputHeight: prepared.height
        )
        return streamConfiguration
    }

    func filterGeometryDescription(_ rect: CGRect) -> String {
        "\(rect.origin.x),\(rect.origin.y),\(rect.width)x\(rect.height)"
    }

    func displayModeGeometryDescription(_ displayID: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return "missing"
        }
        return "logical=\(mode.width)x\(mode.height),pixel=\(mode.pixelWidth)x\(mode.pixelHeight),hz=\(mode.refreshRate)"
    }

    func prepareVideoCapture(
        sourceWidth: Int,
        sourceHeight: Int
    ) async throws -> LumenPreparedVideoCapture {
        let strategy = configuration.effectivePreprocessStrategy
        let width = strategy == .downscale2x
            ? max(sourceWidth / 2, 1)
            : sourceWidth
        let height = strategy == .downscale2x
            ? max(sourceHeight / 2, 1)
            : sourceHeight
        queue.sync {
            outputWidth = width
            outputHeight = height
        }

        let plan = try await resolveEncodingPlan()
        let captureContract = try LumenExactCaptureSourceContract(
            configuration: configuration,
            width: width,
            height: height
        )
        let encodedContract = try LumenExactEncodedOutputContract(
            configuration: configuration
        )
        queue.sync {
            encodingPlan = plan
            sourceContract = captureContract
            outputContract = encodedContract
        }

        try encoderQueue.sync {
            try createCompressionSession(width: width, height: height)
        }
        queue.sync {
            compressionSessionAvailable = true
            statistics.appliedVideoBitRateKbps =
                configuration.targetVideoBitRateKbps
        }
        return LumenPreparedVideoCapture(
            width: width,
            height: height,
            plan: plan
        )
    }

    func startSkyLightDisplayStreamCapture() async throws {
        let displayID = configuration.displayID
        let displayMode = CGDisplayCopyDisplayMode(displayID)
        let sourceWidth = configuration.requestedWidth ?? displayMode?.pixelWidth ?? 0
        let sourceHeight = configuration.requestedHeight ?? displayMode?.pixelHeight ?? 0
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw LumenScreenCaptureError
                .skyLightDisplayModeUnavailable(displayID)
        }

        let prepared = try await prepareVideoCapture(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        let requestedMatrix = configuration.encodedColorConfiguration.map {
            $0.yCbCrMatrix.imageBufferValue as String
        }
        let requestedColorSpace: String? = configuration.usesHDRTransport
            ? CGColorSpace.itur_2100_PQ as String
            : nil
        guard let stream = LumenSkyLightDisplayStream(
            displayID: displayID,
            outputWidth: prepared.width,
            outputHeight: prepared.height,
            pixelFormat: prepared.plan.pixelFormat,
            minimumFrameTime: 0,
            // Keep the private compositor queue shallow. Auto/q4 is useful
            // for SCK admission experiments but recreates the stale-surface
            // backlog that this raw path is meant to remove.
            queueDepth: min(
                configuration.negotiatedQueueProfile.queueDepthHint,
                2
            ),
            showCursor: true,
            yCbCrMatrix: requestedMatrix,
            dynamicRangeMode: configuration.usesHDRTransport ? 2 : 0,
            colorSpaceName: requestedColorSpace,
            callbackQueue: queue,
            frameHandler: { [weak self] status, displayTime, pixelBuffer, pixelBufferStatus in
                self?.processSkyLightFrame(
                    status: status,
                    displayTime: displayTime,
                    pixelBuffer: pixelBuffer,
                    pixelBufferStatus: pixelBufferStatus
                )
            }
        ) else {
            throw LumenScreenCaptureError.skyLightStartFailed(
                displayID,
                "Unable to create the raw SkyLight display stream."
            )
        }

        let streamIdentity = UInt(bitPattern: ObjectIdentifier(stream))
        queue.sync {
            skyLightDisplayStream = stream
            skyLightDisplayStreamIdentity = streamIdentity
            skyLightCaptureFailureReported = false
            skyLightStopStatus = nil
            skyLightFirstDisplayTime = nil
            skyLightLastPresentationTime = nil
            didLogSkyLightFirstFrame = false
            outputOwnership.registerScreenOutput(
                streamIdentity: streamIdentity
            )
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try stream.start()
        } catch {
            await discardSkyLightDisplayStream(stream, streamIdentity: streamIdentity)
            // Keep the private API's original NSError domain/code intact. The
            // caller needs the entitlement/TCC/format reason to classify this
            // fail-closed path; reducing it to a localized string loses that
            // evidence.
            throw error
        }

        let duration = Self.elapsedMilliseconds(since: startedAt)
        let stopRequested = queue.sync {
            streamStartDurationMilliseconds = duration
            return lifecycleStopRequested
        }
        Self.startupLogger.notice(
            "stage=skylight-stream-start-complete backend=\(stream.backendName, privacy: .public) display-id=\(displayID, privacy: .public) stream=\(streamIdentity, privacy: .public) output=\(prepared.width, privacy: .public)x\(prepared.height, privacy: .public) pixel-format=\(auditFourCC(prepared.plan.pixelFormat), privacy: .public) matrix=\(requestedMatrix ?? "unset", privacy: .public) target-fps=\(self.configuration.effectiveTargetFrameRate, privacy: .public) elapsed-ms=\(duration, privacy: .public)"
        )
        guard !stopRequested else {
            await discardSkyLightDisplayStream(stream, streamIdentity: streamIdentity)
            return
        }

        queue.sync {
            try? outputOwnership.markCaptureStarted(
                streamIdentity: streamIdentity
            )
            statistics.isRunning = true
            statistics.notes = makeStatisticsNotes(
                width: outputWidth,
                height: outputHeight
            )
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .started,
                message: skyLightCaptureStartedMessage(
                    stream: stream,
                    streamIdentity: streamIdentity,
                    startMilliseconds: duration,
                    requestedMatrix: requestedMatrix
                )
            ))
        }
    }

    func skyLightCaptureStartedMessage(
        stream: LumenSkyLightDisplayStream,
        streamIdentity: UInt,
        startMilliseconds: Double,
        requestedMatrix: String?
    ) -> String {
        [
            "SkyLight private display stream capture started",
            "private-content-stream=true",
            "backend=\(stream.backendName)",
            "content-stream-class=\(stream.contentStreamClassName ?? "unavailable")",
            "sharing-session-class=\(stream.contentStreamSessionClassName ?? "unavailable")",
            "underlying-cg-display-stream=\(stream.underlyingDisplayStreamAvailable)",
            "underlying-cg-display-stream-type-id=\(stream.underlyingDisplayStreamTypeID)",
            "stream=\(streamIdentity)",
            "output-registration=\(outputOwnership.stage.rawValue)",
            "output=\(outputWidth)x\(outputHeight)",
            "pixel-format=\(auditFourCC(capturePixelFormat))",
            "matrix=\(requestedMatrix ?? "unset")",
            "target-fps=\(configuration.effectiveTargetFrameRate)",
            "stream-start-ms=\(startMilliseconds)"
        ].joined(separator: " ")
    }

    func discardSkyLightDisplayStream(
        _ stream: LumenSkyLightDisplayStream,
        streamIdentity: UInt
    ) async {
        let stopStatus = stream.stop()
        queue.sync {
            skyLightStopStatus = stopStatus
            if skyLightDisplayStream === stream {
                skyLightDisplayStream = nil
                skyLightDisplayStreamIdentity = nil
            }
            skyLightFirstDisplayTime = nil
            skyLightLastPresentationTime = nil
            try? outputOwnership.stop(streamIdentity: streamIdentity)
        }
    }

    func configureSDRColorSpaceIfNeeded(
        _ streamConfiguration: SCStreamConfiguration
    ) {
        guard configuration.chromaSubsampling == .yuv444,
              configuration.dynamicRange == .sdr else {
            return
        }
        streamConfiguration.colorSpaceName = CGColorSpace.itur_709
        streamConfiguration.colorMatrix =
            kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }

    func registerCaptureStream(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) throws -> LumenRegisteredCaptureStream {
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: queue
        )
        let registered = LumenRegisteredCaptureStream(
            stream: stream,
            identity: Self.identity(of: stream)
        )
        queue.sync {
            self.stream = stream
            outputOwnership.registerScreenOutput(
                streamIdentity: registered.identity
            )
        }
        return registered
    }

    func startRegisteredCapture(
        _ registered: LumenRegisteredCaptureStream,
        configuration: SCStreamConfiguration
    ) async throws -> Bool {
        do {
            let streamStart = DispatchTime.now().uptimeNanoseconds
            try await registered.stream.startCapture()
            let duration = Self.elapsedMilliseconds(since: streamStart)
            let stopRequested = queue.sync {
                streamStartDurationMilliseconds = duration
                return lifecycleStopRequested
            }
            let message = [
                "stage=stream-start-complete",
                "display-id=\(self.configuration.displayID)",
                "stream=\(registered.identity)",
                "elapsed-ms=\(duration)",
                "source-queue-depth=\(configuration.queueDepth)"
            ].joined(separator: " ")
            Self.startupLogger.notice("\(message, privacy: .public)")
            guard !stopRequested else {
                await discardRegisteredCapture(
                    registered,
                    stopCapture: true
                )
                return false
            }
            return true
        } catch {
            await discardRegisteredCapture(
                registered,
                stopCapture: false
            )
            throw error
        }
    }

    func discardRegisteredCapture(
        _ registered: LumenRegisteredCaptureStream,
        stopCapture: Bool
    ) async {
        if stopCapture {
            try? await registered.stream.stopCapture()
        }
        try? registered.stream.removeStreamOutput(self, type: .screen)
        queue.sync {
            if self.stream === registered.stream {
                self.stream = nil
            }
            try? outputOwnership.stop(streamIdentity: registered.identity)
        }
    }

    func publishCaptureStart(
        streamIdentity: UInt
    ) -> LumenCaptureStartPublication {
        queue.sync {
            try? outputOwnership.markCaptureStarted(
                streamIdentity: streamIdentity
            )
            let stopRequested = lifecycleStopRequested
            if !stopRequested {
                statistics.isRunning = true
                statistics.notes = makeStatisticsNotes(
                    width: outputWidth,
                    height: outputHeight
                )
            }
            return LumenCaptureStartPublication(
                stopRequested: stopRequested,
                displayAdmissionMode: displayAdmissionMode.rawValue,
                displayAdmissionMilliseconds:
                    displayAdmissionDurationMilliseconds,
                streamStartMilliseconds: streamStartDurationMilliseconds
            )
        }
    }

    func reportCaptureStarted(
        streamIdentity: UInt,
        publication: LumenCaptureStartPublication
    ) {
        queue.sync {
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .started,
                message: captureStartedMessage(
                    streamIdentity: streamIdentity,
                    publication: publication
                )
            ))
        }
    }

    func captureStartedMessage(
        streamIdentity: UInt,
        publication: LumenCaptureStartPublication
    ) -> String {
        [
            "ScreenCaptureKit capture started",
            "stream=\(streamIdentity)",
            "output-registration=\(outputOwnership.stage.rawValue)",
            "display-admission=\(publication.displayAdmissionMode)",
            "display-admission-ms=\(publication.displayAdmissionMilliseconds)",
            "stream-start-ms=\(publication.streamStartMilliseconds)"
        ].joined(separator: " ")
    }

}
