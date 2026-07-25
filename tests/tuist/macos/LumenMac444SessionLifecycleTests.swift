import CoreGraphics
import CoreMedia
import CoreVideo
@testable import LumenMacBridge
import XCTest

final class LumenMac444SessionLifecycleTests: XCTestCase {
    func testSessionRecoveryRoutesSuspendedReplacementTerminationExactlyOnce() async throws {
        let replacementStartEntered = expectation(
            description: "replacement start entered"
        )
        replacementStartEntered.assertForOverFulfill = true
        let laterRecoveryCreated = expectation(
            description: "later recovery runtime created"
        )
        laterRecoveryCreated.assertForOverFulfill = true
        let events = LumenMac444CaptureEventRecorder()
        let replacementStartGate = LumenMac444CaptureRuntimeStartGate()
        let runtimeFactory = LumenMac444CaptureRuntimeFactory(
            replacementStartGate: replacementStartGate,
            replacementStartEntered: {
                replacementStartEntered.fulfill()
            },
            runtimeCreated: { runtimeID in
                if runtimeID == 3 {
                    laterRecoveryCreated.fulfill()
                }
            }
        )
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            runtimeFactory: runtimeFactory
        )

        try await session.start(
            callbacks: .init(
                frameHandler: { _ in },
                eventHandler: { events.append($0) }
            )
        )
        try await assertOriginalRuntimeFenced(
            session: session,
            runtimeFactory: runtimeFactory,
            replacementStartEntered: replacementStartEntered,
            events: events
        )
        await completeReplacementRecovery(
            session: session,
            runtimeFactory: runtimeFactory,
            replacementStartGate: replacementStartGate,
            laterRecoveryCreated: laterRecoveryCreated,
            events: events
        )
    }

    func testSessionStartupTerminationIsTypedAndDoesNotRecover() async throws {
        let startupEntered = expectation(description: "startup entered")
        startupEntered.assertForOverFulfill = true
        let events = LumenMac444CaptureEventRecorder()
        let startupGate = LumenMac444CaptureRuntimeStartGate()
        let runtimeFactory = LumenMac444CaptureRuntimeFactory(
            gatedRuntimeID: 1,
            replacementStartGate: startupGate,
            replacementStartEntered: {
                startupEntered.fulfill()
            }
        )
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            runtimeFactory: runtimeFactory
        )
        let startupTask = Task {
            try await session.start(
                callbacks: .init(
                    frameHandler: { _ in },
                    eventHandler: { events.append($0) }
                )
            )
        }

        await fulfillment(of: [startupEntered], timeout: 2)
        runtimeFactory.terminate(
            runtimeID: 1,
            error: LumenMac444CaptureRuntimeError.startupTermination
        )
        await startupGate.release()

        do {
            try await startupTask.value
            XCTFail("startup termination must fail the initial start")
        } catch let error as LumenEncodedCaptureStartupError {
            XCTAssertEqual(
                error.underlyingError as? LumenMac444CaptureRuntimeError,
                .startupTermination
            )
        }
        XCTAssertEqual(runtimeFactory.makeCount, 1)
        XCTAssertEqual(
            events.snapshot.filter { $0.kind == .restarted }.count,
            0
        )
        await session.stop()
    }

    func testSessionStopFencesReplacementStartAndSilencesLateCallbacks() async throws {
        let replacementStartEntered = expectation(
            description: "replacement start entered"
        )
        replacementStartEntered.assertForOverFulfill = true
        let replacementStartCompleted = expectation(
            description: "replacement start completed"
        )
        replacementStartCompleted.assertForOverFulfill = true
        let lateStartedRuntimeStopped = expectation(
            description: "late-started replacement stopped"
        )
        lateStartedRuntimeStopped.assertForOverFulfill = true
        let events = LumenMac444CaptureEventRecorder()
        let replacementStartGate = LumenMac444CaptureRuntimeStartGate()
        let runtimeFactory = LumenMac444CaptureRuntimeFactory(
            replacementStartGate: replacementStartGate,
            replacementStartEntered: {
                replacementStartEntered.fulfill()
            },
            runtimeStartCompleted: {
                replacementStartCompleted.fulfill()
            },
            lateStartedRuntimeStopped: {
                lateStartedRuntimeStopped.fulfill()
            }
        )
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            runtimeFactory: runtimeFactory
        )

        try await session.start(
            callbacks: .init(
                frameHandler: { _ in },
                eventHandler: { events.append($0) }
            )
        )
        runtimeFactory.terminate(
            runtimeID: 1,
            error: LumenMac444CaptureRuntimeError.originalTermination
        )
        await fulfillment(of: [replacementStartEntered], timeout: 2)

        let stopTask = Task { await session.stop() }
        await replacementStartGate.release()
        await fulfillment(of: [replacementStartCompleted, lateStartedRuntimeStopped], timeout: 2)
        _ = await stopTask.value

        Self.assertStoppedReplacement(
            runtimeFactory: runtimeFactory,
            events: events
        )
    }
}

