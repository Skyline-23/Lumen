use super::*;

fn command_kinds(
    engine: &mut WorkspaceEngine,
    request: LumenWorkspaceSessionRequest,
) -> Vec<LumenWorkspaceCommandKind> {
    assert_eq!(engine.begin_session(request), LumenEngineStatus::Ok);
    let mut kinds = Vec::new();
    loop {
        let command = match engine.next_command() {
            Ok(command) => command,
            Err(LumenEngineStatus::NoCommand) => break,
            Err(status) => panic!("unexpected status: {status:?}"),
        };
        kinds.push(command.kind);
        assert_eq!(
            engine.complete_command(command, true),
            LumenEngineStatus::Ok
        );
    }
    kinds
}

#[test]
fn isolated_workspace_disconnects_physical_displays_after_first_frame_readiness() {
    // Given: a capture-managed isolated workspace request.
    let mut engine = WorkspaceEngine::default();

    // When: the existing lifecycle is driven to its active state.
    let startup = command_kinds(
        &mut engine,
        LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::IsolatedWorkspace,
            move_target_windows: true,
            manage_capture: true,
        },
    );

    // Then: every current transition is explicit and ordered.
    assert_eq!(
        startup,
        vec![
            LumenWorkspaceCommandKind::SnapshotWorkspace,
            LumenWorkspaceCommandKind::CreateVirtualDisplay,
            LumenWorkspaceCommandKind::ConfigureVirtualDisplay,
            LumenWorkspaceCommandKind::PromoteVirtualMain,
            LumenWorkspaceCommandKind::MoveTargetWindows,
            LumenWorkspaceCommandKind::StartCapture,
            LumenWorkspaceCommandKind::ApplyIsolation,
        ]
    );
    assert_eq!(engine.state, LumenWorkspaceState::Active);
}

#[test]
fn coexist_does_not_mutate_existing_workspace() {
    let mut engine = WorkspaceEngine::default();
    let kinds = command_kinds(
        &mut engine,
        LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::Coexist,
            move_target_windows: false,
            manage_capture: true,
        },
    );

    assert_eq!(
        kinds,
        vec![
            LumenWorkspaceCommandKind::SnapshotWorkspace,
            LumenWorkspaceCommandKind::CreateVirtualDisplay,
            LumenWorkspaceCommandKind::ConfigureVirtualDisplay,
            LumenWorkspaceCommandKind::StartCapture,
        ]
    );
    assert_eq!(engine.state, LumenWorkspaceState::Active);
}

#[test]
fn externally_managed_capture_keeps_workspace_transaction_separate() {
    let mut engine = WorkspaceEngine::default();
    let startup = command_kinds(
        &mut engine,
        LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::Coexist,
            move_target_windows: false,
            manage_capture: false,
        },
    );

    assert!(!startup.contains(&LumenWorkspaceCommandKind::StartCapture));
    assert!(startup.contains(&LumenWorkspaceCommandKind::AwaitExternalFirstEncodedFrame));
    assert_eq!(engine.state, LumenWorkspaceState::Active);
    assert_eq!(engine.end_session(), LumenEngineStatus::Ok);

    let mut teardown = Vec::new();
    while let Ok(command) = engine.next_command() {
        teardown.push(command.kind);
        assert_eq!(
            engine.complete_command(command, true),
            LumenEngineStatus::Ok
        );
    }
    assert_eq!(
        teardown,
        vec![LumenWorkspaceCommandKind::DestroyVirtualDisplay]
    );
    assert_eq!(engine.state, LumenWorkspaceState::Idle);
}

