use crate::{
    CoreRequest, CoreState, CoreTransition, Status, ADAPTER_INITIALIZED,
    ADAPTER_SWAPCHAIN_ASSIGNED, PENDING_READ_DEPTH, STATE_ENCODER_ACTIVE, STATE_KEYFRAME_PENDING,
    STATE_MONITOR_ACTIVE,
};

use super::finish;

pub(super) fn claim_owner(mut state: CoreState, request: CoreRequest) -> CoreTransition {
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

pub(super) fn released_state(state: CoreState) -> CoreState {
    CoreState {
        generation: state.generation.checked_add(1).unwrap_or(1),
        render_adapter_luid: state.render_adapter_luid,
        assigned_adapter_luid: 0,
        iddcx_version: state.iddcx_version,
        os_feature_flags: state.os_feature_flags,
        adapter_flags: state.adapter_flags & !ADAPTER_SWAPCHAIN_ASSIGNED,
        backend_capability_mask: state.backend_capability_mask,
        ..CoreState::initial()
    }
}

pub(super) fn create_monitor(
    mut state: CoreState,
    request: CoreRequest,
    monitor_id: u64,
    packed_geometry: u64,
    refresh_millihertz: u64,
) -> CoreTransition {
    let width = packed_geometry >> 32;
    let height = packed_geometry & u64::from(u32::MAX);
    let status = if state.adapter_flags & ADAPTER_INITIALIZED == 0 {
        Status::NotReady
    } else if state.flags & STATE_MONITOR_ACTIVE != 0 {
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

pub(super) fn remove_monitor(
    mut state: CoreState,
    request: CoreRequest,
    monitor_id: u64,
) -> CoreTransition {
    let status = if state.adapter_flags & ADAPTER_SWAPCHAIN_ASSIGNED != 0
        || state.flags & STATE_ENCODER_ACTIVE != 0
    {
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

pub(super) fn start_encoder(mut state: CoreState, request: CoreRequest) -> CoreTransition {
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

pub(super) fn stop_encoder(mut state: CoreState, request: CoreRequest) -> CoreTransition {
    let status = if state.flags & STATE_ENCODER_ACTIVE == 0 {
        Status::NotReady
    } else {
        state.flags &= !(STATE_ENCODER_ACTIVE | STATE_KEYFRAME_PENDING);
        state.pending_access_unit_reads = [0; PENDING_READ_DEPTH];
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}

pub(super) fn request_keyframe(mut state: CoreState, request: CoreRequest) -> CoreTransition {
    let status = if state.flags & STATE_ENCODER_ACTIVE == 0 {
        Status::NotReady
    } else {
        state.flags |= STATE_KEYFRAME_PENDING;
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}
