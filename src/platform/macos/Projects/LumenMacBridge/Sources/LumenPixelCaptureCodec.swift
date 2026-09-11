import Foundation
import ShadowVC3Pixel
import ShadowVCRuntime

struct LumenPixelCaptureCodec {
    let encoder: PixelFrameEncoder

    static func load(width: Int, height: Int, hdr: Bool) async throws -> Self {
        let bundle = PixelCodecResources.bundle
        let directory = try PixelCodecResources.directory(in: bundle, width: width, height: height)
        let shader = try PixelCodecResources.shaderSource(in: bundle)
        let encoder = try await PixelFrameEncoder(
            directory: directory, shaderSource: shader, dynamicRange: hdr ? .hdr10 : .sdr)
        return Self(encoder: encoder)
    }

    func encode(
        _ pixel: ShadowVCPixelBuffer,
        frameID: UInt32,
        forceKeyframe: Bool
    ) async throws -> (bytes: Data, keyframe: Bool, prepared: Bool, hasPixelChanges: Bool) {
        let frame = try await encoder.prepare(
            surface: PixelSurface(pixel.value), generation: frameID, quantizer: 12,
            forceKeyframe: forceKeyframe)
        guard frame.isKeyframe else {
            return (frame.data, false, true, frame.hasPixelChanges)
        }
        // The bridge strips this record before media transmission. Reliable
        // configuration is sent once per negotiated session configuration.
        let record = await encoder.configurationRecord
        var bytes = Data("FPCB".utf8)
        var count = UInt32(record.count).littleEndian
        withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
        bytes.append(record)
        bytes.append(frame.data)
        try await encoder.resolve(generation: frameID, accepted: true)
        return (bytes, true, false, true)
    }
}
