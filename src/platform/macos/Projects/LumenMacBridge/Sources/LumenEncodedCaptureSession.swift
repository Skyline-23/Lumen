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

func lumenScreenCaptureCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    let rawCallbackMachTime = mach_absolute_time()
    guard let outputCallbackRefCon else { return }
    Unmanaged<LumenScreenCaptureVideoRuntime>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
        .enqueueCompressionOutput(
            status: status,
            infoFlags: infoFlags,
            sampleBuffer: sampleBuffer,
            contextPointer: sourceFrameRefCon,
            rawCallbackMachTime: rawCallbackMachTime
        )
}

func exactCodecConfigurationData(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any],
          let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
            as? [String: Any] else {
        return nil
    }
    return (atoms["avcC"] as? Data) ?? (atoms["hvcC"] as? Data)
}

func auditFourCC(_ value: OSType) -> String {
    String(bytes: [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ], encoding: .ascii) ?? String(value)
}

enum LumenMachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard timebase.denom != 0, end >= start else { return 0 }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    static func ticks(for time: CMTime) -> UInt64? {
        guard time.isValid, time.seconds.isFinite, time.seconds >= 0 else { return nil }
        guard timebase.numer != 0 else { return nil }
        let nanoseconds = time.seconds * 1_000_000_000
        return UInt64(nanoseconds * Double(timebase.denom) / Double(timebase.numer))
    }
}

enum LumenScreenCaptureError: Error, LocalizedError {
    case displayUnavailable(UInt32)
    case displayOwnershipLost(UInt32)
    case captureAlreadyRunning
    case captureNotRunning
    case outputOwnershipLost
    case compressionSessionCreationFailed(OSStatus)
    case compressionSessionPreparationFailed(OSStatus)
    case compressionFrameCompletionFailed(OSStatus)
    case compressionPropertyFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable(let displayID):
            return "ScreenCaptureKit display \(displayID) is unavailable."
        case .displayOwnershipLost(let displayID):
            return [
                "Retained virtual display \(displayID) was released",
                "before ScreenCaptureKit became ready."
            ].joined(separator: " ")
        case .captureAlreadyRunning:
            return "ScreenCaptureKit video stream is already starting or running."
        case .captureNotRunning:
            return "ScreenCaptureKit video stream is not running."
        case .outputOwnershipLost:
            return [
                "ScreenCaptureKit delivered a sample from a stream",
                "that no longer owns the registered video output."
            ].joined(separator: " ")
        case .compressionSessionCreationFailed(let status):
            return "Unable to create VideoToolbox compression session (OSStatus \(status))."
        case .compressionSessionPreparationFailed(let status):
            return "Unable to prepare VideoToolbox compression session (OSStatus \(status))."
        case .compressionFrameCompletionFailed(let status):
            return [
                "Unable to complete pending VideoToolbox frames",
                "during teardown (OSStatus \(status))."
            ].joined(separator: " ")
        case .compressionPropertyFailed(let key, let status):
            return "Unable to set VideoToolbox property \(key) (OSStatus \(status))."
        }
    }
}

enum LumenEncodedCaptureStartupError: Error, LocalizedError {
    case runtimeTerminated(any Error)

    var underlyingError: any Error {
        switch self {
        case .runtimeTerminated(let error):
            return error
        }
    }

    var errorDescription: String? {
        switch self {
        case .runtimeTerminated(let error):
            return "ScreenCaptureKit runtime terminated during startup: \(error.localizedDescription)"
        }
    }
}

actor LumenEncodedCaptureSession {
    let configuration: LumenMacCaptureConfiguration
    let preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?
    let preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks?
    let systemAudioPlaybackSuppression:
        LumenSystemAudioPlaybackSuppression?
    let runtimeFactory: any LumenEncodedCaptureRuntimeFactory
    var activeSystemAudio:
        LumenMacAudioCaptureConfiguration?
    var activeSystemAudioCallbacks: LumenAudioCaptureCallbacks?
    var activeSystemAudioIsActivated = false
    var runtime: (any LumenEncodedCaptureRuntime)?
    var startFlight: LumenCaptureStartFlight?
    var callbackGate: LumenCaptureCallbackGate?
    var systemAudioAttachFlight: LumenCaptureStartFlight?
    var systemAudioAttachGate: LumenCaptureCallbackGate?
    struct RuntimeStopRecord {
        let runtime: any LumenEncodedCaptureRuntime
        let task: Task<Void, Never>
    }
    var runtimeStopRecords: [ObjectIdentifier: RuntimeStopRecord] = [:]
    var statistics = LumenEncodedCaptureSessionStatistics()
    var callbacks: LumenEncodedCaptureCallbacks?
    var runtimeGeneration: UInt64 = 0
    var recoveryInProgressGeneration: UInt64?
    var isStopping = false
    let maximumAutomaticRestartCount: UInt64 = 2

    init(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration? = nil,
        preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks? = nil,
        systemAudioPlaybackSuppression:
            LumenSystemAudioPlaybackSuppression? = nil,
        runtimeFactory: any LumenEncodedCaptureRuntimeFactory
    ) {
        self.configuration = configuration
        self.preconfiguredSystemAudio = preconfiguredSystemAudio
        self.preconfiguredSystemAudioCallbacks = preconfiguredSystemAudioCallbacks
        self.systemAudioPlaybackSuppression =
            systemAudioPlaybackSuppression
        self.runtimeFactory = runtimeFactory
        activeSystemAudio = preconfiguredSystemAudio
        activeSystemAudioCallbacks =
            preconfiguredSystemAudioCallbacks
    }

}
