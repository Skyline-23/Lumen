use lumen_windows_driver_core::{
    lumen_driver_core_dispatch, lumen_driver_core_initial_state, CoreRequest, Operation, Status,
    MAX_ACCESS_UNIT_BYTES, MAX_EVENT_BYTES, PENDING_READ_DEPTH,
};

const OWNER: u64 = 0xA11C_E001;

fn claim() -> (lumen_windows_driver_core::CoreState, u64) {
    let state = lumen_driver_core_initial_state();
    let transition = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::ClaimOwner, OWNER, state.generation),
    );
    assert_eq!(transition.response.status, Status::Ok.raw());
    (transition.state, transition.response.generation)
}

fn ready_encoder() -> (lumen_windows_driver_core::CoreState, u64) {
    let (state, generation) = claim();
    let mut create = CoreRequest::new(Operation::CreateMonitor, OWNER, generation);
    create.arguments = [7, (1920 << 32) | 1080, 120_000, 0, 0];
    let created = lumen_driver_core_dispatch(state, create);
    let started = lumen_driver_core_dispatch(
        created.state,
        CoreRequest::new(Operation::StartEncoder, OWNER, generation),
    );
    assert_eq!(started.response.status, Status::Ok.raw());
    (started.state, generation)
}

#[test]
fn rejects_malformed_version_before_state_change() {
    // Given: an otherwise valid owner claim with a future major ABI version.
    let state = lumen_driver_core_initial_state();
    let mut request = CoreRequest::new(Operation::ClaimOwner, OWNER, state.generation);
    request.header.major += 1;

    // When: the request crosses the Rust boundary.
    let transition = lumen_driver_core_dispatch(state, request);

    // Then: it is rejected without assigning an owner.
    assert_eq!(transition.response.status, Status::InvalidVersion.raw());
    assert_eq!(transition.state.owner_id, 0);
}

#[test]
fn rejects_second_owner_without_disturbing_first_owner() {
    // Given: one claimed driver core.
    let (state, generation) = claim();

    // When: another file identity attempts to claim it.
    let transition = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::ClaimOwner, OWNER + 1, generation),
    );

    // Then: the second owner is busy and the first owner remains authoritative.
    assert_eq!(transition.response.status, Status::Busy.raw());
    assert_eq!(transition.state.owner_id, OWNER);
}

#[test]
fn rejects_oversized_access_unit_and_event_reads() {
    // Given: a live encoder owned by the caller.
    let (state, generation) = ready_encoder();
    let mut access_unit = CoreRequest::new(Operation::DequeueAccessUnit, OWNER, generation);
    access_unit.request_id = 1;
    access_unit.arguments[0] = MAX_ACCESS_UNIT_BYTES + 1;

    // When: an oversized access-unit read and event read are submitted.
    let access_unit_result = lumen_driver_core_dispatch(state, access_unit);
    let mut event = CoreRequest::new(Operation::DequeueEvent, OWNER, generation);
    event.request_id = 2;
    event.arguments[0] = MAX_EVENT_BYTES + 1;
    let event_result = lumen_driver_core_dispatch(access_unit_result.state, event);

    // Then: both fail before either bounded queue changes.
    assert_eq!(access_unit_result.response.status, Status::Oversize.raw());
    assert_eq!(event_result.response.status, Status::Oversize.raw());
    assert_eq!(
        event_result.state.pending_access_unit_reads,
        [0; PENDING_READ_DEPTH]
    );
    assert_eq!(
        event_result.state.pending_event_reads,
        [0; PENDING_READ_DEPTH]
    );
}

#[test]
fn rejects_stale_generation_after_owner_release() {
    // Given: an owner generation that was released and replaced.
    let (state, generation) = claim();
    let released = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::ReleaseOwner, OWNER, generation),
    );
    let reclaimed = lumen_driver_core_dispatch(
        released.state,
        CoreRequest::new(Operation::ClaimOwner, OWNER, released.response.generation),
    );

    // When: the new owner submits a command stamped with the old generation.
    let transition = lumen_driver_core_dispatch(
        reclaimed.state,
        CoreRequest::new(Operation::CreateMonitor, OWNER, generation),
    );

    // Then: the stale request is rejected without a monitor transition.
    assert_eq!(transition.response.status, Status::StaleGeneration.raw());
    assert_eq!(transition.state.monitor_id, 0);
}

#[test]
fn cancels_pending_read_and_enforces_pending_depth() {
    // Given: a live encoder with the maximum number of pending AU reads.
    let (mut state, generation) = ready_encoder();
    for request_id in 1..=u64::try_from(PENDING_READ_DEPTH).expect("depth fits in u64") {
        let mut dequeue = CoreRequest::new(Operation::DequeueAccessUnit, OWNER, generation);
        dequeue.request_id = request_id;
        dequeue.arguments[0] = MAX_ACCESS_UNIT_BYTES;
        let transition = lumen_driver_core_dispatch(state, dequeue);
        assert_eq!(transition.response.status, Status::Pending.raw());
        state = transition.state;
    }

    // When: one more read is submitted and the first pending read is cancelled.
    let mut overflow = CoreRequest::new(Operation::DequeueAccessUnit, OWNER, generation);
    overflow.request_id = 99;
    overflow.arguments[0] = MAX_ACCESS_UNIT_BYTES;
    let full = lumen_driver_core_dispatch(state, overflow);
    let mut cancel = CoreRequest::new(Operation::CancelPending, OWNER, generation);
    cancel.request_id = 1;
    cancel.arguments[0] = 1;
    let cancelled = lumen_driver_core_dispatch(full.state, cancel);

    // Then: admission is bounded and cancellation releases exactly one slot.
    assert_eq!(full.response.status, Status::QueueFull.raw());
    assert_eq!(cancelled.response.status, Status::Cancelled.raw());
    assert_eq!(cancelled.state.pending_access_unit_reads[0], 0);
}

