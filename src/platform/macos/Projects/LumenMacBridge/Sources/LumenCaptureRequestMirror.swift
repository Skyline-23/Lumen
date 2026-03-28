import LumenCore
import Foundation
import OSLog

struct LumenBridgeMirroredSinkMode: Equatable, Sendable {
    let hidpi: Bool
    let scaleExplicit: Bool
    let modeIsLogical: Bool
    let scalePercent: Int32
}

struct LumenBridgeMirroredSinkCapability: Equatable, Sendable {
    let gamut: Int32
    let transfer: Int32
    let currentEDRHeadroom: Float
    let potentialEDRHeadroom: Float
    let currentPeakLuminanceNits: Int32
    let potentialPeakLuminanceNits: Int32
    let supportsFrameGatedHDR: Bool
    let supportsHDRTileOverlay: Bool
    let supportsPerFrameHDRMetadata: Bool
}

struct LumenBridgeMirroredSinkRequest: Equatable, Sendable {
    let mode: LumenBridgeMirroredSinkMode
    let capability: LumenBridgeMirroredSinkCapability
    let dynamicRangeTransport: LumenCoreDynamicRangeTransport
}

struct LumenBridgeMirroredEffectiveDisplayState: Equatable, Sendable {
    let gamut: Int32
    let transfer: Int32
    let hdrStaticMetadata: LumenHDRStaticMetadata?
}

struct LumenBridgeMirroredCaptureRequestSnapshot: Equatable, Sendable {
    static let changedNotification = Notification.Name(
        "com.lizardbyte.apollo.capture-request-changed"
    )

    let generation: UInt64
    let videoGeneration: UInt64
    let audioGeneration: UInt64
    let videoRequested: Bool
    let audioRequested: Bool
    let displayID: UInt32
    let codec: LumenCoreCaptureCodec
    let preprocessStrategy: LumenCoreCapturePreprocessStrategy
    let queueProfile: LumenCoreCaptureQueueProfile
    let showCursor: Bool
    let targetFrameRate: Int32
    let targetVideoBitrateKbps: Int32
    let requestedWidth: Int32
    let requestedHeight: Int32
    let sinkRequest: LumenBridgeMirroredSinkRequest
    let effectiveDisplayState: LumenBridgeMirroredEffectiveDisplayState
    let audioSourceKind: LumenCoreAudioCaptureSourceKind
    let audioExcludesCurrentProcess: Bool
    let audioSampleRate: Int32
    let audioChannelCount: Int32
    let audioFrameSize: Int32

    static let mirrorURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Lumen", directoryHint: .isDirectory)
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
              let sinkRequest = Self.sinkRequest(dictionary["sinkRequest"]),
              let effectiveDisplayState = Self.effectiveDisplayState(dictionary["effectiveDisplayState"]),
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
        self.sinkRequest = sinkRequest
        self.effectiveDisplayState = effectiveDisplayState
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

    private static func captureCodec(_ value: Any?) -> LumenCoreCaptureCodec? {
        guard let rawValue = number(value)?.int32Value else {
            return nil
        }
        return LumenCoreCaptureCodec(rawValue: rawValue)
    }

    private static func preprocessStrategy(_ value: Any?) -> LumenCoreCapturePreprocessStrategy? {
        guard let rawValue = number(value)?.uint32Value else {
            return nil
        }
        return LumenCoreCapturePreprocessStrategy(rawValue: rawValue)
    }

    private static func queueProfile(_ value: Any?) -> LumenCoreCaptureQueueProfile? {
        guard let rawValue = number(value)?.uint32Value else {
            return nil
        }
        return LumenCoreCaptureQueueProfile(rawValue: rawValue)
    }

    private static func audioSourceKind(_ value: Any?) -> LumenCoreAudioCaptureSourceKind? {
        guard let rawValue = number(value)?.int32Value else {
            return nil
        }
        return LumenCoreAudioCaptureSourceKind(rawValue: rawValue)
    }

