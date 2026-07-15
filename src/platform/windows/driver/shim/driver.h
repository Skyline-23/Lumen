#pragma once

#include "lumen_driver_abi.h"

#include <iddcx.h>
#include <wdf.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_6.h>

struct LumenDeviceContext {
  LumenDriverCoreState core_state;
  WDFQUEUE access_unit_queue;
  WDFQUEUE event_queue;
  IDDCX_ADAPTER adapter;
  IDDCX_MONITOR monitor;
  IDXGIFactory7 *adapter_factory;
  ID3D11Device *d3d11_probe_device;
  ID3D12Device *d3d12_probe_device;
  HANDLE adapter_change_event;
  PTP_WAIT adapter_change_wait;
  DWORD adapter_change_cookie;
  WDFWORKITEM adapter_change_work_item;
  volatile LONG adapter_monitoring;
};

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(LumenDeviceContext, LumenGetDeviceContext);

struct LumenAdapterContext {
  WDFDEVICE device;
};

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(LumenAdapterContext, LumenGetAdapterContext);

struct LumenMonitorContext {
  WDFDEVICE device;
  uint64_t monitor_id;
  uint32_t width;
  uint32_t height;
  uint32_t refresh_millihertz;
};

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(LumenMonitorContext, LumenGetMonitorContext);

struct LumenAdapterChangeWorkItemContext {
  WDFDEVICE device;
};

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(
  LumenAdapterChangeWorkItemContext,
  LumenGetAdapterChangeWorkItemContext
);

EVT_WDF_DRIVER_DEVICE_ADD LumenEvtDeviceAdd;
EVT_WDF_OBJECT_CONTEXT_CLEANUP LumenEvtDeviceContextCleanup;
EVT_WDF_DEVICE_FILE_CREATE LumenEvtDeviceFileCreate;
EVT_WDF_FILE_CLEANUP LumenEvtFileCleanup;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL LumenEvtIoDeviceControl;
EVT_WDF_IO_QUEUE_IO_CANCELED_ON_QUEUE LumenEvtIoCancelledOnQueue;
EVT_IDD_CX_PARSE_MONITOR_DESCRIPTION LumenEvtIddCxParseMonitorDescription;
EVT_IDD_CX_ADAPTER_INIT_FINISHED LumenEvtIddCxAdapterInitFinished;
EVT_IDD_CX_ADAPTER_COMMIT_MODES LumenEvtIddCxAdapterCommitModes;
EVT_IDD_CX_MONITOR_GET_DEFAULT_DESCRIPTION_MODES LumenEvtIddCxMonitorGetDefaultDescriptionModes;
EVT_IDD_CX_MONITOR_QUERY_TARGET_MODES LumenEvtIddCxMonitorQueryTargetModes;
EVT_IDD_CX_MONITOR_ASSIGN_SWAPCHAIN LumenEvtIddCxMonitorAssignSwapChain;
EVT_IDD_CX_MONITOR_UNASSIGN_SWAPCHAIN LumenEvtIddCxMonitorUnassignSwapChain;
EVT_WDF_WORKITEM LumenEvtAdapterChangeWorkItem;

uint64_t LumenOwnerId(WDFFILEOBJECT file_object);
LumenDriverCoreRequest LumenRequest(uint32_t operation, uint64_t owner_id, uint64_t generation);
NTSTATUS LumenStatusToNtStatus(uint32_t status);
NTSTATUS LumenInitializeAdapter(WDFDEVICE device, LumenDeviceContext *context);
void LumenStopAdapterMonitoring(LumenDeviceContext *context);
NTSTATUS LumenCompletePendingEvent(LumenDeviceContext *context);
NTSTATUS LumenCreateMonitor(
  LumenDeviceContext *context,
  const LumenDriverCoreRequest &request
);
NTSTATUS LumenRemoveMonitor(LumenDeviceContext *context);
uint64_t LumenPackLuid(LUID luid);
LUID LumenUnpackLuid(uint64_t packed);
