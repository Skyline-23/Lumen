#include "lumen_driver_abi.h"

#include <cstdint>
#include <iostream>

namespace {
  constexpr uint64_t kOwner = 0xA11CE001u;

  LumenDriverCoreRequest request(uint32_t operation, uint64_t owner, uint64_t generation) {
    LumenDriverCoreRequest value {};
    value.header.magic = LUMEN_DRIVER_ABI_MAGIC;
    value.header.major = LUMEN_DRIVER_ABI_MAJOR;
    value.header.minor = LUMEN_DRIVER_ABI_MINOR;
    value.header.structure_size = sizeof(value);
    value.header.operation = operation;
    value.owner_id = owner;
    value.generation = generation;
    return value;
  }

  bool status_is(const LumenDriverCoreTransition &transition, LumenDriverStatus expected) {
    return transition.response.status == static_cast<uint32_t>(expected);
  }
}  // namespace

int main() {
  auto state = lumen_driver_core_initial_state();

  auto malformed = request(LumenDriverOperationClaimOwner, kOwner, state.generation);
  ++malformed.header.major;
  const auto malformed_result = lumen_driver_core_dispatch(state, malformed);
  if (!status_is(malformed_result, LumenDriverStatusInvalidVersion)) {
    return 10;
  }

  auto features = request(
    LumenDriverOperationRecordOsFeatures,
    0,
    state.generation
  );
  features.arguments[0] = LUMEN_IDDCX_VERSION_1_11;
  features.arguments[1] = 1;
  features.arguments[2] = LUMEN_IDDCX_FEATURE_D3D12;
  const auto feature_result = lumen_driver_core_dispatch(state, features);
  auto prepare = request(
    LumenDriverOperationPrepareAdapter,
    0,
    feature_result.state.generation
  );
  prepare.arguments[0] = 0x0000000200001234ull;
  prepare.arguments[1] =
    LUMEN_ADAPTER_DEVICE_D3D11 | LUMEN_ADAPTER_DEVICE_D3D12;
  const auto prepared = lumen_driver_core_dispatch(feature_result.state, prepare);
  auto initialize = request(
    LumenDriverOperationCompleteAdapterInitialization,
    0,
    prepared.state.generation
  );
  initialize.arguments[0] = 1;
  const auto initialized = lumen_driver_core_dispatch(prepared.state, initialize);
  if (!status_is(feature_result, LumenDriverStatusOk) ||
      !status_is(prepared, LumenDriverStatusOk) ||
      !status_is(initialized, LumenDriverStatusOk)) {
    return 22;
  }
  state = initialized.state;

  auto claimed = lumen_driver_core_dispatch(
    state,
    request(LumenDriverOperationClaimOwner, kOwner, state.generation)
  );
  if (!status_is(claimed, LumenDriverStatusOk)) {
    return 11;
  }
  state = claimed.state;

  const auto second_owner = lumen_driver_core_dispatch(
    state,
    request(LumenDriverOperationClaimOwner, kOwner + 1, state.generation)
  );
  if (!status_is(second_owner, LumenDriverStatusBusy)) {
    return 12;
  }

  auto create =
    request(LumenDriverOperationCreateMonitor, kOwner, state.generation);
  create.arguments[0] = 7;
  create.arguments[1] = (uint64_t {1920} << 32u) | 1080u;
  create.arguments[2] = 120000;
  const auto created = lumen_driver_core_dispatch(state, create);
  auto query_d3d12 = request(
    LumenDriverOperationQueryBackendCapability,
    kOwner,
    created.state.generation
  );
  query_d3d12.arguments[0] = 0;
  const auto d3d12 = lumen_driver_core_dispatch(created.state, query_d3d12);
  auto query_d3d11 = request(
    LumenDriverOperationQueryBackendCapability,
    kOwner,
    d3d12.state.generation
  );
  query_d3d11.arguments[0] = 1;
  const auto d3d11 = lumen_driver_core_dispatch(d3d12.state, query_d3d11);
  auto matching_request = request(
    LumenDriverOperationAssignSwapchain,
    0,
    d3d11.state.generation
  );
  matching_request.arguments[0] = 7;
  matching_request.arguments[1] = 0x0000000200001234ull;
  const auto matching =
    lumen_driver_core_dispatch(d3d11.state, matching_request);
  auto unassign = request(
    LumenDriverOperationUnassignSwapchain,
    0,
    matching.state.generation
  );
  unassign.arguments[0] = 7;
  const auto unassigned = lumen_driver_core_dispatch(matching.state, unassign);
  auto mismatch_request = request(
    LumenDriverOperationAssignSwapchain,
    0,
    unassigned.state.generation
  );
  mismatch_request.arguments[0] = 7;
  mismatch_request.arguments[1] = 0x0000000200001235ull;
  const auto mismatch =
    lumen_driver_core_dispatch(unassigned.state, mismatch_request);
  const auto started = lumen_driver_core_dispatch(
    mismatch.state,
    request(LumenDriverOperationStartEncoder, kOwner, state.generation)
  );
  if (!status_is(created, LumenDriverStatusOk) ||
      !status_is(d3d12, LumenDriverStatusOk) ||
      !status_is(d3d11, LumenDriverStatusOk) ||
      !status_is(matching, LumenDriverStatusOk) ||
      !status_is(unassigned, LumenDriverStatusOk) ||
      !status_is(mismatch, LumenDriverStatusLuidMismatch) ||
      mismatch.state.assigned_adapter_luid != 0 ||
      !status_is(started, LumenDriverStatusOk)) {
    return 13;
  }
  state = started.state;

  auto oversized = request(LumenDriverOperationDequeueAccessUnit, kOwner, state.generation);
  oversized.request_id = 1;
  oversized.arguments[0] = uint64_t {LUMEN_MAX_ACCESS_UNIT_BYTES} + 1;
  const auto oversized_result = lumen_driver_core_dispatch(state, oversized);
  if (!status_is(oversized_result, LumenDriverStatusOversize)) {
    return 14;
  }

  auto pending = request(LumenDriverOperationDequeueAccessUnit, kOwner, state.generation);
  pending.request_id = 2;
  pending.arguments[0] = LUMEN_MAX_ACCESS_UNIT_BYTES;
  const auto pending_result = lumen_driver_core_dispatch(state, pending);
  if (!status_is(pending_result, LumenDriverStatusPending)) {
    return 15;
  }

  auto cancel = request(LumenDriverOperationCancelPending, kOwner, state.generation);
  cancel.request_id = 2;
  cancel.arguments[0] = 1;
  const auto cancelled = lumen_driver_core_dispatch(pending_result.state, cancel);
  if (!status_is(cancelled, LumenDriverStatusCancelled)) {
    return 16;
  }
  state = cancelled.state;

  for (uint64_t cycle = 0; cycle < 2; ++cycle) {
    for (uint64_t slot = 0; slot < LUMEN_PENDING_READ_DEPTH; ++slot) {
      auto queued = request(LumenDriverOperationDequeueAccessUnit, kOwner, state.generation);
      queued.request_id = 100 + cycle * LUMEN_PENDING_READ_DEPTH + slot;
      queued.arguments[0] = LUMEN_MAX_ACCESS_UNIT_BYTES;
      const auto queued_result = lumen_driver_core_dispatch(state, queued);
      if (!status_is(queued_result, LumenDriverStatusPending)) {
        return 17;
      }
      state = queued_result.state;
    }
    const auto stopped = lumen_driver_core_dispatch(
      state,
      request(LumenDriverOperationStopEncoder, kOwner, state.generation)
    );
    if (!status_is(stopped, LumenDriverStatusOk)) {
      return 18;
    }
    for (uint64_t pending_id : stopped.state.pending_access_unit_reads) {
      if (pending_id != 0) {
        return 19;
      }
    }
    const auto restarted = lumen_driver_core_dispatch(
      stopped.state,
      request(LumenDriverOperationStartEncoder, kOwner, stopped.state.generation)
    );
    if (!status_is(restarted, LumenDriverStatusOk)) {
      return 20;
    }
    state = restarted.state;
  }

  const auto released = lumen_driver_core_dispatch(
    state,
    request(LumenDriverOperationReleaseOwner, kOwner, state.generation)
  );
  const auto reclaimed = lumen_driver_core_dispatch(
    released.state,
    request(LumenDriverOperationClaimOwner, kOwner, released.response.generation)
  );
  const auto stale = lumen_driver_core_dispatch(
    reclaimed.state,
    request(LumenDriverOperationCreateMonitor, kOwner, state.generation)
  );
  if (!status_is(stale, LumenDriverStatusStaleGeneration)) {
    return 21;
  }

  std::cout << "{\"selected_luid\":\"0x0000000200001234\","
               "\"capabilities\":[{\"backend\":\"d3d12\",\"surface\":\"resource\"},"
               "{\"backend\":\"d3d11\",\"surface\":\"texture2d\"}],"
               "\"matching_assignment\":\"accepted\","
               "\"mismatched_assignment\":\"luid_mismatch_rollback\","
               "\"malformed_version\":\"rejected\","
               "\"second_owner\":\"busy\",\"oversize\":\"rejected\","
               "\"cancel\":\"cancelled\",\"stop_restart\":\"bounded\","
               "\"stale_generation\":\"rejected\"}\n";
  return 0;
}
