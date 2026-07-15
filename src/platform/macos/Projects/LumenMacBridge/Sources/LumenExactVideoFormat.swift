import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum LumenCaptureVideoProfile: Int, CaseIterable, Codable, Sendable {
    case h264Main = 0
    case h264High = 1
    case h264High444Predictive = 2
    case hevcMain = 3
    case hevcMain10 = 4
    case hevcMain444 = 5
    case hevcMain44410 = 6
}

public enum LumenCaptureChromaSubsampling: Int, CaseIterable, Codable, Sendable {
    case yuv420 = 0
    case yuv444 = 1
}

public enum LumenCaptureDynamicRange: Int, CaseIterable, Codable, Sendable {
    case sdr = 0
    case hdr10 = 1
}

public enum LumenCaptureColorRange: Int, CaseIterable, Codable, Sendable {
    case limited = 0
    case full = 1
}

enum LumenExactCaptureError: Error, Equatable, LocalizedError {
    case invalidFormat(String)
    case requiredHardwareProfileUnavailable(LumenVideoToolboxProbeTarget)
    case requiredHardwareEncoderUnavailable
    case sourceContractMismatch(String)
    case encodedOutputContractMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let reason):
            return "The selected macOS video format is invalid: \(reason)."
        case .requiredHardwareProfileUnavailable(let target):
            return "The required hardware VideoToolbox profile is unavailable: \(target.rawValue)."
        case .requiredHardwareEncoderUnavailable:
            return "VideoToolbox did not select the required hardware encoder."
        case .sourceContractMismatch(let mismatch):
            return "ScreenCaptureKit source contract mismatch: \(mismatch)."
        case .encodedOutputContractMismatch(let mismatch):
            return "VideoToolbox encoded output contract mismatch: \(mismatch)."
        }
    }
}

struct LumenVideoToolboxEncodingPlan: Equatable, Sendable {
    let profile: String
    let pixelFormat: OSType
    let expectedConfiguration: LumenVideoToolboxParsedConfiguration
}

enum LumenVideoToolboxEncodingPlanResolver {
    static func resolve(
        configuration: LumenMacCaptureConfiguration,
        availableHardware444Profiles: [LumenVideoToolboxProbeTarget: String]
    ) throws -> LumenVideoToolboxEncodingPlan {
        try configuration.validateExactVideoFormat()

        if let target = configuration.requiredHardware444ProbeTarget {
            guard let profile = availableHardware444Profiles[target] else {
                throw LumenExactCaptureError.requiredHardwareProfileUnavailable(target)
            }
            return LumenVideoToolboxEncodingPlan(
                profile: profile,
                pixelFormat: configuration.directCapturePixelFormat,
                expectedConfiguration: configuration.expectedCodecConfiguration
            )
        }

        let profile: CFString
        switch configuration.videoProfile {
        case .h264Main:
            profile = kVTProfileLevel_H264_Main_AutoLevel
        case .h264High:
            profile = kVTProfileLevel_H264_High_AutoLevel
        case .hevcMain:
            profile = kVTProfileLevel_HEVC_Main_AutoLevel
        case .hevcMain10:
            profile = kVTProfileLevel_HEVC_Main10_AutoLevel
        case .h264High444Predictive, .hevcMain444, .hevcMain44410:
            throw LumenExactCaptureError.invalidFormat("4:4:4 plan did not resolve to a probe target")
        }
        return LumenVideoToolboxEncodingPlan(
            profile: profile as String,
            pixelFormat: configuration.directCapturePixelFormat,
            expectedConfiguration: configuration.expectedCodecConfiguration
        )
    }
}

struct LumenExactCaptureSourceContract: Equatable, Sendable {
    let pixelFormat: OSType
    let width: Int
    let height: Int
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?

    init(configuration: LumenMacCaptureConfiguration, width: Int, height: Int) throws {
        try configuration.validateExactVideoFormat()
        self.pixelFormat = configuration.directCapturePixelFormat
        self.width = width
        self.height = height

        if configuration.dynamicRange == .hdr10,
           let color = configuration.encodedColorConfiguration {
            colorPrimaries = color.colorPrimaries.imageBufferValue as String
            transferFunction = color.transferFunction.imageBufferValue as String
            yCbCrMatrix = color.yCbCrMatrix.imageBufferValue as String
        } else {
            colorPrimaries = nil
            transferFunction = nil
            yCbCrMatrix = nil
        }
    }

    func mismatchDescription(
        for imageBuffer: CVImageBuffer,
        formatDescription: CMFormatDescription? = nil
    ) -> String? {
        let actualPixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        guard actualPixelFormat == pixelFormat else {
            return "pixel-format expected=\(fourCC(pixelFormat)) actual=\(fourCC(actualPixelFormat))"
        }
        guard CVPixelBufferGetWidth(imageBuffer) == width,
              CVPixelBufferGetHeight(imageBuffer) == height else {
            return "dimensions expected=\(width)x\(height) actual=\(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer))"
        }
        guard CVPixelBufferIsPlanar(imageBuffer), CVPixelBufferGetPlaneCount(imageBuffer) == 2 else {
            return "plane-count expected=2 actual=\(CVPixelBufferGetPlaneCount(imageBuffer))"
        }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(imageBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, 1)
        let expectedChromaWidth = pixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange ? width : (width + 1) / 2
        let expectedChromaHeight = pixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange ? height : (height + 1) / 2
        guard chromaWidth == expectedChromaWidth, chromaHeight == expectedChromaHeight else {
            return "chroma-plane expected=\(expectedChromaWidth)x\(expectedChromaHeight) actual=\(chromaWidth)x\(chromaHeight)"
        }

        let expectedAttachments: [(CFString, String?, String)] = [
            (kCVImageBufferColorPrimariesKey, colorPrimaries, "primaries"),
            (kCVImageBufferTransferFunctionKey, transferFunction, "transfer"),
            (kCVImageBufferYCbCrMatrixKey, yCbCrMatrix, "matrix")
        ]
        let formatExtensions = formatDescription.flatMap {
            CMFormatDescriptionGetExtensions($0) as? [CFString: Any]
        }
        for (key, expected, name) in expectedAttachments {
            guard let expected else { continue }
            let formatKey = key == kCVImageBufferColorPrimariesKey
                ? kCMFormatDescriptionExtension_ColorPrimaries
                : key == kCVImageBufferTransferFunctionKey
                    ? kCMFormatDescriptionExtension_TransferFunction
                    : kCMFormatDescriptionExtension_YCbCrMatrix
            let actual = (CVBufferCopyAttachment(imageBuffer, key, nil) as? String) ??
                (formatExtensions?[formatKey] as? String)
            guard let actual else {
                return "\(name) expected=\(expected) actual=missing"
            }
            guard actual == expected else {
                return "\(name) expected=\(expected) actual=\(actual)"
            }
        }
        return nil
    }
}

