import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import XCTest
@testable import LumenMacBridge

private actor ShadowVCCaptureProbe {
    var count = 0
    var bytes = 0
    var first: Double?
    var last: Double?
    var payload: Data?
    var failure: String?
    func record(_ frame: LumenEncodedFrame) {
        let time = ProcessInfo.processInfo.systemUptime
        count += 1; bytes += frame.sampleBuffer.totalSampleSize
        if first == nil { first = time }; last = time
        if payload == nil, let block = CMSampleBufferGetDataBuffer(frame.sampleBuffer) {
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let length = data.count
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            payload = data
        }
    }
    func fail(_ error: any Error) { failure = String(describing: error) }
}

final class LumenShadowVCCaptureTests: XCTestCase {
    func testShadowVCRejectsHDRAnd444InsteadOfChangingTheFormat() throws {
        let valid = LumenMacCaptureConfiguration(displayID: 0, codec: .shadowVC,
            videoProfile: .shadowVCSpatialBase16, bitDepth: 10, dynamicRange: .sdr,
            requestedWidth: 3840, requestedHeight: 2160)
        XCTAssertNoThrow(try valid.validateExactVideoFormat())
        let hdr = LumenMacCaptureConfiguration(displayID: 0, codec: .shadowVC,
            videoProfile: .shadowVCSpatialBase16, bitDepth: 10, dynamicRange: .hdr10,
            requestedWidth: 3840, requestedHeight: 2160)
        XCTAssertThrowsError(try hdr.validateExactVideoFormat())
        let fullChroma = LumenMacCaptureConfiguration(displayID: 0, codec: .shadowVC,
            videoProfile: .shadowVCSpatialBase16, chromaSubsampling: .yuv444,
            bitDepth: 10, dynamicRange: .sdr, requestedWidth: 3840, requestedHeight: 2160)
        XCTAssertThrowsError(try fullChroma.validateExactVideoFormat())
    }

    @MainActor
    func testIndependentVirtualDisplayCoreAICapture() async throws {
        guard #available(macOS 27, *), ProcessInfo.processInfo.environment["LUMEN_SHADOWVC_LIVE_TEST"] == "1" else {
            throw XCTSkip("Enable LUMEN_SHADOWVC_LIVE_TEST for the independent virtual-display capture check")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen recording access is unavailable; do not open a permission prompt from automation")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = root.appendingPathComponent("artifacts/ShadowVCModels")
        let config = LumenMacVirtualDisplayConfiguration()
        config.name = "ShadowVC independent capture validation"
        config.backingWidth = 3840; config.backingHeight = 2160
        config.maximumBackingWidth = 3840; config.maximumBackingHeight = 2160
        config.logicalWidth = 1920; config.logicalHeight = 1080
        config.highDensity = true; config.refreshRate = 120; config.hdrEnabled = false
        let display = try LumenMacVirtualDisplay(configuration: config)
        defer { display.destroy() }
        var screen: NSScreen?
        for _ in 0..<30 {
            screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
            if screen != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let target = try XCTUnwrap(screen)
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(display.displayID))
        XCTAssertEqual(mode.width,1920)
        XCTAssertEqual(mode.height,1080)
        XCTAssertEqual(mode.pixelWidth,3840)
        XCTAssertEqual(mode.pixelHeight,2160)
        let window = NSWindow(contentRect: target.frame,styleMask: .borderless,backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating
        window.ignoresMouseEvents = true
        let view = NSView(frame: NSRect(origin: .zero,size: target.frame.size))
        view.wantsLayer = true; window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        let probe = ShadowVCCaptureProbe()
        let runtime = LumenShadowVCCaptureRuntime(context: .init(configuration: .init(displayID: display.displayID,
            codec: .shadowVC,videoProfile: .shadowVCSpatialBase16,bitDepth: 10,dynamicRange: .sdr,
            targetFrameRate: 120,requestedWidth: 3840,requestedHeight: 2160),
            callbacks: .init(frameHandler: { frame in Task { await probe.record(frame) } },eventHandler: nil),
            statisticsHandler: { _ in },terminationHandler: { error in Task { await probe.fail(error) } }),modelDirectory: model)
        do {
            try await runtime.start()
            for tick in 0..<1200 {
                view.layer?.backgroundColor = NSColor(calibratedRed: CGFloat(tick%255)/255,green: 0.35,blue: CGFloat((tick*7)%255)/255,alpha: 1).cgColor
                if tick == 15 { _ = await runtime.resumeVideoEncodingAfterCodecAck() }
                try await Task.sleep(for: .milliseconds(8))
            }
            await runtime.stop()
        } catch { await runtime.stop(); throw error }
        let count = await probe.count, bytes = await probe.bytes
        let firstValue = await probe.first, lastValue = await probe.last
        let first = try XCTUnwrap(firstValue), last = try XCTUnwrap(lastValue)
        let failure = await probe.failure
        XCTAssertNil(failure)
        XCTAssertGreaterThan(count,100)
        let duration = last-first
        let report: [String: Any] = ["scope":"product SCK to Core AI sender; no network or client display",
            "width":3840,"height":2160,"frames":count,"bytes":bytes,"duration_seconds":duration,
            "fps":Double(count-1)/duration]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("artifacts/fc3-product-capture.json"))
        let capturedPayload = await probe.payload
        let payload = try XCTUnwrap(capturedPayload)
        try payload.write(to:root.appendingPathComponent("artifacts/fc3-product-capture.scv1"))
    }
}
