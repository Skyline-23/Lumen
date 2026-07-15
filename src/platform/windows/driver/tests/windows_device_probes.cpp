#include "windows_device_probes.h"

#include "windows_device_io.h"
#include "windows_device_stop_restart.h"

#include <cstdint>
#include <iomanip>
#include <ostream>
#include <vector>

namespace lumen_driver_qa {
  namespace {
    void write_probe(std::ostream *receipt, const char *probe, int result) {
      if (receipt == nullptr) {
        return;
      }
      *receipt << "{\"probe\":\"" << probe << "\",\"result\":" << result << "}\n";
      receipt->flush();
    }

    int cancel_event(HANDLE handle, uint64_t generation) {
      auto pending = request(LumenDriverOperationDequeueEvent, generation);
      pending.request_id = 60;
      pending.arguments[0] = LUMEN_MAX_EVENT_BYTES;
      std::vector<uint8_t> output(LUMEN_MAX_EVENT_BYTES);
      PendingIo pending_io(handle);
      if (!pending_io.valid()) {
        return 50;
      }
      const BOOL immediate = DeviceIoControl(
        handle,
        LUMEN_IOCTL_DEQUEUE_EVENT,
        &pending,
        sizeof(pending),
        output.data(),
        static_cast<DWORD>(output.size()),
        nullptr,
        pending_io.overlapped()
      );
      if (immediate || GetLastError() != ERROR_IO_PENDING) {
        return 50;
      }
      pending_io.mark_pending();
      if (!pending_io.cancel()) {
        return 50;
      }
      return pending_io.wait(5000) == ERROR_OPERATION_ABORTED ? 0 : 51;
    }

    int query_backend_rows(
      HANDLE handle,
      uint64_t generation,
      std::ostream *receipt
    ) {
      auto query = request(LumenDriverOperationQueryBackendCapability, generation);
      LumenDriverCoreResponse response {};
      query.arguments[0] = 0;
      if (send_ioctl(
            handle,
            LUMEN_IOCTL_QUERY_BACKEND_CAPABILITY,
            &query,
            &response,
            sizeof(response)
          ) != ERROR_SUCCESS) {
        return 52;
      }
      const uint64_t count = (response.values[1] >> 24u) & 0xffu;
      for (uint64_t index = 0; index < count; ++index) {
        query.arguments[0] = index;
        if (send_ioctl(
              handle,
              LUMEN_IOCTL_QUERY_BACKEND_CAPABILITY,
              &query,
              &response,
              sizeof(response)
            ) != ERROR_SUCCESS) {
          return 53;
        }
        if (receipt != nullptr) {
          *receipt << "{\"probe\":\"backend_capability\",\"index\":" << index
                   << ",\"luid\":\"0x" << std::hex << std::setw(16)
                   << std::setfill('0') << response.values[0] << std::dec
                   << "\",\"backend\":" << (response.values[1] & 0xffu)
                   << ",\"surface\":" << ((response.values[1] >> 8u) & 0xffu)
                   << "}\n";
        }
      }
      return count == 0 ? 54 : 0;
    }
  }  // namespace

  int run_denied(const std::wstring &path, std::ostream *receipt) {
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    const int result = handle == INVALID_HANDLE_VALUE && GetLastError() == ERROR_ACCESS_DENIED ? 0 : 20;
    if (handle != INVALID_HANDLE_VALUE) {
      CloseHandle(handle);
    }
    write_probe(receipt, "unauthorized_open", result);
    return result;
  }

