#include "driver.h"

#include <evntprov.h>

extern "C" DRIVER_INITIALIZE DriverEntry;

namespace {
  const GUID kLumenDeviceInterface = LUMEN_DEVICE_INTERFACE_GUID_INIT;
  const GUID kLumenInitializationTraceProvider = {
    0x9e0fd0ea,
    0xd1f4,
    0x4aa5,
    {0x8c, 0xf2, 0x72, 0x64, 0x21, 0xd1, 0x04, 0x9b}
  };

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
  const NTSTATUS status = WdfDriverCreate(
    driver_object,
    registry_path,
    WDF_NO_OBJECT_ATTRIBUTES,
    &config,
    WDF_NO_HANDLE
  );
  return NT_SUCCESS(status) ? status : LumenReportInitializationFailure(L"WdfDriverCreate", status);
}

NTSTATUS LumenReportInitializationFailure(PCWSTR stage, NTSTATUS status) {
  REGHANDLE trace_handle = 0;
  if (EventRegister(
        &kLumenInitializationTraceProvider,
        nullptr,
        nullptr,
        &trace_handle
      ) == ERROR_SUCCESS) {
    EventWriteString(trace_handle, 0, 0, stage);
    EventUnregister(trace_handle);
  }

  HANDLE source = RegisterEventSourceW(nullptr, L"LumenIddCx");
  if (source != nullptr) {
    LPCWSTR strings[] = {stage};
    ReportEventW(
      source,
      EVENTLOG_ERROR_TYPE,
      0,
      0x1000,
      nullptr,
      ARRAYSIZE(strings),
      sizeof(status),
      strings,
      &status
    );
    DeregisterEventSource(source);
  }
  return status;
}

