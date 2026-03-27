import ApolloCore
import Foundation
import OSLog

struct ApolloBridgeMirroredCaptureRequestSnapshot: Equatable, Sendable {
    static let changedNotification = Notification.Name(
        "com.lizardbyte.apollo.capture-request-changed"
    )

    let generation: UInt64
    let videoGeneration: UInt64
    let audioGeneration: UInt64
    let videoRequested: Bool
    let audioRequested: Bool
    let displayID: UInt32
    let codec: ApolloCoreCaptureCodec
    let preprocessStrategy: ApolloCoreCapturePreprocessStrategy
    let queueProfile: ApolloCoreCaptureQueueProfile
    let showCursor: Bool
    let targetFrameRate: Int32
    let targetVideoBitrateKbps: Int32
    let requestedWidth: Int32
    let requestedHeight: Int32
    let clientSinkGamut: Int32
    let clientSinkTransfer: Int32
    let effectiveSinkGamut: Int32
    let effectiveSinkTransfer: Int32
    let effectiveHDRStaticMetadata: ApolloHDRStaticMetadata?
    let clientSinkCurrentEDRHeadroom: Float
    let clientSinkPotentialEDRHeadroom: Float
    let clientSinkCurrentPeakLuminanceNits: Int32
    let clientSinkPotentialPeakLuminanceNits: Int32
    let requestedDynamicRangeTransport: Int32
    let clientSinkSupportsFrameGatedHDR: Bool
    let clientSinkSupportsHDRTileOverlay: Bool
    let clientSinkSupportsPerFrameHDRMetadata: Bool
    let audioSourceKind: ApolloCoreAudioCaptureSourceKind
    let audioExcludesCurrentProcess: Bool
    let audioSampleRate: Int32
    let audioChannelCount: Int32
    let audioFrameSize: Int32

