import ApolloMacBridge
import SwiftUI

struct ApolloRootView: View {
    @State private var status: ApolloBridgeStatus?

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
                    Text(status.preferredCaptureBackend.rawValue)
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
            status = await ApolloBridgeRuntime.shared.statusSnapshot()
        }
    }
}
