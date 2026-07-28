import Foundation

@objcMembers
public final class LumenBridgeAudioConfigurationBox: NSObject {
    public let sourceKindRawValue: Int
    public let displayID: UInt32
    public let excludesCurrentProcessAudio: Bool
    public let inputID: String?
    public let sampleRate: Int
    public let channelCount: Int
    public let frameSize: Int

    public init(
        sourceKindRawValue: Int,
        displayID: UInt32,
        excludesCurrentProcessAudio: Bool,
        inputID: String?,
        sampleRate: Int,
        channelCount: Int,
        frameSize: Int
    ) {
        self.sourceKindRawValue = sourceKindRawValue
        self.displayID = displayID
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.inputID = inputID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameSize = frameSize
    }

    convenience init(configuration: LumenMacAudioCaptureConfiguration) {
        switch configuration.source {
        case .microphone(let inputID):
            self.init(
                sourceKindRawValue: LumenBridgeObjCFacade.rawValue(for: LumenAudioCaptureSourceKind.microphone),
                displayID: 0,
                excludesCurrentProcessAudio: false,
                inputID: inputID,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                frameSize: configuration.frameSize
            )
        case .systemOutput(let displayID, let excludesCurrentProcessAudio):
            self.init(
                sourceKindRawValue: LumenBridgeObjCFacade.rawValue(for: LumenAudioCaptureSourceKind.systemOutput),
                displayID: displayID,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio,
                inputID: nil,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                frameSize: configuration.frameSize
            )
        }
    }

    var swiftValue: LumenMacAudioCaptureConfiguration {
        let sourceKind = LumenBridgeObjCFacade.audioSourceKind(fromRawValue: sourceKindRawValue)
        switch sourceKind {
        case .microphone:
            return .microphone(
                inputID: inputID?.isEmpty == false ? inputID : nil,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameSize: frameSize
            )
        case .systemOutput:
            return .systemOutput(
                displayID: displayID,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameSize: frameSize,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio
            )
        }
    }
}
