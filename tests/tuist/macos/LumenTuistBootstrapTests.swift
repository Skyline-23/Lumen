@testable import LumenMacBridge
import CoreMedia
import Dispatch
import XCTest
final class LumenCapturePipelineTests: XCTestCase {
    func testCaptureIngressTimingsExposeWindowServerCadenceAndCallbackDelay() throws {
        var timings = LumenCaptureIngressTimings()
        let firstDisplay = try XCTUnwrap(
            LumenMachTime.ticks(for: CMTime(seconds: 1, preferredTimescale: 120_000))
        )
        let frameInterval = try XCTUnwrap(
            LumenMachTime.ticks(for: CMTime(value: 1, timescale: 120))
        )
        let callbackDelay = try XCTUnwrap(
            LumenMachTime.ticks(for: CMTime(value: 2, timescale: 1_000))
        )

        timings.observe(
            displayedMachTime: firstDisplay,
            callbackMachTime: firstDisplay + callbackDelay
        )
        timings.observe(
            displayedMachTime: firstDisplay + frameInterval,
            callbackMachTime: firstDisplay + frameInterval + callbackDelay
        )
        timings.observe(
            displayedMachTime: firstDisplay,
            callbackMachTime: firstDisplay + (2 * frameInterval) + callbackDelay
        )

        XCTAssertEqual(timings.displayInterval.sampleCount, 1)
        XCTAssertEqual(timings.displayToCallback.sampleCount, 3)
        XCTAssertTrue(
            timings.diagnosticNotes.contains("sourceDisplayApproxFrameRate=120.00")
        )
        XCTAssertTrue(
            timings.diagnosticNotes.contains("sourceDisplayIntervalSampleCount=1")
        )
        XCTAssertTrue(
            timings.diagnosticNotes.contains("sourceDisplayToCallbackSampleCount=3")
        )
    }

    func testBootstrapGateSubmitsOneKeyFrameThenCoalescesUntilDecoded() {
        var gate = LumenVideoBootstrapAdmissionGate()

        XCTAssertEqual(gate.admitSourceFrame(), .submitInitialKeyFrame)
        XCTAssertEqual(gate.admitSourceFrame(), .coalesceUntilAcknowledged)
        XCTAssertEqual(gate.admitSourceFrame(), .coalesceUntilAcknowledged)
        XCTAssertTrue(gate.isAwaitingAcknowledgement)
        XCTAssertFalse(gate.isOpen)

        XCTAssertTrue(gate.acknowledgeConfiguration())
        XCTAssertFalse(gate.isAwaitingAcknowledgement)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.admitSourceFrame(), .submit)
        XCTAssertFalse(gate.acknowledgeConfiguration())

