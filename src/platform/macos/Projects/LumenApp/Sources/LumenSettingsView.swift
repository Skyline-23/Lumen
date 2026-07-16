import LumenAppArchitecture
import LumenMacBridge
import SwiftUI

enum LumenSettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case security
    case general
    case network
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .security: LumenCopy.Settings.security
        case .general: LumenCopy.Settings.general
        case .network: LumenCopy.Settings.network
        case .advanced: LumenCopy.Settings.advanced
        }
    }

    var subtitle: String {
        switch self {
        case .security: LumenCopy.Settings.securitySubtitle
        case .general: LumenCopy.Settings.generalSubtitle
        case .network: LumenCopy.Settings.networkSubtitle
        case .advanced: LumenCopy.Settings.advancedSubtitle
        }
    }

    var icon: LumenAssetIcon {
        switch self {
        case .security: .unlock
        case .general: .settings
        case .network: .workspace
        case .advanced: .restart
        }
    }
}

struct LumenSettingsView: View {
    @ObservedObject var controller: LumenCaptureController
    @ObservedObject var applicationPreferences: LumenApplicationPreferences
    let category: LumenSettingsCategory
    let onLock: () -> Void
    let onFactoryReset: () -> Void
    @State private var draft = LumenNativeHostSettings.defaults
    @State private var persistedSettings = LumenNativeHostSettings.defaults
    @State private var pendingSaveTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.77, blue: 0.28).opacity(0.10),
                    Color.clear
                ],
                startPoint: .topTrailing,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    LumenAssetIconView(category.icon)
                        .frame(width: 26, height: 26)
                        .foregroundStyle(Color(red: 0.84, green: 0.52, blue: 0.06))
                        .padding(10)
                        .background(
                            Color(red: 1.0, green: 0.75, blue: 0.24).opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    pageHeader(category.title, subtitle: category.subtitle)
                    Spacer()
                    if controller.isHostSettingsOperationInFlight {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)

                Divider()

                Form {
                    settingsContent
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .pickerStyle(.menu)
                .frame(maxWidth: 820, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            draft = controller.hostSettings
            persistedSettings = controller.hostSettings
        }
        .onChange(of: controller.hostSettings) { _, settings in
            if draft == persistedSettings {
                draft = settings
            } else {
                draft.systemAuthenticationEnabled = settings.systemAuthenticationEnabled
            }
            persistedSettings = settings
        }
        .onChange(of: draft) { _, settings in
            scheduleSave(settings)
        }
        .onDisappear {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch category {
        case .security:
            securitySettings
        case .general:
            generalSettings
        case .network:
            networkSettings
        case .advanced:
            advancedSettings
        }
    }

    private var securitySettings: some View {
        Section(LumenCopy.Settings.security) {
            Toggle(
                LumenCopy.Settings.systemAuthentication,
                isOn: Binding(
                    get: { controller.isSystemAuthenticationEnabled },
                    set: { isEnabled in
                        controller.setSystemAuthenticationEnabled(isEnabled)
                    }
                )
            )
            .disabled(
                !controller.isSystemAuthenticationAvailable ||
                    controller.isHostSettingsOperationInFlight
            )
            Text(LumenCopy.Settings.systemAuthenticationDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(LumenCopy.Action.lockSettings, action: onLock)
            Button(LumenCopy.Action.factoryResetLumen, role: .destructive, action: onFactoryReset)
        }
    }

    private var generalSettings: some View {
        Group {
            Section(LumenCopy.Settings.application) {
                Toggle(
                    LumenCopy.Settings.hideDockIconWhenMainWindowCloses,
                    isOn: Binding(
                        get: { applicationPreferences.hidesDockIconWhenMainWindowCloses },
                        set: { isEnabled in
                            applicationPreferences.setHidesDockIconWhenMainWindowCloses(isEnabled)
                        }
                    )
                )
                Text(LumenCopy.Settings.hideDockIconWhenMainWindowClosesDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(LumenCopy.Settings.host) {
                TextField(LumenCopy.Settings.name, text: $draft.name)
                Toggle(LumenCopy.Settings.discovery, isOn: $draft.discoveryEnabled)
                Toggle(
                    LumenCopy.Settings.deviceEnrollment,
                    isOn: $draft.deviceEnrollmentEnabled
                )
            }
        }
    }

    private var networkSettings: some View {
        Group {
            Section(LumenCopy.Settings.network) {
                Toggle(LumenCopy.Settings.upnp, isOn: $draft.upnpEnabled)
                Text(LumenCopy.Settings.upnpMappingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(LumenCopy.Settings.addressFamily, selection: $draft.addressFamily) {
                    ForEach(LumenNetworkAddressFamily.allCases, id: \.self) { family in
                        Text(LumenCopy.Settings.addressFamilyTitle(family)).tag(family)
                    }
                }
                basePortField(value: $draft.port)
                Text(LumenCopy.Settings.portPlanDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                networkPortRow(
                    LumenCopy.Settings.controlHTTPSPort,
                    port: networkPortPlan.controlHTTPSPort,
                    transport: "TCP",
                    exposure: upnpExposure
                )
                networkPortRow(
                    LumenCopy.Settings.nativeMediaPort,
                    port: networkPortPlan.nativeMediaUDPPort,
                    transport: "UDP",
                    exposure: upnpExposure
                )
                networkPortRow(
                    LumenCopy.Settings.nativeSessionQUICPort,
                    port: networkPortPlan.nativeSessionQUICPort,
                    transport: "UDP",
                    exposure: upnpExposure
                )
                integerMenu(
                    LumenCopy.Settings.fecPercentage,
                    value: $draft.fecPercentage,
                    options: LumenCopy.Settings.fecOptions,
                    title: LumenCopy.Settings.percentageTitle
                )
            }
        }
    }

    private var advancedSettings: some View {
        Group {
            commandSection(
                LumenCopy.Settings.preparationCommands,
                commands: $draft.globalPrepCommands
            )
            commandSection(
                LumenCopy.Settings.stateCommands,
                commands: $draft.globalStateCommands
            )
            Section(LumenCopy.Settings.serverCommands) {
                ForEach(draft.serverCommands.indices, id: \.self) { index in
                    HStack {
                        TextField(LumenCopy.Settings.commandName, text: $draft.serverCommands[index].name)
                        TextField(LumenCopy.Settings.command, text: $draft.serverCommands[index].command)
                        Button(role: .destructive) {
                            draft.serverCommands.remove(at: index)
                        } label: {
                            LumenAssetIconView(.delete).frame(width: 15, height: 15)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button(LumenCopy.Action.add) {
                    draft.serverCommands.append(LumenServerCommand())
                }
            }
        }
    }

    private var networkPortPlan: LumenNetworkPortPlan {
        draft.networkPortPlan
    }

    private var upnpExposure: String {
        draft.upnpEnabled
            ? LumenCopy.Settings.mappedByUPnP
            : LumenCopy.Settings.notMappedByUPnP
    }

    private func basePortField(value: Binding<Int>) -> some View {
        LabeledContent(LumenCopy.Settings.port) {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 2) {
                    TextField(
                        LumenCopy.Settings.port,
                        value: value,
                        format: .number,
                        prompt: Text(String(LumenNetworkPortPlan.defaultBasePort))
                    )
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 100)
                    Text(
                        LumenCopy.Settings.defaultPort(
                            LumenNetworkPortPlan.defaultBasePort
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Button(LumenCopy.Settings.useDefaultPort) {
                    value.wrappedValue = LumenNetworkPortPlan.defaultBasePort
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func networkPortRow(
        _ title: String,
        port: Int,
        transport: String,
        exposure: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text("\(port)")
                    .monospacedDigit()
                Text(transport)
                Text("·")
                Text(exposure)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func integerMenu(
        _ label: String,
        value: Binding<Int>,
        options: [Int],
        title: @escaping (Int) -> String
    ) -> some View {
        Picker(label, selection: value) {
            ForEach(integerMenuOptions(current: value.wrappedValue, options: options), id: \.self) { option in
                Text(title(option)).tag(option)
            }
        }
    }

    private func integerMenuOptions(current: Int, options: [Int]) -> [Int] {
        options.contains(current) ? options : [current] + options
    }

    private func commandSection(
        _ title: String,
        commands: Binding<[LumenPrepCommand]>
    ) -> some View {
        Section(title) {
            ForEach(commands.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(LumenCopy.Settings.command, text: commands[index].run)
                    TextField(LumenCopy.Settings.undoCommand, text: commands[index].undo)
                    Button(role: .destructive) {
                        commands.wrappedValue.remove(at: index)
                    } label: {
                        LumenAssetIconView(.delete).frame(width: 15, height: 15)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(LumenCopy.Action.add) {
                commands.wrappedValue.append(LumenPrepCommand())
            }
        }
    }

    private func scheduleSave(_ settings: LumenNativeHostSettings) {
        pendingSaveTask?.cancel()
        guard settings != persistedSettings,
              !settings.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else {
                return
            }
            controller.saveHostSettings(settings)
        }
    }
}
