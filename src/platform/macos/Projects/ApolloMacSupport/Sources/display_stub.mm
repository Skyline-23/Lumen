/**
 * @file src/platform/macos/Projects/ApolloMacSupport/Sources/display_stub.mm
 * @brief Bridge-only display shim for macOS.
 */

#include <CoreGraphics/CoreGraphics.h>

#include "src/logging.h"
#include "src/platform/common.h"

namespace platf {
  std::shared_ptr<display_t> display(mem_type_e, const std::string &display_name, const video::config_t &) {
    BOOST_LOG(error) << "Legacy macOS display capture path was removed. Requested display="sv << display_name;
    return {};
  }

  std::vector<std::string> display_names(mem_type_e) {
    uint32_t active_count = 0;
    if (CGGetActiveDisplayList(0, nullptr, &active_count) != kCGErrorSuccess || active_count == 0) {
      return {};
    }

    std::vector<CGDirectDisplayID> display_ids(active_count, kCGNullDirectDisplay);
    if (CGGetActiveDisplayList(active_count, display_ids.data(), &active_count) != kCGErrorSuccess) {
      return {};
    }

    std::vector<std::string> names;
    names.reserve(active_count);
    for (uint32_t index = 0; index < active_count; ++index) {
      names.emplace_back(std::to_string(display_ids[index]));
    }
    return names;
  }

  bool needs_encoder_reenumeration() {
    return false;
  }
}  // namespace platf
