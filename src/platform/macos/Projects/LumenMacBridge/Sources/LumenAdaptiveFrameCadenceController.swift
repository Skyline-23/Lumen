import Foundation
import LumenEngineBridge

/// Swift ownership wrapper for the Rust adaptive source-cadence controller.
///
/// The opaque allocation is kept behind the same `LumenEngineHandle` used by
/// the other Rust-backed stores.  No raw pointer escapes this object, and the
/// destructor therefore runs exactly once when the capture runtime releases
/// its controller.
final class LumenAdaptiveFrameCadenceController: @unchecked Sendable {
    struct Decision: Equatable, Sendable {
        let targetFrameRate: Int
        let changed: Bool
    }

    private let handle: LumenEngineHandle

    init?(requestedFrameRate: Int) {
        guard requestedFrameRate > 0,
              requestedFrameRate <= Int(UInt32.max) else {
            return nil
        }

        var pointer: OpaquePointer?
        let status = lumen_engine_adaptive_frame_cadence_create(
            LumenAdaptiveFrameCadenceRequest(
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
            destructor: lumen_engine_adaptive_frame_cadence_destroy
        )
    }

    func observe(
        monotonicTimeSeconds: Double,
        sourceFrameCount: UInt64,
        outputFrameCount: UInt64,
        pendingDropCount: UInt64,
        callbackLatencyMilliseconds: Double
    ) -> Decision? {
        var decision = LumenAdaptiveFrameCadenceDecision(
            target_frame_rate: 0,
            changed: false
        )
        let status = lumen_engine_adaptive_frame_cadence_observe(
            handle.rawValue,
            LumenAdaptiveFrameCadenceObservation(
                monotonic_time_seconds: monotonicTimeSeconds,
                source_frame_count: sourceFrameCount,
                output_frame_count: outputFrameCount,
                pending_drop_count: pendingDropCount,
                callback_latency_milliseconds: callbackLatencyMilliseconds
            ),
            &decision
        )
        guard status == LumenEngineStatusOk,
              decision.target_frame_rate > 0 else {
            return nil
        }
        return Decision(
            targetFrameRate: Int(decision.target_frame_rate),
            changed: decision.changed
        )
    }

    var targetFrameRate: Int? {
        var target: UInt32 = 0
        let status = lumen_engine_adaptive_frame_cadence_target(
            handle.rawValue,
            &target
        )
        guard status == LumenEngineStatusOk, target > 0 else {
            return nil
        }
        return Int(target)
    }
}
