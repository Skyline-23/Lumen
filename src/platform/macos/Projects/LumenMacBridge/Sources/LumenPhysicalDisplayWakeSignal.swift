import Foundation
import IOKit.pwr_mgt

protocol LumenPhysicalDisplayWakeSignaling: Sendable {
    func signalUserActivity() throws
}

struct LumenSystemPhysicalDisplayWakeSignal: LumenPhysicalDisplayWakeSignaling {
    func signalUserActivity() throws {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(
            "Lumen physical display recovery" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            throw LumenPhysicalDisplayWakeSignalError.failed(result)
        }
        IOPMAssertionRelease(assertionID)
    }
}

private enum LumenPhysicalDisplayWakeSignalError: LocalizedError {
    case failed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .failed(let status):
            "physical display wake signaling failed with status \(status)"
        }
    }
}
