import ApolloMacCaptureAdapter
import SwiftUI

struct ApolloRootView: View {
    @State private var status: ApolloMacCaptureAdapterStatus?
    private let captureAdapter = ApolloMacCaptureAdapter()

    private func backendLabel(_ backend: ApolloMacBridgeCaptureBackend) -> String {
        switch backend.rawValue {
        case 0:
            return "Legacy Apollo"
        case 1:
            return "MacDisplayKit"
        default:
            return "Unknown (\(backend.rawValue))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apollo Tuist Bootstrap")
                .font(.title2.weight(.semibold))

            if let status {
                LabeledContent("Core") {
                    Text(status.coreVersion)
                }
                LabeledContent("Bridge") {
                    Text(status.runtimeDescription)
                }
                LabeledContent("Preferred Backend") {
                    Text(backendLabel(status.preferredCaptureBackend))
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
                Text(status.integrationStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 420, minHeight: 220)
        .padding(24)
        .task {
            status = captureAdapter.copyStatusSnapshot()
        }
    }
}
