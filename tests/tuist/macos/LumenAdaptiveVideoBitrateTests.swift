@testable import LumenMacBridge
import CoreMedia
import Synchronization
import VideoToolbox
import XCTest

final class LumenAdaptiveVideoBitrateTests: XCTestCase {
    func testRateControlDerivesVideoToolboxBitAndByteBudgetsFromKbps() throws {
        let control = try XCTUnwrap(
            LumenVideoToolboxRateControl(bitrateKbps: 48_000)
        )

        XCTAssertEqual(control.averageBitrateBitsPerSecond, 48_000_000)
        XCTAssertEqual(control.dataRateLimitBytesPerSecond, 6_000_000)
        XCTAssertEqual(control.dataRateLimitSeconds, 1)
        XCTAssertNil(LumenVideoToolboxRateControl(bitrateKbps: 0))
    }

    func testRateControlAppliesBothPropertiesToLiveVideoToolboxSession() throws {
        let control = try XCTUnwrap(
            LumenVideoToolboxRateControl(bitrateKbps: 48_000)
        )
        let session = try makeCompressionSession()
        defer { VTCompressionSessionInvalidate(session) }

        try control.apply(to: session)

        XCTAssertEqual(
            try copiedProperty(
                kVTCompressionPropertyKey_AverageBitRate,
                from: session
            ) as? Int,
            48_000_000
        )
        let limits = try XCTUnwrap(
            try copiedProperty(
                kVTCompressionPropertyKey_DataRateLimits,
                from: session
            ) as? [NSNumber]
        )
        XCTAssertEqual(limits.map(\.intValue), [6_000_000, 1])
    }

    func testEncodedBitrateTelemetryMeasuresActualOneSecondOutputRate() {
        var telemetry = LumenEncodedBitrateTelemetry()

        telemetry.observe(
            encodedByteCount: 500_000,
            atUptimeNanoseconds: 10
        )
        XCTAssertNil(telemetry.latestWindowBitrateKbps)

        telemetry.observe(
            encodedByteCount: 500_000,
            atUptimeNanoseconds: 1_000_000_010
        )

        XCTAssertEqual(telemetry.totalEncodedBytes, 1_000_000)
        XCTAssertEqual(
            try XCTUnwrap(telemetry.latestWindowBitrateKbps),
            8_000,
            accuracy: 0.001
        )
    }

    func testBitrateTelemetryIsIncludedInPublishedCaptureDiagnostics() {
        let expectedPrefixes = [
            "videoToolboxAppliedBitrateKbps=",
            "videoToolboxEncodedByteCount=",
            "videoToolboxEstimatedOutputBitrateKbps=",
            "videoToolboxOutputToAppliedBitratePercent=",
            "videoToolboxBitrateUpdateQueueWait",
            "videoToolboxBitrateUpdateApply"
        ]

        for prefix in expectedPrefixes {
            XCTAssertTrue(lumenCaptureDiagnosticPrefixes.contains(prefix))
        }
    }

    func testActiveEncodedSessionForwardsAdaptiveBitrateWithoutRestarting() async throws {
        let runtime = RecordingAdaptiveBitrateRuntime()
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            runtimeFactory: RecordingAdaptiveBitrateRuntimeFactory(
                runtime: runtime
            )
        )
        try await session.start(
            callbacks: .init(
                frameHandler: { _ in },
                eventHandler: nil
            )
        )

