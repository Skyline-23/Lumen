extension LumenMacCaptureConfiguration {
    var hdrConfigurationDebugSummary: String {
        let capability = sinkRequest.capability
        return [
            "uses-hdr-transport=\(usesHDRTransport)",
            "requested-transport=\(lumenDynamicRangeTransportName(sinkRequest.dynamicRangeTransport))",
            "negotiated-transport=\(lumenDynamicRangeTransportName(negotiatedDynamicRangeTransport))",
            "requested-queue=\(queueProfile.rawValue)",
            "negotiated-queue=\(negotiatedQueueProfile.rawValue)",
            "effective-gamut=\(resolvedDisplayGamut.rawValue)",
            "effective-transfer=\(resolvedDisplayTransfer.rawValue)",
            "negotiated-static-metadata=\(effectiveDisplayState.hdrStaticMetadata != nil)",
            "current-edr-headroom=\(capability.currentEDRHeadroom)",
            "potential-edr-headroom=\(capability.potentialEDRHeadroom)",
            "current-peak-nits=\(capability.currentPeakLuminanceNits)",
            "potential-peak-nits=\(capability.potentialPeakLuminanceNits)",
            "supports-frame-gated-hdr=\(capability.supportsFrameGatedHDR)",
            "supports-hdr-tile-overlay=\(capability.supportsHDRTileOverlay)",
            "supports-per-frame-hdr-metadata=\(capability.supportsPerFrameHDRMetadata)",
            "presentation-contract=\(presentationContractName)"
        ].joined(separator: " ")
    }
}
