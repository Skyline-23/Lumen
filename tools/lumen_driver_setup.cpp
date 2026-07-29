#define WIN32_LEAN_AND_MEAN
// MinGW's SetupAPI headers require the Win32 base types to be declared first.
// clang-format off
#include <windows.h>
#include <cfgmgr32.h>
#include <cwchar>
#include <iostream>
#include <iterator>
#include <newdev.h>
#include <setupapi.h>
#include <string>
#include <vector>
// clang-format on

namespace {
  constexpr wchar_t kHardwareId[] = L"Root\\LumenIddCx";
  using DiUninstallDriverWFunction = BOOL(WINAPI *)(HWND, LPCWSTR, DWORD, PBOOL);

  struct DeviceState {
    DWORD count = 0;
    ULONG status = 0;
    ULONG problem = 0;
    DWORD error = ERROR_SUCCESS;
  };

  struct DeviceRemovalState {
    DWORD count = 0;
    bool reboot_required = false;
    DWORD error = ERROR_SUCCESS;
  };

  BOOL uninstall_driver_package(
    const std::wstring &inf_path,
    BOOL *reboot_required
  ) {
    HMODULE newdev = LoadLibraryW(L"newdev.dll");
    if (newdev == nullptr) {
      return FALSE;
    }
    auto uninstall = reinterpret_cast<DiUninstallDriverWFunction>(
      GetProcAddress(newdev, "DiUninstallDriverW")
    );
    if (uninstall == nullptr) {
      FreeLibrary(newdev);
      SetLastError(ERROR_PROC_NOT_FOUND);
      return FALSE;
    }
    const BOOL result = uninstall(
      nullptr,
      inf_path.c_str(),
      0,
      reboot_required
    );
    const DWORD error = result ? ERROR_SUCCESS : GetLastError();
    FreeLibrary(newdev);
    SetLastError(error);
    return result;
  }

  std::wstring full_path(const wchar_t *path) {
    const DWORD required = GetFullPathNameW(path, 0, nullptr, nullptr);
    if (required == 0) {
      return {};
    }
    std::vector<wchar_t> buffer(required);
    if (GetFullPathNameW(path, required, buffer.data(), nullptr) == 0) {
      return {};
    }
    return buffer.data();
  }