    static let mirrorURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Apollo", directoryHint: .isDirectory)
            .appending(path: "capture_request_state.plist", directoryHint: .notDirectory)
    }()

    init?(_ propertyList: Any) {
        guard let dictionary = propertyList as? [String: Any] else {
            return nil
        }

        guard let generation = Self.number(dictionary["generation"])?.uint64Value,
              let videoRequested = dictionary["videoRequested"] as? Bool,
              let audioRequested = dictionary["audioRequested"] as? Bool,
              let displayID = Self.number(dictionary["displayID"])?.uint32Value,
              let codec = Self.captureCodec(dictionary["codec"]),
              let preprocessStrategy = Self.preprocessStrategy(dictionary["preprocessStrategy"]),
              let queueProfile = Self.queueProfile(dictionary["queueProfile"]),
              let showCursor = dictionary["showCursor"] as? Bool,
              let targetFrameRate = Self.number(dictionary["targetFrameRate"])?.int32Value,
              let requestedWidth = Self.number(dictionary["requestedWidth"])?.int32Value,
              let requestedHeight = Self.number(dictionary["requestedHeight"])?.int32Value,
              let audioSourceKind = Self.audioSourceKind(dictionary["audioSourceKind"]),
              let audioExcludesCurrentProcess = dictionary["audioExcludesCurrentProcess"] as? Bool,
              let audioSampleRate = Self.number(dictionary["audioSampleRate"])?.int32Value,
              let audioChannelCount = Self.number(dictionary["audioChannelCount"])?.int32Value,
              let audioFrameSize = Self.number(dictionary["audioFrameSize"])?.int32Value else {
            return nil
        }

        self.generation = generation
        self.videoGeneration = Self.number(dictionary["videoGeneration"])?.uint64Value ?? generation
        self.audioGeneration = Self.number(dictionary["audioGeneration"])?.uint64Value ?? generation
        self.videoRequested = videoRequested
        self.audioRequested = audioRequested
        self.displayID = displayID
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.queueProfile = queueProfile
        self.showCursor = showCursor
        self.targetFrameRate = targetFrameRate
        self.targetVideoBitrateKbps = Self.number(dictionary["targetVideoBitrateKbps"])?.int32Value ?? 0
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.clientSinkGamut = Self.number(dictionary["clientSinkGamut"])?.int32Value ?? 0
        self.clientSinkTransfer = Self.number(dictionary["clientSinkTransfer"])?.int32Value ?? 0
        self.effectiveSinkGamut = Self.number(dictionary["effectiveSinkGamut"])?.int32Value ?? 0
        self.effectiveSinkTransfer = Self.number(dictionary["effectiveSinkTransfer"])?.int32Value ?? 0
        self.effectiveHDRStaticMetadata = Self.hdrStaticMetadata(from: dictionary)
        self.clientSinkCurrentEDRHeadroom = Self.number(dictionary["clientSinkCurrentEDRHeadroom"])?.floatValue ?? 0
        self.clientSinkPotentialEDRHeadroom = Self.number(dictionary["clientSinkPotentialEDRHeadroom"])?.floatValue ?? 0
        self.clientSinkCurrentPeakLuminanceNits = Self.number(dictionary["clientSinkCurrentPeakLuminanceNits"])?.int32Value ?? 0
        self.clientSinkPotentialPeakLuminanceNits = Self.number(dictionary["clientSinkPotentialPeakLuminanceNits"])?.int32Value ?? 0
        self.requestedDynamicRangeTransport = Self.number(dictionary["requestedDynamicRangeTransport"])?.int32Value ?? 0
        self.clientSinkSupportsFrameGatedHDR = (dictionary["clientSinkSupportsFrameGatedHDR"] as? Bool) ?? false
        self.clientSinkSupportsHDRTileOverlay = (dictionary["clientSinkSupportsHDRTileOverlay"] as? Bool) ?? false
        self.clientSinkSupportsPerFrameHDRMetadata = (dictionary["clientSinkSupportsPerFrameHDRMetadata"] as? Bool) ?? false
        self.audioSourceKind = audioSourceKind
        self.audioExcludesCurrentProcess = audioExcludesCurrentProcess
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.audioFrameSize = audioFrameSize
    }

    static func load(from url: URL = mirrorURL) -> Self? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }

        return Self(propertyList)
    }

    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    private static func captureCodec(_ value: Any?) -> ApolloCoreCaptureCodec? {
        guard let rawValue = number(value)?.int32Value else {
            return nil
        }
        return ApolloCoreCaptureCodec(rawValue: rawValue)
    }

    private static func preprocessStrategy(_ value: Any?) -> ApolloCoreCapturePreprocessStrategy? {
        guard let rawValue = number(value)?.uint32Value else {
            return nil
        }
        return ApolloCoreCapturePreprocessStrategy(rawValue: rawValue)
    }

    private static func queueProfile(_ value: Any?) -> ApolloCoreCaptureQueueProfile? {
        guard let rawValue = number(value)?.uint32Value else {
            return nil
        }
        return ApolloCoreCaptureQueueProfile(rawValue: rawValue)
    }

    private static func audioSourceKind(_ value: Any?) -> ApolloCoreAudioCaptureSourceKind? {
        guard let rawValue = number(value)?.int32Value else {
            return nil
        }
        return ApolloCoreAudioCaptureSourceKind(rawValue: rawValue)
    }

    private static func hdrStaticMetadata(from dictionary: [String: Any]) -> ApolloHDRStaticMetadata? {
        guard (dictionary["hasEffectiveHDRMetadata"] as? Bool) == true else {
            return nil
        }

        return ApolloHDRStaticMetadata(
            redPrimaryX: Int(Self.number(dictionary["effectiveHDRRedPrimaryX"])?.int32Value ?? 0),
            redPrimaryY: Int(Self.number(dictionary["effectiveHDRRedPrimaryY"])?.int32Value ?? 0),
            greenPrimaryX: Int(Self.number(dictionary["effectiveHDRGreenPrimaryX"])?.int32Value ?? 0),
            greenPrimaryY: Int(Self.number(dictionary["effectiveHDRGreenPrimaryY"])?.int32Value ?? 0),
            bluePrimaryX: Int(Self.number(dictionary["effectiveHDRBluePrimaryX"])?.int32Value ?? 0),
            bluePrimaryY: Int(Self.number(dictionary["effectiveHDRBluePrimaryY"])?.int32Value ?? 0),
            whitePointX: Int(Self.number(dictionary["effectiveHDRWhitePointX"])?.int32Value ?? 0),
            whitePointY: Int(Self.number(dictionary["effectiveHDRWhitePointY"])?.int32Value ?? 0),
            maxDisplayLuminance: Int(Self.number(dictionary["effectiveHDRMaxDisplayLuminance"])?.int32Value ?? 0),
            minDisplayLuminance: Int(Self.number(dictionary["effectiveHDRMinDisplayLuminance"])?.int32Value ?? 0),
            maxContentLightLevel: Int(Self.number(dictionary["effectiveHDRMaxContentLightLevel"])?.int32Value ?? 0),
            maxFrameAverageLightLevel: Int(Self.number(dictionary["effectiveHDRMaxFrameAverageLightLevel"])?.int32Value ?? 0),
            maxFullFrameLuminance: Int(Self.number(dictionary["effectiveHDRMaxFullFrameLuminance"])?.int32Value ?? 0)
        )
    }

    var semanticState: ApolloBridgeMirroredCaptureRequestSemanticState {
        ApolloBridgeMirroredCaptureRequestSemanticState(snapshot: self)
    }
}

