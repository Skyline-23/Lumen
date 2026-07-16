#include "driver.h"

#include <d3d11on12.h>
#include <sddl.h>
#include <wrl/client.h>

#include <new>
#include <cwchar>

namespace {
using Microsoft::WRL::ComPtr;

constexpr DWORD kSharedFrameTimeoutMilliseconds = 2'000;

struct LumenFrameProcessorState {
  LumenDeviceContext *context;
  uint64_t generation;
  uint64_t monitor_id;
  IDDCX_SWAPCHAIN swapchain;
  HANDLE next_surface_event;
  HANDLE stop_event;
  HANDLE thread;
  bool uses_d3d12;
  ComPtr<ID3D12CommandQueue> d3d12_queue;
  ComPtr<ID3D11Device> d3d11_device;
  ComPtr<ID3D11DeviceContext> d3d11_context;
  ComPtr<ID3D11On12Device> d3d11_on_12;
  ComPtr<ID3D11Texture2D> shared_texture;
  ComPtr<IDXGIKeyedMutex> shared_mutex;
  HANDLE shared_handle;
  D3D11_TEXTURE2D_DESC shared_description;
  uint32_t shared_color_space;
  uint32_t surface_revision;
  uint64_t frame_id;
  uint64_t qpc_frequency;
};

void release_shared_surface(LumenFrameProcessorState *processor) {
  processor->shared_mutex.Reset();
  processor->shared_texture.Reset();
  if (processor->shared_handle != nullptr) {
    CloseHandle(processor->shared_handle);
    processor->shared_handle = nullptr;
  }
  processor->shared_description = {};
  processor->shared_color_space = 0;
}

uint32_t presentation_time_90khz(
  LumenFrameProcessorState *processor,
  uint64_t qpc_time
) {
  if (processor->qpc_frequency == 0) {
    LARGE_INTEGER frequency {};
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) {
      return 0;
    }
    processor->qpc_frequency = static_cast<uint64_t>(frequency.QuadPart);
  }
  const uint64_t whole = qpc_time / processor->qpc_frequency;
  const uint64_t remainder = qpc_time % processor->qpc_frequency;
  return static_cast<uint32_t>(
    whole * 90'000u + remainder * 90'000u / processor->qpc_frequency
  );
}

void signal_frame_request_if_pending(LumenDeviceContext *context) {
  ULONG requests = 0;
  WdfIoQueueGetState(context->frame_queue, &requests, nullptr);
  if (requests == 0) {
    ResetEvent(context->frame_request_event);
    WdfIoQueueGetState(context->frame_queue, &requests, nullptr);
  }
  if (requests != 0) {
    SetEvent(context->frame_request_event);
  }
}

void publish_frame(
  LumenFrameProcessorState *processor,
  const LumenDriverFrameRecord &record,
  NTSTATUS status
) {
  auto *context = processor->context;
  while (InterlockedCompareExchange(&context->pending_frame_ready, 1, 1) != 0) {
    if (WaitForSingleObject(processor->stop_event, 1) == WAIT_OBJECT_0) {
      return;
    }
  }
  context->pending_frame = record;
  context->pending_frame_status = status;
  MemoryBarrier();
  InterlockedExchange(&context->pending_frame_ready, 1);
  WdfWorkItemEnqueue(context->frame_work_item);
}

NTSTATUS create_shared_surface(
  LumenFrameProcessorState *processor,
  const D3D11_TEXTURE2D_DESC &source_description,
  uint32_t color_space
) {
  if (processor->shared_texture != nullptr &&
      processor->shared_description.Width == source_description.Width &&
      processor->shared_description.Height == source_description.Height &&
      processor->shared_description.Format == source_description.Format &&
      processor->shared_color_space == color_space) {
    return STATUS_SUCCESS;
  }

  release_shared_surface(processor);
  D3D11_TEXTURE2D_DESC description = source_description;
  description.MipLevels = 1;
  description.ArraySize = 1;
  description.Usage = D3D11_USAGE_DEFAULT;
  description.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  description.CPUAccessFlags = 0;
  description.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE |
    D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
  HRESULT result = processor->d3d11_device->CreateTexture2D(
    &description,
    nullptr,
    processor->shared_texture.GetAddressOf()
  );
  if (FAILED(result)) {
    return STATUS_INSUFFICIENT_RESOURCES;
  }
  result = processor->shared_texture.As(&processor->shared_mutex);
  if (FAILED(result)) {
    release_shared_surface(processor);
    return STATUS_NOT_SUPPORTED;
  }

  ComPtr<IDXGIResource1> shared_resource;
  result = processor->shared_texture.As(&shared_resource);
  if (FAILED(result)) {
    release_shared_surface(processor);
    return STATUS_NOT_SUPPORTED;
  }
  processor->surface_revision = processor->surface_revision == UINT32_MAX
    ? 1
    : processor->surface_revision + 1;
  wchar_t name[96] {};
  const int name_length = swprintf_s(
    name,
    L"Global\\LumenFrame-%016llX-%08X",
    static_cast<unsigned long long>(processor->monitor_id),
    processor->surface_revision
  );
  if (name_length <= 0) {
    release_shared_surface(processor);
    return STATUS_NAME_TOO_LONG;
  }

  PSECURITY_DESCRIPTOR security_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
        L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;AU)",
        SDDL_REVISION_1,
        &security_descriptor,
        nullptr
      )) {
    release_shared_surface(processor);
    return STATUS_ACCESS_DENIED;
  }
  SECURITY_ATTRIBUTES security_attributes {
    sizeof(SECURITY_ATTRIBUTES),
    security_descriptor,
    FALSE,
  };
  result = shared_resource->CreateSharedHandle(
    &security_attributes,
    DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
    name,
    &processor->shared_handle
  );
  LocalFree(security_descriptor);
  if (FAILED(result)) {
    release_shared_surface(processor);
    return STATUS_ACCESS_DENIED;
  }
  processor->shared_description = description;
  processor->shared_color_space = color_space;
  return STATUS_SUCCESS;
}

