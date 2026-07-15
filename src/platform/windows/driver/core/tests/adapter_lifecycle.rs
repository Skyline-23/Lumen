use lumen_windows_driver_core::{
    lumen_driver_core_dispatch, lumen_driver_core_initial_state, CoreRequest, Operation, Status,
    ADAPTER_DEVICE_D3D11, ADAPTER_DEVICE_D3D12, IDDCX_FEATURE_D3D12,
};

const OWNER: u64 = 0xA11C_E001;
const IDDCX_1_10: u64 = 0x1A80;
const IDDCX_1_11: u64 = 0x1B00;
const SELECTED_LUID: u64 = 0x0000_0002_0000_1234;

fn dispatch(
    state: lumen_windows_driver_core::CoreState,
    operation: Operation,
    arguments: [u64; 5],
) -> lumen_windows_driver_core::CoreTransition {
    let mut request = CoreRequest::new(operation, OWNER, state.generation);
    request.arguments = arguments;
    lumen_driver_core_dispatch(state, request)
}

fn ready_adapter(
    iddcx_version: u64,
    os_features: u64,
    devices: u64,
) -> lumen_windows_driver_core::CoreState {
    let state = lumen_driver_core_initial_state();
    let probed = dispatch(
        state,
        Operation::RecordOsFeatures,
        [iddcx_version, 1, os_features, 0, 0],
    );
    assert_eq!(probed.response.status, Status::Ok.raw());
    let prepared = dispatch(
        probed.state,
        Operation::PrepareAdapter,
        [SELECTED_LUID, devices, 0, 0, 0],
    );
    assert_eq!(prepared.response.status, Status::Ok.raw());
    let initialized = dispatch(
        prepared.state,
        Operation::CompleteAdapterInitialization,
        [1, 0, 0, 0, 0],
    );
    assert_eq!(initialized.response.status, Status::Ok.raw());
    initialized.state
}

fn claimed(state: lumen_windows_driver_core::CoreState) -> lumen_windows_driver_core::CoreState {
    let transition = lumen_driver_core_dispatch(
        state,
        CoreRequest::new(Operation::ClaimOwner, OWNER, state.generation),
    );
    assert_eq!(transition.response.status, Status::Ok.raw());
    transition.state
}

fn with_monitor(
    state: lumen_windows_driver_core::CoreState,
) -> lumen_windows_driver_core::CoreState {
    let state = claimed(state);
    let created = dispatch(
        state,
        Operation::CreateMonitor,
        [7, (1920 << 32) | 1080, 120_000, 0, 0],
    );
    assert_eq!(created.response.status, Status::Ok.raw());
    created.state
}

#[test]
fn rejects_adapter_preparation_before_feature_probe() {
    // Given: an untouched driver core and a valid hardware LUID.
    let state = lumen_driver_core_initial_state();

    // When: adapter selection is attempted before the OS feature probe is recorded.
    let transition = dispatch(
        state,
        Operation::PrepareAdapter,
        [SELECTED_LUID, ADAPTER_DEVICE_D3D11, 0, 0, 0],
    );

    // Then: initialization is rejected without pinning the LUID.
    assert_eq!(transition.response.status, Status::InvalidState.raw());
    assert_eq!(transition.state.render_adapter_luid, 0);
}

#[test]
fn exposes_only_runtime_proven_backend_rows() {
    // Given: IddCx 1.11 with D3D12 reported by the OS and both real devices created.
    let state = ready_adapter(
        IDDCX_1_11,
        IDDCX_FEATURE_D3D12,
        ADAPTER_DEVICE_D3D11 | ADAPTER_DEVICE_D3D12,
    );

    // When: the exact backend rows are queried by stable index.
    let d3d12 = dispatch(state, Operation::QueryBackendCapability, [0, 0, 0, 0, 0]);
    let d3d11 = dispatch(
        d3d12.state,
        Operation::QueryBackendCapability,
        [1, 0, 0, 0, 0],
    );
    let end = dispatch(
        d3d11.state,
        Operation::QueryBackendCapability,
        [2, 0, 0, 0, 0],
    );

    // Then: D3D12-resource and D3D11-texture rows share the selected LUID and no row is inferred.
    assert_eq!(d3d12.response.status, Status::Ok.raw());
    assert_eq!(d3d12.response.values[0], SELECTED_LUID);
    assert_eq!(d3d12.response.values[1] & 0xff, 2);
    assert_eq!(d3d11.response.status, Status::Ok.raw());
    assert_eq!(d3d11.response.values[0], SELECTED_LUID);
    assert_eq!(d3d11.response.values[1] & 0xff, 1);
    assert_eq!(end.response.status, Status::NotReady.raw());
}

#[test]
fn omits_d3d12_when_feature_or_device_probe_is_absent() {
    // Given: one adapter where the OS feature is absent and one where device creation failed.
    let feature_absent = ready_adapter(IDDCX_1_11, 0, ADAPTER_DEVICE_D3D11 | ADAPTER_DEVICE_D3D12);
    let device_absent = ready_adapter(IDDCX_1_11, IDDCX_FEATURE_D3D12, ADAPTER_DEVICE_D3D11);

    // When: their first backend capability rows are queried.
    let feature_result = dispatch(
        feature_absent,
        Operation::QueryBackendCapability,
        [0, 0, 0, 0, 0],
    );
    let device_result = dispatch(
        device_absent,
        Operation::QueryBackendCapability,
        [0, 0, 0, 0, 0],
    );

    // Then: both report D3D11 only, proving enum presence did not advertise D3D12.
    assert_eq!(feature_result.response.values[1] & 0xff, 1);
    assert_eq!(device_result.response.values[1] & 0xff, 1);
}

