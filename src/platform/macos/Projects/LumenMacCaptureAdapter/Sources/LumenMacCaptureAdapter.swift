import LumenHostRuntimeBridge
import LumenMacBridge
import Foundation

public extension Notification.Name {
    static let lumenMacCaptureAdapterStatusDidChange = Notification.Name(
        "LumenMacCaptureAdapterStatusDidChangeNotification"
    )
    static let lumenMacCaptureAdapterCompanionDidStop = Notification.Name(
        "LumenMacCaptureAdapterCompanionDidStopNotification"
    )
}

@objcMembers
public final class LumenMacCaptureAdapterStatus: NSObject {
    public let coreVersion: String
    public let runtimeDescription: String
    public let integrationStatus: String
    public let hostRuntimeRunning: Bool
    public let captureSessionRunning: Bool
    public let audioCaptureSessionRunning: Bool
    public let automaticCaptureOrchestrationRunning: Bool
    public let forwardingPumpRunning: Bool
    public let forwardedFrameCallbackCount: UInt
    public let forwardedEventCallbackCount: UInt
    public let forwardedAudioFrameCallbackCount: UInt
    public let forwardedAudioEventCallbackCount: UInt
    public let videoForwardingSnapshot: LumenMacEncodedCaptureIngressSnapshot
    public let audioForwardingSnapshot: LumenMacBridgeAudioForwardingSnapshot

    public init(
        coreVersion: String,
        runtimeDescription: String,
        integrationStatus: String,
        hostRuntimeRunning: Bool,
        captureSessionRunning: Bool,
        audioCaptureSessionRunning: Bool,
        automaticCaptureOrchestrationRunning: Bool,
        forwardingPumpRunning: Bool,
        forwardedFrameCallbackCount: UInt,
        forwardedEventCallbackCount: UInt,
        forwardedAudioFrameCallbackCount: UInt,
        forwardedAudioEventCallbackCount: UInt,
        videoForwardingSnapshot: LumenMacEncodedCaptureIngressSnapshot,
        audioForwardingSnapshot: LumenMacBridgeAudioForwardingSnapshot
    ) {
        self.coreVersion = coreVersion
        self.runtimeDescription = runtimeDescription
        self.integrationStatus = integrationStatus
        self.hostRuntimeRunning = hostRuntimeRunning
        self.captureSessionRunning = captureSessionRunning
        self.audioCaptureSessionRunning = audioCaptureSessionRunning
        self.automaticCaptureOrchestrationRunning = automaticCaptureOrchestrationRunning
        self.forwardingPumpRunning = forwardingPumpRunning
        self.forwardedFrameCallbackCount = forwardedFrameCallbackCount
        self.forwardedEventCallbackCount = forwardedEventCallbackCount
        self.forwardedAudioFrameCallbackCount = forwardedAudioFrameCallbackCount
        self.forwardedAudioEventCallbackCount = forwardedAudioEventCallbackCount
        self.videoForwardingSnapshot = videoForwardingSnapshot
        self.audioForwardingSnapshot = audioForwardingSnapshot
    }
}

public struct LumenMacCaptureAdapterMenuStatus: Equatable, Sendable {
    public let hostRuntimeRunning: Bool
    public let captureSessionRunning: Bool
    public let audioCaptureSessionRunning: Bool

    public init(
        hostRuntimeRunning: Bool,
        captureSessionRunning: Bool,
        audioCaptureSessionRunning: Bool
    ) {
        self.hostRuntimeRunning = hostRuntimeRunning
        self.captureSessionRunning = captureSessionRunning
        self.audioCaptureSessionRunning = audioCaptureSessionRunning
    }
}

@objcMembers
@MainActor
public final class LumenMacCaptureAdapter: NSObject {
    private let bridgeController: LumenNativeControllerHandle
    private let hostRuntimeController: LumenNativeControllerHandle
    private let hostRuntimeDidStopNotification = Notification.Name("LumenHostRuntimeDidStopNotification")

    private var forwardingPumpRunning = false
    private var stoppingCompanion = false

