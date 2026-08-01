#include "driver.h"

namespace {
constexpr UINT kLumenModeCount = 1;

void fill_signal_info(
  DISPLAYCONFIG_VIDEO_SIGNAL_INFO *signal,
  const LumenMonitorContext *monitor_context,
  bool monitor_mode
) {
  const UINT refresh_millihertz = monitor_context->refresh_millihertz;
  const UINT height = monitor_context->height;
  const UINT width = monitor_context->width;
  signal->activeSize.cx = width;
  signal->activeSize.cy = height;
  signal->totalSize = signal->activeSize;
  signal->vSyncFreq.Numerator = refresh_millihertz;
  signal->vSyncFreq.Denominator = 1000;
  signal->hSyncFreq.Numerator = refresh_millihertz * height;
  signal->hSyncFreq.Denominator = 1000;
  signal->pixelRate =
    (static_cast<UINT64>(refresh_millihertz) * width * height) / 1000;
  signal->AdditionalSignalInfo.vSyncFreqDivider = monitor_mode ? 0 : 1;
  signal->AdditionalSignalInfo.videoStandard = 255;
  signal->scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
}

IDDCX_MONITOR_MODE make_monitor_mode(
  const LumenMonitorContext *monitor_context
) {
  IDDCX_MONITOR_MODE mode {};
  mode.Size = sizeof(mode);
  mode.Origin = IDDCX_MONITOR_MODE_ORIGIN_DRIVER;
  fill_signal_info(&mode.MonitorVideoSignalInfo, monitor_context, true);
  return mode;
}

IDDCX_TARGET_MODE make_target_mode(
  const LumenMonitorContext *monitor_context
) {
  IDDCX_TARGET_MODE mode {};
  mode.Size = sizeof(mode);
  fill_signal_info(
    &mode.TargetVideoSignalInfo.targetVideoSignalInfo,
    monitor_context,
    false
  );
  return mode;
}
}

NTSTATUS LumenEvtIddCxParseMonitorDescription(
  const IDARG_IN_PARSEMONITORDESCRIPTION *input,
  IDARG_OUT_PARSEMONITORDESCRIPTION *output
) {
  if (input == nullptr || output == nullptr) {
    return STATUS_INVALID_PARAMETER;
  }
  // Lumen reports no EDID data, so this callback is only a defensive boundary
  // for a later OS-provided descriptor. The active mode is supplied through
  // the per-monitor default-mode callback below.
  output->MonitorModeBufferOutputCount = 0;
  output->PreferredMonitorModeIdx = NO_PREFERRED_MODE;
  return input->MonitorDescription.DataSize == 0
    ? STATUS_SUCCESS
    : STATUS_NOT_SUPPORTED;
}

NTSTATUS LumenEvtIddCxAdapterCommitModes(
  IDDCX_ADAPTER,
  const IDARG_IN_COMMITMODES *
) {
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxMonitorGetDefaultDescriptionModes(
  IDDCX_MONITOR monitor,
  const IDARG_IN_GETDEFAULTDESCRIPTIONMODES *input,
  IDARG_OUT_GETDEFAULTDESCRIPTIONMODES *output
) {
  if (monitor == nullptr || input == nullptr || output == nullptr) {
    return STATUS_INVALID_PARAMETER;
  }
  auto *monitor_context = LumenGetMonitorContext(monitor);
  output->DefaultMonitorModeBufferOutputCount = kLumenModeCount;
  output->PreferredMonitorModeIdx = 0;
  if (input->DefaultMonitorModeBufferInputCount >= kLumenModeCount &&
      input->pDefaultMonitorModes != nullptr) {
    input->pDefaultMonitorModes[0] = make_monitor_mode(monitor_context);
  }
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxMonitorQueryTargetModes(
  IDDCX_MONITOR monitor,
  const IDARG_IN_QUERYTARGETMODES *input,
  IDARG_OUT_QUERYTARGETMODES *output
) {
  if (monitor == nullptr || input == nullptr || output == nullptr) {
    return STATUS_INVALID_PARAMETER;
  }
  auto *monitor_context = LumenGetMonitorContext(monitor);
  output->TargetModeBufferOutputCount = kLumenModeCount;
  if (input->TargetModeBufferInputCount >= kLumenModeCount &&
      input->pTargetModes != nullptr) {
    input->pTargetModes[0] = make_target_mode(monitor_context);
  }
  return STATUS_SUCCESS;
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