#[test]
fn rejects_feature_query_failure_and_malformed_luid() {
    // Given: IddCx 1.11 with a failed feature query, then a successful query.
    let state = lumen_driver_core_initial_state();
    let failed_probe = dispatch(
        state,
        Operation::RecordOsFeatures,
        [IDDCX_1_11, 0, IDDCX_FEATURE_D3D12, 0, 0],
    );
    let successful_probe = dispatch(
        state,
        Operation::RecordOsFeatures,
        [IDDCX_1_11, 1, IDDCX_FEATURE_D3D12, 0, 0],
    );
    let unknown_feature = dispatch(
        state,
        Operation::RecordOsFeatures,
        [IDDCX_1_11, 1, IDDCX_FEATURE_D3D12 << 8, 0, 0],
    );

    // When: adapter preparation receives the zero LUID after the successful query.
    let malformed = dispatch(
        successful_probe.state,
        Operation::PrepareAdapter,
        [0, ADAPTER_DEVICE_D3D11, 0, 0, 0],
    );

    // Then: both untrusted runtime facts fail closed with typed statuses.
    assert_eq!(
        failed_probe.response.status,
        Status::FeatureUnavailable.raw()
    );
    assert_eq!(
        unknown_feature.response.status,
        Status::InvalidArgument.raw()
    );
    assert_eq!(malformed.response.status, Status::InvalidArgument.raw());
}

#[test]
fn matching_assignment_is_accepted_and_mismatch_rolls_back() {
    // Given: one initialized adapter with an owned monitor.
    let state = with_monitor(ready_adapter(IDDCX_1_10, 0, ADAPTER_DEVICE_D3D11));

    // When: the OS assigns the selected LUID, it is unassigned, then a different LUID arrives.
    let matching = dispatch(
        state,
        Operation::AssignSwapchain,
        [7, SELECTED_LUID, 0, 0, 0],
    );
    let unassigned = dispatch(
        matching.state,
        Operation::UnassignSwapchain,
        [7, 0, 0, 0, 0],
    );
    let mismatched = dispatch(
        unassigned.state,
        Operation::AssignSwapchain,
        [7, SELECTED_LUID + 1, 0, 0, 0],
    );

    // Then: equality is exact and mismatch retains neither assignment nor a substituted LUID.
    assert_eq!(matching.response.status, Status::Ok.raw());
    assert_eq!(matching.state.assigned_adapter_luid, SELECTED_LUID);
    assert_eq!(mismatched.response.status, Status::LuidMismatch.raw());
    assert_eq!(mismatched.state.assigned_adapter_luid, 0);
    assert_eq!(mismatched.state.render_adapter_luid, SELECTED_LUID);
}

#[test]
fn rejects_hot_reassignment_and_duplicate_monitor() {
    // Given: a monitor with an already assigned matching swap chain.
    let state = with_monitor(ready_adapter(IDDCX_1_10, 0, ADAPTER_DEVICE_D3D11));
    let assigned = dispatch(
        state,
        Operation::AssignSwapchain,
        [7, SELECTED_LUID, 0, 0, 0],
    );

    // When: another assignment and another monitor creation are attempted.
    let reassigned = dispatch(
        assigned.state,
        Operation::AssignSwapchain,
        [7, SELECTED_LUID, 0, 0, 0],
    );
    let duplicate = dispatch(
        assigned.state,
        Operation::CreateMonitor,
        [8, (1280 << 32) | 720, 60_000, 0, 0],
    );

    // Then: both exclusive ownership boundaries remain unchanged.
    assert_eq!(reassigned.response.status, Status::Busy.raw());
    assert_eq!(duplicate.response.status, Status::Busy.raw());
    assert_eq!(duplicate.state.monitor_id, 7);
}

#[test]
fn adapter_removal_rolls_back_monitor_and_assignment() {
    // Given: an initialized monitor with a matching assigned swap chain.
    let state = with_monitor(ready_adapter(IDDCX_1_10, 0, ADAPTER_DEVICE_D3D11));
    let assigned = dispatch(
        state,
        Operation::AssignSwapchain,
        [7, SELECTED_LUID, 0, 0, 0],
    );

    // When: PnP removes the selected render adapter.
    let removed = dispatch(
        assigned.state,
        Operation::AdapterRemoved,
        [SELECTED_LUID, 0, 0, 0, 0],
    );
    let stale_assignment = dispatch(
        removed.state,
        Operation::AssignSwapchain,
        [7, SELECTED_LUID, 0, 0, 0],
    );

    // Then: the lifecycle reports a typed removal and clears all dependent ownership.
    assert_eq!(removed.response.status, Status::DeviceRemoved.raw());
    assert_eq!(removed.state.monitor_id, 0);
    assert_eq!(removed.state.assigned_adapter_luid, 0);
    assert_eq!(removed.state.render_adapter_luid, 0);
    assert_eq!(stale_assignment.response.status, Status::NotReady.raw());
}
