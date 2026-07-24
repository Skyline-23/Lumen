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

final class LumenNativeVirtualDisplayTests: XCTestCase {
    func testNativeVirtualDisplayRejectsEmptyGeometry() {
        let configuration = LumenMacVirtualDisplayConfiguration()
        XCTAssertThrowsError(try LumenMacVirtualDisplay(configuration: configuration))
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
        let key = "direct-screen-capture-admission-test"
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen Admission Test"
        configuration.backingWidth = 1_280
        configuration.backingHeight = 720
        configuration.logicalWidth = 1_280
        configuration.logicalHeight = 720
        configuration.refreshRate = 60

        let physicalMainDisplayID = CGMainDisplayID()
        let workspace = LumenMacDisplayWorkspace()
        let physicalTopology = try await workspace.snapshotWorkspace(
            targetProcessIdentifiers: []
        )
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
        try await workspace.stageVirtualDisplayUnmirrored(
            retained.displayID,
            sourceDisplayID: physicalMainDisplayID
        )
        XCTAssertEqual(CGMainDisplayID(), physicalMainDisplayID)
        XCTAssertEqual(
            CGDisplayMirrorsDisplay(retained.displayID),
            kCGNullDirectDisplay
        )
        let physicalBounds = physicalTopology.displays.compactMap { state in
            UInt32(state.id).map(CGDisplayBounds)
        }
        let physicalUnion = try XCTUnwrap(physicalBounds.first).union(
            physicalBounds.dropFirst().reduce(.null) { $0.union($1) }
        )
        let stagedBounds = CGDisplayBounds(retained.displayID)
        XCTAssertEqual(stagedBounds.origin.x.rounded(.up), physicalUnion.maxX.rounded(.up))
        XCTAssertEqual(stagedBounds.origin.y.rounded(.down), physicalUnion.minY.rounded(.down))
        XCTAssertTrue(physicalBounds.allSatisfy { !$0.intersects(stagedBounds) })

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            let error = error as NSError
            if error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
               error.code == -3_801 {
                throw XCTSkip("The XCTest runner does not hold ScreenCaptureKit TCC permission")
            }
            throw error
        }
        let admitted = try XCTUnwrap(
            content.displays.first(where: { UInt32($0.displayID) == retained.displayID })
        )
        XCTAssertEqual(UInt32(admitted.displayID), retained.displayID)
        _ = SCContentFilter(
            display: admitted,
            excludingApplications: [],
            exceptingWindows: []
        )
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
