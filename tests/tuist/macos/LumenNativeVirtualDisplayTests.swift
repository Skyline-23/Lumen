import XCTest
import CoreGraphics
import ScreenCaptureKit
@testable import LumenMacBridge

private final class LumenDirectScreenCaptureOutputProbe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let firstSample: XCTestExpectation

    init(firstSample: XCTestExpectation) {
        self.firstSample = firstSample
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        firstSample.fulfill()
    }
}

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
                return LumenScreenCaptureDisplayReadinessSnapshot(
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
                return LumenScreenCaptureDisplayReadinessSnapshot(
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

    func testRetainedVirtualDisplayPublishesAuthoritativeScreenCaptureDisplay() async throws {
        guard LumenMacVirtualDisplay.isSupported() else {
            throw XCTSkip("CGVirtualDisplay is unavailable on this runtime")
        }
        let key = "direct-screen-capture-admission-v2"
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen Admission Test"
        let identity = LumenMacVirtualDisplayConfigurationFactory.persistentIdentity(
            forDisplayKey: key
        )
        configuration.productID = identity.productID
        configuration.serialNumber = identity.serialNumber
        configuration.backingWidth = 1_920
        configuration.backingHeight = 1_080
        configuration.logicalWidth = 960
        configuration.logicalHeight = 540
        configuration.refreshRate = 120
        configuration.highDensity = true

        let physicalMainDisplayID = CGMainDisplayID()
        let workspace = LumenMacDisplayWorkspace()
        let physicalTopology = try await workspace.snapshotWorkspace(
            targetProcessIdentifiers: []
        )
        let firstOwner = try LumenMacVirtualDisplay.createRegisteredDisplay(
            forKey: key,
            configuration: configuration
        )
        let firstDisplayID = firstOwner.displayID
        XCTAssertTrue(
            LumenMacVirtualDisplay.removeRegisteredDisplay(
                forKey: key,
                ifMatchingDisplay: firstOwner
            )
        )
        let disconnectDeadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while true {
            var onlineCount: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &onlineCount) == .success else {
                XCTFail("The online display inventory could not be read")
                return
            }
            var onlineDisplayIDs = [CGDirectDisplayID](
                repeating: 0,
                count: Int(onlineCount)
            )
            guard CGGetOnlineDisplayList(
                onlineCount,
                &onlineDisplayIDs,
                &onlineCount
            ) == .success else {
                XCTFail("The online display inventory could not be read")
                return
            }
            if !onlineDisplayIDs.prefix(Int(onlineCount)).contains(firstDisplayID) {
                break
            }
            guard DispatchTime.now().uptimeNanoseconds < disconnectDeadline else {
                XCTFail("The first retained virtual display did not disconnect before recreation")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let retained = try LumenMacVirtualDisplay.createRegisteredDisplay(
            forKey: key,
            configuration: configuration
        )
        defer {
            _ = LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: key)
        }

        try retained.updateLogicalWidth(
            configuration.logicalWidth,
            logicalHeight: configuration.logicalHeight,
            refreshRate: configuration.refreshRate
        )
        let retainedDisplayID = retained.displayID
        let owner = LumenRetainedVirtualDisplayReference(display: retained)
        do {
            try await LumenMacVirtualDisplayPublicationStabilizer.waitForModeSettlement(
                displayID: retainedDisplayID,
                expectedOwnerToken: owner.ownerToken,
                timing: .production,
                now: {
                    DispatchTime.now().uptimeNanoseconds
                },
                sleepUntil: { deadline in
                    let now = DispatchTime.now().uptimeNanoseconds
                    if deadline > now {
                        try await Task.sleep(nanoseconds: deadline - now)
                    }
                },
                snapshot: {
                    LumenScreenCaptureDisplayReadiness.snapshot(
                        displayID: retainedDisplayID,
                        owner: owner
                    )
                }
            )
            try await workspace.stageVirtualDisplayUnmirrored(
                retainedDisplayID,
                sourceDisplayID: physicalMainDisplayID
            )
            try await workspace.mirrorOwnedVirtualDisplay(
                retainedDisplayID,
                sourceDisplayID: physicalMainDisplayID
            )
            try await LumenMacVirtualDisplayPublicationStabilizer.wait(
                displayID: retainedDisplayID,
                expectedOwnerToken: owner.ownerToken,
                timing: .production,
                now: {
                    DispatchTime.now().uptimeNanoseconds
                },
                sleepUntil: { deadline in
                    let now = DispatchTime.now().uptimeNanoseconds
                    if deadline > now {
                        try await Task.sleep(nanoseconds: deadline - now)
                    }
                },
                snapshot: {
                    LumenScreenCaptureDisplayReadiness.snapshot(
                        displayID: retainedDisplayID,
                        owner: owner
                    )
                }
            )
            XCTAssertEqual(CGMainDisplayID(), retainedDisplayID)
            XCTAssertEqual(
                CGDisplayMirrorsDisplay(physicalMainDisplayID),
                retainedDisplayID
            )

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let admitted = try XCTUnwrap(
                content.displays.first(where: {
                    UInt32($0.displayID) == retainedDisplayID
                })
            )
            XCTAssertEqual(UInt32(admitted.displayID), retainedDisplayID)
            _ = SCContentFilter(
                display: admitted,
                excludingApplications: [],
                exceptingWindows: []
            )
            try await workspace.restoreWorkspace(physicalTopology)
        } catch {
            let originalError = error
            do {
                try await workspace.restoreWorkspace(physicalTopology)
            } catch {
                throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorRollbackFailed(
                    retainedDisplayID
                )
            }
            let nsError = originalError as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
               nsError.code == -3_801 {
                throw XCTSkip("The XCTest runner does not hold ScreenCaptureKit TCC permission")
            }
            throw originalError
        }
    }

    func testAuthoritativeShareableDisplayStartsScreenCapture() async throws {
        guard LumenMacVirtualDisplay.isSupported() else {
            throw XCTSkip("CGVirtualDisplay is unavailable on this runtime")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("The XCTest runner does not hold ScreenCaptureKit TCC permission")
        }
        let key = "direct-screen-capture-stream-test"
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen Direct Capture Test"
        configuration.backingWidth = 1_280
        configuration.backingHeight = 720
        configuration.logicalWidth = 1_280
        configuration.logicalHeight = 720
        configuration.refreshRate = 60

        let retained = try LumenMacVirtualDisplay.createRegisteredDisplay(
            forKey: key,
            configuration: configuration
        )
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let admitted = try XCTUnwrap(
            content.displays.first(where: { UInt32($0.displayID) == retained.displayID })
        )
        let filter = SCContentFilter(
            display: admitted,
            excludingApplications: [],
            exceptingWindows: []
        )
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = 1_280
        streamConfiguration.height = 720
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        streamConfiguration.queueDepth = 2
        let firstSample = expectation(description: "direct retained display sample")
        let output = LumenDirectScreenCaptureOutputProbe(firstSample: firstSample)
        let queue = DispatchQueue(label: "dev.skyline23.lumen.test.direct-sck")
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)

        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            await fulfillment(of: [firstSample], timeout: 5)
            try await stream.stopCapture()
            try stream.removeStreamOutput(output, type: .screen)
            XCTAssertTrue(LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: key))
        } catch {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(output, type: .screen)
            _ = LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: key)
            let error = error as NSError
            if error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
               error.code == -3_801 {
                firstSample.fulfill()
                throw XCTSkip("The XCTest runner does not hold ScreenCaptureKit TCC permission")
            }
            throw error
        }
    }
}
