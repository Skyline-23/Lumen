extension LumenMacCaptureConfiguration {
    var encodedColorConfiguration: LumenVideoHDRConfiguration? {
        if usesHDRTransport ||
            negotiatedDynamicRangeTransport ==
                LumenMacDynamicRangeTransportSDRBaseHDROverlay,
           codec != .h264 {
            let colorPrimaries = resolvedHDRSignalColorPrimaries
            let yCbCrMatrix = resolvedHDRSignalYCbCrMatrix
            let metadata = resolvedHDRStaticMetadata
            return LumenVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: colorPrimaries,
                transferFunction: resolvedHDRTransferFunction,
                yCbCrMatrix: yCbCrMatrix,
                metadataInsertionMode: .automatic,
                hdrDisplayMetadata: metadata.hdrDisplayMetadata,
                contentLightLevelInfo: metadata.contentLightLevelInfo
            )
        }

        switch resolvedDisplayGamut {
        case .displayP3:
            return LumenVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .p3D65,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: .automatic
            )
        case .rec2020:
            return LumenVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .ituR2020,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR2020,
                metadataInsertionMode: .automatic
            )
        case .srgb, .unknown:
            return LumenVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .ituR709,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: .automatic
            )
        }
    }

    var resolvedDisplayGamut: LumenClientSinkGamut {
        effectiveDisplayState.gamut == .unknown
            ? sinkRequest.capability.gamut
            : effectiveDisplayState.gamut
    }

    var resolvedDisplayTransfer: LumenClientSinkTransfer {
        effectiveDisplayState.transfer == .unknown
            ? sinkRequest.capability.transfer
            : effectiveDisplayState.transfer
    }

    var encodedHDRConfigurationSnapshot: EncodedHDRConfigurationSnapshot? {
        guard usesHDRTransport ||
            negotiatedDynamicRangeTransport ==
                LumenMacDynamicRangeTransportSDRBaseHDROverlay,
              codec != .h264 else {
            return nil
        }

        return EncodedHDRConfigurationSnapshot(
            signalColorPrimaries: resolvedHDRSignalColorPrimaries.rawValue,
            transferFunction: resolvedHDRTransferFunction.rawValue,
            signalYCbCrMatrix: resolvedHDRSignalYCbCrMatrix.rawValue,
            staticMetadataSource: resolvedHDRStaticMetadataSource
        )
    }

    static func sanitizedDimension(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }
        return value
    }

    private var resolvedSourceColorPrimaries: LumenVideoColorPrimaries {
        switch resolvedDisplayGamut {
        case .displayP3:
            return .p3D65
        case .rec2020:
            return .ituR2020
        case .srgb, .unknown:
            return .ituR709
        }
    }

    private var resolvedHDRTransferFunction: LumenVideoTransferFunction {
        switch resolvedDisplayTransfer {
        case .hlg:
            return .ituR2100HLG
        case .sdr:
            return .ituR709
        case .pq, .unknown:
            return .smpteSt2084PQ
        }
    }

    private var resolvedHDRSignalColorPrimaries: LumenVideoColorPrimaries {
        switch resolvedHDRTransferFunction {
        case .smpteSt2084PQ, .ituR2100HLG:
            return .ituR2020
        case .ituR709:
            switch resolvedDisplayGamut {
            case .displayP3:
                return .p3D65
            case .rec2020:
                return .ituR2020
            case .srgb, .unknown:
                return .ituR709
            }
        }
    }

    private var resolvedHDRSignalYCbCrMatrix: LumenVideoYCbCrMatrix {
        switch resolvedHDRTransferFunction {
        case .smpteSt2084PQ, .ituR2100HLG:
            return .ituR2020
        case .ituR709:
            return .ituR709
        }
    }

    private var resolvedHDRStaticMetadata: (
        hdrDisplayMetadata: LumenVideoHDRDisplayMetadata?,
        contentLightLevelInfo: LumenVideoContentLightLevelInfo?
    ) {
        if let hdrStaticMetadata = effectiveDisplayState.hdrStaticMetadata {
            return (
                hdrStaticMetadata.hdrDisplayMetadata,
                hdrStaticMetadata.contentLightLevelInfo
            )
        }

        switch resolvedHDRTransferFunction {
        case .ituR2100HLG:
            return (nil, nil)
        case .smpteSt2084PQ:
            switch resolvedDisplayGamut {
            case .displayP3:
                return (
                    Self.hdrP3DisplayMetadata,
                    Self.hdrP3ContentLightLevelInfo
                )
            case .rec2020:
                return (
                    LumenVideoHDRDisplayMetadata.hdr10Default(),
                    LumenVideoContentLightLevelInfo.hdr10Default()
                )
            case .srgb, .unknown:
                return (
                    Self.hdr709DisplayMetadata,
                    Self.hdr709ContentLightLevelInfo
                )
            }
        case .ituR709:
            return (nil, nil)
        }
    }

    private var resolvedHDRStaticMetadataSource: String {
        if effectiveDisplayState.hdrStaticMetadata != nil {
            return "explicit"
        }

        switch resolvedHDRTransferFunction {
        case .ituR2100HLG:
            return "none"
        case .smpteSt2084PQ:
            switch resolvedDisplayGamut {
            case .displayP3:
                return "display-p3-default"
            case .rec2020:
                return "rec2020-default"
            case .srgb, .unknown:
                return "rec709-default"
            }
        case .ituR709:
            return "none"
        }
    }

    private static let hdr709DisplayMetadata = LumenVideoHDRDisplayMetadata(
        redPrimary: LumenVideoChromaticityPoint(
            xCoordinate: 0.6400,
            yCoordinate: 0.3300
        ),
        greenPrimary: LumenVideoChromaticityPoint(
            xCoordinate: 0.3000,
            yCoordinate: 0.6000
        ),
        bluePrimary: LumenVideoChromaticityPoint(
            xCoordinate: 0.1500,
            yCoordinate: 0.0600
        ),
        whitePoint: LumenVideoChromaticityPoint(
            xCoordinate: 0.3127,
            yCoordinate: 0.3290
        ),
        maxLuminance: 600.0,
        minLuminance: 0.001
    )

    private static let hdr709ContentLightLevelInfo =
        LumenVideoContentLightLevelInfo(
            maximumContentLightLevel: 600,
            maximumFrameAverageLightLevel: 250
        )

    private static let hdrP3DisplayMetadata = LumenVideoHDRDisplayMetadata(
        redPrimary: LumenVideoChromaticityPoint(
            xCoordinate: 0.6800,
            yCoordinate: 0.3200
        ),
        greenPrimary: LumenVideoChromaticityPoint(
            xCoordinate: 0.2650,
            yCoordinate: 0.6900
        ),
        bluePrimary: LumenVideoChromaticityPoint(
            xCoordinate: 0.1500,
            yCoordinate: 0.0600
        ),
        whitePoint: LumenVideoChromaticityPoint(
            xCoordinate: 0.3127,
            yCoordinate: 0.3290
        ),
        maxLuminance: 1000.0,
        minLuminance: 0.001
    )

    private static let hdrP3ContentLightLevelInfo =
        LumenVideoContentLightLevelInfo(
            maximumContentLightLevel: 1000,
            maximumFrameAverageLightLevel: 400
        )
}
