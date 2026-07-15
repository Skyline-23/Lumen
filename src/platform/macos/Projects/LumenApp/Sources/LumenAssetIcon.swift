import AppKit
import SwiftUI

enum LumenAssetIcon: String, Hashable {
    case overview
    case applications
    case settings
    case diagnostics
    case hostRuntime = "host-runtime"
    case currentStream = "current-stream"
    case complete
    case attention
    case add
    case desktop
    case application
    case virtualDisplay = "virtual-display"
    case delete
    case localCredentials = "local-credentials"
    case hostControls = "host-controls"
    case remoteAccess = "remote-access"
    case createOwner = "create-owner"
    case unlock
    case warning
    case showWindow = "show-window"
    case stopStream = "stop-stream"
    case restart
    case quit
    case workspace
    case paused
    case drag

    static let factoryReset = delete
    static let locked = unlock
}

struct LumenAssetIconView: View {
    let icon: LumenAssetIcon

    init(_ icon: LumenAssetIcon) {
        self.icon = icon
    }

    var body: some View {
        if let image = LumenAssetIconStore.image(for: icon) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }
}

@MainActor
enum LumenAssetIconStore {
    private static var cache: [LumenAssetIcon: NSImage] = [:]

    static func image(for icon: LumenAssetIcon) -> NSImage? {
        if let image = cache[icon] {
            return image
        }

        let filename = icon.rawValue
        let candidates = [
            Bundle.main.url(forResource: filename, withExtension: "svg", subdirectory: "assets/icons/ui"),
            Bundle.main.url(forResource: filename, withExtension: "svg", subdirectory: "ui")
        ]

        guard let url = candidates.compactMap({ $0 }).first,
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = true
        cache[icon] = image
        return image
    }
}
