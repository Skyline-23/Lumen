use crate::{
    CoreRequest, CoreResponse, CoreState, CoreTransition, Operation, Status, ABI_MAGIC, ABI_MAJOR,
    ABI_MINOR, ABI_REQUEST_SIZE, ACCESS_UNIT_QUEUE_DEPTH, EVENT_QUEUE_DEPTH, MAX_ACCESS_UNIT_BYTES,
    MAX_EVENT_BYTES, PENDING_READ_DEPTH, STATE_ENCODER_ACTIVE, STATE_KEYFRAME_PENDING,
    STATE_MONITOR_ACTIVE,
};

mod pending_reads;

pub(crate) fn dispatch(mut state: CoreState, request: CoreRequest) -> CoreTransition {
    let operation = match validate_request(&request) {
        Ok(operation) => operation,
        Err(status) => return finish(state, request.header.operation, status, [0; 2]),
    };
    let [argument0, argument1, argument2, _, _] = request.arguments;
    match operation {
        Operation::QueryCapabilities => finish(
            state,
            request.header.operation,
            Status::Ok,
            [
                MAX_ACCESS_UNIT_BYTES,
                (MAX_EVENT_BYTES << 48)
                    | (ACCESS_UNIT_QUEUE_DEPTH << 32)
                    | (EVENT_QUEUE_DEPTH << 16)
                    | u64::try_from(PENDING_READ_DEPTH).unwrap_or(0),
            ],
        ),
        Operation::ClaimOwner => claim_owner(state, request),
        Operation::ReleaseOwner => {
            if let Err(status) = require_owner(&state, &request) {
                return finish(state, request.header.operation, status, [0; 2]);
            }
            state = CoreState {
                generation: next_generation(state.generation),
                ..CoreState::initial()
            };
            finish(state, request.header.operation, Status::Ok, [0; 2])
        }
        Operation::QueryHealth => health(state, request),
        Operation::CreateMonitor
        | Operation::RemoveMonitor
        | Operation::StartEncoder
        | Operation::StopEncoder
        | Operation::RequestKeyframe
        | Operation::DequeueAccessUnit
        | Operation::DequeueEvent
        | Operation::CancelPending => {
            if let Err(status) = require_owner_and_generation(&state, &request) {
                return finish(state, request.header.operation, status, [0; 2]);
            }
            match operation {
                Operation::CreateMonitor => {
                    create_monitor(state, request, argument0, argument1, argument2)
                }
                Operation::RemoveMonitor => remove_monitor(state, request, argument0),
                Operation::StartEncoder => start_encoder(state, request),
                Operation::StopEncoder => stop_encoder(state, request),
                Operation::RequestKeyframe => request_keyframe(state, request),
                Operation::DequeueAccessUnit => {
                    pending_reads::dequeue_access_unit(state, request, argument0)
                }
                Operation::DequeueEvent => pending_reads::dequeue_event(state, request, argument0),
                Operation::CancelPending => {
                    pending_reads::cancel_pending(state, request, argument0)
                }
                Operation::QueryCapabilities
                | Operation::ClaimOwner
                | Operation::ReleaseOwner
                | Operation::QueryHealth => finish(
                    state,
                    request.header.operation,
                    Status::InvalidArgument,
                    [0; 2],
                ),
            }
        }
    }
}

fn validate_request(request: &CoreRequest) -> Result<Operation, Status> {
    if request.header.magic != ABI_MAGIC
        || request.header.major != ABI_MAJOR
        || request.header.minor > ABI_MINOR
        || request.header.structure_size != ABI_REQUEST_SIZE
    {
        return Err(Status::InvalidVersion);
    }
    Operation::parse(request.header.operation).ok_or(Status::InvalidArgument)
}

fn claim_owner(mut state: CoreState, request: CoreRequest) -> CoreTransition {
    let status = if request.owner_id == 0 {
        Status::InvalidArgument
    } else if state.owner_id == 0 || state.owner_id == request.owner_id {
        state.owner_id = request.owner_id;
        Status::Ok
    } else {
        Status::Busy
    };
    finish(state, request.header.operation, status, [0; 2])
}

