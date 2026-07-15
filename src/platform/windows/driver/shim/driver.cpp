#include "driver.h"

extern "C" DRIVER_INITIALIZE DriverEntry;

namespace {
  const GUID kLumenDeviceInterface = LUMEN_DEVICE_INTERFACE_GUID_INIT;

  NTSTATUS create_manual_queue(WDFDEVICE device, WDFQUEUE *queue) {
    WDF_IO_QUEUE_CONFIG config;
    WDF_IO_QUEUE_CONFIG_INIT(&config, WdfIoQueueDispatchManual);
    config.PowerManaged = WdfFalse;
    config.EvtIoCanceledOnQueue = LumenEvtIoCancelledOnQueue;
    return WdfIoQueueCreate(device, &config, WDF_NO_OBJECT_ATTRIBUTES, queue);
  }
}  // namespace

NTSTATUS DriverEntry(PDRIVER_OBJECT driver_object, PUNICODE_STRING registry_path) {
  WDF_DRIVER_CONFIG config;
  WDF_DRIVER_CONFIG_INIT(&config, LumenEvtDeviceAdd);
  return WdfDriverCreate(driver_object, registry_path, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
}

NTSTATUS LumenEvtDeviceAdd(WDFDRIVER, PWDFDEVICE_INIT device_init) {
  IDD_CX_CLIENT_CONFIG iddcx_config;
  IDD_CX_CLIENT_CONFIG_INIT(&iddcx_config);
  iddcx_config.EvtIddCxParseMonitorDescription = LumenEvtIddCxParseMonitorDescription;
  iddcx_config.EvtIddCxAdapterInitFinished = LumenEvtIddCxAdapterInitFinished;
  iddcx_config.EvtIddCxAdapterCommitModes = LumenEvtIddCxAdapterCommitModes;
  iddcx_config.EvtIddCxMonitorGetDefaultDescriptionModes = LumenEvtIddCxMonitorGetDefaultDescriptionModes;
  iddcx_config.EvtIddCxMonitorQueryTargetModes = LumenEvtIddCxMonitorQueryTargetModes;
  iddcx_config.EvtIddCxMonitorAssignSwapChain = LumenEvtIddCxMonitorAssignSwapChain;
  iddcx_config.EvtIddCxMonitorUnassignSwapChain = LumenEvtIddCxMonitorUnassignSwapChain;
  NTSTATUS status = IddCxDeviceInitConfig(device_init, &iddcx_config);
  if (!NT_SUCCESS(status)) {
    return status;
  }

  WDF_FILEOBJECT_CONFIG file_config;
  WDF_FILEOBJECT_CONFIG_INIT(&file_config, LumenEvtDeviceFileCreate, WDF_NO_EVENT_CALLBACK, LumenEvtFileCleanup);
  WdfDeviceInitSetFileObjectConfig(device_init, &file_config, WDF_NO_OBJECT_ATTRIBUTES);

  WDF_IO_TYPE_CONFIG io_config;
  WDF_IO_TYPE_CONFIG_INIT(&io_config);
  io_config.ReadWriteIoType = WdfDeviceIoDirect;
  io_config.DeviceControlIoType = WdfDeviceIoDirect;
  WdfDeviceInitSetIoTypeEx(device_init, &io_config);

  WDF_OBJECT_ATTRIBUTES attributes;
  WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, LumenDeviceContext);
  attributes.ExecutionLevel = WdfExecutionLevelPassive;
  attributes.SynchronizationScope = WdfSynchronizationScopeDevice;

  WDFDEVICE device = nullptr;
  status = WdfDeviceCreate(&device_init, &attributes, &device);
  if (!NT_SUCCESS(status)) {
    return status;
  }

  auto *context = LumenGetDeviceContext(device);
  context->core_state = lumen_driver_core_initial_state();
  context->access_unit_queue = nullptr;
  context->event_queue = nullptr;

  status = IddCxDeviceInitialize(device);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  status = WdfDeviceCreateDeviceInterface(device, &kLumenDeviceInterface, nullptr);
  if (!NT_SUCCESS(status)) {
    return status;
  }

  WDF_IO_QUEUE_CONFIG queue_config;
  WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queue_config, WdfIoQueueDispatchSequential);
  queue_config.EvtIoDeviceControl = LumenEvtIoDeviceControl;
  status = WdfIoQueueCreate(device, &queue_config, WDF_NO_OBJECT_ATTRIBUTES, WDF_NO_HANDLE);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  status = create_manual_queue(device, &context->access_unit_queue);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  return create_manual_queue(device, &context->event_queue);
}

NTSTATUS LumenEvtIddCxAdapterInitFinished(
  IDDCX_ADAPTER,
  const IDARG_IN_ADAPTER_INIT_FINISHED *input
) {
  return input->AdapterInitStatus;
}
