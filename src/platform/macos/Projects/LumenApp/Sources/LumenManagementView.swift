import LumenMacBridge
import SwiftUI

private enum LumenManagementSection: Hashable, Identifiable {
    case overview
    case applications
    case diagnostics
    case settings(LumenSettingsCategory)

    var id: String {
        switch self {
        case .overview: "overview"
        case .applications: "applications"
        case .diagnostics: "diagnostics"
        case let .settings(category): "settings.\(category.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .overview: LumenCopy.Navigation.overview
        case .applications: LumenCopy.Navigation.applications
        case .diagnostics: LumenCopy.Navigation.diagnostics
        case let .settings(category): category.title
        }
    }

    var icon: LumenAssetIcon {
        switch self {
        case .overview: .overview
        case .applications: .applications
        case .diagnostics: .diagnostics
        case let .settings(category): category.icon
        }
    }
}

struct LumenManagementView: View {
    @ObservedObject var controller: LumenCaptureController
    @ObservedObject var applicationPreferences: LumenApplicationPreferences
    let username: String
    let onLock: () -> Void
    let onFactoryReset: () -> Void
    @State private var selection = LumenManagementSection.overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    managementSidebarRow(.overview)
                    managementSidebarRow(.applications)
                }
                Section(LumenCopy.Navigation.settings) {
                    ForEach(LumenSettingsCategory.allCases) { category in
                        managementSidebarRow(.settings(category))
                    }
                }
                Section {
                    managementSidebarRow(.diagnostics)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LumenCopy.Account.signedInAs)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(username)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            Group {
                switch selection {
                case .overview:
                    LumenOverviewView(controller: controller)
                case .applications:
                    LumenApplicationsView(controller: controller)
                case let .settings(category):
                    LumenSettingsView(
                        controller: controller,
                        applicationPreferences: applicationPreferences,
                        category: category,
                        onLock: onLock,
                        onFactoryReset: onFactoryReset
                    )
                case .diagnostics:
                    LumenDiagnosticsView(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func managementSidebarRow(_ section: LumenManagementSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            LumenAssetIconView(section.icon)
                .frame(width: 17, height: 17)
        }
        .tag(section)
    }
}
func pageHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.largeTitle.weight(.semibold))
        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
    }
}
