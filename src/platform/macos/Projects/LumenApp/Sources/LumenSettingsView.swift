import LumenMacBridge
import SwiftUI

enum LumenSettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case security
    case general
    case streaming
    case audio
    case input
    case network
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .security: LumenCopy.Settings.security
        case .general: LumenCopy.Settings.general
        case .streaming: LumenCopy.Settings.streaming
        case .audio: LumenCopy.Settings.audio
        case .input: LumenCopy.Settings.input
        case .network: LumenCopy.Settings.network
        case .advanced: LumenCopy.Settings.advanced
        }
    }

    var subtitle: String {
        switch self {
        case .security: LumenCopy.Settings.securitySubtitle
        case .general: LumenCopy.Settings.generalSubtitle
        case .streaming: LumenCopy.Settings.streamingSubtitle
        case .audio: LumenCopy.Settings.audioSubtitle
        case .input: LumenCopy.Settings.inputSubtitle
        case .network: LumenCopy.Settings.networkSubtitle
        case .advanced: LumenCopy.Settings.advancedSubtitle
        }
    }

    var icon: LumenAssetIcon {
        switch self {
        case .security: .unlock
        case .general: .settings
        case .streaming: .currentStream
        case .audio: .hostControls
        case .input: .remoteAccess
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

                Divider()
                HStack {
                    Text(LumenCopy.Settings.autosaveNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.isHostSettingsOperationInFlight {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.regularMaterial)
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
        case .streaming:
            streamingSettings
        case .audio:
            audioSettings
        case .input:
            inputSettings
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
                TextField(LumenCopy.Settings.hostName, text: $draft.hostName)
                Picker(LumenCopy.Settings.locale, selection: $draft.locale) {
                    ForEach(LumenCopy.Settings.locales, id: \.code) { locale in
                        Text(locale.title).tag(locale.code)
                    }
                }
                Toggle(LumenCopy.Settings.discovery, isOn: $draft.discoveryEnabled)
                Toggle(
                    LumenCopy.Settings.deviceEnrollment,
                    isOn: $draft.deviceEnrollmentEnabled
                )
                Toggle(LumenCopy.Settings.notifyPreReleases, isOn: $draft.notifyPreReleases)
            }
            Section(LumenCopy.Settings.logging) {
                Picker(LumenCopy.Settings.logLevel, selection: $draft.logLevel) {
                    ForEach(LumenLogLevel.allCases, id: \.self) { level in
                        Text(LumenCopy.Settings.logLevelTitle(level)).tag(level)
                    }
                }
            }
        }
    }

    private var streamingSettings: some View {
        Group {
            Section(LumenCopy.Settings.display) {
                TextField(
                    LumenCopy.Settings.adapterName,
                    text: $draft.adapterName,
                    prompt: Text(LumenCopy.Settings.automatic)
                )
                TextField(
                    LumenCopy.Settings.outputName,
                    text: $draft.outputName,
                    prompt: Text(LumenCopy.Settings.automatic)
                )
                Picker(LumenCopy.Settings.fallbackDisplayMode, selection: $draft.fallbackDisplayMode) {
                    ForEach(displayModeOptions, id: \.self) { mode in
                        Text(LumenCopy.Settings.displayModeTitle(mode)).tag(mode)
                    }
                }
                Picker(LumenCopy.Workspace.label, selection: $draft.workspacePolicy) {
                    ForEach(LumenMacWorkspacePolicy.allCases, id: \.self) { policy in
                        Text(LumenCopy.Workspace.title(for: policy)).tag(policy)
                    }
                }
            }
        }
    }

    private var audioSettings: some View {
        Section(LumenCopy.Settings.audio) {
            Toggle(LumenCopy.Settings.streamAudio, isOn: $draft.streamAudio)
            TextField(
                LumenCopy.Settings.audioSink,
                text: $draft.audioSink,
                prompt: Text(LumenCopy.Settings.automatic)
            )
            Text(LumenCopy.Settings.audioSinkDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inputSettings: some View {
        Group {
            Section(LumenCopy.Settings.controller) {
                Toggle(LumenCopy.Settings.controllerInput, isOn: $draft.controllerInput)
                integerMenu(
                    LumenCopy.Settings.controllerBackButtonTimeout,
                    value: $draft.controllerBackButtonTimeoutMilliseconds,
                    options: LumenCopy.Settings.controllerTimeoutOptions,
                    title: LumenCopy.Settings.controllerTimeoutTitle
                )
                Toggle(LumenCopy.Settings.rumbleForwarding, isOn: $draft.rumbleForwarding)
            }
            Section(LumenCopy.Settings.keyboard) {
                Toggle(LumenCopy.Settings.keyboardInput, isOn: $draft.keyboardInput)
                Toggle(LumenCopy.Settings.mapRightAltToWindowsKey, isOn: $draft.mapRightAltToWindowsKey)
            }
            Section(LumenCopy.Settings.pointer) {
                Toggle(LumenCopy.Settings.mouseInput, isOn: $draft.mouseInput)
                Toggle(LumenCopy.Settings.highResolutionScrolling, isOn: $draft.highResolutionScrolling)
                Toggle(LumenCopy.Settings.nativePenAndTouch, isOn: $draft.nativePenAndTouch)
            }
        }
    }

    private var networkSettings: some View {
        Group {
            Section(LumenCopy.Settings.network) {
                Toggle(LumenCopy.Settings.upnp, isOn: $draft.upnpEnabled)
                Picker(LumenCopy.Settings.addressFamily, selection: $draft.addressFamily) {
                    ForEach(LumenNetworkAddressFamily.allCases, id: \.self) { family in
                        Text(LumenCopy.Settings.addressFamilyTitle(family)).tag(family)
                    }
                }
                numberField(LumenCopy.Settings.port, value: $draft.port)
                TextField(LumenCopy.Settings.externalIP, text: $draft.externalIP)
            }
            Section(LumenCopy.Settings.encryption) {
                Picker(LumenCopy.Settings.lanEncryption, selection: $draft.lanEncryption) {
                    ForEach(LumenEncryptionMode.allCases, id: \.self) { mode in
                        Text(LumenCopy.Settings.encryptionTitle(mode)).tag(mode)
                    }
                }
                Picker(LumenCopy.Settings.wanEncryption, selection: $draft.wanEncryption) {
                    ForEach(LumenEncryptionMode.allCases, id: \.self) { mode in
                        Text(LumenCopy.Settings.encryptionTitle(mode)).tag(mode)
                    }
                }
                integerMenu(
                    LumenCopy.Settings.pingTimeout,
                    value: $draft.pingTimeoutMilliseconds,
                    options: LumenCopy.Settings.connectionTimeoutOptions,
                    title: LumenCopy.Settings.millisecondsTitle
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

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 150)
        }
    }

    private func numberStepper(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(value.wrappedValue.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
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

    private var displayModeOptions: [String] {
        if LumenCopy.Settings.displayModeOptions.contains(draft.fallbackDisplayMode) {
            return LumenCopy.Settings.displayModeOptions
        }
        return [draft.fallbackDisplayMode] + LumenCopy.Settings.displayModeOptions
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
              !settings.hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
