/**
 * @file src/system_tray.cpp
 * @brief Definitions for the system tray icon and notification system.
 */
// macros
#if defined SUNSHINE_TRAY && SUNSHINE_TRAY >= 1

  #if defined(_WIN32)
    #define WIN32_LEAN_AND_MEAN
    #include <accctrl.h>
    #include <aclapi.h>
    #include "platform/windows/utils.h"
    #define TRAY_ICON WEB_DIR "images/apollo.ico"
    #define TRAY_ICON_PLAYING WEB_DIR "images/apollo-playing.ico"
    #define TRAY_ICON_PAUSING WEB_DIR "images/apollo-pausing.ico"
    #define TRAY_ICON_LOCKED WEB_DIR "images/apollo-locked.ico"
  #elif defined(__linux__) || defined(linux) || defined(__linux)
    #define TRAY_ICON SUNSHINE_TRAY_PREFIX "-tray"
    #define TRAY_ICON_PLAYING SUNSHINE_TRAY_PREFIX "-playing"
    #define TRAY_ICON_PAUSING SUNSHINE_TRAY_PREFIX "-pausing"
    #define TRAY_ICON_LOCKED SUNSHINE_TRAY_PREFIX "-locked"
  #elif defined(__APPLE__) || defined(__MACH__)
    #define TRAY_ICON WEB_DIR "images/logo-apollo-16.png"
    #define TRAY_ICON_PLAYING WEB_DIR "images/apollo-playing-16.png"
    #define TRAY_ICON_PAUSING WEB_DIR "images/apollo-pausing-16.png"
    #define TRAY_ICON_LOCKED WEB_DIR "images/apollo-locked-16.png"
    #include <dispatch/dispatch.h>
    #include <mach-o/dyld.h>
  #endif

  #define TRAY_MSG_NO_APP_RUNNING "Reload Apps"

  #ifndef BOOST_PROCESS_VERSION
    #define BOOST_PROCESS_VERSION 1
  #endif

  // standard includes
  #include <atomic>
  #include <chrono>
  #include <csignal>
  #include <filesystem>
  #include <string>
  #include <thread>

  // lib includes
  #include <boost/filesystem.hpp>
  #include <boost/process/v1/environment.hpp>
  #include <tray/src/tray.h>

  // local includes
  #include "config.h"
  #include "shadow_control_http.h"
  #include "display_device.h"
  #include "logging.h"
  #include "platform/common.h"
  #ifdef __APPLE__
    #include "platform/macos/misc.h"
  #endif
  #include "process.h"
  #include "network.h"
  #include "src/entry_handler.h"

using namespace std::literals;

// system_tray namespace
namespace system_tray {
  static std::atomic tray_initialized = false;

  namespace {
#ifdef __APPLE__
    const char *resolved_tray_icon_path(const char *relative_icon_path) {
      static std::string default_icon;
      static std::string locked_icon;
      static std::string playing_icon;
      static std::string pausing_icon;

      auto resolve_icon = [](const char *icon_path) -> std::string {
        uint32_t executable_path_size = 0;
        _NSGetExecutablePath(nullptr, &executable_path_size);

        std::string executable_path(executable_path_size, '\0');
        if (_NSGetExecutablePath(executable_path.data(), &executable_path_size) != 0) {
          return icon_path;
        }

        executable_path.resize(std::strlen(executable_path.c_str()));
        const auto macos_dir = std::filesystem::path(executable_path).parent_path();
        const auto resource_icon_path = macos_dir.parent_path() / "Resources" / "assets" / "web" / "images" / std::filesystem::path(icon_path).filename();
        return resource_icon_path.string();
      };

      if (default_icon.empty()) {
        default_icon = resolve_icon(TRAY_ICON);
        locked_icon = resolve_icon(TRAY_ICON_LOCKED);
        playing_icon = resolve_icon(TRAY_ICON_PLAYING);
        pausing_icon = resolve_icon(TRAY_ICON_PAUSING);
      }

      if (std::strcmp(relative_icon_path, TRAY_ICON_LOCKED) == 0) {
        return locked_icon.c_str();
      }
      if (std::strcmp(relative_icon_path, TRAY_ICON_PLAYING) == 0) {
        return playing_icon.c_str();
      }
      if (std::strcmp(relative_icon_path, TRAY_ICON_PAUSING) == 0) {
        return pausing_icon.c_str();
      }
      return default_icon.c_str();
    }
#else
    const char *resolved_tray_icon_path(const char *icon_path) {
      return icon_path;
    }
#endif
  }  // namespace