fn require_owner(state: &CoreState, request: &CoreRequest) -> Result<(), Status> {
    if request.owner_id != 0 && state.owner_id == request.owner_id {
        Ok(())
    } else {
        Err(Status::AccessDenied)
    }
}

fn require_owner_and_generation(state: &CoreState, request: &CoreRequest) -> Result<(), Status> {
    require_owner(state, request)?;
    if state.generation == request.generation {
        Ok(())
    } else {
        Err(Status::StaleGeneration)
    }
}

fn create_monitor(
    mut state: CoreState,
    request: CoreRequest,
    monitor_id: u64,
    packed_geometry: u64,
    refresh_millihertz: u64,
) -> CoreTransition {
    let width = packed_geometry >> 32;
    let height = packed_geometry & u64::from(u32::MAX);
    let status = if state.flags & STATE_MONITOR_ACTIVE != 0 {
        Status::Busy
    } else if monitor_id == 0 || width == 0 || height == 0 || refresh_millihertz == 0 {
        Status::InvalidArgument
    } else {
        state.monitor_id = monitor_id;
        state.flags |= STATE_MONITOR_ACTIVE;
        Status::Ok
    };
    finish(
        state,
        request.header.operation,
        status,
        [monitor_id, packed_geometry],
    )
}

fn remove_monitor(mut state: CoreState, request: CoreRequest, monitor_id: u64) -> CoreTransition {
    let status = if state.flags & STATE_ENCODER_ACTIVE != 0 {
        Status::InvalidState
    } else if state.flags & STATE_MONITOR_ACTIVE == 0 || state.monitor_id != monitor_id {
        Status::NotReady
    } else {
        state.monitor_id = 0;
        state.flags &= !(STATE_MONITOR_ACTIVE | STATE_KEYFRAME_PENDING);
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}

fn start_encoder(mut state: CoreState, request: CoreRequest) -> CoreTransition {
    let status = if state.flags & STATE_MONITOR_ACTIVE == 0 {
        Status::NotReady
    } else if state.flags & STATE_ENCODER_ACTIVE != 0 {
        Status::Busy
    } else {
        state.flags |= STATE_ENCODER_ACTIVE;
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}

fn stop_encoder(mut state: CoreState, request: CoreRequest) -> CoreTransition {
    let status = if state.flags & STATE_ENCODER_ACTIVE == 0 {
        Status::NotReady
    } else {
        state.flags &= !(STATE_ENCODER_ACTIVE | STATE_KEYFRAME_PENDING);
        state.pending_access_unit_reads = [0; PENDING_READ_DEPTH];
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}

fn request_keyframe(mut state: CoreState, request: CoreRequest) -> CoreTransition {
    let status = if state.flags & STATE_ENCODER_ACTIVE == 0 {
        Status::NotReady
    } else {
        state.flags |= STATE_KEYFRAME_PENDING;
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}

fn health(state: CoreState, request: CoreRequest) -> CoreTransition {
    let access_unit_reads = state
        .pending_access_unit_reads
        .iter()
        .filter(|request_id| **request_id != 0)
        .count();
    let event_reads = state
        .pending_event_reads
        .iter()
        .filter(|request_id| **request_id != 0)
        .count();
    let pending_counts = u64::try_from(access_unit_reads).unwrap_or(0) << 32
        | u64::try_from(event_reads).unwrap_or(0);
    finish(
        state,
        request.header.operation,
        Status::Ok,
        [u64::from(state.flags), pending_counts],
    )
}

fn next_generation(current: u64) -> u64 {
    current.checked_add(1).unwrap_or(1)
}

fn finish(
    mut state: CoreState,
    operation: u32,
    status: Status,
    values: [u64; 2],
) -> CoreTransition {
    state.last_status = status.raw();
    CoreTransition {
        response: CoreResponse {
            header: crate::AbiHeader::response(operation),
            status: status.raw(),
            reserved: 0,
            generation: state.generation,
            values,
        },
        state,
    }
}
