#pragma once

#include <cstdint>
#include <windows.h>

namespace lumen_driver_qa {
  struct StopRestartResult {
    int stop;
    int restart;
  };

  StopRestartResult stop_restart_cycle(
    HANDLE handle,
    uint64_t generation,
    uint64_t request_id
  );
}  // namespace lumen_driver_qa