NTSTATUS copy_frame(
  LumenFrameProcessorState *processor,
  ID3D11Texture2D *source,
  uint32_t color_space,
  uint64_t qpc_time
) {
  D3D11_TEXTURE2D_DESC description {};
  source->GetDesc(&description);
  NTSTATUS status = create_shared_surface(processor, description, color_space);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  HRESULT result = processor->shared_mutex->AcquireSync(
    0,
    kSharedFrameTimeoutMilliseconds
  );
  if (FAILED(result)) {
    return STATUS_IO_TIMEOUT;
  }
  processor->d3d11_context->CopyResource(processor->shared_texture.Get(), source);
  processor->d3d11_context->Flush();
  result = processor->shared_mutex->ReleaseSync(1);
  if (FAILED(result)) {
    return STATUS_DEVICE_HARDWARE_ERROR;
  }

  LumenDriverFrameRecord record {};
  record.header.magic = LUMEN_DRIVER_ABI_MAGIC;
  record.header.major = LUMEN_DRIVER_ABI_MAJOR;
  record.header.minor = LUMEN_DRIVER_ABI_MINOR;
  record.header.structure_size = sizeof(record);
  record.header.operation = LumenDriverOperationDequeueFrame;
  record.generation = processor->generation;
  record.monitor_id = processor->monitor_id;
  record.frame_id = ++processor->frame_id;
  record.presentation_time_90khz = presentation_time_90khz(processor, qpc_time);
  record.width = description.Width;
  record.height = description.Height;
  record.format = static_cast<uint32_t>(description.Format);
  record.color_space = color_space;
  record.surface_revision = processor->surface_revision;
  publish_frame(processor, record, STATUS_SUCCESS);
  return STATUS_SUCCESS;
}

NTSTATUS acquire_d3d12_frame(LumenFrameProcessorState *processor) {
  IDARG_IN_RELEASEANDACQUIREBUFFER2 input {};
  input.Size = sizeof(input);
  input.pD3D12CommandQueue = processor->d3d12_queue.Get();
  IDARG_OUT_RELEASEANDACQUIREBUFFER2 output {};
  output.MetaData.Size = sizeof(output.MetaData);
  const HRESULT result = IddCxSwapChainReleaseAndAcquireBuffer2(
    processor->swapchain,
    &input,
    &output
  );
  if (result == E_PENDING) {
    return STATUS_RETRY;
  }
  if (FAILED(result) || output.MetaData.pD3D12Surface == nullptr) {
    return STATUS_DEVICE_HARDWARE_ERROR;
  }
  if (output.MetaData.HwProtectedSurface) {
    return STATUS_ACCESS_DENIED;
  }
  D3D11_RESOURCE_FLAGS flags {};
  ComPtr<ID3D11Texture2D> wrapped;
  HRESULT wrap_result = processor->d3d11_on_12->CreateWrappedResource(
    output.MetaData.pD3D12Surface,
    &flags,
    D3D12_RESOURCE_STATE_COMMON,
    D3D12_RESOURCE_STATE_COMMON,
    IID_PPV_ARGS(wrapped.GetAddressOf())
  );
  if (FAILED(wrap_result)) {
    return STATUS_NOT_SUPPORTED;
  }
  ID3D11Resource *resources[] = {wrapped.Get()};
  processor->d3d11_on_12->AcquireWrappedResources(resources, ARRAYSIZE(resources));
  const NTSTATUS status = copy_frame(
    processor,
    wrapped.Get(),
    static_cast<uint32_t>(output.MetaData.SurfaceColorSpace),
    output.MetaData.PresentDisplayQPCTime
  );
  processor->d3d11_on_12->ReleaseWrappedResources(resources, ARRAYSIZE(resources));
  processor->d3d11_context->Flush();
  return status;
}

