import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceConfigurationTests: XCTestCase {
    func testVirtualDisplayConfigurationPreservesHDRSinkContract() throws {
        let fixture = try makeHDRConfigurationFixture()

        XCTAssertEqual(fixture.configuration.backingWidth, 2388)
        XCTAssertEqual(fixture.configuration.maximumBackingWidth, 15_360)
        XCTAssertEqual(fixture.configuration.maximumBackingHeight, 15_360)
        XCTAssertEqual(fixture.configuration.logicalWidth, 1592)
        XCTAssertEqual(fixture.configuration.refreshRate, 120)
        XCTAssertTrue(fixture.configuration.highDensity)
        XCTAssertTrue(fixture.configuration.hdrEnabled)
        XCTAssertEqual(fixture.configuration.gamut.rawValue, 1)
        XCTAssertEqual(fixture.configuration.transfer.rawValue, 1)
        XCTAssertEqual(fixture.configuration.currentPeakLuminanceNits, 120)
        XCTAssertEqual(fixture.configuration.potentialPeakLuminanceNits, 1600)
        XCTAssertNotEqual(fixture.configuration.serialNumber, 0)
        XCTAssertEqual(
            fixture.configuration.serialNumber,
            fixture.matchingConfiguration.serialNumber
        )
        XCTAssertEqual(
            fixture.configuration.productID,
            fixture.matchingConfiguration.productID
        )
        XCTAssertNotEqual(
            [fixture.configuration.productID, fixture.configuration.serialNumber],
            [fixture.distinctConfiguration.productID, fixture.distinctConfiguration.serialNumber]
        )
        XCTAssertNotEqual(
            [fixture.collidingConfiguration.productID, fixture.collidingConfiguration.serialNumber],
            [
                fixture.otherCollidingConfiguration.productID,
                fixture.otherCollidingConfiguration.serialNumber
            ]
        )
    }

    func testWorkspaceRequestBoxSeparatesClientSinkScaleFromHostDisplayMode() throws {
        let box = LumenMacWorkspaceSessionRequestBox()
        box.displayKey = "client-key"
        box.width = 640
        box.height = 360
        box.scalePercent = 200
        box.refreshRate = 120
        box.hdrEnabled = true
        box.clientSinkGamutRawValue = 3
        box.clientSinkTransferRawValue = 2
        box.potentialEDRHeadroom = 16
        box.potentialPeakLuminanceNits = 1600

        let request = box.makeRequest(policy: .isolatedWorkspace)

        XCTAssertEqual(request.displayKey, "client-key")
        XCTAssertEqual(request.policy, .isolatedWorkspace)
        XCTAssertFalse(request.managesCapture)
        XCTAssertEqual(request.displayMode.width, 640)
        XCTAssertEqual(request.displayMode.height, 360)
        XCTAssertEqual(request.displayMode.scalePercent, 100)
        XCTAssertFalse(request.displayMode.dimensionsAreLogical)
        XCTAssertEqual(request.captureConfiguration.sinkRequest.mode.scalePercent, 200)
        XCTAssertTrue(request.captureConfiguration.sinkRequest.mode.hidpi)
        XCTAssertTrue(request.captureConfiguration.usesHDRTransport)
        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)
        let configuration = try LumenMacVirtualDisplayConfigurationFactory.make(
            geometry: geometry,
            request: request
        )
        XCTAssertEqual(configuration.backingWidth, 640)
        XCTAssertEqual(configuration.maximumBackingWidth, 7_680)
        XCTAssertEqual(configuration.maximumBackingHeight, 7_680)
        XCTAssertEqual(configuration.logicalWidth, 640)
        XCTAssertFalse(configuration.highDensity)
        XCTAssertEqual(
            request.captureConfiguration.sinkRequest.capability.potentialPeakLuminanceNits,
            1600
        )
    }

    func testWorkspaceRequestBoxSeparatesCaptureSizeFromSupportedDesktopMirrorMode() throws {
        let box = LumenMacWorkspaceSessionRequestBox()
        box.width = 640
        box.height = 360
        box.scalePercent = 200
        box.desktopMirrorSourceDisplayID = 3

        let request = box.makeRequest(policy: .isolatedWorkspace)

        XCTAssertEqual(
            request.contentSource,
            .desktopMirror(sourceDisplayID: 3)
        )
        XCTAssertEqual(request.captureConfiguration.requestedWidth, 640)
        XCTAssertEqual(request.captureConfiguration.requestedHeight, 360)
        XCTAssertEqual(request.displayMode.width, 1_920)
        XCTAssertEqual(request.displayMode.height, 1_080)
        XCTAssertEqual(request.displayMode.scalePercent, 200)
        XCTAssertFalse(request.displayMode.dimensionsAreLogical)

        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)
        let configuration = try LumenMacVirtualDisplayConfigurationFactory.make(
            geometry: geometry,
            request: request
        )
        XCTAssertEqual(configuration.backingWidth, 1_920)
        XCTAssertEqual(configuration.backingHeight, 1_080)
        XCTAssertEqual(configuration.logicalWidth, 960)
        XCTAssertEqual(configuration.logicalHeight, 540)
        XCTAssertTrue(configuration.highDensity)
    }
}

private struct WorkspaceHDRConfigurationFixture {
    let configuration: LumenMacVirtualDisplayConfiguration
    let matchingConfiguration: LumenMacVirtualDisplayConfiguration
    let distinctConfiguration: LumenMacVirtualDisplayConfiguration
    let collidingConfiguration: LumenMacVirtualDisplayConfiguration
    let otherCollidingConfiguration: LumenMacVirtualDisplayConfiguration
}

private extension LumenWorkspaceConfigurationTests {
    func makeHDRConfigurationFixture() throws -> WorkspaceHDRConfigurationFixture {
        let capture = makeHDRCaptureConfiguration()
        let request = makeHDRRequest(
            displayKey: "hdr-contract-display",
            capture: capture
        )
        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)
        let makeConfiguration = { key in
            try LumenMacVirtualDisplayConfigurationFactory.make(
                geometry: geometry,
                request: self.makeHDRRequest(displayKey: key, capture: capture)
            )
        }
        return try WorkspaceHDRConfigurationFixture(
            configuration: makeConfiguration("hdr-contract-display"),
            matchingConfiguration: makeConfiguration("hdr-contract-display"),
            distinctConfiguration: makeConfiguration("distinct-hdr-contract-display"),
            collidingConfiguration: makeConfiguration("lumen-workspace-100000000326246"),
            otherCollidingConfiguration: makeConfiguration(
                "lumen-workspace-100000001467780"
            )
        )
    }

    func makeHDRCaptureConfiguration() -> LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
            displayID: 0,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    currentEDRHeadroom: 1.2,
                    potentialEDRHeadroom: 16,
                    currentPeakLuminanceNits: 120,
                    potentialPeakLuminanceNits: 1600,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )
    }

    func makeHDRRequest(
        displayKey: String,
        capture: LumenMacCaptureConfiguration
    ) -> LumenMacWorkspaceSessionRequest {
        LumenMacWorkspaceSessionRequest(
            displayKey: displayKey,
            displayMode: LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            ),
            refreshRate: 120,
            captureConfiguration: capture
        )
    }
}