struct LumenExactEncodedOutputContract: Equatable, Sendable {
    let expectedConfiguration: LumenVideoToolboxParsedConfiguration

    init(configuration: LumenMacCaptureConfiguration) throws {
        try configuration.validateExactVideoFormat()
        expectedConfiguration = configuration.expectedCodecConfiguration
    }

    func mismatchDescription(codecConfigurationData: Data?) -> String? {
        guard let codecConfigurationData else {
            return "codec-configuration missing"
        }
        switch expectedConfiguration {
        case .h264(let expectedProfile):
            guard let actual = LumenVideoToolboxCodecConfigurationParser.parseAVCC(codecConfigurationData) else {
                return "AVC configuration malformed"
            }
            guard actual.profileIdc == expectedProfile else {
                return "AVC profile expected=\(expectedProfile) actual=\(actual.profileIdc)"
            }
        case .hevc(let expectedChroma, let expectedLumaDepth, let expectedChromaDepth):
            guard let actual = LumenVideoToolboxCodecConfigurationParser.parseHVCC(codecConfigurationData) else {
                return "HEVC configuration malformed"
            }
            guard actual.chromaFormatIdc == expectedChroma,
                  actual.lumaBitDepth == expectedLumaDepth,
                  actual.chromaBitDepth == expectedChromaDepth else {
                return "HEVC configuration expected=chroma:\(expectedChroma)/luma:\(expectedLumaDepth)/chroma-depth:\(expectedChromaDepth) actual=chroma:\(actual.chromaFormatIdc)/luma:\(actual.lumaBitDepth)/chroma-depth:\(actual.chromaBitDepth)"
            }
        }
        return nil
    }
}

extension LumenMacCaptureConfiguration {
    var requiredHardware444ProbeTarget: LumenVideoToolboxProbeTarget? {
        switch videoProfile {
        case .h264High444Predictive: return .h264High444Predictive
        case .hevcMain444: return .hevcMain444
        case .hevcMain44410: return .hevcMain44410
        case .h264Main, .h264High, .hevcMain, .hevcMain10: return nil
        }
    }

    var expectedCodecConfiguration: LumenVideoToolboxParsedConfiguration {
        switch videoProfile {
        case .h264Main: return .h264(profileIdc: 77)
        case .h264High: return .h264(profileIdc: 100)
        case .h264High444Predictive: return .h264(profileIdc: 244)
        case .hevcMain: return .hevc(chromaFormatIdc: 1, lumaBitDepth: 8, chromaBitDepth: 8)
        case .hevcMain10: return .hevc(chromaFormatIdc: 1, lumaBitDepth: 10, chromaBitDepth: 10)
        case .hevcMain444: return .hevc(chromaFormatIdc: 3, lumaBitDepth: 8, chromaBitDepth: 8)
        case .hevcMain44410: return .hevc(chromaFormatIdc: 3, lumaBitDepth: 10, chromaBitDepth: 10)
        }
    }

    func validateExactVideoFormat() throws {
        let matches: Bool
        switch videoProfile {
        case .h264Main, .h264High:
            matches = codec == .h264 && chromaSubsampling == .yuv420 && bitDepth == 8
        case .h264High444Predictive:
            matches = codec == .h264 && chromaSubsampling == .yuv444 && bitDepth == 8 && dynamicRange == .sdr && colorRange == .full
        case .hevcMain:
            matches = codec == .hevc && chromaSubsampling == .yuv420 && bitDepth == 8
        case .hevcMain10:
            matches = codec == .hevc && chromaSubsampling == .yuv420 && bitDepth == 10
        case .hevcMain444:
            matches = codec == .hevc && chromaSubsampling == .yuv444 && bitDepth == 8 && dynamicRange == .sdr && colorRange == .full
        case .hevcMain44410:
            matches = codec == .hevc && chromaSubsampling == .yuv444 && bitDepth == 10 && dynamicRange == .hdr10 && colorRange == .limited
        }
        guard matches else {
            throw LumenExactCaptureError.invalidFormat(
                "codec=\(codec.rawValue) profile=\(videoProfile.rawValue) chroma=\(chromaSubsampling.rawValue) bit-depth=\(bitDepth) dynamic-range=\(dynamicRange.rawValue) color-range=\(colorRange.rawValue)"
            )
        }
    }
}

private func fourCC(_ value: OSType) -> String {
    String(bytes: [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ], encoding: .ascii) ?? String(value)
}
