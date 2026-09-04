import XCTest
import CoreGraphics
@testable import LumenMacBridge

private actor LumenVirtualDisplayPublicationClock {
    private var uptimeNanoseconds: UInt64 = 0

    func now() -> UInt64 {
        uptimeNanoseconds
    }

    func sleep(until deadline: UInt64) {
        uptimeNanoseconds = max(uptimeNanoseconds, deadline)
    }
}

final class LumenNativeVirtualDisplayTests: XCTestCase {
    func testNativeVirtualDisplayRejectsEmptyGeometry() {
        let configuration = LumenMacVirtualDisplayConfiguration()
        XCTAssertThrowsError(try LumenMacVirtualDisplay(configuration: configuration))
    }

    func testSDRVirtualDisplayUsesLegacyModeWithoutTransferFunction() throws {
        guard LumenMacVirtualDisplay.isSupported() else {
            throw XCTSkip("CGVirtualDisplay is unavailable on this runtime")
        }
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen SDR Mode Contract Test"
        configuration.backingWidth = 1_280
        configuration.backingHeight = 720
        configuration.maximumBackingWidth = 15_360
        configuration.maximumBackingHeight = 15_360
        configuration.logicalWidth = 640
        configuration.logicalHeight = 360
        configuration.refreshRate = 60
        configuration.hdrEnabled = false
        configuration.transfer = .PQ

        let display = try LumenMacVirtualDisplay(configuration: configuration)
        defer { display.destroy() }
        let initialMode = try XCTUnwrap(display.value(forKey: "mode") as? NSObject)
        let initialTransferFunction = try XCTUnwrap(
            initialMode.value(forKey: "transferFunction") as? NSNumber
        )
        XCTAssertEqual(initialTransferFunction.uint32Value, 0)

        try display.updateLogicalWidth(640, logicalHeight: 360, refreshRate: 60)
        let duplicateMode = try XCTUnwrap(display.value(forKey: "mode") as? NSObject)
        XCTAssertIdentical(duplicateMode, initialMode)

        try display.updateLogicalWidth(800, logicalHeight: 450, refreshRate: 60)
        let updatedMode = try XCTUnwrap(display.value(forKey: "mode") as? NSObject)
        XCTAssertNotIdentical(updatedMode, initialMode)
        let updatedTransferFunction = try XCTUnwrap(
            updatedMode.value(forKey: "transferFunction") as? NSNumber
        )
        XCTAssertEqual(updatedTransferFunction.uint32Value, 0)
        XCTAssertEqual(display.backingWidth, 1_600)
        XCTAssertEqual(display.backingHeight, 900)
    }

