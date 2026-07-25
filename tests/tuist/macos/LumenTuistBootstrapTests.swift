@testable import LumenMacBridge
import CoreGraphics
import CoreMedia
import Dispatch
import ScreenCaptureKit
import XCTest

private func makeTestBridgeRuntime() -> LumenBridgeRuntime {
    LumenBridgeRuntime(
        systemAudioPlaybackSuppression:
            LumenSystemAudioPlaybackSuppression(
                hal:
                    LumenCoreAudioSystemAudioPlaybackSuppressionHAL()
            ),
        encodedCaptureRuntimeFactory:
            LumenProductionEncodedCaptureRuntimeFactory()
    )
}

final class LumenTuistBootstrapTests: XCTestCase {
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
        let admission = LumenLatestFrameSerialEncoderAdmission<Int, Int>(
            ownerQueue: sourceQueue,
            submissionQueue: submissionQueue,
            submit: { source, entered in
                guard entered() else {
                    return .cancelled
                }
                if source == 1 {
                    firstSubmissionPassedHandshake.signal()
                    allowFirstActualInvocation.wait()
                } else {
                    secondActualInvocation.signal()
                }
                recorder.append(source)
                return .submitted(source)
            },
            completion: { _, _ in
                submissionsCompleted.fulfill()
            }
        )