    private static func sinkMode(_ value: Any?) -> LumenBridgeMirroredSinkMode? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        return LumenBridgeMirroredSinkMode(
            hidpi: (dictionary["hidpi"] as? Bool) ?? false,
            scaleExplicit: (dictionary["scaleExplicit"] as? Bool) ?? false,
            modeIsLogical: (dictionary["modeIsLogical"] as? Bool) ?? false,
            scalePercent: Self.number(dictionary["scalePercent"])?.int32Value ?? 100
        )
    }

    private static func sinkCapability(_ value: Any?) -> LumenBridgeMirroredSinkCapability? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        guard let gamut = Self.number(dictionary["gamut"])?.int32Value,
              let transfer = Self.number(dictionary["transfer"])?.int32Value else {
            return nil
        }
        return LumenBridgeMirroredSinkCapability(
            gamut: gamut,
            transfer: transfer,
            currentEDRHeadroom: Self.number(dictionary["currentEDRHeadroom"])?.floatValue ?? 0,
            potentialEDRHeadroom: Self.number(dictionary["potentialEDRHeadroom"])?.floatValue ?? 0,
            currentPeakLuminanceNits: Self.number(dictionary["currentPeakLuminanceNits"])?.int32Value ?? 0,
            potentialPeakLuminanceNits: Self.number(dictionary["potentialPeakLuminanceNits"])?.int32Value ?? 0,
            supportsFrameGatedHDR: (dictionary["supportsFrameGatedHDR"] as? Bool) ?? false,
            supportsHDRTileOverlay: (dictionary["supportsHDRTileOverlay"] as? Bool) ?? false,
            supportsPerFrameHDRMetadata: (dictionary["supportsPerFrameHDRMetadata"] as? Bool) ?? false
        )
    }

    private static func sinkRequest(_ value: Any?) -> LumenBridgeMirroredSinkRequest? {
        guard let dictionary = value as? [String: Any],
              let mode = sinkMode(dictionary["mode"]),
              let capability = sinkCapability(dictionary["capability"]) else {
            return nil
        }
        let dynamicRangeTransport = LumenCoreDynamicRangeTransport(
            rawValue: UInt32(Self.number(dictionary["dynamicRangeTransport"])?.int32Value ?? 0)
        )
        return LumenBridgeMirroredSinkRequest(
            mode: mode,
            capability: capability,
            dynamicRangeTransport: dynamicRangeTransport
        )
    }

    private static func effectiveDisplayState(_ value: Any?) -> LumenBridgeMirroredEffectiveDisplayState? {
        guard let dictionary = value as? [String: Any],
              let gamut = Self.number(dictionary["gamut"])?.int32Value,
              let transfer = Self.number(dictionary["transfer"])?.int32Value else {
            return nil
        }
        return LumenBridgeMirroredEffectiveDisplayState(
            gamut: gamut,
            transfer: transfer,
            hdrStaticMetadata: Self.hdrStaticMetadata(dictionary["hdrStaticMetadata"])
        )
    }

    private static func hdrStaticMetadata(_ value: Any?) -> LumenHDRStaticMetadata? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        return LumenHDRStaticMetadata(
            redPrimaryX: Int(Self.number(dictionary["redPrimaryX"])?.int32Value ?? 0),
            redPrimaryY: Int(Self.number(dictionary["redPrimaryY"])?.int32Value ?? 0),
            greenPrimaryX: Int(Self.number(dictionary["greenPrimaryX"])?.int32Value ?? 0),
            greenPrimaryY: Int(Self.number(dictionary["greenPrimaryY"])?.int32Value ?? 0),
            bluePrimaryX: Int(Self.number(dictionary["bluePrimaryX"])?.int32Value ?? 0),
            bluePrimaryY: Int(Self.number(dictionary["bluePrimaryY"])?.int32Value ?? 0),
            whitePointX: Int(Self.number(dictionary["whitePointX"])?.int32Value ?? 0),
            whitePointY: Int(Self.number(dictionary["whitePointY"])?.int32Value ?? 0),
            maxDisplayLuminance: Int(Self.number(dictionary["maxDisplayLuminance"])?.int32Value ?? 0),
            minDisplayLuminance: Int(Self.number(dictionary["minDisplayLuminance"])?.int32Value ?? 0),
            maxContentLightLevel: Int(Self.number(dictionary["maxContentLightLevel"])?.int32Value ?? 0),
            maxFrameAverageLightLevel: Int(Self.number(dictionary["maxFrameAverageLightLevel"])?.int32Value ?? 0),
            maxFullFrameLuminance: Int(Self.number(dictionary["maxFullFrameLuminance"])?.int32Value ?? 0)
        )
    }

    var semanticState: LumenBridgeMirroredCaptureRequestSemanticState {
        LumenBridgeMirroredCaptureRequestSemanticState(snapshot: self)
    }
}

