#include "windows_device_stop_restart.h"

#include "windows_device_io.h"

#include <cstdint>
#include <vector>

namespace lumen_driver_qa {
  namespace {
    class AccessUnitRead final {
    public:
      AccessUnitRead(HANDLE handle, uint64_t generation, uint64_t request_id):
          request_(request(LumenDriverOperationDequeueAccessUnit, generation)),
          output_(LUMEN_MAX_ACCESS_UNIT_BYTES),
          pending_(handle) {
        request_.request_id = request_id;
        request_.arguments[0] = LUMEN_MAX_ACCESS_UNIT_BYTES;
      }

      bool submit(HANDLE handle) {
        if (!pending_.valid()) {
          return false;
        }
        const BOOL immediate = DeviceIoControl(
          handle,
          LUMEN_IOCTL_DEQUEUE_ACCESS_UNIT,
          &request_,
          sizeof(request_),
          output_.data(),
          static_cast<DWORD>(output_.size()),
          nullptr,
          pending_.overlapped()
        );
        if (immediate || GetLastError() != ERROR_IO_PENDING) {
          return false;
        }
        pending_.mark_pending();
        return true;
      }

      bool cancel() {
        return pending_.cancel();
      }

      DWORD wait() {
        return pending_.wait(5000);
      }

    private:
      LumenDriverCoreRequest request_;
      std::vector<uint8_t> output_;
      PendingIo pending_;
    };

    bool access_unit_count_is(
      HANDLE handle,
      uint64_t generation,
      uint32_t expected
    ) {
      auto health = request(LumenDriverOperationQueryHealth, generation);
      LumenDriverCoreResponse response {};
      if (send_ioctl(handle, LUMEN_IOCTL_QUERY_HEALTH, &health, &response, sizeof(response)) != ERROR_SUCCESS) {
        return false;
      }
      return response.values[1] >> 32u == expected;
    }

  }  // namespace

  StopRestartResult stop_restart_cycle(
    HANDLE handle,
    uint64_t generation,
    uint64_t request_id
  ) {
    AccessUnitRead stop_pending(handle, generation, request_id);
    if (!stop_pending.submit(handle)) {
      return {40, 46};
    }

    auto stop = request(LumenDriverOperationStopEncoder, generation);
    LumenDriverCoreResponse response {};
    if (send_ioctl(handle, LUMEN_IOCTL_STOP_ENCODER, &stop, &response, sizeof(response)) != ERROR_SUCCESS) {
      return {41, 46};
    }
    if (stop_pending.wait() != ERROR_OPERATION_ABORTED) {
      return {42, 46};
    }

    auto restart = request(LumenDriverOperationStartEncoder, generation);
    if (send_ioctl(handle, LUMEN_IOCTL_START_ENCODER, &restart, &response, sizeof(response)) != ERROR_SUCCESS) {
      return {0, 43};
    }
    AccessUnitRead restart_pending(handle, generation, request_id);
    if (!restart_pending.submit(handle)) {
      return {0, 44};
    }
    if (!access_unit_count_is(handle, generation, 1)) {
      return {0, 45};
    }
    if (!restart_pending.cancel() || restart_pending.wait() != ERROR_OPERATION_ABORTED) {
      return {0, 46};
    }
    return {0, access_unit_count_is(handle, generation, 0) ? 0 : 47};
  }
}  // namespace lumen_driver_qa
