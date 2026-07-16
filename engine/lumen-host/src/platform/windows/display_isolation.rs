use lumen_engine::RecoveryPhase;
use std::time::Duration;

pub(super) const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(10);

pub(super) const fn monitor_required(
    _client_virtual_display: Option<bool>,
    _application_virtual_display: bool,
) -> bool {
    true
}

pub(super) fn first_frame_timed_out(phase: RecoveryPhase, elapsed: Duration) -> bool {
    phase == RecoveryPhase::CaptureStarting && elapsed >= FIRST_FRAME_TIMEOUT
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct DisplayIsolationLifecycle {
    phase: RecoveryPhase,
}

impl DisplayIsolationLifecycle {
    pub(super) const fn new() -> Self {
        Self {
            phase: RecoveryPhase::SnapshotPersisted,
        }
    }

    pub(super) const fn at(phase: RecoveryPhase) -> Self {
        Self { phase }
    }

    pub(super) const fn phase(self) -> RecoveryPhase {
        self.phase
    }

    pub(super) fn transition(
        &mut self,
        expected: RecoveryPhase,
        next: RecoveryPhase,
    ) -> Result<(), &'static str> {
        if self.phase != expected {
            return Err("Windows display lifecycle transition is out of order");
        }
        if !valid_transition(expected, next) {
            return Err("Windows display lifecycle transition is forbidden");
        }
        self.phase = next;
        Ok(())
    }

    pub(super) const fn can_destroy_monitor(self) -> bool {
        matches!(self.phase, RecoveryPhase::RestorationVerified)
    }
}

const fn valid_transition(current: RecoveryPhase, next: RecoveryPhase) -> bool {
    matches!(
        (current, next),
        (
            RecoveryPhase::SnapshotPersisted,
            RecoveryPhase::VirtualCreated | RecoveryPhase::PhysicalRestored
        ) | (
            RecoveryPhase::VirtualCreated,
            RecoveryPhase::VirtualConfigured | RecoveryPhase::PhysicalRestored
        ) | (
            RecoveryPhase::VirtualConfigured,
            RecoveryPhase::CaptureStarting | RecoveryPhase::PhysicalRestored
        ) | (
            RecoveryPhase::CaptureStarting,
            RecoveryPhase::FirstFrameReady | RecoveryPhase::CaptureStopped
        ) | (
            RecoveryPhase::FirstFrameReady,
            RecoveryPhase::IsolationStarted | RecoveryPhase::CaptureStopped
        ) | (
            RecoveryPhase::IsolationStarted,
            RecoveryPhase::Isolated | RecoveryPhase::CaptureStopped
        ) | (RecoveryPhase::Isolated, RecoveryPhase::CaptureStopped)
            | (
                RecoveryPhase::CaptureStopped,
                RecoveryPhase::PhysicalRestored
            )
            | (
                RecoveryPhase::PhysicalRestored,
                RecoveryPhase::RestorationVerified
            )
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn omitted_and_false_client_settings_still_require_the_idd_monitor() {
        // Given: omitted and explicitly false client display settings.
        let requests = [None, Some(false), Some(true)];

        // When: Windows resolves monitor ownership for each stream.
        let required = requests.map(|request| monitor_required(request, false));

        // Then: every request requires the first-party IDD monitor.
        assert_eq!(required, [true, true, true]);
    }

    #[test]
    fn isolation_cannot_start_before_the_first_encoded_frame() {
        // Given: a persisted physical topology with a configured IDD monitor.
        let mut lifecycle = DisplayIsolationLifecycle::new();
        lifecycle
            .transition(
                RecoveryPhase::SnapshotPersisted,
                RecoveryPhase::VirtualCreated,
            )
            .unwrap();
        lifecycle
            .transition(
                RecoveryPhase::VirtualCreated,
                RecoveryPhase::VirtualConfigured,
            )
            .unwrap();
        lifecycle
            .transition(
                RecoveryPhase::VirtualConfigured,
                RecoveryPhase::CaptureStarting,
            )
            .unwrap();

        // When: isolation is requested before first-frame readiness.
        let result = lifecycle.transition(
            RecoveryPhase::FirstFrameReady,
            RecoveryPhase::IsolationStarted,
        );

        // Then: the transition fails and capture remains non-isolated.
        assert!(result.is_err());
        assert_eq!(lifecycle.phase(), RecoveryPhase::CaptureStarting);
    }

    #[test]
    fn monitor_destruction_requires_verified_physical_restoration() {
        // Given: an isolated display lifecycle.
        let lifecycle = DisplayIsolationLifecycle {
            phase: RecoveryPhase::Isolated,
        };

        // When: monitor destruction is considered before recovery verification.
        let allowed = lifecycle.can_destroy_monitor();

        // Then: the IDD monitor must remain until physical restoration verifies.
        assert!(!allowed);
    }

    #[test]
    fn normal_cleanup_restores_and_verifies_before_monitor_destruction() {
        // Given: a stream that reached virtual-only isolation after its first frame.
        let mut lifecycle = DisplayIsolationLifecycle::at(RecoveryPhase::Isolated);

        // When: normal cleanup advances through the durable recovery phases.
        lifecycle
            .transition(RecoveryPhase::Isolated, RecoveryPhase::CaptureStopped)
            .unwrap();
        assert!(!lifecycle.can_destroy_monitor());
        lifecycle
            .transition(
                RecoveryPhase::CaptureStopped,
                RecoveryPhase::PhysicalRestored,
            )
            .unwrap();
        assert!(!lifecycle.can_destroy_monitor());
        lifecycle
            .transition(
                RecoveryPhase::PhysicalRestored,
                RecoveryPhase::RestorationVerified,
            )
            .unwrap();

        // Then: IDD destruction becomes legal only after independent physical verification.
        assert!(lifecycle.can_destroy_monitor());
    }

    #[test]
    fn first_frame_timeout_is_bounded_without_isolating() {
        // Given: capture is waiting at the first-frame barrier.
        let phase = RecoveryPhase::CaptureStarting;

        // When: elapsed time reaches the production deadline.
        let before = first_frame_timed_out(phase, FIRST_FRAME_TIMEOUT - Duration::from_millis(1));
        let expired = first_frame_timed_out(phase, FIRST_FRAME_TIMEOUT);

        // Then: cleanup is requested exactly at the bound, before any isolation phase.
        assert!(!before);
        assert!(expired);
        assert!(!first_frame_timed_out(
            RecoveryPhase::FirstFrameReady,
            FIRST_FRAME_TIMEOUT
        ));
    }
}