struct LumenBridgeMirroredCaptureRequestSemanticState: Equatable, Sendable {
    let videoRequested: Bool
    let audioRequested: Bool
    let displayID: UInt32
    let codec: LumenCoreCaptureCodec
    let preprocessStrategy: LumenCoreCapturePreprocessStrategy
    let queueProfile: LumenCoreCaptureQueueProfile
    let showCursor: Bool
    let targetFrameRate: Int32
    let targetVideoBitrateKbps: Int32
    let requestedWidth: Int32
    let requestedHeight: Int32
    let sinkRequest: LumenBridgeMirroredSinkRequest
    let effectiveDisplayState: LumenBridgeMirroredEffectiveDisplayState
    let audioSourceKind: LumenCoreAudioCaptureSourceKind
    let audioExcludesCurrentProcess: Bool
    let audioSampleRate: Int32
    let audioChannelCount: Int32
    let audioFrameSize: Int32

    init(snapshot: LumenBridgeMirroredCaptureRequestSnapshot) {
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
        sinkRequest = snapshot.sinkRequest
        effectiveDisplayState = snapshot.effectiveDisplayState
        audioSourceKind = snapshot.audioSourceKind
        audioExcludesCurrentProcess = snapshot.audioExcludesCurrentProcess
        audioSampleRate = snapshot.audioSampleRate
        audioChannelCount = snapshot.audioChannelCount
        audioFrameSize = snapshot.audioFrameSize
    }

    init(snapshot: LumenCoreCaptureRequestSnapshot) {
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
        sinkRequest = LumenBridgeMirroredSinkRequest(
            mode: LumenBridgeMirroredSinkMode(
                hidpi: snapshot.sink_request.mode.hidpi,
                scaleExplicit: snapshot.sink_request.mode.scale_explicit,
                modeIsLogical: snapshot.sink_request.mode.mode_is_logical,
                scalePercent: snapshot.sink_request.mode.scale_percent
            ),
            capability: LumenBridgeMirroredSinkCapability(
                gamut: snapshot.sink_request.capability.gamut,
                transfer: snapshot.sink_request.capability.transfer,
                currentEDRHeadroom: snapshot.sink_request.capability.current_edr_headroom,
                potentialEDRHeadroom: snapshot.sink_request.capability.potential_edr_headroom,
                currentPeakLuminanceNits: snapshot.sink_request.capability.current_peak_luminance_nits,
                potentialPeakLuminanceNits: snapshot.sink_request.capability.potential_peak_luminance_nits,
                supportsFrameGatedHDR: snapshot.sink_request.capability.supports_frame_gated_hdr,
                supportsHDRTileOverlay: snapshot.sink_request.capability.supports_hdr_tile_overlay,
                supportsPerFrameHDRMetadata: snapshot.sink_request.capability.supports_per_frame_hdr_metadata
            ),
            dynamicRangeTransport: snapshot.sink_request.dynamic_range_transport
        )
        effectiveDisplayState = LumenBridgeMirroredEffectiveDisplayState(
            gamut: snapshot.effective_display_state.gamut,
            transfer: snapshot.effective_display_state.transfer,
            hdrStaticMetadata: snapshot.effective_display_state.has_hdr_static_metadata ?
                LumenHDRStaticMetadata(coreValue: snapshot.effective_display_state.hdr_static_metadata) :
                nil
        )
        audioSourceKind = snapshot.audio_source_kind
        audioExcludesCurrentProcess = snapshot.audio_excludes_current_process
        audioSampleRate = snapshot.audio_sample_rate
        audioChannelCount = snapshot.audio_channel_count
        audioFrameSize = snapshot.audio_frame_size
    }
}

