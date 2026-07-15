import Foundation

public struct LumenHostReadinessState: Equatable, Sendable {
    public var runtimeRunning: Bool
    public var videoCaptureRunning: Bool
    public var audioCaptureRunning: Bool
    public var accessibilityGranted: Bool
    public var screenCaptureGranted: Bool
    public var lastErrorMessage: String?

    public init(
        runtimeRunning: Bool = false,
        videoCaptureRunning: Bool = false,
        audioCaptureRunning: Bool = false,
        accessibilityGranted: Bool = false,
        screenCaptureGranted: Bool = false,
        lastErrorMessage: String? = nil
    ) {
        self.runtimeRunning = runtimeRunning
        self.videoCaptureRunning = videoCaptureRunning
        self.audioCaptureRunning = audioCaptureRunning
        self.accessibilityGranted = accessibilityGranted
        self.screenCaptureGranted = screenCaptureGranted
        self.lastErrorMessage = lastErrorMessage
    }
}

public enum LumenHostReadinessAction: Equatable, Sendable {
    case runtimeStatusChanged(runtime: Bool, video: Bool, audio: Bool)
    case permissionsChanged(accessibility: Bool, screenCapture: Bool)
    case runtimeStopped(message: String)
    case errorChanged(String?)
}

public actor LumenHostReadinessStore {
    private var state: LumenHostReadinessState
    private var continuations: [UUID: AsyncStream<LumenHostReadinessState>.Continuation] = [:]

    public init(initialState: LumenHostReadinessState = LumenHostReadinessState()) {
        state = initialState
    }

    public func snapshot() -> LumenHostReadinessState {
        state
    }

    public func states() -> AsyncStream<LumenHostReadinessState> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: LumenHostReadinessState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(identifier)
            }
        }
        continuations[identifier] = continuation
        continuation.yield(state)
        return stream
    }

    public func send(_ action: LumenHostReadinessAction) {
        let previousState = state
        reduce(action)
        guard state != previousState else {
            return
        }
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private func reduce(_ action: LumenHostReadinessAction) {
        switch action {
        case let .runtimeStatusChanged(runtime, video, audio):
            state.runtimeRunning = runtime
            state.videoCaptureRunning = video
            state.audioCaptureRunning = audio
            if runtime {
                state.lastErrorMessage = nil
            }
        case let .permissionsChanged(accessibility, screenCapture):
            state.accessibilityGranted = accessibility
            state.screenCaptureGranted = screenCapture
        case let .runtimeStopped(message):
            state.runtimeRunning = false
            state.videoCaptureRunning = false
            state.audioCaptureRunning = false
            state.lastErrorMessage = message
        case let .errorChanged(message):
            state.lastErrorMessage = message
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}