NTSTATUS acquire_d3d11_frame(LumenFrameProcessorState *processor) {
  IDARG_OUT_RELEASEANDACQUIREBUFFER output {};
  output.MetaData.Size = sizeof(output.MetaData);
  const HRESULT result = IddCxSwapChainReleaseAndAcquireBuffer(
    processor->swapchain,
    &output
  );
  if (result == E_PENDING) {
    return STATUS_RETRY;
  }
  if (FAILED(result) || output.MetaData.pSurface == nullptr) {
    return STATUS_DEVICE_HARDWARE_ERROR;
  }
  if (output.MetaData.HwProtectedSurface) {
    return STATUS_ACCESS_DENIED;
  }
  ComPtr<ID3D11Texture2D> source;
  const HRESULT query_result = output.MetaData.pSurface->QueryInterface(
    IID_PPV_ARGS(source.GetAddressOf())
  );
  if (FAILED(query_result)) {
    return STATUS_NOT_SUPPORTED;
  }
  return copy_frame(
    processor,
    source.Get(),
    static_cast<uint32_t>(DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709),
    output.MetaData.PresentDisplayQPCTime
  );
}

DWORD WINAPI run_frame_processor(void *value) {
  auto *processor = static_cast<LumenFrameProcessorState *>(value);
  HANDLE request_events[] = {
    processor->stop_event,
    processor->context->frame_request_event,
  };
  HANDLE surface_events[] = {
    processor->stop_event,
    processor->next_surface_event,
  };
  for (;;) {
    const DWORD request_wait = WaitForMultipleObjects(
      ARRAYSIZE(request_events),
      request_events,
      FALSE,
      INFINITE
    );
    if (request_wait == WAIT_OBJECT_0) {
      return 0;
    }
    if (request_wait != WAIT_OBJECT_0 + 1) {
      return 1;
    }
    signal_frame_request_if_pending(processor->context);
    if (InterlockedCompareExchange(&processor->context->encoder_active, 1, 1) == 0) {
      ResetEvent(processor->context->frame_request_event);
      continue;
    }
    ULONG pending = 0;
    WdfIoQueueGetState(processor->context->frame_queue, &pending, nullptr);
    if (pending == 0) {
      ResetEvent(processor->context->frame_request_event);
      continue;
    }
    const DWORD surface_wait = WaitForMultipleObjects(
      ARRAYSIZE(surface_events),
      surface_events,
      FALSE,
      INFINITE
    );
    if (surface_wait == WAIT_OBJECT_0) {
      return 0;
    }
    if (surface_wait != WAIT_OBJECT_0 + 1) {
      return 2;
    }
    const NTSTATUS status = processor->uses_d3d12
      ? acquire_d3d12_frame(processor)
      : acquire_d3d11_frame(processor);
    if (status == STATUS_RETRY) {
      continue;
    }
    if (!NT_SUCCESS(status)) {
      LumenDriverFrameRecord record {};
      record.generation = processor->generation;
      record.monitor_id = processor->monitor_id;
      publish_frame(processor, record, status);
    }
  }
}

NTSTATUS initialize_d3d12_processor(LumenFrameProcessorState *processor) {
  auto *device = processor->context->d3d12_probe_device;
  if (device == nullptr) {
    return STATUS_NOT_SUPPORTED;
  }
  D3D12_COMMAND_QUEUE_DESC queue_description {};
  queue_description.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
  HRESULT result = device->CreateCommandQueue(
    &queue_description,
    IID_PPV_ARGS(processor->d3d12_queue.GetAddressOf())
  );
  if (FAILED(result)) {
    return STATUS_NOT_SUPPORTED;
  }
  IUnknown *queues[] = {processor->d3d12_queue.Get()};
  D3D_FEATURE_LEVEL selected_level {};
  result = D3D11On12CreateDevice(
    device,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
    nullptr,
    0,
    queues,
    ARRAYSIZE(queues),
    0,
    processor->d3d11_device.GetAddressOf(),
    processor->d3d11_context.GetAddressOf(),
    &selected_level
  );
  if (FAILED(result)) {
    return STATUS_NOT_SUPPORTED;
  }
  result = processor->d3d11_device.As(&processor->d3d11_on_12);
  if (FAILED(result)) {
    return STATUS_NOT_SUPPORTED;
  }
  IDARG_IN_SWAPCHAINSETDEVICE2 input {};
  input.Type = IDDCX_SWAPCHAIN_DEVICE_TYPE_D3D12;
  input.Device.pD3d12Device = device;
  result = IddCxSwapChainSetDevice2(processor->swapchain, &input);
  if (FAILED(result)) {
    return STATUS_NOT_SUPPORTED;
  }
  processor->uses_d3d12 = true;
  return STATUS_SUCCESS;
}

