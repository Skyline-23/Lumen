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
  auto assignment = LumenRequest(
    LumenDriverOperationAssignSwapchain,
    0,
    context->core_state.generation
  );
  assignment.arguments[0] = monitor_context->monitor_id;
  assignment.arguments[1] = LumenPackLuid(input->RenderAdapterLuid);
  const auto assigned = lumen_driver_core_dispatch(context->core_state, assignment);
  if (assigned.response.status != LumenDriverStatusOk) {
    return LumenStatusToNtStatus(assigned.response.status);
  }
  context->core_state = assigned.state;
  const NTSTATUS status = LumenAssignSwapChain(context, monitor_context, input);
  if (!NT_SUCCESS(status)) {
    LumenUnassignSwapChain(context, monitor_context->monitor_id);
    return STATUS_GRAPHICS_INDIRECT_DISPLAY_ABANDON_SWAPCHAIN;
  }
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxMonitorUnassignSwapChain(IDDCX_MONITOR monitor) {
  auto *monitor_context = LumenGetMonitorContext(monitor);
  auto *context = LumenGetDeviceContext(monitor_context->device);
  return LumenUnassignSwapChain(context, monitor_context->monitor_id);
}
