#pragma once

#include <string_view>

namespace platf {
  void post_macos_tray_notification(
    std::string_view identifier,
    std::string_view title,
    std::string_view body,
    std::string_view launch_path = {}
  );
}
