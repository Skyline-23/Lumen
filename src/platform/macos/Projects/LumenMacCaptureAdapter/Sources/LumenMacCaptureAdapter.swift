import LumenHostedRuntime
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
    public let hostedRuntimeRunning: Bool
    public let captureSessionRunning: Bool
    public let audioCaptureSessionRunning: Bool
    public let automaticCaptureOrchestrationRunning: Bool
    public let forwardingPumpRunning: Bool
    public let forwardedFrameCallbackCount: UInt
    public let forwardedEventCallbackCount: UInt
    public let forwardedAudioFrameCallbackCount: UInt
    public let forwardedAudioEventCallbackCount: UInt
    public let coreForwardingSnapshot: ApolloCoreEncodedCaptureIngressSnapshot
    public let audioForwardingSnapshot: ApolloMacBridgeAudioForwardingSnapshot

    public init(
        coreVersion: String,
        runtimeDescription: String,
        integrationStatus: String,
        hostedRuntimeRunning: Bool,
        captureSessionRunning: Bool,
        audioCaptureSessionRunning: Bool,
        automaticCaptureOrchestrationRunning: Bool,
        forwardingPumpRunning: Bool,
        forwardedFrameCallbackCount: UInt,
        forwardedEventCallbackCount: UInt,
        forwardedAudioFrameCallbackCount: UInt,
        forwardedAudioEventCallbackCount: UInt,
        coreForwardingSnapshot: ApolloCoreEncodedCaptureIngressSnapshot,
        audioForwardingSnapshot: ApolloMacBridgeAudioForwardingSnapshot
    ) {
        self.coreVersion = coreVersion
        self.runtimeDescription = runtimeDescription
        self.integrationStatus = integrationStatus
        self.hostedRuntimeRunning = hostedRuntimeRunning
        self.captureSessionRunning = captureSessionRunning
        self.audioCaptureSessionRunning = audioCaptureSessionRunning
        self.automaticCaptureOrchestrationRunning = automaticCaptureOrchestrationRunning
        self.forwardingPumpRunning = forwardingPumpRunning
        self.forwardedFrameCallbackCount = forwardedFrameCallbackCount
        self.forwardedEventCallbackCount = forwardedEventCallbackCount
        self.forwardedAudioFrameCallbackCount = forwardedAudioFrameCallbackCount
        self.forwardedAudioEventCallbackCount = forwardedAudioEventCallbackCount
        self.coreForwardingSnapshot = coreForwardingSnapshot
        self.audioForwardingSnapshot = audioForwardingSnapshot
    }
}

public struct LumenMacCaptureAdapterMenuStatus: Equatable, Sendable {
    public let hostedRuntimeRunning: Bool
    public let captureSessionRunning: Bool
    public let audioCaptureSessionRunning: Bool

    public init(
        hostedRuntimeRunning: Bool,
        captureSessionRunning: Bool,
        audioCaptureSessionRunning: Bool
    ) {
        self.hostedRuntimeRunning = hostedRuntimeRunning
        self.captureSessionRunning = captureSessionRunning
        self.audioCaptureSessionRunning = audioCaptureSessionRunning
    }
}

@objcMembers
public final class LumenMacCaptureAdapter: NSObject {
    private let bridgeController: OpaquePointer
    private let hostedRuntimeController: OpaquePointer
    private let hostedRuntimeDidStopNotification = Notification.Name("LumenHostedRuntimeDidStopNotification")

    private var forwardingPumpRunning = false
    private var stoppingCompanion = false
    private var bridgeStatusObserver: NSObjectProtocol?
    private var hostedRuntimeStopObserver: NSObjectProtocol?

