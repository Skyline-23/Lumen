import SwiftUI

@main
struct ApolloApp: App {
    @StateObject private var captureController = ApolloCaptureController()

    var body: some Scene {
        MenuBarExtra("Apollo", systemImage: captureController.menuBarImageName) {
            ApolloRootView(captureController: captureController)
        }
        .menuBarExtraStyle(.window)
    }
}
