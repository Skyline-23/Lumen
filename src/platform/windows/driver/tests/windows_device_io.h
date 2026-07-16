#pragma once

#include "lumen_driver_abi.h"

#include <cstdint>
#include <string>
#include <windows.h>

namespace lumen_driver_qa {
  class PendingIo final {
  public:
    explicit PendingIo(HANDLE handle);
    ~PendingIo();
    PendingIo(const PendingIo &) = delete;
    PendingIo &operator=(const PendingIo &) = delete;

    bool valid() const;
    OVERLAPPED *overlapped();
    void mark_pending();
    bool cancel();
    DWORD wait(DWORD timeout_milliseconds);

  private:
    HANDLE handle_;
    OVERLAPPED overlapped_ {};
    bool pending_ = false;
  };

  std::wstring device_path();
  LumenDriverCoreRequest request(uint32_t operation, uint64_t generation);
  DWORD send_ioctl(
    HANDLE handle,
    DWORD code,
    LumenDriverCoreRequest *input,
    void *output,
    DWORD output_size
  );
}  // namespace lumen_driver_qa
