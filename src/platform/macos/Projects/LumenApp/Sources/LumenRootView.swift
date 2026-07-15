import AppKit
import SwiftUI

enum LumenRootPresentation {
    case window
    case menuBar
}

struct LumenRootView: View {
    @ObservedObject var captureController: LumenCaptureController
    @ObservedObject var applicationPreferences: LumenApplicationPreferences
    let presentation: LumenRootPresentation
    let showMainWindow: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var ownerName = ""
    @State private var newPassword = ""
    @State private var passwordConfirmation = ""
    @State private var loginPassword = ""
    @State private var isFactoryResetPresented = false
    @State private var factoryResetConfirmation = ""
    @FocusState private var focusedAuthenticationField: LumenAuthenticationField?

    var body: some View {
        Group {
            if presentation == .window && !captureController.ownerAccessState.isAuthenticated {
                authenticationWindow
            } else {
                rootContent
                    .frame(width: presentation == .menuBar ? 320 : nil)
                    .padding(presentation == .menuBar ? 12 : 0)
            }
        }
        .frame(
            minWidth: presentation == .window ? LumenMainWindowLayout.minimumContentSize.width : nil,
            minHeight: presentation == .window ? LumenMainWindowLayout.minimumContentSize.height : nil
        )
        .background {
            if presentation == .window {
                LumenMainWindowConfigurator(
                    layout: captureController.ownerAccessState.isAuthenticated ? .management : .authentication
                )
                .frame(width: 0, height: 0)
            }
        }
        .tint(LumenAuthenticationPalette(colorScheme: colorScheme).tint)
        .accentColor(LumenAuthenticationPalette(colorScheme: colorScheme).tint)
        .onAppear {
            captureController.refreshPermissionStatus()
        }
        .onChange(of: focusedAuthenticationField) { _, field in
            preferEnglishInputSource(for: field)
        }
        .sheet(isPresented: $isFactoryResetPresented) {
            factoryResetSheet
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        Group {
            switch captureController.ownerAccessState {
            case .loading:
                loadingView
            case .setupRequired:
                ownerSetupView
            case let .loginRequired(username):
                ownerLoginView(username: username)
            case let .authenticated(username):
                dashboardView(username: username)
            case .corrupt:
                recoveryView(
                    title: LumenCopy.Recovery.damagedTitle,
                    message: LumenCopy.Recovery.damagedDetail
                )
            case .unavailable:
                recoveryView(
                    title: LumenCopy.Recovery.unavailableTitle,
                    message: LumenCopy.Recovery.unavailableDetail
                )
            }
        }
    }

    private var authenticationWindow: some View {
        let palette = LumenAuthenticationPalette(colorScheme: colorScheme)

        return HStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                palette.heroBackground

                Circle()
                    .fill(palette.amberGlow)
                    .frame(width: 330, height: 330)
                    .blur(radius: 48)
                    .offset(x: -130, y: -230)
                Circle()
                    .fill(palette.coralGlow)
                    .frame(width: 240, height: 240)
                    .blur(radius: 58)
                    .offset(x: 105, y: -210)
                Circle()
                    .fill(palette.mintGlow)
                    .frame(width: 280, height: 280)
                    .blur(radius: 66)
                    .offset(x: 125, y: 225)

                LumenBrandMark()
                    .opacity(palette.watermarkOpacity)
                    .frame(width: 390, height: 390)
                    .rotationEffect(.degrees(14))
                    .offset(x: 115, y: 155)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        LumenBrandMark()
                            .frame(width: 27, height: 27)
                        Text(LumenCopy.productNameUppercase)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .tracking(3.2)
                    }
                    .foregroundStyle(palette.primaryText)

                    Spacer()

                    Text(LumenCopy.Onboarding.headline)
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .tracking(-1)
                        .foregroundStyle(palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(LumenCopy.Onboarding.introduction)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.secondaryText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)

                    VStack(alignment: .leading, spacing: 13) {
                        authenticationFeature(LumenCopy.Onboarding.localCredentials, icon: .localCredentials)
                        authenticationFeature(LumenCopy.Onboarding.nativeHostControls, icon: .hostControls)
                        authenticationFeature(LumenCopy.Onboarding.remoteDeviceAccess, icon: .remoteAccess)
                    }
                    .padding(.top, 24)

                    Spacer()

                    Text(LumenCopy.Onboarding.credentialsNotice)
                        .font(.caption)
                        .foregroundStyle(palette.tertiaryText)
                }
                .padding(32)
            }
            .frame(width: 340)
            .clipped()

            ZStack {
                palette.formBackground
                rootContent
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 36)
            }
        }
    }

    private func authenticationFeature(_ title: String, icon: LumenAssetIcon) -> some View {
        Label {
            Text(title)
        } icon: {
            LumenAssetIconView(icon)
                .frame(width: 17, height: 17)
        }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(LumenAuthenticationPalette(colorScheme: colorScheme).secondaryText)
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(LumenCopy.Onboarding.opening)
                .font(.headline)
            Text(LumenCopy.Onboarding.openingDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
    }

    private var ownerSetupView: some View {
        VStack(alignment: .leading, spacing: 16) {
            authHeader(
                icon: .createOwner,
                title: LumenCopy.Onboarding.createOwnerTitle,
                subtitle: LumenCopy.Onboarding.createOwnerDetail
            )

            VStack(alignment: .leading, spacing: 10) {
                TextField(LumenCopy.Account.ownerName, text: $ownerName)
                    .textContentType(NSTextContentType.username)
                    .autocorrectionDisabled()
                    .focused($focusedAuthenticationField, equals: .ownerName)
                SecureField(LumenCopy.Account.passwordMinimum, text: $newPassword)
                    .textContentType(NSTextContentType.newPassword)
                    .focused($focusedAuthenticationField, equals: .newPassword)
                SecureField(LumenCopy.Account.confirmPassword, text: $passwordConfirmation)
                    .textContentType(NSTextContentType.newPassword)
                    .focused($focusedAuthenticationField, equals: .passwordConfirmation)
                    .onSubmit(createOwner)
            }
            .textFieldStyle(.roundedBorder)

            errorBanner

            Button(action: createOwner) {
                operationLabel(LumenCopy.Action.createAccount)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                captureController.isOwnerOperationInFlight ||
                    ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    newPassword.count < 12 ||
                    passwordConfirmation.isEmpty
            )

            Text(LumenCopy.Onboarding.passwordStorageNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ownerLoginView(username: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            authHeader(
                icon: .unlock,
                title: LumenCopy.Onboarding.unlockTitle,
                subtitle: LumenCopy.Onboarding.unlockDetail
            )

            completionRow(title: LumenCopy.Account.ownerAccount, detail: username, complete: true)

            SecureField(LumenCopy.Account.password, text: $loginPassword)
                .textContentType(NSTextContentType.password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedAuthenticationField, equals: .loginPassword)
                .onSubmit(loginOwner)

            errorBanner

            Button(action: loginOwner) {
                operationLabel(LumenCopy.Action.signIn)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(captureController.isOwnerOperationInFlight || loginPassword.isEmpty)

            if captureController.isSystemAuthenticationEnabled {
                Button(action: captureController.unlockOwnerWithSystemAuthentication) {
                    Text(LumenCopy.Action.unlockWithSystemAuthentication)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(
                    captureController.isOwnerOperationInFlight ||
                        !captureController.isSystemAuthenticationAvailable
                )
            }

            HStack {
                Button(LumenCopy.Action.forgotPassword) {
                    presentFactoryReset()
                }
                .buttonStyle(.link)
                Spacer()
                Button(LumenCopy.Action.quit) {
                    captureController.quitApplication()
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func dashboardView(username: String) -> some View {
        if presentation == .window {
            LumenManagementView(
                controller: captureController,
                applicationPreferences: applicationPreferences,
                username: username,
                onLock: {
                    loginPassword = ""
                    captureController.logoutOwner()
                },
                onFactoryReset: presentFactoryReset
            )
        } else {
            LumenMenuBarDashboardView(
                controller: captureController,
                username: username,
                showMainWindow: showMainWindow,
                onLock: {
                    loginPassword = ""
                    captureController.logoutOwner()
                },
                onFactoryReset: presentFactoryReset
            )
        }
    }

    private func recoveryView(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            authHeader(icon: .warning, title: title, subtitle: message)
            errorBanner
            Button(LumenCopy.Action.factoryResetLumen, role: .destructive) {
                presentFactoryReset()
            }
            .buttonStyle(.borderedProminent)
            Button(LumenCopy.Action.quit) {
                captureController.quitApplication()
            }
            .buttonStyle(.link)
        }
    }

    private func authHeader(icon: LumenAssetIcon, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            LumenAssetIconView(icon)
                .frame(width: 25, height: 25)
                .foregroundStyle(Color(red: 0.94, green: 0.42, blue: 0.12))
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = captureController.lastErrorMessage, !message.isEmpty {
            Label {
                Text(message)
            } icon: {
                LumenAssetIconView(.attention)
                    .frame(width: 14, height: 14)
            }
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func operationLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            if captureController.isOwnerOperationInFlight {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
        }
    }

    private func completionRow(title: String, detail: String, complete: Bool) -> some View {
        HStack(spacing: 8) {
            LumenAssetIconView(complete ? .complete : .attention)
                .frame(width: 17, height: 17)
                .foregroundStyle(complete ? Color.green : Color.orange)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var factoryResetSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(LumenCopy.Recovery.factoryResetTitle)
            } icon: {
                LumenAssetIconView(.warning)
                    .frame(width: 19, height: 19)
            }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text(LumenCopy.Recovery.factoryResetDetail)
                .fixedSize(horizontal: false, vertical: true)
            Text(LumenCopy.Recovery.factoryResetPrompt)
                .font(.subheadline.weight(.medium))
            TextField(LumenCopy.Recovery.factoryResetConfirmation, text: $factoryResetConfirmation)
                .textFieldStyle(.roundedBorder)
                .focused($focusedAuthenticationField, equals: .factoryResetConfirmation)
            HStack {
                Spacer()
                Button(LumenCopy.Action.cancel) {
                    isFactoryResetPresented = false
                }
                Button(LumenCopy.Action.eraseAllSettings, role: .destructive) {
                    isFactoryResetPresented = false
                    captureController.factoryReset()
                }
                .disabled(factoryResetConfirmation != LumenCopy.Recovery.factoryResetConfirmation)
            }
        }
        .frame(width: 390)
        .padding(20)
    }

    private func createOwner() {
        captureController.createOwner(
            username: ownerName,
            password: newPassword,
            confirmation: passwordConfirmation
        )
    }

    private func loginOwner() {
        captureController.loginOwner(password: loginPassword)
    }

    private func presentFactoryReset() {
        factoryResetConfirmation = ""
        isFactoryResetPresented = true
    }

    private func preferEnglishInputSource(for field: LumenAuthenticationField?) {
        guard let field else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard focusedAuthenticationField == field else {
                return
            }
            if !LumenAuthenticationInputSource.selectEnglishForCurrentField() {
                try? await Task.sleep(for: .milliseconds(50))
                guard focusedAuthenticationField == field else {
                    return
                }
                _ = LumenAuthenticationInputSource.selectEnglishForCurrentField()
            }
        }
    }
}
