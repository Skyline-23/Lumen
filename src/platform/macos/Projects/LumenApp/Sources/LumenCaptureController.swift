@preconcurrency import LumenMacCaptureAdapter
import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    static let lumenRuntimeEvent = Notification.Name("LumenRuntimeEventNotification")
    static let lumenRuntimeWebUIReady = Notification.Name("LumenRuntimeWebUIReadyNotification")
}

@MainActor
final class LumenCaptureController: ObservableObject {
    private enum WebDashboardConfiguration {
        static let defaultBasePort = 47_989
        static let httpsPortOffset = 1
        static let configurationDirectoryName = "Lumen"
        static let configurationFileName = "lumen.conf"
    }

    @Published private(set) var menuStatus = LumenMacCaptureAdapterMenuStatus(
        hostedRuntimeRunning: false,
        captureSessionRunning: false,
        audioCaptureSessionRunning: false
    )
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastRuntimeEventMessage: String?
    @Published private(set) var isAccessibilityPermissionGranted = true
    @Published private(set) var isScreenCapturePermissionGranted = true

    private let adapter: LumenMacCaptureAdapter
    private let statusRefreshQueue = DispatchQueue(label: "LumenCaptureController.StatusRefresh", qos: .userInitiated)
    private var statusObserver: NSObjectProtocol?
    private var companionStopObserver: NSObjectProtocol?
    private var runtimeEventObserver: NSObjectProtocol?
    private var runtimeWebUIReadyObserver: NSObjectProtocol?
    private var runtimeWebDashboardBaseURLString: String?
    private var shouldOpenDashboardWhenReady = false
    private var isShuttingDown = false
    private var isStatusRefreshInFlight = false
    private var hasPendingStatusRefresh = false