        let didApplyBitrate = await session.setVideoBitRateKbps(48_000)
        XCTAssertTrue(didApplyBitrate)
        XCTAssertEqual(runtime.bitrateUpdates, [48_000])
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.stopCount, 0)

        await session.stop()
    }

    func testPipelinePolicyReducesAdmissionWithoutLoweringBitrate() async throws {
        let runtime = RecordingAdaptiveBitrateRuntime()
        let session = LumenEncodedCaptureSession(
            configuration: .panelNative(displayID: 118),
            runtimeFactory: RecordingAdaptiveBitrateRuntimeFactory(runtime: runtime)
        )
        try await session.start(
            callbacks: .init(
                frameHandler: { _ in },
                eventHandler: nil
            )
        )

        let didApplyPolicy = await session.setVideoDeliveryPolicy(
            bitrateKbps: 18_491,
            admissionDivisor: 2
        )
        XCTAssertTrue(didApplyPolicy)
        XCTAssertEqual(runtime.deliveryPolicies, [.init(bitrate: 18_491, divisor: 2)])

        await session.stop()
    }

    func testFramePacerKeepsNegotiatedCeilingWhileRunningAtSixtyishTarget() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(
            bitrateKbps: 20_000,
            targetFrameRate: 120
        )

        XCTAssertTrue(
            state.apply(
                bitrateKbps: 20_000,
                admissionDivisor: 1,
                targetFrameRate: 60
            ) {}
        )
        XCTAssertEqual(state.frameRateCeiling, 120)
        XCTAssertEqual(state.targetFrameRate, 60)

        let first = state.admit(
            sourcePresentationTime: .zero,
            forceKeyFrame: false
        )
        let early = state.admit(
            sourcePresentationTime: CMTime(value: 1, timescale: 120),
            forceKeyFrame: false
        )
        let next = state.admit(
            sourcePresentationTime: CMTime(value: 2, timescale: 120),
            forceKeyFrame: false
        )

        XCTAssertEqual(first.durationSeconds ?? 0, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(early, .drop)
        XCTAssertEqual(next.durationSeconds ?? 0, 1.0 / 60.0, accuracy: 0.000_001)
    }

    func testFramePacerTargetRateIsAuthoritativeOverLegacyDivisor() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(
            bitrateKbps: 20_000,
            targetFrameRate: 120
        )

        XCTAssertTrue(
            state.apply(
                bitrateKbps: 20_000,
                admissionDivisor: 2,
                targetFrameRate: 60
            ) {}
        )

        // The source is already delivering at the selected 60 fps target.
        // A stale divisor of two must not turn this into 30 fps.
        let admissions = (0 ... 4).map { index in
            state.admit(
                sourcePresentationTime: CMTime(
                    value: CMTimeValue(index),
                    timescale: 60
                ),
                forceKeyFrame: false
            ).isAdmitted
        }
        XCTAssertEqual(admissions, [true, true, true, true, true])
    }

    func testFramePacerComposesEngineTargetAndClientDivisorOnce() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 120)

        XCTAssertTrue(
            state.apply(
                bitrateKbps: 20_000,
                admissionDivisor: 2,
                targetFrameRate: 120
            ) {}
        )
        XCTAssertEqual(state.targetFrameRate, 60)

        XCTAssertTrue(
            state.apply(
                bitrateKbps: 20_000,
                admissionDivisor: 2,
                targetFrameRate: 60
            ) {}
        )
        XCTAssertEqual(state.targetFrameRate, 60)

        XCTAssertTrue(
            state.apply(
                bitrateKbps: 20_000,
                admissionDivisor: 2,
                targetFrameRate: 40
            ) {}
        )
        XCTAssertEqual(state.targetFrameRate, 40)
    }

    func testFramePacerFractionalTargetPreservesAverageCadence() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 120)
        XCTAssertTrue(state.setTargetFrameRate(58))

        var admittedCount = 0
        for index in 0 ... 120 {
            let decision = state.admit(
                sourcePresentationTime: CMTime(
                    value: CMTimeValue(index),
                    timescale: 120
                ),
                forceKeyFrame: false
            )
            if decision.isAdmitted {
                admittedCount += 1
            }
        }

        // Include the frame at t=0; over a one-second 120 Hz source, the
        // fractional deadline should land within one frame of 58 admissions.
        XCTAssertTrue((57 ... 59).contains(admittedCount))
    }

    func testChangingTargetPreservesLastAdmittedPresentationTime() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 120)

        XCTAssertTrue(
            state.admit(
                sourcePresentationTime: .zero,
                forceKeyFrame: false
            ).isAdmitted
        )
        XCTAssertTrue(state.setTargetFrameRate(60))

        // Reconfiguring the target must not reset the PTS anchor.  This frame
        // is only 1/120 s after the admitted frame, so it remains early for
        // the new 60 fps cadence.
        XCTAssertEqual(
            state.admit(
                sourcePresentationTime: CMTime(value: 1, timescale: 120),
                forceKeyFrame: false
            ),
            .drop
        )
        XCTAssertTrue(
            state.admit(
                sourcePresentationTime: CMTime(value: 1, timescale: 60),
                forceKeyFrame: false
            ).isAdmitted
        )
    }

    func testInvalidTargetDoesNotPartiallyMutatePacer() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 120)
        _ = state.admit(
            sourcePresentationTime: .zero,
            forceKeyFrame: false
        )

        XCTAssertFalse(state.setTargetFrameRate(0))
        XCTAssertEqual(state.targetFrameRate, 120)
        XCTAssertEqual(
            state.admit(
                sourcePresentationTime: CMTime(value: 1, timescale: 240),
                forceKeyFrame: false
            ),
            .drop
        )
    }

    func testPolicyApplyFailureLeavesAllValueStateUntouched() {
        enum Failure: Error { case rejected }

        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 120)
        let before = state

        XCTAssertFalse(
            state.apply(
                bitrateKbps: 24_000,
                admissionDivisor: 2,
                targetFrameRate: 60
            ) {
                throw Failure.rejected
            }
        )
        XCTAssertEqual(state, before)
    }

    func testPacerHandlesInvalidTimestampWithoutCorruptingPTSAnchor() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 60)

        let invalid = state.admit(
            sourcePresentationTime: .invalid,
            forceKeyFrame: false
        )
        XCTAssertTrue(invalid.isAdmitted)
        XCTAssertEqual(
            invalid.durationSeconds ?? 0,
            1.0 / 60.0,
            accuracy: 0.000_001
        )

        XCTAssertTrue(
            state.admit(
                sourcePresentationTime: .zero,
                forceKeyFrame: false
            ).isAdmitted
        )
        XCTAssertEqual(
            state.admit(
                sourcePresentationTime: CMTime(value: 1, timescale: 120),
                forceKeyFrame: false
            ),
            .drop
        )
    }

    func testRustAdaptiveFrameCadenceControllerStartsAtRequestedCeiling() {
        let controller = LumenAdaptiveFrameCadenceController(
            requestedFrameRate: 120
        )
        XCTAssertEqual(controller?.targetFrameRate, 120)
        let decision = controller?.observe(
            monotonicTimeSeconds: 1,
            sourceFrameCount: 1,
            outputFrameCount: 1,
            pendingDropCount: 0,
            callbackLatencyMilliseconds: 0
        )
        XCTAssertEqual(decision, .init(targetFrameRate: 120, changed: false))
    }

    func testFramePacerUsesAdmittedVariablePTSForDuration() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 120)

        _ = state.admit(
            sourcePresentationTime: .zero,
            forceKeyFrame: false
        )
        let variable = state.admit(
            sourcePresentationTime: CMTime(value: 1, timescale: 90),
            forceKeyFrame: false
        )
        let longGap = state.admit(
            sourcePresentationTime: CMTime(value: 1, timescale: 3),
            forceKeyFrame: false
        )

        XCTAssertEqual(variable.durationSeconds ?? 0, 1.0 / 90.0, accuracy: 0.000_001)
        XCTAssertEqual(
            longGap.durationSeconds ?? 0,
            LumenAdaptiveVideoFrameTiming.maximumDurationSeconds,
            accuracy: 0.000_001
        )
    }

    func testFramePacerForceAdmitsBootstrapAndRepairKeyFrames() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 60)
        _ = state.admit(
            sourcePresentationTime: .zero,
            forceKeyFrame: false
        )
        state.beginStopping()

        let repair = state.admit(
            sourcePresentationTime: CMTime(value: 1, timescale: 120),
            forceKeyFrame: true
        )

        XCTAssertTrue(repair.isAdmitted)
    }

    func testFramePacerRecoversMonotonicallyAfterEarlyAndOutOfOrderPTS() {
        var state = LumenAdaptiveVideoDeliveryPolicyState()
        state.beginRunning(bitrateKbps: 20_000, targetFrameRate: 60)

        _ = state.admit(
            sourcePresentationTime: .zero,
            forceKeyFrame: false
        )
        XCTAssertEqual(
            state.admit(
                sourcePresentationTime: CMTime(value: 1, timescale: 120),
                forceKeyFrame: false
            ),
            .drop
        )
        let admitted = state.admit(
            sourcePresentationTime: CMTime(value: 1, timescale: 60),
            forceKeyFrame: false
        )
        XCTAssertTrue(admitted.isAdmitted)
        XCTAssertEqual(
            state.admit(
                sourcePresentationTime: CMTime(value: 1, timescale: 120),
                forceKeyFrame: false
            ),
            .drop
        )
        let recovered = state.admit(
            sourcePresentationTime: CMTime(value: 2, timescale: 60),
            forceKeyFrame: false
        )

        XCTAssertTrue(recovered.isAdmitted)
        XCTAssertEqual(recovered.durationSeconds ?? 0, 1.0 / 60.0, accuracy: 0.000_001)
    }

    func testFrameDurationUsesFiniteFallbackAndClamp() {
        XCTAssertEqual(
            LumenAdaptiveVideoFrameTiming.durationSeconds(
                from: nil,
                targetFrameRate: 120
            ),
            1.0 / 120.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LumenAdaptiveVideoFrameTiming.durationSeconds(
                from: .infinity,
                targetFrameRate: 120
            ),
            1.0 / 120.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LumenAdaptiveVideoFrameTiming.durationSeconds(
                from: 1.0,
                targetFrameRate: 120
            ),
            LumenAdaptiveVideoFrameTiming.maximumDurationSeconds,
            accuracy: 0.000_001
        )
    }

    func testRuntimeRejectsPolicyFromReplacedCaptureIdentity() async throws {
        let runtime = RecordingAdaptiveBitrateRuntime()
        let bridge = LumenBridgeRuntime(
            systemAudioPlaybackSuppression: LumenSystemAudioPlaybackSuppression(
                hal: LumenCoreAudioSystemAudioPlaybackSuppressionHAL()
            ),
            encodedCaptureRuntimeFactory: RecordingAdaptiveBitrateRuntimeFactory(
                runtime: runtime
            )
        )
        let original = LumenMacCaptureConfiguration(
            displayID: 118,
            sessionEpoch: 7,
            policyRevision: 1
        )
        try await bridge.startCapture(configuration: original)
        let replacement = LumenMacCaptureConfiguration(
            displayID: 118,
            sessionEpoch: 7,
            policyRevision: 2
        )
        try await bridge.startCapture(configuration: replacement)

        let stalePolicyApplied = await bridge.setVideoDeliveryPolicy(
            sessionEpoch: 7,
            policyRevision: 1,
            bitrateKbps: 18_491,
            admissionDivisor: 2
        )
        let currentPolicyApplied = await bridge.setVideoDeliveryPolicy(
            sessionEpoch: 7,
            policyRevision: 2,
            bitrateKbps: 18_491,
            admissionDivisor: 2
        )
        XCTAssertFalse(stalePolicyApplied)
        XCTAssertTrue(currentPolicyApplied)
        XCTAssertEqual(
            runtime.deliveryPolicies,
            [.init(bitrate: 18_491, divisor: 2)]
        )

        await bridge.stopCapture()
    }

    func testStoppingQueuedBeforePolicyRejectsWithoutPartialBitrateMutation() {
        let queue = DispatchQueue(label: "dev.skyline23.lumen.tests.adaptive-policy")
        let blocker = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let box = AdaptivePolicyStateBox()
        box.state.beginRunning(bitrateKbps: 18_491)

        queue.async {
            blocker.wait()
        }
        queue.async {
            box.state.beginStopping()
        }
        queue.async {
            box.didApply = box.state.apply(
                bitrateKbps: 24_000,
                admissionDivisor: 2
            ) {
                box.bitrateApplyCount += 1
            }
            finished.signal()
        }

        blocker.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(box.didApply)
        XCTAssertEqual(box.bitrateApplyCount, 0)
        XCTAssertEqual(box.state.appliedBitrateKbps, 18_491)
        XCTAssertEqual(box.state.admissionDivisor, 1)
    }
}