    public override init() {
        guard let bridgeController = LumenMacBridgeControllerCreate() else {
            fatalError("LumenMacBridgeControllerCreate returned nil")
        }
        guard let hostRuntimeController = LumenHostRuntimeControllerCreate() else {
            fatalError("LumenHostRuntimeControllerCreate returned nil")
        }

        self.bridgeController = LumenNativeControllerHandle(bridgeController) {
            LumenMacBridgeControllerDestroy($0)
        }
        self.hostRuntimeController = LumenNativeControllerHandle(hostRuntimeController) {
            LumenHostRuntimeControllerStop($0)
            LumenHostRuntimeControllerDestroy($0)
        }
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBridgeStatusDidChange),
            name: LumenBridgeRuntime.statusDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHostRuntimeDidStop(_:)),
            name: hostRuntimeDidStopNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func makePanelNativeConfiguration(forDisplayID displayID: UInt32) -> LumenMacBridgeCaptureConfiguration {
        LumenMacBridgeControllerMakePanelNativeConfiguration(displayID)
    }

    public func makeDefaultMicrophoneAudioConfiguration() -> LumenMacBridgeAudioCaptureConfiguration {
        LumenMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration()
    }

    public func makeSystemOutputAudioConfiguration(forDisplayID displayID: UInt32) -> LumenMacBridgeAudioCaptureConfiguration {
        LumenMacBridgeControllerMakeSystemOutputAudioConfiguration(displayID)
    }

    public func startRuntimeCompanion() throws {
        stoppingCompanion = false
        let started = withErrorBuffer { errorBuffer, errorCapacity in
            LumenHostRuntimeControllerStart(
                hostRuntimeController.rawValue,
                errorBuffer,
                errorCapacity
            )
        }

        guard started.result else {
            postStatusDidChangeNotification()
            throw adapterError(started.errorMessage)
        }

        postStatusDidChangeNotification()
    }

    public func restartRuntimeCompanion() throws {
        stopRuntimeCompanion()
        try startRuntimeCompanion()
    }

    public func stopRuntimeCompanion() {
        stoppingCompanion = true
        stopForwardingPump()
        LumenHostRuntimeControllerStop(hostRuntimeController.rawValue)
        postStatusDidChangeNotification()
    }

    public func factoryReset() throws {
        stopRuntimeCompanion()
        let reset = withErrorBuffer { errorBuffer, errorCapacity in
            LumenHostRuntimeControllerFactoryReset(
                hostRuntimeController.rawValue,
                errorBuffer,
                errorCapacity
            )
        }

        guard reset.result else {
            throw adapterError(reset.errorMessage)
        }
    }

    public func forceStopCurrentStream() {
        LumenHostRuntimeControllerForceStopStream(hostRuntimeController.rawValue)
    }

    public func reloadApplications() {
        LumenHostRuntimeControllerReloadApplications(hostRuntimeController.rawValue)
    }

    public var isAccessibilityPermissionGranted: Bool {
        LumenHostRuntimeIsAccessibilityPermissionGranted()
    }

    public func requestAccessibilityPermission() {
        LumenHostRuntimeRequestAccessibilityPermission()
    }

    public var isScreenCapturePermissionGranted: Bool {
        LumenHostRuntimeIsScreenCapturePermissionGranted()
    }

    public func requestScreenCapturePermission() {
        LumenHostRuntimeRequestScreenCapturePermission()
    }

    public func startManagedCaptureSession(
        with configuration: LumenMacBridgeCaptureConfiguration,
        frameCapacity: UInt,
        eventCapacity: UInt
    ) throws {
        stopManagedCaptureSession()
        configureVideoForwarding(withFrameCapacity: frameCapacity, eventCapacity: eventCapacity)
        try startCapture(with: configuration)
        try startForwardingPump()
    }

    public func stopManagedCaptureSession() {
        stopForwardingPump()
        stopCapture()
    }

    public func startManagedAudioCaptureSession(
        with configuration: LumenMacBridgeAudioCaptureConfiguration,
        frameCapacity: UInt,
        eventCapacity: UInt
    ) throws {
        stopManagedAudioCaptureSession()
        configureAudioForwarding(withFrameCapacity: frameCapacity, eventCapacity: eventCapacity)
        try startAudioCapture(with: configuration)
        if !forwardingPumpRunning {
            try startForwardingPump()
        }
    }

    public func stopManagedAudioCaptureSession() {
        stopAudioCapture()
    }

    public func configureVideoForwarding(withFrameCapacity frameCapacity: UInt, eventCapacity: UInt) {
        LumenMacBridgeControllerConfigureVideoForwarding(
            bridgeController.rawValue,
            numericCast(frameCapacity),
            numericCast(eventCapacity)
        )
    }

    public func configureAudioForwarding(withFrameCapacity frameCapacity: UInt, eventCapacity: UInt) {
        LumenMacBridgeControllerConfigureAudioForwarding(
            bridgeController.rawValue,
            numericCast(frameCapacity),
            numericCast(eventCapacity)
        )
    }

    public func startCapture(with configuration: LumenMacBridgeCaptureConfiguration) throws {
        let started = withErrorBuffer { errorBuffer, errorCapacity in
            LumenMacBridgeControllerStartCapture(
                bridgeController.rawValue,
                configuration,
                errorBuffer,
                errorCapacity
            )
        }

        guard started.result else {
            throw adapterError(started.errorMessage)
        }

        postStatusDidChangeNotification()
    }

    public func stopCapture() {
        LumenMacBridgeControllerStopCapture(bridgeController.rawValue)
        postStatusDidChangeNotification()
    }

    public func startAudioCapture(with configuration: LumenMacBridgeAudioCaptureConfiguration) throws {
        let started = withErrorBuffer { errorBuffer, errorCapacity in
            LumenMacBridgeControllerStartAudioCapture(
                bridgeController.rawValue,
                configuration,
                errorBuffer,
                errorCapacity
            )
        }

        guard started.result else {
            throw adapterError(started.errorMessage)
        }

        postStatusDidChangeNotification()
    }

    public func stopAudioCapture() {
        LumenMacBridgeControllerStopAudioCapture(bridgeController.rawValue)
        postStatusDidChangeNotification()
    }

    public func startForwardingPump() throws {
        forwardingPumpRunning = true
        postStatusDidChangeNotification()
    }

    public func stopForwardingPump() {
        forwardingPumpRunning = false
        postStatusDidChangeNotification()
    }

    public func copyStatusSnapshot() -> LumenMacCaptureAdapterStatus {
        let bridgeStatus = LumenMacBridgeControllerCopyStatusSnapshot(bridgeController.rawValue)
        let videoForwardingSnapshot = LumenMacBridgeControllerCopyVideoForwardingSnapshot(bridgeController.rawValue)
        let audioForwardingSnapshot = LumenMacBridgeControllerCopyAudioForwardingSnapshot(bridgeController.rawValue)

        return LumenMacCaptureAdapterStatus(
            coreVersion: stringFromCStringTuple(bridgeStatus.core_version),
            runtimeDescription: stringFromCStringTuple(bridgeStatus.runtime_description),
            integrationStatus: stringFromCStringTuple(bridgeStatus.integration_status),
            hostRuntimeRunning: LumenHostRuntimeControllerIsRunning(hostRuntimeController.rawValue),
            captureSessionRunning: bridgeStatus.capture_session_running,
            audioCaptureSessionRunning: bridgeStatus.audio_capture_session_running,
            automaticCaptureOrchestrationRunning: bridgeStatus.automatic_capture_orchestration_running,
            forwardingPumpRunning: forwardingPumpRunning,
            forwardedFrameCallbackCount: numericCast(videoForwardingSnapshot.frame_count),
            forwardedEventCallbackCount: numericCast(videoForwardingSnapshot.event_count),
            forwardedAudioFrameCallbackCount: numericCast(audioForwardingSnapshot.frame_count),
            forwardedAudioEventCallbackCount: numericCast(audioForwardingSnapshot.event_count),
            videoForwardingSnapshot: videoForwardingSnapshot,
            audioForwardingSnapshot: audioForwardingSnapshot
        )
    }

    public func copyMenuStatusSnapshot() -> LumenMacCaptureAdapterMenuStatus {
        let bridgeStatus = LumenMacBridgeControllerCopyStatusSnapshot(bridgeController.rawValue)

        return LumenMacCaptureAdapterMenuStatus(
            hostRuntimeRunning: LumenHostRuntimeControllerIsRunning(hostRuntimeController.rawValue),
            captureSessionRunning: bridgeStatus.capture_session_running,
            audioCaptureSessionRunning: bridgeStatus.audio_capture_session_running
        )
    }

    private func postStatusDidChangeNotification() {
        NotificationCenter.default.post(name: .lumenMacCaptureAdapterStatusDidChange, object: self)
    }

    @objc private func handleBridgeStatusDidChange() {
        postStatusDidChangeNotification()
    }

    @objc private func handleHostRuntimeDidStop(_ notification: Notification) {
        postStatusDidChangeNotification()
        let willRestart = notification.userInfo?["willRestart"] as? Bool == true
        guard !willRestart, !stoppingCompanion else {
            return
        }

        NotificationCenter.default.post(
            name: .lumenMacCaptureAdapterCompanionDidStop,
            object: self
        )
    }
}

