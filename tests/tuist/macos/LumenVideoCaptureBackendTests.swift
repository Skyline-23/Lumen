@testable import LumenMacBridge
import CoreMedia
import CoreVideo
import Darwin
import IOSurface
import ScreenCaptureKit
import Synchronization
import XCTest

final class LumenVideoCaptureBackendTests: XCTestCase {
    private func makeOverlapRuntime() throws -> LumenScreenCaptureVideoRuntime {
        try LumenScreenCaptureVideoRuntime(
            configuration: LumenMacCaptureConfiguration(
                displayID: 42, codec: .hevc, videoProfile: .hevcMain,
                chromaSubsampling: .yuv420, bitDepth: 8, dynamicRange: .sdr,
                targetFrameRate: 120
            ),
            callbacks: .init(frameHandler: { _ in }, eventHandler: nil),
            statisticsHandler: { _ in }, terminationHandler: { _ in }
        )
    }

    func testOverlapNeverDelaysIdleOrBootstrapAndPreservesTwoSlotBound() throws {
        let runtime = try makeOverlapRuntime()
        runtime.queue.sync {
            runtime.encoderOverlapEpoch = runtime.mediaEpoch
            runtime.encoderOverlapNotBefore = ContinuousClock().now.advanced(by: .seconds(1))
            runtime.inflightFrameCount = 0
            XCTAssertTrue(runtime.hasFreshEncoderSubmissionCapacity())
            runtime.inflightFrameCount = 1
            XCTAssertTrue(runtime.hasFreshEncoderSubmissionCapacity())
            runtime.inflightFrameCount = 2
            XCTAssertFalse(runtime.hasFreshEncoderSubmissionCapacity())
            runtime.stopping = true
            runtime.inflightFrameCount = 0
            XCTAssertFalse(runtime.hasFreshEncoderSubmissionCapacity())
        }
    }

    func testOverlapRetiresOldEpochCadenceBeforeAdmission() throws {
        let runtime = try makeOverlapRuntime()
        runtime.queue.sync {
            runtime.encoderOverlapEpoch = runtime.mediaEpoch &+ 1
            runtime.encoderOverlapLastOutput = 1
            runtime.encoderOverlapIntervalMilliseconds = 500
            runtime.encoderOverlapNotBefore = ContinuousClock().now.advanced(by: .seconds(1))
            XCTAssertTrue(runtime.hasFreshEncoderSubmissionCapacity())
            XCTAssertNil(runtime.encoderOverlapLastOutput)
            XCTAssertNil(runtime.encoderOverlapIntervalMilliseconds)
            XCTAssertNil(runtime.encoderOverlapNotBefore)
        }
    }

    func testOverlapLearnsOnlyBusyIntervalsAndBoundsWakeAfterStall() throws {
        let runtime = try makeOverlapRuntime()
        let now = mach_absolute_time()
        let second = try XCTUnwrap(LumenMachTime.ticks(for: CMTime(seconds: 1, preferredTimescale: 1_000)))
        let context = LumenEncodedFrameContext(
            sequenceNumber: 1, displayTime: now - second,
            submissionMachTime: now - second, mediaEpoch: runtime.mediaEpoch,
            bootstrapReason: nil, requiresBootstrapAcknowledgement: false, sourceSurfaceLease: nil
        )
        runtime.queue.sync {
            runtime.encoderOverlapLastOutput = now - second / 2
            runtime.inflightFrameCount = 1
            runtime.observeEncoderOverlapOutput(context: context, rawCallbackMachTime: now)
            XCTAssertNotNil(runtime.encoderOverlapIntervalMilliseconds)
            if let deadline = runtime.encoderOverlapNotBefore {
                XCTAssertLessThanOrEqual(ContinuousClock().now.duration(to: deadline), .milliseconds(9))
            }
            runtime.inflightFrameCount = 0
            runtime.observeEncoderOverlapOutput(context: context, rawCallbackMachTime: now + 1)
            XCTAssertNil(runtime.encoderOverlapNotBefore)
        }
    }

    func testOverlapClockReplacesItsPendingWake() async {
        let clock = LumenEncoderOverlapClock()
        let stale = expectation(description: "superseded wake")
        stale.isInverted = true
        let current = expectation(description: "latest wake")
        await clock.schedule(until: ContinuousClock().now.advanced(by: .milliseconds(40))) {
            stale.fulfill()
        }
        await clock.schedule(until: ContinuousClock().now.advanced(by: .milliseconds(5))) {
            current.fulfill()
        }
        await fulfillment(of: [current, stale], timeout: 0.1)
    }

    func testSkyLightBackendIdentifiesDisplayStreamPath() {
        XCTAssertEqual(
            LumenVideoCaptureBackend.skyLightDisplayStream.rawValue,
            "skylight-display-stream"
        )
    }