struct ApolloBridgeMirroredCaptureRequestSemanticState: Equatable, Sendable {
    let videoRequested: Bool
    let audioRequested: Bool
    let displayID: UInt32
    let codec: ApolloCoreCaptureCodec
    let preprocessStrategy: ApolloCoreCapturePreprocessStrategy
    let queueProfile: ApolloCoreCaptureQueueProfile
    let showCursor: Bool
    let targetFrameRate: Int32
    let targetVideoBitrateKbps: Int32
    let requestedWidth: Int32
    let requestedHeight: Int32
    let clientSinkGamut: Int32
    let clientSinkTransfer: Int32
    let effectiveSinkGamut: Int32
    let effectiveSinkTransfer: Int32
    let effectiveHDRStaticMetadata: ApolloHDRStaticMetadata?
    let clientSinkCurrentEDRHeadroom: Float
    let clientSinkPotentialEDRHeadroom: Float
    let clientSinkCurrentPeakLuminanceNits: Int32
    let clientSinkPotentialPeakLuminanceNits: Int32
    let requestedDynamicRangeTransport: Int32
    let clientSinkSupportsFrameGatedHDR: Bool
    let clientSinkSupportsHDRTileOverlay: Bool
    let clientSinkSupportsPerFrameHDRMetadata: Bool
    let audioSourceKind: ApolloCoreAudioCaptureSourceKind
    let audioExcludesCurrentProcess: Bool
    let audioSampleRate: Int32
    let audioChannelCount: Int32
    let audioFrameSize: Int32

    init(snapshot: ApolloBridgeMirroredCaptureRequestSnapshot) {
        videoRequested = snapshot.videoRequested
        audioRequested = snapshot.audioRequested
        displayID = snapshot.displayID
        codec = snapshot.codec
        preprocessStrategy = snapshot.preprocessStrategy
        queueProfile = snapshot.queueProfile
        showCursor = snapshot.showCursor
        targetFrameRate = snapshot.targetFrameRate
        targetVideoBitrateKbps = snapshot.targetVideoBitrateKbps
        requestedWidth = snapshot.requestedWidth
        requestedHeight = snapshot.requestedHeight
        clientSinkGamut = snapshot.clientSinkGamut
        clientSinkTransfer = snapshot.clientSinkTransfer
        effectiveSinkGamut = snapshot.effectiveSinkGamut
        effectiveSinkTransfer = snapshot.effectiveSinkTransfer
        effectiveHDRStaticMetadata = snapshot.effectiveHDRStaticMetadata
        clientSinkCurrentEDRHeadroom = snapshot.clientSinkCurrentEDRHeadroom
        clientSinkPotentialEDRHeadroom = snapshot.clientSinkPotentialEDRHeadroom
        clientSinkCurrentPeakLuminanceNits = snapshot.clientSinkCurrentPeakLuminanceNits
        clientSinkPotentialPeakLuminanceNits = snapshot.clientSinkPotentialPeakLuminanceNits
        requestedDynamicRangeTransport = snapshot.requestedDynamicRangeTransport
        clientSinkSupportsFrameGatedHDR = snapshot.clientSinkSupportsFrameGatedHDR
        clientSinkSupportsHDRTileOverlay = snapshot.clientSinkSupportsHDRTileOverlay
        clientSinkSupportsPerFrameHDRMetadata = snapshot.clientSinkSupportsPerFrameHDRMetadata
        audioSourceKind = snapshot.audioSourceKind
        audioExcludesCurrentProcess = snapshot.audioExcludesCurrentProcess
        audioSampleRate = snapshot.audioSampleRate
        audioChannelCount = snapshot.audioChannelCount
        audioFrameSize = snapshot.audioFrameSize
    }

