actor LumenBridgeCaptureLifecycle {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        case stopping
    }

    private var state: State = .idle

    var currentState: State {
        state
    }

    var shouldExposeProducer: Bool {
        state == .running
    }

    var shouldRequestImmediateKeyFrame: Bool {
        state == .running
    }

    func beginStartup() {
        state = .starting
    }

    func finishStartup() {
        state = .running
    }

    func failStartup() {
        state = .idle
    }

    func beginStop() {
        state = .stopping
    }

    func finishStop() {
        state = .idle
    }
}
