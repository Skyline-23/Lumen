use lumen_windows_driver_core::{
    lumen_driver_core_dispatch, lumen_driver_core_initial_state, CoreRequest, CoreState, Operation,
    Status, ADAPTER_DEVICE_D3D11, MAX_ACCESS_UNIT_BYTES, PENDING_READ_DEPTH,
};

const OWNER: u64 = 0xA11C_E001;

fn ready_encoder() -> (CoreState, u64) {
    let initial = lumen_driver_core_initial_state();
    let mut feature_probe = CoreRequest::new(Operation::RecordOsFeatures, 0, initial.generation);
    feature_probe.arguments = [0x1A80, 1, 0, 0, 0];
    let probed = lumen_driver_core_dispatch(initial, feature_probe);
    let mut prepare = CoreRequest::new(Operation::PrepareAdapter, 0, initial.generation);
    prepare.arguments = [0x0000_0002_0000_1234, ADAPTER_DEVICE_D3D11, 0, 0, 0];
    let prepared = lumen_driver_core_dispatch(probed.state, prepare);
    let mut complete = CoreRequest::new(
        Operation::CompleteAdapterInitialization,
        0,
        initial.generation,
    );
    complete.arguments[0] = 1;
    let initialized = lumen_driver_core_dispatch(prepared.state, complete);
    let claimed = lumen_driver_core_dispatch(
        initialized.state,
        CoreRequest::new(Operation::ClaimOwner, OWNER, initialized.state.generation),
    );
    let mut create = CoreRequest::new(Operation::CreateMonitor, OWNER, claimed.state.generation);
    create.arguments = [7, (1920 << 32) | 1080, 120_000, 0, 0];
    let created = lumen_driver_core_dispatch(claimed.state, create);
    let started = lumen_driver_core_dispatch(
        created.state,
        CoreRequest::new(Operation::StartEncoder, OWNER, created.state.generation),
    );
    assert_eq!(started.response.status, Status::Ok.raw());
    (started.state, started.response.generation)
}

fn fill_access_unit_reads(mut state: CoreState, generation: u64, base: u64) -> CoreState {
    for offset in 0..u64::try_from(PENDING_READ_DEPTH).expect("depth fits in u64") {
        let mut dequeue = CoreRequest::new(Operation::DequeueAccessUnit, OWNER, generation);
        dequeue.request_id = base + offset;
        dequeue.arguments[0] = MAX_ACCESS_UNIT_BYTES;
        let transition = lumen_driver_core_dispatch(state, dequeue);
        assert_eq!(transition.response.status, Status::Pending.raw());
        state = transition.state;
    }
    state
}

#[test]
fn repeated_stop_start_cycles_restore_full_pending_capacity() {
    // Given: a live encoder whose bounded access-unit read ledger is repeatedly filled.
    let (mut state, generation) = ready_encoder();

    // When: two full pending-read generations are stopped and restarted.
    for cycle in 0..2 {
        state = fill_access_unit_reads(state, generation, cycle * 100 + 1);
        let stopped = lumen_driver_core_dispatch(
            state,
            CoreRequest::new(Operation::StopEncoder, OWNER, generation),
        );
        assert_eq!(stopped.response.status, Status::Ok.raw());
        assert_eq!(
            stopped.state.pending_access_unit_reads,
            [0; PENDING_READ_DEPTH]
        );
        let restarted = lumen_driver_core_dispatch(
            stopped.state,
            CoreRequest::new(Operation::StartEncoder, OWNER, generation),
        );
        assert_eq!(restarted.response.status, Status::Ok.raw());
        state = restarted.state;
    }

    // Then: the next session still admits the complete fixed queue depth.
    let filled = fill_access_unit_reads(state, generation, 1_000);
    assert!(filled.pending_access_unit_reads.iter().all(|id| *id != 0));
}

#[test]
fn stale_session_cancellation_cannot_remove_reused_request_id() {
    // Given: a released owner whose new generation reused an access-unit request identifier.
    let (state, old_generation) = ready_encoder();
    let released = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::ReleaseOwner, OWNER, old_generation),
    );
    let claimed = lumen_driver_core_dispatch(
        released.state,
        CoreRequest::new(Operation::ClaimOwner, OWNER, released.state.generation),
    );
    let mut adopt = CoreRequest::new(Operation::AdoptMonitor, OWNER, claimed.state.generation);
    adopt.arguments[0] = 7;
    let adopted = lumen_driver_core_dispatch(claimed.state, adopt);
    let started = lumen_driver_core_dispatch(
        adopted.state,
        CoreRequest::new(Operation::StartEncoder, OWNER, adopted.state.generation),
    );
    let mut dequeue = CoreRequest::new(
        Operation::DequeueAccessUnit,
        OWNER,
        started.state.generation,
    );
    dequeue.request_id = 77;
    dequeue.arguments[0] = MAX_ACCESS_UNIT_BYTES;
    let pending = lumen_driver_core_dispatch(started.state, dequeue);

    // When: a cancellation from the released generation targets that reused identifier.
    let mut stale_cancel = CoreRequest::new(Operation::CancelPending, OWNER, old_generation);
    stale_cancel.request_id = 77;
    stale_cancel.arguments[0] = 1;
    let cancelled = lumen_driver_core_dispatch(pending.state, stale_cancel);

    // Then: generation validation rejects it and the new session's request remains pending.
    assert_eq!(cancelled.response.status, Status::StaleGeneration.raw());
    assert!(cancelled.state.pending_access_unit_reads.contains(&77));
}
