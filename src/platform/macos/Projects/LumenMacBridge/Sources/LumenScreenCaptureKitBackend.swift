import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization
import VideoToolbox

struct LumenVideoChromaticityPoint: Equatable, Sendable {
    let xCoordinate: Double
    let yCoordinate: Double
}

struct LumenVideoHDRDisplayMetadata: Equatable, Sendable {
    let redPrimary: LumenVideoChromaticityPoint
    let greenPrimary: LumenVideoChromaticityPoint
    let bluePrimary: LumenVideoChromaticityPoint
    let whitePoint: LumenVideoChromaticityPoint
    let maxLuminance: Double
    let minLuminance: Double

    static func hdr10Default() -> Self {
        Self(
            redPrimary: .init(xCoordinate: 0.708, yCoordinate: 0.292),
            greenPrimary: .init(xCoordinate: 0.170, yCoordinate: 0.797),
            bluePrimary: .init(xCoordinate: 0.131, yCoordinate: 0.046),
            whitePoint: .init(xCoordinate: 0.3127, yCoordinate: 0.3290),
            maxLuminance: 1_000,
            minLuminance: 0.001
        )
    }
}

struct LumenVideoContentLightLevelInfo: Equatable, Sendable {
    let maximumContentLightLevel: Int
    let maximumFrameAverageLightLevel: Int

    static func hdr10Default() -> Self {
        Self(maximumContentLightLevel: 1_000, maximumFrameAverageLightLevel: 400)
    }
}

enum LumenVideoColorPrimaries: String, Equatable, Sendable {
    case ituR709
    case p3D65
    case ituR2020

    var coreMediaValue: CFString {
        switch self {
        case .ituR709: return kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case .p3D65: return kCMFormatDescriptionColorPrimaries_P3_D65
        case .ituR2020: return kCMFormatDescriptionColorPrimaries_ITU_R_2020
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case .p3D65: return kCVImageBufferColorPrimaries_P3_D65
        case .ituR2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        }
    }
}

enum LumenVideoTransferFunction: String, Equatable, Sendable {
    case ituR709
    case smpteSt2084PQ
    case ituR2100HLG

    var coreMediaValue: CFString {
        switch self {
        case .ituR709: return kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case .smpteSt2084PQ: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .ituR2100HLG: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709: return kCVImageBufferTransferFunction_ITU_R_709_2
        case .smpteSt2084PQ: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .ituR2100HLG: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }
}

enum LumenVideoYCbCrMatrix: String, Equatable, Sendable {
    case ituR709
    case ituR2020

    var coreMediaValue: CFString {
        switch self {
        case .ituR709: return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case .ituR2020: return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .ituR2020: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
    }
}

struct LumenVideoHDRConfiguration: Equatable, Sendable {
    let sourceColorPrimaries: LumenVideoColorPrimaries
    let colorPrimaries: LumenVideoColorPrimaries
    let transferFunction: LumenVideoTransferFunction
    let yCbCrMatrix: LumenVideoYCbCrMatrix
    let hdrDisplayMetadata: LumenVideoHDRDisplayMetadata?
    let contentLightLevelInfo: LumenVideoContentLightLevelInfo?

    init(
        sourceColorPrimaries: LumenVideoColorPrimaries,
        colorPrimaries: LumenVideoColorPrimaries,
        transferFunction: LumenVideoTransferFunction,
        yCbCrMatrix: LumenVideoYCbCrMatrix,
        metadataInsertionMode: LumenVideoMetadataInsertionMode = .automatic,
        hdrDisplayMetadata: LumenVideoHDRDisplayMetadata? = nil,
        contentLightLevelInfo: LumenVideoContentLightLevelInfo? = nil
    ) {
        _ = metadataInsertionMode
        self.sourceColorPrimaries = sourceColorPrimaries
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.hdrDisplayMetadata = hdrDisplayMetadata
        self.contentLightLevelInfo = contentLightLevelInfo
    }

}

struct LumenCaptureColorContract: Equatable, Sendable {
    private struct ExpectedAttachment {
        let key: CFString
        let value: String
        let name: String
    }

    let pixelFormat: OSType
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String