  // Threading variables for all platforms
  static std::thread tray_thread;
  static std::atomic tray_thread_running = false;
  static std::atomic tray_thread_should_exit = false;

#ifdef __APPLE__
  namespace {
    void mirror_notification_when_no_tray(
      std::string identifier,
      std::string title,
      std::string body,
      std::string launch_path = {}
    ) {
      if (tray_initialized) {
        return;
      }

      platf::post_runtime_event_notification(identifier, title, body, launch_path);
    }
  }  // namespace
#endif

  void tray_open_ui_cb([[maybe_unused]] struct tray_menu *item) {
    BOOST_LOG(info) << "Opening UI from system tray"sv;
    launch_ui();
  }

  void
  tray_force_stop_cb(struct tray_menu *item) {
    BOOST_LOG(info) << "Force stop from system tray"sv;
    proc::proc.terminate();
  }

  void tray_reset_display_device_config_cb([[maybe_unused]] struct tray_menu *item) {
    BOOST_LOG(info) << "Resetting display device config from system tray"sv;

    std::ignore = display_device::reset_persistence();
  }

  void tray_restart_cb([[maybe_unused]] struct tray_menu *item) {
    BOOST_LOG(info) << "Restarting from system tray"sv;
    platf::restart();
  }

  void tray_quit_cb([[maybe_unused]] struct tray_menu *item) {
    BOOST_LOG(info) << "Quitting from system tray"sv;

    proc::proc.terminate();

  #ifdef _WIN32
    // If we're running in a service, return a special status to
    // tell it to terminate too, otherwise it will just respawn us.
    if (GetConsoleWindow() == nullptr) {
      lifetime::exit_runtime(ERROR_SHUTDOWN_IN_PROGRESS, true);
      return;
    }
  #endif

    lifetime::exit_runtime(0, true);
  }

  // Tray menu
  static struct tray tray = {
#ifdef __APPLE__
    .icon = nullptr,
#else
    .icon = TRAY_ICON,
#endif
    .tooltip = PROJECT_NAME,
    .menu =
      (struct tray_menu[]) {
        // todo - use boost/locale to translate menu strings
        { .text = "Open Apollo", .cb = tray_open_ui_cb },
        { .text = "-" },
        // { .text = "-" },
        // { .text = "Donate",
        //   .submenu =
        //     (struct tray_menu[]) {
        //       { .text = "GitHub Sponsors", .cb = tray_donate_github_cb },
        //       { .text = "MEE6", .cb = tray_donate_mee6_cb },
        //       { .text = "Patreon", .cb = tray_donate_patreon_cb },
        //       { .text = "PayPal", .cb = tray_donate_paypal_cb },
        //       { .text = nullptr } } },
        // { .text = "-" },
        { .text = TRAY_MSG_NO_APP_RUNNING, .cb = tray_force_stop_cb },
  // Currently display device settings are only supported on Windows
  #ifdef _WIN32
        {.text = "Reset Display Device Config", .cb = tray_reset_display_device_config_cb},
  #endif
        {.text = "Restart", .cb = tray_restart_cb},
        {.text = "Quit", .cb = tray_quit_cb},
        {.text = nullptr}
      },
    .iconPathCount = 4,
#ifdef __APPLE__
    .allIconPaths = {nullptr, nullptr, nullptr, nullptr},
#else
    .allIconPaths = {TRAY_ICON, TRAY_ICON_LOCKED, TRAY_ICON_PLAYING, TRAY_ICON_PAUSING},
#endif
  };

