/**
 * @file src/platform/macos/Projects/ApolloMacPlatformRuntime/Headers/platform/macos/misc.h
 * @brief Miscellaneous declarations for macOS platform.
 */
#pragma once

// standard includes
#include <string>
#include <vector>

// platform includes
#include <CoreGraphics/CoreGraphics.h>

// local includes
#include "src/platform/common.h"

namespace platf {
  struct capture_request_mirror_state_t {
    std::uint64_t generation;
    std::uint64_t video_generation;
    std::uint64_t audio_generation;
    bool video_requested;
    bool audio_requested;
    std::uint32_t display_id;
    int codec;
    int preprocess_strategy;
    int queue_profile;
    bool show_cursor;
    int target_frame_rate;
    int target_video_bitrate_kbps;
    int requested_width;
    int requested_height;
    int dynamic_range;
    int client_display_gamut;
    int client_display_transfer;
    int effective_display_gamut;
    int effective_display_transfer;
    bool has_effective_hdr_metadata;
    float client_display_current_edr_headroom;
    float client_display_potential_edr_headroom;
    int client_display_current_peak_luminance_nits;
    int client_display_potential_peak_luminance_nits;
    int requested_dynamic_range_transport;
    bool client_supports_frame_gated_hdr;
    bool client_supports_hdr_tile_overlay;
    bool client_supports_per_frame_hdr_metadata;
    int effective_hdr_red_primary_x;
    int effective_hdr_red_primary_y;
    int effective_hdr_green_primary_x;
    int effective_hdr_green_primary_y;
    int effective_hdr_blue_primary_x;
    int effective_hdr_blue_primary_y;
    int effective_hdr_white_point_x;
    int effective_hdr_white_point_y;
    int effective_hdr_max_display_luminance;
    int effective_hdr_min_display_luminance;
    int effective_hdr_max_content_light_level;
    int effective_hdr_max_frame_average_light_level;
    int effective_hdr_max_full_frame_luminance;
    int audio_source_kind;
    bool audio_excludes_current_process;
    int audio_sample_rate;
    int audio_channel_count;
    int audio_frame_size;
  };

  struct effective_display_state_t {
    int gamut;
    int transfer;
  };

  struct external_capture_display_metadata_t {
    touch_port_t viewport;
    int env_width;
    int env_height;
    float client_offset_x;
    float client_offset_y;
    float scalar_inv;
    bool hdr_active;
    SS_HDR_METADATA hdr_metadata;
  };

  void prepare_app_bundle_environment();
  bool is_accessibility_allowed();
  void request_accessibility_permission();
  bool is_screen_capture_allowed();
  void request_screen_capture_permission();
  void arm_display_wake_watchdog();
  bool isolate_virtual_display(CGDirectDisplayID virtual_display_id);
  void restore_virtual_display_isolation();
  void focus_virtual_display_workspace(CGDirectDisplayID virtual_display_id);
  bool ensure_private_virtual_display_set_active(const char *reason);
  void log_private_display_control_availability();
  bool sleep_physical_displays();
  bool wake_physical_displays();
  void mirror_capture_request_state(const capture_request_mirror_state_t &state);
  void clear_capture_request_state_mirror();
  void post_runtime_event_notification(
    const std::string &identifier,
    const std::string &title,
    const std::string &body,
    const std::string &launch_path
  );
  void post_runtime_web_ui_ready_notification(const std::string &url);
  effective_display_state_t resolve_capture_request_effective_display_state(
    std::uint32_t display_id,
    int dynamic_range,
    int client_display_gamut,
    int client_display_transfer
  );
  bool resolve_effective_display_hdr_metadata(
    int effective_display_gamut,
    int effective_display_transfer,
    float client_display_current_edr_headroom,
    float client_display_potential_edr_headroom,
    int client_display_current_peak_luminance_nits,
    int client_display_potential_peak_luminance_nits,
    SS_HDR_METADATA &metadata
  );
  bool query_external_capture_display_metadata(
    const std::string &display_name,
    int target_width,
    int target_height,
    external_capture_display_metadata_t &metadata
  );
}

namespace dyn {
  typedef void (*apiproc)();

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict = true);
  void *handle(const std::vector<const char *> &libs);

}  // namespace dyn
