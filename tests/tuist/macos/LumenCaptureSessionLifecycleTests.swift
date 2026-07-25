@testable import LumenMacBridge
import ScreenCaptureKit
import XCTest

final class LumenCaptureSessionLifecycleTests: XCTestCase {
    func testSessionRecoveryFencesCompleteFramesTerminationReentryFromFailedRuntimeStop() async throws {
        let restarted = expectation(description: "one restart decision")
        restarted.assertForOverFulfill = true
        let replacementStarted = expectation(
            description: "one replacement runtime started"
        )
        replacementStarted.assertForOverFulfill = true
        let eventRecorder = LumenEncodedCaptureEventRecorder()
        let runtimeFactory = LumenReentrantTerminationRuntimeFactory(
            replacementStarted: {
                replacementStarted.fulfill()
            }
        )
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            runtimeFactory: runtimeFactory
        )

        try await session.start(
            callbacks: .init(
                frameHandler: { _ in },
                eventHandler: { event in
                    eventRecorder.append(event)
                    if event.kind == .restarted {
                        restarted.fulfill()
                    }
                }
            )
        )
        runtimeFactory.terminateOriginalRuntime()

        await fulfillment(
            of: [
                restarted,
                replacementStarted
            ],
            timeout: 2
        )
        await session.stop()

