import AppKit
import SwiftUI
import UserNotifications

enum LumenMainWindowLayout: Equatable {
    case authentication
    case management

    static let minimumContentSize = NSSize(width: 820, height: 500)
    static let defaultContentSize = NSSize(width: 960, height: 620)

    var preferredContentSize: NSSize {
        switch self {
        case .authentication:
            NSSize(width: 900, height: 560)
        case .management:
            Self.defaultContentSize
        }
    }
}

struct LumenMainWindowConfigurator: NSViewRepresentable {
    let layout: LumenMainWindowLayout

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(coordinator: context.coordinator, layout: layout)
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        view.update(coordinator: context.coordinator, layout: layout)
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var layout: LumenMainWindowLayout?

        func apply(_ layout: LumenMainWindowLayout, to window: NSWindow) {
            window.contentMinSize = LumenMainWindowLayout.minimumContentSize
            let windowChanged = self.window !== window
            guard windowChanged || self.layout != layout else {
                return
            }

            let currentSize = window.contentLayoutRect.size
            let preferredSize = layout.preferredContentSize
            let isExcessivelyLarge = currentSize.height > preferredSize.height * 1.25
            let isBelowMinimum = currentSize.width < LumenMainWindowLayout.minimumContentSize.width ||
                currentSize.height < LumenMainWindowLayout.minimumContentSize.height
            if windowChanged && (isExcessivelyLarge || isBelowMinimum) {
                window.setContentSize(preferredSize)
            } else if !windowChanged && self.layout != layout {
                window.setContentSize(preferredSize)
            }

            self.window = window
            self.layout = layout
        }
    }

    @MainActor
    final class WindowProbe: NSView {
        private weak var coordinator: Coordinator?
        private var layout: LumenMainWindowLayout

        init(coordinator: Coordinator, layout: LumenMainWindowLayout) {
            self.coordinator = coordinator
            self.layout = layout
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyLayoutIfPossible()
        }

        func update(coordinator: Coordinator, layout: LumenMainWindowLayout) {
            self.coordinator = coordinator
            self.layout = layout
            applyLayoutIfPossible()
        }

        private func applyLayoutIfPossible() {
            guard let coordinator, let window else {
                return
            }
            coordinator.apply(layout, to: window)
        }
    }
}

@MainActor
final class LumenAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var captureController: LumenCaptureController?
    var applicationPreferences: LumenApplicationPreferences?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        NotificationCenter.default.removeObserver(self)
        captureController?.prepareForTermination()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        captureController?.refreshPermissionStatus()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        _ = sender
        _ = flag
        showMainWindow()
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        _ = center
        _ = notification
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        _ = center
        _ = response
        await showMainWindow()
    }

    @MainActor
    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .first(where: { $0.title == LumenCopy.productName && $0.canBecomeKey })?
            .makeKeyAndOrderFront(nil)
    }

    @objc
    private func mainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.title == LumenCopy.productName,
              window.canBecomeKey,
              applicationPreferences?.hidesDockIconWhenMainWindowCloses == true else {
            return
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard self?.applicationPreferences?.hidesDockIconWhenMainWindowCloses == true,
                  !NSApp.windows.contains(where: {
                      $0.title == LumenCopy.productName && $0.canBecomeKey && $0.isVisible
                  }) else {
                return
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct LumenMenuBarContent: View {
    @ObservedObject var captureController: LumenCaptureController
    @ObservedObject var applicationPreferences: LumenApplicationPreferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LumenRootView(
            captureController: captureController,
            applicationPreferences: applicationPreferences,
            presentation: .menuBar,
            showMainWindow: showMainWindow
        )
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
    private let container: LumenAppContainer
    @StateObject private var captureController: LumenCaptureController
    @StateObject private var applicationPreferences: LumenApplicationPreferences

    init() {
        let container = LumenAppContainer.live()
        self.container = container
        _captureController = StateObject(wrappedValue: container.captureController)
        _applicationPreferences = StateObject(wrappedValue: container.applicationPreferences)
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window(LumenCopy.productName, id: "main") {
            LumenRootView(
                captureController: captureController,
                applicationPreferences: applicationPreferences,
                presentation: .window,
                showMainWindow: nil
            )
            .task {
                appDelegate.captureController = captureController
                appDelegate.applicationPreferences = applicationPreferences
            }
        }
        .defaultSize(
            width: LumenMainWindowLayout.defaultContentSize.width,
            height: LumenMainWindowLayout.defaultContentSize.height
        )
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            LumenMenuBarContent(
                captureController: captureController,
                applicationPreferences: applicationPreferences
            )
                .task {
                    appDelegate.captureController = captureController
                    appDelegate.applicationPreferences = applicationPreferences
                }
        } label: {
            Image(nsImage: captureController.menuBarImage)
                .renderingMode(.template)
                .frame(width: 18, height: 18)
                .help(LumenCopy.productName)
        }
        .menuBarExtraStyle(.window)
    }
}
