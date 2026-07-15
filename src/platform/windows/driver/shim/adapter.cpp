#include "driver.h"

#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

namespace {
  using Microsoft::WRL::ComPtr;

  const GUID kLumenMonitorContainer =
    {0x89f7cc80, 0x27a5, 0x4a18, {0x95, 0x30, 0x47, 0x5e, 0xd8, 0x31, 0xa8, 0x41}};

  LumenDriverCoreTransition dispatch_internal(
    LumenDeviceContext *context,
    uint32_t operation,
    uint64_t argument0,
    uint64_t argument1,
    uint64_t argument2
  ) {
    auto request = LumenRequest(operation, 0, context->core_state.generation);
    request.arguments[0] = argument0;
    request.arguments[1] = argument1;
    request.arguments[2] = argument2;
    return lumen_driver_core_dispatch(context->core_state, request);
  }

  NTSTATUS record_os_features(LumenDeviceContext *context) {
    const uint64_t version = IddCxGetVersion();
    uint64_t feature_query_succeeded = 1;
    uint64_t features = 0;
    if (version >= LUMEN_IDDCX_VERSION_1_11) {
      IDARG_OUT_FEATURES_SUPPORTED supported {};
      supported.Size = sizeof(supported);
      const NTSTATUS status = IddCxCheckOsFeatureSupport(&supported);
      feature_query_succeeded = NT_SUCCESS(status) ? 1 : 0;
      if (NT_SUCCESS(status) &&
          (supported.Features_1_11 & IDDCX_DEVICE_FEATURES_1_11_D3D12) != 0) {
        features |= LUMEN_IDDCX_FEATURE_D3D12;
      }
    }
    const auto transition = dispatch_internal(
      context,
      LumenDriverOperationRecordOsFeatures,
      version,
      feature_query_succeeded,
      features
    );
    context->core_state = transition.state;
    return LumenStatusToNtStatus(transition.response.status);
  }

  NTSTATUS select_render_adapter(
    uint64_t os_features,
    uint64_t *selected_luid,
    uint64_t *device_probes
  ) {
    ComPtr<IDXGIFactory6> factory;
    HRESULT result = CreateDXGIFactory2(0, IID_PPV_ARGS(factory.GetAddressOf()));
    if (FAILED(result)) {
      return STATUS_NOT_SUPPORTED;
    }
    for (UINT index = 0;; ++index) {
      ComPtr<IDXGIAdapter4> adapter;
      result = factory->EnumAdapterByGpuPreference(
        index,
        DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
        IID_PPV_ARGS(adapter.GetAddressOf())
      );
      if (result == DXGI_ERROR_NOT_FOUND) {
        return STATUS_NOT_SUPPORTED;
      }
      if (FAILED(result)) {
        return STATUS_DEVICE_HARDWARE_ERROR;
      }
      DXGI_ADAPTER_DESC3 description {};
      result = adapter->GetDesc3(&description);
      if (FAILED(result) || (description.Flags & DXGI_ADAPTER_FLAG3_SOFTWARE) != 0) {
        continue;
      }

      uint64_t probes = 0;
      ComPtr<ID3D11Device> d3d11_device;
      ComPtr<ID3D11DeviceContext> d3d11_context;
      const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
      D3D_FEATURE_LEVEL selected_level {};
      result = D3D11CreateDevice(
        adapter.Get(),
        D3D_DRIVER_TYPE_UNKNOWN,
        nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        levels,
        ARRAYSIZE(levels),
        D3D11_SDK_VERSION,
        d3d11_device.GetAddressOf(),
        &selected_level,
        d3d11_context.GetAddressOf()
      );
      if (SUCCEEDED(result)) {
        probes |= LUMEN_ADAPTER_DEVICE_D3D11;
      }

      if ((os_features & LUMEN_IDDCX_FEATURE_D3D12) != 0) {
        ComPtr<ID3D12Device> d3d12_device;
        result = D3D12CreateDevice(
          adapter.Get(),
          D3D_FEATURE_LEVEL_11_0,
          IID_PPV_ARGS(d3d12_device.GetAddressOf())
        );
        if (SUCCEEDED(result)) {
          probes |= LUMEN_ADAPTER_DEVICE_D3D12;
        }
      }
      if (probes == 0) {
        continue;
      }
      *selected_luid = LumenPackLuid(description.AdapterLuid);
      *device_probes = probes;
      return STATUS_SUCCESS;
    }
  }
}

uint64_t LumenPackLuid(LUID luid) {
  return uint64_t {luid.LowPart} |
    (uint64_t {static_cast<uint32_t>(luid.HighPart)} << 32u);
}

LUID LumenUnpackLuid(uint64_t packed) {
  LUID luid {};
  luid.LowPart = static_cast<uint32_t>(packed);
  luid.HighPart = static_cast<LONG>(static_cast<uint32_t>(packed >> 32u));
  return luid;
}

