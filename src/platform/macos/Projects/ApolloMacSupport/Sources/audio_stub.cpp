/**
 * @file src/platform/macos/Projects/ApolloMacSupport/Sources/audio_stub.cpp
 * @brief No-op audio control shim for bridge-only macOS builds.
 */

#include "src/platform/common.h"

namespace platf {
  std::unique_ptr<audio_control_t> audio_control() {
    return {};
  }
}  // namespace platf