#[test]
fn external_capture_isolates_after_the_typed_first_frame_boundary() {
    let mut engine = WorkspaceEngine::default();
    assert_eq!(
        engine.begin_session(LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::IsolatedWorkspace,
            move_target_windows: false,
            manage_capture: false,
        }),
        LumenEngineStatus::Ok
    );

    for expected in [
        LumenWorkspaceCommandKind::SnapshotWorkspace,
        LumenWorkspaceCommandKind::CreateVirtualDisplay,
        LumenWorkspaceCommandKind::ConfigureVirtualDisplay,
        LumenWorkspaceCommandKind::PromoteVirtualMain,
    ] {
        let command = engine.next_command().expect("preparation command");
        assert_eq!(command.kind, expected);
        assert_eq!(
            engine.complete_command(command, true),
            LumenEngineStatus::Ok
        );
    }

    let barrier = engine.next_command().expect("first-frame barrier");
    assert_eq!(
        barrier.kind,
        LumenWorkspaceCommandKind::AwaitExternalFirstEncodedFrame
    );
    assert_eq!(engine.state, LumenWorkspaceState::Starting);
    assert_eq!(
        engine.complete_command(barrier, true),
        LumenEngineStatus::Ok
    );
    let isolate = engine.next_command().expect("post-first-frame isolation");
    assert_eq!(isolate.kind, LumenWorkspaceCommandKind::ApplyIsolation);
    assert_eq!(
        engine.complete_command(isolate, true),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.next_command(), Err(LumenEngineStatus::NoCommand));
    assert_eq!(engine.state, LumenWorkspaceState::Active);
}

#[test]
fn unavailable_physical_isolation_is_nonfatal_after_virtual_main_promotion() {
    let mut engine = WorkspaceEngine::default();
    assert_eq!(
        engine.begin_session(LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::IsolatedWorkspace,
            move_target_windows: false,
            manage_capture: false,
        }),
        LumenEngineStatus::Ok
    );

    for expected in [
        LumenWorkspaceCommandKind::SnapshotWorkspace,
        LumenWorkspaceCommandKind::CreateVirtualDisplay,
        LumenWorkspaceCommandKind::ConfigureVirtualDisplay,
        LumenWorkspaceCommandKind::PromoteVirtualMain,
    ] {
        let command = engine.next_command().expect("preparation command");
        assert_eq!(command.kind, expected);
        assert_eq!(
            engine.complete_command(command, true),
            LumenEngineStatus::Ok
        );
    }

    let barrier = engine.next_command().expect("first-frame barrier");
    assert_eq!(
        barrier.kind,
        LumenWorkspaceCommandKind::AwaitExternalFirstEncodedFrame
    );
    assert_eq!(
        engine.complete_command(barrier, true),
        LumenEngineStatus::Ok
    );
    let isolate = engine.next_command().expect("post-first-frame isolation");
    assert_eq!(isolate.kind, LumenWorkspaceCommandKind::ApplyIsolation);
    assert_eq!(
        engine.complete_command_with_payload(
            isolate,
            WorkspaceCommandCompletion::physical_mutation_applied(false),
        ),
        LumenEngineStatus::Ok
    );
    assert!(engine.resources.physical_mutation_applied);
    assert_eq!(engine.next_command(), Err(LumenEngineStatus::NoCommand));
    assert_eq!(engine.state, LumenWorkspaceState::Active);
}

#[test]
fn focused_workspace_promotes_and_moves_only_target_windows() {
    let mut engine = WorkspaceEngine::default();
    let kinds = command_kinds(
        &mut engine,
        LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::FocusedWorkspace,
            move_target_windows: false,
            manage_capture: true,
        },
    );

    assert!(kinds.contains(&LumenWorkspaceCommandKind::PromoteVirtualMain));
    assert!(kinds.contains(&LumenWorkspaceCommandKind::MoveTargetWindows));
    assert!(!kinds.contains(&LumenWorkspaceCommandKind::ApplyIsolation));
}

#[test]
fn teardown_stops_capture_before_restore_and_destroy() {
    let mut engine = WorkspaceEngine::default();
    command_kinds(
        &mut engine,
        LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::PromoteVirtualMain,
            move_target_windows: false,
            manage_capture: true,
        },
    );

    assert_eq!(engine.end_session(), LumenEngineStatus::Ok);
    let mut teardown = Vec::new();
    while let Ok(command) = engine.next_command() {
        teardown.push(command.kind);
        assert_eq!(
            engine.complete_command(command, true),
            LumenEngineStatus::Ok
        );
    }

    assert_eq!(
        teardown,
        vec![
            LumenWorkspaceCommandKind::StopCapture,
            LumenWorkspaceCommandKind::RestoreWorkspace,
            LumenWorkspaceCommandKind::VerifyPhysicalDisplays,
            LumenWorkspaceCommandKind::DestroyVirtualDisplay,
        ]
    );
    assert_eq!(engine.state, LumenWorkspaceState::Idle);
}