NTSTATUS LumenInitializeAdapter(WDFDEVICE device, LumenDeviceContext *context) {
  NTSTATUS status = IddCxDeviceInitialize(device);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  status = record_os_features(context);
  if (!NT_SUCCESS(status)) {
    return status;
  }

  uint64_t selected_luid = 0;
  uint64_t device_probes = 0;
  status = select_render_adapter(
    context->core_state.os_feature_flags,
    &selected_luid,
    &device_probes
  );
  if (!NT_SUCCESS(status)) {
    return status;
  }
  const auto prepared = dispatch_internal(
    context,
    LumenDriverOperationPrepareAdapter,
    selected_luid,
    device_probes,
    0
  );
  if (prepared.response.status != LumenDriverStatusOk) {
    return LumenStatusToNtStatus(prepared.response.status);
  }
  context->core_state = prepared.state;

  IDDCX_ADAPTER_CAPS caps {};
  caps.Size = sizeof(caps);
  caps.MaxMonitorsSupported = 1;
  WDF_OBJECT_ATTRIBUTES attributes;
  WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, LumenAdapterContext);
  IDARG_IN_ADAPTER_INIT input {};
  input.WdfDevice = device;
  input.pCaps = &caps;
  input.ObjectAttributes = &attributes;
  IDARG_OUT_ADAPTER_INIT output {};
  status = IddCxAdapterInitAsync(&input, &output);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  context->adapter = output.AdapterObject;
  LumenGetAdapterContext(output.AdapterObject)->device = device;
  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtIddCxAdapterInitFinished(
  IDDCX_ADAPTER adapter,
  const IDARG_IN_ADAPTER_INIT_FINISHED *input
) {
  auto *adapter_context = LumenGetAdapterContext(adapter);
  auto *context = LumenGetDeviceContext(adapter_context->device);
  if (!NT_SUCCESS(input->AdapterInitStatus)) {
    const auto failed = dispatch_internal(
      context,
      LumenDriverOperationCompleteAdapterInitialization,
      0,
      0,
      0
    );
    context->core_state = failed.state;
    return input->AdapterInitStatus;
  }

  IDARG_IN_ADAPTERSETRENDERADAPTER render_adapter {};
  render_adapter.PreferredRenderAdapter =
    LumenUnpackLuid(context->core_state.render_adapter_luid);
  IddCxAdapterSetRenderAdapter(adapter, &render_adapter);
  const auto initialized = dispatch_internal(
    context,
    LumenDriverOperationCompleteAdapterInitialization,
    1,
    0,
    0
  );
  context->core_state = initialized.state;
  return LumenStatusToNtStatus(initialized.response.status);
}

NTSTATUS LumenCreateMonitor(
  LumenDeviceContext *context,
  const LumenDriverCoreRequest &request
) {
  if (context->adapter == nullptr || context->monitor != nullptr) {
    return STATUS_INVALID_DEVICE_STATE;
  }
  IDDCX_MONITOR_INFO monitor_info {};
  monitor_info.Size = sizeof(monitor_info);
  monitor_info.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_WIRED;
  monitor_info.ConnectorIndex = 0;
  monitor_info.MonitorDescription.Size = sizeof(monitor_info.MonitorDescription);
  monitor_info.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_EDID;
  monitor_info.MonitorContainerId = kLumenMonitorContainer;
  WDF_OBJECT_ATTRIBUTES attributes;
  WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, LumenMonitorContext);
  IDARG_IN_MONITORCREATE input {};
  input.ObjectAttributes = &attributes;
  input.pMonitorInfo = &monitor_info;
  IDARG_OUT_MONITORCREATE output {};
  NTSTATUS status = IddCxMonitorCreate(context->adapter, &input, &output);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  auto *monitor_context = LumenGetMonitorContext(output.MonitorObject);
  monitor_context->device = LumenGetAdapterContext(context->adapter)->device;
  monitor_context->monitor_id = request.arguments[0];
  monitor_context->width = static_cast<uint32_t>(request.arguments[1] >> 32u);
  monitor_context->height = static_cast<uint32_t>(request.arguments[1]);
  monitor_context->refresh_millihertz = static_cast<uint32_t>(request.arguments[2]);
  status = IddCxMonitorArrival(output.MonitorObject);
  if (!NT_SUCCESS(status)) {
    WdfObjectDelete(output.MonitorObject);
    return status;
  }
  context->monitor = output.MonitorObject;
  return STATUS_SUCCESS;
}

NTSTATUS LumenRemoveMonitor(LumenDeviceContext *context) {
  if (context->monitor == nullptr) {
    return STATUS_DEVICE_NOT_READY;
  }
  const NTSTATUS status = IddCxMonitorDeparture(context->monitor);
  if (NT_SUCCESS(status)) {
    context->monitor = nullptr;
  }
  return status;
}
