import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import ShadowVCRuntime
import XCTest

final class LumenShadowVC4RuntimeTests: XCTestCase {
    func testSourceQuantizationBoundsEveryGrayCodeAndPreservesReferences() async throws {
        let configuration = try ShadowVC4Configuration(width: 256, height: 2)
        XCTAssertThrowsError(try ShadowVC4Encoder(configuration: configuration, sourceQuantizationStep: 3))
        for step in [UInt32(1), 2, 4, 8] {
            let encoder = try ShadowVC4Encoder(configuration: configuration, sourceQuantizationStep: step)
            let decoder = try ShadowVC4PlaneDecoder(configuration: configuration)
            var pixel: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
            XCTAssertEqual(CVPixelBufferCreate(nil, 256, 2, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &pixel), kCVReturnSuccess)
            let source = try XCTUnwrap(pixel)
            for frameID in 1...4 {
                CVPixelBufferLockBaseAddress(source, [])
                let base = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt32.self)
                let stride = CVPixelBufferGetBytesPerRow(source)/4
                for y in 0..<2 { for x in 0..<256 {
                    let value = UInt32((x+frameID*13)%256)
                    base[y*stride+x] = 0xff000000 | value << 16 | value << 8 | value
                } }
                CVPixelBufferUnlockBaseAddress(source, [])
                let frame = try await encoder.encode(.init(source), frameID: UInt32(frameID))
                let decoded = try await decoder.decode(frame)
                for y in 0..<2 { for x in 0..<256 {
                    let original = UInt32((x+frameID*13)%256)
                    let expected = min(255, ((original+step/2)/step)*step)
                    XCTAssertEqual(decoded[0][y*256+x], UInt8(expected))
                    XCTAssertLessThanOrEqual(abs(Int(decoded[0][y*256+x])-Int(original)), Int(step/2))
                } }
                XCTAssertTrue(decoded[1].allSatisfy { $0 == 128 })
                XCTAssertTrue(decoded[2].allSatisfy { $0 == 128 })
            }
        }
    }
    func testFullRuntimeTimingOnHeldOutDesktop() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LUMEN_FC4_FIXTURE"], let reportPath = environment["LUMEN_FC4_REPORT"] else {
            throw XCTSkip("Set LUMEN_FC4_FIXTURE and LUMEN_FC4_REPORT for the bounded local codec timing gate")
        }
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 3840); XCTAssertGreaterThanOrEqual(image.height, 2400)
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let canvas = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width*4, space: color,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let input = try XCTUnwrap(canvas.data)
        let configuration = try ShadowVC4Configuration(width: 3840, height: 2160)
        let encoder = try ShadowVC4Encoder(configuration: configuration)
        let decoder = try ShadowVC4Decoder(configuration: configuration)
        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixel), kCVReturnSuccess)
        let source = try XCTUnwrap(pixel)
        var rows: [[String: Any]] = []
        for index in 0..<120 {
            CVPixelBufferLockBaseAddress(source, [])
            let target = CVPixelBufferGetBaseAddress(source)!, stride = CVPixelBufferGetBytesPerRow(source)
            let offset = (index % 100)*2
            for y in 0..<2160 {
                target.advanced(by: y*stride).copyMemory(from: input.advanced(by: y*3840*4), byteCount: 3840*4)
                if (160..<2000).contains(y) {
                    target.advanced(by: y*stride+160*4).copyMemory(from: input.advanced(by: ((y+offset)*3840+160)*4), byteCount: 1680*4)
                }
            }
            CVPixelBufferUnlockBaseAddress(source, [])
            let start = ProcessInfo.processInfo.systemUptime
            let frame = try await encoder.encode(.init(source), frameID: UInt32(index+1))
            let encoded = frame.serialized()
            let encodedAt = ProcessInfo.processInfo.systemUptime
            let parsed = try ShadowVC4Frame(data: encoded, configuration: configuration)
            let decoded = try await decoder.decode(parsed)
            let decodedAt = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(CVPixelBufferGetWidth(decoded.value), 3840)
            let packMS = await encoder.lastPackMilliseconds, nativeMS = await encoder.lastNativeMilliseconds
            let timings = await encoder.lastPlaneTimings
            rows.append(["frame": index+1, "bytes": encoded.count, "intra": frame.isKeyframe,
                         "encode_ms": (encodedAt-start)*1000, "decode_ms": (decodedAt-encodedAt)*1000,
                         "pack_ms": packMS, "native_ms": nativeMS,
                         "planes": timings.map { ["motion_ms": $0.motionMilliseconds,
                             "transform_ms": $0.transformMilliseconds, "entropy_ms": $0.entropyMilliseconds] }])
        }
        let report: [String: Any] = ["scope": "local BGRA -> Metal -> parallel native SCV2 -> Metal P010; includes initial frame; no capture/network/iPad/display",
            "width": 3840, "height": 2160, "frames": 120, "rows": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: reportPath))
    }
    func testMetalRoundtripPreservesUniformAndSinglePixelLines() async throws {
        for (width, height, level, lines) in [(2, 2, 0, false), (2, 2, 255, false), (1282, 1090, 127, false), (1282, 1090, 255, true)] {
            let configuration = try ShadowVC4Configuration(width: width, height: height)
            let encoder = try ShadowVC4Encoder(configuration: configuration)
            let decoder = try ShadowVC4Decoder(configuration: configuration)
            var pixel: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
            XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                               attributes as CFDictionary, &pixel), kCVReturnSuccess)
            let source = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(source, [])
            let base = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(source)/4
            for y in 0..<height { for x in 0..<width {
                let value = UInt32(lines && x % 8 == 3 ? 0 : level)
                base[y*stride+x] = 0xff000000 | (value << 16) | (value << 8) | value
            } }
            CVPixelBufferUnlockBaseAddress(source, [])
            let frame = try await encoder.encode(.init(source), frameID: 1)
            let restored = try await decoder.decode(frame)
            let output = restored.value
            CVPixelBufferLockBaseAddress(output, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
            let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)/2
            var mismatches = 0
            for y in 0..<height { for x in 0..<width {
                let value = lines && x % 8 == 3 ? 0 : level
                let expected = Int((Double(value)*876/255+64).rounded())
                if Int(luma[y*yStride+x] >> 6) != expected { mismatches += 1 }
            } }
            XCTAssertEqual(mismatches, 0, "luma altered at \(width)x\(height), level \(level), lines \(lines)")
            let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
            let cStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)/2
            var tinted = 0
            for y in 0..<height/2 { for x in 0..<width { if chroma[y*cStride+x] >> 6 != 512 { tinted += 1 } } }
            XCTAssertEqual(tinted, 0, "neutral gray must remain neutral")
        }
    }
    private func pixels(width: Int, height: Int, seed: Int) -> [Data] {
        (0..<3).map { plane in
            let count = width*height/(plane == 0 ? 1 : 4)
            return Data((0..<count).map { UInt8(($0*13 + ($0/43)*7 + seed + plane*17) % 256) })
        }
    }
    func testExactPlanesAtSmallAndPartialGeometry() async throws {
        for (width, height) in [(2, 2), (1282, 1090)] {
            let configuration = try ShadowVC4Configuration(width: width, height: height)
            XCTAssertEqual(try ShadowVC4Configuration(record: configuration.record), configuration)
            let encoder = try ShadowVC4PlaneEncoder(configuration: configuration)
            let decoder = try ShadowVC4PlaneDecoder(configuration: configuration)
            for frameID in 1...3 {
                let source = pixels(width: width, height: height, seed: frameID)
                let frame = try await encoder.encode(source, frameID: UInt32(frameID))
                let received = try ShadowVC4Frame(data: frame.serialized(), configuration: configuration)
                XCTAssertEqual(received.isKeyframe, frameID == 1)
                let decoded = try await decoder.decode(received)
                XCTAssertEqual(decoded, source)
            }
        }
    }
    func testPlaneFailureInvalidatesTheWholeReferenceAndIntraRecovers() async throws {
        let configuration = try ShadowVC4Configuration(width: 258, height: 130)
        let encoder = try ShadowVC4PlaneEncoder(configuration: configuration)
        let decoder = try ShadowVC4PlaneDecoder(configuration: configuration)
        let first = try await encoder.encode(pixels(width: 258, height: 130, seed: 1), frameID: 1)
        _ = try await decoder.decode(first)
        let source = pixels(width: 258, height: 130, seed: 2)
        let second = try await encoder.encode(source, frameID: 2)
        var packets = second.planes
        packets[1][packets[1].count-1] ^= 1
        let corrupt = try ShadowVC4Frame(id: second.id, parent: second.parent, configuration: configuration, planes: packets)
        do { _ = try await decoder.decode(corrupt); XCTFail("corrupt chroma accepted") } catch {}
        do { _ = try await decoder.decode(second); XCTFail("partial reference was reused") } catch {}
        do { _ = try await decoder.decode(first); XCTFail("old intra replay accepted") } catch {}
        let repair = try await encoder.encode(source, frameID: 3, forceKeyframe: true)
        let decoded = try await decoder.decode(repair)
        XCTAssertEqual(decoded, source)
        var bytes = repair.serialized(); bytes[bytes.count-1] ^= 1
        XCTAssertThrowsError(try ShadowVC4Frame(data: bytes, configuration: configuration))
    }
    func testMissingFrameRequiresMatchingReference() async throws {
        let configuration = try ShadowVC4Configuration(width: 128, height: 128)
        let encoder = try ShadowVC4PlaneEncoder(configuration: configuration)
        let decoder = try ShadowVC4PlaneDecoder(configuration: configuration)
        let source = pixels(width: 128, height: 128, seed: 9)
        let first = try await encoder.encode(source, frameID: 1)
        _ = try await decoder.decode(first)
        _ = try await encoder.encode(source, frameID: 2)
        let third = try await encoder.encode(source, frameID: 3)
        do { _ = try await decoder.decode(third); XCTFail("missing reference accepted") } catch {}
        let repair = try await encoder.encode(source, frameID: 4, forceKeyframe: true)
        let decoded = try await decoder.decode(repair)
        XCTAssertEqual(decoded, source)
    }
}
