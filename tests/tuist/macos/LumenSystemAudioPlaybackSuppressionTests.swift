@testable import LumenMacBridge
import CoreAudio
import Synchronization
import XCTest

final class LumenSystemAudioPlaybackSuppressionTests: XCTestCase {
    func testIOProcIsTheSinglePCMSourceAndTeardownRunsInReverse() async throws {
        let hal = RecordingSystemAudioSuppressionHAL()
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let frames = AudioFrameRecorder()
        let callbacks = recordingCallbacks(frames: frames)

        try await source.activate(
            configuration: .systemOutput(
                displayID: 118,
                sampleRate: 48_000,
                channelCount: 2,
                frameSize: 2
            ),
            callbacks: callbacks
        )
        hal.emitPCM(
            .init(
                hostTimeNanoseconds: 1_000_000,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 4,
                pcmFloat32LE: pcmData([
                    0.1, -0.1,
                    0.2, -0.2,
                    0.3, -0.3,
                    0.4, -0.4,
                ])
            )
        )
        let cleanupFailures = await source.deactivate()

        XCTAssertTrue(cleanupFailures.isEmpty)
        let capturedFrames = frames.frames
        XCTAssertEqual(capturedFrames.count, 2)
        XCTAssertEqual(capturedFrames.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(capturedFrames.map(\.sampleRate), [48_000, 48_000])
        XCTAssertEqual(capturedFrames.map(\.channelCount), [2, 2])
        XCTAssertEqual(capturedFrames.map(\.frameCount), [2, 2])
        XCTAssertEqual(
            capturedFrames.flatMap { pcmFloats($0.pcmFloat32LE) },
            [
                0.1, -0.1,
                0.2, -0.2,
                0.3, -0.3,
                0.4, -0.4,
            ]
        )
        XCTAssertEqual(
            hal.events,
            [
                .createProcessTap(
                    muteBehavior: .muted,
                    isPrivate: true,
                    excludedProcessObjectIDs: [44]
                ),
                .readTapStreamFormat(tapID: 11),
                .createAggregateDevice(tapUID: "test-tap"),
                .createIOProc(deviceID: 22),
                .startIO(deviceID: 22, ioProcID: 33),
                .stopIO(deviceID: 22, ioProcID: 33),
                .destroyIOProc(deviceID: 22, ioProcID: 33),
                .destroyAggregateDevice(deviceID: 22),
                .destroyProcessTap(tapID: 11),
            ]
        )
    }

    func testIOProcPCMConvertsSampleRateChannelsAndRequestedFrameSize() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(
            streamFormat: .init(
                sampleRate: 24_000,
                channelCount: 1,
                isInterleaved: true
            )
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let frames = AudioFrameRecorder()

        try await source.activate(
            configuration: .systemOutput(
                displayID: 118,
                sampleRate: 48_000,
                channelCount: 2,
                frameSize: 8
            ),
            callbacks: recordingCallbacks(frames: frames)
        )
        for index in 0..<8 {
            hal.emitPCM(
                .init(
                    hostTimeNanoseconds: UInt64(index) * 1_000_000,
                    sampleRate: 24_000,
                    channelCount: 1,
                    frameCount: 8,
                    pcmFloat32LE: pcmData(
                        (0..<8).map { Float(index * 8 + $0) / 64 }
                    )
                )
            )
        }
        _ = await source.deactivate()

        let capturedFrames = frames.frames
        XCTAssertFalse(capturedFrames.isEmpty)
        XCTAssertTrue(capturedFrames.allSatisfy { $0.sampleRate == 48_000 })
        XCTAssertTrue(capturedFrames.allSatisfy { $0.channelCount == 2 })
        XCTAssertTrue(capturedFrames.allSatisfy { $0.frameCount == 8 })
        XCTAssertTrue(capturedFrames.allSatisfy {
            $0.pcmFloat32LE.count == 8 * 2 * MemoryLayout<Float>.size
        })
        XCTAssertEqual(
            capturedFrames.map(\.sequenceNumber),
            capturedFrames.indices.map { UInt64($0 + 1) }
        )
    }

    func testCurrentProcessIsExcludedOnlyWhenConfigurationRequestsIt() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(currentProcessObjectID: 44)
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)

        try await source.activate(
            configuration: .systemOutput(
                displayID: 118,
                excludesCurrentProcessAudio: true
            ),
            callbacks: noOpCallbacks
        )
        _ = await source.deactivate()
        try await source.activate(
            configuration: .systemOutput(
                displayID: 118,
                excludesCurrentProcessAudio: false
            ),
            callbacks: noOpCallbacks
        )
        _ = await source.deactivate()

