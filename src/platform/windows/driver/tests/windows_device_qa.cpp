#include "windows_device_io.h"
#include "windows_device_probes.h"

#include <filesystem>
#include <fstream>
#include <string>

int wmain(int argc, wchar_t **argv) {
  if (argc < 2) {
    return 2;
  }
  const bool denied = std::wstring(argv[1]) == L"--expect-denied";
  const bool has_output = argc == 4 && std::wstring(argv[2]) == L"--output";
  std::ofstream output;
  if (has_output) {
    output.open(std::filesystem::path(argv[3]));
    if (!output.is_open()) {
      return 3;
    }
  }
  const std::wstring path = lumen_driver_qa::device_path();
  if (path.empty()) {
    return 4;
  }
  std::ostream *receipt = has_output ? &output : nullptr;
  return denied ? lumen_driver_qa::run_denied(path, receipt) : lumen_driver_qa::run_authorized(path, receipt);
}