    func testSkyLightRawBackendIsAvailableWithoutRestrictedEntitlement() {
        XCTAssertTrue(LumenSkyLightDisplayStream.isSupported())
    }

    func testSkyLightTerminalFailurePublishesStoppedStatistics() throws {
        let publishedStatistics = Mutex<
            LumenEncodedCaptureSessionStatistics?
        >(nil)
        let runtime = try LumenScreenCaptureVideoRuntime(
            configuration: LumenMacCaptureConfiguration(
                displayID: 42,
                codec: .hevc,
                videoProfile: .hevcMain,
                chromaSubsampling: .yuv420,
                bitDepth: 8,
                dynamicRange: .sdr,
                targetFrameRate: 120
            ),
            callbacks: .init(
                frameHandler: { _ in },
                eventHandler: nil
            ),
            statisticsHandler: { statistics in
                publishedStatistics.withLock {
                    $0 = statistics
                }
            },
            terminationHandler: { _ in }
        )

        runtime.queue.sync {
            runtime.statistics.isRunning = true
            runtime.compressionSessionAvailable = true
            runtime.processSkyLightFrame(
                status: .stopped,
                displayTime: 1,
                pixelBuffer: nil,
                pixelBufferStatus: kCVReturnSuccess
            )
        }

        XCTAssertFalse(
            try XCTUnwrap(publishedStatistics.withLock { $0 }).isRunning
        )
        runtime.queue.sync {
            XCTAssertTrue(runtime.stopping)
            XCTAssertFalse(runtime.compressionSessionAvailable)
        }
    }

    func testPreviouslyValidatedPendingSourceCanBeReofferedAfterBootstrapAck()
        throws
    {
        let runtime = try LumenScreenCaptureVideoRuntime(
            configuration: LumenMacCaptureConfiguration(
                displayID: 42,
                codec: .hevc,
                videoProfile: .hevcMain,
                chromaSubsampling: .yuv420,
                bitDepth: 8,
                dynamicRange: .sdr,
                targetFrameRate: 120
            ),
            callbacks: .init(frameHandler: { _ in }, eventHandler: nil),
            statisticsHandler: { _ in },
            terminationHandler: { _ in }
        )
        var pixelBufferValue: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                nil,
                &pixelBufferValue
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(pixelBufferValue)

        runtime.queue.sync {
            let source = runtime.makePendingSource(
                imageBuffer: pixelBuffer,
                presentationTime: CMTime(value: 1, timescale: 120),
                sourceDisplayTime: 1
            )
            XCTAssertFalse(source.hasValidatedEncoderOrdering)

            let firstOffer = runtime.validatedEncoderSourceForSubmission(source)
            XCTAssertNotNil(firstOffer)
            XCTAssertTrue(firstOffer?.hasValidatedEncoderOrdering == true)

            let reoffer = firstOffer.flatMap {
                runtime.validatedEncoderSourceForSubmission($0)
            }
            XCTAssertEqual(reoffer?.sequenceNumber, source.sequenceNumber)
            XCTAssertFalse(runtime.terminalContractFailureReported)
        }
    }