NTSTATUS initialize_d3d11_processor(LumenFrameProcessorState *processor) {
  if (processor->context->d3d11_probe_device == nullptr) {
    return STATUS_NOT_SUPPORTED;
  }
  processor->d3d11_device = processor->context->d3d11_probe_device;
  processor->d3d11_device->GetImmediateContext(
    processor->d3d11_context.GetAddressOf()
  );
  ComPtr<IDXGIDevice> dxgi_device;
  HRESULT result = processor->d3d11_device.As(&dxgi_device);
  if (FAILED(result)) {
    return STATUS_NOT_SUPPORTED;
  }
  IDARG_IN_SWAPCHAINSETDEVICE input {};
  input.pDevice = dxgi_device.Get();
  result = IddCxSwapChainSetDevice(processor->swapchain, &input);
  if (FAILED(result)) {
    return STATUS_NOT_SUPPORTED;
  }
  processor->uses_d3d12 = false;
  return STATUS_SUCCESS;
}
}

struct LumenFrameProcessor {
  LumenFrameProcessorState state;
};

NTSTATUS LumenAssignSwapChain(
  LumenDeviceContext *context,
  LumenMonitorContext *monitor_context,
  const IDARG_IN_SETSWAPCHAIN *input
) {
  if (context->frame_processor != nullptr) {
    return STATUS_DEVICE_BUSY;
  }
  auto *processor = new (std::nothrow) LumenFrameProcessor {};
  if (processor == nullptr) {
    return STATUS_INSUFFICIENT_RESOURCES;
  }
  processor->state.context = context;
  processor->state.generation = context->core_state.generation;
  processor->state.monitor_id = monitor_context->monitor_id;
  processor->state.swapchain = input->hSwapChain;
  processor->state.next_surface_event = input->hNextSurfaceAvailable;
  processor->state.stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (processor->state.stop_event == nullptr) {
    delete processor;
    return STATUS_INSUFFICIENT_RESOURCES;
  }
  NTSTATUS status = STATUS_NOT_SUPPORTED;
  if ((context->core_state.backend_capability_mask & (1u << 1u)) != 0) {
    status = initialize_d3d12_processor(&processor->state);
  }
  if (!NT_SUCCESS(status)) {
    status = initialize_d3d11_processor(&processor->state);
  }
  if (!NT_SUCCESS(status)) {
    CloseHandle(processor->state.stop_event);
    delete processor;
    return status;
  }
  processor->state.thread = CreateThread(
    nullptr,
    0,
    run_frame_processor,
    &processor->state,
    0,
    nullptr
  );
  if (processor->state.thread == nullptr) {
    CloseHandle(processor->state.stop_event);
    delete processor;
    return STATUS_INSUFFICIENT_RESOURCES;
  }
  context->frame_processor = processor;
  return STATUS_SUCCESS;
}

void LumenStopFrameProcessor(LumenDeviceContext *context) {
  auto *processor = context->frame_processor;
  context->frame_processor = nullptr;
  if (processor == nullptr) {
    return;
  }
  SetEvent(processor->state.stop_event);
  SetEvent(context->frame_request_event);
  if (processor->state.thread != nullptr) {
    WaitForSingleObject(processor->state.thread, INFINITE);
    CloseHandle(processor->state.thread);
  }
  release_shared_surface(&processor->state);
  CloseHandle(processor->state.stop_event);
  delete processor;
}

NTSTATUS LumenUnassignSwapChain(LumenDeviceContext *context, uint64_t monitor_id) {
  LumenStopFrameProcessor(context);
  auto request = LumenRequest(
    LumenDriverOperationUnassignSwapchain,
    0,
    context->core_state.generation
  );
  request.arguments[0] = monitor_id;
  const auto transition = lumen_driver_core_dispatch(context->core_state, request);
  context->core_state = transition.state;
  InterlockedExchange(&context->encoder_active, 0);
  ResetEvent(context->frame_request_event);
  if (transition.response.status == LumenDriverStatusOk &&
      context->core_state.pending_event_code != 0) {
    LumenCompletePendingEvent(context);
  }
  return LumenStatusToNtStatus(transition.response.status);
}

void LumenSignalFrameRequest(LumenDeviceContext *context) {
  SetEvent(context->frame_request_event);
}