        sourceQueue.async {
            XCTAssertNil(admission.offer(1))
        }
        XCTAssertEqual(
            firstSubmissionPassedHandshake.wait(timeout: .now() + 1),
            .success
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
        let admission = LumenLatestFrameSerialEncoderAdmission<Int, Int>(
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
                "stopped",
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
                "completion-failed--12903-frame-1,frame-2",
            ]
        )
    }

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
                replacementStarted,
            ],
            timeout: 2
        )
        await session.stop()

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
            LumenCaptureStreamConfigurationFactory.make(usesHDRTransport: false).showsCursor
        )
        XCTAssertTrue(
            LumenCaptureStreamConfigurationFactory.make(usesHDRTransport: true).showsCursor
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
        let shouldRequestImmediateKeyFrame = await lifecycle.shouldRequestImmediateKeyFrame

        XCTAssertFalse(shouldExposeProducer)
        XCTAssertFalse(shouldRequestImmediateKeyFrame)
    }

    func testBridgeCaptureLifecycleAllowsKeyFramesOnlyWhileRunning() async {
        let lifecycle = LumenBridgeCaptureLifecycle()

        await lifecycle.beginStartup()
        await lifecycle.finishStartup()
        let runningShouldExposeProducer = await lifecycle.shouldExposeProducer
        let runningShouldRequestImmediateKeyFrame = await lifecycle.shouldRequestImmediateKeyFrame
        XCTAssertTrue(runningShouldExposeProducer)
        XCTAssertTrue(runningShouldRequestImmediateKeyFrame)

        await lifecycle.beginStop()
        let stoppingShouldExposeProducer = await lifecycle.shouldExposeProducer
        let stoppingShouldRequestImmediateKeyFrame = await lifecycle.shouldRequestImmediateKeyFrame
        XCTAssertFalse(stoppingShouldExposeProducer)
        XCTAssertFalse(stoppingShouldRequestImmediateKeyFrame)
    }

    func testBridgeConfigurationBoxRoundTripsRequestedOutputAndHDR() {
        let hdrStaticMetadata = LumenHDRStaticMetadata(
            redPrimaryX: 34_000,
            redPrimaryY: 16_000,
            greenPrimaryX: 13_250,
            greenPrimaryY: 34_500,
            bluePrimaryX: 7_500,
            bluePrimaryY: 3_000,
            whitePointX: 15_635,
            whitePointY: 16_450,
            maxDisplayLuminance: 1_000,
            minDisplayLuminance: 10,
            maxContentLightLevel: 1_000,
            maxFrameAverageLightLevel: 400,
            maxFullFrameLuminance: 1_000
        )
        let configuration = LumenMacCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            targetFrameRate: 120,
            targetVideoBitRateKbps: 41_000,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    currentEDRHeadroom: 2.8,
                    potentialEDRHeadroom: 8.4,
                    currentPeakLuminanceNits: 800,
                    potentialPeakLuminanceNits: 1600,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq,
                hdrStaticMetadata: hdrStaticMetadata
            )
        )

        let roundTrip = LumenBridgeConfigurationBox(configuration: configuration).swiftValue
        XCTAssertEqual(roundTrip.displayID, 11)
        XCTAssertEqual(roundTrip.codec, .hevc)
        XCTAssertEqual(roundTrip.targetFrameRate, 120)
        XCTAssertEqual(roundTrip.targetVideoBitRateKbps, 41_000)
        XCTAssertEqual(roundTrip.requestedWidth, 3512)
        XCTAssertEqual(roundTrip.requestedHeight, 2290)
        XCTAssertTrue(roundTrip.usesHDRTransport)
        XCTAssertEqual(roundTrip.effectiveDisplayState.hdrStaticMetadata, hdrStaticMetadata)
        XCTAssertEqual(roundTrip.sinkRequest.capability.currentEDRHeadroom, 2.8)
        XCTAssertEqual(roundTrip.sinkRequest.capability.potentialEDRHeadroom, 8.4)
        XCTAssertEqual(roundTrip.sinkRequest.capability.currentPeakLuminanceNits, 800)
        XCTAssertEqual(roundTrip.sinkRequest.capability.potentialPeakLuminanceNits, 1600)
    }

    func testBridgeHDRConfigurationSeparatesDisplayGamutFromSignalPrimaries() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            targetFrameRate: 120,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        let snapshot = configuration.encodedHDRConfigurationSnapshot
        XCTAssertEqual(snapshot?.signalColorPrimaries, "ituR2020")
        XCTAssertEqual(snapshot?.transferFunction, "smpteSt2084PQ")
        XCTAssertEqual(snapshot?.signalYCbCrMatrix, "ituR2020")
        XCTAssertEqual(snapshot?.staticMetadataSource, "display-p3-default")
    }

    func testCaptureColorContractAcceptsConvertedHDR10InputWithoutRetagging() throws {
        let color = LumenVideoHDRConfiguration(
            sourceColorPrimaries: .p3D65,
            colorPrimaries: .ituR2020,
            transferFunction: .smpteSt2084PQ,
            yCbCrMatrix: .ituR2020
        )
        let contract = LumenCaptureColorContract(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            color: color
        )
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)

        XCTAssertNil(contract.mismatchDescription(for: imageBuffer))
    }

    func testCaptureColorContractRejectsDisplayP3PixelsRetaggedAsBT2020() throws {
        let color = LumenVideoHDRConfiguration(
            sourceColorPrimaries: .p3D65,
            colorPrimaries: .ituR2020,
            transferFunction: .smpteSt2084PQ,
            yCbCrMatrix: .ituR2020
        )
        let contract = LumenCaptureColorContract(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            color: color
        )
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        XCTAssertEqual(
            contract.mismatchDescription(for: imageBuffer),
            "primaries expected=ITU_R_2020 actual=P3_D65"
        )
    }

    func testHDRCaptureUsesSDRPreservingHDR10OutputContract() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("The SDR-preserving HDR10 ScreenCaptureKit preset requires macOS 26")
        }

        let configuration = LumenCaptureStreamConfigurationFactory.make(usesHDRTransport: true)
        XCTAssertEqual(configuration.captureDynamicRange, .hdrCanonicalDisplay)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(configuration.colorSpaceName as String, CGColorSpace.itur_2100_PQ as String)
        XCTAssertEqual(configuration.colorMatrix as String, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
    }

    func testBridgeNegotiatesFrameGatedHDRAgainstSinkCapabilities() {
        let unsupportedSink = LumenMacCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 60,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
            )
        )

        XCTAssertEqual(unsupportedSink.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportSDR)
        XCTAssertFalse(unsupportedSink.usesHDRTransport)
        XCTAssertEqual(unsupportedSink.negotiatedQueueProfile, .q2)
    }

    func testBridgeNegotiatesOverlayFallbackAndAutoQueueProfile() {
        let fallbackOverlay = LumenMacCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 60,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            )
        )
        let overlayRequestedSink = LumenMacCaptureConfiguration(
            displayID: 11,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 60,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            )
        )

        XCTAssertEqual(fallbackOverlay.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportFrameGatedHDR)
        XCTAssertTrue(fallbackOverlay.usesHDRTransport)
        XCTAssertTrue(fallbackOverlay.prefersRealtimeHDRMetadata)
        XCTAssertEqual(fallbackOverlay.negotiatedQueueProfile, .q3)

        XCTAssertEqual(overlayRequestedSink.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportSDRBaseHDROverlay)
        XCTAssertFalse(overlayRequestedSink.usesHDRTransport)
        XCTAssertTrue(overlayRequestedSink.prefersRealtimeHDRMetadata)
        XCTAssertEqual(overlayRequestedSink.negotiatedQueueProfile, .q4)
    }

    func testRecommendedVideoForwardingFrameCapacityStaysLowLatency() {
        let q2 = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 120
        )
        let auto = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .auto,
            targetFrameRate: 120
        )
        let q4 = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q4,
            targetFrameRate: 120
        )
        let q2NinetyFps = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 90
        )
        let q2SixtyFps = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 60
        )
        let q2ThirtyFps = LumenMacCaptureConfiguration(
            displayID: 7,
            queueProfile: .q2,
            targetFrameRate: 30
        )

        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q2), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: auto), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q4), 3)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q2NinetyFps), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q2SixtyFps), 2)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: q2ThirtyFps), 2)
    }

    func testBridgePreservesRequested120HzWithoutImplicitDownscaleFor4KOverlay() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            preprocessStrategy: .none,
            queueProfile: .auto,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        XCTAssertEqual(configuration.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportSDRBaseHDROverlay)
        XCTAssertEqual(configuration.effectiveTargetFrameRate, 120)
        XCTAssertEqual(configuration.effectivePreprocessStrategy, .none)
        XCTAssertEqual(configuration.negotiatedQueueProfile, .q3)
        XCTAssertEqual(configuration.negotiatedQueueProfile.queueDepthHint, 3)
        XCTAssertEqual(configuration.forwardingQueueDepthReserve, 2)
        XCTAssertEqual(configuration.effectiveTargetFrameRate, 120)
        XCTAssertEqual(configuration.requestedWidth, 3512)
        XCTAssertEqual(configuration.requestedHeight, 2290)
        XCTAssertEqual(LumenBridgeRuntime.recommendedVideoForwardingFrameCapacity(for: configuration), 3)
    }

    func testLumenProtocolKeepsEveryClientVisiblePresentationSingleFrame() {
        let capabilities = [
            LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: true
            ),
            LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: false,
                supportsPerFrameHDRMetadata: true
            ),
            LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: false
            ),
        ]

        for capability in capabilities {
            let contract = LumenProtocolPresentationContract.resolve(
                requestedTransport: .sdrBaseHDROverlay,
                sinkCapability: capability
            )
            XCTAssertEqual(contract, .singleFrame)
            XCTAssertEqual(contract.wireName, "single-frame")
            XCTAssertEqual(contract.completionRule, .fullFrame)
        }
    }

    func testMacBridgeDerivesPresentationContractFromLumenProtocol() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        XCTAssertEqual(configuration.lumenProtocolPresentationContract, .singleFrame)
        XCTAssertEqual(configuration.presentationContractName, "single-frame")
        XCTAssertEqual(configuration.presentationCompletionName, "full-frame")
    }

    func testMacProtocolAdapterMapsConfigurationToLumenProtocolSignals() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        let adapter = configuration.lumenProtocolAdapter

        XCTAssertEqual(adapter.requestedTransport, .sdrBaseHDROverlay)
        XCTAssertEqual(adapter.negotiatedTransport, .sdrBaseHDROverlay)
        XCTAssertEqual(
            adapter.sinkCapability,
            LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: true
            )
        )
        XCTAssertEqual(adapter.presentationContract, .singleFrame)
    }

    func testMacProtocolAdapterExposesSourceNeutralPresentationSignal() {
        let adapter = LumenMacProtocolAdapter(
            requestedTransport: .sdrBaseHDROverlay,
            negotiatedTransport: .sdrBaseHDROverlay,
            sinkCapability: LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: true
            )
        )

        XCTAssertEqual(
            adapter.presentationSignal,
            LumenProtocolPresentationSignal(
                requestedTransport: .sdrBaseHDROverlay,
                negotiatedTransport: .sdrBaseHDROverlay,
                sinkCapability: LumenProtocolSinkCapability(
                    prefersHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                )
            )
        )
        XCTAssertEqual(adapter.presentationContract, .singleFrame)
    }

    func testMacProtocolAdapterUsesSharedProtocolAdapterOutputShape() {
        let output = LumenProtocolAdapterOutput(
            requestedTransport: .sdrBaseHDROverlay,
            negotiatedTransport: .sdrBaseHDROverlay,
            sinkCapability: LumenProtocolSinkCapability(
                prefersHDR: true,
                supportsHDRTileOverlay: true,
                supportsPerFrameHDRMetadata: true
            )
        )
        let adapter = LumenMacProtocolAdapter(output: output)

        XCTAssertEqual(adapter.output, output)
        XCTAssertEqual(adapter.presentationContract, .singleFrame)
    }

    func testBridgePrefersTenBitEncoderInputForPartialHDROverlay() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )

        XCTAssertEqual(configuration.effectiveEncoderInputStrategy, .yuv420v10)
        XCTAssertEqual(configuration.effectiveCapturePixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.effectiveCapturePixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.encodedHDRConfigurationSnapshot?.transferFunction, "smpteSt2084PQ")
    }

    func testBridgeDoesNotForceHDRTransportForBatterySavingSDRMode() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            queueProfile: .auto,
            targetFrameRate: 120,
            requestedWidth: 3512,
            requestedHeight: 2290,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .sdr,
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportSDRBaseHDROverlay
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .sdr
            )
        )

        XCTAssertFalse(configuration.usesHDRTransport)
        XCTAssertEqual(configuration.negotiatedDynamicRangeTransport, LumenMacDynamicRangeTransportSDR)
        XCTAssertFalse(configuration.prefersRealtimeHDRMetadata)
        XCTAssertEqual(configuration.effectiveCapturePixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertNil(configuration.encodedHDRConfigurationSnapshot)
    }

    func testBridgeForwardsSyntheticSampleBufferIntoSwiftIngress() async throws {
        let runtime = makeTestBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        let sampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0xAA, 0xBB, 0xCC]),
            codecType: kCMVideoCodecType_HEVC,
            colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            transferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
            notSync: true
        )
        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: sampleBuffer,
            codec: .hevc,
            sourceSequenceNumber: 7,
            sourceDisplayTime: 9,
            outputCallbackLatencyMilliseconds: 2.75,
            isKeyFrame: false,
            isHDRSignaled: true
        )
        await runtime.debugForwardSyntheticEvent(
            kind: .droppedFrame,
            message: "synthetic-drop",
            sourceDisplayTime: 9
        )

        let snapshot = await runtime.videoForwardingSnapshot()
        XCTAssertEqual(snapshot.frameCount, 1)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.lastFrameCodec, .hevc)
        XCTAssertEqual(snapshot.lastFramePayloadSize, 3)
        XCTAssertEqual(snapshot.lastFrameSourceSequenceNumber, 7)
        XCTAssertEqual(snapshot.lastFrameSourceDisplayTime, 9)
        XCTAssertTrue(snapshot.hasLastSampleBuffer)
        XCTAssertFalse(snapshot.lastFrameIsKeyFrame)
        XCTAssertTrue(snapshot.lastFrameIsHDRSignaled)
        XCTAssertEqual(snapshot.lastEventKind, .droppedFrame)
    }

    func testBridgeForwardingRequiresFreshKeyFrameAfterCapacityOverflow() async throws {
        let runtime = makeTestBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        await runtime.configureVideoForwarding(frameCapacity: 1, eventCapacity: 1)

        let firstSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x01]),
            codecType: kCMVideoCodecType_HEVC
        )
        let secondSampleBuffer = try Self.makeEncodedSampleBuffer(
            payload: Data([0x02]),
            codecType: kCMVideoCodecType_HEVC
        )

        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: firstSampleBuffer,
            codec: .hevc,
            sourceSequenceNumber: 1,
            sourceDisplayTime: 10,
            isKeyFrame: true,
            isHDRSignaled: false
        )
        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: secondSampleBuffer,
            codec: .hevc,
            sourceSequenceNumber: 2,
            sourceDisplayTime: 20,
            isKeyFrame: false,
            isHDRSignaled: true
        )

        let snapshot = await runtime.videoForwardingSnapshot()
        XCTAssertEqual(snapshot.frameCount, 2)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.queuedFrameCount, 0)
        XCTAssertEqual(snapshot.queuedEventCount, 1)
        XCTAssertEqual(snapshot.droppedFrameCount, 2)
        XCTAssertEqual(snapshot.lastEventKind, .droppedFrame)

        let discardedFrame = await runtime.drainNextVideoForwardedFrame()
        XCTAssertNil(discardedFrame)

        let drainedEvent = await runtime.drainNextVideoForwardedEvent()
        XCTAssertEqual(drainedEvent?.kind, .droppedFrame)
        XCTAssertEqual(drainedEvent?.message, "core-forwarder-overflow")
        XCTAssertEqual(drainedEvent?.sourceDisplayTime, 10)
    }

    func testBridgeForwardingDropsDependentsUntilRecoveryKeyFrame() async throws {
        let runtime = makeTestBridgeRuntime()
        await runtime.debugResetVideoForwarding()
        await runtime.configureVideoForwarding(frameCapacity: 1, eventCapacity: 2)

        for (sequence, keyFrame) in [(1, true), (2, false), (3, true), (4, true)] {
            await runtime.debugForwardSyntheticFrame(
                sampleBuffer: try Self.makeEncodedSampleBuffer(
                    payload: Data([UInt8(sequence)]),
                    codecType: kCMVideoCodecType_HEVC
                ),
                codec: .hevc,
                sourceSequenceNumber: UInt64(sequence),
                sourceDisplayTime: UInt64(sequence * 10),
                isKeyFrame: keyFrame,
                requiresBootstrapAcknowledgement: sequence == 4,
                isRepairKeyFrame: sequence == 4,
                isHDRSignaled: true
            )
        }

        let recoveredFrame = await runtime.drainNextVideoForwardedFrame()
        let recovered = try XCTUnwrap(recoveredFrame)
        XCTAssertEqual(recovered.sourceSequenceNumber, 4)
        XCTAssertTrue(recovered.isKeyFrame)
        XCTAssertEqual(try Self.payloadBytes(from: recovered.sampleBuffer), Data([0x04]))

        await runtime.debugForwardSyntheticFrame(
            sampleBuffer: try Self.makeEncodedSampleBuffer(
                payload: Data([0x05]),
                codecType: kCMVideoCodecType_HEVC
            ),
            codec: .hevc,
            sourceSequenceNumber: 5,
            sourceDisplayTime: 50,
            isKeyFrame: false,
            isHDRSignaled: true
        )

        let snapshot = await runtime.videoForwardingSnapshot()
        XCTAssertEqual(snapshot.frameCount, 5)
        XCTAssertEqual(snapshot.droppedFrameCount, 3)
        XCTAssertEqual(snapshot.queuedFrameCount, 1)
        let dependent = await runtime.drainNextVideoForwardedFrame()
        XCTAssertEqual(dependent?.sourceSequenceNumber, 5)
    }

}

private enum LumenConcurrentCaptureStartupTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "test failure"
    }
}

private final class LumenEncoderSubmissionRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.tests.encoder-recorder")
    private var values: [Int] = []
    private var invalidated = false

    func append(_ value: Int) {
        queue.sync {
            values.append(value)
        }
    }

    var snapshot: [Int] {
        queue.sync {
            values
        }
    }

    func markInvalidated() {
        queue.sync {
            invalidated = true
        }
    }

    var isInvalidated: Bool {
        queue.sync {
            invalidated
        }
    }
}

private final class LumenStopLifecycleRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.tests.stop-recorder")
    private var values: [String] = []

    func append(_ value: String) {
        queue.sync {
            values.append(value)
        }
    }

    var snapshot: [String] {
        queue.sync {
            values
        }
    }
}

private final class LumenEncodedCaptureEventRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.capture-event-recorder"
    )
    private var events: [LumenEncodedCaptureSessionEvent] = []

    func append(_ event: LumenEncodedCaptureSessionEvent) {
        queue.sync {
            events.append(event)
        }
    }

    var snapshot: [LumenEncodedCaptureSessionEvent] {
        queue.sync {
            events
        }
    }
}

private final class LumenReentrantTerminationRuntimeFactory:
    LumenEncodedCaptureRuntimeFactory,
    @unchecked Sendable
{
    static let completeFramesFailureStatus = OSStatus(-12903)

    private struct State {
        var makeCount = 0
        var startCounts: [Int: Int] = [:]
        var stopCounts: [Int: Int] = [:]
        var contexts: [Int: LumenEncodedCaptureRuntimeContext] = [:]
        var didEmitTeardownFailure = false
        var runningRuntimeIDs: Set<Int> = []
    }

    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.reentrant-runtime-factory"
    )
    private let replacementStarted: @Sendable () -> Void
    private let replacementStartGate: LumenCaptureRuntimeStartGate?
    private let lateStartedRuntimeStopped: @Sendable () -> Void
    private let runtimeStartedLatch = LumenCaptureRuntimeStartedLatch()
    private var state = State()

    init(
        replacementStarted: @escaping @Sendable () -> Void,
        replacementStartGate: LumenCaptureRuntimeStartGate? = nil,
        lateStartedRuntimeStopped: @escaping @Sendable () -> Void = {}
    ) {
        self.replacementStarted = replacementStarted
        self.replacementStartGate = replacementStartGate
        self.lateStartedRuntimeStopped = lateStartedRuntimeStopped
    }

    var makeCount: Int {
        queue.sync {
            state.makeCount
        }
    }

    func startCount(for runtimeID: Int) -> Int {
        queue.sync {
            state.startCounts[runtimeID, default: 0]
        }
    }

    func stopCount(for runtimeID: Int) -> Int {
        queue.sync {
            state.stopCounts[runtimeID, default: 0]
        }
    }

    func isRunning(runtimeID: Int) -> Bool {
        queue.sync {
            state.runningRuntimeIDs.contains(runtimeID)
        }
    }

    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime {
        let runtimeID = queue.sync {
            state.makeCount += 1
            let runtimeID = state.makeCount
            state.contexts[runtimeID] = context
            return runtimeID
        }
        return LumenReentrantTerminationRuntime(
            runtimeID: runtimeID,
            factory: self
        )
    }

    func terminateOriginalRuntime() {
        let handler = queue.sync {
            state.contexts[1]?.terminationHandler
        }
        handler?(LumenCaptureRecoveryTestError.originalTermination)
    }

    fileprivate func start(runtimeID: Int) async {
        queue.sync {
            state.startCounts[runtimeID, default: 0] += 1
        }
        if runtimeID > 1 {
            replacementStarted()
            if let replacementStartGate {
                await replacementStartGate.wait()
            }
        }
        _ = queue.sync {
            state.runningRuntimeIDs.insert(runtimeID)
        }
        await runtimeStartedLatch.markStarted(runtimeID: runtimeID)
    }

    fileprivate func stop(runtimeID: Int) async {
        let mustWaitForStartedRuntime = queue.sync {
            state.startCounts[runtimeID, default: 0] > 0 &&
                !state.runningRuntimeIDs.contains(runtimeID)
        }
        if mustWaitForStartedRuntime {
            await runtimeStartedLatch.waitUntilStarted(
                runtimeID: runtimeID
            )
        }
        let (
            failureContext,
            stoppedRunningRuntime
        ): (LumenEncodedCaptureRuntimeContext?, Bool) = queue.sync {
            state.stopCounts[runtimeID, default: 0] += 1
            let stoppedRunningRuntime =
                state.runningRuntimeIDs.remove(runtimeID) != nil
            guard runtimeID == 1,
                  !state.didEmitTeardownFailure else {
                return (nil, stoppedRunningRuntime)
            }
            state.didEmitTeardownFailure = true
            return (state.contexts[runtimeID], stoppedRunningRuntime)
        }
        if runtimeID > 1, stoppedRunningRuntime {
            lateStartedRuntimeStopped()
        }
        guard let failureContext else {
            return
        }

        let error = LumenScreenCaptureError
            .compressionFrameCompletionFailed(
                Self.completeFramesFailureStatus
            )
        failureContext.callbacks.eventHandler?(.init(
            kind: .failed,
            message: error.localizedDescription,
            stopStatus: Self.completeFramesFailureStatus
        ))
        failureContext.terminationHandler(error)
        for _ in 0..<256 {
            await Task.yield()
        }
    }
}

