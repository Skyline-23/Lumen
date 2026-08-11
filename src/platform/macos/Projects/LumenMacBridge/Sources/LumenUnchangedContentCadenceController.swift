import Foundation
import LumenEngineBridge

/// ScreenCaptureKit already reports idle frames and damage rectangles. This
/// wrapper keeps that metadata-driven policy in Rust while exposing a small
/// value result to the capture runtime.
final class LumenUnchangedContentCadenceController: @unchecked Sendable {
    enum Signal: Equatable, Sendable {
        case unknown
        case changed
        case unchanged
        case idle

        var rawValue: UInt32 {
            switch self {
            case .unknown:
                UInt32(LumenContentCadenceSignalUnknown.rawValue)
            case .changed:
                UInt32(LumenContentCadenceSignalChanged.rawValue)
            case .unchanged:
                UInt32(LumenContentCadenceSignalUnchanged.rawValue)
            case .idle:
                UInt32(LumenContentCadenceSignalIdle.rawValue)
            }
        }
    }

    struct Decision: Equatable, Sendable {
        let targetFrameRate: Int
        let changed: Bool
        let lowRateActive: Bool
    }

    private let handle: LumenEngineHandle

    init?(requestedFrameRate: Int) {
        guard requestedFrameRate > 0,
              requestedFrameRate <= Int(UInt32.max) else {
            return nil
        }

        var pointer: OpaquePointer?
        let status = lumen_engine_content_cadence_create(
            LumenContentCadenceRequest(
                requested_frame_rate: UInt32(requestedFrameRate)
            ),
            &pointer
        )
        guard status == LumenEngineStatusOk,
              let pointer else {
            return nil
        }
        handle = LumenEngineHandle(
            pointer,
            destructor: lumen_engine_content_cadence_destroy
        )
    }

    func observe(
        monotonicTimeSeconds: Double,
        signal: Signal,
        pipelineStable: Bool
    ) -> Decision? {
        var decision = LumenContentCadenceDecision(
            target_frame_rate: 0,
            changed: false,
            low_rate_active: false
        )
        let status = lumen_engine_content_cadence_observe(
            handle.rawValue,
            LumenContentCadenceObservation(
                monotonic_time_seconds: monotonicTimeSeconds,
                signal: signal.rawValue,
                pipeline_stable: pipelineStable
            ),
            &decision
        )
        guard status == LumenEngineStatusOk,
              decision.target_frame_rate > 0 else {
            return nil
        }
        return Decision(
            targetFrameRate: Int(decision.target_frame_rate),
            changed: decision.changed,
            lowRateActive: decision.low_rate_active
        )
    }

    /// Wakes the target after a validated reliable host input or motion event
    /// and rebases idle confirmation without changing codec/config generation.
    func wake(monotonicTimeSeconds: Double) -> Decision? {
        var decision = LumenContentCadenceDecision(
            target_frame_rate: 0,
            changed: false,
            low_rate_active: false
        )
        let status = lumen_engine_content_cadence_wake(
            handle.rawValue,
            monotonicTimeSeconds,
            &decision
        )
        guard status == LumenEngineStatusOk,
              decision.target_frame_rate > 0 else {
            return nil
        }
        return Decision(
            targetFrameRate: Int(decision.target_frame_rate),
            changed: decision.changed,
            lowRateActive: decision.low_rate_active
        )
    }

    var targetFrameRate: Int? {
        var target: UInt32 = 0
        let status = lumen_engine_content_cadence_target(
            handle.rawValue,
            &target
        )
        guard status == LumenEngineStatusOk,
              target > 0 else {
            return nil
        }
        return Int(target)
    }
}
