#include "ApolloCore.h"
#include "ApolloCore.hpp"

namespace apollo::core {
  std::string version_string() {
    return "ApolloCore bootstrap";
  }

  std::string runtime_description() {
    return "C and C++ compatibility surface for the Swift/Tuist Apollo shell.";
  }
}

const char *ApolloCoreBootstrapVersionString(void) {
  static const std::string version = apollo::core::version_string();
  return version.c_str();
}

const char *ApolloCoreBootstrapRuntimeDescription(void) {
  static const std::string description = apollo::core::runtime_description();
  return description.c_str();
}
