#import "LumenHostedRuntime.h"

#import <Foundation/Foundation.h>
#include "platform/macos/misc.h"
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

struct ApolloRuntimeOptions {
  bool enable_legacy_system_tray;
  bool install_signal_handlers;
};

int apollo_run(int argc, char *argv[], const ApolloRuntimeOptions &options);
void apollo_request_shutdown(void);
bool apollo_is_running(void);
void apollo_force_stop_stream(void);

namespace {
  NSString *const hosted_runtime_did_stop_notification_name = @LumenHostedRuntimeDidStopNotification;

  void copy_string_to_buffer(const std::string &message, char *destination, std::size_t capacity) {
    if (!destination || capacity == 0) {
      return;
    }

    destination[0] = '\0';
    if (message.empty()) {
      return;
    }

    std::strncpy(destination, message.c_str(), capacity - 1);
    destination[capacity - 1] = '\0';
  }

  std::string hosted_runtime_executable_name() {
    NSString *bundle_executable_path = NSBundle.mainBundle.executablePath;
    if (bundle_executable_path.length > 0) {
      return bundle_executable_path.UTF8String ?: "Lumen";
    }

    NSString *process_name = NSProcessInfo.processInfo.processName;
    if (process_name.length > 0) {
      return process_name.UTF8String ?: "Lumen";
    }

    return "Lumen";
  }
}

class LumenHostedRuntimeState {
 public:
  bool start(std::string &error_message) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (thread_.joinable()) {
      if (running_.load(std::memory_order_acquire)) {
        return true;
      }
      thread_.join();
    }

    const std::string executable_name = hosted_runtime_executable_name();
    argv_storage_.clear();
    argv_storage_.push_back(executable_name);
    argv_.clear();
    for (std::string &argument : argv_storage_) {
      argv_.push_back(argument.data());
    }
    argv_.push_back(nullptr);

    running_.store(true, std::memory_order_release);
    thread_ = std::thread([this]() {
      const int exit_code = apollo_run(
        static_cast<int>(argv_storage_.size()),
        argv_.data(),
        ApolloRuntimeOptions {
          .enable_legacy_system_tray = false,
          .install_signal_handlers = false,
        }
      );

      {
        std::lock_guard<std::mutex> lock(mutex_);
        last_exit_code_ = exit_code;
        running_.store(false, std::memory_order_release);
      }
      condition_.notify_all();
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:hosted_runtime_did_stop_notification_name object:nil];
      });
    });

    return true;
  }

  void stop() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!thread_.joinable()) {
      running_.store(false, std::memory_order_release);
      return;
    }

    lock.unlock();
    apollo_request_shutdown();
    lock.lock();
    condition_.wait_for(lock, std::chrono::seconds(10), [this]() {
      return !running_.load(std::memory_order_acquire);
    });
    lock.unlock();

    if (thread_.joinable()) {
      thread_.join();
    }
  }

  bool is_running() const {
    return running_.load(std::memory_order_acquire) || apollo_is_running();
  }

  int32_t last_exit_code() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return last_exit_code_;
  }

  ~LumenHostedRuntimeState() {
    stop();
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::atomic<bool> running_ {false};
  std::thread thread_;
  std::vector<std::string> argv_storage_;
  std::vector<char *> argv_;
  int32_t last_exit_code_ = 0;
};

struct LumenHostedRuntimeController {
  LumenHostedRuntimeState state;
};

LumenHostedRuntimeController *LumenHostedRuntimeControllerCreate(void) {
  return new LumenHostedRuntimeController();
}

void LumenHostedRuntimeControllerDestroy(LumenHostedRuntimeController *controller) {
  delete controller;
}

bool LumenHostedRuntimeControllerStart(
  LumenHostedRuntimeController *controller,
  char *error_destination,
  size_t error_capacity
) {
  if (!controller) {
    copy_string_to_buffer("LumenHostedRuntimeControllerStart called with a null controller.", error_destination, error_capacity);
    return false;
  }

  std::string error_message;
  const bool started = controller->state.start(error_message);
  copy_string_to_buffer(error_message, error_destination, error_capacity);
  return started;
}

void LumenHostedRuntimeControllerStop(LumenHostedRuntimeController *controller) {
  if (!controller) {
    return;
  }

  controller->state.stop();
}

bool LumenHostedRuntimeControllerIsRunning(const LumenHostedRuntimeController *controller) {
  if (!controller) {
    return false;
  }

  return controller->state.is_running();
}

int32_t LumenHostedRuntimeControllerCopyLastExitCode(const LumenHostedRuntimeController *controller) {
  if (!controller) {
    return 0;
  }

  return controller->state.last_exit_code();
}

void LumenHostedRuntimeControllerForceStopStream(LumenHostedRuntimeController *controller) {
  if (!controller || !controller->state.is_running()) {
    return;
  }

  apollo_force_stop_stream();
}

bool LumenHostedRuntimeIsAccessibilityPermissionGranted(void) {
  return platf::is_accessibility_allowed();
}

void LumenHostedRuntimeRequestAccessibilityPermission(void) {
  platf::request_accessibility_permission();
}

bool LumenHostedRuntimeIsScreenCapturePermissionGranted(void) {
  return platf::is_screen_capture_allowed();
}

void LumenHostedRuntimeRequestScreenCapturePermission(void) {
  platf::request_screen_capture_permission();
}
