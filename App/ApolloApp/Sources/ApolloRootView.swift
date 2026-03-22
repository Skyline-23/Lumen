import ApolloMacCaptureAdapter
import SwiftUI

struct ApolloRootView: View {
    @StateObject private var captureController = ApolloCaptureController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apollo Tuist Bootstrap")
                .font(.title2.weight(.semibold))

            if let status = captureController.status {
                LabeledContent("Core") {
                    Text(status.coreVersion)
                }
                LabeledContent("Bridge") {
                    Text(status.runtimeDescription)
                }
                LabeledContent("Capture Path") {
                    Text("MacDisplayKit")
                }
                LabeledContent("Capture Session") {
                    Text(status.captureSessionRunning ? "Running" : "Stopped")
                }
                LabeledContent("Forwarding Pump") {
                    Text(status.forwardingPumpRunning ? "Running" : "Stopped")
                }
                LabeledContent("Frame Callbacks") {
                    Text("\(status.forwardedFrameCallbackCount)")
                }
                LabeledContent("Event Callbacks") {
                    Text("\(status.forwardedEventCallbackCount)")
                }
                LabeledContent("Queued Frames") {
                    Text("\(status.coreForwardingSnapshot.queued_frame_count)")
                }
                LabeledContent("Dropped Frames") {
                    Text("\(status.coreForwardingSnapshot.dropped_frame_count)")
                }
                LabeledContent("Queued Events") {
                    Text("\(status.coreForwardingSnapshot.queued_event_count)")
                }
                Text(status.integrationStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            if let lastErrorMessage = captureController.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button(captureController.status?.captureSessionRunning == true ? "Restart Capture" : "Start Capture") {
                    Task {
                        await captureController.startOrRestartCapture()
                    }
                }
                .disabled(captureController.isStarting)

                Button("Stop Capture") {
                    captureController.stopCapture()
                }
                .disabled(captureController.status?.captureSessionRunning != true && captureController.status?.forwardingPumpRunning != true)

                Button("Refresh Status") {
                    captureController.refreshStatus()
                }
            }
        }
        .frame(minWidth: 420, minHeight: 220)
        .padding(24)
        .task {
            await captureController.startIfNeeded()
        }
        .onDisappear {
            captureController.stopCapture()
        }
    }
}
