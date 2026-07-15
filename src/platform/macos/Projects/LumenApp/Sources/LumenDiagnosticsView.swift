import SwiftUI

struct LumenDiagnosticsView: View {
    @ObservedObject var controller: LumenCaptureController

    var body: some View {
        Form {
            Section {
                diagnosticRow(
                    LumenCopy.Overview.hostRuntime,
                    LumenCopy.Status.runtime(isRunning: controller.menuStatus.hostRuntimeRunning)
                )
                diagnosticRow(
                    LumenCopy.Diagnostics.videoCapture,
                    LumenCopy.Status.stream(isRunning: controller.menuStatus.captureSessionRunning)
                )
                diagnosticRow(
                    LumenCopy.Diagnostics.audioCapture,
                    LumenCopy.Status.stream(isRunning: controller.menuStatus.audioCaptureSessionRunning)
                )
                diagnosticRow(LumenCopy.Diagnostics.applicationRecords, "\(controller.applications.count)")
            } header: {
                pageHeader(LumenCopy.Navigation.diagnostics, subtitle: LumenCopy.Diagnostics.subtitle)
            }
            if !controller.runtimeWarnings.isEmpty {
                Section(LumenCopy.Diagnostics.runtimeWarnings) {
                    ForEach(controller.runtimeWarnings) { warning in
                        LumenRuntimeWarningBanner(warning: warning)
                    }
                }
            }
            if let event = controller.lastRuntimeEventMessage, !event.isEmpty {
                Section(LumenCopy.Diagnostics.lastRuntimeEvent) {
                    Text(event).textSelection(.enabled)
                }
            }
            if let error = controller.lastErrorMessage, !error.isEmpty {
                Section(LumenCopy.Diagnostics.lastError) {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}
