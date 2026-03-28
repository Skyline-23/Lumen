import AppKit
import SwiftUI
import UserNotifications

final class LumenAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var captureController: LumenCaptureController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        captureController?.prepareForTermination()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        _ = center
        _ = notification
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        _ = center
        let launchPath = response.notification.request.content.userInfo["lumenLaunchPath"] as? String ?? "/"
        await MainActor.run {
            captureController?.openWebDashboard(path: launchPath)
        }
    }
}

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
    @StateObject private var captureController = LumenCaptureController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            LumenRootView(captureController: captureController)
                .task {
                    appDelegate.captureController = captureController
                }
        } label: {
            Image(nsImage: captureController.menuBarImage)
                .renderingMode(.template)
                .frame(width: 18, height: 18)
                .help("Lumen")
        }
        .menuBarExtraStyle(.menu)
    }
}
