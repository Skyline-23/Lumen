import SwiftUI

struct ApolloRootView: View {
    @ObservedObject var captureController: ApolloCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            statusSection
            messagesSection
        }
        .frame(width: 320)
        .padding(16)
    }

    @ViewBuilder
    private func statusRow(title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apollo")
                .font(.title3.weight(.semibold))
            Text("Web stays primary. This menu bar app only mirrors runtime status and macOS capture state.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
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

    @ViewBuilder
    private var statusSection: some View {
        if let status = captureController.status {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                statusRow(title: "Runtime", value: status.hostedApolloRuntimeRunning ? "Active" : "Stopped")
                statusRow(title: "Video", value: status.captureSessionRunning ? "Streaming" : "Idle")
                statusRow(title: "Audio", value: status.audioCaptureSessionRunning ? "Streaming" : "Idle")
                statusRow(title: "Forwarding", value: status.forwardingPumpRunning ? "Active" : "Idle")
                statusRow(title: "Frame Callbacks", value: "\(status.forwardedFrameCallbackCount)")
                statusRow(title: "Audio Callbacks", value: "\(status.forwardedAudioFrameCallbackCount)")
                statusRow(title: "Queued Frames", value: "\(status.coreForwardingSnapshot.queued_frame_count)")
                statusRow(title: "Dropped Frames", value: "\(status.coreForwardingSnapshot.dropped_frame_count)")
            }
            .font(.footnote)

            if !status.integrationStatus.isEmpty {
                Text(status.integrationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        if captureController.lastErrorMessage != nil || captureController.lastRuntimeEventMessage != nil {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let lastErrorMessage = captureController.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lastRuntimeEventMessage = captureController.lastRuntimeEventMessage {
                    Text(lastRuntimeEventMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
