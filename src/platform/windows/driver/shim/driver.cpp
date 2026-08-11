#include "driver.h"

#include <evntprov.h>

extern "C" DRIVER_INITIALIZE DriverEntry;

namespace {
  constexpr LONG kControlPlaneUninitialized = 0;
  constexpr LONG kControlPlaneInitializing = 1;
  constexpr LONG kControlPlaneReady = 2;
  constexpr LONG kControlPlaneFailed = 3;

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

  NTSTATUS initialize_control_plane(
    WDFDEVICE device,
    LumenDeviceContext *context
  ) {
    const LONG prior_state = InterlockedCompareExchange(
      &context->control_plane_state,
      kControlPlaneInitializing,
      kControlPlaneUninitialized
    );
    if (prior_state == kControlPlaneReady) {
      return STATUS_SUCCESS;
    }
    if (prior_state == kControlPlaneFailed) {
      return context->control_plane_status;
    }
    if (prior_state != kControlPlaneUninitialized) {
      return STATUS_DEVICE_BUSY;
    }

    const auto fail = [context](const wchar_t *stage, NTSTATUS status) {
      const NTSTATUS reported = LumenReportInitializationFailure(stage, status);
      context->control_plane_status = reported;
      InterlockedExchange(
        &context->control_plane_state,
        kControlPlaneFailed
      );
      return reported;
    };

    NTSTATUS status =
      WdfDeviceCreateDeviceInterface(device, &kLumenDeviceInterface, nullptr);
    if (!NT_SUCCESS(status)) {
      return fail(L"WdfDeviceCreateDeviceInterface", status);
    }

    context->frame_request_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (context->frame_request_event == nullptr) {
      return fail(L"CreateEvent.FrameRequest", STATUS_INSUFFICIENT_RESOURCES);
    }

    WDF_WORKITEM_CONFIG frame_work_item_config;
    WDF_WORKITEM_CONFIG_INIT(
      &frame_work_item_config,
      LumenEvtFrameWorkItem
    );
    frame_work_item_config.AutomaticSerialization = FALSE;
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
      return fail(L"WdfWorkItemCreate.Frame", status);
    }
    LumenGetFrameWorkItemContext(context->frame_work_item)->device = device;

    status = create_manual_queue(device, &context->frame_queue);
    if (!NT_SUCCESS(status)) {
      return fail(L"WdfIoQueueCreate.Frame", status);
    }
    status = create_manual_queue(device, &context->event_queue);
    if (!NT_SUCCESS(status)) {
      return fail(L"WdfIoQueueCreate.Event", status);
    }

    context->control_plane_status = STATUS_SUCCESS;
    InterlockedExchange(&context->control_plane_state, kControlPlaneReady);
    return STATUS_SUCCESS;
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
  iddcx_config.EvtIddCxAdapterInitFinished = LumenEvtIddCxAdapterInitFinished;
  iddcx_config.EvtIddCxMonitorGetDefaultDescriptionModes = LumenEvtIddCxMonitorGetDefaultDescriptionModes;
  iddcx_config.EvtIddCxMonitorAssignSwapChain = LumenEvtIddCxMonitorAssignSwapChain;
  iddcx_config.EvtIddCxMonitorUnassignSwapChain = LumenEvtIddCxMonitorUnassignSwapChain;
  if (IDD_IS_FIELD_AVAILABLE(IDD_CX_CLIENT_CONFIG, EvtIddCxAdapterQueryTargetInfo)) {
    iddcx_config.EvtIddCxAdapterQueryTargetInfo = LumenEvtIddCxAdapterQueryTargetInfo;
    iddcx_config.EvtIddCxParseMonitorDescription2 = LumenEvtIddCxParseMonitorDescription2;
    iddcx_config.EvtIddCxMonitorQueryTargetModes2 = LumenEvtIddCxMonitorQueryTargetModes2;
    iddcx_config.EvtIddCxAdapterCommitModes2 = LumenEvtIddCxAdapterCommitModes2;
  } else {
    iddcx_config.EvtIddCxParseMonitorDescription = LumenEvtIddCxParseMonitorDescription;
    iddcx_config.EvtIddCxAdapterCommitModes = LumenEvtIddCxAdapterCommitModes;
    iddcx_config.EvtIddCxMonitorQueryTargetModes = LumenEvtIddCxMonitorQueryTargetModes;
  }
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
  io_config.ReadWriteIoType = WdfDeviceIoBufferedOrDirect;
  io_config.DeviceControlIoType = WdfDeviceIoBufferedOrDirect;
  WdfDeviceInitSetIoTypeEx(device_init, &io_config);

  WDF_OBJECT_ATTRIBUTES attributes;
  WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, LumenDeviceContext);
  attributes.EvtCleanupCallback = LumenEvtDeviceContextCleanup;

  WDFDEVICE device = nullptr;
  status = WdfDeviceCreate(&device_init, &attributes, &device);
  if (!NT_SUCCESS(status)) {
    return LumenReportInitializationFailure(L"WdfDeviceCreate", status);
  }

  auto *context = LumenGetDeviceContext(device);
  context->core_state_lock_initialized = 0;
  if (!InitializeCriticalSectionEx(&context->core_state_lock, 0, 0)) {
    return LumenReportInitializationFailure(
      L"InitializeCriticalSectionEx.CoreState",
      STATUS_INSUFFICIENT_RESOURCES
    );
  }
  InterlockedExchange(&context->core_state_lock_initialized, 1);

  status = IddCxDeviceInitialize(device);
  if (!NT_SUCCESS(status)) {
    return LumenReportInitializationFailure(L"IddCxDeviceInitialize", status);
  }

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
  context->control_plane_state = kControlPlaneUninitialized;
  context->control_plane_status = STATUS_SUCCESS;

  return STATUS_SUCCESS;
}

NTSTATUS LumenEvtDeviceD0Entry(
  WDFDEVICE device,
  WDF_POWER_DEVICE_STATE
) {
  auto *context = LumenGetDeviceContext(device);
  NTSTATUS status = initialize_control_plane(device, context);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  LumenCoreStateGuard core_state_guard(context);
  status = LumenInitializeAdapter(device, context);
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
  {
    LumenCoreStateGuard core_state_guard(context);
    if (context->core_state.render_adapter_luid != 0) {
      auto request = LumenRequest(
        LumenDriverOperationAdapterRemoved,
        0,
        context->core_state.generation
      );
      request.arguments[0] = context->core_state.render_adapter_luid;
      context->core_state =
        lumen_driver_core_dispatch(context->core_state, request).state;
    }
  }
  if (InterlockedExchange(&context->core_state_lock_initialized, 0) != 0) {
    DeleteCriticalSection(&context->core_state_lock);
  }
}
