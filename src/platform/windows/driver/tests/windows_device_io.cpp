#include "windows_device_io.h"

#include <cstdint>
#include <setupapi.h>
#include <vector>

namespace lumen_driver_qa {
  namespace {
    const GUID kInterface = LUMEN_DEVICE_INTERFACE_GUID_INIT;
  }

  PendingIo::PendingIo(HANDLE handle):
      handle_(handle) {
    overlapped_.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  }

  PendingIo::~PendingIo() {
    if (pending_) {
      CancelIoEx(handle_, &overlapped_);
      DWORD transferred = 0;
      GetOverlappedResult(handle_, &overlapped_, &transferred, TRUE);
    }
    if (overlapped_.hEvent != nullptr) {
      CloseHandle(overlapped_.hEvent);
    }
  }

  bool PendingIo::valid() const {
    return overlapped_.hEvent != nullptr;
  }

  OVERLAPPED *PendingIo::overlapped() {
    return &overlapped_;
  }

  void PendingIo::mark_pending() {
    pending_ = true;
  }

  bool PendingIo::cancel() {
    return pending_ && CancelIoEx(handle_, &overlapped_);
  }

  DWORD PendingIo::wait(DWORD timeout_milliseconds) {
    if (!pending_) {
      return ERROR_INVALID_STATE;
    }
    const DWORD wait_result =
      WaitForSingleObject(overlapped_.hEvent, timeout_milliseconds);
    if (wait_result != WAIT_OBJECT_0) {
      CancelIoEx(handle_, &overlapped_);
    }
    DWORD transferred = 0;
    const BOOL completed = GetOverlappedResult(
      handle_,
      &overlapped_,
      &transferred,
      wait_result == WAIT_OBJECT_0 ? FALSE : TRUE
    );
    const DWORD error = completed ? ERROR_SUCCESS : GetLastError();
    pending_ = false;
    return wait_result == WAIT_TIMEOUT ? ERROR_TIMEOUT : error;
  }

  std::wstring device_path() {
    HDEVINFO devices = SetupDiGetClassDevsW(
      &kInterface,
      nullptr,
      nullptr,
      DIGCF_PRESENT | DIGCF_DEVICEINTERFACE
    );
    if (devices == INVALID_HANDLE_VALUE) {
      return {};
    }
    SP_DEVICE_INTERFACE_DATA interface_data {};
    interface_data.cbSize = sizeof(interface_data);
    if (!SetupDiEnumDeviceInterfaces(devices, nullptr, &kInterface, 0, &interface_data)) {
      SetupDiDestroyDeviceInfoList(devices);
      return {};
    }
    DWORD required_size = 0;
    SetupDiGetDeviceInterfaceDetailW(devices, &interface_data, nullptr, 0, &required_size, nullptr);
    std::vector<uint8_t> storage(required_size);
    auto *detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W *>(storage.data());
    detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
    const BOOL resolved = SetupDiGetDeviceInterfaceDetailW(
      devices,
      &interface_data,
      detail,
      required_size,
      nullptr,
      nullptr
    );
    std::wstring path = resolved ? detail->DevicePath : L"";
    SetupDiDestroyDeviceInfoList(devices);
    return path;
  }

  LumenDriverCoreRequest request(uint32_t operation, uint64_t generation) {
    LumenDriverCoreRequest value {};
    value.header.magic = LUMEN_DRIVER_ABI_MAGIC;
    value.header.major = LUMEN_DRIVER_ABI_MAJOR;
    value.header.minor = LUMEN_DRIVER_ABI_MINOR;
    value.header.structure_size = sizeof(value);
    value.header.operation = operation;
    value.generation = generation;
    return value;
  }

  DWORD send_ioctl(
    HANDLE handle,
    DWORD code,
    LumenDriverCoreRequest *input,
    void *output,
    DWORD output_size
  ) {
    PendingIo pending(handle);
    if (!pending.valid()) {
      return GetLastError();
    }
    const BOOL completed = DeviceIoControl(
      handle,
      code,
      input,
      sizeof(*input),
      output,
      output_size,
      nullptr,
      pending.overlapped()
    );
    if (completed) {
      return ERROR_SUCCESS;
    }
    const DWORD error = GetLastError();
    if (error != ERROR_IO_PENDING) {
      return error;
    }
    pending.mark_pending();
    return pending.wait(5000);
  }
}  // namespace lumen_driver_qa
