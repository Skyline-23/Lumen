#include "driver.h"

namespace {
constexpr UINT kLumenModeCount = 1;

void fill_signal_info(
  DISPLAYCONFIG_VIDEO_SIGNAL_INFO *signal,
  const LumenDriverVideoSignalMode &mode
) {
  signal->activeSize.cx = static_cast<LONG>(mode.width);
  signal->activeSize.cy = static_cast<LONG>(mode.height);
  signal->totalSize = signal->activeSize;
  signal->vSyncFreq.Numerator = mode.vertical_sync_numerator;
  signal->vSyncFreq.Denominator = mode.vertical_sync_denominator;
  signal->hSyncFreq.Numerator = mode.horizontal_sync_numerator;
  signal->hSyncFreq.Denominator = mode.horizontal_sync_denominator;
  signal->pixelRate = mode.pixel_rate;
  signal->AdditionalSignalInfo.vSyncFreqDivider = mode.vertical_sync_divider;
  signal->AdditionalSignalInfo.videoStandard = mode.video_standard;
  signal->scanLineOrdering =
    static_cast<DISPLAYCONFIG_SCANLINE_ORDERING>(mode.scan_line_ordering);
}

LumenDriverVideoSignalMode make_signal_mode(
  uint32_t width,
  uint32_t height,
  uint32_t refresh_millihertz,
  uint32_t vertical_sync_divider
) {
  // Rust owns the shared signal arithmetic. IddCx requires a zero divider for
  // monitor modes and a nonzero divider for target activation modes.
  return lumen_driver_core_build_video_signal_mode(
    width,
    height,
    refresh_millihertz,
    vertical_sync_divider
  );
}

IDDCX_MONITOR_MODE make_monitor_mode(
  uint32_t width,
  uint32_t height,
  uint32_t refresh_millihertz,
  IDDCX_MONITOR_MODE_ORIGIN origin
) {
  IDDCX_MONITOR_MODE mode {};
  mode.Size = sizeof(mode);
  mode.Origin = origin;
  const auto signal = make_signal_mode(
    width,
    height,
    refresh_millihertz,
    0
  );
  fill_signal_info(&mode.MonitorVideoSignalInfo, signal);
  return mode;
}

IDDCX_MONITOR_MODE make_monitor_mode(
  const LumenMonitorContext *monitor_context
) {
  return make_monitor_mode(
    monitor_context->width,
    monitor_context->height,
    monitor_context->refresh_millihertz,
    IDDCX_MONITOR_MODE_ORIGIN_DRIVER
  );
}

IDDCX_TARGET_MODE make_target_mode(
  const LumenMonitorContext *monitor_context
) {
  IDDCX_TARGET_MODE mode {};
  mode.Size = sizeof(mode);
  const auto signal = make_signal_mode(
    monitor_context->width,
    monitor_context->height,
    monitor_context->refresh_millihertz,
    1
  );
  fill_signal_info(&mode.TargetVideoSignalInfo.targetVideoSignalInfo, signal);
  return mode;
}

IDDCX_MONITOR_MODE2 make_monitor_mode2(
  uint32_t width,
  uint32_t height,
  uint32_t refresh_millihertz,
  IDDCX_MONITOR_MODE_ORIGIN origin
) {
  IDDCX_MONITOR_MODE2 mode {};
  mode.Size = sizeof(mode);
  mode.Origin = origin;
  const auto signal = make_signal_mode(
    width,
    height,
    refresh_millihertz,
    0
  );
  fill_signal_info(&mode.MonitorVideoSignalInfo, signal);
  mode.BitsPerComponent.Rgb = IDDCX_BITS_PER_COMPONENT_8;
  return mode;
}

IDDCX_TARGET_MODE2 make_target_mode2(
  const LumenMonitorContext *monitor_context
) {
  IDDCX_TARGET_MODE2 mode {};
  mode.Size = sizeof(mode);
  const auto signal = make_signal_mode(
    monitor_context->width,
    monitor_context->height,
    monitor_context->refresh_millihertz,
    1
  );
  fill_signal_info(&mode.TargetVideoSignalInfo.targetVideoSignalInfo, signal);
  mode.BitsPerComponent.Rgb = IDDCX_BITS_PER_COMPONENT_8;
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
  // The Rust core owns EDID validation/parsing and the signal arithmetic;
  // this boundary only maps the parsed mode into the IddCx structure.
  constexpr UINT kEdidModeCount = 1;
  output->MonitorModeBufferOutputCount = kEdidModeCount;
  output->PreferredMonitorModeIdx = 0;
  if (input->MonitorDescription.DataSize == 0) {
    output->MonitorModeBufferOutputCount = 0;
    output->PreferredMonitorModeIdx = NO_PREFERRED_MODE;
    return STATUS_SUCCESS;
  }
  if (input->MonitorDescription.DataSize != LUMEN_MONITOR_EDID_BYTES ||
      input->MonitorDescription.pData == nullptr) {
    return STATUS_INVALID_PARAMETER;
  }
  LumenDriverMonitorEdidMode parsed_mode {};
  if (lumen_driver_core_parse_monitor_edid(
        static_cast<const uint8_t *>(input->MonitorDescription.pData),
        input->MonitorDescription.DataSize,
        &parsed_mode
      ) != LUMEN_EDID_STATUS_OK) {
    return STATUS_INVALID_PARAMETER;
  }
  if (input->MonitorModeBufferInputCount == 0) {
    return STATUS_SUCCESS;
  }
  if (input->MonitorModeBufferInputCount < kEdidModeCount ||
      input->pMonitorModes == nullptr) {
    return STATUS_BUFFER_TOO_SMALL;
  }
  input->pMonitorModes[0] = make_monitor_mode(
    parsed_mode.width,
    parsed_mode.height,
    parsed_mode.refresh_millihertz,
    IDDCX_MONITOR_MODE_ORIGIN_MONITORDESCRIPTOR
  );
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxAdapterCommitModes(
  IDDCX_ADAPTER,
  const IDARG_IN_COMMITMODES *
) {
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxAdapterQueryTargetInfo(
  IDDCX_ADAPTER adapter,
  IDARG_IN_QUERYTARGET_INFO *input,
  IDARG_OUT_QUERYTARGET_INFO *output
) {
  if (adapter == nullptr || input == nullptr || output == nullptr) {
    return STATUS_INVALID_PARAMETER;
  }
  output->TargetCaps = IDDCX_TARGET_CAPS_NONE;
  output->DitheringSupport.Rgb = IDDCX_BITS_PER_COMPONENT_8;
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxAdapterCommitModes2(
  IDDCX_ADAPTER,
  const IDARG_IN_COMMITMODES2 *
) {
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxParseMonitorDescription2(
  const IDARG_IN_PARSEMONITORDESCRIPTION2 *input,
  IDARG_OUT_PARSEMONITORDESCRIPTION *output
) {
  if (input == nullptr || output == nullptr) {
    return STATUS_INVALID_PARAMETER;
  }
  output->MonitorModeBufferOutputCount = kLumenModeCount;
  output->PreferredMonitorModeIdx = 0;
  if (input->MonitorDescription.DataSize == 0) {
    output->MonitorModeBufferOutputCount = 0;
    output->PreferredMonitorModeIdx = NO_PREFERRED_MODE;
    return STATUS_SUCCESS;
  }
  if (input->MonitorDescription.DataSize != LUMEN_MONITOR_EDID_BYTES ||
      input->MonitorDescription.pData == nullptr) {
    return STATUS_INVALID_PARAMETER;
  }
  LumenDriverMonitorEdidMode parsed_mode {};
  if (lumen_driver_core_parse_monitor_edid(
        static_cast<const uint8_t *>(input->MonitorDescription.pData),
        input->MonitorDescription.DataSize,
        &parsed_mode
      ) != LUMEN_EDID_STATUS_OK) {
    return STATUS_INVALID_PARAMETER;
  }
  if (input->MonitorModeBufferInputCount == 0) {
    return STATUS_SUCCESS;
  }
  if (input->MonitorModeBufferInputCount < kLumenModeCount ||
      input->pMonitorModes == nullptr) {
    return STATUS_BUFFER_TOO_SMALL;
  }
  input->pMonitorModes[0] = make_monitor_mode2(
    parsed_mode.width,
    parsed_mode.height,
    parsed_mode.refresh_millihertz,
    IDDCX_MONITOR_MODE_ORIGIN_MONITORDESCRIPTOR
  );
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

NTSTATUS LumenEvtIddCxMonitorQueryTargetModes2(
  IDDCX_MONITOR monitor,
  const IDARG_IN_QUERYTARGETMODES2 *input,
  IDARG_OUT_QUERYTARGETMODES *output
) {
  if (monitor == nullptr || input == nullptr || output == nullptr) {
    return STATUS_INVALID_PARAMETER;
  }
  auto *monitor_context = LumenGetMonitorContext(monitor);
  output->TargetModeBufferOutputCount = kLumenModeCount;
  if (input->TargetModeBufferInputCount >= kLumenModeCount &&
      input->pTargetModes != nullptr) {
    input->pTargetModes[0] = make_target_mode2(monitor_context);
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
