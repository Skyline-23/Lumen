@testable import LumenMacBridge
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Synchronization
import XCTest

final class LumenShadowVCContentCadenceTests: XCTestCase {
    func testMetadataOnlyIdleLowersTargetWithoutEvictingLastCompleteImage() async throws {
        let controller = try XCTUnwrap(LumenUnchangedContentCadenceController(requestedFrameRate: 120))
        let (frames, continuation) = AsyncStream<LumenShadowVCCapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = LumenShadowVCStreamOutput(continuation: continuation, contentCadence: controller,
            currentEpoch: { 7 }, pipelineStable: { true }, takeWakeRequest: { _ in false }, failed: { _ in })
        let complete = try sample(status: .complete, dirtyRects: [NSValue(rect: .init(x: 0, y: 0, width: 2, height: 2))])
        let idle = try sample(status: .idle)
        XCTAssertNil(idle.imageBuffer)
        output.process(complete, monotonicTimeSeconds: 0)
        output.process(idle, monotonicTimeSeconds: 0.01)
        output.process(idle, monotonicTimeSeconds: 1.01)
        XCTAssertEqual(controller.targetFrameRate, 1)
        output.finish()
        var iterator = frames.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertNotNil(first?.sample.value.imageBuffer)
        XCTAssertEqual(first?.epoch, 7)
        let second = await iterator.next()
        XCTAssertNil(second)
        XCTAssertEqual(output.droppedFrames.load(ordering: .relaxed), 0)
    }

    func testInputWakeReopensCadenceBeforeTheNextUnchangedImage() async throws {
        let controller = try XCTUnwrap(LumenUnchangedContentCadenceController(requestedFrameRate: 120))
        let wakeEpoch = Atomic<UInt64>(0)
        let stable = Atomic(true)
        let (frames, continuation) = AsyncStream<LumenShadowVCCapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = LumenShadowVCStreamOutput(continuation: continuation, contentCadence: controller,
            currentEpoch: { 7 }, pipelineStable: { stable.load(ordering: .acquiring) },
            takeWakeRequest: { wakeEpoch.exchange(0, ordering: .acquiringAndReleasing) == $0 }, failed: { _ in })
        let idle = try sample(status: .idle)
        let unchanged = try sample(status: .complete, dirtyRects: [])
        output.process(idle, monotonicTimeSeconds: 0)
        output.process(idle, monotonicTimeSeconds: 1)
        XCTAssertEqual(controller.targetFrameRate, 1)
        wakeEpoch.store(6, ordering: .releasing)
        output.process(idle, monotonicTimeSeconds: 1.01)
        XCTAssertEqual(controller.targetFrameRate, 1, "A retired media epoch cannot wake this capture")
        wakeEpoch.store(7, ordering: .releasing)
        output.process(unchanged, monotonicTimeSeconds: 1.02)
        XCTAssertEqual(controller.targetFrameRate, 120)
        output.process(idle, monotonicTimeSeconds: 2.01)
        XCTAssertEqual(controller.targetFrameRate, 120)
        output.process(idle, monotonicTimeSeconds: 2.02)
        XCTAssertEqual(controller.targetFrameRate, 1)
        stable.store(false, ordering: .releasing)
        output.process(idle, monotonicTimeSeconds: 2.03)
        XCTAssertEqual(controller.targetFrameRate, 120, "Bootstrap/repair cannot inherit idle pacing")
        output.process(idle, monotonicTimeSeconds: 5)
        XCTAssertEqual(controller.targetFrameRate, 120)
        output.finish()
        var iterator = frames.makeAsyncIterator()
        let frame = await iterator.next()
        XCTAssertNotNil(frame?.sample.value.imageBuffer)
    }

    func testMovingContentAndUntrustedMetadataReopenWithoutInput() throws {
        let controller = try XCTUnwrap(LumenUnchangedContentCadenceController(requestedFrameRate: 120))
        let (_, continuation) = AsyncStream<LumenShadowVCCapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = LumenShadowVCStreamOutput(continuation: continuation, contentCadence: controller,
            currentEpoch: { 1 }, pipelineStable: { true }, takeWakeRequest: { _ in false }, failed: { _ in })
        let idle = try sample(status: .idle)
        output.process(idle, monotonicTimeSeconds: 0)
        output.process(idle, monotonicTimeSeconds: 1)
        XCTAssertEqual(controller.targetFrameRate, 1)
        let moving = try sample(status: .complete, dirtyRects: [NSValue(rect: .init(x: 0, y: 0, width: 2, height: 2))])
        for tick in 0..<240 {
            output.process(moving, monotonicTimeSeconds: 1.01 + Double(tick) / 120)
            XCTAssertEqual(controller.targetFrameRate, 120)
        }
        output.process(idle, monotonicTimeSeconds: 4)
        output.process(idle, monotonicTimeSeconds: 5)
        XCTAssertEqual(controller.targetFrameRate, 1)
        output.process(try sample(status: .complete), monotonicTimeSeconds: 5.01)
        XCTAssertEqual(controller.targetFrameRate, 120, "Missing damage rectangles fail open")
        output.finish()
    }

    func testInactiveOrStaleSessionInputIsRejected() throws {
        let runtime = LumenShadowVCCaptureRuntime(context: .init(configuration: .init(
            displayID: 0, sessionEpoch: 7, codec: .shadowVC, videoProfile: .shadowVCLuma16),
            callbacks: .init(frameHandler: { _ in }), statisticsHandler: { _ in }, terminationHandler: { _ in }),
            modelDirectory: nil,
            contentCadence: try XCTUnwrap(LumenUnchangedContentCadenceController(requestedFrameRate: 120)))
        XCTAssertFalse(runtime.wakeUnchangedContentCadence(sessionEpoch: 6))
        XCTAssertFalse(runtime.wakeUnchangedContentCadence(sessionEpoch: 7))
    }

    private func sample(status: SCFrameStatus, dirtyRects: [NSValue]? = nil) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        if status == .complete {
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
            let image = try XCTUnwrap(pixel)
            var format: CMVideoFormatDescription?
            XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescriptionOut: &format), noErr)
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        } else {
            XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
                formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        }
        let result = try XCTUnwrap(sample)
        let array = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        let values: [String: Any] = [SCStreamFrameInfo.status.rawValue: NSNumber(value: status.rawValue)]
        for (key, value) in values {
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key as NSString).toOpaque(),
                Unmanaged.passUnretained(value as AnyObject).toOpaque())
        }
        if let dirtyRects {
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(SCStreamFrameInfo.dirtyRects.rawValue as NSString).toOpaque(),
                Unmanaged.passUnretained(dirtyRects as NSArray).toOpaque())
        }
        return result
    }
}
