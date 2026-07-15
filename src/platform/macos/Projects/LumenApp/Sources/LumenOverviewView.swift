import SwiftUI

struct LumenOverviewView: View {
    @ObservedObject var controller: LumenCaptureController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(LumenCopy.Navigation.overview, subtitle: LumenCopy.Overview.subtitle)

                HStack(spacing: 14) {
                    statusCard(
                        title: LumenCopy.Overview.hostRuntime,
                        value: LumenCopy.Status.runtime(isRunning: controller.menuStatus.hostRuntimeRunning),
                        icon: .hostRuntime,
                        ready: controller.menuStatus.hostRuntimeRunning
                    )
                    statusCard(
                        title: LumenCopy.Overview.currentStream,
                        value: LumenCopy.Status.stream(isRunning: controller.menuStatus.captureSessionRunning),
                        icon: .currentStream,
                        ready: controller.menuStatus.captureSessionRunning
                    )
                    statusCard(
                        title: LumenCopy.Navigation.applications,
                        value: "\(controller.applications.count)",
                        icon: .applications,
                        ready: !controller.applications.isEmpty
                    )
                }

                GroupBox(LumenCopy.Permission.systemAccess) {
                    VStack(spacing: 12) {
                        permissionRow(
                            LumenCopy.Permission.screenRecording,
                            granted: controller.isScreenCapturePermissionGranted,
                            request: controller.requestScreenCapturePermission,
                            settings: controller.openScreenRecordingSettings
                        )
                        Divider()
                        permissionRow(
                            LumenCopy.Permission.accessibility,
                            granted: controller.isAccessibilityPermissionGranted,
                            request: controller.requestAccessibilityPermission,
                            settings: controller.openAccessibilitySettings
                        )
                    }
                    .padding(6)
                }

                GroupBox(LumenCopy.Overview.hostControls) {
                    HStack {
                        Button(LumenCopy.Action.reloadApplications) {
                            controller.refreshApplications()
                        }
                        .buttonStyle(.borderedProminent)

                        if controller.hasActiveStream {
                            Button(LumenCopy.Action.forceStopStream, role: .destructive) {
                                controller.forceStopCurrentStream()
                            }
                            .buttonStyle(.bordered)
                        }

                        Spacer()
                        Button(LumenCopy.Action.restartHost) {
                            controller.restartRuntimeCompanion()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!controller.canRestartRuntime)
                    }
                    .padding(6)
                }
            }
            .padding(28)
        }
    }

    private func statusCard(
        title: String,
        value: String,
        icon: LumenAssetIcon,
        ready: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            LumenAssetIconView(icon)
                .frame(width: 24, height: 24)
                .foregroundStyle(ready ? Color.accentColor : Color.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private func permissionRow(
        _ title: String,
        granted: Bool,
        request: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        HStack {
            LumenAssetIconView(granted ? .complete : .attention)
                .frame(width: 18, height: 18)
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            if granted {
                Text(LumenCopy.Status.ready)
                    .foregroundStyle(.secondary)
            } else {
                Button(LumenCopy.Action.request, action: request)
                    .buttonStyle(.borderedProminent)
                Button(LumenCopy.Action.openSettings, action: settings)
                    .buttonStyle(.link)
            }
        }
    }
}
