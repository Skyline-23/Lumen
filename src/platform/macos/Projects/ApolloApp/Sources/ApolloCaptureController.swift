import ApolloMacCaptureAdapter
import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    static let apolloRuntimeEvent = Notification.Name("ApolloRuntimeEventNotification")
}

@MainActor
final class ApolloCaptureController: ObservableObject {
    @Published private(set) var status: ApolloMacCaptureAdapterStatus?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastRuntimeEventMessage: String?

    private let adapter: ApolloMacCaptureAdapter
    private var statusObserver: NSObjectProtocol?
    private var companionStopObserver: NSObjectProtocol?
    private var runtimeEventObserver: NSObjectProtocol?
    private var isShuttingDown = false

    init(adapter: ApolloMacCaptureAdapter = ApolloMacCaptureAdapter()) {
        self.adapter = adapter
        statusObserver = NotificationCenter.default.addObserver(
            forName: .ApolloMacCaptureAdapterStatusDidChange,
            object: adapter,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
        companionStopObserver = NotificationCenter.default.addObserver(
            forName: .ApolloMacCaptureAdapterCompanionDidStop,
            object: adapter,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else {
                    return
                }

                self.lastErrorMessage = "Apollo web runtime stopped."
                NSApp.terminate(nil)
            }
        }
        runtimeEventObserver = NotificationCenter.default.addObserver(
            forName: .apolloRuntimeEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRuntimeEvent(notification)
            }
        }
        do {
            try adapter.startApolloCompanion()
            openWebDashboard()
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
        self.status = adapter.copyStatusSnapshot()
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        if let companionStopObserver {
            NotificationCenter.default.removeObserver(companionStopObserver)
        }
        if let runtimeEventObserver {
            NotificationCenter.default.removeObserver(runtimeEventObserver)
        }
        isShuttingDown = true
        adapter.stopApolloCompanion()
    }

    var menuBarImageName: String {
        guard let status else {
            return "bolt.horizontal.circle"
        }

        if status.captureSessionRunning || status.audioCaptureSessionRunning {
            return "dot.radiowaves.left.and.right"
        }
        if status.hostedApolloRuntimeRunning {
            return "bolt.horizontal.circle.fill"
        }
        return "exclamationmark.circle"
    }

    func refreshStatus() {
        status = adapter.copyStatusSnapshot()
    }

    var openWebTitle: String {
        "Open Apollo (localhost:47990)"
    }

    var streamControlTitle: String {
        status?.captureSessionRunning == true || status?.audioCaptureSessionRunning == true ? "Force Stop Stream" : "Reload Apps"
    }

    var canRestartApollo: Bool {
        true
    }

    func openWebDashboard(path: String = "/") {
        guard var components = URLComponents(string: "https://localhost:47990") else {
            return
        }

        let normalizedPath = path.isEmpty ? "/" : path
        if let hashIndex = normalizedPath.firstIndex(of: "#") {
            components.path = String(normalizedPath[..<hashIndex]).isEmpty ? "/" : String(normalizedPath[..<hashIndex])
            components.fragment = String(normalizedPath[normalizedPath.index(after: hashIndex)...])
        } else {
            components.path = normalizedPath
        }

        guard let url = components.url else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func restartApolloCompanion() {
        lastErrorMessage = nil
        do {
            try adapter.restartApolloCompanion()
            openWebDashboard()
            refreshStatus()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func forceStopCurrentStream() {
        adapter.forceStopCurrentStream()
        refreshStatus()
    }

    func quitApplication() {
        isShuttingDown = true
        NSApp.terminate(nil)
    }

    func prepareForTermination() {
        isShuttingDown = true
        adapter.stopApolloCompanion()
    }

    private func handleRuntimeEvent(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            return
        }

        let identifier = userInfo["identifier"] as? String ?? UUID().uuidString
        let title = userInfo["title"] as? String ?? "Apollo"
        let body = userInfo["body"] as? String ?? ""
        let launchPath = userInfo["launchPath"] as? String ?? "/"

        lastRuntimeEventMessage = body
        presentRuntimeNotification(
            identifier: identifier,
            title: title,
            body: body,
            launchPath: launchPath
        )
    }

    private func presentRuntimeNotification(
        identifier: String,
        title: String,
        body: String,
        launchPath: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["apolloLaunchPath": launchPath]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
