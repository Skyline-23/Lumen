import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

final class LumenAVCaptureSessionHandle: @unchecked Sendable {
    let session: AVCaptureSession
    let output: AVCaptureVideoDataOutput
    var runtimeErrorObserver: NSObjectProtocol?

    init(
        session: AVCaptureSession,
        output: AVCaptureVideoDataOutput
    ) {
        self.session = session
        self.output = output
    }
}

extension LumenScreenCaptureVideoRuntime {
    func startAVFoundationCapture() async throws {
        let displayID = configuration.displayID
        guard let displayMode = CGDisplayCopyDisplayMode(displayID) else {
            throw LumenScreenCaptureError
                .avFoundationDisplayModeUnavailable(displayID)
        }
        let sourceWidth = configuration.requestedWidth
            ?? displayMode.pixelWidth
        let sourceHeight = configuration.requestedHeight
            ?? displayMode.pixelHeight
        let prepared = try await prepareVideoCapture(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        guard let input = AVCaptureScreenInput(displayID: displayID) else {
            throw LumenScreenCaptureError
                .avFoundationScreenInputUnavailable(displayID)
        }
        input.minFrameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(
                configuration.effectiveTargetFrameRate
            )
        )
        input.capturesCursor = true

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                prepared.plan.pixelFormat,
            kCVPixelBufferWidthKey as String: prepared.width,
            kCVPixelBufferHeightKey as String: prepared.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            output.setSampleBufferDelegate(nil, queue: nil)
            throw LumenScreenCaptureError
                .avFoundationInputRejected(displayID)
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            output.setSampleBufferDelegate(nil, queue: nil)
            throw LumenScreenCaptureError.avFoundationOutputRejected
        }
        session.addOutput(output)
        session.commitConfiguration()

        let handle = LumenAVCaptureSessionHandle(
            session: session,
            output: output
        )
        handle.runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self, weak handle] notification in
            guard let self, let handle else {
                return
            }
            let description = (
                notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            )?.localizedDescription ?? "unknown runtime error"
            self.queue.async {
                guard self.avCaptureHandle === handle,
                      !self.stopping else {
                    return
                }
                let error = LumenScreenCaptureError
                    .avFoundationRuntimeFailed(description)
                self.statistics.isRunning = false
                self.statistics.processingFailureCount &+= 1
                self.statistics.lastErrorDescription =
                    error.localizedDescription
                self.refreshStatisticsNotes()
                self.statisticsHandler(self.statistics)
                self.eventHandler(.init(
                    kind: .failed,
                    message: error.localizedDescription
                ))
                self.terminationHandler(error)
            }
        }
        queue.sync {
            avCaptureHandle = handle
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        await withCheckedContinuation { continuation in
            captureControlQueue.async {
                handle.session.startRunning()
                continuation.resume()
            }
        }
        guard handle.session.isRunning else {
            await discardAVFoundationCapture(handle)
            throw LumenScreenCaptureError
                .avFoundationStartFailed(displayID)
        }

        let duration = Self.elapsedMilliseconds(since: startedAt)
        let stopRequested = queue.sync {
            streamStartDurationMilliseconds = duration
            return lifecycleStopRequested
        }
        let startMessage = [
            "stage=avfoundation-start-complete",
            "display-id=\(displayID)",
            "elapsed-ms=\(duration)",
            "target-fps=\(configuration.effectiveTargetFrameRate)"
        ].joined(separator: " ")
        Self.startupLogger.notice(
            "\(startMessage, privacy: .public)"
        )
        guard !stopRequested else {
            await discardAVFoundationCapture(handle)
            return
        }

        queue.sync {
            statistics.isRunning = true
            statistics.notes = makeStatisticsNotes(
                width: outputWidth,
                height: outputHeight
            )
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .started,
                message: [
                    "AVCaptureScreenInput capture started",
                    "display=\(displayID)",
                    "target-fps=\(configuration.effectiveTargetFrameRate)",
                    "stream-start-ms=\(duration)"
                ].joined(separator: " ")
            ))
        }
    }

    func discardAVFoundationCapture(
        _ handle: LumenAVCaptureSessionHandle
    ) async {
        await stopAVFoundationCaptureSession(handle)
        queue.sync {
            if avCaptureHandle === handle {
                avCaptureHandle = nil
            }
        }
    }

    func stopAVFoundationCaptureSession(
        _ handle: LumenAVCaptureSessionHandle
    ) async {
        await withCheckedContinuation { continuation in
            captureControlQueue.async {
                handle.output.setSampleBufferDelegate(nil, queue: nil)
                if let observer = handle.runtimeErrorObserver {
                    NotificationCenter.default.removeObserver(observer)
                    handle.runtimeErrorObserver = nil
                }
                if handle.session.isRunning {
                    handle.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }
}
