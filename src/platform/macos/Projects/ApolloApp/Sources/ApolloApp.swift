import AppKit
import SwiftUI
import UserNotifications

final class ApolloAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var captureController: ApolloCaptureController?

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
        let launchPath = response.notification.request.content.userInfo["apolloLaunchPath"] as? String ?? "/"
        await MainActor.run {
            captureController?.openWebDashboard(path: launchPath)
        }
    }
}

@main
struct ApolloApp: App {
    @NSApplicationDelegateAdaptor(ApolloAppDelegate.self) private var appDelegate
    @StateObject private var captureController = ApolloCaptureController()

    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Apollo", systemImage: captureController.menuBarImageName) {
            ApolloRootView(captureController: captureController)
                .task {
                    appDelegate.captureController = captureController
                }
        }
        .menuBarExtraStyle(.menu)
    }
}