        let tapEvents = hal.events.compactMap { event -> [AudioObjectID]? in
            guard case .createProcessTap(_, _, let excludedIDs) = event else {
                return nil
            }
            return excludedIDs
        }
        XCTAssertEqual(tapEvents, [[44], []])
    }

    func testActivationRejectsAggregateThatRetainsTheWrongProcessTapUID() async {
        let hal = RecordingSystemAudioSuppressionHAL(
            aggregateTapUID: "not-the-created-tap"
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)

        do {
            try await source.activate(
                configuration: testConfiguration,
                callbacks: noOpCallbacks
            )
            XCTFail("Activation must reject an aggregate with the wrong retained tap UID")
        } catch let error as LumenSystemAudioPlaybackSuppressionError {
            guard case .activationFailed(
                let stage,
                let status,
                let message,
                let cleanupFailures
            ) = error else {
                return XCTFail("Unexpected typed source error: \(error)")
            }
            XCTAssertEqual(stage, .createAggregateDevice)
            XCTAssertEqual(status, -704)
            XCTAssertEqual(
                message,
                "The private aggregate did not retain the exact session process tap."
            )
            XCTAssertTrue(cleanupFailures.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            hal.events.map(\.shortName),
            [
                "tap-create",
                "tap-format",
                "aggregate-create",
                "aggregate-destroy",
                "tap-destroy",
            ]
        )
    }

    func testActivationRejectsAggregateWithNoInputStreams() async {
        let hal = RecordingSystemAudioSuppressionHAL(
            aggregateInputStreamCount: 0
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)

        do {
            try await source.activate(
                configuration: testConfiguration,
                callbacks: noOpCallbacks
            )
            XCTFail("Activation must reject an aggregate with no input streams")
        } catch let error as LumenSystemAudioPlaybackSuppressionError {
            guard case .activationFailed(
                let stage,
                let status,
                let message,
                let cleanupFailures
            ) = error else {
                return XCTFail("Unexpected typed source error: \(error)")
            }
            XCTAssertEqual(stage, .createAggregateDevice)
            XCTAssertEqual(status, -705)
            XCTAssertEqual(
                message,
                "The private aggregate published no input stream for the session process tap."
            )
            XCTAssertTrue(cleanupFailures.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            hal.events.map(\.shortName),
            [
                "tap-create",
                "tap-format",
                "aggregate-create",
                "aggregate-destroy",
                "tap-destroy",
            ]
        )
    }

    func testAudioObjectIDListUsesTheCompletedPropertyQueryByteCount() throws {
        XCTAssertEqual(
            try lumenAudioObjectIDs(
                from: [71],
                returnedDataSize: 0
            ),
            []
        )
        XCTAssertEqual(
            try lumenAudioObjectIDs(
                from: [71, 72],
                returnedDataSize: UInt32(MemoryLayout<AudioObjectID>.stride)
            ),
            [71]
        )
        XCTAssertThrowsError(
            try lumenAudioObjectIDs(
                from: [71],
                returnedDataSize: UInt32(MemoryLayout<AudioObjectID>.stride + 1)
            )
        )
        XCTAssertThrowsError(
            try lumenAudioObjectIDs(
                from: [kAudioObjectUnknown],
                returnedDataSize: UInt32(MemoryLayout<AudioObjectID>.stride)
            )
        )
    }

    func testActivationFailureDestroysEveryCreatedResourceInReverse() async {
        let hal = RecordingSystemAudioSuppressionHAL(
            activationFailureStage: .startIO
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)

        do {
            try await source.activate(
                configuration: testConfiguration,
                callbacks: noOpCallbacks
            )
            XCTFail("Expected system-audio source activation to fail")
        } catch let error as LumenSystemAudioPlaybackSuppressionError {
            guard case .activationFailed(
                let stage,
                let status,
                _,
                let cleanupFailures
            ) = error else {
                return XCTFail("Unexpected typed source error: \(error)")
            }
            XCTAssertEqual(stage, .startIO)
            XCTAssertEqual(status, -700)
            XCTAssertTrue(cleanupFailures.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            Array(hal.events.suffix(3)),
            [
                .destroyIOProc(deviceID: 22, ioProcID: 33),
                .destroyAggregateDevice(deviceID: 22),
                .destroyProcessTap(tapID: 11),
            ]
        )
    }

    func testCancellationDuringActivationDestroysEveryCreatedResource() async {
        let hal = RecordingSystemAudioSuppressionHAL(
            cancelAfterStage: .createAggregateDevice
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)

        do {
            try await source.activate(
                configuration: testConfiguration,
                callbacks: noOpCallbacks
            )
            XCTFail("Expected system-audio source activation to be cancelled")
        } catch let error as LumenSystemAudioPlaybackSuppressionError {
            XCTAssertEqual(error, .cancelled(cleanupFailures: []))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            Array(hal.events.suffix(2)),
            [
                .destroyAggregateDevice(deviceID: 22),
                .destroyProcessTap(tapID: 11),
            ]
        )
    }

    func testCleanupStopsAtFirstFailedStageAndRetainsDependentResources() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(
            cleanupStatuses: [
                .stopIO: -701,
                .destroyIOProc: -702,
                .destroyAggregateDevice: -703,
                .destroyProcessTap: -704,
            ]
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)

        try await source.activate(
            configuration: testConfiguration,
            callbacks: noOpCallbacks
        )
        let cleanupFailures = await source.deactivate()

        XCTAssertEqual(
            cleanupFailures,
            [.init(stage: .stopIO, status: -701)]
        )
        XCTAssertEqual(
            Array(hal.events.suffix(1)),
            [.stopIO(deviceID: 22, ioProcID: 33)]
        )
    }

    func testDeactivateFencesPCMDeliveryEvenWhenCoreAudioStopFails() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(
            cleanupStatuses: [.stopIO: -701]
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let frames = AudioFrameRecorder()

        try await source.activate(
            configuration: .systemOutput(
                displayID: 118,
                frameSize: 1
            ),
            callbacks: recordingCallbacks(frames: frames)
        )
        let failures = await source.deactivate()
        hal.emitPCM(
            .init(
                hostTimeNanoseconds: 10,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 1,
                pcmFloat32LE: pcmData([0.1, -0.1])
            )
        )

        XCTAssertEqual(
            failures,
            [.init(stage: .stopIO, status: -701)]
        )
        XCTAssertTrue(frames.frames.isEmpty)
    }

    func testDroppedTapInputClearsPartialPacketBeforeNextFrame() async throws {
        let hal = RecordingSystemAudioSuppressionHAL()
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let frames = AudioFrameRecorder()

        try await source.activate(
            configuration: .systemOutput(
                displayID: 118,
                frameSize: 2
            ),
            callbacks: recordingCallbacks(frames: frames)
        )
        hal.emitPCM(
            .init(
                hostTimeNanoseconds: 10,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 1,
                pcmFloat32LE: pcmData([0.1, 0.2])
            )
        )
        hal.emitDrop(message: "input discontinuity")
        hal.emitPCM(
            .init(
                hostTimeNanoseconds: 20,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 2,
                pcmFloat32LE: pcmData([0.8, 0.9, 1.0, 1.1])
            )
        )
        _ = await source.deactivate()

        XCTAssertEqual(frames.frames.count, 1)
        XCTAssertEqual(
            pcmFloats(frames.frames[0].pcmFloat32LE),
            [0.8, 0.9, 1.0, 1.1]
        )
    }

    func testFailedTeardownRetriesExactRemainingStageBeforeCreatingAnotherTap() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(
            cleanupStatusSequences: [
                .destroyAggregateDevice: [-703, noErr],
            ]
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)

        try await source.activate(
            configuration: testConfiguration,
            callbacks: noOpCallbacks
        )
        let initialFailures = await source.deactivate()
        XCTAssertEqual(
            initialFailures,
            [.init(stage: .destroyAggregateDevice, status: -703)]
        )

        try await source.activate(
            configuration: testConfiguration,
            callbacks: noOpCallbacks
        )

        XCTAssertEqual(
            hal.events.map(\.shortName),
            [
                "tap-create",
                "tap-format",
                "aggregate-create",
                "io-proc-create",
                "io-start",
                "io-stop",
                "io-proc-destroy",
                "aggregate-destroy",
                "aggregate-destroy",
                "tap-destroy",
                "tap-create",
                "tap-format",
                "aggregate-create",
                "io-proc-create",
                "io-start",
            ]
        )
    }

    func testPersistentTeardownFailureBlocksSecondTap() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(
            cleanupStatuses: [.destroyAggregateDevice: -703]
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)

        try await source.activate(
            configuration: testConfiguration,
            callbacks: noOpCallbacks
        )
        _ = await source.deactivate()

        do {
            try await source.activate(
                configuration: testConfiguration,
                callbacks: noOpCallbacks
            )
            XCTFail("Expected retained cleanup to block another tap")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    LumenSystemAudioPlaybackSuppressionStage
                        .destroyAggregateDevice.rawValue
                )
            )
        }
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 1)
    }

    func testSharedSessionAttachAndDetachUseTapIOProcWithoutSCKAudioOutput() async throws {
        let trace = SystemAudioSuppressionTrace()
        let hal = RecordingSystemAudioSuppressionHAL(trace: trace)
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let runtimeFactory = RecordingEncodedCaptureRuntimeFactory(trace: trace)
        let frames = AudioFrameRecorder()
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            systemAudioPlaybackSuppression: source,
            runtimeFactory: runtimeFactory
        )

        try await session.start(callbacks: noOpVideoCallbacks)
        try await session.attachSystemAudio(
            configuration: .systemOutput(
                displayID: 118,
                frameSize: 2
            ),
            callbacks: recordingCallbacks(frames: frames)
        )
        hal.emitPCM(
            .init(
                hostTimeNanoseconds: 10,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 2,
                pcmFloat32LE: pcmData([0.1, 0.2, 0.3, 0.4])
            )
        )
        await session.detachSystemAudio()
        await session.stop()

        XCTAssertEqual(frames.frames.count, 1)
        XCTAssertEqual(
            trace.events,
            [
                "video-start",
                "tap-create",
                "tap-format",
                "aggregate-create",
                "io-proc-create",
                "io-start",
                "io-stop",
                "io-proc-destroy",
                "aggregate-destroy",
                "tap-destroy",
                "video-stop",
            ]
        )
        XCTAssertEqual(runtimeFactory.makeCount, 1)
    }

    func testVideoStartErrorPreservesOriginalErrorAndTapCleanupFailure() async {
        let hal = RecordingSystemAudioSuppressionHAL(
            cleanupStatuses: [.destroyAggregateDevice: -703]
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let runtimeFactory = RecordingEncodedCaptureRuntimeFactory(
            startErrors: [SystemAudioSuppressionTestError.consumerStartFailed]
        )
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            preconfiguredSystemAudio: testConfiguration,
            preconfiguredSystemAudioCallbacks: noOpCallbacks,
            systemAudioPlaybackSuppression: source,
            runtimeFactory: runtimeFactory
        )

        do {
            try await session.start(callbacks: noOpVideoCallbacks)
            XCTFail("Expected encoded runtime startup to fail")
        } catch let error as LumenSystemAudioCaptureLifecycleError {
            XCTAssertEqual(
                error.underlyingError as? SystemAudioSuppressionTestError,
                .consumerStartFailed
            )
            XCTAssertEqual(
                error.cleanupFailures,
                [.init(stage: .destroyAggregateDevice, status: -703)]
            )
        } catch {
            XCTFail("Unexpected combined lifecycle error: \(error)")
        }
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 1)
    }

    func testAutomaticRestartDoesNotCreateDuplicateTapWhenCleanupFails() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(
            cleanupStatusSequences: [
                .destroyAggregateDevice: [-703, noErr],
            ]
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let runtimeFactory = RecordingEncodedCaptureRuntimeFactory()
        let audioEvents = Mutex<[LumenAudioCaptureSessionEvent]>([])
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            preconfiguredSystemAudio: testConfiguration,
            preconfiguredSystemAudioCallbacks: .init(
                frameHandler: { _ in },
                eventHandler: { event in
                    audioEvents.withLock { $0.append(event) }
                }
            ),
            systemAudioPlaybackSuppression: source,
            runtimeFactory: runtimeFactory
        )

        try await session.start(callbacks: noOpVideoCallbacks)
        runtimeFactory.terminateLatest(
            with: SystemAudioSuppressionTestError.unexpectedTermination
        )
        try await waitUntil {
            audioEvents.withLock {
                $0.contains { $0.kind == .failed }
            }
        }
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(runtimeFactory.makeCount, 1)
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 1)
        XCTAssertFalse(
            runtimeFactory.events.contains("video-restart-created")
        )
        let cleanupFailures = await session.stop()
        XCTAssertTrue(cleanupFailures.isEmpty)
        XCTAssertEqual(
            hal.events.map(\.shortName)
                .filter { $0 == "aggregate-destroy" }.count,
            2
        )
    }

    func testAutomaticRestartReusesSameSourceAfterCompleteReverseCleanup() async throws {
        let hal = RecordingSystemAudioSuppressionHAL()
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let runtimeFactory = RecordingEncodedCaptureRuntimeFactory()
        let restarted = Mutex(false)
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            preconfiguredSystemAudio: testConfiguration,
            preconfiguredSystemAudioCallbacks: noOpCallbacks,
            systemAudioPlaybackSuppression: source,
            runtimeFactory: runtimeFactory
        )

        try await session.start(
            callbacks: .init(
                frameHandler: { _ in },
                eventHandler: { event in
                    if event.kind == .restarted {
                        restarted.withLock { $0 = true }
                    }
                }
            )
        )
        runtimeFactory.terminateLatest(
            with: SystemAudioSuppressionTestError.unexpectedTermination
        )
        try await waitUntil {
            restarted.withLock { $0 } && runtimeFactory.makeCount == 2
        }

        XCTAssertEqual(runtimeFactory.makeCount, 2)
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 2)
        let names = hal.events.map(\.shortName)
        let firstTapDestroy = try XCTUnwrap(
            names.firstIndex(of: "tap-destroy")
        )
        let secondTapCreate = try XCTUnwrap(
            names.lastIndex(of: "tap-create")
        )
        XCTAssertLessThan(firstTapDestroy, secondTapCreate)
        await session.stop()
    }

    func testInjectedBridgeRuntimeUsesCoreAudioSourceForStandaloneSystemAudio() async throws {
        let hal = RecordingSystemAudioSuppressionHAL()
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let bridge = LumenBridgeRuntime(
            systemAudioPlaybackSuppression: source,
            encodedCaptureRuntimeFactory:
                RecordingEncodedCaptureRuntimeFactory()
        )
        await bridge.configureAudioForwarding(
            frameCapacity: 4,
            eventCapacity: 4
        )

        try await bridge.startAudioCapture(
            configuration: .systemOutput(
                displayID: 118,
                frameSize: 2
            )
        )
        hal.emitPCM(
            .init(
                hostTimeNanoseconds: 100,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 2,
                pcmFloat32LE: pcmData([0.1, 0.2, 0.3, 0.4])
            )
        )
        try await waitUntil {
            await bridge.audioForwardingSnapshot().frameCount == 1
        }
        let frame = await bridge.drainNextVideoForwardedAudioFrame()
        await bridge.stopAudioCapture()

        XCTAssertEqual(frame?.sampleRate, 48_000)
        XCTAssertEqual(frame?.channelCount, 2)
        XCTAssertEqual(frame?.frameCount, 2)
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 1)
    }

    func testInjectedBridgeRetainsCleanupDebtAcrossGenerationReset() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(
            cleanupStatusSequences: [
                .stopIO: [-701, noErr],
            ]
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let bridge = LumenBridgeRuntime(
            systemAudioPlaybackSuppression: source,
            encodedCaptureRuntimeFactory:
                RecordingEncodedCaptureRuntimeFactory()
        )
        await bridge.configureAudioForwarding(
            frameCapacity: 4,
            eventCapacity: 8
        )

        try await bridge.startAudioCapture(
            configuration: .systemOutput(
                displayID: 118,
                frameSize: 2
            )
        )
        await bridge.stopAudioCapture()
        XCTAssertEqual(
            hal.events.filter {
                if case .stopIO = $0 { return true }
                return false
            }.count,
            1
        )
        let firstStopSnapshot = await bridge.audioForwardingSnapshot()
        XCTAssertEqual(firstStopSnapshot.lastEventKind, .failed)

        await bridge.stopAudioCapture()
        XCTAssertEqual(
            hal.events.filter {
                if case .stopIO = $0 { return true }
                return false
            }.count,
            2
        )
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 1)
        XCTAssertEqual(
            hal.events.filter {
                if case .destroyProcessTap = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testInjectedBridgeSharedRouteAttachesAndDetachesSingleCoreAudioTap() async throws {
        let trace = SystemAudioSuppressionTrace()
        let hal = RecordingSystemAudioSuppressionHAL(trace: trace)
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let runtimeFactory =
            RecordingEncodedCaptureRuntimeFactory(trace: trace)
        let bridge = LumenBridgeRuntime(
            systemAudioPlaybackSuppression: source,
            encodedCaptureRuntimeFactory: runtimeFactory
        )
        await bridge.configureAudioForwarding(
            frameCapacity: 4,
            eventCapacity: 4
        )

        try await bridge.startCapture(
            configuration: .panelNative(displayID: 118)
        )
        try await bridge.startAudioCapture(
            configuration: .systemOutput(
                displayID: 118,
                frameSize: 2
            )
        )
        hal.emitPCM(
            .init(
                hostTimeNanoseconds: 100,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 2,
                pcmFloat32LE: pcmData([0.1, 0.2, 0.3, 0.4])
            )
        )
        try await waitUntil {
            await bridge.audioForwardingSnapshot().frameCount == 1
        }
        await bridge.stopAudioCapture()
        await bridge.stopCapture()

        XCTAssertEqual(
            trace.events,
            [
                "video-start",
                "tap-create",
                "tap-format",
                "aggregate-create",
                "io-proc-create",
                "io-start",
                "io-stop",
                "io-proc-destroy",
                "aggregate-destroy",
                "tap-destroy",
                "video-stop",
            ]
        )
        XCTAssertEqual(runtimeFactory.makeCount, 1)
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 1)
    }

    func testInjectedBridgeAutomaticRestartReleasesTapBeforeReplacement() async throws {
        let trace = SystemAudioSuppressionTrace()
        let hal = RecordingSystemAudioSuppressionHAL(trace: trace)
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let runtimeFactory =
            RecordingEncodedCaptureRuntimeFactory(trace: trace)
        let bridge = LumenBridgeRuntime(
            systemAudioPlaybackSuppression: source,
            encodedCaptureRuntimeFactory: runtimeFactory
        )

        try await bridge.startCapture(
            configuration: .panelNative(displayID: 118),
            preconfiguredSystemAudio: testConfiguration
        )
        runtimeFactory.terminateLatest(
            with: SystemAudioSuppressionTestError.unexpectedTermination
        )
        try await waitUntil {
            runtimeFactory.makeCount == 2 &&
                hal.events.filter(\.isTapCreate).count == 2
        }
        await bridge.stopCapture()

        let names = hal.events.map(\.shortName)
        let firstTapDestroy = try XCTUnwrap(
            names.firstIndex(of: "tap-destroy")
        )
        let secondTapCreate = try XCTUnwrap(
            names.lastIndex(of: "tap-create")
        )
        XCTAssertLessThan(firstTapDestroy, secondTapCreate)
        XCTAssertEqual(runtimeFactory.makeCount, 2)
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 2)
    }

    func testInjectedBridgeRejectsReplacementCaptureWhileAudioCleanupDebtRemains() async throws {
        let hal = RecordingSystemAudioSuppressionHAL(
            cleanupStatusSequences: [
                .stopIO: [-701, -701, noErr],
            ]
        )
        let source = LumenSystemAudioPlaybackSuppression(hal: hal)
        let runtimeFactory =
            RecordingEncodedCaptureRuntimeFactory()
        let bridge = LumenBridgeRuntime(
            systemAudioPlaybackSuppression: source,
            encodedCaptureRuntimeFactory: runtimeFactory
        )

        try await bridge.startCapture(
            configuration: .panelNative(displayID: 118),
            preconfiguredSystemAudio: testConfiguration
        )
        await bridge.stopCapture()

        do {
            try await bridge.startCapture(
                configuration: .panelNative(displayID: 118)
            )
            XCTFail("A replacement capture must not overwrite retained audio cleanup ownership")
        } catch let error as LumenSystemAudioCaptureLifecycleError {
            XCTAssertEqual(
                error.cleanupFailures,
                [.init(stage: .stopIO, status: -701)]
            )
        }

        XCTAssertEqual(runtimeFactory.makeCount, 1)
        XCTAssertEqual(
            hal.events.map(\.shortName)
                .filter { $0 == "io-stop" }.count,
            2
        )

        await bridge.stopCapture()
        XCTAssertEqual(
            hal.events.map(\.shortName)
                .filter { $0 == "io-stop" }.count,
            3
        )
        XCTAssertEqual(hal.events.filter(\.isTapCreate).count, 1)
    }
}

