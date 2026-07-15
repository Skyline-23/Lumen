import AppKit

@MainActor
final class LumenWorkspaceApplicationRelauncher: LumenApplicationRelaunching {
    private let applicationURL: URL

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
    }

    func relaunch() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        NSApp.terminate(nil)
    }
}
