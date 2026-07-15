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
  const auto started = lumen_driver_core_dispatch(
    created.state,
    request(LumenDriverOperationStartEncoder, kOwner, state.generation)
  );
  if (!status_is(created, LumenDriverStatusOk) ||
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

  const auto released = lumen_driver_core_dispatch(
    cancelled.state,
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
    return 17;
  }

  std::cout << "{\"malformed_version\":\"rejected\","
               "\"second_owner\":\"busy\",\"oversize\":\"rejected\","
               "\"cancel\":\"cancelled\",\"stale_generation\":\"rejected\"}\n";
  return 0;
}
