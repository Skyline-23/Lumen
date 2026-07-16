#pragma once

#include <ostream>
#include <string>

namespace lumen_driver_qa {
  int run_denied(const std::wstring &path, std::ostream *receipt);
  int run_authorized(const std::wstring &path, std::ostream *receipt);
}  // namespace lumen_driver_qa
