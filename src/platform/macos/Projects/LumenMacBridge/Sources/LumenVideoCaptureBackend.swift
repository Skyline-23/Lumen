import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum LumenVideoCaptureBackend: String, Equatable, Sendable {
    case avFoundationScreenInput = "av-foundation-screen-input"
    case screenCaptureKit = "screen-capture-kit"
    case skyLightDisplayStream = "skylight-display-stream"

    static func preferred(
        for configuration: LumenMacCaptureConfiguration,
        skyLightDisplayStreamAvailable: Bool = false
    ) -> Self {
        if skyLightDisplayStreamAvailable,
           configuration.chromaSubsampling == .yuv420 {
            return .skyLightDisplayStream
        }
        guard configuration.dynamicRange == .sdr,
              configuration.bitDepth == 8,
              configuration.chromaSubsampling == .yuv420 else {
            return .screenCaptureKit
        }
        return .avFoundationScreenInput
    }
}

enum LumenScreenCaptureCadence {
    static func minimumFrameInterval(
        targetFrameRate: Int
    ) -> CMTime {
        return CMTime(
            value: 1,
            timescale: CMTimeScale(max(targetFrameRate, 1))
        )
    }
}

enum LumenScreenCaptureGeometry {
    static func contentRect(from attachment: Any?) -> CGRect? {
        if let rect = attachment as? CGRect {
            return rect
        }
        guard let dictionary = attachment as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    static func applyFullDisplayMapping(
        to configuration: SCStreamConfiguration,
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        outputWidth: Int,
        outputHeight: Int
    ) {
        configuration.sourceRect = CGRect(
            x: 0,
            y: 0,
            width: sourceWidth,
            height: sourceHeight
        )
        configuration.destinationRect = CGRect(
            x: 0,
            y: 0,
            width: outputWidth,
            height: outputHeight
        )
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
    }
}
