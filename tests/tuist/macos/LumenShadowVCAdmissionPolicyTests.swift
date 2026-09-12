import CoreMedia
import XCTest
@testable import LumenMacBridge

final class LumenShadowVCAdmissionPolicyTests: XCTestCase {
    func testIdleWakePreservesReceiverPressureAndRestoresFullCadence() {
        var policy = LumenShadowVCAdmissionPolicy(frameRateCeiling: 120)
        XCTAssertTrue(policy.apply(admissionDivisor: 2))
        XCTAssertEqual(policy.targetFrameRate, 60)
        policy.setContentFrameRate(1)
        XCTAssertEqual(policy.targetFrameRate, 1)
        policy.setContentFrameRate(120)
        XCTAssertEqual(policy.targetFrameRate, 60)
        XCTAssertTrue(policy.apply(admissionDivisor: 1))
        XCTAssertEqual(policy.targetFrameRate, 120)
        for tick in 0..<240 {
            XCTAssertTrue(policy.admit(
                sourcePresentationTime: CMTime(value: Int64(tick * 8332), timescale: 1_000_000),
                forceKeyFrame: false))
        }
    }

    func testPressureActsBeforeEncodingAndRepairBypassesPacing() {
        var policy = LumenShadowVCAdmissionPolicy(frameRateCeiling: 120)
        XCTAssertTrue(policy.apply(admissionDivisor: 2))
        XCTAssertTrue(policy.admit(sourcePresentationTime: .zero, forceKeyFrame: false))
        let early = CMTime(value: 1, timescale: 120)
        XCTAssertFalse(policy.admit(sourcePresentationTime: early, forceKeyFrame: false))
        XCTAssertTrue(policy.admit(sourcePresentationTime: early, forceKeyFrame: true))
        XCTAssertFalse(policy.apply(admissionDivisor: 0))
        XCTAssertFalse(policy.apply(admissionDivisor: 5))
        XCTAssertEqual(policy.targetFrameRate, 60)
        policy.setContentFrameRate(1)
        XCTAssertFalse(policy.admit(sourcePresentationTime: CMTime(value: 1, timescale: 2), forceKeyFrame: false))
        policy.setContentFrameRate(120)
        XCTAssertTrue(policy.admit(sourcePresentationTime: CMTime(value: 1, timescale: 2), forceKeyFrame: false))
    }
}
