import SwiftUI

struct ApolloRootView: View {
    @ObservedObject var captureController: ApolloCaptureController

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
        Text("Apollo")
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

            Button("Restart Apollo") {
                captureController.restartApolloCompanion()
            }
            .disabled(!captureController.canRestartApollo)

            Button("Quit Apollo") {
                captureController.quitApplication()
            }
        }
        .buttonStyle(.borderless)
    }
}
