import LumenMacCaptureAdapter
import LumenMacBridge

protocol LumenOwnerAccountServicing: Sendable {
    func state() async -> LumenOwnerAccountState
    func createOwner(username: String, password: String) async throws
    func verifyOwner(username: String, password: String) async throws
    func username() async throws -> String
}

protocol LumenHostSettingsServicing: Sendable {
    func snapshot() async throws -> LumenNativeHostSettings
    func save(_ settings: LumenNativeHostSettings) async throws
    func setSystemAuthenticationEnabled(_ enabled: Bool) async
}

protocol LumenApplicationCatalogServicing: Sendable {
    func applications() async throws -> [LumenApplication]
    func save(_ application: LumenApplication) async throws
    func delete(applicationID: String) async throws
    func reorder(applicationIDs: [String]) async throws
}

@MainActor
protocol LumenApplicationRelaunching: AnyObject {
    func relaunch() async throws
}

@MainActor
protocol LumenHostRuntimeControlling: AnyObject {
    var isAccessibilityPermissionGranted: Bool { get }
    var isScreenCapturePermissionGranted: Bool { get }

    func copyMenuStatusSnapshot() -> LumenMacCaptureAdapterMenuStatus
    func startRuntimeCompanion() throws
    func restartRuntimeCompanion() throws
    func stopRuntimeCompanion()
    func factoryReset() throws
    func forceStopCurrentStream()
    func reloadApplications()
    func requestAccessibilityPermission()
    func requestScreenCapturePermission()
}

extension LumenOwnerAccountStore: LumenOwnerAccountServicing {}
extension LumenHostSettingsStore: LumenHostSettingsServicing {}
extension LumenApplicationCatalogStore: LumenApplicationCatalogServicing {}
extension LumenMacCaptureAdapter: LumenHostRuntimeControlling {}