#[test]
fn startup_failure_recovers_only_resources_that_exist() {
    let mut engine = WorkspaceEngine::default();
    assert_eq!(
        engine.begin_session(LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::IsolatedWorkspace,
            move_target_windows: true,
            manage_capture: true,
        }),
        LumenEngineStatus::Ok
    );

    let snapshot = engine.next_command().unwrap();
    assert_eq!(
        engine.complete_command(snapshot, true),
        LumenEngineStatus::Ok
    );
    let create = engine.next_command().unwrap();
    assert_eq!(engine.complete_command(create, true), LumenEngineStatus::Ok);
    let configure = engine.next_command().unwrap();
    assert_eq!(
        engine.complete_command(configure, false),
        LumenEngineStatus::CommandFailed
    );

    let destroy = engine.next_command().unwrap();
    assert_eq!(
        destroy.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    assert_eq!(
        engine.complete_command(destroy, true),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.state, LumenWorkspaceState::Idle);
    assert_eq!(engine.last_failure, LumenEngineStatus::CommandFailed);
}

#[test]
fn stale_completion_cannot_advance_a_session() {
    let mut engine = WorkspaceEngine::default();
    assert_eq!(
        engine.begin_session(LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::Coexist,
            move_target_windows: false,
            manage_capture: true,
        }),
        LumenEngineStatus::Ok
    );
    let expected = engine.next_command().unwrap();
    let stale = LumenWorkspaceCommand {
        generation: expected.generation.wrapping_sub(1),
        ..expected
    };

    assert_eq!(
        engine.complete_command(stale, true),
        LumenEngineStatus::CommandMismatch
    );
    assert_eq!(engine.awaiting_command(), Some(expected));
}

#[test]
fn cleanup_failure_does_not_loop_or_skip_remaining_cleanup() {
    let mut engine = WorkspaceEngine::default();
    command_kinds(
        &mut engine,
        LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::Coexist,
            move_target_windows: false,
            manage_capture: true,
        },
    );
    assert_eq!(engine.end_session(), LumenEngineStatus::Ok);

    let stop = engine.next_command().unwrap();
    assert_eq!(stop.kind, LumenWorkspaceCommandKind::StopCapture);
    assert_eq!(
        engine.complete_command(stop, false),
        LumenEngineStatus::CommandFailed
    );
    let destroy = engine.next_command().unwrap();
    assert_eq!(
        destroy.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    assert_eq!(
        engine.complete_command(destroy, true),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.next_command(), Err(LumenEngineStatus::NoCommand));
    assert_eq!(engine.state, LumenWorkspaceState::Idle);
    assert_eq!(engine.last_failure, LumenEngineStatus::CommandFailed);
}

#[test]
fn physical_verification_failure_still_destroys_the_owned_virtual_display_once() {
    let mut engine = WorkspaceEngine::default();
    command_kinds(
        &mut engine,
        LumenWorkspaceSessionRequest {
            policy: LumenWorkspacePolicy::FocusedWorkspace,
            move_target_windows: false,
            manage_capture: false,
        },
    );
    assert_eq!(engine.end_session(), LumenEngineStatus::Ok);

    let restore = engine.next_command().unwrap();
    assert_eq!(restore.kind, LumenWorkspaceCommandKind::RestoreWorkspace);
    assert_eq!(
        engine.complete_command(restore, true),
        LumenEngineStatus::Ok
    );
    let verify = engine.next_command().unwrap();
    assert_eq!(
        verify.kind,
        LumenWorkspaceCommandKind::VerifyPhysicalDisplays
    );
    assert_eq!(
        engine.complete_command(verify, false),
        LumenEngineStatus::CommandFailed
    );

    let destroy = engine
        .next_command()
        .expect("virtual display destruction must remain independent");
    assert_eq!(
        destroy.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    assert_eq!(
        engine.complete_command(destroy, true),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.next_command(), Err(LumenEngineStatus::NoCommand));
    assert_eq!(engine.state, LumenWorkspaceState::Stopping);
    assert_eq!(engine.last_failure, LumenEngineStatus::CommandFailed);
}
