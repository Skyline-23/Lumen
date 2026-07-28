import Foundation
import OSLog
import ScreenCaptureKit

@objcMembers
public final class LumenScreenCaptureInventoryWarmup: NSObject {
    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "ScreenCaptureStartup"
    )

    public static func start() {
        Task(priority: .utility) {
            await warmInventory()
        }
    }

    private static func warmInventory() async {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        writeScreenCaptureStartupDiagnostic(
            "stage=display-inventory-warmup-begin"
        )
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let elapsedMilliseconds = Double(
                DispatchTime.now().uptimeNanoseconds - startedAt
            ) / 1_000_000
            let observedDisplayIDs = content.displays
                .map { String(UInt32($0.displayID)) }
                .joined(separator: ",")
            let message = [
                "stage=display-inventory-warmup-complete",
                "elapsed-ms=\(elapsedMilliseconds)",
                "observed-display-ids=\(observedDisplayIDs)"
            ].joined(separator: " ")
            logger.notice("\(message, privacy: .public)")
            writeScreenCaptureStartupDiagnostic(message)
        } catch {
            let elapsedMilliseconds = Double(
                DispatchTime.now().uptimeNanoseconds - startedAt
            ) / 1_000_000
            let message = [
                "stage=display-inventory-warmup-failed",
                "elapsed-ms=\(elapsedMilliseconds)",
                "error=\(String(describing: error))"
            ].joined(separator: " ")
            logger.warning("\(message, privacy: .public)")
            writeScreenCaptureStartupDiagnostic(message)
        }
    }
}