private let testConfiguration = LumenMacAudioCaptureConfiguration.systemOutput(
    displayID: 118,
    sampleRate: 48_000,
    channelCount: 2,
    frameSize: 480
)

private let noOpCallbacks = LumenAudioCaptureCallbacks(
    frameHandler: { _ in },
    eventHandler: nil
)

private let noOpVideoCallbacks = LumenEncodedCaptureCallbacks(
    frameHandler: { _ in },
    eventHandler: nil
)

private func recordingCallbacks(
    frames: AudioFrameRecorder
) -> LumenAudioCaptureCallbacks {
    LumenAudioCaptureCallbacks(
        frameHandler: { frame in
            frames.append(frame)
        },
        eventHandler: nil
    )
}

private final class AudioFrameRecorder: @unchecked Sendable {
    private let state = Mutex<[LumenAudioFrame]>([])

    var frames: [LumenAudioFrame] {
        state.withLock { $0 }
    }

    func append(_ frame: LumenAudioFrame) {
        state.withLock { $0.append(frame) }
    }
}

private func pcmData(_ values: [Float]) -> Data {
    values.withUnsafeBytes { Data($0) }
}

private func pcmFloats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    predicate: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for asynchronous condition")
}

private final class RecordingSystemAudioSuppressionHAL:
    LumenSystemAudioPlaybackSuppressionHAL,
    @unchecked Sendable
{
    enum Event: Equatable {
        case createProcessTap(
            muteBehavior: LumenSystemAudioPlaybackSuppressionMuteBehavior,
            isPrivate: Bool,
            excludedProcessObjectIDs: [AudioObjectID]
        )
        case readTapStreamFormat(tapID: AudioObjectID)
        case createAggregateDevice(tapUID: String)
        case createIOProc(deviceID: AudioObjectID)
        case startIO(deviceID: AudioObjectID, ioProcID: UInt)
        case stopIO(deviceID: AudioObjectID, ioProcID: UInt)
        case destroyIOProc(deviceID: AudioObjectID, ioProcID: UInt)
        case destroyAggregateDevice(deviceID: AudioObjectID)
        case destroyProcessTap(tapID: AudioObjectID)

        var shortName: String {
            switch self {
            case .createProcessTap: "tap-create"
            case .readTapStreamFormat: "tap-format"
            case .createAggregateDevice: "aggregate-create"
            case .createIOProc: "io-proc-create"
            case .startIO: "io-start"
            case .stopIO: "io-stop"
            case .destroyIOProc: "io-proc-destroy"
            case .destroyAggregateDevice: "aggregate-destroy"
            case .destroyProcessTap: "tap-destroy"
            }
        }

        var isTapCreate: Bool {
            if case .createProcessTap = self {
                return true
            }
            return false
        }
    }

    private let recordedEvents = Mutex<[Event]>([])
    private let bufferHandler = Mutex<
        (@Sendable (LumenSystemAudioPlaybackSuppressionIOEvent) -> Void)?
    >(nil)
    private let trace: SystemAudioSuppressionTrace?
    private let currentProcessObjectID: AudioObjectID?
    private let aggregateTapUID: String
    private let aggregateInputStreamCount: Int
    private let streamFormat:
        LumenSystemAudioPlaybackSuppressionStreamFormat
    private let activationFailureStage:
        LumenSystemAudioPlaybackSuppressionStage?
    private let cancelAfterStage: LumenSystemAudioPlaybackSuppressionStage?
    private let cleanupStatuses:
        [LumenSystemAudioPlaybackSuppressionStage: OSStatus]
    private let cleanupStatusSequences = Mutex<
        [LumenSystemAudioPlaybackSuppressionStage: [OSStatus]]
    >([:])

    init(
        trace: SystemAudioSuppressionTrace? = nil,
        currentProcessObjectID: AudioObjectID? = 44,
        aggregateTapUID: String = "test-tap",
        aggregateInputStreamCount: Int = 1,
        streamFormat:
            LumenSystemAudioPlaybackSuppressionStreamFormat = .init(
                sampleRate: 48_000,
                channelCount: 2,
                isInterleaved: true
            ),
        activationFailureStage:
            LumenSystemAudioPlaybackSuppressionStage? = nil,
        cancelAfterStage:
            LumenSystemAudioPlaybackSuppressionStage? = nil,
        cleanupStatuses:
            [LumenSystemAudioPlaybackSuppressionStage: OSStatus] = [:],
        cleanupStatusSequences:
            [LumenSystemAudioPlaybackSuppressionStage: [OSStatus]] = [:]
    ) {
        self.trace = trace
        self.currentProcessObjectID = currentProcessObjectID
        self.aggregateTapUID = aggregateTapUID
        self.aggregateInputStreamCount = aggregateInputStreamCount
        self.streamFormat = streamFormat
        self.activationFailureStage = activationFailureStage
        self.cancelAfterStage = cancelAfterStage
        self.cleanupStatuses = cleanupStatuses
        self.cleanupStatusSequences.withLock {
            $0 = cleanupStatusSequences
        }
    }

    var events: [Event] {
        recordedEvents.withLock { $0 }
    }

    func resolveCurrentProcessObjectID() throws -> AudioObjectID? {
        currentProcessObjectID
    }

    func createProcessTap(
        muteBehavior: LumenSystemAudioPlaybackSuppressionMuteBehavior,
        isPrivate: Bool,
        excludedProcessObjectIDs: [AudioObjectID]
    ) throws -> LumenSystemAudioPlaybackSuppressionTap {
        trace?.append("tap-create")
        record(
            .createProcessTap(
                muteBehavior: muteBehavior,
                isPrivate: isPrivate,
                excludedProcessObjectIDs: excludedProcessObjectIDs
            )
        )
        try failIfRequested(.createProcessTap)
        return LumenSystemAudioPlaybackSuppressionTap(
            id: 11,
            uid: "test-tap"
        )
    }

    func readTapStreamFormat(
        tapID: AudioObjectID
    ) throws -> LumenSystemAudioPlaybackSuppressionStreamFormat {
        trace?.append("tap-format")
        record(.readTapStreamFormat(tapID: tapID))
        try failIfRequested(.readTapStreamFormat)
        return streamFormat
    }

    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        trace?.append("aggregate-create")
        record(.createAggregateDevice(tapUID: tapUID))
        try failIfRequested(.createAggregateDevice)
        return 22
    }

    func validateAggregateDevice(
        deviceID: AudioObjectID,
        tapUID: String
    ) throws {
        guard tapUID == aggregateTapUID else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: -704,
                message: "The private aggregate did not retain the exact session process tap."
            )
        }
        guard aggregateInputStreamCount > 0 else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: -705,
                message: "The private aggregate published no input stream for the session process tap."
            )
        }
    }

    func createIOProc(
        deviceID: AudioObjectID,
        streamFormat:
            LumenSystemAudioPlaybackSuppressionStreamFormat,
        eventHandler: @escaping @Sendable (
            LumenSystemAudioPlaybackSuppressionIOEvent
        ) -> Void
    ) throws -> LumenSystemAudioPlaybackSuppressionIOProc {
        trace?.append("io-proc-create")
        record(.createIOProc(deviceID: deviceID))
        try failIfRequested(.createIOProc)
        bufferHandler.withLock { $0 = eventHandler }
        return LumenSystemAudioPlaybackSuppressionIOProc(
            id: 33,
            stopDelivering: { [weak self] in
                self?.bufferHandler.withLock { $0 = nil }
            }
        )
    }

    func startIO(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) throws {
        trace?.append("io-start")
        record(.startIO(deviceID: deviceID, ioProcID: ioProc.id))
        try failIfRequested(.startIO)
    }

    func stopIO(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) -> OSStatus {
        trace?.append("io-stop")
        record(.stopIO(deviceID: deviceID, ioProcID: ioProc.id))
        return cleanupStatus(for: .stopIO)
    }

    func destroyIOProc(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) -> OSStatus {
        trace?.append("io-proc-destroy")
        record(.destroyIOProc(deviceID: deviceID, ioProcID: ioProc.id))
        let status = cleanupStatus(for: .destroyIOProc)
        if status == noErr {
            bufferHandler.withLock { $0 = nil }
        }
        return status
    }

    func destroyAggregateDevice(deviceID: AudioObjectID) -> OSStatus {
        trace?.append("aggregate-destroy")
        record(.destroyAggregateDevice(deviceID: deviceID))
        return cleanupStatus(for: .destroyAggregateDevice)
    }

    func destroyProcessTap(tapID: AudioObjectID) -> OSStatus {
        trace?.append("tap-destroy")
        record(.destroyProcessTap(tapID: tapID))
        return cleanupStatus(for: .destroyProcessTap)
    }

    func emitPCM(
        _ buffer: LumenSystemAudioPlaybackSuppressionPCMBuffer
    ) {
        let handler = bufferHandler.withLock { $0 }
        handler?(.pcm(buffer))
    }

    func emitDrop(message: String) {
        let handler = bufferHandler.withLock { $0 }
        handler?(.dropped(message: message))
    }

    private func record(_ event: Event) {
        recordedEvents.withLock { $0.append(event) }
    }

    private func cleanupStatus(
        for stage: LumenSystemAudioPlaybackSuppressionStage
    ) -> OSStatus {
        let sequencedStatus: OSStatus? = cleanupStatusSequences.withLock {
            sequences in
            guard var statuses = sequences[stage], !statuses.isEmpty else {
                return nil
            }
            let status = statuses.removeFirst()
            sequences[stage] = statuses
            return status
        }
        return sequencedStatus ?? cleanupStatuses[stage] ?? noErr
    }

    private func failIfRequested(
        _ stage: LumenSystemAudioPlaybackSuppressionStage
    ) throws {
        if cancelAfterStage == stage {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        guard activationFailureStage == stage else {
            return
        }
        throw LumenSystemAudioPlaybackSuppressionHALOperationError(
            status: -700
        )
    }
}