        Self.assertRecoveredSession(
            runtimeFactory: runtimeFactory,
            eventRecorder: eventRecorder
        )
    }

    func testSessionStopFencesLateReplacementStartAndStopsItAfterSuspension() async throws {
        let replacementStartEntered = expectation(
            description: "replacement start entered"
        )
        replacementStartEntered.assertForOverFulfill = true
        let lateStartedRuntimeStopped = expectation(
            description: "late-started replacement stopped"
        )
        lateStartedRuntimeStopped.assertForOverFulfill = true
        let replacementStartGate = LumenCaptureRuntimeStartGate()
        let runtimeFactory = LumenReentrantTerminationRuntimeFactory(
            replacementStarted: {
                replacementStartEntered.fulfill()
            },
            replacementStartGate: replacementStartGate,
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
                eventHandler: nil
            )
        )
        runtimeFactory.terminateOriginalRuntime()
        await fulfillment(of: [replacementStartEntered], timeout: 2)

        let stopTask = Task { await session.stop() }
        await replacementStartGate.release()
        await fulfillment(of: [lateStartedRuntimeStopped], timeout: 2)
        _ = await stopTask.value

        XCTAssertEqual(runtimeFactory.makeCount, 2)
        XCTAssertEqual(runtimeFactory.startCount(for: 2), 1)
        XCTAssertEqual(runtimeFactory.stopCount(for: 2), 1)
        XCTAssertFalse(runtimeFactory.isRunning(runtimeID: 2))
    }

    func testSystemAudioJoinsTheActiveVideoStreamForTheSameDisplay() throws {
        let configuration = LumenMacAudioCaptureConfiguration.systemOutput(displayID: 118)

        XCTAssertEqual(configuration.frameSize, 240)
        guard case .systemOutput(
            _,
            let excludesCurrentProcessAudio
        ) = configuration.source else {
            return XCTFail("Expected a system-output source")
        }
        XCTAssertTrue(excludesCurrentProcessAudio)
        let route = try LumenSystemAudioCaptureRoute.resolve(
            configuration: configuration,
            activeVideoDisplayID: 118
        )

        XCTAssertEqual(route, .sharedVideoStream)
    }

    func testSystemAudioRejectsASecondStreamForAnotherActiveVideoDisplay() {
        let configuration = LumenMacAudioCaptureConfiguration.systemOutput(displayID: 119)

        XCTAssertThrowsError(
            try LumenSystemAudioCaptureRoute.resolve(
                configuration: configuration,
                activeVideoDisplayID: 118
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "System audio display 119 does not match active video display 118."
            )
        }
    }

    func testLegacyVisualFirstCoordinatorStillPreservesTypedBoundaries() async throws {
        let probe = LumenCaptureStartupOrderProbe()

        try await LumenBridgeCaptureStartupCoordinator.startVisualFirst(
            video: {
                await probe.append(.videoStarted)
                try await Task.sleep(for: .milliseconds(50))
                await probe.append(.videoReady)
            },
            launchAudio: {
                await probe.append(.audioScheduled)
            }
        )

        let events = await probe.events
        XCTAssertEqual(events, [.videoStarted, .videoReady, .audioScheduled])
    }

    func testBridgeCaptureStartupPreservesTheFailingBoundary() async {
        do {
            try await LumenBridgeCaptureStartupCoordinator.startVisualFirst(
                video: { throw LumenConcurrentCaptureStartupTestError.failed },
                launchAudio: {}
            )
            XCTFail("Expected video startup to fail")
        } catch let error as LumenBridgeCaptureStartupError {
            XCTAssertEqual(error.source, .video)
            XCTAssertTrue(error.message.contains("test failure"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWorkspaceStopFallsBackToDurableRecovery() async throws {
        let result = try await LumenWorkspaceStopRecoveryCoordinator.stop(
            stop: { throw LumenConcurrentCaptureStartupTestError.failed },
            recover: { true }
        )

        XCTAssertTrue(result.usedDurableRecovery)
        XCTAssertTrue(result.stopFailureMessage?.contains("test failure") == true)
    }

    func testBridgeExposesBootstrapStatus() async {
        let status = await LumenBridgeRuntime.shared.statusSnapshot()

        XCTAssertTrue(status.coreVersion.hasPrefix("Rust ABI "))
        XCTAssertEqual(status.runtimeDescription, "Rust host with Swift macOS capture adapters")
        XCTAssertFalse(status.integrationStatus.isEmpty)
    }

    func testBridgeBuildsPanelNativeScreenCaptureKitConfiguration() async {
        let configuration = await LumenBridgeRuntime.shared.preferredCaptureConfiguration(
            displayID: 7
        )

        XCTAssertEqual(configuration.displayID, 7)
        XCTAssertTrue(LumenCaptureCodec.allCases.contains(configuration.codec))
        XCTAssertEqual(configuration.preprocessStrategy, .none)
        XCTAssertTrue(LumenCaptureQueueProfile.allCases.contains(configuration.queueProfile))
        XCTAssertEqual(configuration.targetFrameRate, 120)
        XCTAssertNil(configuration.requestedWidth)
        XCTAssertNil(configuration.requestedHeight)
        XCTAssertFalse(configuration.usesHDRTransport)
    }

    func testScreenCaptureKitConfigurationAlwaysIncludesCursor() {
        XCTAssertTrue(
            LumenCaptureStreamConfigurationFactory.make(
                usesHDRTransport: false
            ).showsCursor
        )
        XCTAssertTrue(
            LumenCaptureStreamConfigurationFactory.make(
                usesHDRTransport: true
            ).showsCursor
        )
    }

    func testBridgeIgnoresImmediateKeyFrameRequestsWithoutActiveSession() async {
        await LumenBridgeRuntime.shared.requestImmediateCaptureKeyFrame()
        let status = await LumenBridgeRuntime.shared.statusSnapshot()
        XCTAssertFalse(status.captureSessionRunning)
    }

    func testBridgeCaptureLifecycleKeepsProducerInactiveDuringStartup() async {
        let lifecycle = LumenBridgeCaptureLifecycle()

        await lifecycle.beginStartup()

        let shouldExposeProducer = await lifecycle.shouldExposeProducer
        let shouldRequestImmediateKeyFrame =
            await lifecycle.shouldRequestImmediateKeyFrame

        XCTAssertFalse(shouldExposeProducer)
        XCTAssertFalse(shouldRequestImmediateKeyFrame)
    }

    func testBridgeCaptureLifecycleAllowsKeyFramesOnlyWhileRunning() async {
        let lifecycle = LumenBridgeCaptureLifecycle()

        await lifecycle.beginStartup()
        await lifecycle.finishStartup()
        let runningShouldExposeProducer = await lifecycle.shouldExposeProducer
        let runningShouldRequestImmediateKeyFrame =
            await lifecycle.shouldRequestImmediateKeyFrame
        XCTAssertTrue(runningShouldExposeProducer)
        XCTAssertTrue(runningShouldRequestImmediateKeyFrame)

        await lifecycle.beginStop()
        let stoppingShouldExposeProducer = await lifecycle.shouldExposeProducer
        let stoppingShouldRequestImmediateKeyFrame =
            await lifecycle.shouldRequestImmediateKeyFrame
        XCTAssertFalse(stoppingShouldExposeProducer)
        XCTAssertFalse(stoppingShouldRequestImmediateKeyFrame)
    }

}

private extension LumenCaptureSessionLifecycleTests {
    static func assertRecoveredSession(
        runtimeFactory: LumenReentrantTerminationRuntimeFactory,
        eventRecorder: LumenEncodedCaptureEventRecorder
    ) {
        XCTAssertEqual(runtimeFactory.makeCount, 2)
        XCTAssertEqual(runtimeFactory.startCount(for: 1), 1)
        XCTAssertEqual(runtimeFactory.stopCount(for: 1), 1)
        XCTAssertEqual(runtimeFactory.startCount(for: 2), 1)
        XCTAssertEqual(runtimeFactory.stopCount(for: 2), 1)
        XCTAssertEqual(
            eventRecorder.snapshot.filter { $0.kind == .restarted }.count,
            1
        )
        XCTAssertEqual(
            eventRecorder.snapshot.filter {
                $0.kind == .failed &&
                    $0.stopStatus ==
                    LumenReentrantTerminationRuntimeFactory
                    .completeFramesFailureStatus
            }.count,
            0
        )
    }
}