private final class LumenReentrantTerminationRuntime:
    LumenEncodedCaptureRuntime,
    @unchecked Sendable
{
    private let runtimeID: Int
    private let factory: LumenReentrantTerminationRuntimeFactory

    init(
        runtimeID: Int,
        factory: LumenReentrantTerminationRuntimeFactory
    ) {
        self.runtimeID = runtimeID
        self.factory = factory
    }

    func start() async throws {
        await factory.start(runtimeID: runtimeID)
    }

    func stop() async {
        await factory.stop(runtimeID: runtimeID)
    }

    func requestImmediateKeyFrame() {}

    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        true
    }
}

private enum LumenCaptureRecoveryTestError: Error {
    case originalTermination
}

private actor LumenCaptureRuntimeStartedLatch {
    private var startedRuntimeIDs: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func markStarted(runtimeID: Int) {
        startedRuntimeIDs.insert(runtimeID)
        let continuations = waiters.removeValue(forKey: runtimeID) ?? []
        continuations.forEach { $0.resume() }
    }

    func waitUntilStarted(runtimeID: Int) async {
        guard !startedRuntimeIDs.contains(runtimeID) else {
            return
        }
        await withCheckedContinuation { continuation in
            if startedRuntimeIDs.contains(runtimeID) {
                continuation.resume()
            } else {
                waiters[runtimeID, default: []].append(continuation)
            }
        }
    }
}

private actor LumenCaptureRuntimeStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private enum LumenCaptureStartupOrderEvent: Equatable {
    case videoStarted
    case videoReady
    case audioScheduled
}

private actor LumenCaptureStartupOrderProbe {
    private(set) var events: [LumenCaptureStartupOrderEvent] = []

    func append(_ event: LumenCaptureStartupOrderEvent) {
        events.append(event)
    }
}

private extension LumenTuistBootstrapTests {
    static func makeEncodedSampleBuffer(
        payload: Data,
        codecType: CMVideoCodecType,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        notSync: Bool = false
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let bytes = [UInt8](payload)
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(status, noErr)

        let appendStatus = bytes.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        XCTAssertEqual(appendStatus, noErr)

        var extensions: [CFString: Any] = [:]
        if let colorPrimaries {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = colorPrimaries as CFString
        }
        if let transferFunction {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transferFunction as CFString
        }
        if transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = Data([0, 1, 0, 1]) as CFData
        }

        var formatDescription: CMFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codecType,
                width: 3840,
                height: 2160,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: 1, timescale: 120),
            decodeTimeStamp: .invalid
        )
        let sampleSize = [bytes.count]
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: [timing],
                sampleSizeEntryCount: 1,
                sampleSizeArray: sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )

        if notSync,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
            try XCTUnwrap(sampleBuffer),
            createIfNecessary: true
           ) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return try XCTUnwrap(sampleBuffer)
    }

    static func payloadBytes(from sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw NSError(domain: "LumenTuistBootstrapTests", code: 1)
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: rawBuffer.baseAddress!
            )
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        return bytes
    }
}
