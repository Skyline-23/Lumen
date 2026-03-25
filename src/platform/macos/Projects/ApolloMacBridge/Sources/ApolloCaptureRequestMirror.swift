import ApolloCore
import Foundation

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
    let requestedWidth: Int32
    let requestedHeight: Int32
    let dynamicRange: Int32
    let clientDisplayGamut: Int32
    let clientDisplayTransfer: Int32
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
              let dynamicRange = Self.number(dictionary["dynamicRange"])?.int32Value,
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
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.dynamicRange = dynamicRange
        self.clientDisplayGamut = Self.number(dictionary["clientDisplayGamut"])?.int32Value ?? 0
        self.clientDisplayTransfer = Self.number(dictionary["clientDisplayTransfer"])?.int32Value ?? 0
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
}

actor ApolloCaptureRequestMirrorCoordinator {
    private var mirroredGeneration: UInt64?

    func syncCurrentState() {
        if let mirroredSnapshot = ApolloBridgeMirroredCaptureRequestSnapshot.load() {
            guard mirroredGeneration != mirroredSnapshot.generation else {
                return
            }

            mirroredGeneration = mirroredSnapshot.generation
            ApolloCoreCaptureRequestClear()

            if mirroredSnapshot.videoRequested {
                ApolloCoreCaptureRequestPublishVideo(
                    mirroredSnapshot.displayID,
                    mirroredSnapshot.codec,
                    mirroredSnapshot.preprocessStrategy,
                    mirroredSnapshot.queueProfile,
                    mirroredSnapshot.showCursor,
                    mirroredSnapshot.targetFrameRate,
                    mirroredSnapshot.requestedWidth,
                    mirroredSnapshot.requestedHeight,
                    mirroredSnapshot.dynamicRange,
                    mirroredSnapshot.clientDisplayGamut,
                    mirroredSnapshot.clientDisplayTransfer
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
            }
        } else if mirroredGeneration != nil {
            mirroredGeneration = nil
            ApolloCoreCaptureRequestClear()
        }
    }
}