private extension LumenMacCaptureAdapter {
    func adapterError(_ description: String?) -> NSError {
        NSError(
            domain: "LumenMacCaptureAdapter",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: description?.isEmpty == false
                    ? description!
                    : "LumenMacCaptureAdapter failed."
            ]
        )
    }

    func withErrorBuffer(
        _ body: (_ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorCapacity: Int) -> Bool
    ) -> (result: Bool, errorMessage: String?) {
        var errorBuffer = Array<CChar>(repeating: 0, count: 512)
        let result = errorBuffer.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
        let errorMessage = errorBuffer.first == 0 ? nil : stringFromCStringArray(errorBuffer)
        return (result, errorMessage)
    }
}

private func stringFromCStringTuple<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private func stringFromCStringArray(_ characters: [CChar]) -> String {
    let bytes = characters.lazy.map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
}

private final class LumenNativeControllerHandle: Sendable {
    private let address: UInt
    private let destructor: @Sendable (OpaquePointer) -> Void

    init(_ pointer: OpaquePointer, destructor: @escaping @Sendable (OpaquePointer) -> Void) {
        address = UInt(bitPattern: pointer)
        self.destructor = destructor
    }

    deinit {
        destructor(rawValue)
    }

    var rawValue: OpaquePointer {
        guard let pointer = OpaquePointer(bitPattern: address) else {
            preconditionFailure("Lumen native controller lost its pointer value")
        }
        return pointer
    }
}
