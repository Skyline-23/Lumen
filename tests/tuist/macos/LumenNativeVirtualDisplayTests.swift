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

    func testRetainedVirtualDisplayCreatesDirectScreenCaptureAuthority() throws {
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

        let retained = try LumenMacVirtualDisplay.createRegisteredDisplay(
            forKey: key,
            configuration: configuration
        )
        defer {
            _ = LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: key)
        }

        let admittedObject = try retained.makeScreenCaptureDisplay()
        let admitted = try XCTUnwrap(admittedObject as? SCDisplay)
        XCTAssertEqual(UInt32(admitted.displayID), retained.displayID)
        _ = SCContentFilter(
            display: admitted,
            excludingApplications: [],
            exceptingWindows: []
        )
    }

    func testDirectScreenCaptureAuthorityStartsWithoutShareableContentEnumeration() async throws {
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
        let admittedObject = try retained.makeScreenCaptureDisplay()
        let admitted = try XCTUnwrap(admittedObject as? SCDisplay)
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
