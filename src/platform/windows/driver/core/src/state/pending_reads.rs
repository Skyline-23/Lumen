use crate::{
    CoreRequest, CoreState, CoreTransition, Status, MAX_ACCESS_UNIT_BYTES, MAX_EVENT_BYTES,
    PENDING_READ_DEPTH, STATE_ENCODER_ACTIVE,
};

const READ_KIND_ACCESS_UNIT: u64 = 1;
const READ_KIND_EVENT: u64 = 2;

pub(super) fn dequeue_access_unit(
    mut state: CoreState,
    request: CoreRequest,
    capacity: u64,
) -> CoreTransition {
    let status = if state.flags & STATE_ENCODER_ACTIVE == 0 {
        Status::NotReady
    } else if capacity > MAX_ACCESS_UNIT_BYTES {
        Status::Oversize
    } else if capacity == 0 || request.request_id == 0 {
        Status::InvalidArgument
    } else {
        enqueue_pending(&mut state.pending_access_unit_reads, request.request_id)
    };
    super::finish(state, request.header.operation, status, [0; 2])
}

pub(super) fn dequeue_event(
    mut state: CoreState,
    request: CoreRequest,
    capacity: u64,
) -> CoreTransition {
    if capacity > MAX_EVENT_BYTES {
        return super::finish(state, request.header.operation, Status::Oversize, [0; 2]);
    }
    if capacity == 0 || request.request_id == 0 {
        return super::finish(
            state,
            request.header.operation,
            Status::InvalidArgument,
            [0; 2],
        );
    }
    if state.pending_event_code != 0 {
        remove_pending(&mut state.pending_event_reads, request.request_id);
        let values = [
            u64::from(state.pending_event_code),
            state.pending_event_value,
        ];
        state.pending_event_code = 0;
        state.pending_event_value = 0;
        return super::finish(state, request.header.operation, Status::Ok, values);
    }
    let status = enqueue_pending(&mut state.pending_event_reads, request.request_id);
    super::finish(state, request.header.operation, status, [0; 2])
}

pub(super) fn cancel_pending(
    mut state: CoreState,
    request: CoreRequest,
    read_kind: u64,
) -> CoreTransition {
    let pending = match read_kind {
        READ_KIND_ACCESS_UNIT => &mut state.pending_access_unit_reads,
        READ_KIND_EVENT => &mut state.pending_event_reads,
        _ => {
            return super::finish(
                state,
                request.header.operation,
                Status::InvalidArgument,
                [0; 2],
            );
        }
    };
    let status = if remove_pending(pending, request.request_id) {
        Status::Cancelled
    } else {
        Status::NotReady
    };
    super::finish(state, request.header.operation, status, [0; 2])
}

fn enqueue_pending(pending: &mut [u64; PENDING_READ_DEPTH], request_id: u64) -> Status {
    if pending.contains(&request_id) {
        return Status::Busy;
    }
    if let Some(slot) = pending.iter_mut().find(|candidate| **candidate == 0) {
        *slot = request_id;
        Status::Pending
    } else {
        Status::QueueFull
    }
}

fn remove_pending(pending: &mut [u64; PENDING_READ_DEPTH], request_id: u64) -> bool {
    if let Some(slot) = pending
        .iter_mut()
        .find(|candidate| **candidate == request_id)
    {
        *slot = 0;
        true
    } else {
        false
    }
}