  bool contains_hardware_id(
    HDEVINFO devices,
    SP_DEVINFO_DATA *device,
    const wchar_t *expected
  ) {
    DWORD type = 0;
    DWORD required = 0;
    SetupDiGetDeviceRegistryPropertyW(
      devices,
      device,
      SPDRP_HARDWAREID,
      &type,
      nullptr,
      0,
      &required
    );
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || type != REG_MULTI_SZ) {
      return false;
    }
    std::vector<BYTE> bytes(required);
    if (!SetupDiGetDeviceRegistryPropertyW(
          devices,
          device,
          SPDRP_HARDWAREID,
          &type,
          bytes.data(),
          required,
          nullptr
        )) {
      return false;
    }
    const auto *cursor = reinterpret_cast<const wchar_t *>(bytes.data());
    while (*cursor != L'\0') {
      if (_wcsicmp(cursor, expected) == 0) {
        return true;
      }
      cursor += std::wcslen(cursor) + 1;
    }
    return false;
  }

  DeviceState query_device_state() {
    DeviceState result;
    HDEVINFO devices = SetupDiGetClassDevsW(
      nullptr,
      nullptr,
      nullptr,
      DIGCF_ALLCLASSES
    );
    if (devices == INVALID_HANDLE_VALUE) {
      result.error = GetLastError();
      return result;
    }

    for (DWORD index = 0;; ++index) {
      SP_DEVINFO_DATA device {};
      device.cbSize = sizeof(device);
      if (!SetupDiEnumDeviceInfo(devices, index, &device)) {
        const DWORD error = GetLastError();
        if (error != ERROR_NO_MORE_ITEMS) {
          result.error = error;
        }
        break;
      }
      if (!contains_hardware_id(devices, &device, kHardwareId)) {
        continue;
      }
      ++result.count;
      ULONG status = 0;
      ULONG problem = 0;
      const CONFIGRET query = CM_Get_DevNode_Status(
        &status,
        &problem,
        device.DevInst,
        0
      );
      if (query != CR_SUCCESS) {
        result.error = ERROR_GEN_FAILURE;
        continue;
      }
      result.status = status;
      result.problem = problem;
    }
    SetupDiDestroyDeviceInfoList(devices);
    return result;
  }

  bool remove_created_device(HDEVINFO devices, SP_DEVINFO_DATA *device) {
    SP_REMOVEDEVICE_PARAMS parameters {};
    parameters.ClassInstallHeader.cbSize = sizeof(parameters.ClassInstallHeader);
    parameters.ClassInstallHeader.InstallFunction = DIF_REMOVE;
    parameters.Scope = DI_REMOVEDEVICE_GLOBAL;
    parameters.HwProfile = 0;
    return SetupDiSetClassInstallParamsW(
             devices,
             device,
             &parameters.ClassInstallHeader,
             sizeof(parameters)
           ) &&
           SetupDiCallClassInstaller(DIF_REMOVE, devices, device);
  }

  bool device_install_requires_restart(
    HDEVINFO devices,
    SP_DEVINFO_DATA *device
  ) {
    SP_DEVINSTALL_PARAMS_W parameters {};
    parameters.cbSize = sizeof(parameters);
    if (!SetupDiGetDeviceInstallParamsW(devices, device, &parameters)) {
      return false;
    }
    return (parameters.Flags & (DI_NEEDREBOOT | DI_NEEDRESTART)) != 0;
  }

  DeviceRemovalState remove_root_devices() {
    DeviceRemovalState result;
    HDEVINFO devices = SetupDiGetClassDevsW(
      nullptr,
      nullptr,
      nullptr,
      DIGCF_ALLCLASSES
    );
    if (devices == INVALID_HANDLE_VALUE) {
      result.error = GetLastError();
      return result;
    }

    for (DWORD index = 0;; ++index) {
      SP_DEVINFO_DATA device {};
      device.cbSize = sizeof(device);
      if (!SetupDiEnumDeviceInfo(devices, index, &device)) {
        const DWORD error = GetLastError();
        if (error != ERROR_NO_MORE_ITEMS) {
          result.error = error;
        }
        break;
      }
      if (!contains_hardware_id(devices, &device, kHardwareId)) {
        continue;
      }
      if (!remove_created_device(devices, &device)) {
        result.error = GetLastError();
        break;
      }
      ++result.count;
      result.reboot_required =
        result.reboot_required ||
        device_install_requires_restart(devices, &device);
    }
    SetupDiDestroyDeviceInfoList(devices);
    return result;
  }

  bool create_root_device(
    const std::wstring &inf_path,
    HDEVINFO *devices_out,
    SP_DEVINFO_DATA *device_out
  ) {
    GUID class_guid {};
    wchar_t class_name[MAX_CLASS_NAME_LEN] {};
    if (!SetupDiGetINFClassW(
          inf_path.c_str(),
          &class_guid,
          class_name,
          MAX_CLASS_NAME_LEN,
          nullptr
        )) {
      return false;
    }

    HDEVINFO devices = SetupDiCreateDeviceInfoList(&class_guid, nullptr);
    if (devices == INVALID_HANDLE_VALUE) {
      return false;
    }
    SP_DEVINFO_DATA device {};
    device.cbSize = sizeof(device);
    if (!SetupDiCreateDeviceInfoW(
          devices,
          class_name,
          &class_guid,
          nullptr,
          nullptr,
          DICD_GENERATE_ID,
          &device
        )) {
      SetupDiDestroyDeviceInfoList(devices);
      return false;
    }

    std::vector<wchar_t> hardware_ids(
      kHardwareId,
      kHardwareId + std::size(kHardwareId)
    );
    hardware_ids.push_back(L'\0');
    if (!SetupDiSetDeviceRegistryPropertyW(
          devices,
          &device,
          SPDRP_HARDWAREID,
          reinterpret_cast<const BYTE *>(hardware_ids.data()),
          static_cast<DWORD>(hardware_ids.size() * sizeof(wchar_t))
        ) ||
        !SetupDiCallClassInstaller(DIF_REGISTERDEVICE, devices, &device)) {
      SetupDiDestroyDeviceInfoList(devices);
      return false;
    }
    *devices_out = devices;
    *device_out = device;
    return true;
  }

  void rollback_created_install(
    const std::wstring &inf_path,
    HDEVINFO devices,
    SP_DEVINFO_DATA *device
  ) {
    remove_created_device(devices, device);
    SetupDiDestroyDeviceInfoList(devices);
    BOOL reboot_required = FALSE;
    uninstall_driver_package(inf_path, &reboot_required);
  }

  int emit_result(
    const wchar_t *operation,
    const wchar_t *result,
    DWORD error,
    ULONG problem
  ) {
    std::wcout << L"{\"operation\":\"" << operation
               << L"\",\"result\":\"" << result
               << L"\",\"win32_error\":" << error
               << L",\"problem_code\":" << problem << L"}\n";
    if (error != ERROR_SUCCESS || std::wcscmp(result, L"error") == 0) {
      return 1;
    }
    return std::wcscmp(result, L"restart_required") == 0 ? ERROR_SUCCESS_REBOOT_REQUIRED : 0;
  }

  int install_driver(const std::wstring &inf_path) {
    DeviceState before = query_device_state();
    if (before.error != ERROR_SUCCESS || before.count > 1) {
      return emit_result(L"install", L"error", before.error, before.problem);
    }

    HDEVINFO created_devices = INVALID_HANDLE_VALUE;
    SP_DEVINFO_DATA created_device {};
    if (before.count == 0 &&
        !create_root_device(inf_path, &created_devices, &created_device)) {
      return emit_result(L"install", L"error", GetLastError(), 0);
    }

    BOOL reboot_required = FALSE;
    const BOOL updated = UpdateDriverForPlugAndPlayDevicesW(
      nullptr,
      kHardwareId,
      inf_path.c_str(),
      INSTALLFLAG_FORCE | INSTALLFLAG_NONINTERACTIVE,
      &reboot_required
    );
    const DWORD update_error = updated ? ERROR_SUCCESS : GetLastError();
    const bool registration_requires_restart =
      created_devices != INVALID_HANDLE_VALUE &&
      device_install_requires_restart(created_devices, &created_device);
    if (!updated) {
      if (created_devices != INVALID_HANDLE_VALUE) {
        rollback_created_install(inf_path, created_devices, &created_device);
      }
      return emit_result(L"install", L"error", update_error, 0);
    }

    const DeviceState after = query_device_state();
    if (after.error != ERROR_SUCCESS || after.count != 1) {
      if (created_devices != INVALID_HANDLE_VALUE) {
        rollback_created_install(inf_path, created_devices, &created_device);
      }
      return emit_result(L"install", L"error", after.error, after.problem);
    }
    if (reboot_required || registration_requires_restart ||
        after.problem == CM_PROB_NEED_RESTART) {
      if (created_devices != INVALID_HANDLE_VALUE) {
        SetupDiDestroyDeviceInfoList(created_devices);
      }
      return emit_result(
        L"install",
        L"restart_required",
        ERROR_SUCCESS,
        after.problem
      );
    }
    if (after.problem != 0) {
      if (created_devices != INVALID_HANDLE_VALUE) {
        rollback_created_install(inf_path, created_devices, &created_device);
      }
      return emit_result(L"install", L"error", ERROR_GEN_FAILURE, after.problem);
    }
    if (created_devices != INVALID_HANDLE_VALUE) {
      SetupDiDestroyDeviceInfoList(created_devices);
    }
    return emit_result(L"install", L"ready", ERROR_SUCCESS, 0);
  }

  int uninstall_driver(const std::wstring &inf_path) {
    const DeviceRemovalState removed = remove_root_devices();
    if (removed.error != ERROR_SUCCESS) {
      return emit_result(L"uninstall", L"error", removed.error, 0);
    }

    const DeviceState after_device_removal = query_device_state();
    if (after_device_removal.error != ERROR_SUCCESS ||
        (!removed.reboot_required && after_device_removal.count != 0)) {
      return emit_result(
        L"uninstall",
        L"error",
        after_device_removal.error == ERROR_SUCCESS
          ? ERROR_GEN_FAILURE
          : after_device_removal.error,
        after_device_removal.problem
      );
    }

    BOOL package_reboot_required = FALSE;
    if (!uninstall_driver_package(inf_path, &package_reboot_required)) {
      const DWORD error = GetLastError();
      if (error != ERROR_FILE_NOT_FOUND) {
        return emit_result(L"uninstall", L"error", error, 0);
      }
    }
    const bool reboot_required =
      removed.reboot_required || package_reboot_required;
    const DeviceState remaining = query_device_state();
    if (remaining.error != ERROR_SUCCESS ||
        (!reboot_required && remaining.count != 0)) {
      return emit_result(
        L"uninstall",
        L"error",
        remaining.error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : remaining.error,
        remaining.problem
      );
    }
    return emit_result(
      L"uninstall",
      reboot_required ? L"restart_required" : L"removed",
      ERROR_SUCCESS,
      0
    );
  }
}  // namespace

int wmain(int argc, wchar_t **argv) {
  if (argc != 3) {
    std::wcerr << L"Usage: LumenDriverSetup.exe <install|uninstall> <absolute-inf-path>\n";
    return ERROR_INVALID_PARAMETER;
  }
  const std::wstring inf_path = full_path(argv[2]);
  if (inf_path.empty() || GetFileAttributesW(inf_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return emit_result(argv[1], L"error", ERROR_FILE_NOT_FOUND, 0);
  }
  if (_wcsicmp(argv[1], L"install") == 0) {
    return install_driver(inf_path);
  }
  if (_wcsicmp(argv[1], L"uninstall") == 0) {
    return uninstall_driver(inf_path);
  }
  return emit_result(argv[1], L"error", ERROR_INVALID_PARAMETER, 0);
}
