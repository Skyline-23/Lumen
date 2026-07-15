#include "lumen_driver_abi.h"

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <windows.h>
#if defined(_WIN32)
  #include <setupapi.h>
#endif

namespace {
  const GUID kInterface = LUMEN_DEVICE_INTERFACE_GUID_INIT;

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
    auto *detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W *>(
      storage.data()
    );
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

  DWORD send_ioctl(HANDLE handle, DWORD code, LumenDriverCoreRequest *input, void *output, DWORD output_size) {
    OVERLAPPED overlapped {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) {
      return GetLastError();
    }
    BOOL completed = DeviceIoControl(handle, code, input, sizeof(*input), output, output_size, nullptr, &overlapped);
    DWORD error = completed ? ERROR_SUCCESS : GetLastError();
    if (!completed && error == ERROR_IO_PENDING) {
      const DWORD wait = WaitForSingleObject(overlapped.hEvent, 5000);
      DWORD transferred = 0;
      completed = wait == WAIT_OBJECT_0 &&
                  GetOverlappedResult(handle, &overlapped, &transferred, FALSE);
      error = completed ? ERROR_SUCCESS : GetLastError();
    }
    CloseHandle(overlapped.hEvent);
    return error;
  }

  int expect_denied(const std::wstring &path) {
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    if (handle != INVALID_HANDLE_VALUE) {
      CloseHandle(handle);
      return 20;
    }
    return GetLastError() == ERROR_ACCESS_DENIED ? 0 : 21;
  }

  int run_authorized(const std::wstring &path) {
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
      return 30;
    }
    HANDLE second = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    const DWORD second_error = GetLastError();
    if (second != INVALID_HANDLE_VALUE) {
      CloseHandle(second);
      CloseHandle(handle);
      return 31;
    }
    if (second_error != ERROR_BUSY) {
      CloseHandle(handle);
      return 31;
    }

    auto health = request(LumenDriverOperationQueryHealth, 0);
    LumenDriverCoreResponse health_response {};
    if (send_ioctl(handle, LUMEN_IOCTL_QUERY_HEALTH, &health, &health_response, sizeof(health_response)) != ERROR_SUCCESS) {
      CloseHandle(handle);
      return 32;
    }
    const uint64_t generation = health_response.generation;

    auto malformed = request(LumenDriverOperationQueryCapabilities, generation);
    ++malformed.header.major;
    LumenDriverCoreResponse response {};
    if (send_ioctl(handle, LUMEN_IOCTL_QUERY_CAPABILITIES, &malformed, &response, sizeof(response)) == ERROR_SUCCESS) {
      CloseHandle(handle);
      return 33;
    }

    auto oversize = request(LumenDriverOperationDequeueEvent, generation);
    oversize.request_id = 41;
    oversize.arguments[0] = LUMEN_MAX_EVENT_BYTES + 1;
    std::vector<uint8_t> oversize_output(LUMEN_MAX_EVENT_BYTES + 1);
    if (send_ioctl(handle, LUMEN_IOCTL_DEQUEUE_EVENT, &oversize, oversize_output.data(), static_cast<DWORD>(oversize_output.size())) == ERROR_SUCCESS) {
      CloseHandle(handle);
      return 34;
    }

    auto stale = request(LumenDriverOperationCreateMonitor, generation - 1);
    stale.arguments[0] = 7;
    stale.arguments[1] = (uint64_t {1920} << 32u) | 1080u;
    stale.arguments[2] = 120000;
    if (send_ioctl(handle, LUMEN_IOCTL_CREATE_MONITOR, &stale, &response, sizeof(response)) == ERROR_SUCCESS) {
      CloseHandle(handle);
      return 35;
    }

    auto create = request(LumenDriverOperationCreateMonitor, generation);
    create.arguments[0] = 7;
    create.arguments[1] = (uint64_t {1920} << 32u) | 1080u;
    create.arguments[2] = 120000;
    if (send_ioctl(handle, LUMEN_IOCTL_CREATE_MONITOR, &create, &response, sizeof(response)) != ERROR_SUCCESS) {
      CloseHandle(handle);
      return 36;
    }
    auto start = request(LumenDriverOperationStartEncoder, generation);
    if (send_ioctl(handle, LUMEN_IOCTL_START_ENCODER, &start, &response, sizeof(response)) != ERROR_SUCCESS) {
      CloseHandle(handle);
      return 37;
    }

    auto pending = request(LumenDriverOperationDequeueEvent, generation);
    pending.request_id = 42;
    pending.arguments[0] = LUMEN_MAX_EVENT_BYTES;
    std::vector<uint8_t> event_output(LUMEN_MAX_EVENT_BYTES);
    OVERLAPPED overlapped {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    const BOOL immediate = DeviceIoControl(
      handle,
      LUMEN_IOCTL_DEQUEUE_EVENT,
      &pending,
      sizeof(pending),
      event_output.data(),
      static_cast<DWORD>(event_output.size()),
      nullptr,
      &overlapped
    );
    if (immediate || GetLastError() != ERROR_IO_PENDING ||
        !CancelIoEx(handle, &overlapped)) {
      CloseHandle(overlapped.hEvent);
      CloseHandle(handle);
      return 38;
    }
    WaitForSingleObject(overlapped.hEvent, 5000);
    DWORD transferred = 0;
    const BOOL cancel_result =
      GetOverlappedResult(handle, &overlapped, &transferred, FALSE);
    const DWORD cancel_error = GetLastError();
    CloseHandle(overlapped.hEvent);
    CloseHandle(handle);
    return !cancel_result && cancel_error == ERROR_OPERATION_ABORTED ? 0 : 39;
  }
}  // namespace

int wmain(int argc, wchar_t **argv) {
  const std::wstring path = device_path();
  if (path.empty() || argc < 2) {
    return 2;
  }
  const bool denied = std::wstring(argv[1]) == L"--expect-denied";
  const int result = denied ? expect_denied(path) : run_authorized(path);
  if (argc == 4 && std::wstring(argv[2]) == L"--output") {
    std::ofstream output {std::filesystem::path(argv[3])};
    output << "{\"mode\":\"" << (denied ? "unauthorized" : "authorized")
           << "\",\"result\":" << result << "}\n";
  }
  return result;
}
