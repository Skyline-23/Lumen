import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Synchronization

protocol LumenPhysicalDisplayWakeAssertion: AnyObject, Sendable {
    func release()
}

protocol LumenPhysicalDisplayWakeSignaling: Sendable {
    func acquireUserActivityAssertion() throws
        -> any LumenPhysicalDisplayWakeAssertion
    func isDisplayAsleep(_ displayID: CGDirectDisplayID) -> Bool
    func retainUserActivityAssertion(
        _ assertion: any LumenPhysicalDisplayWakeAssertion,
        for duration: Duration
    )
}

extension LumenPhysicalDisplayWakeSignaling {
    func isDisplayAsleep(_ displayID: CGDirectDisplayID) -> Bool {
        false
    }

    func pulseUserActivity() throws {
        let assertion = try acquireUserActivityAssertion()
        assertion.release()
    }

    func retainUserActivityAssertion(
        _ assertion: any LumenPhysicalDisplayWakeAssertion,
        for _: Duration
    ) {
        assertion.release()
    }
}

struct LumenSystemPhysicalDisplayWakeSignal: LumenPhysicalDisplayWakeSignaling {
    private static let localInputPollInterval: Duration = .milliseconds(500)

    func isDisplayAsleep(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsAsleep(displayID) != 0
    }

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
        var displaySleepAssertionID = IOPMAssertionID(0)
        let displaySleepResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Lumen physical display recovery lease" as CFString,
            &displaySleepAssertionID
        )
        guard displaySleepResult == kIOReturnSuccess else {
            IOPMAssertionRelease(assertionID)
            throw LumenPhysicalDisplayWakeSignalError.failed(
                displaySleepResult
            )
        }
        return LumenSystemPhysicalDisplayWakeAssertion(
            assertionIDs: [assertionID, displaySleepAssertionID]
        )
    }

    func retainUserActivityAssertion(
        _ assertion: any LumenPhysicalDisplayWakeAssertion,
        for duration: Duration
    ) {
        let initialIdleNanoseconds = Self.localInputIdleNanoseconds()
        Task.detached(priority: .utility) {
            let deadline = ContinuousClock.now.advanced(by: duration)
            var previousIdleNanoseconds = initialIdleNanoseconds
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.localInputPollInterval)
                guard let currentIdleNanoseconds =
                    Self.localInputIdleNanoseconds()
                else {
                    continue
                }
                if Self.didObserveLocalInput(
                    previousIdleNanoseconds: previousIdleNanoseconds,
                    currentIdleNanoseconds: currentIdleNanoseconds
                ) {
                    break
                }
                previousIdleNanoseconds = currentIdleNanoseconds
            }
            try? pulseUserActivity()
            assertion.release()
        }
    }

    static func didObserveLocalInput(
        previousIdleNanoseconds: UInt64?,
        currentIdleNanoseconds: UInt64
    ) -> Bool {
        guard let previousIdleNanoseconds else { return false }
        return currentIdleNanoseconds < previousIdleNanoseconds
    }

    private static func localInputIdleNanoseconds() -> UInt64? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "HIDIdleTime" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return value.uint64Value
    }
}

private final class LumenSystemPhysicalDisplayWakeAssertion:
    LumenPhysicalDisplayWakeAssertion,
    @unchecked Sendable {
    private let assertionIDs: Mutex<[IOPMAssertionID]>

    init(assertionIDs: [IOPMAssertionID]) {
        self.assertionIDs = Mutex(assertionIDs)
    }

    func release() {
        let assertionIDs = assertionIDs.withLock { assertionIDs in
            let current = assertionIDs
            assertionIDs.removeAll()
            return current
        }
        for assertionID in assertionIDs {
            IOPMAssertionRelease(assertionID)
        }
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
