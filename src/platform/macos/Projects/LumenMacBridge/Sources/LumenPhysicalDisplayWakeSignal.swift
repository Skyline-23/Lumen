import Foundation
import IOKit.pwr_mgt
import Synchronization

protocol LumenPhysicalDisplayWakeAssertion: AnyObject, Sendable {
    func release()
}

protocol LumenPhysicalDisplayWakeSignaling: Sendable {
    func acquireUserActivityAssertion() throws
        -> any LumenPhysicalDisplayWakeAssertion
}

struct LumenSystemPhysicalDisplayWakeSignal: LumenPhysicalDisplayWakeSignaling {
    func acquireUserActivityAssertion() throws
        -> any LumenPhysicalDisplayWakeAssertion {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(
            "Lumen physical display recovery" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            throw LumenPhysicalDisplayWakeSignalError.failed(result)
        }
        return LumenSystemPhysicalDisplayWakeAssertion(
            assertionID: assertionID
        )
    }
}

private final class LumenSystemPhysicalDisplayWakeAssertion:
    LumenPhysicalDisplayWakeAssertion,
    @unchecked Sendable
{
    private let assertionID: Mutex<IOPMAssertionID?>

    init(assertionID: IOPMAssertionID) {
        self.assertionID = Mutex(assertionID)
    }

    func release() {
        let assertionID = assertionID.withLock { assertionID in
            let current = assertionID
            assertionID = nil
            return current
        }
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
    }

    deinit {
        release()
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
