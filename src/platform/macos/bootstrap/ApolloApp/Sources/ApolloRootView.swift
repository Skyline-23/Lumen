import CoreGraphics
import SwiftUI

struct ApolloRootView: View {
    @ObservedObject var captureController: ApolloCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apollo")
                .font(.title2.weight(.semibold))

            if let status = captureController.status {
                LabeledContent("Main Display") {
                    Text("\(CGMainDisplayID())")
                }
                LabeledContent("Core") {
                    Text(status.coreVersion)
                }
                LabeledContent("Bridge") {
                    Text(status.runtimeDescription)
                }
                LabeledContent("Capture Path") {
                    Text("MacDisplayKit")
                }
                LabeledContent("Codec") {
                    Text(captureController.selectedCodec.label)
                }
                LabeledContent("Queue") {
                    Text(captureController.selectedQueueProfile.label)
                }
                LabeledContent("Preprocess") {
                    Text(captureController.selectedPreprocess.label)
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

            Divider()

            Picker("Codec", selection: $captureController.selectedCodec) {
                ForEach(ApolloCaptureCodecChoice.allCases) { codec in
                    Text(codec.label).tag(codec)
                }
            }

            Picker("Queue", selection: $captureController.selectedQueueProfile) {
                ForEach(ApolloCaptureQueueProfileChoice.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }

            Picker("Preprocess", selection: $captureController.selectedPreprocess) {
                ForEach(ApolloCapturePreprocessChoice.allCases) { preprocess in
                    Text(preprocess.label).tag(preprocess)
                }
            }

            Toggle("Show Cursor", isOn: $captureController.showCursor)

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
        .frame(width: 360)
        .padding(24)
        .task {
            captureController.activateIfNeeded()
        }
    }
}
