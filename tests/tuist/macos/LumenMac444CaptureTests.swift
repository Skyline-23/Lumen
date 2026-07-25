import CoreGraphics
import CoreMedia
import CoreVideo
@testable import LumenMacBridge
import XCTest

final class LumenMac444CaptureTests: XCTestCase {
    func testBridgeConfigurationRoundTripsExact444Plan() {
        let configuration = makeConfiguration(
            codec: .hevc,
            profile: .hevcMain44410,
            bitDepth: 10,
            dynamicRange: .hdr10,
            colorRange: .limited
        )

        let roundTrip = LumenBridgeConfigurationBox(configuration: configuration).swiftValue

        XCTAssertEqual(roundTrip.videoProfile, .hevcMain44410)
        XCTAssertEqual(roundTrip.chromaSubsampling, .yuv444)
        XCTAssertEqual(roundTrip.bitDepth, 10)
        XCTAssertEqual(roundTrip.dynamicRange, .hdr10)
        XCTAssertEqual(roundTrip.colorRange, .limited)
    }

    func testExact444PlansSelectDirectScreenCaptureKitFormats() {
        let h264 = makeConfiguration(codec: .h264, profile: .h264High444Predictive)
        let hevc = makeConfiguration(codec: .hevc, profile: .hevcMain444)
        let hevc10 = makeConfiguration(
            codec: .hevc,
            profile: .hevcMain44410,
            bitDepth: 10,
            dynamicRange: .hdr10,
            colorRange: .limited
        )

        XCTAssertEqual(h264.effectiveCapturePixelFormat, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(hevc.effectiveCapturePixelFormat, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(hevc10.effectiveCapturePixelFormat, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        let streamConfiguration = LumenCaptureStreamConfigurationFactory.make(configuration: hevc10)
        XCTAssertEqual(streamConfiguration.pixelFormat, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        XCTAssertEqual(streamConfiguration.captureDynamicRange, .hdrCanonicalDisplay)
        XCTAssertTrue(streamConfiguration.showsCursor)
    }

    func test444EncodingPlanUsesOnlyRuntimeProbedHardwareProfile() throws {
        let configuration = makeConfiguration(
            codec: .hevc,
            profile: .hevcMain44410,
            bitDepth: 10,
            dynamicRange: .hdr10,
            colorRange: .limited
        )

        let plan = try LumenVideoToolboxEncodingPlanResolver.resolve(
            configuration: configuration,
            availableHardware444Profiles: [
                .hevcMain44410: "HEVC_Main44410_AutoLevel"
            ]
        )

        XCTAssertEqual(plan.profile, "HEVC_Main44410_AutoLevel")
        XCTAssertEqual(plan.pixelFormat, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        XCTAssertEqual(plan.expectedConfiguration, .hevc(chromaFormatIdc: 3, lumaBitDepth: 10, chromaBitDepth: 10))
        XCTAssertThrowsError(
            try LumenVideoToolboxEncodingPlanResolver.resolve(
                configuration: configuration,
                availableHardware444Profiles: [:]
            )
        ) { error in
            XCTAssertEqual(error as? LumenExactCaptureError, .requiredHardwareProfileUnavailable(.hevcMain44410))
        }
    }

    func test444SourceContractRequiresFullResolutionPlanesAndColorAttachments() throws {
        let configuration = makeConfiguration(codec: .h264, profile: .h264High444Predictive)
        let contract = try LumenExactCaptureSourceContract(
            configuration: configuration,
            width: 16,
            height: 12
        )
        let buffer = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            width: 16,
            height: 12
        )
        attachSDRColor(to: buffer)

        XCTAssertNil(contract.mismatchDescription(for: buffer))
        XCTAssertEqual(CVPixelBufferGetWidthOfPlane(buffer, 1), 16)
        XCTAssertEqual(CVPixelBufferGetHeightOfPlane(buffer, 1), 12)

        let unexpected420 = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            width: 16,
            height: 12
        )
        attachSDRColor(to: unexpected420)
        XCTAssertEqual(
            contract.mismatchDescription(for: unexpected420),
            "pixel-format expected=444f actual=x420"
        )

        let hdrContract = try LumenExactCaptureSourceContract(
            configuration: makeConfiguration(
                codec: .hevc,
                profile: .hevcMain44410,
                bitDepth: 10,
                dynamicRange: .hdr10,
                colorRange: .limited
            ),
            width: 16,
            height: 12
        )
        let missingHDRAttachments = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
            width: 16,
            height: 12
        )
        XCTAssertEqual(
            hdrContract.mismatchDescription(for: missingHDRAttachments),
            "primaries expected=ITU_R_2020 actual=missing"
        )
    }

    func testEncodedOutputContractRejectsMismatchedAVCCAndHVCC() throws {
        let h264 = try LumenExactEncodedOutputContract(
            configuration: makeConfiguration(codec: .h264, profile: .h264High444Predictive)
        )
        XCTAssertNil(h264.mismatchDescription(codecConfigurationData: Data([1, 244, 0, 52])))
        XCTAssertEqual(
            h264.mismatchDescription(codecConfigurationData: Data([1, 100, 0, 52])),
            "AVC profile expected=244 actual=100"
        )

        let hevc = try LumenExactEncodedOutputContract(
            configuration: makeConfiguration(
                codec: .hevc,
                profile: .hevcMain44410,
                bitDepth: 10,
                dynamicRange: .hdr10,
                colorRange: .limited
            )
        )
        XCTAssertNil(hevc.mismatchDescription(codecConfigurationData: hvcc(chroma: 3, depth: 10)))
        XCTAssertEqual(
            hevc.mismatchDescription(codecConfigurationData: hvcc(chroma: 1, depth: 10)),
            "HEVC configuration expected=chroma:3/luma:10/chroma-depth:10 actual=chroma:1/luma:10/chroma-depth:10"
        )
    }

    func testFirstEncodedFrameGateRejectsStaleGenerationAndTimesOut() async throws {
        let gate = LumenFirstEncodedFrameGate()
        let staleGeneration = await gate.beginCapture()
        let activeGeneration = await gate.beginCapture()
        await gate.resolve(generation: staleGeneration)

        do {
            try await gate.wait(for: activeGeneration, timeoutNanoseconds: 5_000_000)
            XCTFail("stale output must not satisfy the active capture")
        } catch {
            XCTAssertEqual(error as? LumenFirstEncodedFrameReadinessError, .timedOut)
        }

        let successfulGeneration = await gate.beginCapture()
        await gate.resolve(generation: successfulGeneration)
        try await gate.wait(for: successfulGeneration, timeoutNanoseconds: 5_000_000)
    }

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
        let eventCountAfterFailedRuntimeWasFenced =
            events.snapshot.count
        runtimeFactory.emitLateStartedEvent(runtimeID: 1)
        XCTAssertEqual(
            events.snapshot.count,
            eventCountAfterFailedRuntimeWasFenced
        )

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

        XCTAssertEqual(runtimeFactory.makeCount, 2)
        XCTAssertEqual(runtimeFactory.startCount(for: 2), 1)
        XCTAssertEqual(runtimeFactory.stopCount(for: 2), 1)
        XCTAssertFalse(runtimeFactory.isRunning(runtimeID: 2))
        let eventCountAfterStop = events.snapshot.count
        runtimeFactory.emitLateStartedEvent(runtimeID: 2)
        XCTAssertEqual(events.snapshot.count, eventCountAfterStop)
    }

    func testLiveRequiredHardware444CaptureWritesAuditArtifactWhenRequested() async throws {
        guard let artifactPath = ProcessInfo.processInfo.environment["LUMEN_VT444_CAPTURE_ARTIFACT_PATH"] else {
            throw XCTSkip("Set LUMEN_VT444_CAPTURE_ARTIFACT_PATH for permission-gated ScreenCaptureKit QA")
        }
        let artifactURL = URL(fileURLWithPath: artifactPath)
        try? FileManager.default.removeItem(at: artifactURL)

        let configurations = [
            makeConfiguration(codec: .h264, profile: .h264High444Predictive, targetFrameRate: 60),
            makeConfiguration(codec: .hevc, profile: .hevcMain444, targetFrameRate: 120),
            makeConfiguration(
                codec: .hevc,
                profile: .hevcMain44410,
                bitDepth: 10,
                dynamicRange: .hdr10,
                colorRange: .limited,
                targetFrameRate: 60
            )
        ]
        var audits: [LumenExactCaptureAuditSnapshot] = []
        for configuration in configurations {
            audits.append(try await captureAudit(configuration: configuration))
        }
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(audits).write(to: artifactURL, options: .atomic)

        XCTAssertEqual(audits.map(\.inputFourCC), ["444f", "444f", "xf44"])
        XCTAssertEqual(audits.map(\.lumaPlaneWidth), [192, 192, 192])
        XCTAssertEqual(audits.map(\.lumaPlaneHeight), [108, 108, 108])
        XCTAssertEqual(audits.map(\.chromaPlaneWidth), [192, 192, 192])
        XCTAssertEqual(audits.map(\.chromaPlaneHeight), [108, 108, 108])
        XCTAssertEqual(
            audits.map(\.profile),
            [
                "H264_High444Predictive_AutoLevel",
                "HEVC_Main444_AutoLevel",
                "HEVC_Main44410_AutoLevel"
            ]
        )
        XCTAssertTrue(audits.allSatisfy { $0.hardwareUsed == true })
        XCTAssertEqual(audits.map(\.configurationAtom), ["avcC", "hvcC", "hvcC"])
        XCTAssertEqual(audits[0].profileIdc, 244)
        XCTAssertEqual(audits[1].chromaFormatIdc, 3)
        XCTAssertEqual(audits[1].lumaBitDepth, 8)
        XCTAssertEqual(audits[1].chromaBitDepth, 8)
        XCTAssertEqual(audits[2].chromaFormatIdc, 3)
        XCTAssertEqual(audits[2].lumaBitDepth, 10)
        XCTAssertEqual(audits[2].chromaBitDepth, 10)
        XCTAssertTrue(audits.allSatisfy { $0.conversionCount == 0 })
        XCTAssertEqual(audits[2].colorPrimaries, "ITU_R_2020")
        XCTAssertEqual(audits[2].transferFunction, "SMPTE_ST_2084_PQ")
        XCTAssertEqual(audits[2].yCbCrMatrix, "ITU_R_2020")
    }

    private func makeConfiguration(
        codec: LumenCaptureCodec,
        profile: LumenCaptureVideoProfile,
        bitDepth: Int = 8,
        dynamicRange: LumenCaptureDynamicRange = .sdr,
        colorRange: LumenCaptureColorRange = .full,
        targetFrameRate: Int = 120
    ) -> LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
            displayID: CGMainDisplayID(),
            codec: codec,
            videoProfile: profile,
            chromaSubsampling: .yuv444,
            bitDepth: bitDepth,
            dynamicRange: dynamicRange,
            colorRange: colorRange,
            targetFrameRate: targetFrameRate,
            targetVideoBitRateKbps: 20_000,
            requestedWidth: 192,
            requestedHeight: 108,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: dynamicRange == .hdr10 ? .rec2020 : .srgb,
                    transfer: dynamicRange == .hdr10 ? .pq : .sdr,
                    supportsFrameGatedHDR: dynamicRange == .hdr10,
                    supportsPerFrameHDRMetadata: dynamicRange == .hdr10
                ),
                dynamicRangeTransport: dynamicRange == .hdr10
                    ? LumenMacDynamicRangeTransportFullFrameHDR
                    : LumenMacDynamicRangeTransportSDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: dynamicRange == .hdr10 ? .rec2020 : .srgb,
                transfer: dynamicRange == .hdr10 ? .pq : .sdr
            )
        )
    }

    private func captureAudit(
        configuration: LumenMacCaptureConfiguration
    ) async throws -> LumenExactCaptureAuditSnapshot {
        let session = LumenEncodedCaptureSession(
            configuration: configuration,
            runtimeFactory:
                LumenProductionEncodedCaptureRuntimeFactory()
        )
        let gate = LumenFirstEncodedFrameGate()
        let generation = await gate.beginCapture()
        try await session.start(
            callbacks: LumenEncodedCaptureCallbacks(
                frameHandler: { frame in
                    Task {
                        await gate.resolve(
                            generation: generation,
                            sequenceNumber: frame.sourceSequenceNumber
                        )
                    }
                },
                eventHandler: nil
            )
        )
        do {
            try await gate.wait(for: generation, timeoutNanoseconds: 5_000_000_000)
            var audit = await session.statisticsSnapshot().exactCaptureAudit
            for _ in 0 ..< 100 {
                if audit.configurationAtom != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
                audit = await session.statisticsSnapshot().exactCaptureAudit
            }
            await session.stop()
            return audit
        } catch {
            let statistics = await session.statisticsSnapshot()
            await session.stop()
            if let lastErrorDescription = statistics.lastErrorDescription {
                throw NSError(
                    domain: "LumenMac444CaptureTests.LiveCapture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: lastErrorDescription]
                )
            }
            throw error
        }
    }

    private func makePixelBuffer(
        pixelFormat: OSType,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                pixelFormat,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        return try XCTUnwrap(pixelBuffer)
    }

    private func attachSDRColor(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }

    private func hvcc(chroma: UInt8, depth: UInt8) -> Data {
        var data = Data(repeating: 0, count: 23)
        data[0] = 1
        data[16] = 0xFC | chroma
        data[17] = 0xF8 | (depth - 8)
        data[18] = 0xF8 | (depth - 8)
        return data
    }
}

