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

extension LumenScreenCaptureVideoRuntime {
    func stop() async {
        await prepareCaptureStop()
        let stoppedStreamIdentity = await stopActiveCaptureStream()
        await completeCaptureOutputLifecycle()
        finishCaptureStop(stoppedStreamIdentity: stoppedStreamIdentity)
    }

    func prepareCaptureStop() async {
        let startWasInFlight = queue.sync {
            lifecycleStopRequested = true
            return lifecycleStartInFlight
        }
        if startWasInFlight {
            await waitForLifecycleStart()
        }
        queue.sync {
            stopping = true
            compressionSessionAvailable = false
            pendingVideoBootstrapSource = nil
            encoderAdmission.beginStopping()
        }
        encoderAdmission.waitUntilSubmissionReturns()
    }

    func stopActiveCaptureStream() async -> UInt? {
        let streamToStop = queue.sync { () -> SCStream? in
            let stream = self.stream
            self.stream = nil
            return stream
        }
        guard let stream = streamToStop else {
            return nil
        }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
        let streamIdentity = Self.identity(of: stream)
        queue.sync {
            try? outputOwnership.stop(streamIdentity: streamIdentity)
        }
        return streamIdentity
    }

    func completeCaptureOutputLifecycle() async {
        await outputLifecycle.completeAndInvalidate(
            completeFrames: { [self] in
                encoderQueue.sync {
                    completeCompressionFrames()
                }
            },
            invalidate: { [self] in
                encoderQueue.sync {
                    invalidateCompressionSession()
                }
            },
            completionFailure: { [self] status, cancelledContexts in
                queue.sync {
                    reportCompressionFrameCompletionFailure(
                        status: status,
                        cancelledContexts: cancelledContexts
                    )
                }
            }
        )
    }

    func finishCaptureStop(stoppedStreamIdentity: UInt?) {
        guard stoppedStreamIdentity != nil else {
            queue.sync {
                lifecycleStopRequested = false
            }
            return
        }
        queue.sync {
            statistics.isRunning = false
            refreshStatisticsNotes()
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .stopped,
                message: [
                    "ScreenCaptureKit capture stopped",
                    "output-registration=\(outputOwnership.stage.rawValue)",
                    "source-samples=\(outputOwnership.screenSampleCount)"
                ].joined(separator: " "),
                stopStatus: 0
            ))
            lifecycleStopRequested = false
        }
    }

    func beginLifecycleStart() -> Bool {
        queue.sync {
            guard !lifecycleStartInFlight,
                  !lifecycleStopRequested,
                  stream == nil else {
                return false
            }
            lifecycleStartInFlight = true
            stopping = false
            return true
        }
    }

    func finishLifecycleStart() async {
        let waiters = queue.sync { () -> [CheckedContinuation<Void, Never>] in
            lifecycleStartInFlight = false
            let waiters = lifecycleSettlementWaiters
            lifecycleSettlementWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func waitForLifecycleStart() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.lifecycleStartInFlight {
                    self.lifecycleSettlementWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func requestImmediateKeyFrame() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.videoBootstrapAdmission.beginBootstrapGeneration() {
                self.pendingVideoBootstrapSource = nil
            }
        }
    }

    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self,
                      !self.stopping,
                      self.videoBootstrapAdmission
                        .acknowledgeConfiguration() else {
                    continuation.resume(returning: false)
                    return
                }
                let pendingSource = self.pendingVideoBootstrapSource
                self.pendingVideoBootstrapSource = nil
                if let pendingSource {
                    self.submitSource(pendingSource, forceKeyFrame: false)
                }
                let message = [
                    "VideoToolbox encoding resumed after codec acknowledgement",
                    "coalesced-source=\(pendingSource != nil)"
                ].joined(separator: " ")
                self.eventHandler(.init(
                    kind: .started,
                    message: message
                ))
                continuation.resume(returning: true)
            }
        }
    }
}
