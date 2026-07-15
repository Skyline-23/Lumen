#include "driver.h"

NTSTATUS LumenEvtIddCxParseMonitorDescription(
  const IDARG_IN_PARSEMONITORDESCRIPTION *,
  IDARG_OUT_PARSEMONITORDESCRIPTION *
) {
  return STATUS_NOT_SUPPORTED;
}

NTSTATUS LumenEvtIddCxAdapterCommitModes(
  IDDCX_ADAPTER,
  const IDARG_IN_COMMITMODES *
) {
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxMonitorGetDefaultDescriptionModes(
  IDDCX_MONITOR,
  const IDARG_IN_GETDEFAULTDESCRIPTIONMODES *,
  IDARG_OUT_GETDEFAULTDESCRIPTIONMODES *
) {
  return STATUS_NOT_SUPPORTED;
}

NTSTATUS LumenEvtIddCxMonitorQueryTargetModes(
  IDDCX_MONITOR,
  const IDARG_IN_QUERYTARGETMODES *,
  IDARG_OUT_QUERYTARGETMODES *
) {
  return STATUS_NOT_SUPPORTED;
}

NTSTATUS LumenEvtIddCxMonitorAssignSwapChain(
  IDDCX_MONITOR monitor,
  const IDARG_IN_SETSWAPCHAIN *input
) {
  auto *monitor_context = LumenGetMonitorContext(monitor);
  auto *context = LumenGetDeviceContext(monitor_context->device);
  auto assign = LumenRequest(
    LumenDriverOperationAssignSwapchain,
    0,
    context->core_state.generation
  );
  assign.arguments[0] = monitor_context->monitor_id;
  assign.arguments[1] = LumenPackLuid(input->RenderAdapterLuid);
  const auto assigned = lumen_driver_core_dispatch(context->core_state, assign);
  if (assigned.response.status != LumenDriverStatusOk) {
    context->core_state = assigned.state;
    return STATUS_GRAPHICS_INDIRECT_DISPLAY_ABANDON_SWAPCHAIN;
  }
  auto rollback = LumenRequest(
    LumenDriverOperationUnassignSwapchain,
    0,
    assigned.state.generation
  );
  rollback.arguments[0] = monitor_context->monitor_id;
  context->core_state =
    lumen_driver_core_dispatch(assigned.state, rollback).state;
  return STATUS_GRAPHICS_INDIRECT_DISPLAY_ABANDON_SWAPCHAIN;
}

NTSTATUS LumenEvtIddCxMonitorUnassignSwapChain(IDDCX_MONITOR monitor) {
  auto *monitor_context = LumenGetMonitorContext(monitor);
  auto *context = LumenGetDeviceContext(monitor_context->device);
  auto request = LumenRequest(
    LumenDriverOperationUnassignSwapchain,
    0,
    context->core_state.generation
  );
  request.arguments[0] = monitor_context->monitor_id;
  const auto transition = lumen_driver_core_dispatch(context->core_state, request);
  if (transition.response.status == LumenDriverStatusOk) {
    context->core_state = transition.state;
  }
  return STATUS_SUCCESS;
}