  int run_authorized(const std::wstring &path, std::ostream *receipt) {
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    int result = handle == INVALID_HANDLE_VALUE ? 30 : 0;
    write_probe(receipt, "first_owner", result);
    if (result != 0) {
      return result;
    }
    HANDLE second = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    const DWORD second_error = GetLastError();
    result = second == INVALID_HANDLE_VALUE && second_error == ERROR_BUSY ? 0 : 31;
    if (second != INVALID_HANDLE_VALUE) {
      CloseHandle(second);
    }
    write_probe(receipt, "second_owner", result);
    if (result != 0) {
      CloseHandle(handle);
      return result;
    }

    auto health = request(LumenDriverOperationQueryHealth, 0);
    LumenDriverCoreResponse response {};
    result = send_ioctl(handle, LUMEN_IOCTL_QUERY_HEALTH, &health, &response, sizeof(response)) == ERROR_SUCCESS ? 0 : 32;
    write_probe(receipt, "query_health", result);
    if (result != 0) {
      CloseHandle(handle);
      return result;
    }
    const uint64_t generation = response.generation;
    result = query_backend_rows(handle, generation, receipt);
    write_probe(receipt, "backend_capabilities", result);
    if (result != 0) {
      CloseHandle(handle);
      return result;
    }

    auto malformed = request(LumenDriverOperationQueryCapabilities, generation);
    ++malformed.header.major;
    result = send_ioctl(handle, LUMEN_IOCTL_QUERY_CAPABILITIES, &malformed, &response, sizeof(response)) == ERROR_SUCCESS ? 33 : 0;
    write_probe(receipt, "malformed_version", result);
    if (result != 0) {
      CloseHandle(handle);
      return result;
    }
    auto oversize = request(LumenDriverOperationDequeueEvent, generation);
    oversize.request_id = 41;
    oversize.arguments[0] = LUMEN_MAX_EVENT_BYTES + 1;
    std::vector<uint8_t> oversize_output(LUMEN_MAX_EVENT_BYTES + 1);
    result = send_ioctl(handle, LUMEN_IOCTL_DEQUEUE_EVENT, &oversize, oversize_output.data(), static_cast<DWORD>(oversize_output.size())) == ERROR_SUCCESS ? 34 : 0;
    write_probe(receipt, "oversize_event", result);
    if (result != 0) {
      CloseHandle(handle);
      return result;
    }
    auto stale = request(LumenDriverOperationCreateMonitor, generation - 1);
    stale.arguments[0] = 7;
    stale.arguments[1] = (uint64_t {1920} << 32u) | 1080u;
    stale.arguments[2] = 120000;
    result = send_ioctl(handle, LUMEN_IOCTL_CREATE_MONITOR, &stale, &response, sizeof(response)) == ERROR_SUCCESS ? 35 : 0;
    write_probe(receipt, "stale_generation", result);
    if (result != 0) {
      CloseHandle(handle);
      return result;
    }

    auto create = request(LumenDriverOperationCreateMonitor, generation);
    create.arguments[0] = 7;
    create.arguments[1] = (uint64_t {1920} << 32u) | 1080u;
    create.arguments[2] = 120000;
    result = send_ioctl(handle, LUMEN_IOCTL_CREATE_MONITOR, &create, &response, sizeof(response)) == ERROR_SUCCESS ? 0 : 36;
    write_probe(receipt, "create_monitor", result);
    if (result != 0) {
      CloseHandle(handle);
      return result;
    }
    auto start = request(LumenDriverOperationStartEncoder, generation);
    result = send_ioctl(handle, LUMEN_IOCTL_START_ENCODER, &start, &response, sizeof(response)) == ERROR_SUCCESS ? 0 : 37;
    write_probe(receipt, "start_encoder", result);
    if (result != 0) {
      CloseHandle(handle);
      return result;
    }

    for (uint64_t cycle = 1; cycle <= 2; ++cycle) {
      const StopRestartResult cycle_result = stop_restart_cycle(handle, generation, 50 + cycle);
      const char *stop_probe = cycle == 1 ? "stop_cancels_access_unit_1" : "stop_cancels_access_unit_2";
      const char *restart_probe = cycle == 1 ? "restart_accepts_access_unit_1" : "restart_accepts_access_unit_2";
      write_probe(receipt, stop_probe, cycle_result.stop);
      if (cycle_result.stop != 0) {
        CloseHandle(handle);
        return cycle_result.stop;
      }
      write_probe(receipt, restart_probe, cycle_result.restart);
      if (cycle_result.restart != 0) {
        CloseHandle(handle);
        return cycle_result.restart;
      }
    }

    result = cancel_event(handle, generation);
    write_probe(receipt, "cancel_event", result);
    CloseHandle(handle);
    return result;
  }
}  // namespace lumen_driver_qa
