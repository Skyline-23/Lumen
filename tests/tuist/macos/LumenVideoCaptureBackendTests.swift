@testable import LumenMacBridge
import CoreMedia
import CoreVideo
import IOSurface
import ScreenCaptureKit
import Synchronization
import XCTest

final class LumenVideoCaptureBackendTests: XCTestCase {
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
