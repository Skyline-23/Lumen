use crate::{
    CoreRequest, CoreResponse, CoreState, CoreTransition, Operation, Status, ABI_MAGIC, ABI_MAJOR,
    ABI_MINOR, ABI_REQUEST_SIZE, EVENT_QUEUE_DEPTH, FRAME_QUEUE_DEPTH, FRAME_RECORD_BYTES,
    MAX_EVENT_BYTES, PENDING_READ_DEPTH,
};

mod adapter;
mod pending_reads;
mod session;

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
                FRAME_RECORD_BYTES,
                (MAX_EVENT_BYTES << 48)
                    | (FRAME_QUEUE_DEPTH << 32)
                    | (EVENT_QUEUE_DEPTH << 16)
                    | u64::try_from(PENDING_READ_DEPTH).unwrap_or(0),
            ],
        ),
        Operation::QueryBackendCapability => adapter::query_backend(state, request, argument0),
        Operation::RecordOsFeatures => {
            adapter::record_os_features(state, request, argument0, argument1, argument2)
        }
        Operation::PrepareAdapter => adapter::prepare_adapter(state, request, argument0, argument1),
        Operation::CompleteAdapterInitialization => {
            adapter::complete_initialization(state, request, argument0)
        }
        Operation::AssignSwapchain => {
            adapter::assign_swapchain(state, request, argument0, argument1)
        }
        Operation::UnassignSwapchain => adapter::unassign_swapchain(state, request, argument0),
        Operation::AdapterRemoved => adapter::adapter_removed(state, request, argument0),
        Operation::ClaimOwner => session::claim_owner(state, request),
        Operation::ReleaseOwner => {
            if let Err(status) = require_owner(&state, &request) {
                return finish(state, request.header.operation, status, [0; 2]);
            }
            state = session::released_state(state);
            finish(state, request.header.operation, Status::Ok, [0; 2])
        }
        Operation::QueryHealth => health(state, request),
        Operation::CreateMonitor
        | Operation::RemoveMonitor
        | Operation::QueryMonitor
        | Operation::AdoptMonitor
        | Operation::StartEncoder
        | Operation::StopEncoder
        | Operation::RequestKeyframe
        | Operation::DequeueFrame
        | Operation::CompleteFrame
        | Operation::DequeueEvent
        | Operation::CancelPending => {
            if let Err(status) = require_owner_and_generation(&state, &request) {
                return finish(state, request.header.operation, status, [0; 2]);
            }
            match operation {
                Operation::CreateMonitor => {
                    session::create_monitor(state, request, argument0, argument1, argument2)
                }
                Operation::RemoveMonitor => session::remove_monitor(state, request, argument0),
                Operation::QueryMonitor => session::query_monitor(state, request),
                Operation::AdoptMonitor => session::adopt_monitor(state, request, argument0),
                Operation::StartEncoder => session::start_encoder(state, request),
                Operation::StopEncoder => session::stop_encoder(state, request),
                Operation::RequestKeyframe => session::request_keyframe(state, request),
                Operation::DequeueFrame => pending_reads::dequeue_frame(state, request, argument0),
                Operation::CompleteFrame => {
                    pending_reads::complete_frame(state, request, argument0)
                }
                Operation::DequeueEvent => pending_reads::dequeue_event(state, request, argument0),
                Operation::CancelPending => {
                    pending_reads::cancel_pending(state, request, argument0)
                }
                Operation::QueryCapabilities
                | Operation::ClaimOwner
                | Operation::ReleaseOwner
                | Operation::QueryHealth
                | Operation::QueryBackendCapability
                | Operation::RecordOsFeatures
                | Operation::PrepareAdapter
                | Operation::CompleteAdapterInitialization
                | Operation::AssignSwapchain
                | Operation::UnassignSwapchain
                | Operation::AdapterRemoved => finish(
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

fn health(state: CoreState, request: CoreRequest) -> CoreTransition {
    let access_unit_reads = state
        .pending_frame_reads
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

pub(super) fn finish(
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
