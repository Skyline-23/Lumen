import LumenEngineBridge

extension LumenBridgeObjCFacade {
    static func codec(fromRawValue rawValue: Int) -> LumenCaptureCodec {
        switch rawValue {
        case Int(LumenMacCaptureCodecH264.rawValue):
            return .h264
        case Int(LumenMacCaptureCodecHEVC.rawValue):
            return .hevc
        default:
            return .hevc
        }
    }

    static func preprocessStrategy(fromRawValue rawValue: Int) -> LumenCapturePreprocessStrategy {
        switch rawValue {
        case 1:
            return .downscale2x
        default:
            return .none
        }
    }

    static func queueProfile(fromRawValue rawValue: Int) -> LumenCaptureQueueProfile {
        switch rawValue {
        case 4:
            return .auto
        case 0:
            return .q1
        case 1:
            return .q2
        case 2:
            return .q3
        case 3:
            return .q4
        default:
            return .q2
        }
    }

    static func clientSinkGamut(fromRawValue rawValue: Int) -> LumenClientSinkGamut {
        switch rawValue {
        case 1:
            return .srgb
        case 2:
            return .displayP3
        case 3:
            return .rec2020
        default:
            return .unknown
        }
    }

    static func clientSinkTransfer(fromRawValue rawValue: Int) -> LumenClientSinkTransfer {
        switch rawValue {
        case 1:
            return .sdr
        case 2:
            return .pq
        case 3:
            return .hlg
        default:
            return .unknown
        }
    }

    static func audioSourceKind(fromRawValue rawValue: Int) -> LumenAudioCaptureSourceKind {
        switch rawValue {
        case 1:
            return .systemOutput
        default:
            return .microphone
        }
    }

    static func rawValue(for codec: LumenCaptureCodec) -> Int {
        switch codec {
        case .h264:
            return Int(LumenMacCaptureCodecH264.rawValue)
        case .hevc:
            return Int(LumenMacCaptureCodecHEVC.rawValue)
        }
    }

    static func rawValue(for strategy: LumenCapturePreprocessStrategy) -> Int {
        switch strategy {
        case .none:
            return 0
        case .downscale2x:
            return 1
        }
    }

    static func rawValue(for queueProfile: LumenCaptureQueueProfile) -> Int {
        switch queueProfile {
        case .auto:
            return 4
        case .q1:
            return 0
        case .q2:
            return 1
        case .q3:
            return 2
        case .q4:
            return 3
        }
    }

    static func rawValue(for clientSinkGamut: LumenClientSinkGamut) -> Int {
        switch clientSinkGamut {
        case .unknown:
            return 0
        case .srgb:
            return 1
        case .displayP3:
            return 2
        case .rec2020:
            return 3
        }
    }

    static func rawValue(for clientSinkTransfer: LumenClientSinkTransfer) -> Int {
        switch clientSinkTransfer {
        case .unknown:
            return 0
        case .sdr:
            return 1
        case .pq:
            return 2
        case .hlg:
            return 3
        }
    }

    static func rawValue(for audioSourceKind: LumenAudioCaptureSourceKind) -> Int {
        switch audioSourceKind {
        case .microphone:
            return 0
        case .systemOutput:
            return 1
        }
    }

    static func rawValue(for eventKind: LumenBridgeCaptureEventKind) -> Int {
        switch eventKind {
        case .started:
            return Int(LumenMacCaptureEventKindStarted.rawValue)
        case .stopped:
            return Int(LumenMacCaptureEventKindStopped.rawValue)
        case .restarted:
            return Int(LumenMacCaptureEventKindRestarted.rawValue)
        case .failed:
            return Int(LumenMacCaptureEventKindFailed.rawValue)
        case .droppedFrame:
            return Int(LumenMacCaptureEventKindDroppedFrame.rawValue)
        case .coalescedFrame:
            return Int(LumenMacCaptureEventKindCoalescedFrame.rawValue)
        }
    }
}
