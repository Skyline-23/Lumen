import LumenAppArchitecture
import LumenMacCaptureAdapter
import LumenMacBridge
import AppKit
import Foundation
import LocalAuthentication
import UserNotifications

extension Notification.Name {
    static let lumenRuntimeEvent = Notification.Name("LumenRuntimeEventNotification")
}
enum LumenOwnerAccessState: Equatable {
    case loading
    case setupRequired
    case loginRequired(username: String)
    case authenticated(username: String)
    case corrupt
    case unavailable

    var isConfigured: Bool {
        switch self {
        case .loginRequired, .authenticated:
            true
        default:
            false
        }
    }

    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
}

@MainActor
final class LumenCaptureController: NSObject, ObservableObject {
    @Published private(set) var menuStatus = LumenMacCaptureAdapterMenuStatus(
        hostRuntimeRunning: false,
        captureSessionRunning: false,
        audioCaptureSessionRunning: false
    )
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastRuntimeEventMessage: String?
    @Published private(set) var runtimeWarnings: [LumenRuntimeWarning] = []
    @Published private(set) var isAccessibilityPermissionGranted = true
    @Published private(set) var isScreenCapturePermissionGranted = true
    @Published private(set) var ownerAccessState = LumenOwnerAccessState.loading
    @Published private(set) var isOwnerOperationInFlight = false
    @Published private(set) var hostSettings = LumenNativeHostSettings.defaults
    @Published private(set) var workspacePolicy = LumenMacWorkspacePolicy.coexist
    @Published private(set) var isSystemAuthenticationEnabled = false
    @Published private(set) var isHostSettingsOperationInFlight = false
    @Published private(set) var applications: [LumenApplication] = []
    @Published private(set) var isApplicationOperationInFlight = false
    @Published private(set) var isApplicationRestartInFlight = false

    private let adapter: any LumenHostRuntimeControlling
    private let applicationRelauncher: any LumenApplicationRelaunching
    private let readinessStore: LumenHostReadinessStore
    private let ownerAccountStore: (any LumenOwnerAccountServicing)?
    private let hostSettingsStore: (any LumenHostSettingsServicing)?
    private let applicationCatalogStore: (any LumenApplicationCatalogServicing)?
    private let permissionDragPanelController: LumenPermissionDragPanelController
    private var isShuttingDown = false
    private var isRestartingCompanion = false
    private var shouldIgnoreNextCompanionStop = false
    private var isStatusRefreshInFlight = false
    private var hasPendingStatusRefresh = false
    private var hasRequestedRuntimeStart = false
    private var localAuthenticationContext: LAContext?
    private var localAuthenticationRequestID: UUID?
    private var pendingHostSettings: LumenNativeHostSettings?
    private var readinessObservationTask: Task<Void, Never>?