private final class RecordingEncodedCaptureRuntimeFactory:
    LumenEncodedCaptureRuntimeFactory,
    @unchecked Sendable
{
    private struct State {
        var makeCount = 0
        var startErrors: [any Error]
        var terminationHandlers: [
            @Sendable (any Error) -> Void
        ] = []
        var events: [String] = []
    }

    private let state: Mutex<State>
    private let trace: SystemAudioSuppressionTrace?

    init(
        trace: SystemAudioSuppressionTrace? = nil,
        startErrors: [any Error] = []
    ) {
        self.trace = trace
        state = Mutex(State(startErrors: startErrors))
    }

    var makeCount: Int {
        state.withLock(\.makeCount)
    }

    var events: [String] {
        state.withLock(\.events)
    }

    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime {
        let startError: (any Error)? = state.withLock { state in
            state.makeCount += 1
            if state.makeCount > 1 {
                state.events.append("video-restart-created")
            }
            state.terminationHandlers.append(context.terminationHandler)
            return state.startErrors.isEmpty
                ? nil
                : state.startErrors.removeFirst()
        }
        return RecordingEncodedCaptureRuntime(
            trace: trace,
            startError: startError
        )
    }

    func terminateLatest(with error: any Error) {
        let handler = state.withLock { $0.terminationHandlers.last }
        handler?(error)
    }
}

private final class RecordingEncodedCaptureRuntime:
    LumenEncodedCaptureRuntime,
    @unchecked Sendable
{
    private let trace: SystemAudioSuppressionTrace?
    private let startError: (any Error)?

    init(
        trace: SystemAudioSuppressionTrace?,
        startError: (any Error)?
    ) {
        self.trace = trace
        self.startError = startError
    }

    func start() async throws {
        trace?.append("video-start")
        if let startError {
            throw startError
        }
    }

    func stop() async {
        trace?.append("video-stop")
    }

    func requestImmediateKeyFrame() {}

    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        true
    }
}

private enum SystemAudioSuppressionTestError:
    Error,
    Equatable,
    LocalizedError
{
    case consumerStartFailed
    case unexpectedTermination

    var errorDescription: String? {
        switch self {
        case .consumerStartFailed:
            "consumer-start-failed"
        case .unexpectedTermination:
            "unexpected-termination"
        }
    }
}

private final class SystemAudioSuppressionTrace: @unchecked Sendable {
    private let state = Mutex<[String]>([])

    var events: [String] {
        state.withLock { $0 }
    }

    func append(_ event: String) {
        state.withLock { $0.append(event) }
    }
}
