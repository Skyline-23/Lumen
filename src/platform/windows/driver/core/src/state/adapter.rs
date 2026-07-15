use crate::{
    CoreRequest, CoreState, CoreTransition, Status, ADAPTER_DEVICE_D3D11, ADAPTER_DEVICE_D3D12,
    ADAPTER_FEATURES_PROBED, ADAPTER_INITIALIZED, ADAPTER_PREPARED, ADAPTER_REMOVED,
    ADAPTER_SWAPCHAIN_ASSIGNED, BACKEND_CAPABILITY_D3D11, BACKEND_CAPABILITY_D3D12, BACKEND_D3D11,
    BACKEND_D3D12, IDDCX_FEATURE_D3D12, IDDCX_VERSION_1_11, STATE_ENCODER_ACTIVE,
    STATE_KEYFRAME_PENDING, STATE_MONITOR_ACTIVE, SURFACE_D3D11_TEXTURE2D, SURFACE_D3D12_RESOURCE,
};

use super::finish;

const KNOWN_OS_FEATURES: u64 = IDDCX_FEATURE_D3D12;
const KNOWN_DEVICE_PROBES: u64 = ADAPTER_DEVICE_D3D11 | ADAPTER_DEVICE_D3D12;

pub(super) fn record_os_features(
    mut state: CoreState,
    request: CoreRequest,
    iddcx_version: u64,
    query_succeeded: u64,
    os_features: u64,
) -> CoreTransition {
    let status = if state.adapter_flags & ADAPTER_FEATURES_PROBED != 0 {
        Status::Busy
    } else if iddcx_version > u64::from(u32::MAX)
        || query_succeeded > 1
        || os_features & !KNOWN_OS_FEATURES != 0
        || (iddcx_version < IDDCX_VERSION_1_11 && os_features != 0)
    {
        Status::InvalidArgument
    } else if iddcx_version >= IDDCX_VERSION_1_11 && query_succeeded == 0 {
        Status::FeatureUnavailable
    } else {
        state.iddcx_version = u32::try_from(iddcx_version).unwrap_or(0);
        state.os_feature_flags = u32::try_from(os_features).unwrap_or(0);
        state.adapter_flags = ADAPTER_FEATURES_PROBED;
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}

pub(super) fn prepare_adapter(
    mut state: CoreState,
    request: CoreRequest,
    selected_luid: u64,
    device_probes: u64,
) -> CoreTransition {
    let d3d12_available = state.os_feature_flags & u32::try_from(IDDCX_FEATURE_D3D12).unwrap_or(0)
        != 0
        && device_probes & ADAPTER_DEVICE_D3D12 != 0;
    let d3d11_available = device_probes & ADAPTER_DEVICE_D3D11 != 0;
    let status = if state.adapter_flags & ADAPTER_FEATURES_PROBED == 0 {
        Status::InvalidState
    } else if state.adapter_flags & ADAPTER_PREPARED != 0 {
        Status::Busy
    } else if selected_luid == 0 || device_probes & !KNOWN_DEVICE_PROBES != 0 {
        Status::InvalidArgument
    } else if !d3d11_available && !d3d12_available {
        Status::FeatureUnavailable
    } else {
        state.render_adapter_luid = selected_luid;
        state.adapter_flags |= ADAPTER_PREPARED;
        state.backend_capability_mask = if d3d11_available {
            BACKEND_CAPABILITY_D3D11
        } else {
            0
        } | if d3d12_available {
            BACKEND_CAPABILITY_D3D12
        } else {
            0
        };
        Status::Ok
    };
    finish(
        state,
        request.header.operation,
        status,
        [selected_luid, u64::from(state.backend_capability_mask)],
    )
}

pub(super) fn complete_initialization(
    mut state: CoreState,
    request: CoreRequest,
    succeeded: u64,
) -> CoreTransition {
    let status = if succeeded > 1 {
        Status::InvalidArgument
    } else if state.adapter_flags & ADAPTER_PREPARED == 0 {
        Status::InvalidState
    } else if state.adapter_flags & ADAPTER_INITIALIZED != 0 {
        Status::Busy
    } else if succeeded == 0 {
        clear_adapter_dependents(&mut state);
        state.adapter_flags |= ADAPTER_REMOVED;
        Status::DeviceRemoved
    } else {
        state.adapter_flags |= ADAPTER_INITIALIZED;
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}

pub(super) fn query_backend(state: CoreState, request: CoreRequest, index: u64) -> CoreTransition {
    let row = capability_at(&state, index);
    match row {
        Some((backend, surface)) => {
            let packed = u64::from(backend)
                | (u64::from(surface) << 8)
                | (1 << 16)
                | (u64::from(capability_count(&state)) << 24)
                | (u64::from(state.iddcx_version) << 32);
            finish(
                state,
                request.header.operation,
                Status::Ok,
                [state.render_adapter_luid, packed],
            )
        }
        None => finish(
            state,
            request.header.operation,
            Status::NotReady,
            [
                state.render_adapter_luid,
                u64::from(capability_count(&state)) << 24,
            ],
        ),
    }
}

pub(super) fn assign_swapchain(
    mut state: CoreState,
    request: CoreRequest,
    monitor_id: u64,
    assigned_luid: u64,
) -> CoreTransition {
    let status = if state.adapter_flags & ADAPTER_INITIALIZED == 0
        || state.flags & STATE_MONITOR_ACTIVE == 0
        || state.monitor_id != monitor_id
    {
        Status::NotReady
    } else if state.adapter_flags & ADAPTER_SWAPCHAIN_ASSIGNED != 0 {
        Status::Busy
    } else if assigned_luid == 0 || assigned_luid != state.render_adapter_luid {
        state.assigned_adapter_luid = 0;
        state.adapter_flags &= !ADAPTER_SWAPCHAIN_ASSIGNED;
        Status::LuidMismatch
    } else {
        state.assigned_adapter_luid = assigned_luid;
        state.adapter_flags |= ADAPTER_SWAPCHAIN_ASSIGNED;
        Status::Ok
    };
    finish(
        state,
        request.header.operation,
        status,
        [assigned_luid, monitor_id],
    )
}

pub(super) fn unassign_swapchain(
    mut state: CoreState,
    request: CoreRequest,
    monitor_id: u64,
) -> CoreTransition {
    let status = if state.monitor_id != monitor_id
        || state.adapter_flags & ADAPTER_SWAPCHAIN_ASSIGNED == 0
    {
        Status::NotReady
    } else {
        state.assigned_adapter_luid = 0;
        state.adapter_flags &= !ADAPTER_SWAPCHAIN_ASSIGNED;
        Status::Ok
    };
    finish(state, request.header.operation, status, [0; 2])
}

pub(super) fn adapter_removed(
    mut state: CoreState,
    request: CoreRequest,
    removed_luid: u64,
) -> CoreTransition {
    let status = if removed_luid == 0 || removed_luid != state.render_adapter_luid {
        Status::InvalidArgument
    } else {
        clear_adapter_dependents(&mut state);
        state.adapter_flags = ADAPTER_FEATURES_PROBED | ADAPTER_REMOVED;
        Status::DeviceRemoved
    };
    finish(state, request.header.operation, status, [removed_luid, 0])
}

fn capability_at(state: &CoreState, index: u64) -> Option<(u32, u32)> {
    let has_d3d12 = state.backend_capability_mask & BACKEND_CAPABILITY_D3D12 != 0;
    let has_d3d11 = state.backend_capability_mask & BACKEND_CAPABILITY_D3D11 != 0;
    match (has_d3d12, has_d3d11, index) {
        (true, _, 0) => Some((BACKEND_D3D12, SURFACE_D3D12_RESOURCE)),
        (true, true, 1) | (false, true, 0) => Some((BACKEND_D3D11, SURFACE_D3D11_TEXTURE2D)),
        (true, true, _) | (true, false, _) | (false, true, _) | (false, false, _) => None,
    }
}

fn capability_count(state: &CoreState) -> u32 {
    let d3d11 = if state.backend_capability_mask & BACKEND_CAPABILITY_D3D11 != 0 {
        1
    } else {
        0
    };
    let d3d12 = if state.backend_capability_mask & BACKEND_CAPABILITY_D3D12 != 0 {
        1
    } else {
        0
    };
    d3d11 + d3d12
}

fn clear_adapter_dependents(state: &mut CoreState) {
    state.render_adapter_luid = 0;
    state.assigned_adapter_luid = 0;
    state.monitor_id = 0;
    state.flags &= !(STATE_MONITOR_ACTIVE | STATE_ENCODER_ACTIVE | STATE_KEYFRAME_PENDING);
    state.adapter_flags = 0;
    state.backend_capability_mask = 0;
    state.pending_access_unit_reads = [0; crate::PENDING_READ_DEPTH];
}
