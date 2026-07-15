#include "driver.h"

#include <cstdint>

namespace {
  uint32_t operation_for_ioctl(ULONG code) {
    switch (code) {
      case LUMEN_IOCTL_QUERY_CAPABILITIES:
        return LumenDriverOperationQueryCapabilities;
      case LUMEN_IOCTL_CREATE_MONITOR:
        return LumenDriverOperationCreateMonitor;
      case LUMEN_IOCTL_REMOVE_MONITOR:
        return LumenDriverOperationRemoveMonitor;
      case LUMEN_IOCTL_START_ENCODER:
        return LumenDriverOperationStartEncoder;
      case LUMEN_IOCTL_STOP_ENCODER:
        return LumenDriverOperationStopEncoder;
      case LUMEN_IOCTL_REQUEST_KEYFRAME:
        return LumenDriverOperationRequestKeyframe;
      case LUMEN_IOCTL_DEQUEUE_ACCESS_UNIT:
        return LumenDriverOperationDequeueAccessUnit;
      case LUMEN_IOCTL_DEQUEUE_EVENT:
        return LumenDriverOperationDequeueEvent;
      case LUMEN_IOCTL_QUERY_HEALTH:
        return LumenDriverOperationQueryHealth;
      default:
        return 0;
    }
  }

  void cancel_core_read(LumenDeviceContext *context, WDFREQUEST request, uint64_t kind) {
    void *buffer = nullptr;
    if (!NT_SUCCESS(WdfRequestRetrieveInputBuffer(
          request,
          sizeof(LumenDriverCoreRequest),
          &buffer,
          nullptr
        ))) {
      return;
    }
    auto cancel = LumenRequest(LumenDriverOperationCancelPending, LumenOwnerId(WdfRequestGetFileObject(request)), context->core_state.generation);
    cancel.request_id =
      static_cast<LumenDriverCoreRequest *>(buffer)->request_id;
    cancel.arguments[0] = kind;
    context->core_state =
      lumen_driver_core_dispatch(context->core_state, cancel).state;
  }

  void complete_response(WDFREQUEST request, const LumenDriverCoreTransition &transition) {
    void *buffer = nullptr;
    const NTSTATUS buffer_status = WdfRequestRetrieveOutputBuffer(
      request,
      sizeof(LumenDriverCoreResponse),
      &buffer,
      nullptr
    );
    if (!NT_SUCCESS(buffer_status)) {
      WdfRequestComplete(request, buffer_status);
      return;
    }
    *static_cast<LumenDriverCoreResponse *>(buffer) = transition.response;
    WdfRequestCompleteWithInformation(
      request,
      LumenStatusToNtStatus(transition.response.status),
      sizeof(LumenDriverCoreResponse)
    );
  }
}  // namespace

uint64_t LumenOwnerId(WDFFILEOBJECT file_object) {
  return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(file_object));
}

LumenDriverCoreRequest LumenRequest(uint32_t operation, uint64_t owner_id, uint64_t generation) {
  LumenDriverCoreRequest request {};
  request.header.magic = LUMEN_DRIVER_ABI_MAGIC;
  request.header.major = LUMEN_DRIVER_ABI_MAJOR;
  request.header.minor = LUMEN_DRIVER_ABI_MINOR;
  request.header.structure_size = sizeof(request);
  request.header.operation = operation;
  request.owner_id = owner_id;
  request.generation = generation;
  return request;
}

NTSTATUS LumenStatusToNtStatus(uint32_t status) {
  switch (status) {
    case LumenDriverStatusOk:
      return STATUS_SUCCESS;
    case LumenDriverStatusInvalidVersion:
    case LumenDriverStatusStaleGeneration:
      return STATUS_REVISION_MISMATCH;
    case LumenDriverStatusAccessDenied:
      return STATUS_ACCESS_DENIED;
    case LumenDriverStatusBusy:
    case LumenDriverStatusQueueFull:
      return STATUS_DEVICE_BUSY;
    case LumenDriverStatusInvalidArgument:
      return STATUS_INVALID_PARAMETER;
    case LumenDriverStatusOversize:
      return STATUS_BUFFER_OVERFLOW;
    case LumenDriverStatusCancelled:
      return STATUS_CANCELLED;
    case LumenDriverStatusInvalidState:
      return STATUS_INVALID_DEVICE_STATE;
    case LumenDriverStatusNotReady:
      return STATUS_DEVICE_NOT_READY;
    case LumenDriverStatusPending:
      return STATUS_PENDING;
    default:
      return STATUS_INVALID_PARAMETER;
  }
}