  void assign_tray_icon_paths() {
#ifdef __APPLE__
    tray.icon = resolved_tray_icon_path(TRAY_ICON);
    tray.allIconPaths[0] = resolved_tray_icon_path(TRAY_ICON);
    tray.allIconPaths[1] = resolved_tray_icon_path(TRAY_ICON_LOCKED);
    tray.allIconPaths[2] = resolved_tray_icon_path(TRAY_ICON_PLAYING);
    tray.allIconPaths[3] = resolved_tray_icon_path(TRAY_ICON_PAUSING);
#endif
  }

  int init_tray() {
#ifdef __APPLE__
    assign_tray_icon_paths();
#endif
  #ifdef _WIN32
    // If we're running as SYSTEM, Explorer.exe will not have permission to open our thread handle
    // to monitor for thread termination. If Explorer fails to open our thread, our tray icon
    // will persist forever if we terminate unexpectedly. To avoid this, we will modify our thread
    // DACL to add an ACE that allows SYNCHRONIZE access to Everyone.
    {
      PACL old_dacl;
      PSECURITY_DESCRIPTOR sd;
      auto error = GetSecurityInfo(GetCurrentThread(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, &old_dacl, nullptr, &sd);
      if (error != ERROR_SUCCESS) {
        BOOST_LOG(warning) << "GetSecurityInfo() failed: "sv << error;
        return 1;
      }

      auto free_sd = util::fail_guard([sd]() {
        LocalFree(sd);
      });

      SID_IDENTIFIER_AUTHORITY sid_authority = SECURITY_WORLD_SID_AUTHORITY;
      PSID world_sid;
      if (!AllocateAndInitializeSid(&sid_authority, 1, SECURITY_WORLD_RID, 0, 0, 0, 0, 0, 0, 0, &world_sid)) {
        error = GetLastError();
        BOOST_LOG(warning) << "AllocateAndInitializeSid() failed: "sv << error;
        return 1;
      }

      auto free_sid = util::fail_guard([world_sid]() {
        FreeSid(world_sid);
      });

      EXPLICIT_ACCESS ea {};
      ea.grfAccessPermissions = SYNCHRONIZE;
      ea.grfAccessMode = GRANT_ACCESS;
      ea.grfInheritance = NO_INHERITANCE;
      ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
      ea.Trustee.ptstrName = (LPSTR) world_sid;

      PACL new_dacl;
      error = SetEntriesInAcl(1, &ea, old_dacl, &new_dacl);
      if (error != ERROR_SUCCESS) {
        BOOST_LOG(warning) << "SetEntriesInAcl() failed: "sv << error;
        return 1;
      }

      auto free_new_dacl = util::fail_guard([new_dacl]() {
        LocalFree(new_dacl);
      });

      error = SetSecurityInfo(GetCurrentThread(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, new_dacl, nullptr);
      if (error != ERROR_SUCCESS) {
        BOOST_LOG(warning) << "SetSecurityInfo() failed: "sv << error;
        return 1;
      }
    }

    // Wait for the shell to be initialized before registering the tray icon.
    // This ensures the tray icon works reliably after a logoff/logon cycle.
    while (GetShellWindow() == nullptr) {
      Sleep(1000);
    }
  #endif

    if (tray_init(&tray) < 0) {
      BOOST_LOG(warning) << "Failed to create system tray"sv;
      return 1;
    }

    BOOST_LOG(info) << "System tray created"sv;
    tray_initialized = true;
    return 0;
  }

  int process_tray_events() {
    if (!tray_initialized) {
      return 1;
    }

    // Process one iteration of the tray loop with non-blocking mode (0)
    if (const int result = tray_loop(0); result != 0) {
      BOOST_LOG(warning) << "System tray loop failed"sv;
      return result;
    }

    return 0;
  }

  int end_tray() {
    if (tray_initialized) {
      tray_initialized = false;
      tray_exit();
    }
    return 0;
  }

  void update_tray_playing(std::string app_name) {
#ifdef __APPLE__
    mirror_notification_when_no_tray(
      "apollo.app-launched",
      "App launched",
      app_name + " launched."
    );
#endif
    if (!tray_initialized) {
      return;
    }

    tray.notification_title = nullptr;
    tray.notification_text = nullptr;
    tray.notification_cb = nullptr;
    tray.notification_icon = nullptr;
    tray.icon = resolved_tray_icon_path(TRAY_ICON_PLAYING);

    tray_update(&tray);
    tray.icon = resolved_tray_icon_path(TRAY_ICON_PLAYING);
    tray.notification_title = "App launched";
    char msg[256];
    static char force_close_msg[256];
    snprintf(msg, std::size(msg), "%s launched.", app_name.c_str());
    snprintf(force_close_msg, std::size(force_close_msg), "Force close [%s]", app_name.c_str());
  #ifdef _WIN32
    strncpy(msg, utf8ToAcp(msg).c_str(), std::size(msg) - 1);
    strncpy(force_close_msg, utf8ToAcp(force_close_msg).c_str(), std::size(force_close_msg) - 1);
  #endif
    tray.notification_text = msg;
    tray.notification_icon = resolved_tray_icon_path(TRAY_ICON_PLAYING);
    tray.tooltip = PROJECT_NAME;
    tray.menu[2].text = force_close_msg;
    tray_update(&tray);
  }

  void update_tray_pausing(std::string app_name) {
#ifdef __APPLE__
    mirror_notification_when_no_tray(
      "apollo.stream-paused",
      "Stream Paused",
      "Streaming paused for " + app_name
    );
#endif
    if (!tray_initialized) {
      return;
    }

    tray.notification_title = nullptr;
    tray.notification_text = nullptr;
    tray.notification_cb = nullptr;
    tray.notification_icon = nullptr;
    tray.icon = resolved_tray_icon_path(TRAY_ICON_PAUSING);
    tray_update(&tray);
    char msg[256];
    snprintf(msg, std::size(msg), "Streaming paused for %s", app_name.c_str());
  #ifdef _WIN32
    strncpy(msg, utf8ToAcp(msg).c_str(), std::size(msg) - 1);
  #endif
    tray.icon = resolved_tray_icon_path(TRAY_ICON_PAUSING);
    tray.notification_title = "Stream Paused";
    tray.notification_text = msg;
    tray.notification_icon = resolved_tray_icon_path(TRAY_ICON_PAUSING);
    tray.tooltip = PROJECT_NAME;
    tray_update(&tray);
  }

  void update_tray_stopped(std::string app_name) {
#ifdef __APPLE__
    mirror_notification_when_no_tray(
      "apollo.application-stopped",
      "Application Stopped",
      "Streaming stopped for " + app_name
    );
#endif
    if (!tray_initialized) {
      return;
    }

    tray.notification_title = nullptr;
    tray.notification_text = nullptr;
    tray.notification_cb = nullptr;
    tray.notification_icon = nullptr;
    tray.icon = resolved_tray_icon_path(TRAY_ICON);
    tray_update(&tray);
    char msg[256];
    snprintf(msg, std::size(msg), "Streaming stopped for %s", app_name.c_str());
  #ifdef _WIN32
    strncpy(msg, utf8ToAcp(msg).c_str(), std::size(msg) - 1);
  #endif
    tray.icon = resolved_tray_icon_path(TRAY_ICON);
    tray.notification_icon = resolved_tray_icon_path(TRAY_ICON);
    tray.notification_title = "Application Stopped";
    tray.notification_text = msg;
    tray.tooltip = PROJECT_NAME;
    tray.menu[2].text = TRAY_MSG_NO_APP_RUNNING;
    tray_update(&tray);
  }

  void
  update_tray_launch_error(std::string app_name, int exit_code) {
#ifdef __APPLE__
    mirror_notification_when_no_tray(
      "apollo.launch-error",
      "Launch Error",
      "Application " + app_name + " exited too fast with code " + std::to_string(exit_code) + ".",
      "/"
    );
#endif
    if (!tray_initialized) {
      return;
    }

    tray.notification_title = NULL;
    tray.notification_text = NULL;
    tray.notification_cb = NULL;
    tray.notification_icon = NULL;
    tray.icon = resolved_tray_icon_path(TRAY_ICON);
    tray_update(&tray);
    char msg[256];
    snprintf(msg, std::size(msg), "Application %s exited too fast with code %d. Click here to terminate the stream.", app_name.c_str(), exit_code);
  #ifdef _WIN32
    strncpy(msg, utf8ToAcp(msg).c_str(), std::size(msg) - 1);
  #endif
    tray.icon = resolved_tray_icon_path(TRAY_ICON);
    tray.notification_icon = resolved_tray_icon_path(TRAY_ICON);
    tray.notification_title = "Launch Error";
    tray.notification_text = msg;
    tray.notification_cb = []() {
      BOOST_LOG(info) << "Force stop from notification"sv;
      proc::proc.terminate();
    };
    tray.tooltip = PROJECT_NAME;
    tray_update(&tray);
  }

  void update_tray_require_pairing_approval(std::string device_name, std::string user_code) {
#ifdef __APPLE__
    mirror_notification_when_no_tray(
      "apollo.require-pairing-approval",
      "Incoming Pairing Request",
      "Approve " + device_name + " with code " + user_code + ".",
      "/pairing"
    );
#endif
    if (!tray_initialized) {
      return;
    }

    tray.notification_title = nullptr;
    tray.notification_text = nullptr;
    tray.notification_cb = nullptr;
    tray.notification_icon = nullptr;
    tray.icon = resolved_tray_icon_path(TRAY_ICON);
    tray_update(&tray);

    char msg[256];
    snprintf(msg, std::size(msg), "Approve %s with code %s.", device_name.c_str(), user_code.c_str());
#ifdef _WIN32
    strncpy(msg, utf8ToAcp(msg).c_str(), std::size(msg) - 1);
#endif
    tray.icon = resolved_tray_icon_path(TRAY_ICON);
    tray.notification_title = "Incoming Pairing Request";
    tray.notification_text = msg;
    tray.notification_icon = resolved_tray_icon_path(TRAY_ICON_LOCKED);
    tray.tooltip = PROJECT_NAME;
    tray.notification_cb = []() {
      launch_ui("/pairing");
    };
    tray_update(&tray);
  }

  void
  update_tray_paired(std::string device_name) {
#ifdef __APPLE__
    mirror_notification_when_no_tray(
      "apollo.device-paired",
      "Device Paired Successfully",
      "Device " + device_name + " paired successfully."
    );
#endif
    if (!tray_initialized) {
      return;
    }

    tray.notification_title = NULL;
    tray.notification_text = NULL;
    tray.notification_cb = NULL;
    tray.notification_icon = NULL;
    tray_update(&tray);
    char msg[256];
    snprintf(msg, std::size(msg), "Device %s paired Succesfully. Please make sure you have access to the device.", device_name.c_str());
  #ifdef _WIN32
    strncpy(msg, utf8ToAcp(msg).c_str(), std::size(msg) - 1);
  #endif
    tray.notification_title = "Device Paired Succesfully";
    tray.notification_text = msg;
    tray.notification_icon = resolved_tray_icon_path(TRAY_ICON);
    tray.tooltip = PROJECT_NAME;
    tray_update(&tray);
  }

  void
  update_tray_client_connected(std::string client_name) {
#ifdef __APPLE__
    mirror_notification_when_no_tray(
      "apollo.client-connected",
      "Client Connected",
      client_name + " has connected to the session."
    );
#endif
    if (!tray_initialized) {
      return;
    }

    tray.notification_title = NULL;
    tray.notification_text = NULL;
    tray.notification_cb = NULL;
    tray.notification_icon = NULL;
    tray.icon = resolved_tray_icon_path(TRAY_ICON);
    tray_update(&tray);
    char msg[256];
    snprintf(msg, std::size(msg), "%s has connected to the session.", client_name.c_str());
  #ifdef _WIN32
    strncpy(msg, utf8ToAcp(msg).c_str(), std::size(msg) - 1);
  #endif
    tray.notification_title = "Client Connected";
    tray.notification_text = msg;
    tray.notification_icon = resolved_tray_icon_path(TRAY_ICON);
    tray.tooltip = PROJECT_NAME;
    tray_update(&tray);
  }

  // Threading functions available on all platforms
  static void tray_thread_worker() {
    BOOST_LOG(info) << "System tray thread started"sv;

    // Initialize the tray in this thread
    if (init_tray() != 0) {
      BOOST_LOG(error) << "Failed to initialize tray in thread"sv;
      tray_thread_running = false;
      return;
    }

    tray_thread_running = true;

    // Main tray event loop
    while (!tray_thread_should_exit) {
      if (process_tray_events() != 0) {
        BOOST_LOG(warning) << "Tray event processing failed in thread"sv;
        break;
      }

      // Sleep to avoid busy waiting
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    // Clean up the tray
    end_tray();
    tray_thread_running = false;
    BOOST_LOG(info) << "System tray thread ended"sv;
  }

  int init_tray_threaded() {
    if (tray_thread_running) {
      BOOST_LOG(warning) << "Tray thread is already running"sv;
      return 1;
    }

  #ifdef _WIN32
    std::string tmp_str = "Open Apollo (" + config::shadow_http.host_name + ":" + std::to_string(net::map_port(shadow_control_http::PORT_HTTPS)) + ")";
    static const std::string title_str = utf8ToAcp(tmp_str);
  #else
    static const std::string title_str = "Open Apollo (" + config::shadow_http.host_name + ":" + std::to_string(net::map_port(shadow_control_http::PORT_HTTPS)) + ")";
  #endif
    tray.menu[0].text = title_str.c_str();

    if (config::runtime.hide_tray_controls) {
      tray.menu[1].text = nullptr;
    }

    tray_thread_should_exit = false;

    try {
      tray_thread = std::thread(tray_thread_worker);

      // Wait for the thread to start and initialize
      const auto start_time = std::chrono::steady_clock::now();
      while (!tray_thread_running && !tray_thread_should_exit) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));

        // Timeout after 10 seconds
        if (std::chrono::steady_clock::now() - start_time > std::chrono::seconds(10)) {
          BOOST_LOG(error) << "Tray thread initialization timeout"sv;
          tray_thread_should_exit = true;
          if (tray_thread.joinable()) {
            tray_thread.join();
          }
          return 1;
        }
      }

      if (!tray_thread_running) {
        BOOST_LOG(error) << "Tray thread failed to start"sv;
        if (tray_thread.joinable()) {
          tray_thread.join();
        }
        return 1;
      }

      BOOST_LOG(info) << "System tray thread initialized successfully"sv;
      return 0;
    } catch (const std::exception &e) {
      BOOST_LOG(error) << "Failed to create tray thread: " << e.what();
      return 1;
    }
  }

  int end_tray_threaded() {
    if (!tray_thread_running) {
      return 0;
    }

    BOOST_LOG(info) << "Stopping system tray thread"sv;
    tray_thread_should_exit = true;

    if (tray_thread.joinable()) {
      tray_thread.join();
    }

    BOOST_LOG(info) << "System tray thread stopped"sv;
    return 0;
  }

}  // namespace system_tray

  #ifdef BOOST_PROCESS_VERSION
    #undef BOOST_PROCESS_VERSION 1
  #endif

#endif
