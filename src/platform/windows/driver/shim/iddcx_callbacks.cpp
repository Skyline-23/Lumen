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
  auto validation = LumenRequest(
    LumenDriverOperationValidateAndAbandonSwapchain,
    0,
    context->core_state.generation
  );
  validation.arguments[0] = monitor_context->monitor_id;
  validation.arguments[1] = LumenPackLuid(input->RenderAdapterLuid);
  const auto validated =
    lumen_driver_core_dispatch(context->core_state, validation);
  context->core_state = validated.state;
  return STATUS_GRAPHICS_INDIRECT_DISPLAY_ABANDON_SWAPCHAIN;
}

NTSTATUS LumenEvtIddCxMonitorUnassignSwapChain(IDDCX_MONITOR) {
  return STATUS_SUCCESS;
}