    init(snapshot: ApolloCoreCaptureRequestSnapshot) {
        videoRequested = snapshot.video_requested
        audioRequested = snapshot.audio_requested
        displayID = snapshot.display_id
        codec = snapshot.codec
        preprocessStrategy = snapshot.preprocess_strategy
        queueProfile = snapshot.queue_profile
        showCursor = snapshot.show_cursor
        targetFrameRate = snapshot.target_frame_rate
        targetVideoBitrateKbps = snapshot.target_video_bitrate_kbps
        requestedWidth = snapshot.requested_width
        requestedHeight = snapshot.requested_height
        clientSinkGamut = snapshot.client_sink_gamut
        clientSinkTransfer = snapshot.client_sink_transfer
        effectiveSinkGamut = snapshot.effective_sink_gamut
        effectiveSinkTransfer = snapshot.effective_sink_transfer
        effectiveHDRStaticMetadata = snapshot.has_effective_hdr_metadata ?
            ApolloHDRStaticMetadata(coreValue: snapshot.effective_hdr_metadata) :
            nil
        clientSinkCurrentEDRHeadroom = snapshot.client_sink_current_edr_headroom
        clientSinkPotentialEDRHeadroom = snapshot.client_sink_potential_edr_headroom
        clientSinkCurrentPeakLuminanceNits = snapshot.client_sink_current_peak_luminance_nits
        clientSinkPotentialPeakLuminanceNits = snapshot.client_sink_potential_peak_luminance_nits
        requestedDynamicRangeTransport = Int32(snapshot.requested_dynamic_range_transport.rawValue)
        clientSinkSupportsFrameGatedHDR = snapshot.client_sink_supports_frame_gated_hdr
        clientSinkSupportsHDRTileOverlay = snapshot.client_sink_supports_hdr_tile_overlay
        clientSinkSupportsPerFrameHDRMetadata = snapshot.client_sink_supports_per_frame_hdr_metadata
        audioSourceKind = snapshot.audio_source_kind
        audioExcludesCurrentProcess = snapshot.audio_excludes_current_process
        audioSampleRate = snapshot.audio_sample_rate
        audioChannelCount = snapshot.audio_channel_count
        audioFrameSize = snapshot.audio_frame_size
    }
}

