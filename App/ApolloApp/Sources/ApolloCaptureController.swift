import ApolloMacCaptureAdapter
import CoreGraphics
import Foundation

@MainActor
final class ApolloCaptureController: ObservableObject {
    @Published private(set) var status: ApolloMacCaptureAdapterStatus?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isStarting = false

    private let adapter: ApolloMacCaptureAdapter
    private var refreshTask: Task<Void, Never>?
    private var hasAttemptedAutoStart = false

    init(adapter: ApolloMacCaptureAdapter = ApolloMacCaptureAdapter()) {
        self.adapter = adapter
        self.status = adapter.copyStatusSnapshot()
    }

    func startIfNeeded() async {
        guard !hasAttemptedAutoStart else {
            return
        }

        hasAttemptedAutoStart = true
        await startOrRestartCapture()
    }

    func startOrRestartCapture() async {
        refreshTask?.cancel()
        isStarting = true
        lastErrorMessage = nil

        let configuration = adapter.makePanelNativeConfiguration(forDisplayID: CGMainDisplayID())

        do {
            try adapter.startManagedCaptureSession(
                with: configuration,
                frameCapacity: 128,
                eventCapacity: 32
            )
            status = adapter.copyStatusSnapshot()
            startRefreshLoop()
        } catch {
            status = adapter.copyStatusSnapshot()
            lastErrorMessage = error.localizedDescription
        }

        isStarting = false
    }

    func stopCapture() {
        refreshTask?.cancel()
        refreshTask = nil
        adapter.stopManagedCaptureSession()
        status = adapter.copyStatusSnapshot()
    }

    func refreshStatus() {
        status = adapter.copyStatusSnapshot()
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                self.refreshStatus()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