NTSTATUS LumenEvtDeviceAdd(WDFDRIVER, PWDFDEVICE_INIT device_init) {
  WDF_PNPPOWER_EVENT_CALLBACKS power_callbacks;
  WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&power_callbacks);
  power_callbacks.EvtDeviceD0Entry = LumenEvtDeviceD0Entry;
  WdfDeviceInitSetPnpPowerEventCallbacks(device_init, &power_callbacks);

  IDD_CX_CLIENT_CONFIG iddcx_config;
  IDD_CX_CLIENT_CONFIG_INIT(&iddcx_config);
  iddcx_config.EvtIddCxDeviceIoControl = LumenEvtIddCxDeviceIoControl;
  iddcx_config.EvtIddCxParseMonitorDescription = LumenEvtIddCxParseMonitorDescription;
  iddcx_config.EvtIddCxAdapterInitFinished = LumenEvtIddCxAdapterInitFinished;
  iddcx_config.EvtIddCxAdapterCommitModes = LumenEvtIddCxAdapterCommitModes;
  iddcx_config.EvtIddCxMonitorGetDefaultDescriptionModes = LumenEvtIddCxMonitorGetDefaultDescriptionModes;
  iddcx_config.EvtIddCxMonitorQueryTargetModes = LumenEvtIddCxMonitorQueryTargetModes;
  iddcx_config.EvtIddCxMonitorAssignSwapChain = LumenEvtIddCxMonitorAssignSwapChain;
  iddcx_config.EvtIddCxMonitorUnassignSwapChain = LumenEvtIddCxMonitorUnassignSwapChain;
  NTSTATUS status = IddCxDeviceInitConfig(device_init, &iddcx_config);
  if (!NT_SUCCESS(status)) {
    return LumenReportInitializationFailure(L"IddCxDeviceInitConfig", status);
  }

  WDF_FILEOBJECT_CONFIG file_config;
  WDF_FILEOBJECT_CONFIG_INIT(&file_config, LumenEvtDeviceFileCreate, WDF_NO_EVENT_CALLBACK, LumenEvtFileCleanup);
  WDF_OBJECT_ATTRIBUTES file_attributes;
  WDF_OBJECT_ATTRIBUTES_INIT(&file_attributes);
  file_attributes.SynchronizationScope = WdfSynchronizationScopeNone;
  file_attributes.ExecutionLevel = WdfExecutionLevelPassive;
  WdfDeviceInitSetFileObjectConfig(device_init, &file_config, &file_attributes);

  WDF_IO_TYPE_CONFIG io_config;
  WDF_IO_TYPE_CONFIG_INIT(&io_config);
  io_config.ReadWriteIoType = WdfDeviceIoDirect;
  io_config.DeviceControlIoType = WdfDeviceIoDirect;
  WdfDeviceInitSetIoTypeEx(device_init, &io_config);

  WDF_OBJECT_ATTRIBUTES attributes;
  WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, LumenDeviceContext);
  attributes.ExecutionLevel = WdfExecutionLevelPassive;
  attributes.SynchronizationScope = WdfSynchronizationScopeDevice;
  attributes.EvtCleanupCallback = LumenEvtDeviceContextCleanup;

  WDFDEVICE device = nullptr;
  status = WdfDeviceCreate(&device_init, &attributes, &device);
  if (!NT_SUCCESS(status)) {
    return LumenReportInitializationFailure(L"WdfDeviceCreate", status);
  }

  auto *context = LumenGetDeviceContext(device);
  context->core_state = lumen_driver_core_initial_state();
  context->frame_queue = nullptr;
  context->event_queue = nullptr;
  context->adapter = nullptr;
  context->monitor = nullptr;
  context->adapter_factory = nullptr;
  context->d3d11_probe_device = nullptr;
  context->d3d12_probe_device = nullptr;
  context->adapter_change_event = nullptr;
  context->adapter_change_wait = nullptr;
  context->adapter_change_cookie = 0;
  context->adapter_change_work_item = nullptr;
  context->frame_work_item = nullptr;
  context->frame_request_event = nullptr;
  context->frame_processor = nullptr;
  context->pending_frame = {};
  context->pending_frame_status = STATUS_SUCCESS;
  context->pending_frame_ready = 0;
  context->encoder_active = 0;
  context->adapter_monitoring = 0;

  context->frame_request_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (context->frame_request_event == nullptr) {
    return STATUS_INSUFFICIENT_RESOURCES;
  }
  WDF_WORKITEM_CONFIG frame_work_item_config;
  WDF_WORKITEM_CONFIG_INIT(&frame_work_item_config, LumenEvtFrameWorkItem);
  frame_work_item_config.AutomaticSerialization = TRUE;
  WDF_OBJECT_ATTRIBUTES frame_work_item_attributes;
  WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(
    &frame_work_item_attributes,
    LumenFrameWorkItemContext
  );
  frame_work_item_attributes.ParentObject = device;
  status = WdfWorkItemCreate(
    &frame_work_item_config,
    &frame_work_item_attributes,
    &context->frame_work_item
  );
  if (!NT_SUCCESS(status)) {
    return LumenReportInitializationFailure(L"WdfWorkItemCreate.Frame", status);
  }
  LumenGetFrameWorkItemContext(context->frame_work_item)->device = device;

  status = IddCxDeviceInitialize(device);
  if (!NT_SUCCESS(status)) {
    return LumenReportInitializationFailure(L"IddCxDeviceInitialize", status);
  }
  status = WdfDeviceCreateDeviceInterface(device, &kLumenDeviceInterface, nullptr);
  if (!NT_SUCCESS(status)) {
    return LumenReportInitializationFailure(L"WdfDeviceCreateDeviceInterface", status);
  }

  status = create_manual_queue(device, &context->frame_queue);
  if (!NT_SUCCESS(status)) {
    return LumenReportInitializationFailure(L"WdfIoQueueCreate.Frame", status);
  }
  status = create_manual_queue(device, &context->event_queue);
  return NT_SUCCESS(status) ? status : LumenReportInitializationFailure(L"WdfIoQueueCreate.Event", status);
}

NTSTATUS LumenEvtDeviceD0Entry(
  WDFDEVICE device,
  WDF_POWER_DEVICE_STATE
) {
  auto *context = LumenGetDeviceContext(device);
  const NTSTATUS status = LumenInitializeAdapter(device, context);
  return NT_SUCCESS(status) ? status : LumenReportInitializationFailure(L"LumenInitializeAdapter", status);
}

void LumenEvtDeviceContextCleanup(WDFOBJECT object) {
  auto *context = LumenGetDeviceContext(static_cast<WDFDEVICE>(object));
  LumenStopFrameProcessor(context);
  if (context->frame_work_item != nullptr) {
    WdfWorkItemFlush(context->frame_work_item);
  }
  if (context->frame_request_event != nullptr) {
    CloseHandle(context->frame_request_event);
    context->frame_request_event = nullptr;
  }
  LumenStopAdapterMonitoring(context);
  if (context->core_state.render_adapter_luid == 0) {
    return;
  }
  auto request = LumenRequest(
    LumenDriverOperationAdapterRemoved,
    0,
    context->core_state.generation
  );
  request.arguments[0] = context->core_state.render_adapter_luid;
  context->core_state =
    lumen_driver_core_dispatch(context->core_state, request).state;
}