    func testSDR420UsesAVFoundationScreenInput() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            videoProfile: .hevcMain,
            chromaSubsampling: .yuv420,
            bitDepth: 8,
            dynamicRange: .sdr,
            targetFrameRate: 120
        )

        XCTAssertEqual(
            LumenVideoCaptureBackend.preferred(
                for: configuration,
                skyLightDisplayStreamAvailable: false
            ),
            .avFoundationScreenInput
        )
    }

    func testSDR420UsesAVFoundationBelow120WithoutAFPSPolicyGate() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            videoProfile: .hevcMain,
            chromaSubsampling: .yuv420,
            bitDepth: 8,
            dynamicRange: .sdr,
            targetFrameRate: 60
        )

        XCTAssertEqual(
            LumenVideoCaptureBackend.preferred(
                for: configuration,
                skyLightDisplayStreamAvailable: false
            ),
            .avFoundationScreenInput
        )
    }

    func testSDR420UsesSkyLightDisplayStreamWhenPrivateSymbolsAreAvailable() {
        let configuration = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            videoProfile: .hevcMain,
            chromaSubsampling: .yuv420,
            bitDepth: 8,
            dynamicRange: .sdr,
            targetFrameRate: 120
        )

        XCTAssertEqual(
            LumenVideoCaptureBackend.preferred(
                for: configuration,
                skyLightDisplayStreamAvailable: true
            ),
            .skyLightDisplayStream
        )
    }

    func testHDRUsesSkyLightAnd444KeepsScreenCaptureKitAt120() {
        let hdr = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            videoProfile: .hevcMain10,
            chromaSubsampling: .yuv420,
            bitDepth: 10,
            dynamicRange: .hdr10,
            targetFrameRate: 120
        )
        let yuv444 = LumenMacCaptureConfiguration(
            displayID: 42,
            codec: .hevc,
            videoProfile: .hevcMain444,
            chromaSubsampling: .yuv444,
            bitDepth: 8,
            dynamicRange: .sdr,
            colorRange: .full,
            targetFrameRate: 120
        )

        XCTAssertEqual(
            LumenVideoCaptureBackend.preferred(
                for: hdr,
                skyLightDisplayStreamAvailable: false
            ),
            .screenCaptureKit
        )
        XCTAssertEqual(
            LumenVideoCaptureBackend.preferred(
                for: hdr,
                skyLightDisplayStreamAvailable: true
            ),
            .skyLightDisplayStream
        )
        XCTAssertEqual(
            LumenVideoCaptureBackend.preferred(
                for: yuv444,
                skyLightDisplayStreamAvailable: true
            ),
            .screenCaptureKit
        )
    }

    func testSkyLightFrameLeaseOwnsIOSurfaceUseCount() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                64,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let resolvedPixelBuffer = try XCTUnwrap(pixelBuffer)
        let surface = try XCTUnwrap(
            CVPixelBufferGetIOSurface(resolvedPixelBuffer)?.takeUnretainedValue()
        )
        let originalUseCount = IOSurfaceGetUseCount(surface)

        var lease: LumenMacSkyLightDisplayStreamFrameLease? = try XCTUnwrap(
            LumenMacSkyLightDisplayStreamFrameLease.lease(
                withPixelBuffer: resolvedPixelBuffer
            )
        )
        withExtendedLifetime(lease) {
            XCTAssertEqual(
                IOSurfaceGetUseCount(surface),
                originalUseCount + 1
            )
        }

        lease = nil
        XCTAssertEqual(IOSurfaceGetUseCount(surface), originalUseCount)
    }

    func testScreenCaptureKitUsesRequestedFrameInterval() {
        XCTAssertEqual(
            LumenScreenCaptureCadence.minimumFrameInterval(
                targetFrameRate: 120
            ),
            CMTime(value: 1, timescale: 120)
        )
        XCTAssertEqual(
            LumenScreenCaptureCadence.minimumFrameInterval(
                targetFrameRate: 144
            ),
            CMTime(value: 1, timescale: 144)
        )
        XCTAssertEqual(
            LumenScreenCaptureCadence.minimumFrameInterval(
                targetFrameRate: 60
            ),
            CMTime(value: 1, timescale: 60)
        )
    }

    func testAdvertisedTurboThroughputModeUsesRuntimeModeID() {
        let supportedModes: NSDictionary = [
            "turbo": [
                ["ThroughputModeID": 17, "ThroughputModePerformance": 123],
                ["ThroughputModeID": 17, "ThroughputModePerformance": 123],
            ] as NSArray
        ]

        XCTAssertEqual(
            LumenVideoToolboxThroughputModeResolver.advertisedTurboModeID(
                from: supportedModes
            ),
            17
        )
    }

    func testAdvertisedTurboThroughputModeRejectsIncompleteOrInconsistentIDs() {
        let inconsistentModes: NSDictionary = [
            "turbo": [
                ["ThroughputModeID": 5],
                ["ThroughputModeID": 7],
            ] as NSArray
        ]
        let incompleteModes: NSDictionary = [
            "turbo": [
                ["ThroughputModeID": 5],
                ["ThroughputModePerformance": 7],
            ] as NSArray
        ]

        XCTAssertNil(
            LumenVideoToolboxThroughputModeResolver.advertisedTurboModeID(
                from: inconsistentModes
            )
        )
        XCTAssertNil(
            LumenVideoToolboxThroughputModeResolver.advertisedTurboModeID(
                from: incompleteModes
            )
        )
    }

    func testScreenCaptureKitMapsFullLogicalDisplayIntoHiDPIBackingSurface() {
        let configuration = SCStreamConfiguration()

        LumenScreenCaptureGeometry.applyFullDisplayMapping(
            to: configuration,
            sourceWidth: 1_210,
            sourceHeight: 834,
            outputWidth: 2_420,
            outputHeight: 1_668
        )

        XCTAssertEqual(
            configuration.sourceRect,
            CGRect(x: 0, y: 0, width: 1_210, height: 834)
        )
        XCTAssertEqual(
            configuration.destinationRect,
            CGRect(x: 0, y: 0, width: 2_420, height: 1_668)
        )
        XCTAssertTrue(configuration.scalesToFit)
        XCTAssertTrue(configuration.preservesAspectRatio)
    }
}
