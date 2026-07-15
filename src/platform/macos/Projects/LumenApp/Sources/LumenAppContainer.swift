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

        return Self(
            captureController: LumenCaptureController(
                adapter: adapter,
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