private extension LumenAdaptiveVideoBitrateTests {
    func makeCompressionSession() throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 64,
            height: 64,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(session)
    }

    func copiedProperty(
        _ key: CFString,
        from session: VTCompressionSession
    ) throws -> Any? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session,
                key: key,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        XCTAssertEqual(status, noErr)
        return value
    }
}

private struct RecordingAdaptiveBitrateRuntimeFactory:
    LumenEncodedCaptureRuntimeFactory {
    let runtime: RecordingAdaptiveBitrateRuntime

    func makeRuntime(
        context _: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime {
        runtime
    }
}

private final class AdaptivePolicyStateBox: @unchecked Sendable {
    var state = LumenAdaptiveVideoDeliveryPolicyState()
    var bitrateApplyCount = 0
    var didApply = false
}

private final class RecordingAdaptiveBitrateRuntime:
    LumenEncodedCaptureRuntime,
    @unchecked Sendable {
    private struct State {
        var bitrateUpdates: [Int] = []
        var deliveryPolicies: [DeliveryPolicy] = []
        var startCount = 0
        var stopCount = 0
    }

    struct DeliveryPolicy: Equatable {
        let bitrate: Int
        let divisor: Int
    }

    private let state = Mutex(State())

    var bitrateUpdates: [Int] {
        state.withLock { $0.bitrateUpdates }
    }

    var deliveryPolicies: [DeliveryPolicy] {
        state.withLock { $0.deliveryPolicies }
    }

    var startCount: Int {
        state.withLock { $0.startCount }
    }

    var stopCount: Int {
        state.withLock { $0.stopCount }
    }

    func start() async throws {
        state.withLock { $0.startCount += 1 }
    }

    func stop() async {
        state.withLock { $0.stopCount += 1 }
    }

    func requestImmediateKeyFrame() {}

    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        true
    }

    func setVideoBitRateKbps(_ bitrateKbps: Int) async -> Bool {
        state.withLock { $0.bitrateUpdates.append(bitrateKbps) }
        return true
    }


    func setVideoDeliveryPolicy(
        bitrateKbps: Int,
        admissionDivisor: Int
    ) async -> Bool {
        state.withLock {
            $0.deliveryPolicies.append(
                .init(bitrate: bitrateKbps, divisor: admissionDivisor)
            )
        }
        return true
    }
}