    init(adapter: LumenMacCaptureAdapter = LumenMacCaptureAdapter()) {
        self.adapter = adapter
        statusObserver = NotificationCenter.default.addObserver(
            forName: .lumenMacCaptureAdapterStatusDidChange,
            object: adapter,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
        companionStopObserver = NotificationCenter.default.addObserver(
            forName: .lumenMacCaptureAdapterCompanionDidStop,
            object: adapter,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else {
                    return
                }

                self.lastErrorMessage = "Lumen web runtime stopped."
                NSApp.terminate(nil)
            }
        }
        runtimeEventObserver = NotificationCenter.default.addObserver(
            forName: .lumenRuntimeEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRuntimeEvent(notification)
            }
        }
        runtimeWebUIReadyObserver = NotificationCenter.default.addObserver(
            forName: .lumenRuntimeWebUIReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRuntimeWebUIReady(notification)
            }
        }
        do {
            shouldOpenDashboardWhenReady = true
            try adapter.startRuntimeCompanion()
        } catch {
            self.lastErrorMessage = error.localizedDescription
        }
        refreshPermissionStatus()
        refreshStatus()
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
        if let runtimeWebUIReadyObserver {
            NotificationCenter.default.removeObserver(runtimeWebUIReadyObserver)
        }
        isShuttingDown = true
        adapter.stopRuntimeCompanion()
    }

    var menuBarImageName: String {
        if menuStatus.captureSessionRunning {
            return "lumen-playing-16"
        }

        if menuStatus.hostedRuntimeRunning {
            return "lumen-pausing-16"
        }

        return "lumen-locked-16"
    }

    var menuBarImage: NSImage {
        if let image = loadMenuBarImage(named: menuBarImageName) {
            return image
        }

        if let fallbackImage = makeFallbackMenuBarImage() {
            return fallbackImage
        }

        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    func refreshStatus() {
        refreshPermissionStatus()

        guard !isStatusRefreshInFlight else {
            hasPendingStatusRefresh = true
            return
        }

        isStatusRefreshInFlight = true
        let adapter = self.adapter
        statusRefreshQueue.async { [weak self] in
            let menuStatus = adapter.copyMenuStatusSnapshot()

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.menuStatus = menuStatus
                self.isStatusRefreshInFlight = false

                guard self.hasPendingStatusRefresh else {
                    return
                }

                self.hasPendingStatusRefresh = false
                self.refreshStatus()
            }
        }
    }

    private func loadMenuBarImage(named name: String) -> NSImage? {
        for resourceName in [name, "logo-lumen-16"] {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else {
                continue
            }

            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }

        return nil
    }

    private func makeFallbackMenuBarImage() -> NSImage? {
        let symbolName: String
        if menuStatus.captureSessionRunning {
            symbolName = "dot.radiowaves.left.and.right"
        } else if menuStatus.hostedRuntimeRunning {
            symbolName = "pause.circle"
        } else {
            symbolName = "lock.circle"
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Lumen")?
            .withSymbolConfiguration(configuration) else {
            return nil
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    var openWebTitle: String {
        "Open Lumen"
    }

    var streamControlTitle: String {
        menuStatus.captureSessionRunning || menuStatus.audioCaptureSessionRunning ? "Force Stop Stream" : "Reload Apps"
    }

    var canRestartRuntime: Bool {
        true
    }

    var shouldShowScreenCapturePermissionButton: Bool {
        !isScreenCapturePermissionGranted
    }

    var shouldShowAccessibilityPermissionButton: Bool {
        !isAccessibilityPermissionGranted
    }

    func openWebDashboard(path: String = "/") {
        guard var components = URLComponents(string: webDashboardBaseURLString) else {
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

    func restartRuntimeCompanion() {
        lastErrorMessage = nil
        runtimeWebDashboardBaseURLString = nil
        shouldOpenDashboardWhenReady = true
        do {
            try adapter.restartRuntimeCompanion()
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

    func refreshPermissionStatus() {
        isAccessibilityPermissionGranted = adapter.isAccessibilityPermissionGranted
        isScreenCapturePermissionGranted = adapter.isScreenCapturePermissionGranted
    }

    func requestAccessibilityPermission() {
        adapter.requestAccessibilityPermission()
        refreshPermissionStatus()
    }

    func requestScreenCapturePermission() {
        adapter.requestScreenCapturePermission()
        refreshPermissionStatus()
    }

    func prepareForTermination() {
        isShuttingDown = true
        adapter.stopRuntimeCompanion()
    }

    private func handleRuntimeEvent(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            return
        }

        let identifier = userInfo["identifier"] as? String ?? UUID().uuidString
        let title = userInfo["title"] as? String ?? "Lumen"
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
        content.userInfo = ["lumenLaunchPath": launchPath]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func handleRuntimeWebUIReady(_ notification: Notification) {
        if let baseURLString = notification.userInfo?["url"] as? String, !baseURLString.isEmpty {
            runtimeWebDashboardBaseURLString = baseURLString
        } else {
            runtimeWebDashboardBaseURLString = nil
        }

        objectWillChange.send()

        guard shouldOpenDashboardWhenReady else {
            return
        }

        shouldOpenDashboardWhenReady = false
        openWebDashboard()
    }

    private var webDashboardPort: Int {
        resolvedLumenBasePort() + WebDashboardConfiguration.httpsPortOffset
    }

    private var webDashboardBaseURLString: String {
        runtimeWebDashboardBaseURLString ?? "https://localhost:\(webDashboardPort)"
    }

    private func resolvedLumenBasePort() -> Int {
        guard let configurationURL = apolloConfigurationURL,
              let configurationContents = try? String(contentsOf: configurationURL, encoding: .utf8),
              let configuredPort = configuredLumenBasePort(from: configurationContents) else {
            return WebDashboardConfiguration.defaultBasePort
        }

        return configuredPort
    }

    private var apolloConfigurationURL: URL? {
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return applicationSupportDirectory
            .appendingPathComponent(WebDashboardConfiguration.configurationDirectoryName, isDirectory: true)
            .appendingPathComponent(WebDashboardConfiguration.configurationFileName, isDirectory: false)
    }

    private func configuredLumenBasePort(from configurationContents: String) -> Int? {
        for rawLine in configurationContents.split(whereSeparator: \.isNewline) {
            let lineWithoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !lineWithoutComment.isEmpty else {
                continue
            }

            let keyValue = lineWithoutComment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2 else {
                continue
            }

            let key = keyValue[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "port" else {
                continue
            }

            let value = keyValue[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(value) {
                return port
            }
        }

        return nil
    }
}