void LumenEvtDeviceFileCreate(WDFDEVICE device, WDFREQUEST request, WDFFILEOBJECT file_object) {
  auto *context = LumenGetDeviceContext(device);
  const auto claim = LumenRequest(LumenDriverOperationClaimOwner, LumenOwnerId(file_object), context->core_state.generation);
  const auto transition =
    lumen_driver_core_dispatch(context->core_state, claim);
  context->core_state = transition.state;
  if (transition.response.status == LumenDriverStatusOk) {
    WdfIoQueueStart(context->access_unit_queue);
    WdfIoQueueStart(context->event_queue);
  }
  WdfRequestComplete(request, LumenStatusToNtStatus(transition.response.status));
}

void LumenEvtFileCleanup(WDFFILEOBJECT file_object) {
  auto *context = LumenGetDeviceContext(WdfFileObjectGetDevice(file_object));
  const uint64_t owner_id = LumenOwnerId(file_object);
  if (context->core_state.owner_id != owner_id) {
    return;
  }
  WdfIoQueuePurge(context->access_unit_queue, WDF_NO_EVENT_CALLBACK, WDF_NO_CONTEXT);
  WdfIoQueuePurge(context->event_queue, WDF_NO_EVENT_CALLBACK, WDF_NO_CONTEXT);
  const auto release = LumenRequest(LumenDriverOperationReleaseOwner, owner_id, context->core_state.generation);
  context->core_state =
    lumen_driver_core_dispatch(context->core_state, release).state;
}

void LumenEvtIoDeviceControl(WDFQUEUE queue, WDFREQUEST request, size_t output_length, size_t input_length, ULONG code) {
  const uint32_t operation = operation_for_ioctl(code);
  if (operation == 0 || input_length != sizeof(LumenDriverCoreRequest)) {
    WdfRequestComplete(request, STATUS_INVALID_PARAMETER);
    return;
  }
  void *buffer = nullptr;
  NTSTATUS status = WdfRequestRetrieveInputBuffer(
    request,
    sizeof(LumenDriverCoreRequest),
    &buffer,
    nullptr
  );
  if (!NT_SUCCESS(status)) {
    WdfRequestComplete(request, status);
    return;
  }
  auto core_request = *static_cast<LumenDriverCoreRequest *>(buffer);
  if (core_request.header.operation != operation) {
    WdfRequestComplete(request, STATUS_INVALID_PARAMETER);
    return;
  }
  core_request.owner_id = LumenOwnerId(WdfRequestGetFileObject(request));
  if ((operation == LumenDriverOperationDequeueAccessUnit ||
       operation == LumenDriverOperationDequeueEvent) &&
      (core_request.arguments[0] != output_length || output_length == 0)) {
    WdfRequestComplete(request, STATUS_INVALID_BUFFER_SIZE);
    return;
  }

  auto *context = LumenGetDeviceContext(WdfIoQueueGetDevice(queue));
  const auto transition =
    lumen_driver_core_dispatch(context->core_state, core_request);
  context->core_state = transition.state;
  if (transition.response.status != LumenDriverStatusPending) {
    complete_response(request, transition);
    return;
  }

  WDFQUEUE destination =
    operation == LumenDriverOperationDequeueAccessUnit ? context->access_unit_queue : context->event_queue;
  status = WdfRequestForwardToIoQueue(request, destination);
  if (!NT_SUCCESS(status)) {
    auto cancel =
      LumenRequest(LumenDriverOperationCancelPending, core_request.owner_id, context->core_state.generation);
    cancel.request_id = core_request.request_id;
    cancel.arguments[0] =
      operation == LumenDriverOperationDequeueAccessUnit ? 1 : 2;
    context->core_state =
      lumen_driver_core_dispatch(context->core_state, cancel).state;
    WdfRequestComplete(request, status);
  }
}

void LumenEvtIoCancelledOnQueue(WDFQUEUE queue, WDFREQUEST request) {
  auto *context = LumenGetDeviceContext(WdfIoQueueGetDevice(queue));
  cancel_core_read(context, request, queue == context->access_unit_queue ? 1 : 2);
  WdfRequestComplete(request, STATUS_CANCELLED);
}
