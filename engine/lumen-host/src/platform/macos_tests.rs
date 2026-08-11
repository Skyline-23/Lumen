use super::*;
use crate::PlatformRuntimeEventCode;
use std::sync::atomic::{AtomicUsize, Ordering};

static STOP_WORKSPACE_ATTEMPTS: AtomicUsize = AtomicUsize::new(0);

unsafe extern "C" fn fail_workspace_stop_once(
    _key: *const c_char,
    _error: *mut c_char,
    _error_length: usize,
) -> bool {
    STOP_WORKSPACE_ATTEMPTS.fetch_add(1, Ordering::Relaxed) > 0
}

#[test]
fn pending_isolation_keeps_session_start_nonfatal_and_clears_stale_warning() {
    let event = workspace_isolation_event(
        MacWorkspaceActivationResult {
            activated: true,
            isolation_status: 3,
        },
        String::new(),
    )
    .expect("pending isolation remains a valid active session");

    assert_eq!(event.disposition, PlatformRuntimeEventDisposition::Cleared);
    assert_eq!(event.severity, PlatformRuntimeEventSeverity::Warning);
    assert_eq!(
        event.code,
        PlatformRuntimeEventCode::PhysicalDisplayIsolation
    );
}

#[test]
fn unavailable_isolation_is_a_typed_nonfatal_warning() {
    let event = workspace_isolation_event(
        MacWorkspaceActivationResult {
            activated: true,
            isolation_status: 2,
        },
        "display 114 was not published".to_owned(),
    )
    .expect("unavailable isolation must not fail stream startup");

    assert_eq!(event.disposition, PlatformRuntimeEventDisposition::Raised);
    assert_eq!(event.severity, PlatformRuntimeEventSeverity::Warning);
    assert_eq!(
        event.code,
        PlatformRuntimeEventCode::PhysicalDisplayIsolation
    );
    assert_eq!(
        event.message.as_deref(),
        Some("display 114 was not published")
    );
}

#[test]
fn capture_pair_keeps_audio_scheduling_failure_nonfatal() {
    assert_eq!(
        capture_pair_audio_failure(2, "audio route unavailable".to_owned()).unwrap(),
        Some("audio route unavailable".to_owned())
    );
    assert_eq!(capture_pair_audio_failure(0, String::new()).unwrap(), None);
}

#[test]
fn capture_pair_preserves_video_start_failure_as_terminal() {
    assert_eq!(
        capture_pair_audio_failure(1, "capture rejected".to_owned()).unwrap_err(),
        "video capture failed: capture rejected"
    );
}

#[test]
fn incomplete_real_pcm_does_not_advance_audio_clock_or_catch_up() {
    let now = Instant::now();
    let deadline = now - MAXIMUM_AUDIO_CATCHUP - Duration::from_millis(1);
    let packet_bytes = AUDIO_FRAME_COUNT * 2 * std::mem::size_of::<f32>();

    for pcm_length in [0, packet_bytes - std::mem::size_of::<f32>()] {
        let mut state = MacSessionState {
            controller: ptr::null_mut(),
            workspace_key: None,
            display_id: 0,
            input_display_id: 0,
            input_display_bounds: None,
            input_capture_viewport: None,
            desktop_mirror_source_display_id: 0,
            opus: None,
            audio_channels: 2,
            pcm: vec![0; pcm_length],
            audio_scratch: vec![0; MAXIMUM_PCM_BYTES],
            next_audio_timestamp: 42,
            next_audio_deadline: Some(deadline),
            audio_capture_failure: None,
            plan: None,
        };

        assert_eq!(
            ready_audio_packet_deadline(&mut state, now, packet_bytes),
            None
        );
        assert_eq!(state.pcm.len(), pcm_length);
        assert_eq!(state.next_audio_timestamp, 42);
        assert_eq!(state.next_audio_deadline, Some(deadline));
    }
}

#[test]
fn desktop_mirror_source_candidate_requires_desktop_intent_and_virtual_display() {
    assert_eq!(
        desktop_mirror_source_candidate_display_id(true, true, 3).unwrap(),
        3
    );
    assert_eq!(
        desktop_mirror_source_candidate_display_id(false, true, 3).unwrap(),
        0
    );
    assert_eq!(
        desktop_mirror_source_candidate_display_id(true, false, 3).unwrap(),
        0
    );
    assert_eq!(
        desktop_mirror_source_candidate_display_id(true, true, 0).unwrap_err(),
        "macOS desktop capture has no current source display"
    );
}