    func testRetainedVirtualDisplayRejectsModeBeyondDescriptorCapacity() throws {
        guard LumenMacVirtualDisplay.isSupported() else {
            throw XCTSkip("CGVirtualDisplay is unavailable on this runtime")
        }
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen Retained Capacity Contract Test"
        configuration.backingWidth = 1_280
        configuration.backingHeight = 720
        configuration.maximumBackingWidth = 3_840
        configuration.maximumBackingHeight = 2_400
        configuration.logicalWidth = 640
        configuration.logicalHeight = 360
        configuration.refreshRate = 60
        configuration.highDensity = true

        let display = try LumenMacVirtualDisplay(configuration: configuration)
        defer { display.destroy() }

        try display.updateLogicalWidth(1_800, logicalHeight: 1_130, refreshRate: 60)
        XCTAssertEqual(display.logicalWidth, 1_800)
        XCTAssertEqual(display.logicalHeight, 1_130)
        XCTAssertEqual(display.backingWidth, 3_600)
        XCTAssertEqual(display.backingHeight, 2_260)

        XCTAssertThrowsError(
            try display.updateLogicalWidth(2_000, logicalHeight: 1_300, refreshRate: 60)
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "dev.skyline23.lumen.virtual-display")
            XCTAssertEqual(nsError.code, 1)
            XCTAssertTrue(nsError.localizedDescription.contains("exceeds"))
        }
        XCTAssertEqual(display.logicalWidth, 1_800)
        XCTAssertEqual(display.logicalHeight, 1_130)
        XCTAssertEqual(display.backingWidth, 3_600)
        XCTAssertEqual(display.backingHeight, 2_260)
    }

    func testPublishedHiDPIModeSelectsLogicalAndBackingGeometry() async throws {
        guard LumenMacVirtualDisplay.isSupported() else {
            throw XCTSkip("Virtual displays are unavailable on this runtime")
        }
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen HiDPI Selection Contract Test"
        configuration.backingWidth = 2_420
        configuration.backingHeight = 1_668
        configuration.maximumBackingWidth = 3_840
        configuration.maximumBackingHeight = 2_400
        configuration.logicalWidth = 1_210
        configuration.logicalHeight = 834
        configuration.refreshRate = 120
        configuration.highDensity = true

        let display = try LumenMacVirtualDisplay(configuration: configuration)
        defer { display.destroy() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while true {
            do {
                try display.selectPublishedHiDPIMode()
                break
            } catch {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw error }
                try await Task.sleep(
                    nanoseconds: min(100_000_000, deadline - now)
                )
            }
        }

        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(display.displayID))
        XCTAssertEqual(mode.width, Int(configuration.logicalWidth))
        XCTAssertEqual(mode.height, Int(configuration.logicalHeight))
        XCTAssertEqual(mode.pixelWidth, Int(configuration.backingWidth))
        XCTAssertEqual(mode.pixelHeight, Int(configuration.backingHeight))

        let owner = LumenRetainedVirtualDisplayReference(display: display)
        let readiness = LumenScreenCaptureDisplayReadiness.snapshot(
            displayID: display.displayID,
            owner: owner
        )
        XCTAssertEqual(readiness.pixelWidth, Int(configuration.backingWidth))
        XCTAssertEqual(readiness.pixelHeight, Int(configuration.backingHeight))
        XCTAssertTrue(
            readiness.isModeReady(for: .retained(ownerToken: owner.ownerToken))
        )
    }

    func testPublicationStabilizerRestartsContinuousReadyWindowAfterStateChange() async throws {
        let clock = LumenVirtualDisplayPublicationClock()
        let ownerToken: UInt = 41
        let timing = LumenMacVirtualDisplayPublicationTiming(
            overallDeadlineNanoseconds: 6_000_000_000,
            stableWindowNanoseconds: 2_000_000_000,
            pollNanoseconds: 500_000_000
        )

        try await LumenMacVirtualDisplayPublicationStabilizer.wait(
            displayID: 77,
            expectedOwnerToken: ownerToken,
            timing: timing,
            now: {
                await clock.now()
            },
            sleepUntil: { deadline in
                await clock.sleep(until: deadline)
            },
            snapshot: {
                let now = await clock.now()
                let pixelWidth = now < 1_000_000_000 ? 640 : 1_280
                let pixelHeight = now < 1_000_000_000 ? 360 : 720
                return LumenCaptureDisplayReadinessSnapshot(
                    ownerToken: ownerToken,
                    isOnline: true,
                    isActive: true,
                    hasCurrentMode: now < 1_000_000_000,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    configuredPixelWidth: pixelWidth,
                    configuredPixelHeight: pixelHeight
                )
            }
        )

        let completedAt = await clock.now()
        XCTAssertEqual(completedAt, 3_000_000_000)
    }

    func testModeSettlementAcceptsAStableRetainedModeBeforeActivation() async throws {
        let clock = LumenVirtualDisplayPublicationClock()
        let ownerToken: UInt = 42
        let timing = LumenMacVirtualDisplayPublicationTiming(
            overallDeadlineNanoseconds: 3_000_000_000,
            stableWindowNanoseconds: 1_000_000_000,
            pollNanoseconds: 500_000_000
        )

        try await LumenMacVirtualDisplayPublicationStabilizer.waitForModeSettlement(
            displayID: 78,
            expectedOwnerToken: ownerToken,
            timing: timing,
            now: {
                await clock.now()
            },
            sleepUntil: { deadline in
                await clock.sleep(until: deadline)
            },
            snapshot: {
                return LumenCaptureDisplayReadinessSnapshot(
                    ownerToken: ownerToken,
                    isOnline: false,
                    isActive: false,
                    hasCurrentMode: false,
                    pixelWidth: 640,
                    pixelHeight: 360,
                    configuredPixelWidth: 640,
                    configuredPixelHeight: 360
                )
            }
        )

        let completedAt = await clock.now()
        XCTAssertEqual(completedAt, 1_000_000_000)
    }

    func testPublicationFailureDescribesTheOwnedDisplayBoundary() {
        XCTAssertEqual(
            LumenMacWorkspaceSessionError
                .virtualDisplayModeSettlementUnavailable(76)
                .errorDescription,
            "owned virtual display 76 did not finish its mode publication " +
                "before the settlement deadline"
        )
        XCTAssertEqual(
            LumenMacWorkspaceSessionError
                .virtualDisplayPublicationUnavailable(77)
                .errorDescription,
            "owned virtual display 77 did not reach stable capture readiness " +
                "before the publication deadline"
        )
    }

    func testVirtualDisplayRegistryHandlesUnknownKeysWithoutSideEffects() {
        LumenMacVirtualDisplay.destroyAllRegisteredDisplays()

        XCTAssertNil(LumenMacVirtualDisplay.registeredDisplay(forKey: "missing"))
        XCTAssertNil(LumenMacVirtualDisplay.registeredDisplay(forDisplayID: 999_999))
        XCTAssertFalse(LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: "missing"))
    }

    func testRegistryRejectsDuplicateKeysAndConditionallyRemovesOnlyTheExactOwner() throws {
        guard LumenMacVirtualDisplay.isSupported() else {
            throw XCTSkip("CGVirtualDisplay is unavailable on this runtime")
        }
        let originalKey = "conditional-owner-\(UUID().uuidString)"
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen Registry Ownership Test"
        configuration.backingWidth = 1_280
        configuration.backingHeight = 720
        configuration.logicalWidth = 1_280
        configuration.logicalHeight = 720
        configuration.refreshRate = 60

        let original = try LumenMacVirtualDisplay.createRegisteredDisplay(
            forKey: originalKey,
            configuration: configuration
        )
        let mismatchedOwner = try XCTUnwrap(
            (LumenMacVirtualDisplay.self as AnyObject)
                .perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue() as? LumenMacVirtualDisplay
        )
        defer {
            _ = LumenMacVirtualDisplay.removeRegisteredDisplay(
                forKey: originalKey,
                ifMatchingDisplay: original
            )
        }

        XCTAssertThrowsError(
            try LumenMacVirtualDisplay.createRegisteredDisplay(
                forKey: originalKey,
                configuration: configuration
            )
        )
        XCTAssertTrue(LumenMacVirtualDisplay.registeredDisplay(forKey: originalKey) === original)
        XCTAssertFalse(
            LumenMacVirtualDisplay.removeRegisteredDisplay(
                forKey: originalKey,
                ifMatchingDisplay: mismatchedOwner
            )
        )
        XCTAssertTrue(LumenMacVirtualDisplay.registeredDisplay(forKey: originalKey) === original)
        XCTAssertTrue(
            LumenMacVirtualDisplay.removeRegisteredDisplay(
                forKey: originalKey,
                ifMatchingDisplay: original
            )
        )
        XCTAssertNil(LumenMacVirtualDisplay.registeredDisplay(forKey: originalKey))
    }

}