actor LumenCaptureRequestMirrorCoordinator {
    private let logger = Logger(subsystem: "com.lizardbyte.apollo", category: "CaptureRequestMirror")
    private var mirroredGeneration: UInt64?
    private var mirroredSemanticState: LumenBridgeMirroredCaptureRequestSemanticState?

    func syncCurrentState() {
        if let mirroredSnapshot = LumenBridgeMirroredCaptureRequestSnapshot.load() {
            guard mirroredGeneration != mirroredSnapshot.generation else {
                return
            }

            let semanticState = mirroredSnapshot.semanticState
            mirroredGeneration = mirroredSnapshot.generation
            let currentLumenCoreSemanticState = LumenBridgeMirroredCaptureRequestSemanticState(
                snapshot: LumenCoreCaptureRequestCopySnapshot()
            )
            guard semanticState != mirroredSemanticState ||
                    semanticState != currentLumenCoreSemanticState else {
                logger.debug(
                    "Skipping mirrored capture request sync generation=\(mirroredSnapshot.generation, privacy: .public) because semantic state already matches LumenCore"
                )
                return
            }

            mirroredSemanticState = semanticState
            logger.notice(
                "Applying mirrored capture request generation=\(mirroredSnapshot.generation, privacy: .public) video-generation=\(mirroredSnapshot.videoGeneration, privacy: .public) audio-generation=\(mirroredSnapshot.audioGeneration, privacy: .public) video-requested=\(mirroredSnapshot.videoRequested, privacy: .public) audio-requested=\(mirroredSnapshot.audioRequested, privacy: .public) display-id=\(mirroredSnapshot.displayID, privacy: .public) queue=\(mirroredSnapshot.queueProfile.rawValue, privacy: .public)"
            )
            LumenCoreCaptureRequestClear()

            if mirroredSnapshot.videoRequested {
                let effectiveHDRStaticMetadata = mirroredSnapshot.effectiveDisplayState.hdrStaticMetadata?.coreValue ?? LumenCoreHDRStaticMetadata()
                var sinkMode = LumenCoreSinkMode()
                var sinkCapability = LumenCoreSinkCapability()
                sinkCapability.gamut = mirroredSnapshot.sinkRequest.capability.gamut
                sinkCapability.transfer = mirroredSnapshot.sinkRequest.capability.transfer
                sinkCapability.current_edr_headroom = mirroredSnapshot.sinkRequest.capability.currentEDRHeadroom
                sinkCapability.potential_edr_headroom = mirroredSnapshot.sinkRequest.capability.potentialEDRHeadroom
                sinkCapability.current_peak_luminance_nits = mirroredSnapshot.sinkRequest.capability.currentPeakLuminanceNits
                sinkCapability.potential_peak_luminance_nits = mirroredSnapshot.sinkRequest.capability.potentialPeakLuminanceNits
                sinkCapability.supports_frame_gated_hdr = mirroredSnapshot.sinkRequest.capability.supportsFrameGatedHDR
                sinkCapability.supports_hdr_tile_overlay = mirroredSnapshot.sinkRequest.capability.supportsHDRTileOverlay
                sinkCapability.supports_per_frame_hdr_metadata = mirroredSnapshot.sinkRequest.capability.supportsPerFrameHDRMetadata
                var sinkRequest = LumenCoreSinkRequest()
                sinkMode.hidpi = mirroredSnapshot.sinkRequest.mode.hidpi
                sinkMode.scale_explicit = mirroredSnapshot.sinkRequest.mode.scaleExplicit
                sinkMode.mode_is_logical = mirroredSnapshot.sinkRequest.mode.modeIsLogical
                sinkMode.scale_percent = mirroredSnapshot.sinkRequest.mode.scalePercent
                sinkRequest.mode = sinkMode
                sinkRequest.capability = sinkCapability
                sinkRequest.dynamic_range_transport = mirroredSnapshot.sinkRequest.dynamicRangeTransport
                var effectiveDisplayState = LumenCoreEffectiveDisplayState()
                effectiveDisplayState.gamut = mirroredSnapshot.effectiveDisplayState.gamut
                effectiveDisplayState.transfer = mirroredSnapshot.effectiveDisplayState.transfer
                effectiveDisplayState.has_hdr_static_metadata = mirroredSnapshot.effectiveDisplayState.hdrStaticMetadata != nil
                effectiveDisplayState.hdr_static_metadata = effectiveHDRStaticMetadata
                LumenCoreCaptureRequestPublishVideo(
                    mirroredSnapshot.displayID,
                    mirroredSnapshot.codec,
                    mirroredSnapshot.preprocessStrategy,
                    mirroredSnapshot.queueProfile,
                    mirroredSnapshot.showCursor,
                    mirroredSnapshot.targetFrameRate,
                    mirroredSnapshot.targetVideoBitrateKbps,
                    mirroredSnapshot.requestedWidth,
                    mirroredSnapshot.requestedHeight,
                    sinkRequest,
                    effectiveDisplayState
                )
                logger.notice(
                    "Republished mirrored video capture request generation=\(mirroredSnapshot.generation, privacy: .public) display-id=\(mirroredSnapshot.displayID, privacy: .public) codec=\(mirroredSnapshot.codec.rawValue, privacy: .public) queue=\(mirroredSnapshot.queueProfile.rawValue, privacy: .public) fps=\(mirroredSnapshot.targetFrameRate, privacy: .public)"
                )
            }

            if mirroredSnapshot.audioRequested {
                LumenCoreCaptureRequestPublishAudio(
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
                "Clearing LumenCore capture request because mirrored capture request state disappeared previous-generation=\(self.mirroredGeneration ?? 0, privacy: .public)"
            )
            mirroredGeneration = nil
            mirroredSemanticState = nil
            LumenCoreCaptureRequestClear()
        }
    }
}