        XCTAssertTrue(gate.beginBootstrapGeneration())
        XCTAssertFalse(gate.beginBootstrapGeneration())
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(gate.isAwaitingAcknowledgement)
        XCTAssertEqual(gate.admitSourceFrame(), .submitInitialKeyFrame)
        gate.cancelBootstrapSubmission()
        XCTAssertFalse(gate.isAwaitingAcknowledgement)
        XCTAssertEqual(gate.admitSourceFrame(), .submitInitialKeyFrame)
    }

    func testSerialEncoderAdmissionPreservesInvocationOrderAndKeepsLatestPendingSource() {
        let sourceQueue = DispatchQueue(
            label: "dev.skyline23.lumen.tests.sck-source",
            qos: .userInteractive
        )
        let submissionQueue = DispatchQueue(
            label: "dev.skyline23.lumen.tests.vt-submission",
            qos: .userInteractive,
            attributes: .concurrent
        )
        let firstSubmissionPassedHandshake = DispatchSemaphore(value: 0)
        let allowFirstActualInvocation = DispatchSemaphore(value: 0)
        let secondActualInvocation = DispatchSemaphore(value: 0)
        let sourceIntakeReturned = DispatchSemaphore(value: 0)
        let submissionsCompleted = expectation(description: "serial submissions completed")
        submissionsCompleted.expectedFulfillmentCount = 2
        let recorder = LumenEncoderSubmissionRecorder()
        let admission = Self.makeCoalescingAdmission(
            context: LumenCoalescingAdmissionTestContext(
                sourceQueue: sourceQueue,
                submissionQueue: submissionQueue,
                firstSubmissionPassedHandshake:
                    firstSubmissionPassedHandshake,
                allowFirstActualInvocation: allowFirstActualInvocation,
                secondActualInvocation: secondActualInvocation,
                recorder: recorder,
                submissionsCompleted: submissionsCompleted
            )
        )

        sourceQueue.async {
            XCTAssertNil(admission.offer(1))
        }
        XCTAssertEqual(
            firstSubmissionPassedHandshake.wait(timeout: .now() + 1), .success
        )

        sourceQueue.async {
            XCTAssertNil(admission.offer(2))
            XCTAssertEqual(admission.offer(3), 2)
            sourceIntakeReturned.signal()
        }
        XCTAssertEqual(sourceIntakeReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            secondActualInvocation.wait(timeout: .now() + 0.1),
            .timedOut
        )
        allowFirstActualInvocation.signal()
        XCTAssertEqual(
            XCTWaiter.wait(for: [submissionsCompleted], timeout: 1),
            .completed
        )
        XCTAssertEqual(recorder.snapshot, [1, 3])
    }

    func testSerialEncoderAdmissionStopDrainsEnteredCallAndCancelsLatestPendingBeforeInvalidation() {
        let sourceQueue = DispatchQueue(
            label: "dev.skyline23.lumen.tests.sck-stop-source",
            qos: .userInteractive
        )
        let submissionQueue = DispatchQueue(
            label: "dev.skyline23.lumen.tests.vt-stop-submission",
            qos: .userInteractive,
            attributes: .concurrent
        )
        let activeSubmissionEntered = expectation(description: "active VT submission entered")
        let unblockActiveSubmission = DispatchSemaphore(value: 0)
        let drainFinished = DispatchSemaphore(value: 0)
        let recorder = LumenEncoderSubmissionRecorder()
        let admission = Self.makeStoppingAdmission(
            sourceQueue: sourceQueue,
            submissionQueue: submissionQueue,
            activeSubmissionEntered: activeSubmissionEntered,
            unblockActiveSubmission: unblockActiveSubmission,
            recorder: recorder
        )

        sourceQueue.async {
            XCTAssertNil(admission.offer(1))
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [activeSubmissionEntered], timeout: 1),
            .completed
        )
        sourceQueue.sync {
            XCTAssertNil(admission.offer(2))
            XCTAssertEqual(admission.beginStopping(), [2])
        }

        DispatchQueue.global(qos: .background).async {
            admission.waitUntilSubmissionReturns()
            sourceQueue.sync {}
            recorder.markInvalidated()
            drainFinished.signal()
        }

        XCTAssertEqual(drainFinished.wait(timeout: .now() + 0.1), .timedOut)
        unblockActiveSubmission.signal()
        XCTAssertEqual(drainFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(recorder.snapshot, [1])
        XCTAssertTrue(recorder.isInvalidated)
    }

    func testSerialEncoderAdmissionStopCancelsScheduledCallBeforeSubmissionEntry() {
        let sourceQueue = DispatchQueue(
            label: "dev.skyline23.lumen.tests.sck-pre-entry-stop-source",
            qos: .userInteractive
        )
        let submissionQueue = DispatchQueue(
            label: "dev.skyline23.lumen.tests.vt-pre-entry-stop-submission",
            qos: .userInteractive
        )
        let submissionScheduled = DispatchSemaphore(value: 0)
        let allowSubmissionEntry = DispatchSemaphore(value: 0)
        let recorder = LumenEncoderSubmissionRecorder()
        let admission = LumenLatestFrameSerialEncoderAdmission<Int, Int>(
            ownerQueue: sourceQueue,
            submissionQueue: submissionQueue,
            entryHandler: { source in
                recorder.append(source)
            },
            submit: { source, entered in
                submissionScheduled.signal()
                allowSubmissionEntry.wait()
                guard entered() else {
                    return .cancelled
                }
                return .submitted(source)
            },
            completion: { _, _ in }
        )

        sourceQueue.async {
            XCTAssertNil(admission.offer(1))
        }
        XCTAssertEqual(submissionScheduled.wait(timeout: .now() + 1), .success)
        sourceQueue.sync {
            XCTAssertEqual(admission.beginStopping(), [1])
        }
        allowSubmissionEntry.signal()
        admission.waitUntilSubmissionReturns()
        sourceQueue.sync {}

        XCTAssertEqual(recorder.snapshot, [])
    }

}