    init(pixelFormat: OSType, color: LumenVideoHDRConfiguration) {
        self.pixelFormat = pixelFormat
        self.colorPrimaries = color.colorPrimaries.imageBufferValue as String
        self.transferFunction = color.transferFunction.imageBufferValue as String
        self.yCbCrMatrix = color.yCbCrMatrix.imageBufferValue as String
    }

    func mismatchDescription(for imageBuffer: CVImageBuffer) -> String? {
        let actualPixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        guard actualPixelFormat == pixelFormat else {
            return "pixel-format expected=\(fourCC(pixelFormat)) actual=\(fourCC(actualPixelFormat))"
        }

        let expectedAttachments = [
            ExpectedAttachment(
                key: kCVImageBufferColorPrimariesKey,
                value: colorPrimaries,
                name: "primaries"
            ),
            ExpectedAttachment(
                key: kCVImageBufferTransferFunctionKey,
                value: transferFunction,
                name: "transfer"
            ),
            ExpectedAttachment(
                key: kCVImageBufferYCbCrMatrixKey,
                value: yCbCrMatrix,
                name: "matrix"
            )
        ]
        for attachment in expectedAttachments {
            let actual = CVBufferCopyAttachment(imageBuffer, attachment.key, nil)
            guard let actualString = actual as? String else {
                return "\(attachment.name) expected=\(attachment.value) actual=missing"
            }
            guard actualString == attachment.value else {
                return "\(attachment.name) expected=\(attachment.value) actual=\(actualString)"
            }
        }
        return nil
    }

    private func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

enum LumenCaptureStreamConfigurationFactory {
    static func make(configuration: LumenMacCaptureConfiguration) -> SCStreamConfiguration {
        if configuration.chromaSubsampling == .yuv444,
           configuration.dynamicRange == .hdr10,
           #available(macOS 15.0, *) {
            let result = SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
            result.captureDynamicRange = .hdrCanonicalDisplay
            result.pixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            result.colorSpaceName = CGColorSpace.itur_2100_PQ
            result.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
            result.showsCursor = true
            return result
        }
        return make(usesHDRTransport: configuration.usesHDRTransport)
    }

    static func make(usesHDRTransport: Bool) -> SCStreamConfiguration {
        let configuration: SCStreamConfiguration
        if !usesHDRTransport {
            configuration = SCStreamConfiguration()
        } else if #available(macOS 15.0, *) {
            // This runtime forwards live frames and owns HDR10 metadata on the
            // encoded stream. The recording preset adds recording-oriented
            // preservation work that is unnecessary on this path. Keep the
            // live canonical-display preset so ScreenCaptureKit can service
            // the requested high-refresh stream directly.
            let result = SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
            result.captureDynamicRange = .hdrCanonicalDisplay
            result.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            result.colorSpaceName = CGColorSpace.itur_2100_PQ
            result.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
            configuration = result
        } else {
            configuration = SCStreamConfiguration()
        }

        configuration.showsCursor = true
        return configuration
    }
}

extension LumenVideoHDRDisplayMetadata {
    var encodedData: Data {
        var data = Data(capacity: 24)
        [
            redPrimary.xCoordinate, redPrimary.yCoordinate,
            greenPrimary.xCoordinate, greenPrimary.yCoordinate,
            bluePrimary.xCoordinate, bluePrimary.yCoordinate,
            whitePoint.xCoordinate, whitePoint.yCoordinate
        ].map(Self.encodeChromaticity).forEach { value in
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        [Self.encodeLuminance(maxLuminance), Self.encodeLuminance(minLuminance)].forEach { value in
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func encodeChromaticity(_ value: Double) -> UInt16 {
        UInt16(clamping: Int((min(max(value, 0), 1) * 50_000).rounded()))
    }

    static func encodeLuminance(_ value: Double) -> UInt32 {
        UInt32(clamping: Int((max(value, 0) * 10_000).rounded()))
    }
}

extension LumenVideoContentLightLevelInfo {
    var encodedData: Data {
        var data = Data(capacity: 4)
        [maximumContentLightLevel, maximumFrameAverageLightLevel].forEach { value in
            var bigEndian = UInt16(clamping: value).bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
