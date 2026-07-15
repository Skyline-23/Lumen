import Foundation
import LumenAppArchitecture
import LumenMacCaptureAdapter
import LumenMacBridge

@MainActor
struct LumenAppContainer {
    let captureController: LumenCaptureController
    let applicationPreferences: LumenApplicationPreferences

    static func live() -> Self {
        let adapter = LumenMacCaptureAdapter()
        let ownerAccountStore = try? LumenOwnerAccountStore()
        let hostSettingsStore = try? LumenHostSettingsStore()
        let applicationCatalogStore = try? LumenApplicationCatalogStore()
        let readinessStore = LumenHostReadinessStore()
        let applicationLocaleStore = LumenApplicationLocaleStore(
            userDefaults: .standard,
            activeLanguage: { Bundle.main.preferredLocalizations.first }
        )

        return Self(
            captureController: LumenCaptureController(
                adapter: adapter,
                applicationLocaleStore: applicationLocaleStore,
                applicationRelauncher: LumenWorkspaceApplicationRelauncher(
                    applicationURL: Bundle.main.bundleURL
                ),
                readinessStore: readinessStore,
                ownerAccountStore: ownerAccountStore,
                hostSettingsStore: hostSettingsStore,
                applicationCatalogStore: applicationCatalogStore,
                permissionDragPanelController: LumenPermissionDragPanelController()
            ),
            applicationPreferences: LumenApplicationPreferences(userDefaults: .standard)
        )
    }
}