    init(
        adapter: any LumenHostRuntimeControlling,
        applicationRelauncher: any LumenApplicationRelaunching,
        readinessStore: LumenHostReadinessStore,
        ownerAccountStore: (any LumenOwnerAccountServicing)?,
        hostSettingsStore: (any LumenHostSettingsServicing)?,
        applicationCatalogStore: (any LumenApplicationCatalogServicing)?,
        permissionDragPanelController: LumenPermissionDragPanelController
    ) {
        self.adapter = adapter
        self.applicationRelauncher = applicationRelauncher
        self.readinessStore = readinessStore
        self.ownerAccountStore = ownerAccountStore
        self.hostSettingsStore = hostSettingsStore
        self.applicationCatalogStore = applicationCatalogStore
        self.permissionDragPanelController = permissionDragPanelController
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStatusDidChange),
            name: .lumenMacCaptureAdapterStatusDidChange,
            object: adapter
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCompanionDidStop),
            name: .lumenMacCaptureAdapterCompanionDidStop,
            object: adapter
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleRuntimeEvent(_:)),
            name: .lumenRuntimeEvent,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        observeReadinessState()
        bootstrapOwnerAccess()
        bootstrapHostSettings()
        refreshApplications()
        refreshPermissionStatus()
        refreshStatus()
    }

    deinit {
        readinessObservationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    var menuBarImage: NSImage {
        if let image = makeMenuBarImage() {
            return image
        }

        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    func refreshStatus() {
        refreshPermissionStatus()

        guard !isStatusRefreshInFlight else {
            hasPendingStatusRefresh = true
            return
        }

        isStatusRefreshInFlight = true
        let menuStatus = adapter.copyMenuStatusSnapshot()
        dispatchReadiness(
            .runtimeStatusChanged(
                runtime: menuStatus.hostRuntimeRunning,
                video: menuStatus.captureSessionRunning,
                audio: menuStatus.audioCaptureSessionRunning
            )
        )
        isStatusRefreshInFlight = false

        guard hasPendingStatusRefresh else {
            return
        }

        hasPendingStatusRefresh = false
        refreshStatus()
    }

    private func makeMenuBarImage() -> NSImage? {
        let icon: LumenAssetIcon
        if !ownerAccessState.isAuthenticated {
            icon = .locked
        } else if menuStatus.captureSessionRunning {
            icon = .currentStream
        } else if menuStatus.hostRuntimeRunning {
            icon = .paused
        } else {
            icon = .locked
        }

        guard let image = LumenAssetIconStore.image(for: icon)?.copy() as? NSImage else {
            return nil
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    var hasActiveStream: Bool {
        menuStatus.captureSessionRunning || menuStatus.audioCaptureSessionRunning
    }

    var canRestartRuntime: Bool {
        ownerAccessState.isAuthenticated
    }

    var canRestartApplication: Bool {
        !isApplicationRestartInFlight
    }

    var isSystemAuthenticationAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var shouldShowScreenCapturePermissionButton: Bool {
        !isScreenCapturePermissionGranted
    }

    var shouldShowAccessibilityPermissionButton: Bool {
        !isAccessibilityPermissionGranted
    }

    var setupIsComplete: Bool {
        ownerAccessState.isConfigured &&
            isScreenCapturePermissionGranted &&
            isAccessibilityPermissionGranted
    }

    var setupSummary: String {
        guard ownerAccessState.isConfigured else {
            return LumenCopy.HostState.ownerSetupRequired
        }
        if setupIsComplete {
            return LumenCopy.HostState.ready
        }
        if !isScreenCapturePermissionGranted && !isAccessibilityPermissionGranted {
            return LumenCopy.HostState.permissionsRequired
        }
        if !isScreenCapturePermissionGranted {
            return LumenCopy.HostState.screenRecordingRequired
        }
        return LumenCopy.HostState.accessibilityRequired
    }

    func createOwner(username: String, password: String, confirmation: String) {
        setError(nil)
        guard password == confirmation else {
            setError(LumenCopy.HostState.passwordConfirmationMismatch)
            return
        }
        guard let ownerAccountStore else {
            ownerAccessState = .unavailable
            setError(LumenOwnerAccountError.storageUnavailable.localizedDescription)
            return
        }

        isOwnerOperationInFlight = true
        Task { @MainActor [weak self, ownerAccountStore] in
            guard let self else {
                return
            }
            defer { self.isOwnerOperationInFlight = false }
            do {
                try await ownerAccountStore.createOwner(username: username, password: password)
                let savedUsername = try await ownerAccountStore.username()
                self.ownerAccessState = .authenticated(username: savedUsername)
                self.startRuntimeAfterOwnerSetup()
            } catch {
                self.setError(error.localizedDescription)
                await self.refreshOwnerAccessState(using: ownerAccountStore)
            }
        }
    }

    func loginOwner(password: String) {
        setError(nil)
        guard case let .loginRequired(username) = ownerAccessState,
              let ownerAccountStore else {
            return
        }

        isOwnerOperationInFlight = true
        Task { @MainActor [weak self, ownerAccountStore] in
            guard let self else {
                return
            }
            defer { self.isOwnerOperationInFlight = false }
            do {
                try await ownerAccountStore.verifyOwner(username: username, password: password)
                self.ownerAccessState = .authenticated(username: username)
            } catch {
                self.setError(error.localizedDescription)
            }
        }
    }

    func logoutOwner() {
        guard case let .authenticated(username) = ownerAccessState else {
            return
        }
        ownerAccessState = .loginRequired(username: username)
        localAuthenticationContext?.invalidate()
        localAuthenticationContext = nil
        localAuthenticationRequestID = nil
        setError(nil)
    }

    func unlockOwnerWithSystemAuthentication() {
        guard isSystemAuthenticationEnabled,
              case let .loginRequired(username) = ownerAccessState,
              !isOwnerOperationInFlight else {
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = LumenCopy.Action.cancel
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &availabilityError) else {
            setError(availabilityError?.localizedDescription ?? LumenCopy.Account.systemAuthenticationUnavailable)
            return
        }

        localAuthenticationContext?.invalidate()
        localAuthenticationContext = context
        let requestID = UUID()
        localAuthenticationRequestID = requestID
        isOwnerOperationInFlight = true
        setError(nil)
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: LumenCopy.Account.systemAuthenticationReason
        ) { [weak self, requestID] success, error in
            let cancellationCodes: Set<LAError.Code> = [.userCancel, .appCancel, .systemCancel]
            let wasCancelled = (error as? LAError).map { cancellationCodes.contains($0.code) } ?? false
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self, requestID, wasCancelled, errorMessage] in
                guard let self, self.localAuthenticationRequestID == requestID else {
                    return
                }
                self.localAuthenticationContext = nil
                self.localAuthenticationRequestID = nil
                self.isOwnerOperationInFlight = false
                if success {
                    self.ownerAccessState = .authenticated(username: username)
                    return
                }

                if wasCancelled {
                    return
                }
                self.setError(errorMessage ?? LumenCopy.Account.systemAuthenticationFailed)
            }
        }
    }

    func setSystemAuthenticationEnabled(_ enabled: Bool) {
        guard ownerAccessState.isAuthenticated,
              !isHostSettingsOperationInFlight,
              let hostSettingsStore else {
            return
        }
        if !enabled {
            persistSystemAuthenticationEnabled(false, using: hostSettingsStore)
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = LumenCopy.Action.cancel
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &availabilityError) else {
            setError(availabilityError?.localizedDescription ?? LumenCopy.Account.systemAuthenticationUnavailable)
            return
        }

        localAuthenticationContext?.invalidate()
        localAuthenticationContext = context
        let requestID = UUID()
        localAuthenticationRequestID = requestID
        isHostSettingsOperationInFlight = true
        setError(nil)
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: LumenCopy.Account.enableSystemAuthenticationReason
        ) { [weak self, requestID] success, error in
            let cancellationCodes: Set<LAError.Code> = [.userCancel, .appCancel, .systemCancel]
            let wasCancelled = (error as? LAError).map { cancellationCodes.contains($0.code) } ?? false
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self, requestID, wasCancelled, errorMessage, hostSettingsStore] in
                guard let self, self.localAuthenticationRequestID == requestID else {
                    return
                }
                self.localAuthenticationContext = nil
                self.localAuthenticationRequestID = nil
                if success {
                    await self.finishPersistingSystemAuthenticationEnabled(true, using: hostSettingsStore)
                    return
                }

                self.isHostSettingsOperationInFlight = false
                if wasCancelled {
                    return
                }
                self.setError(errorMessage ?? LumenCopy.Account.systemAuthenticationFailed)
            }
        }
    }

    private func persistSystemAuthenticationEnabled(
        _ enabled: Bool,
        using hostSettingsStore: any LumenHostSettingsServicing
    ) {
        isHostSettingsOperationInFlight = true
        setError(nil)
        Task { @MainActor [weak self, hostSettingsStore] in
            guard let self else {
                return
            }
            await self.finishPersistingSystemAuthenticationEnabled(enabled, using: hostSettingsStore)
        }
    }

    private func finishPersistingSystemAuthenticationEnabled(
        _ enabled: Bool,
        using hostSettingsStore: any LumenHostSettingsServicing
    ) async {
        await hostSettingsStore.setSystemAuthenticationEnabled(enabled)
        do {
            applyHostSettingsSnapshot(try await hostSettingsStore.snapshot())
        } catch {
            setError(error.localizedDescription)
        }
        isHostSettingsOperationInFlight = false
    }

    func setWorkspacePolicy(_ policy: LumenMacWorkspacePolicy) {
        guard ownerAccessState.isAuthenticated,
              !isHostSettingsOperationInFlight,
              let hostSettingsStore else {
            return
        }
        isHostSettingsOperationInFlight = true
        setError(nil)
        Task { @MainActor [weak self, hostSettingsStore] in
            guard let self else {
                return
            }
            defer { self.isHostSettingsOperationInFlight = false }
            do {
                try await hostSettingsStore.setWorkspacePolicy(policy)
                self.applyHostSettingsSnapshot(try await hostSettingsStore.snapshot())
            } catch {
                self.setError(error.localizedDescription)
            }
        }
    }

    func saveHostSettings(_ settings: LumenNativeHostSettings) {
        guard ownerAccessState.isAuthenticated,
              let hostSettingsStore else {
            return
        }

        var settings = settings
        settings.systemAuthenticationEnabled = isSystemAuthenticationEnabled
        guard !isHostSettingsOperationInFlight else {
            pendingHostSettings = settings
            return
        }
        isHostSettingsOperationInFlight = true
        setError(nil)
        Task { @MainActor [weak self, hostSettingsStore] in
            guard let self else {
                return
            }
            defer {
                self.isHostSettingsOperationInFlight = false
                if let pendingSettings = self.pendingHostSettings {
                    self.pendingHostSettings = nil
                    self.saveHostSettings(pendingSettings)
                }
            }
            do {
                try await hostSettingsStore.save(settings)
                self.applyHostSettingsSnapshot(try await hostSettingsStore.snapshot())
            } catch {
                self.setError(error.localizedDescription)
            }
        }
    }

    func refreshApplications() {
        guard let applicationCatalogStore, !isApplicationOperationInFlight else {
            return
        }
        isApplicationOperationInFlight = true
        Task { @MainActor [weak self, applicationCatalogStore] in
            guard let self else {
                return
            }
            defer { self.isApplicationOperationInFlight = false }
            do {
                self.applications = try await applicationCatalogStore.applications()
            } catch {
                self.setError(error.localizedDescription)
            }
        }
    }

    func saveApplication(_ application: LumenApplication) {
        mutateApplications { store in
            try await store.save(application)
        }
    }

    func deleteApplication(_ application: LumenApplication) {
        mutateApplications { store in
            try await store.delete(applicationID: application.id)
        }
    }

    func moveApplications(from source: IndexSet, to destination: Int) {
        var reordered = applications
        reordered.move(fromOffsets: source, toOffset: destination)
        applications = reordered
        let identifiers = reordered.map(\.id)
        mutateApplications { store in
            try await store.reorder(applicationIDs: identifiers)
        }
    }

    func restartRuntimeCompanion() {
        setError(nil)
        isRestartingCompanion = true
        shouldIgnoreNextCompanionStop = true
        do {
            try adapter.restartRuntimeCompanion()
            refreshStatus()
        } catch {
            isRestartingCompanion = false
            shouldIgnoreNextCompanionStop = false
            setError(error.localizedDescription)
        }
    }

    func restartApplication() {
        guard canRestartApplication else {
            return
        }

        setError(nil)
        isApplicationRestartInFlight = true
        isShuttingDown = true
        adapter.stopRuntimeCompanion()

        Task { @MainActor [weak self, applicationRelauncher] in
            guard let self else {
                return
            }
            do {
                try await applicationRelauncher.relaunch()
            } catch let relaunchError {
                self.isShuttingDown = false
                self.isApplicationRestartInFlight = false
                do {
                    try self.adapter.startRuntimeCompanion()
                    self.refreshStatus()
                    self.setError(relaunchError.localizedDescription)
                } catch {
                    self.setError(error.localizedDescription)
                }
            }
        }
    }

    func forceStopCurrentStream() {
        adapter.forceStopCurrentStream()
        refreshStatus()
    }

    func quitApplication() {
        isShuttingDown = true
        NSApp.terminate(nil)
    }

    func factoryReset() {
        setError(nil)
        isShuttingDown = true

        do {
            try adapter.factoryReset()
        } catch {
            isShuttingDown = false
            setError(error.localizedDescription)
            return
        }

        LumenHostSettingsStore.resetStandardDefaults(bundleIdentifier: Bundle.main.bundleIdentifier)
        hostSettings = .defaults
        workspacePolicy = hostSettings.workspacePolicy
        isSystemAuthenticationEnabled = false

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    self.isShuttingDown = false
                    self.setError(error.localizedDescription)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    func refreshPermissionStatus() {
        let accessibilityGranted = adapter.isAccessibilityPermissionGranted
        let screenCaptureGranted = adapter.isScreenCapturePermissionGranted
        dispatchReadiness(
            .permissionsChanged(
                accessibility: accessibilityGranted,
                screenCapture: screenCaptureGranted
            )
        )
        permissionDragPanelController.update(
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenCaptureGranted
        )
    }

    func requestAccessibilityPermission() {
        adapter.requestAccessibilityPermission()
        presentPermissionPanel(.accessibility)
        schedulePermissionRefresh()
    }

    func requestScreenCapturePermission() {
        adapter.requestScreenCapturePermission()
        refreshPermissionStatus()
        if !isScreenCapturePermissionGranted {
            presentPermissionPanel(.screenRecording)
        }
        schedulePermissionRefresh()
    }

    func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
        presentPermissionPanel(.accessibility)
    }

    func openScreenRecordingSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
        presentPermissionPanel(.screenRecording)
    }

    func prepareForTermination() {
        isShuttingDown = true
        permissionDragPanelController.close()
        adapter.stopRuntimeCompanion()
    }

    private func observeReadinessState() {
        readinessObservationTask = Task { @MainActor [weak self, readinessStore] in
            let states = await readinessStore.states()
            for await state in states {
                guard let self, !Task.isCancelled else {
                    return
                }
                applyReadinessState(state)
            }
        }
    }

    private func dispatchReadiness(_ action: LumenHostReadinessAction) {
        Task { [readinessStore] in
            await readinessStore.send(action)
        }
    }

    private func setError(_ message: String?) {
        dispatchReadiness(.errorChanged(message))
    }

    private func applyReadinessState(_ state: LumenHostReadinessState) {
        menuStatus = LumenMacCaptureAdapterMenuStatus(
            hostRuntimeRunning: state.runtimeRunning,
            captureSessionRunning: state.videoCaptureRunning,
            audioCaptureSessionRunning: state.audioCaptureRunning
        )
        isAccessibilityPermissionGranted = state.accessibilityGranted
        isScreenCapturePermissionGranted = state.screenCaptureGranted
        lastErrorMessage = state.lastErrorMessage
        if isRestartingCompanion && state.runtimeRunning {
            isRestartingCompanion = false
        }
    }

    private func presentPermissionPanel(_ permission: LumenPermissionKind) {
        permissionDragPanelController.present(
            permission: permission,
            onCheck: { [weak self] in
                guard let self else {
                    return false
                }
                self.refreshPermissionStatus()
                return switch permission {
                case .accessibility: self.isAccessibilityPermissionGranted
                case .screenRecording: self.isScreenCapturePermissionGranted
                }
            },
            onDragEnded: { [weak self] in
                self?.schedulePermissionRefresh()
            }
        )
    }

    @objc private func handleStatusDidChange() {
        refreshStatus()
    }

    @objc private func handleCompanionDidStop() {
        guard !isShuttingDown else {
            return
        }

        if isRestartingCompanion || shouldIgnoreNextCompanionStop {
            shouldIgnoreNextCompanionStop = false
            return
        }

        dispatchReadiness(.runtimeStopped(message: LumenCopy.HostState.runtimeStopped))
    }

    @objc private func handleRuntimeEvent(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            return
        }

        let identifier = userInfo["identifier"] as? String ?? UUID().uuidString
        let body = userInfo["body"] as? String ?? ""
        let launchPath = userInfo["launchPath"] as? String ?? "/"
        let disposition = (userInfo["disposition"] as? NSNumber)
            .flatMap { LumenRuntimeEventDisposition(rawValue: $0.intValue) }
        let severity = (userInfo["severity"] as? NSNumber)?.intValue
        let code = (userInfo["code"] as? NSNumber)?.intValue

        if severity == 0, let code, let disposition {
            switch disposition {
            case .raised:
                let warning = LumenRuntimeWarning(code: code, message: body)
                let isDuplicate = runtimeWarnings.first(where: { $0.code == code }) == warning
                runtimeWarnings.removeAll(where: { $0.code == code })
                runtimeWarnings.insert(warning, at: 0)
                if runtimeWarnings.count > 8 {
                    runtimeWarnings.removeLast(runtimeWarnings.count - 8)
                }
                let localizedBody = warning.localizedMessage
                lastRuntimeEventMessage = localizedBody
                guard !isDuplicate else {
                    return
                }
                presentRuntimeNotification(
                    identifier: identifier,
                    title: LumenCopy.Diagnostics.runtimeWarning,
                    body: localizedBody,
                    launchPath: launchPath
                )
            case .cleared:
                let clearedMessage = runtimeWarnings.first(where: { $0.code == code })?.localizedMessage
                runtimeWarnings.removeAll(where: { $0.code == code })
                if lastRuntimeEventMessage == clearedMessage {
                    lastRuntimeEventMessage = runtimeWarnings.first?.localizedMessage
                }
                let notificationCenter = UNUserNotificationCenter.current()
                notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
                notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
                return
            }
            return
        }

        let title = userInfo["title"] as? String ?? LumenCopy.productName

        lastRuntimeEventMessage = body
        presentRuntimeNotification(
            identifier: identifier,
            title: title,
            body: body,
            launchPath: launchPath
        )
    }

    private func bootstrapOwnerAccess() {
        guard let ownerAccountStore else {
            ownerAccessState = .unavailable
            setError(LumenOwnerAccountError.storageUnavailable.localizedDescription)
            return
        }
        Task { @MainActor [weak self, ownerAccountStore] in
            guard let self else {
                return
            }
            await self.refreshOwnerAccessState(using: ownerAccountStore)
            if self.ownerAccessState.isConfigured {
                self.startRuntimeAfterOwnerSetup()
            }
        }
    }

    private func bootstrapHostSettings() {
        guard let hostSettingsStore else {
            setError(LumenHostSettingsError.invalidValue.localizedDescription)
            return
        }
        Task { @MainActor [weak self, hostSettingsStore] in
            guard let self else {
                return
            }
            do {
                self.applyHostSettingsSnapshot(try await hostSettingsStore.snapshot())
            } catch {
                self.setError(error.localizedDescription)
            }
        }
    }

    private func applyHostSettingsSnapshot(_ settings: LumenNativeHostSettings) {
        hostSettings = settings
        workspacePolicy = settings.workspacePolicy
        isSystemAuthenticationEnabled = settings.systemAuthenticationEnabled
    }

    private func mutateApplications(
        _ operation: @escaping @Sendable (any LumenApplicationCatalogServicing) async throws -> Void
    ) {
        guard ownerAccessState.isAuthenticated,
              let applicationCatalogStore,
              !isApplicationOperationInFlight else {
            return
        }
        isApplicationOperationInFlight = true
        setError(nil)
        Task { @MainActor [weak self, applicationCatalogStore] in
            guard let self else {
                return
            }
            defer { self.isApplicationOperationInFlight = false }
            do {
                try await operation(applicationCatalogStore)
                self.applications = try await applicationCatalogStore.applications()
                self.adapter.reloadApplications()
            } catch {
                self.setError(error.localizedDescription)
            }
        }
    }

    private func refreshOwnerAccessState(using store: any LumenOwnerAccountServicing) async {
        switch await store.state() {
        case .uninitialized:
            ownerAccessState = .setupRequired
        case .ready:
            do {
                ownerAccessState = .loginRequired(username: try await store.username())
            } catch {
                ownerAccessState = .corrupt
                setError(error.localizedDescription)
            }
        case .corrupt:
            ownerAccessState = .corrupt
        case .unavailable:
            ownerAccessState = .unavailable
        @unknown default:
            ownerAccessState = .unavailable
        }
    }

    private func startRuntimeAfterOwnerSetup() {
        guard !hasRequestedRuntimeStart else {
            return
        }
        hasRequestedRuntimeStart = true
        do {
            try adapter.startRuntimeCompanion()
        } catch {
            hasRequestedRuntimeStart = false
            setError(error.localizedDescription)
        }
        refreshStatus()
    }

    private func schedulePermissionRefresh() {
        refreshPermissionStatus()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            self?.refreshPermissionStatus()
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func presentRuntimeNotification(
        identifier: String,
        title: String,
        body: String,
        launchPath: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["lumenLaunchPath": launchPath]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

}
