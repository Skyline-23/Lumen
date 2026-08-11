@testable import LumenMacBridge
import CoreMedia
import ScreenCaptureKit
import XCTest

final class LumenUnchangedContentCadenceTests: XCTestCase {
    func testControllerLowersAfterConfirmationAndEveryActivitySignalRebases() throws {
        let controller = try XCTUnwrap(
            LumenUnchangedContentCadenceController(requestedFrameRate: 120)
        )
        XCTAssertEqual(controller.targetFrameRate, 120)
        XCTAssertEqual(
            controller.observe(
                monotonicTimeSeconds: 0,
                signal: .idle,
                pipelineStable: true
            ),
            .init(targetFrameRate: 120, changed: false, lowRateActive: false)
        )
        XCTAssertEqual(
            controller.observe(
                monotonicTimeSeconds: 1,
                signal: .idle,
                pipelineStable: true
            ),
            .init(targetFrameRate: 2, changed: true, lowRateActive: true)
        )
        XCTAssertEqual(
            controller.observe(
                monotonicTimeSeconds: 1.01,
                signal: .changed,
                pipelineStable: true
            ),
            .init(targetFrameRate: 120, changed: true, lowRateActive: false)
        )
        XCTAssertEqual(
            controller.observe(
                monotonicTimeSeconds: 1.5,
                signal: .unknown,
                pipelineStable: true
            ),
            .init(targetFrameRate: 120, changed: false, lowRateActive: false)
        )
        XCTAssertEqual(
            controller.observe(
                monotonicTimeSeconds: 2,
                signal: .idle,
                pipelineStable: false
            ),
            .init(targetFrameRate: 120, changed: false, lowRateActive: false)
        )
        XCTAssertEqual(
            controller.wake(monotonicTimeSeconds: 2.01),
            .init(targetFrameRate: 120, changed: false, lowRateActive: false)
        )
    }

    func testScreenCaptureMetadataAndSessionEpochClassifyFailOpen() {
        let cases: [(
            SCFrameStatus?,
            Int?,
            LumenUnchangedContentCadenceController.Signal
        )] = [
            (.idle, nil, .idle),
            (.complete, 0, .unchanged),
            (.complete, 1, .changed),
            (.complete, nil, .unknown),
            (.blank, 0, .unknown),
            (nil, nil, .unknown),
        ]
        for (status, dirtyRectCount, expected) in cases {
            XCTAssertEqual(
                LumenScreenCaptureVideoRuntime.unchangedContentCadenceSignal(
                    status: status,
                    dirtyRectCount: dirtyRectCount
                ),
                expected
            )
        }
        XCTAssertTrue(
            LumenScreenCaptureVideoRuntime.isCurrentSessionEpoch(
                requested: 7,
                active: 7
            )
        )
        XCTAssertFalse(
            LumenScreenCaptureVideoRuntime.isCurrentSessionEpoch(
                requested: 6,
                active: 7
            )
        )
    }

    func testContentTargetAndIngressPacerComposeBeforeEncoderAdmission() {
        var delivery = LumenAdaptiveVideoDeliveryPolicyState()
        delivery.beginRunning(bitrateKbps: 20_000, targetFrameRate: 120)
        XCTAssertTrue(
            delivery.admit(
                sourcePresentationTime: .zero,
                forceKeyFrame: false
            ).isAdmitted
        )
        XCTAssertTrue(delivery.setContentTargetFrameRate(2))
        XCTAssertEqual(delivery.targetFrameRate, 2)
        XCTAssertEqual(
            delivery.admit(
                sourcePresentationTime: .zero,
                forceKeyFrame: false
            ),
            .drop
        )

        var ingress = LumenAdaptiveVideoFramePacer(frameRateCeiling: 120)
        XCTAssertTrue(ingress.configure(targetFrameRate: 2))
        XCTAssertTrue(
            ingress.admit(
                sourcePresentationTime: .zero,
                forceKeyFrame: false
            ).isAdmitted
        )
        XCTAssertFalse(
            ingress.admit(
                sourcePresentationTime: CMTime(
                    seconds: 1.0 / 120.0,
                    preferredTimescale: 120
                ),
                forceKeyFrame: false
            ).isAdmitted
        )
        XCTAssertTrue(
            ingress.admit(
                sourcePresentationTime: CMTime(
                    seconds: 0.5,
                    preferredTimescale: 120
                ),
                forceKeyFrame: false
            ).isAdmitted
        )
    }
}