#[test]
fn stop_encoder_clears_only_access_unit_pending_reads() {
    // Given: a live encoder with one pending access-unit read and one event read.
    let (state, generation) = ready_encoder();
    let mut access_unit = CoreRequest::new(Operation::DequeueAccessUnit, OWNER, generation);
    access_unit.request_id = 10;
    access_unit.arguments[0] = MAX_ACCESS_UNIT_BYTES;
    let access_unit_pending = lumen_driver_core_dispatch(state, access_unit);
    let mut event = CoreRequest::new(Operation::DequeueEvent, OWNER, generation);
    event.request_id = 11;
    event.arguments[0] = MAX_EVENT_BYTES;
    let event_pending = lumen_driver_core_dispatch(access_unit_pending.state, event);

    // When: encoder ownership stops without releasing the device owner.
    let stopped = lumen_driver_core_dispatch(
        event_pending.state,
        CoreRequest::new(Operation::StopEncoder, OWNER, generation),
    );

    // Then: AU reads are cancelled by encoder stop while event reads remain pending.
    assert_eq!(stopped.response.status, Status::Ok.raw());
    assert_eq!(
        stopped.state.pending_access_unit_reads,
        [0; PENDING_READ_DEPTH]
    );
    assert_eq!(stopped.state.pending_event_reads[0], 11);
}

#[test]
fn release_owner_resets_pending_reads_and_advances_generation() {
    // Given: an owned live encoder with pending AU and event reads.
    let (state, generation) = ready_encoder();
    let mut access_unit = CoreRequest::new(Operation::DequeueAccessUnit, OWNER, generation);
    access_unit.request_id = 20;
    access_unit.arguments[0] = MAX_ACCESS_UNIT_BYTES;
    let access_unit_pending = lumen_driver_core_dispatch(state, access_unit);
    let mut event = CoreRequest::new(Operation::DequeueEvent, OWNER, generation);
    event.request_id = 21;
    event.arguments[0] = MAX_EVENT_BYTES;
    let event_pending = lumen_driver_core_dispatch(access_unit_pending.state, event);

    // When: the file owner releases the core.
    let released = lumen_driver_core_dispatch(
        event_pending.state,
        CoreRequest::new(Operation::ReleaseOwner, OWNER, generation),
    );

    // Then: both read classes and all lifecycle state reset under one new generation.
    assert_eq!(released.response.status, Status::Ok.raw());
    assert_eq!(released.response.generation, generation + 1);
    assert_eq!(released.state.owner_id, 0);
    assert_eq!(released.state.monitor_id, 0);
    assert_eq!(
        released.state.pending_access_unit_reads,
        [0; PENDING_READ_DEPTH]
    );
    assert_eq!(released.state.pending_event_reads, [0; PENDING_READ_DEPTH]);
}

#[test]
fn pending_read_status_precedence_is_stable() {
    // Given: an owner without an encoder and then a fully ready encoder.
    let (claimed, generation) = claim();
    let mut unavailable = CoreRequest::new(Operation::DequeueAccessUnit, OWNER, generation);
    unavailable.request_id = 30;
    unavailable.arguments[0] = MAX_ACCESS_UNIT_BYTES + 1;
    let unavailable_result = lumen_driver_core_dispatch(claimed, unavailable);
    let (ready, ready_generation) = ready_encoder();

    // When: malformed pending reads violate more than one condition.
    let mut oversized_access_unit =
        CoreRequest::new(Operation::DequeueAccessUnit, OWNER, ready_generation);
    oversized_access_unit.arguments[0] = MAX_ACCESS_UNIT_BYTES + 1;
    let access_unit_result = lumen_driver_core_dispatch(ready, oversized_access_unit);
    let mut oversized_event = CoreRequest::new(Operation::DequeueEvent, OWNER, ready_generation);
    oversized_event.arguments[0] = MAX_EVENT_BYTES + 1;
    let event_result = lumen_driver_core_dispatch(access_unit_result.state, oversized_event);
    let mut invalid_cancel = CoreRequest::new(Operation::CancelPending, OWNER, ready_generation);
    invalid_cancel.request_id = 30;
    invalid_cancel.arguments[0] = 3;
    let cancel_result = lumen_driver_core_dispatch(event_result.state, invalid_cancel);

    // Then: readiness, size, and read-kind checks retain their established order.
    assert_eq!(unavailable_result.response.status, Status::NotReady.raw());
    assert_eq!(access_unit_result.response.status, Status::Oversize.raw());
    assert_eq!(event_result.response.status, Status::Oversize.raw());
    assert_eq!(cancel_result.response.status, Status::InvalidArgument.raw());
}