    public override init() {
        guard let bridgeController = ApolloMacBridgeControllerCreate() else {
            fatalError("ApolloMacBridgeControllerCreate returned nil")
        }
        guard let hostedRuntimeController = LumenHostedRuntimeControllerCreate() else {
            fatalError("LumenHostedRuntimeControllerCreate returned nil")
        }

        self.bridgeController = bridgeController
        self.hostedRuntimeController = hostedRuntimeController
        super.init()

        bridgeStatusObserver = NotificationCenter.default.addObserver(
            forName: ApolloBridgeRuntime.statusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.postStatusDidChangeNotification()
        }

        hostedRuntimeStopObserver = NotificationCenter.default.addObserver(
            forName: hostedRuntimeDidStopNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }

            self.postStatusDidChangeNotification()
            if !self.stoppingCompanion {
                NotificationCenter.default.post(
                    name: .lumenMacCaptureAdapterCompanionDidStop,
                    object: self
                )
            }
        }
    }

    deinit {
        if let bridgeStatusObserver {
            NotificationCenter.default.removeObserver(bridgeStatusObserver)
        }
        if let hostedRuntimeStopObserver {
            NotificationCenter.default.removeObserver(hostedRuntimeStopObserver)
        }

        stopRuntimeCompanion()
        ApolloMacBridgeControllerDestroy(bridgeController)
        LumenHostedRuntimeControllerDestroy(hostedRuntimeController)
    }

    public func makePanelNativeConfiguration(forDisplayID displayID: UInt32) -> ApolloMacBridgeCaptureConfiguration {
        ApolloMacBridgeControllerMakePanelNativeConfiguration(displayID)
    }

    public func makeDefaultMicrophoneAudioConfiguration() -> ApolloMacBridgeAudioCaptureConfiguration {
        ApolloMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration()
    }

    public func makeSystemOutputAudioConfiguration(forDisplayID displayID: UInt32) -> ApolloMacBridgeAudioCaptureConfiguration {
        ApolloMacBridgeControllerMakeSystemOutputAudioConfiguration(displayID)
    }

    public func startRuntimeCompanion() throws {
        stoppingCompanion = false
        let started = withErrorBuffer { errorBuffer, errorCapacity in
            LumenHostedRuntimeControllerStart(
                hostedRuntimeController,
                errorBuffer,
                errorCapacity
            )
        }

        guard started.result else {
            postStatusDidChangeNotification()
            throw adapterError(started.errorMessage)
        }

        startAutomaticCoreCaptureOrchestration()
        postStatusDidChangeNotification()
    }

    public func restartRuntimeCompanion() throws {
        stopRuntimeCompanion()
        try startRuntimeCompanion()
    }

    public func stopRuntimeCompanion() {
        stoppingCompanion = true
        stopAutomaticCoreCaptureOrchestration()
        stopForwardingPump()
        LumenHostedRuntimeControllerStop(hostedRuntimeController)
        postStatusDidChangeNotification()
    }

    public func forceStopCurrentStream() {
        LumenHostedRuntimeControllerForceStopStream(hostedRuntimeController)
    }

    public var isAccessibilityPermissionGranted: Bool {
        LumenHostedRuntimeIsAccessibilityPermissionGranted()
    }

    public func requestAccessibilityPermission() {
        LumenHostedRuntimeRequestAccessibilityPermission()
    }

    public var isScreenCapturePermissionGranted: Bool {
        LumenHostedRuntimeIsScreenCapturePermissionGranted()
    }

    public func requestScreenCapturePermission() {
        LumenHostedRuntimeRequestScreenCapturePermission()
    }

    public func startManagedCaptureSession(
        with configuration: ApolloMacBridgeCaptureConfiguration,
        frameCapacity: UInt,
        eventCapacity: UInt
    ) throws {
        stopManagedCaptureSession()
        configureCoreForwarding(withFrameCapacity: frameCapacity, eventCapacity: eventCapacity)
        try startMacDisplayKitCapture(with: configuration)
        try startForwardingPump()
    }

    public func stopManagedCaptureSession() {
        stopForwardingPump()
        stopMacDisplayKitCapture()
    }

    public func startManagedAudioCaptureSession(
        with configuration: ApolloMacBridgeAudioCaptureConfiguration,
        frameCapacity: UInt,
        eventCapacity: UInt
    ) throws {
        stopManagedAudioCaptureSession()
        configureAudioForwarding(withFrameCapacity: frameCapacity, eventCapacity: eventCapacity)
        try startMacDisplayKitAudioCapture(with: configuration)
        if !forwardingPumpRunning {
            try startForwardingPump()
        }
    }

    public func stopManagedAudioCaptureSession() {
        stopMacDisplayKitAudioCapture()
    }

    public func configureCoreForwarding(withFrameCapacity frameCapacity: UInt, eventCapacity: UInt) {
        ApolloMacBridgeControllerConfigureCoreForwarding(
            bridgeController,
            numericCast(frameCapacity),
            numericCast(eventCapacity)
        )
    }

    public func configureAudioForwarding(withFrameCapacity frameCapacity: UInt, eventCapacity: UInt) {
        ApolloMacBridgeControllerConfigureAudioForwarding(
            bridgeController,
            numericCast(frameCapacity),
            numericCast(eventCapacity)
        )
    }

    public func startMacDisplayKitCapture(with configuration: ApolloMacBridgeCaptureConfiguration) throws {
        let started = withErrorBuffer { errorBuffer, errorCapacity in
            ApolloMacBridgeControllerStartMacDisplayKitCapture(
                bridgeController,
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

    public func stopMacDisplayKitCapture() {
        ApolloMacBridgeControllerStopMacDisplayKitCapture(bridgeController)
        postStatusDidChangeNotification()
    }

    public func startMacDisplayKitAudioCapture(with configuration: ApolloMacBridgeAudioCaptureConfiguration) throws {
        let started = withErrorBuffer { errorBuffer, errorCapacity in
            ApolloMacBridgeControllerStartMacDisplayKitAudioCapture(
                bridgeController,
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

    public func stopMacDisplayKitAudioCapture() {
        ApolloMacBridgeControllerStopMacDisplayKitAudioCapture(bridgeController)
        postStatusDidChangeNotification()
    }

    public func startAutomaticCoreCaptureOrchestration() {
        ApolloMacBridgeControllerStartApolloCoreCaptureAutomation(bridgeController)
        postStatusDidChangeNotification()
    }

    public func stopAutomaticCoreCaptureOrchestration() {
        ApolloMacBridgeControllerStopApolloCoreCaptureAutomation(bridgeController)
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
        let bridgeStatus = ApolloMacBridgeControllerCopyStatusSnapshot(bridgeController)
        let coreForwardingSnapshot = ApolloMacBridgeControllerCopyCoreForwardingSnapshot(bridgeController)
        let audioForwardingSnapshot = ApolloMacBridgeControllerCopyAudioForwardingSnapshot(bridgeController)

        return LumenMacCaptureAdapterStatus(
            coreVersion: stringFromCStringTuple(bridgeStatus.core_version),
            runtimeDescription: stringFromCStringTuple(bridgeStatus.runtime_description),
            integrationStatus: stringFromCStringTuple(bridgeStatus.integration_status),
            hostedRuntimeRunning: LumenHostedRuntimeControllerIsRunning(hostedRuntimeController),
            captureSessionRunning: bridgeStatus.capture_session_running,
            audioCaptureSessionRunning: bridgeStatus.audio_capture_session_running,
            automaticCaptureOrchestrationRunning: bridgeStatus.automatic_capture_orchestration_running,
            forwardingPumpRunning: forwardingPumpRunning,
            forwardedFrameCallbackCount: numericCast(coreForwardingSnapshot.frame_count),
            forwardedEventCallbackCount: numericCast(coreForwardingSnapshot.event_count),
            forwardedAudioFrameCallbackCount: numericCast(audioForwardingSnapshot.frame_count),
            forwardedAudioEventCallbackCount: numericCast(audioForwardingSnapshot.event_count),
            coreForwardingSnapshot: coreForwardingSnapshot,
            audioForwardingSnapshot: audioForwardingSnapshot
        )
    }

    public func copyMenuStatusSnapshot() -> LumenMacCaptureAdapterMenuStatus {
        let bridgeStatus = ApolloMacBridgeControllerCopyStatusSnapshot(bridgeController)

        return LumenMacCaptureAdapterMenuStatus(
            hostedRuntimeRunning: LumenHostedRuntimeControllerIsRunning(hostedRuntimeController),
            captureSessionRunning: bridgeStatus.capture_session_running,
            audioCaptureSessionRunning: bridgeStatus.audio_capture_session_running
        )
    }

    private func postStatusDidChangeNotification() {
        NotificationCenter.default.post(name: .lumenMacCaptureAdapterStatusDidChange, object: self)
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
        let errorMessage = errorBuffer.first == 0 ? nil : String(cString: errorBuffer)
        return (result, errorMessage)
    }
}

private func stringFromCStringTuple<T>(_ tuple: T) -> String {
    withUnsafePointer(to: tuple) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cStringPointer in
            String(cString: cStringPointer)
        }
    }
}
