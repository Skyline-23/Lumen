import SwiftUI

struct LumenRootView: View {
    @ObservedObject var captureController: LumenCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
        }
        .frame(width: 320)
        .padding(16)
        .onAppear {
            captureController.refreshPermissionStatus()
        }
    }

    private var header: some View {
        Text("Lumen")
            .font(.title3.weight(.semibold))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if captureController.shouldShowAccessibilityPermissionButton {
                Button("Request Accessibility Permission") {
                    captureController.requestAccessibilityPermission()
                }
            }

            if captureController.shouldShowScreenCapturePermissionButton {
                Button("Request Screen Recording Permission") {
                    captureController.requestScreenCapturePermission()
                }
            }

            Button(captureController.openWebTitle) {
                captureController.openWebDashboard()
            }

            Button(captureController.streamControlTitle) {
                captureController.forceStopCurrentStream()
            }

            Button("Restart Lumen") {
                captureController.restartRuntimeCompanion()
            }
            .disabled(!captureController.canRestartRuntime)

            Button("Quit Lumen") {
                captureController.quitApplication()
            }
        }
        .buttonStyle(.borderless)
    }
}
