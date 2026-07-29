@testable import LumenMacBridge
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

        var cadence = LumenAdaptiveVideoAdmissionCadence()
        XCTAssertTrue(cadence.configure(divisor: 2))
        XCTAssertEqual(
            (0 ..< 6).map { _ in cadence.shouldAdmit() },
            [true, false, true, false, true, false]
        )
        await session.stop()
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