private actor LumenMac444CaptureRuntimeStartGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor LumenMac444CaptureRuntimeStartedLatch {
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

private final class LumenMac444CaptureEventRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.mac444-event-recorder"
    )
    private var events: [LumenEncodedCaptureSessionEvent] = []

    func append(_ event: LumenEncodedCaptureSessionEvent) {
        queue.sync {
            events.append(event)
        }
    }

    var snapshot: [LumenEncodedCaptureSessionEvent] {
        queue.sync { events }
    }
}

private final class LumenMac444CaptureRuntimeFactory:
    LumenEncodedCaptureRuntimeFactory,
    @unchecked Sendable
{
    private struct State {
        var makeCount = 0
        var startCounts: [Int: Int] = [:]
        var stopCounts: [Int: Int] = [:]
        var contexts: [Int: LumenEncodedCaptureRuntimeContext] = [:]
        var runningRuntimeIDs: Set<Int> = []
    }

    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.mac444-runtime-factory"
    )
    private let replacementStartGate: LumenMac444CaptureRuntimeStartGate
    private let gatedRuntimeID: Int?
    private let replacementStartEntered: @Sendable () -> Void
    private let runtimeStartCompleted: @Sendable () -> Void
    private let runtimeCreated: @Sendable (Int) -> Void
    private let lateStartedRuntimeStopped: @Sendable () -> Void
    private let runtimeStartedLatch =
        LumenMac444CaptureRuntimeStartedLatch()
    private var state = State()

    init(
        gatedRuntimeID: Int? = 2,
        replacementStartGate: LumenMac444CaptureRuntimeStartGate,
        replacementStartEntered: @escaping @Sendable () -> Void,
        runtimeStartCompleted: @escaping @Sendable () -> Void = {},
        runtimeCreated: @escaping @Sendable (Int) -> Void = { _ in },
        lateStartedRuntimeStopped: @escaping @Sendable () -> Void = {}
    ) {
        self.gatedRuntimeID = gatedRuntimeID
        self.replacementStartGate = replacementStartGate
        self.replacementStartEntered = replacementStartEntered
        self.runtimeStartCompleted = runtimeStartCompleted
        self.runtimeCreated = runtimeCreated
        self.lateStartedRuntimeStopped = lateStartedRuntimeStopped
    }

    var makeCount: Int {
        queue.sync { state.makeCount }
    }

    func startCount(for runtimeID: Int) -> Int {
        queue.sync { state.startCounts[runtimeID, default: 0] }
    }

    func stopCount(for runtimeID: Int) -> Int {
        queue.sync { state.stopCounts[runtimeID, default: 0] }
    }

    func isRunning(runtimeID: Int) -> Bool {
        queue.sync { state.runningRuntimeIDs.contains(runtimeID) }
    }

    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime {
        let runtimeID = queue.sync {
            state.makeCount += 1
            state.contexts[state.makeCount] = context
            return state.makeCount
        }
        runtimeCreated(runtimeID)
        return LumenMac444CaptureRuntime(runtimeID: runtimeID, factory: self)
    }

    func terminate(
        runtimeID: Int,
        error: LumenMac444CaptureRuntimeError = .terminated
    ) {
        let handler = queue.sync { state.contexts[runtimeID]?.terminationHandler }
        handler?(error)
    }

    func emitLateStartedEvent(runtimeID: Int) {
        let handler = queue.sync { state.contexts[runtimeID]?.callbacks.eventHandler }
        handler?(.init(kind: .started, message: "late-started"))
    }

    fileprivate func start(runtimeID: Int) async {
        queue.sync {
            state.startCounts[runtimeID, default: 0] += 1
        }
        if runtimeID == gatedRuntimeID {
            replacementStartEntered()
            await replacementStartGate.wait()
        }
        _ = queue.sync {
            state.runningRuntimeIDs.insert(runtimeID)
        }
        await runtimeStartedLatch.markStarted(runtimeID: runtimeID)
        if runtimeID == gatedRuntimeID {
            runtimeStartCompleted()
        }
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
        let wasRunning = queue.sync {
            state.stopCounts[runtimeID, default: 0] += 1
            return state.runningRuntimeIDs.remove(runtimeID) != nil
        }
        if runtimeID > 1, wasRunning {
            lateStartedRuntimeStopped()
        }
    }
}

private final class LumenMac444CaptureRuntime:
    LumenEncodedCaptureRuntime,
    @unchecked Sendable
{
    private let runtimeID: Int
    private let factory: LumenMac444CaptureRuntimeFactory

    init(runtimeID: Int, factory: LumenMac444CaptureRuntimeFactory) {
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

private enum LumenMac444CaptureRuntimeError: Error {
    case terminated
    case originalTermination
    case replacementTermination
    case startupTermination
}
