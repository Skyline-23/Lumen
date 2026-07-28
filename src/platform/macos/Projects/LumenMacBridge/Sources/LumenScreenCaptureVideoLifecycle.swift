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
        let display = try await resolveCaptureDisplay()
        let streamConfiguration = try await prepareCaptureStreamConfiguration(
            for: display
        )
        let registeredStream = try registerCaptureStream(
            display: display,
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

        let streamConfiguration = LumenCaptureStreamConfigurationFactory.make(
            configuration: configuration
        )
        streamConfiguration.width = width
        streamConfiguration.height = height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.effectiveTargetFrameRate)
        )
        streamConfiguration.queueDepth =
            configuration.negotiatedQueueProfile.queueDepthHint
        streamConfiguration.pixelFormat = plan.pixelFormat
        configureSDRColorSpaceIfNeeded(streamConfiguration)
        streamConfiguration.scalesToFit = false
        streamConfiguration.preservesAspectRatio = true
        try encoderQueue.sync {
            try createCompressionSession(width: width, height: height)
        }
        queue.sync {
            compressionSessionAvailable = true
        }
        return streamConfiguration
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
        display: SCDisplay,
        configuration: SCStreamConfiguration
    ) throws -> LumenRegisteredCaptureStream {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
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