private extension LumenMac444SessionLifecycleTests {
    func assertOriginalRuntimeFenced(
        session: LumenEncodedCaptureSession,
        runtimeFactory: LumenMac444CaptureRuntimeFactory,
        replacementStartEntered: XCTestExpectation,
        events: LumenMac444CaptureEventRecorder
    ) async throws {
        do {
            try await session.start(
                callbacks: .init(
                    frameHandler: { _ in },
                    eventHandler: { events.append($0) }
                )
            )
            XCTFail("A live encoded session must reject a second start")
        } catch LumenScreenCaptureError.captureAlreadyRunning {
            XCTAssertEqual(runtimeFactory.makeCount, 1)
        }
        runtimeFactory.terminate(
            runtimeID: 1,
            error: LumenMac444CaptureRuntimeError.originalTermination
        )
        await fulfillment(of: [replacementStartEntered], timeout: 2)
        let eventCountAfterFailedRuntimeWasFenced = events.snapshot.count
        runtimeFactory.emitLateStartedEvent(runtimeID: 1)
        XCTAssertEqual(
            events.snapshot.count,
            eventCountAfterFailedRuntimeWasFenced
        )
    }

    func completeReplacementRecovery(
        session: LumenEncodedCaptureSession,
        runtimeFactory: LumenMac444CaptureRuntimeFactory,
        replacementStartGate: LumenMac444CaptureRuntimeStartGate,
        laterRecoveryCreated: XCTestExpectation,
        events: LumenMac444CaptureEventRecorder
    ) async {
        runtimeFactory.terminate(
            runtimeID: 2,
            error: LumenMac444CaptureRuntimeError.replacementTermination
        )
        await replacementStartGate.release()
        await fulfillment(of: [laterRecoveryCreated], timeout: 3)
        await session.stop()

        XCTAssertEqual(runtimeFactory.makeCount, 3)
        XCTAssertEqual(runtimeFactory.stopCount(for: 2), 1)
        XCTAssertEqual(runtimeFactory.stopCount(for: 3), 1)
        XCTAssertEqual(
            events.snapshot.filter { $0.kind == .restarted }.count,
            2
        )
    }

    static func assertStoppedReplacement(
        runtimeFactory: LumenMac444CaptureRuntimeFactory,
        events: LumenMac444CaptureEventRecorder
    ) {
        XCTAssertEqual(runtimeFactory.makeCount, 2)
        XCTAssertEqual(runtimeFactory.startCount(for: 2), 1)
        XCTAssertEqual(runtimeFactory.stopCount(for: 2), 1)
        XCTAssertFalse(runtimeFactory.isRunning(runtimeID: 2))
        let eventCountAfterStop = events.snapshot.count
        runtimeFactory.emitLateStartedEvent(runtimeID: 2)
        XCTAssertEqual(events.snapshot.count, eventCountAfterStop)
    }
}
