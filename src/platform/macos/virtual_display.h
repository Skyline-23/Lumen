#pragma once

#include <cstdint>
#include <string>

namespace VDISPLAY {
  enum class DRIVER_STATUS {
    UNKNOWN = 1,
    OK = 0,
    FAILED = -1,
  };

  DRIVER_STATUS openVDisplayDevice();
  void closeVDisplayDevice();

  std::string createVirtualDisplay(
    const char *client_uid,
    const char *client_name,
    std::uint32_t width,
    std::uint32_t height,
    std::uint32_t fps_millihz
  );

  bool removeVirtualDisplay(const std::string &client_uid);
}