#[test]
fn explicit_physical_capture_requires_the_current_main_display() {
    assert_eq!(physical_capture_display_id(7).unwrap(), 7);
    assert_eq!(
        physical_capture_display_id(0).unwrap_err(),
        "macOS physical capture has no current source display"
    );
}

#[test]
fn desktop_capture_preserves_the_requested_virtual_topology() {
    assert_eq!(
        mac_capture_topology(true, 3, 7).unwrap(),
        MacCaptureTopology::VirtualWorkspace {
            desktop_mirror_source_display_id: 3,
        }
    );
    assert_eq!(
        mac_capture_topology(true, 0, 7).unwrap(),
        MacCaptureTopology::VirtualWorkspace {
            desktop_mirror_source_display_id: 0,
        }
    );
    assert_eq!(
        mac_capture_topology(false, 3, 7).unwrap(),
        MacCaptureTopology::PhysicalDisplay(7)
    );
}

#[test]
fn dynamic_display_reconfiguration_preserves_capture_topology() {
    assert_eq!(
        dynamic_display_reconfiguration_mode(true, true).unwrap(),
        MacDynamicDisplayReconfigurationMode::RetainedWorkspace
    );
    assert_eq!(
        dynamic_display_reconfiguration_mode(false, false).unwrap(),
        MacDynamicDisplayReconfigurationMode::PhysicalCapture
    );
    for topology in [(true, false), (false, true)] {
        assert_eq!(
            dynamic_display_reconfiguration_mode(topology.0, topology.1).unwrap_err(),
            "dynamic display reconfiguration cannot change the capture topology"
        );
    }
}

#[test]
fn retained_workspace_reconfiguration_stops_capture_before_mutating_display() {
    assert_eq!(
        mac_capture_reconfiguration_steps(MacDynamicDisplayReconfigurationMode::RetainedWorkspace),
        &[
            MacCaptureReconfigurationStep::StopCapturePair,
            MacCaptureReconfigurationStep::ReconfigureWorkspace,
            MacCaptureReconfigurationStep::StartCapturePair,
        ]
    );
}

#[test]
fn physical_reconfiguration_stops_capture_before_restarting_it() {
    assert_eq!(
        mac_capture_reconfiguration_steps(MacDynamicDisplayReconfigurationMode::PhysicalCapture),
        &[
            MacCaptureReconfigurationStep::StopCapturePair,
            MacCaptureReconfigurationStep::StartCapturePair,
        ]
    );
}

#[test]
fn retained_workspace_reconfiguration_commits_the_replacement_display_identity() {
    assert_eq!(
        mac_reconfigured_display_ids(
            MacDynamicDisplayReconfigurationMode::RetainedWorkspace,
            55,
            90,
        ),
        (90, 90)
    );
    assert_eq!(
        mac_reconfigured_display_ids(
            MacDynamicDisplayReconfigurationMode::PhysicalCapture,
            55,
            90,
        ),
        (55, 55)
    );
}

#[test]
fn input_display_id_remains_unselected_until_workspace_prepare_succeeds() {
    assert_eq!(input_display_id_after_workspace_prepare(81, false), 0);
    assert_eq!(input_display_id_after_workspace_prepare(81, true), 81);
    assert!(!session_epoch_matches(None, 81));
    assert!(session_epoch_matches(Some(81), 81));
    assert!(!session_epoch_matches(Some(80), 81));
}

#[test]
fn workspace_request_keeps_the_bridge_layout_stable() {
    assert_eq!(std::mem::size_of::<MacWorkspaceSessionRequest>(), 72);
    assert_eq!(
        std::mem::offset_of!(MacWorkspaceSessionRequest, desktop_mirror_source_display_id),
        68
    );
}

#[test]
fn workspace_display_identity_is_stable_across_session_restarts() {
    assert_eq!(
        CString::new(MACOS_WORKSPACE_DISPLAY_KEY)
            .unwrap()
            .to_str()
            .unwrap(),
        "dev.skyline23.lumen.workspace.primary.v1"
    );
}

#[test]
fn failed_workspace_stop_retains_key_for_cleanup_retry() {
    STOP_WORKSPACE_ATTEMPTS.store(0, Ordering::Relaxed);
    let mut workspace_key = Some(CString::new(MACOS_WORKSPACE_DISPLAY_KEY).unwrap());

    assert!(stop_workspace(&mut workspace_key, fail_workspace_stop_once).is_err());
    assert!(workspace_key.is_some());
    assert_eq!(
        stop_workspace(&mut workspace_key, fail_workspace_stop_once),
        Ok(())
    );
    assert!(workspace_key.is_none());
    assert_eq!(STOP_WORKSPACE_ATTEMPTS.load(Ordering::Relaxed), 2);
}
