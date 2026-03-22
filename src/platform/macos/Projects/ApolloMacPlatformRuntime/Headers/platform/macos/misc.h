/**
 * @file src/platform/macos/Projects/ApolloMacPlatformRuntime/Headers/platform/macos/misc.h
 * @brief Miscellaneous declarations for macOS platform.
 */
#pragma once

// standard includes
#include <vector>

// platform includes
#include <CoreGraphics/CoreGraphics.h>

namespace platf {
  struct capture_request_mirror_state_t {
    std::uint64_t generation;
    bool video_requested;
    bool audio_requested;
    std::uint32_t display_id;
    int codec;
    int preprocess_strategy;
    int queue_profile;
    bool show_cursor;
    int target_frame_rate;
    int requested_width;
    int requested_height;
    int dynamic_range;
    int audio_source_kind;
    bool audio_excludes_current_process;
    int audio_sample_rate;
    int audio_channel_count;
    int audio_frame_size;
  };

  void prepare_app_bundle_environment();
  bool is_screen_capture_allowed();
  void arm_display_wake_watchdog();
  bool isolate_virtual_display(CGDirectDisplayID virtual_display_id);
  void restore_virtual_display_isolation();
  void focus_virtual_display_workspace(CGDirectDisplayID virtual_display_id);
  void log_private_display_control_availability();
  bool sleep_physical_displays();
  bool wake_physical_displays();
  void mirror_capture_request_state(const capture_request_mirror_state_t &state);
  void clear_capture_request_state_mirror();
}

namespace dyn {
  typedef void (*apiproc)();

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict = true);
  void *handle(const std::vector<const char *> &libs);

}  // namespace dyn
