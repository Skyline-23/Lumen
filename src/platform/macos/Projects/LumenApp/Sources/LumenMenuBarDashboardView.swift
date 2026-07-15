import LumenMacBridge
import SwiftUI

struct LumenMenuBarDashboardView: View {
    @ObservedObject var controller: LumenCaptureController
    let username: String
    let showMainWindow: (() -> Void)?
    let onLock: () -> Void
    let onFactoryReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            errorBanner
            if let warning = controller.runtimeWarnings.first {
                LumenRuntimeWarningBanner(warning: warning)
            }
            systemStatus
            Divider()
            workspacePolicyControl
            Divider()
            controls
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LumenBrandMark()
                .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 1) {
                Text(LumenCopy.productName)
                    .font(.headline)
                Text(username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            runtimeStatus
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var runtimeStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(controller.menuStatus.hostRuntimeRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(LumenCopy.Status.runtime(isRunning: controller.menuStatus.hostRuntimeRunning))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var systemStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel(LumenCopy.Permission.systemAccess)
            permissionRow(
                title: LumenCopy.Permission.screenRecording,
                granted: controller.isScreenCapturePermissionGranted,
                request: controller.requestScreenCapturePermission,
                openSettings: controller.openScreenRecordingSettings
            )
            permissionRow(
                title: LumenCopy.Permission.accessibility,
                granted: controller.isAccessibilityPermissionGranted,
                request: controller.requestAccessibilityPermission,
                openSettings: controller.openAccessibilitySettings
            )
        }
        .padding(.horizontal, 4)
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            LumenAssetIconView(granted ? .complete : .attention)
                .frame(width: 15, height: 15)
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
                .font(.subheadline)
            Spacer()
            if granted {
                Text(LumenCopy.Status.ready)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button(LumenCopy.Action.request, action: request)
                    .buttonStyle(.link)
                Button(LumenCopy.Action.settings, action: openSettings)
                    .buttonStyle(.link)
            }
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = controller.lastErrorMessage, !message.isEmpty {
            Label {
                Text(message)
            } icon: {
                LumenAssetIconView(.attention)
                    .frame(width: 14, height: 14)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var workspacePolicyControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LumenAssetIconView(.workspace)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(.secondary)
                Text(LumenCopy.Workspace.label)
                    .font(.subheadline)
                Spacer()
                if controller.isHostSettingsOperationInFlight {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Picker(
                LumenCopy.Workspace.label,
                selection: Binding(
                    get: { controller.workspacePolicy },
                    set: { policy in
                        controller.setWorkspacePolicy(policy)
                    }
                )
            ) {
                ForEach(LumenMacWorkspacePolicy.allCases, id: \.self) { policy in
                    Text(LumenCopy.Workspace.title(for: policy)).tag(policy)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(controller.isHostSettingsOperationInFlight)
            Text(LumenCopy.Workspace.description(for: controller.workspacePolicy))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 23)
        }
        .padding(.horizontal, 4)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let showMainWindow {
                menuButton(LumenCopy.Action.showWindow, icon: .showWindow, action: showMainWindow)
            }
            if controller.hasActiveStream {
                menuButton(LumenCopy.Action.forceStopStream, icon: .stopStream) {
                    controller.forceStopCurrentStream()
                }
            }

            menuDivider

            menuButton(LumenCopy.Action.reloadApplications, icon: .applications) {
                controller.refreshApplications()
            }
            menuButton(LumenCopy.Action.restartLumen, icon: .restart) {
                controller.restartApplication()
            }
            .disabled(!controller.canRestartApplication)

            menuDivider

            menuButton(LumenCopy.Action.lockSettings, icon: .locked, action: onLock)
            menuButton(LumenCopy.Action.factoryReset, icon: .factoryReset, action: onFactoryReset)
            menuButton(LumenCopy.Action.quitLumen, icon: .quit) {
                controller.quitApplication()
            }
        }
    }

    private var menuDivider: some View {
        Divider()
            .padding(.vertical, 3)
            .padding(.leading, 31)
    }

    private func menuButton(
        _ title: String,
        icon: LumenAssetIcon,
        action: @escaping () -> Void
    ) -> some View {
        LumenMenuActionButton(title: title, icon: icon, action: action)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
    }
}

private struct LumenMenuActionButton: View {
    let title: String
    let icon: LumenAssetIcon
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                LumenAssetIconView(icon)
                    .frame(width: 15, height: 15)
                Text(title)
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(foregroundStyle)
            .contentShape(Rectangle())
            .padding(.horizontal, 7)
            .frame(height: 27)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    private var foregroundStyle: Color {
        guard isEnabled else {
            return .secondary.opacity(0.55)
        }
        return isHovering ? .white : .primary
    }

    private var backgroundStyle: Color {
        isEnabled && isHovering ? .accentColor : .clear
    }
}
