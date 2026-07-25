import XCTest
import CoreGraphics
import ScreenCaptureKit
@testable import LumenMacBridge

private final class LumenDirectScreenCaptureOutputProbe:
    NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable {
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

private struct LumenVirtualDisplayAdmissionContext {
    let key: String
    let physicalMainDisplayID: CGDirectDisplayID
    let workspace: LumenMacDisplayWorkspace
    let physicalTopology: LumenMacPhysicalDisplayTopology
    let retained: LumenMacVirtualDisplay
    let owner: LumenRetainedVirtualDisplayReference

    var displayID: CGDirectDisplayID {
        retained.displayID
    }
}

private struct LumenDirectCaptureContext {
    let key: String
    let firstSample: XCTestExpectation
    let output: LumenDirectScreenCaptureOutputProbe
    let queue: DispatchQueue
    let stream: SCStream
}

final class LumenNativeVirtualDisplayCaptureTests: XCTestCase {
    func testRetainedVirtualDisplayPublishesAuthoritativeScreenCaptureDisplay() async throws {
        guard LumenMacVirtualDisplay.isSupported() else {
            throw XCTSkip("CGVirtualDisplay is unavailable on this runtime")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("The XCTest runner does not hold ScreenCaptureKit TCC permission")
        }
        let context = try await makeAdmissionContext()
        defer {
            _ = LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: context.key)
        }

        do {
            try await publishRetainedDisplay(context)
            XCTAssertEqual(CGMainDisplayID(), context.displayID)
            XCTAssertEqual(
                CGDisplayMirrorsDisplay(context.physicalMainDisplayID),
                context.displayID
            )
            try await assertAuthoritativeScreenCaptureDisplay(context.displayID)
            try await context.workspace.restoreWorkspace(context.physicalTopology)
        } catch {
            let originalError = error
            do {
                try await context.workspace.restoreWorkspace(context.physicalTopology)
            } catch {
                throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorRollbackFailed(
                    context.displayID
                )
            }
            try skipScreenCapturePermissionError(originalError)
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
        let context = try await makeDirectCaptureContext()

        do {
            try context.stream.addStreamOutput(
                context.output,
                type: .screen,
                sampleHandlerQueue: context.queue
            )
            try await context.stream.startCapture()
            await fulfillment(of: [context.firstSample], timeout: 5)
            try await context.stream.stopCapture()
            try context.stream.removeStreamOutput(context.output, type: .screen)
            XCTAssertTrue(LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: context.key))
        } catch {
            try? await context.stream.stopCapture()
            try? context.stream.removeStreamOutput(context.output, type: .screen)
            _ = LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: context.key)
            let nsError = error as NSError
            if isScreenCapturePermissionError(nsError) {
                context.firstSample.fulfill()
                throw XCTSkip("The XCTest runner does not hold ScreenCaptureKit TCC permission")
            }
            throw nsError
        }
    }
}

private extension LumenNativeVirtualDisplayCaptureTests {
    func makeAdmissionContext() async throws -> LumenVirtualDisplayAdmissionContext {
        let key = "direct-screen-capture-admission-v2"
        let configuration = makeAdmissionConfiguration(key: key)
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
        try await waitForDisplayDisconnection(firstDisplayID)
        let retained = try LumenMacVirtualDisplay.createRegisteredDisplay(
            forKey: key,
            configuration: configuration
        )
        try retained.updateLogicalWidth(
            configuration.logicalWidth,
            logicalHeight: configuration.logicalHeight,
            refreshRate: configuration.refreshRate
        )
        return LumenVirtualDisplayAdmissionContext(
            key: key,
            physicalMainDisplayID: physicalMainDisplayID,
            workspace: workspace,
            physicalTopology: physicalTopology,
            retained: retained,
            owner: LumenRetainedVirtualDisplayReference(display: retained)
        )
    }

    func makeAdmissionConfiguration(
        key: String
    ) -> LumenMacVirtualDisplayConfiguration {
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
        return configuration
    }

    func waitForDisplayDisconnection(
        _ displayID: CGDirectDisplayID
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
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
            if !onlineDisplayIDs.prefix(Int(onlineCount)).contains(displayID) {
                return
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("The first retained virtual display did not disconnect before recreation")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func publishRetainedDisplay(
        _ context: LumenVirtualDisplayAdmissionContext
    ) async throws {
        try await waitForModeSettlement(context)
        try await context.workspace.stageVirtualDisplayUnmirrored(
            context.displayID,
            sourceDisplayID: context.physicalMainDisplayID
        )
        try await context.workspace.mirrorOwnedVirtualDisplay(
            context.displayID,
            sourceDisplayID: context.physicalMainDisplayID
        )
        try await waitForStablePublication(context)
    }

    func waitForModeSettlement(
        _ context: LumenVirtualDisplayAdmissionContext
    ) async throws {
        let displayID = context.displayID
        let owner = context.owner
        try await LumenMacVirtualDisplayPublicationStabilizer.waitForModeSettlement(
            displayID: displayID,
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
                    displayID: displayID,
                    owner: owner
                )
            }
        )
    }

    func waitForStablePublication(
        _ context: LumenVirtualDisplayAdmissionContext
    ) async throws {
        let displayID = context.displayID
        let owner = context.owner
        try await LumenMacVirtualDisplayPublicationStabilizer.wait(
            displayID: displayID,
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
                    displayID: displayID,
                    owner: owner
                )
            }
        )
    }

    func assertAuthoritativeScreenCaptureDisplay(
        _ displayID: CGDirectDisplayID
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let admitted = try XCTUnwrap(
            content.displays.first(where: {
                UInt32($0.displayID) == displayID
            })
        )
        XCTAssertEqual(UInt32(admitted.displayID), displayID)
        _ = SCContentFilter(
            display: admitted,
            excludingApplications: [],
            exceptingWindows: []
        )
    }

    func makeDirectCaptureContext() async throws -> LumenDirectCaptureContext {
        let key = "direct-screen-capture-stream-test"
        let retained = try LumenMacVirtualDisplay.createRegisteredDisplay(
            forKey: key,
            configuration: makeDirectCaptureConfiguration()
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
        let firstSample = expectation(description: "direct retained display sample")
        let output = LumenDirectScreenCaptureOutputProbe(firstSample: firstSample)
        return LumenDirectCaptureContext(
            key: key,
            firstSample: firstSample,
            output: output,
            queue: DispatchQueue(label: "dev.skyline23.lumen.test.direct-sck"),
            stream: SCStream(
                filter: filter,
                configuration: makeDirectStreamConfiguration(),
                delegate: output
            )
        )
    }

    func makeDirectCaptureConfiguration() -> LumenMacVirtualDisplayConfiguration {
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen Direct Capture Test"
        configuration.backingWidth = 1_280
        configuration.backingHeight = 720
        configuration.logicalWidth = 1_280
        configuration.logicalHeight = 720
        configuration.refreshRate = 60
        return configuration
    }

    func makeDirectStreamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = 1_280
        configuration.height = 720
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 2
        return configuration
    }

    func skipScreenCapturePermissionError(_ error: Error) throws {
        let nsError = error as NSError
        if isScreenCapturePermissionError(nsError) {
            throw XCTSkip("The XCTest runner does not hold ScreenCaptureKit TCC permission")
        }
    }

    func isScreenCapturePermissionError(_ error: NSError) -> Bool {
        error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" &&
            error.code == -3_801
    }
}