actor ApolloCaptureRequestMirrorCoordinator {
    private let logger = Logger(subsystem: "com.lizardbyte.apollo", category: "CaptureRequestMirror")
    private var mirroredGeneration: UInt64?
    private var mirroredSemanticState: ApolloBridgeMirroredCaptureRequestSemanticState?

    func syncCurrentState() {
        if let mirroredSnapshot = ApolloBridgeMirroredCaptureRequestSnapshot.load() {
            guard mirroredGeneration != mirroredSnapshot.generation else {
                return
            }

            let semanticState = mirroredSnapshot.semanticState
            mirroredGeneration = mirroredSnapshot.generation
            let currentApolloCoreSemanticState = ApolloBridgeMirroredCaptureRequestSemanticState(
                snapshot: ApolloCoreCaptureRequestCopySnapshot()
            )
            guard semanticState != mirroredSemanticState ||
                    semanticState != currentApolloCoreSemanticState else {
                logger.debug(
                    "Skipping mirrored capture request sync generation=\(mirroredSnapshot.generation, privacy: .public) because semantic state already matches ApolloCore"
                )
                return
            }

            mirroredSemanticState = semanticState
            logger.notice(
                "Applying mirrored capture request generation=\(mirroredSnapshot.generation, privacy: .public) video-generation=\(mirroredSnapshot.videoGeneration, privacy: .public) audio-generation=\(mirroredSnapshot.audioGeneration, privacy: .public) video-requested=\(mirroredSnapshot.videoRequested, privacy: .public) audio-requested=\(mirroredSnapshot.audioRequested, privacy: .public) display-id=\(mirroredSnapshot.displayID, privacy: .public) queue=\(mirroredSnapshot.queueProfile.rawValue, privacy: .public)"
            )
            ApolloCoreCaptureRequestClear()

            if mirroredSnapshot.videoRequested {
                let effectiveHDRStaticMetadata = mirroredSnapshot.effectiveHDRStaticMetadata?.coreValue ?? ApolloCoreHDRStaticMetadata()
                ApolloCoreCaptureRequestPublishVideo(
                    mirroredSnapshot.displayID,
                    mirroredSnapshot.codec,
                    mirroredSnapshot.preprocessStrategy,
                    mirroredSnapshot.queueProfile,
                    mirroredSnapshot.showCursor,
                    mirroredSnapshot.targetFrameRate,
                    mirroredSnapshot.targetVideoBitrateKbps,
                    mirroredSnapshot.requestedWidth,
                    mirroredSnapshot.requestedHeight,
                    mirroredSnapshot.clientSinkGamut,
                    mirroredSnapshot.clientSinkTransfer,
                    mirroredSnapshot.effectiveSinkGamut,
                    mirroredSnapshot.effectiveSinkTransfer,
                    mirroredSnapshot.effectiveHDRStaticMetadata != nil,
                    effectiveHDRStaticMetadata,
                    mirroredSnapshot.clientSinkCurrentEDRHeadroom,
                    mirroredSnapshot.clientSinkPotentialEDRHeadroom,
                    mirroredSnapshot.clientSinkCurrentPeakLuminanceNits,
                    mirroredSnapshot.clientSinkPotentialPeakLuminanceNits,
                    ApolloCoreDynamicRangeTransport(rawValue: UInt32(mirroredSnapshot.requestedDynamicRangeTransport)) ?? ApolloCoreDynamicRangeTransportUnknown,
                    mirroredSnapshot.clientSinkSupportsFrameGatedHDR,
                    mirroredSnapshot.clientSinkSupportsHDRTileOverlay,
                    mirroredSnapshot.clientSinkSupportsPerFrameHDRMetadata
                )
                logger.notice(
                    "Republished mirrored video capture request generation=\(mirroredSnapshot.generation, privacy: .public) display-id=\(mirroredSnapshot.displayID, privacy: .public) codec=\(mirroredSnapshot.codec.rawValue, privacy: .public) queue=\(mirroredSnapshot.queueProfile.rawValue, privacy: .public) fps=\(mirroredSnapshot.targetFrameRate, privacy: .public)"
                )
            }

            if mirroredSnapshot.audioRequested {
                ApolloCoreCaptureRequestPublishAudio(
                    mirroredSnapshot.audioSourceKind,
                    mirroredSnapshot.displayID,
                    mirroredSnapshot.audioExcludesCurrentProcess,
                    mirroredSnapshot.audioSampleRate,
                    mirroredSnapshot.audioChannelCount,
                    mirroredSnapshot.audioFrameSize
                )
                logger.notice(
                    "Republished mirrored audio capture request generation=\(mirroredSnapshot.generation, privacy: .public) source=\(mirroredSnapshot.audioSourceKind.rawValue, privacy: .public) sample-rate=\(mirroredSnapshot.audioSampleRate, privacy: .public) channels=\(mirroredSnapshot.audioChannelCount, privacy: .public)"
                )
            }
        } else if mirroredGeneration != nil {
            logger.notice(
                "Clearing ApolloCore capture request because mirrored capture request state disappeared previous-generation=\(self.mirroredGeneration ?? 0, privacy: .public)"
            )
            mirroredGeneration = nil
            mirroredSemanticState = nil
            ApolloCoreCaptureRequestClear()
        }
    }
}
