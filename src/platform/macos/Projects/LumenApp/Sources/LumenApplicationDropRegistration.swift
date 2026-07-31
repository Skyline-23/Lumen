import AppKit
import LumenMacBridge
import UniformTypeIdentifiers

/// Builds a catalog entry from an application bundle dropped onto the app list.
///
/// Registering by hand requires the user to know the launch command, so dropping a
/// bundle derives the display name and an `open` command that macOS can start.
enum LumenApplicationDropRegistration {
    static func makeApplication(fromBundleAt url: URL) -> LumenApplication? {
        guard isApplicationBundle(url) else { return nil }
        let bundle = Bundle(url: url)
        let name = displayName(for: url, bundle: bundle)
        return LumenApplication(
            name: name,
            command: launchCommand(for: url),
            imagePath: iconPath(for: url, bundle: bundle) ?? "",
            autoDetach: true,
            waitForAllProcesses: false
        )
    }

    static func isApplicationBundle(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func displayName(for url: URL, bundle: Bundle?) -> String {
        let info = bundle?.infoDictionary
        let candidates = [
            info?["CFBundleDisplayName"] as? String,
            info?["CFBundleName"] as? String,
        ]
        if let named = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return named
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Quotes the path so bundles under directories with spaces still launch.
    private static func launchCommand(for url: URL) -> String {
        "/usr/bin/open -n \"\(url.path)\""
    }

    private static func iconPath(for url: URL, bundle: Bundle?) -> String? {
        guard let iconFile = bundle?.infoDictionary?["CFBundleIconFile"] as? String,
              !iconFile.isEmpty
        else {
            return nil
        }
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        let named = resources.appendingPathComponent(iconFile, isDirectory: false)
        if FileManager.default.fileExists(atPath: named.path) {
            return named.path
        }
        let withExtension = named.appendingPathExtension("icns")
        guard FileManager.default.fileExists(atPath: withExtension.path) else {
            return nil
        }
        return withExtension.path
    }
}