final class LumenVideoToolboxLifecycleTests: XCTestCase {
    func testVideoToolboxStopLifecycleDrainsOutputProcessingBeforeInvalidationAndStoppedEvent() async {
        let outputQueue = DispatchQueue(
            label: "dev.skyline23.lumen.tests.vt-output",
            qos: .userInteractive
        )
        let lifecycle = LumenVideoToolboxOutputLifecycle<String>(
            ownerQueue: outputQueue
        )
        let recorder = LumenStopLifecycleRecorder()
        outputQueue.sync {
            lifecycle.registerSubmission(id: 1, context: "frame-1")
        }

        await lifecycle.completeAndInvalidate(
            completeFrames: {
                recorder.append("complete-frames")
                lifecycle.enqueueOutput(id: 1) { context in
                    guard let context else {
                        XCTFail("Registered output context was lost")
                        return
                    }
                    recorder.append("output-processed-\(context)")
                }
                return noErr
            },
            invalidate: {
                recorder.append("invalidated")
            },
            completionFailure: { _, _ in
                XCTFail("Successful completion must not cancel output ownership")
            }
        )
        recorder.append("stopped")

        XCTAssertEqual(
            recorder.snapshot,
            [
                "complete-frames",
                "output-processed-frame-1",
                "invalidated",
                "stopped"
            ]
        )
    }

    func testVideoToolboxStopLifecycleCancelsOutstandingContextsWhenCompleteFramesFails() async {
        let outputQueue = DispatchQueue(
            label: "dev.skyline23.lumen.tests.vt-output-failure",
            qos: .userInteractive
        )
        let lifecycle = LumenVideoToolboxOutputLifecycle<String>(
            ownerQueue: outputQueue
        )
        let recorder = LumenStopLifecycleRecorder()
        let completeFramesFailure = OSStatus(-12903)
        outputQueue.sync {
            lifecycle.registerSubmission(id: 1, context: "frame-1")
            lifecycle.registerSubmission(id: 2, context: "frame-2")
        }

        await lifecycle.completeAndInvalidate(
            completeFrames: {
                recorder.append("complete-frames")
                return completeFramesFailure
            },
            invalidate: {
                recorder.append("invalidated")
            },
            completionFailure: { status, contexts in
                recorder.append(
                    "completion-failed-\(status)-\(contexts.sorted().joined(separator: ","))"
                )
            }
        )
        lifecycle.enqueueOutput(id: 1) { context in
            guard let context else {
                return
            }
            recorder.append("late-output-\(context)")
        }
        outputQueue.sync {}

        XCTAssertEqual(
            recorder.snapshot,
            [
                "complete-frames",
                "invalidated",
                "completion-failed--12903-frame-1,frame-2"
            ]
        )
    }

}

private extension LumenCapturePipelineTests {
    static func makeCoalescingAdmission(
        context: LumenCoalescingAdmissionTestContext
    ) -> LumenLatestFrameSerialEncoderAdmission<Int, Int> {
        LumenLatestFrameSerialEncoderAdmission(
            ownerQueue: context.sourceQueue,
            submissionQueue: context.submissionQueue,
            submit: { source, entered in
                guard entered() else {
                    return .cancelled
                }
                if source == 1 {
                    context.firstSubmissionPassedHandshake.signal()
                    context.allowFirstActualInvocation.wait()
                } else {
                    context.secondActualInvocation.signal()
                }
                context.recorder.append(source)
                return .submitted(source)
            },
            completion: { _, _ in
                context.submissionsCompleted.fulfill()
            }
        )
    }

    static func makeStoppingAdmission(
        sourceQueue: DispatchQueue,
        submissionQueue: DispatchQueue,
        activeSubmissionEntered: XCTestExpectation,
        unblockActiveSubmission: DispatchSemaphore,
        recorder: LumenEncoderSubmissionRecorder
    ) -> LumenLatestFrameSerialEncoderAdmission<Int, Int> {
        LumenLatestFrameSerialEncoderAdmission(
            ownerQueue: sourceQueue,
            submissionQueue: submissionQueue,
            entryHandler: { source in
                recorder.append(source)
            },
            submit: { source, entered in
                guard entered() else {
                    return .cancelled
                }
                XCTAssertFalse(recorder.isInvalidated)
                if source == 1 {
                    activeSubmissionEntered.fulfill()
                    unblockActiveSubmission.wait()
                }
                return .submitted(source)
            },
            completion: { _, _ in }
        )
    }
}

private struct LumenCoalescingAdmissionTestContext {
    let sourceQueue: DispatchQueue
    let submissionQueue: DispatchQueue
    let firstSubmissionPassedHandshake: DispatchSemaphore
    let allowFirstActualInvocation: DispatchSemaphore
    let secondActualInvocation: DispatchSemaphore
    let recorder: LumenEncoderSubmissionRecorder
    let submissionsCompleted: XCTestExpectation
}
