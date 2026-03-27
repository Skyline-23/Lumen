/**
 * @file src/platform/macos/Projects/ApolloMacPlatformRuntime/Sources/misc.mm
 * @brief Miscellaneous definitions for macOS platform.
 */

// Required for IPV6_PKTINFO with Darwin headers
#ifndef __APPLE_USE_RFC_3542  // NOLINT(bugprone-reserved-identifier)
  #define __APPLE_USE_RFC_3542 1
#endif

// standard includes
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <ifaddrs.h>
#include <optional>

// platform includes
#include <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <net/if_dl.h>
#include <spawn.h>
#include <pwd.h>
#include <unistd.h>

extern char **environ;

// lib includes
#include <boost/asio/ip/address.hpp>
#include <boost/asio/ip/host_name.hpp>
#include <boost/process/v1.hpp>

// local includes
#include "platform/macos/misc.h"
#include "src/config.h"
#include "src/entry_handler.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/video.h"

using namespace std::literals;
namespace fs = std::filesystem;
namespace bp = boost::process::v1;

namespace platf {

// Even though the following two functions are available starting in macOS 10.15, they weren't
// actually in the Mac SDK until Xcode 12.2, the first to include the SDK for macOS 11
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 110000  // __MAC_11_0
  // If they're not in the SDK then we can use our own function definitions.
  // Need to use weak import so that this will link in macOS 10.14 and earlier
  extern "C" bool CGPreflightScreenCaptureAccess(void) __attribute__((weak_import));
  extern "C" bool CGRequestScreenCaptureAccess(void) __attribute__((weak_import));
#endif

  namespace {
    auto screen_capture_allowed = std::atomic<bool> {false};
    auto screen_capture_warning_logged = std::atomic<bool> {false};
    struct display_layout_entry_t {
      CGDirectDisplayID display_id;
      CGPoint origin;
      CGDirectDisplayID mirror_master;
    };

    std::mutex virtual_display_layout_mutex;
    std::vector<display_layout_entry_t> virtual_display_layout_snapshot;
    bool virtual_display_layout_active = false;
    bool private_display_set_active = false;
    int private_display_set_previous = 0;
    std::atomic<bool> accessibility_prompt_requested = false;
    std::once_flag private_display_control_log_once;
    constexpr int32_t kVirtualIsolationParkOriginX = -32768;
    constexpr int32_t kVirtualIsolationParkOriginY = 0;
    constexpr int32_t kVirtualIsolationParkSpacingY = 4096;
    constexpr std::string_view kCaptureRequestMirrorFileName = "capture_request_state.plist"sv;
    NSString *const kCaptureRequestMirrorNotificationName = @"com.lizardbyte.apollo.capture-request-changed";
    NSString *const kApolloRuntimeEventNotificationName = @"ApolloRuntimeEventNotification";
    NSString *const kApolloRuntimeWebUIReadyNotificationName = @"ApolloRuntimeWebUIReadyNotification";
    NSString *const kApolloRuntimeEventIdentifierKey = @"identifier";
    NSString *const kApolloRuntimeEventTitleKey = @"title";
    NSString *const kApolloRuntimeEventBodyKey = @"body";
    NSString *const kApolloRuntimeEventLaunchPathKey = @"launchPath";
    NSString *const kApolloRuntimeWebUIReadyURLKey = @"url";

    struct private_display_control_api_t {
      void *handle = nullptr;
      dyn::apiproc cgx_current_display_set = nullptr;
      dyn::apiproc cgx_select_display_set = nullptr;
      dyn::apiproc cgx_set_display_set = nullptr;
      dyn::apiproc coredisplay_display_is_main = nullptr;
      dyn::apiproc ws_canonical_mirror_master_for_display_device = nullptr;
      dyn::apiproc ws_display_is_canonical_mirror_master = nullptr;
      dyn::apiproc cgx_vfb_select_online_state = nullptr;
    };

    dyn::apiproc load_private_symbol(void *handle, const char *symbol_name) {
      if (handle == nullptr || symbol_name == nullptr || symbol_name[0] == '\0') {
        return nullptr;
      }

      if (auto *symbol = reinterpret_cast<dyn::apiproc>(dlsym(handle, symbol_name)); symbol != nullptr) {
        return symbol;
      }

      if (symbol_name[0] == '_') {
        if (auto *symbol = reinterpret_cast<dyn::apiproc>(dlsym(handle, symbol_name + 1)); symbol != nullptr) {
          return symbol;
        }
      }

      std::string underscored_name = "_";
      underscored_name += symbol_name;
      return reinterpret_cast<dyn::apiproc>(dlsym(handle, underscored_name.c_str()));
    }

    private_display_control_api_t load_private_display_control_api() {
      private_display_control_api_t api;
      api.handle = dyn::handle({
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
      });
      if (!api.handle) {
        return api;
      }

      api.cgx_current_display_set = load_private_symbol(api.handle, "CGXCurrentDisplaySet");
      api.cgx_select_display_set = load_private_symbol(api.handle, "CGXSelectDisplaySet");
      api.cgx_set_display_set = load_private_symbol(api.handle, "CGXSetDisplaySet");
      api.coredisplay_display_is_main = load_private_symbol(api.handle, "CoreDisplay_Display_IsMain");
      api.ws_canonical_mirror_master_for_display_device = load_private_symbol(api.handle, "WSCanonicalMirrorMasterForDisplayDevice");
      api.ws_display_is_canonical_mirror_master = load_private_symbol(api.handle, "WSDisplayIsCanonicalMirrorMaster");
      api.cgx_vfb_select_online_state = load_private_symbol(api.handle, "CGXVFBSelectOnlineState");
      return api;
    }

    NSURL *capture_request_mirror_url() {
      auto directory = appdata();
      std::error_code ec;
      fs::create_directories(directory, ec);
      if (ec) {
        BOOST_LOG(warning) << "Unable to create Apollo appdata directory for capture request mirroring: "sv << ec.message();
      }

      const auto mirror_path = directory / kCaptureRequestMirrorFileName;
      return [NSURL fileURLWithPath:[NSString stringWithUTF8String:mirror_path.string().c_str()]];
    }

    void post_capture_request_mirror_notification() {
      CFNotificationCenterPostNotification(
        CFNotificationCenterGetDistributedCenter(),
        (__bridge CFStringRef) kCaptureRequestMirrorNotificationName,
        nullptr,
        nullptr,
        true
      );
    }

    NSDictionary *capture_request_dictionary(const capture_request_mirror_state_t &state) {
      return @{
        @"generation": @(state.generation),
        @"videoGeneration": @(state.video_generation),
        @"audioGeneration": @(state.audio_generation),
        @"videoRequested": @(state.video_requested),
        @"audioRequested": @(state.audio_requested),
        @"displayID": @(state.display_id),
        @"codec": @(state.codec),
        @"preprocessStrategy": @(state.preprocess_strategy),
        @"queueProfile": @(state.queue_profile),
        @"showCursor": @(state.show_cursor),
        @"targetFrameRate": @(state.target_frame_rate),
        @"targetVideoBitrateKbps": @(state.target_video_bitrate_kbps),
        @"requestedWidth": @(state.requested_width),
        @"requestedHeight": @(state.requested_height),
        @"clientSinkGamut": @(state.client_sink_gamut),
        @"clientSinkTransfer": @(state.client_sink_transfer),
        @"effectiveSinkGamut": @(state.effective_sink_gamut),
        @"effectiveSinkTransfer": @(state.effective_sink_transfer),
        @"hasEffectiveHDRMetadata": @(state.has_effective_hdr_metadata),
        @"clientSinkCurrentEDRHeadroom": @(state.client_sink_current_edr_headroom),
        @"clientSinkPotentialEDRHeadroom": @(state.client_sink_potential_edr_headroom),
        @"clientSinkCurrentPeakLuminanceNits": @(state.client_sink_current_peak_luminance_nits),
        @"clientSinkPotentialPeakLuminanceNits": @(state.client_sink_potential_peak_luminance_nits),
        @"requestedDynamicRangeTransport": @(state.requested_dynamic_range_transport),
        @"clientSinkSupportsFrameGatedHDR": @(state.client_sink_supports_frame_gated_hdr),
        @"clientSinkSupportsHDRTileOverlay": @(state.client_sink_supports_hdr_tile_overlay),
        @"clientSinkSupportsPerFrameHDRMetadata": @(state.client_sink_supports_per_frame_hdr_metadata),
        @"effectiveHDRRedPrimaryX": @(state.effective_hdr_red_primary_x),
        @"effectiveHDRRedPrimaryY": @(state.effective_hdr_red_primary_y),
        @"effectiveHDRGreenPrimaryX": @(state.effective_hdr_green_primary_x),
        @"effectiveHDRGreenPrimaryY": @(state.effective_hdr_green_primary_y),
        @"effectiveHDRBluePrimaryX": @(state.effective_hdr_blue_primary_x),
        @"effectiveHDRBluePrimaryY": @(state.effective_hdr_blue_primary_y),
        @"effectiveHDRWhitePointX": @(state.effective_hdr_white_point_x),
        @"effectiveHDRWhitePointY": @(state.effective_hdr_white_point_y),
        @"effectiveHDRMaxDisplayLuminance": @(state.effective_hdr_max_display_luminance),
        @"effectiveHDRMinDisplayLuminance": @(state.effective_hdr_min_display_luminance),
        @"effectiveHDRMaxContentLightLevel": @(state.effective_hdr_max_content_light_level),
        @"effectiveHDRMaxFrameAverageLightLevel": @(state.effective_hdr_max_frame_average_light_level),
        @"effectiveHDRMaxFullFrameLuminance": @(state.effective_hdr_max_full_frame_luminance),
        @"audioSourceKind": @(state.audio_source_kind),
        @"audioExcludesCurrentProcess": @(state.audio_excludes_current_process),
        @"audioSampleRate": @(state.audio_sample_rate),
        @"audioChannelCount": @(state.audio_channel_count),
        @"audioFrameSize": @(state.audio_frame_size),
      };
    }

    struct capture_request_hdr_preferences_t {
      int client_sink_gamut = 0;
      int client_sink_transfer = 0;
      int effective_sink_gamut = 0;
      int effective_sink_transfer = 0;
      bool has_effective_hdr_metadata = false;
      float client_sink_current_edr_headroom = 0.0f;
      float client_sink_potential_edr_headroom = 0.0f;
      int client_sink_current_peak_luminance_nits = 0;
      int client_sink_potential_peak_luminance_nits = 0;
      int requested_dynamic_range_transport = 0;
      bool client_sink_supports_frame_gated_hdr = false;
      bool client_sink_supports_hdr_tile_overlay = false;
      bool client_sink_supports_per_frame_hdr_metadata = false;
      int target_video_bitrate_kbps = 0;
      SS_HDR_METADATA effective_hdr_metadata {};
    };

    NSScreen *reference_screen_for_virtual_display_negotiation() {
      NSScreen *reference_screen = [NSScreen mainScreen];
      if (reference_screen == nil && [NSScreen screens].count > 0) {
        reference_screen = [NSScreen screens].firstObject;
      }
      return reference_screen;
    }

    bool screen_prefers_display_p3(NSScreen *screen) {
      if (screen == nil) {
        return false;
      }

      NSColorSpace *color_space = screen.colorSpace;
      if (color_space == nil) {
        return false;
      }

      if ([color_space respondsToSelector:sel_registerName("displayGamut")]) {
        NSNumber *display_gamut = [color_space valueForKey:@"displayGamut"];
        if (display_gamut != nil && display_gamut.integerValue == 1) {
          return true;
        }
      }

      NSString *localized_name = color_space.localizedName.lowercaseString;
      return [localized_name containsString:@"display p3"] || [localized_name containsString:@"p3"];
    }

    std::string_view display_gamut_label(const int gamut) {
      using gamut_e = video::client_sink_gamut_e;
      switch (static_cast<gamut_e>(gamut)) {
        case gamut_e::srgb:
          return "srgb"sv;
        case gamut_e::display_p3:
          return "display-p3"sv;
        case gamut_e::rec2020:
          return "rec2020"sv;
        case gamut_e::unknown:
        default:
          return "unknown"sv;
      }
    }

    std::optional<capture_request_hdr_preferences_t> read_capture_request_hdr_preferences() {
      @autoreleasepool {
        NSError *error = nil;
        auto *data = [NSData dataWithContentsOfURL:capture_request_mirror_url()
                                          options:0
                                            error:&error];
        if (data == nil) {
          return std::nullopt;
        }

        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:&format
                                                               error:&error];
        auto *dictionary = [plist isKindOfClass:[NSDictionary class]] ? (NSDictionary *) plist : nil;
        if (dictionary == nil) {
          BOOST_LOG(warning) << "Unable to parse mirrored Apollo capture request HDR preferences";
          return std::nullopt;
        }

        NSNumber *client_sink_gamut = dictionary[@"clientSinkGamut"];
        NSNumber *client_sink_transfer = dictionary[@"clientSinkTransfer"];
        NSNumber *effective_sink_gamut = dictionary[@"effectiveSinkGamut"];
        NSNumber *effective_sink_transfer = dictionary[@"effectiveSinkTransfer"];
        NSNumber *has_effective_hdr_metadata = dictionary[@"hasEffectiveHDRMetadata"];
        NSNumber *client_sink_current_edr_headroom = dictionary[@"clientSinkCurrentEDRHeadroom"];
        NSNumber *client_sink_potential_edr_headroom = dictionary[@"clientSinkPotentialEDRHeadroom"];
        NSNumber *client_sink_current_peak_luminance_nits = dictionary[@"clientSinkCurrentPeakLuminanceNits"];
        NSNumber *client_sink_potential_peak_luminance_nits = dictionary[@"clientSinkPotentialPeakLuminanceNits"];
        NSNumber *requested_dynamic_range_transport = dictionary[@"requestedDynamicRangeTransport"];
        NSNumber *client_sink_supports_frame_gated_hdr = dictionary[@"clientSinkSupportsFrameGatedHDR"];
        NSNumber *client_sink_supports_hdr_tile_overlay = dictionary[@"clientSinkSupportsHDRTileOverlay"];
        NSNumber *client_sink_supports_per_frame_hdr_metadata = dictionary[@"clientSinkSupportsPerFrameHDRMetadata"];
        NSNumber *target_video_bitrate_kbps = dictionary[@"targetVideoBitrateKbps"];
        if (client_sink_gamut == nil || client_sink_transfer == nil) {
          return std::nullopt;
        }

        capture_request_hdr_preferences_t preferences;
        preferences.client_sink_gamut = [client_sink_gamut intValue];
        preferences.client_sink_transfer = [client_sink_transfer intValue];
        preferences.effective_sink_gamut = effective_sink_gamut != nil ? [effective_sink_gamut intValue] : 0;
        preferences.effective_sink_transfer = effective_sink_transfer != nil ? [effective_sink_transfer intValue] : 0;
        preferences.client_sink_current_edr_headroom =
          client_sink_current_edr_headroom != nil ? [client_sink_current_edr_headroom floatValue] : 0.0f;
        preferences.client_sink_potential_edr_headroom =
          client_sink_potential_edr_headroom != nil ? [client_sink_potential_edr_headroom floatValue] : 0.0f;
        preferences.client_sink_current_peak_luminance_nits =
          client_sink_current_peak_luminance_nits != nil ? [client_sink_current_peak_luminance_nits intValue] : 0;
        preferences.client_sink_potential_peak_luminance_nits =
          client_sink_potential_peak_luminance_nits != nil ? [client_sink_potential_peak_luminance_nits intValue] : 0;
        preferences.requested_dynamic_range_transport =
          requested_dynamic_range_transport != nil ? [requested_dynamic_range_transport intValue] : 0;
        preferences.client_sink_supports_frame_gated_hdr =
          client_sink_supports_frame_gated_hdr != nil ? [client_sink_supports_frame_gated_hdr boolValue] : false;
        preferences.client_sink_supports_hdr_tile_overlay =
          client_sink_supports_hdr_tile_overlay != nil ? [client_sink_supports_hdr_tile_overlay boolValue] : false;
        preferences.client_sink_supports_per_frame_hdr_metadata =
          client_sink_supports_per_frame_hdr_metadata != nil ? [client_sink_supports_per_frame_hdr_metadata boolValue] : false;
        preferences.target_video_bitrate_kbps =
          target_video_bitrate_kbps != nil ? [target_video_bitrate_kbps intValue] : 0;

        if (has_effective_hdr_metadata.boolValue) {
          preferences.has_effective_hdr_metadata = true;
          preferences.effective_hdr_metadata.displayPrimaries[0] = {
            static_cast<uint16_t>([dictionary[@"effectiveHDRRedPrimaryX"] intValue]),
            static_cast<uint16_t>([dictionary[@"effectiveHDRRedPrimaryY"] intValue]),
          };
          preferences.effective_hdr_metadata.displayPrimaries[1] = {
            static_cast<uint16_t>([dictionary[@"effectiveHDRGreenPrimaryX"] intValue]),
            static_cast<uint16_t>([dictionary[@"effectiveHDRGreenPrimaryY"] intValue]),
          };
          preferences.effective_hdr_metadata.displayPrimaries[2] = {
            static_cast<uint16_t>([dictionary[@"effectiveHDRBluePrimaryX"] intValue]),
            static_cast<uint16_t>([dictionary[@"effectiveHDRBluePrimaryY"] intValue]),
          };
          preferences.effective_hdr_metadata.whitePoint = {
            static_cast<uint16_t>([dictionary[@"effectiveHDRWhitePointX"] intValue]),
            static_cast<uint16_t>([dictionary[@"effectiveHDRWhitePointY"] intValue]),
          };
          preferences.effective_hdr_metadata.maxDisplayLuminance =
            static_cast<uint32_t>([dictionary[@"effectiveHDRMaxDisplayLuminance"] intValue]);
          preferences.effective_hdr_metadata.minDisplayLuminance =
            static_cast<uint32_t>([dictionary[@"effectiveHDRMinDisplayLuminance"] intValue]);
          preferences.effective_hdr_metadata.maxContentLightLevel =
            static_cast<uint16_t>([dictionary[@"effectiveHDRMaxContentLightLevel"] intValue]);
          preferences.effective_hdr_metadata.maxFrameAverageLightLevel =
            static_cast<uint16_t>([dictionary[@"effectiveHDRMaxFrameAverageLightLevel"] intValue]);
          preferences.effective_hdr_metadata.maxFullFrameLuminance =
            static_cast<uint16_t>([dictionary[@"effectiveHDRMaxFullFrameLuminance"] intValue]);
        }

        return preferences;
      }
    }

    effective_display_state_t resolve_capture_request_effective_display_state_impl(
      NSScreen *screen,
      video::dynamic_range_transport_e requested_dynamic_range_transport,
      int client_sink_gamut,
      int client_sink_transfer
    ) {
      using gamut_e = video::client_sink_gamut_e;
      using transfer_e = video::client_sink_transfer_e;

      effective_display_state_t state {
        .gamut = static_cast<int>(gamut_e::unknown),
        .transfer = static_cast<int>(transfer_e::unknown),
      };

      switch (static_cast<gamut_e>(client_sink_gamut)) {
        case gamut_e::display_p3:
          state.gamut = static_cast<int>(gamut_e::display_p3);
          break;
        case gamut_e::rec2020:
          state.gamut = static_cast<int>(gamut_e::rec2020);
          break;
        case gamut_e::srgb:
          state.gamut = static_cast<int>(gamut_e::srgb);
          break;
        case gamut_e::unknown:
        default:
          state.gamut = static_cast<int>(
            screen_prefers_display_p3(screen != nil ? screen : reference_screen_for_virtual_display_negotiation()) ?
              gamut_e::display_p3 :
              gamut_e::srgb
          );
          break;
      }

      if (!video::dynamic_range_transport_uses_hdr_stream(
            video::effective_dynamic_range_transport(requested_dynamic_range_transport)
          )) {
        state.transfer = static_cast<int>(transfer_e::sdr);
        return state;
      }

      switch (static_cast<transfer_e>(client_sink_transfer)) {
        case transfer_e::hlg:
          state.transfer = static_cast<int>(transfer_e::hlg);
          break;
        case transfer_e::sdr:
          state.transfer = static_cast<int>(transfer_e::sdr);
          break;
        case transfer_e::pq:
        case transfer_e::unknown:
        default:
          state.transfer = static_cast<int>(transfer_e::pq);
          break;
      }

      return state;
    }

    std::pair<uint32_t, std::string_view> resolve_effective_display_peak_luminance_nits(
      int effective_sink_gamut,
      int client_sink_current_peak_luminance_nits,
      int client_sink_potential_peak_luminance_nits
    ) {
      using gamut_e = video::client_sink_gamut_e;

      if (client_sink_potential_peak_luminance_nits > 0) {
        return {
          static_cast<uint32_t>(client_sink_potential_peak_luminance_nits),
          "client-potential-peak"
        };
      }

      if (client_sink_current_peak_luminance_nits > 0) {
        return {
          static_cast<uint32_t>(client_sink_current_peak_luminance_nits),
          "client-current-peak"
        };
      }

      const auto fallback_peak =
        static_cast<gamut_e>(effective_sink_gamut) == gamut_e::display_p3 ?
          1000u :
          600u;
      return {fallback_peak, "legacy-fallback"};
    }

    bool resolve_effective_display_hdr_metadata_impl(
      int effective_sink_gamut,
      int effective_sink_transfer,
      float client_sink_current_edr_headroom,
      float client_sink_potential_edr_headroom,
      int client_sink_current_peak_luminance_nits,
      int client_sink_potential_peak_luminance_nits,
      std::string_view *peak_source,
      SS_HDR_METADATA &metadata
    ) {
      using gamut_e = video::client_sink_gamut_e;
      using transfer_e = video::client_sink_transfer_e;

      if (static_cast<transfer_e>(effective_sink_transfer) != transfer_e::pq) {
        return false;
      }

      std::memset(&metadata, 0, sizeof(metadata));
      metadata.whitePoint = {15635, 16450};
      metadata.minDisplayLuminance = 10;  // 0.001 nits in 1/10000th units

      const bool use_display_p3 = static_cast<gamut_e>(effective_sink_gamut) == gamut_e::display_p3;
      const auto [chosen_peak_luminance_nits, resolved_peak_source] = resolve_effective_display_peak_luminance_nits(
        effective_sink_gamut,
        client_sink_current_peak_luminance_nits,
        client_sink_potential_peak_luminance_nits
      );
      const auto chosen_frame_average_light_level = static_cast<uint16_t>(std::min<uint32_t>(
        chosen_peak_luminance_nits,
        static_cast<uint32_t>(std::lround(static_cast<double>(chosen_peak_luminance_nits) * 0.4))
      ));
      if (use_display_p3) {
        metadata.displayPrimaries[0] = {34000, 16000};
        metadata.displayPrimaries[1] = {13250, 34500};
        metadata.displayPrimaries[2] = {7500, 3000};
      } else {
        metadata.displayPrimaries[0] = {32000, 16500};
        metadata.displayPrimaries[1] = {15000, 30000};
        metadata.displayPrimaries[2] = {7500, 3000};
      }
      metadata.maxDisplayLuminance = chosen_peak_luminance_nits;
      metadata.maxContentLightLevel = static_cast<uint16_t>(chosen_peak_luminance_nits);
      metadata.maxFrameAverageLightLevel = chosen_frame_average_light_level;
      metadata.maxFullFrameLuminance = static_cast<uint16_t>(chosen_peak_luminance_nits);

      if (peak_source != nullptr) {
        *peak_source = resolved_peak_source;
      }

      BOOST_LOG(info) << "Resolved effective HDR metadata from negotiated display characteristics"
                      << " gamut="sv << display_gamut_label(effective_sink_gamut)
                      << " transfer="sv << effective_sink_transfer
                      << " current-edr-headroom="sv << client_sink_current_edr_headroom
                      << " potential-edr-headroom="sv << client_sink_potential_edr_headroom
                      << " current-peak-nits="sv << client_sink_current_peak_luminance_nits
                      << " potential-peak-nits="sv << client_sink_potential_peak_luminance_nits
                      << " chosen-peak-source="sv << resolved_peak_source
                      << " chosen-peak-nits="sv << chosen_peak_luminance_nits;

      return true;
    }

    bool bridge_aligned_external_capture_hdr_metadata(
      const capture_request_hdr_preferences_t &preferences,
      NSScreen *screen,
      SS_HDR_METADATA &metadata
    ) {
      if (preferences.has_effective_hdr_metadata) {
        metadata = preferences.effective_hdr_metadata;
        BOOST_LOG(info) << "macOS external capture HDR metadata resolved from mirrored negotiated payload";
        return true;
      }

      auto effective_state =
        preferences.effective_sink_gamut != 0 && preferences.effective_sink_transfer != 0 ?
          effective_display_state_t {
            .gamut = preferences.effective_sink_gamut,
            .transfer = preferences.effective_sink_transfer,
          } :
          resolve_capture_request_effective_display_state_impl(
            screen,
            static_cast<video::dynamic_range_transport_e>(preferences.requested_dynamic_range_transport),
            preferences.client_sink_gamut,
            preferences.client_sink_transfer
          );

      if (!video::dynamic_range_transport_uses_hdr_stream(
            video::effective_dynamic_range_transport(preferences.requested_dynamic_range_transport)
          )) {
        return false;
      }

      std::string_view peak_source {"none"};
      if (!resolve_effective_display_hdr_metadata_impl(
            effective_state.gamut,
            effective_state.transfer,
            preferences.client_sink_current_edr_headroom,
            preferences.client_sink_potential_edr_headroom,
            preferences.client_sink_current_peak_luminance_nits,
            preferences.client_sink_potential_peak_luminance_nits,
            &peak_source,
            metadata
          )) {
        return false;
      }

      BOOST_LOG(info) << "macOS external capture HDR metadata negotiation resolved from mirrored capture request"
                      << " requested-gamut="sv << display_gamut_label(preferences.client_sink_gamut)
                      << " effective-gamut="sv << display_gamut_label(effective_state.gamut)
                      << " requested-transfer="sv << preferences.client_sink_transfer
                      << " effective-transfer="sv << effective_state.transfer
                      << " current-edr-headroom="sv << preferences.client_sink_current_edr_headroom
                      << " potential-edr-headroom="sv << preferences.client_sink_potential_edr_headroom
                      << " current-peak-nits="sv << preferences.client_sink_current_peak_luminance_nits
                      << " potential-peak-nits="sv << preferences.client_sink_potential_peak_luminance_nits
                      << " peak-source="sv << peak_source
                      << " max-display-nits="sv << metadata.maxDisplayLuminance;
      return true;
    }

    using cgx_current_display_set_t = int (*)();
    using cgx_select_display_set_t = int (*)(int);
    using cgx_set_display_set_t = int (*)(int);
    using cgx_vfb_select_online_state_t = int (*)(int);

    bool apply_private_virtual_display_set(int requested_set) {
      const auto api = load_private_display_control_api();
      if (!api.handle) {
        return false;
      }

      int previous_set = requested_set;
      if (api.cgx_current_display_set != nullptr) {
        previous_set = reinterpret_cast<cgx_current_display_set_t>(api.cgx_current_display_set)();
      }

      bool any_call_succeeded = false;
      if (api.cgx_select_display_set != nullptr) {
        const auto rc = reinterpret_cast<cgx_select_display_set_t>(api.cgx_select_display_set)(requested_set);
        BOOST_LOG(info) << "macOS private display set select requested="sv << requested_set << " previous="sv << previous_set << " rc="sv << rc;
        any_call_succeeded = true;
      } else if (api.cgx_set_display_set != nullptr) {
        const auto rc = reinterpret_cast<cgx_set_display_set_t>(api.cgx_set_display_set)(requested_set);
        BOOST_LOG(info) << "macOS private display set apply requested="sv << requested_set << " previous="sv << previous_set << " rc="sv << rc;
        any_call_succeeded = true;
      }

      if (api.cgx_vfb_select_online_state != nullptr) {
        const auto rc = reinterpret_cast<cgx_vfb_select_online_state_t>(api.cgx_vfb_select_online_state)(requested_set);
        BOOST_LOG(info) << "macOS private VFB online state requested="sv << requested_set << " rc="sv << rc;
        any_call_succeeded = true;
      }

      if (!any_call_succeeded) {
        return false;
      }

      if (requested_set != 0) {
        private_display_set_previous = previous_set;
        private_display_set_active = true;
      } else {
        private_display_set_active = false;
      }

      return true;
    }

    int current_private_display_set() {
      const auto api = load_private_display_control_api();
      if (!api.handle || api.cgx_current_display_set == nullptr) {
        return 0;
      }

      return reinterpret_cast<cgx_current_display_set_t>(api.cgx_current_display_set)();
    }

    uint32_t refresh_active_display_ids(std::vector<CGDirectDisplayID> &display_ids) {
      uint32_t active_count = 0;
      if (CGGetActiveDisplayList(0, nullptr, &active_count) != kCGErrorSuccess || active_count == 0) {
        return 0;
      }

      display_ids.assign(active_count, kCGNullDirectDisplay);
      if (CGGetActiveDisplayList(active_count, display_ids.data(), &active_count) != kCGErrorSuccess) {
        display_ids.clear();
        return 0;
      }

      display_ids.resize(active_count);
      return active_count;
    }

    void open_accessibility_settings() {
      NSURL *settings_url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
      if (settings_url == nil) {
        return;
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSWorkspace sharedWorkspace] openURL:settings_url];
      });
    }

    void open_screen_capture_settings() {
      NSURL *settings_url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"];
      if (settings_url == nil) {
        return;
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSWorkspace sharedWorkspace] openURL:settings_url];
      });
    }

    void prompt_for_accessibility_permission_once() {
      if (accessibility_prompt_requested.exchange(true)) {
        return;
      }

      CFTypeRef keys[] = {kAXTrustedCheckOptionPrompt};
      CFTypeRef values[] = {kCFBooleanTrue};
      CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFCopyStringDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
      );
      if (options != nullptr) {
        AXIsProcessTrustedWithOptions(options);
        CFRelease(options);
      }
    }

    bool refresh_screen_capture_permission_state() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
      if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {10, 15, 0})] &&
          CGPreflightScreenCaptureAccess != nullptr) {
        const bool allowed = CGPreflightScreenCaptureAccess();
        screen_capture_allowed = allowed;
        return allowed;
      }
#pragma clang diagnostic pop

      screen_capture_allowed = true;
      return true;
    }

  }  // namespace

  bool is_accessibility_allowed() {
    return AXIsProcessTrusted();
  }

  void request_accessibility_permission() {
    if (is_accessibility_allowed()) {
      return;
    }

    prompt_for_accessibility_permission_once();
    open_accessibility_settings();
  }

  // Return whether screen capture is allowed for this process.
  bool is_screen_capture_allowed() {
    refresh_screen_capture_permission_state();
    return screen_capture_allowed;
  }

  void request_screen_capture_permission() {
    if (refresh_screen_capture_permission_state()) {
      return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {10, 15, 0})] &&
        CGRequestScreenCaptureAccess != nullptr) {
      const bool granted = CGRequestScreenCaptureAccess();
      screen_capture_allowed = granted;
      if (granted) {
        return;
      }
    }
#pragma clang diagnostic pop

    open_screen_capture_settings();
  }

  void prepare_app_bundle_environment() {
    NSString *resource_path = [[NSBundle mainBundle] resourcePath];
    if (resource_path != nil && [resource_path length] > 0) {
      const char *resource_path_cstr = [resource_path fileSystemRepresentation];
      if (resource_path_cstr != nullptr) {
        chdir(resource_path_cstr);
      }
    }
  }

  std::unique_ptr<deinit_t> init() {
    if (!refresh_screen_capture_permission_state()) {
      if (!screen_capture_warning_logged.exchange(true)) {
        BOOST_LOG(warning) << "Screen capture permission is not granted yet."sv;
        BOOST_LOG(warning) << "Please enable Apollo in System Settings -> Privacy & Security -> Screen Recording."sv;
      }
    }

    prepare_app_bundle_environment();
    return std::make_unique<deinit_t>();
  }

  fs::path appdata() {
    const char *homedir;
    if ((homedir = getenv("HOME")) == nullptr) {
      homedir = getpwuid(geteuid())->pw_dir;
    }

    return fs::path {homedir} / "Library/Application Support/Apollo"sv;
  }

  using ifaddr_t = util::safe_ptr<ifaddrs, freeifaddrs>;

  ifaddr_t get_ifaddrs() {
    ifaddrs *p {nullptr};

    getifaddrs(&p);

    return ifaddr_t {p};
  }

  std::string from_sockaddr(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
    }

    return std::string {data};
  }

  std::pair<std::uint16_t, std::string> from_sockaddr_ex(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    std::uint16_t port = 0;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
      port = ((sockaddr_in6 *) ip_addr)->sin6_port;
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
      port = ((sockaddr_in *) ip_addr)->sin_port;
    }

    return {port, std::string {data}};
  }

  std::string get_mac_address(const std::string_view &address) {
    auto ifaddrs = get_ifaddrs();

    for (auto pos = ifaddrs.get(); pos != nullptr; pos = pos->ifa_next) {
      if (pos->ifa_addr && address == from_sockaddr(pos->ifa_addr)) {
        BOOST_LOG(verbose) << "Looking for MAC of "sv << pos->ifa_name;

        struct ifaddrs *ifap, *ifaptr;
        unsigned char *ptr;
        std::string mac_address;

        if (getifaddrs(&ifap) == 0) {
          for (ifaptr = ifap; ifaptr != nullptr; ifaptr = (ifaptr)->ifa_next) {
            if (!strcmp((ifaptr)->ifa_name, pos->ifa_name) && (((ifaptr)->ifa_addr)->sa_family == AF_LINK)) {
              ptr = (unsigned char *) LLADDR((struct sockaddr_dl *) (ifaptr)->ifa_addr);
              char buff[100];

              snprintf(buff, sizeof(buff), "%02x:%02x:%02x:%02x:%02x:%02x", *ptr, *(ptr + 1), *(ptr + 2), *(ptr + 3), *(ptr + 4), *(ptr + 5));
              mac_address = buff;
              break;
            }
          }

          freeifaddrs(ifap);

          if (ifaptr != nullptr) {
            BOOST_LOG(verbose) << "Found MAC of "sv << pos->ifa_name << ": "sv << mac_address;
            return mac_address;
          }
        }
      }
    }

    BOOST_LOG(warning) << "Unable to find MAC address for "sv << address;
    return "00:00:00:00:00:00"s;
  }

  // TODO: return actual IP
  std::string get_local_ip_for_gateway() {
    return "";
  }

  bp::child run_command(bool elevated, bool interactive, const std::string &cmd, boost::filesystem::path &working_dir, const bp::environment &env, FILE *file, std::error_code &ec, bp::group *group) {
    // clang-format off
    if (!group) {
      if (!file) {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > bp::null, bp::std_err > bp::null, bp::limit_handles, ec);
      }
      else {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > file, bp::std_err > file, bp::limit_handles, ec);
      }
    }
    else {
      if (!file) {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > bp::null, bp::std_err > bp::null, bp::limit_handles, ec, *group);
      }
      else {
        return bp::child(cmd, env, bp::start_dir(working_dir), bp::std_in < bp::null, bp::std_out > file, bp::std_err > file, bp::limit_handles, ec, *group);
      }
    }
    // clang-format on
  }

  /**
   * @brief Open a url in the default web browser.
   * @param url The url to open.
   */
  void open_url(const std::string &url) {
    boost::filesystem::path working_dir;
    std::string cmd = R"(open ")" + url + R"(")";

    boost::process::v1::environment _env = boost::this_process::environment();
    std::error_code ec;
    auto child = run_command(false, false, cmd, working_dir, _env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Couldn't open url ["sv << url << "]: System: "sv << ec.message();
    } else {
      BOOST_LOG(info) << "Opened url ["sv << url << "]"sv;
      child.detach();
    }
  }

  void adjust_thread_priority(thread_priority_e priority) {
    // Unimplemented
  }

  void streaming_will_start() {
    // Nothing to do
  }

  void streaming_will_stop() {
    // Nothing to do
  }

  bool spawn_restart_process() {
    char executable[2048];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) < 0) {
      BOOST_LOG(fatal) << "NSGetExecutablePath() failed: "sv << errno;
      return false;
    }

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
      BOOST_LOG(fatal) << "posix_spawnattr_init() failed: "sv << errno;
      return false;
    }

    pid_t child_pid = 0;
    const int spawn_status = posix_spawn(&child_pid, executable, nullptr, &attr, lifetime::get_argv(), ::environ);
    posix_spawnattr_destroy(&attr);
    if (spawn_status != 0) {
      BOOST_LOG(fatal) << "posix_spawn() failed: "sv << spawn_status;
      return false;
    }

    BOOST_LOG(info) << "Spawned replacement Apollo process pid="sv << child_pid;
    return true;
  }

  void restart() {
    if (!spawn_restart_process()) {
      BOOST_LOG(error) << "Failed to spawn replacement Apollo process during restart."sv;
      return;
    }
    lifetime::exit_runtime(0, true);
  }

  int set_env(const std::string &name, const std::string &value) {
    return setenv(name.c_str(), value.c_str(), 1);
  }

  int unset_env(const std::string &name) {
    return unsetenv(name.c_str());
  }

  bool request_process_group_exit(std::uintptr_t native_handle) {
    if (killpg((pid_t) native_handle, SIGTERM) == 0 || errno == ESRCH) {
      BOOST_LOG(debug) << "Successfully sent SIGTERM to process group: "sv << native_handle;
      return true;
    } else {
      BOOST_LOG(warning) << "Unable to send SIGTERM to process group ["sv << native_handle << "]: "sv << errno;
      return false;
    }
  }

  bool process_group_running(std::uintptr_t native_handle) {
    return waitpid(-((pid_t) native_handle), nullptr, WNOHANG) >= 0;
  }

  struct sockaddr_in to_sockaddr(boost::asio::ip::address_v4 address, uint16_t port) {
    struct sockaddr_in saddr_v4 = {};

    saddr_v4.sin_family = AF_INET;
    saddr_v4.sin_port = htons(port);

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v4.sin_addr, addr_bytes.data(), sizeof(saddr_v4.sin_addr));

    return saddr_v4;
  }

  struct sockaddr_in6 to_sockaddr(boost::asio::ip::address_v6 address, uint16_t port) {
    struct sockaddr_in6 saddr_v6 = {};

    saddr_v6.sin6_family = AF_INET6;
    saddr_v6.sin6_port = htons(port);
    saddr_v6.sin6_scope_id = address.scope_id();

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v6.sin6_addr, addr_bytes.data(), sizeof(saddr_v6.sin6_addr));

    return saddr_v6;
  }

  bool send_batch(batched_send_info_t &send_info) {
    // Fall back to unbatched send calls
    return false;
  }

  bool send(send_info_t &send_info) {
    auto sockfd = (int) send_info.native_socket;
    struct msghdr msg = {};

    // Convert the target address into a sockaddr
    struct sockaddr_in taddr_v4 = {};
    struct sockaddr_in6 taddr_v6 = {};
    if (send_info.target_address.is_v6()) {
      taddr_v6 = to_sockaddr(send_info.target_address.to_v6(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v6;
      msg.msg_namelen = sizeof(taddr_v6);
    } else {
      taddr_v4 = to_sockaddr(send_info.target_address.to_v4(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v4;
      msg.msg_namelen = sizeof(taddr_v4);
    }

    union {
      char buf[std::max(CMSG_SPACE(sizeof(struct in_pktinfo)), CMSG_SPACE(sizeof(struct in6_pktinfo)))];
      struct cmsghdr alignment;
    } cmbuf {};

    socklen_t cmbuflen = 0;

    msg.msg_control = cmbuf.buf;
    msg.msg_controllen = sizeof(cmbuf.buf);

    auto pktinfo_cm = CMSG_FIRSTHDR(&msg);
    if (send_info.source_address.is_v6()) {
      struct in6_pktinfo pktInfo {};

      struct sockaddr_in6 saddr_v6 = to_sockaddr(send_info.source_address.to_v6(), 0);
      pktInfo.ipi6_addr = saddr_v6.sin6_addr;
      pktInfo.ipi6_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IPV6;
      pktinfo_cm->cmsg_type = IPV6_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    } else {
      struct in_pktinfo pktInfo {};

      struct sockaddr_in saddr_v4 = to_sockaddr(send_info.source_address.to_v4(), 0);
      pktInfo.ipi_spec_dst = saddr_v4.sin_addr;
      pktInfo.ipi_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IP;
      pktinfo_cm->cmsg_type = IP_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    }

    struct iovec iovs[2] = {};
    int iovlen = 0;
    if (send_info.header) {
      iovs[iovlen].iov_base = (void *) send_info.header;
      iovs[iovlen].iov_len = send_info.header_size;
      iovlen++;
    }
    iovs[iovlen].iov_base = (void *) send_info.payload;
    iovs[iovlen].iov_len = send_info.payload_size;
    iovlen++;

    msg.msg_iov = iovs;
    msg.msg_iovlen = iovlen;

    msg.msg_controllen = cmbuflen;

    auto bytes_sent = sendmsg(sockfd, &msg, 0);

    // If there's no send buffer space, wait for some to be available
    while (bytes_sent < 0 && errno == EAGAIN) {
      struct pollfd pfd;

      pfd.fd = sockfd;
      pfd.events = POLLOUT;

      if (poll(&pfd, 1, -1) != 1) {
        BOOST_LOG(warning) << "poll() failed: "sv << errno;
        break;
      }

      // Try to send again
      bytes_sent = sendmsg(sockfd, &msg, 0);
    }

    if (bytes_sent < 0) {
      BOOST_LOG(warning) << "sendmsg() failed: "sv << errno;
      return false;
    }

    return true;
  }

  // We can't track QoS state separately for each destination on this OS,
  // so we keep a ref count to only disable QoS options when all clients
  // are disconnected.
  static std::atomic<int> qos_ref_count = 0;

  class qos_t: public deinit_t {
  public:
    qos_t(int sockfd, std::vector<std::tuple<int, int, int>> options):
        sockfd(sockfd),
        options(options) {
      qos_ref_count++;
    }

    virtual ~qos_t() {
      if (--qos_ref_count == 0) {
        for (const auto &tuple : options) {
          auto reset_val = std::get<2>(tuple);
          if (setsockopt(sockfd, std::get<0>(tuple), std::get<1>(tuple), &reset_val, sizeof(reset_val)) < 0) {
            BOOST_LOG(warning) << "Failed to reset option: "sv << errno;
          }
        }
      }
    }

  private:
    int sockfd;
    std::vector<std::tuple<int, int, int>> options;
  };

  /**
   * @brief Enables QoS on the given socket for traffic to the specified destination.
   * @param native_socket The native socket handle.
   * @param address The destination address for traffic sent on this socket.
   * @param port The destination port for traffic sent on this socket.
   * @param data_type The type of traffic sent on this socket.
   * @param dscp_tagging Specifies whether to enable DSCP tagging on outgoing traffic.
   */
  std::unique_ptr<deinit_t> enable_socket_qos(uintptr_t native_socket, boost::asio::ip::address &address, uint16_t port, qos_data_type_e data_type, bool dscp_tagging) {
    int sockfd = (int) native_socket;
    std::vector<std::tuple<int, int, int>> reset_options;

    // We can use SO_NET_SERVICE_TYPE to set link-layer prioritization without DSCP tagging
    int service_type = 0;
    switch (data_type) {
      case qos_data_type_e::video:
        service_type = NET_SERVICE_TYPE_VI;
        break;
      case qos_data_type_e::audio:
        service_type = NET_SERVICE_TYPE_VO;
        break;
      default:
        BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
        break;
    }

    if (service_type) {
      if (setsockopt(sockfd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service_type, sizeof(service_type)) == 0) {
        // Reset SO_NET_SERVICE_TYPE to best-effort when QoS is disabled
        reset_options.emplace_back(std::make_tuple(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_BE));
      } else {
        BOOST_LOG(error) << "Failed to set SO_NET_SERVICE_TYPE: "sv << errno;
      }
    }

    if (dscp_tagging) {
      int level;
      int option;
      if (address.is_v6()) {
        level = IPPROTO_IPV6;
        option = IPV6_TCLASS;
      } else {
        level = IPPROTO_IP;
        option = IP_TOS;
      }

      // The specific DSCP values here are chosen to be consistent with Windows,
      // except that we use CS6 instead of CS7 for audio traffic.
      int dscp = 0;
      switch (data_type) {
        case qos_data_type_e::video:
          dscp = 40;
          break;
        case qos_data_type_e::audio:
          dscp = 48;
          break;
        default:
          BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
          break;
      }

      if (dscp) {
        // Shift to put the DSCP value in the correct position in the TOS field
        dscp <<= 2;

        if (setsockopt(sockfd, level, option, &dscp, sizeof(dscp)) == 0) {
          // Reset TOS to -1 when QoS is disabled
          reset_options.emplace_back(std::make_tuple(level, option, -1));
        } else {
          BOOST_LOG(error) << "Failed to set TOS/TCLASS: "sv << errno;
        }
      }
    }

    return std::make_unique<qos_t>(sockfd, reset_options);
  }

  std::string get_host_name() {
    try {
      return boost::asio::ip::host_name();
    } catch (boost::system::system_error &err) {
      BOOST_LOG(error) << "Failed to get hostname: "sv << err.what();
      return "Sunshine"s;
    }
  }

  class macos_high_precision_timer: public high_precision_timer {
  public:
    void sleep_for(const std::chrono::nanoseconds &duration) override {
      std::this_thread::sleep_for(duration);
    }

    operator bool() override {
      return true;
    }
  };

  std::unique_ptr<high_precision_timer> create_high_precision_timer() {
    return std::make_unique<macos_high_precision_timer>();
  }

  std::string
  get_clipboard() {
    // Placeholder
    return "";
  }

  bool
  set_clipboard(const std::string& content) {
    // Placeholder
    return false;
  }

  void arm_display_wake_watchdog() {
    boost::filesystem::path working_dir;
    boost::process::v1::environment env = boost::this_process::environment();
    std::error_code ec;
    const auto pid = static_cast<long>(getpid());
    std::string cmd = "/bin/sh -c 'while kill -0 " + std::to_string(pid) + " 2>/dev/null; do sleep 1; done; /usr/bin/caffeinate -u -t 1 >/dev/null 2>&1'";
    auto child = run_command(false, false, cmd, working_dir, env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Failed to arm macOS display wake watchdog: "sv << ec.message();
      return;
    }

    child.detach();
    BOOST_LOG(info) << "Armed macOS display wake watchdog for pid="sv << pid;
  }

  bool isolate_virtual_display(CGDirectDisplayID virtual_display_id) {
    std::call_once(private_display_control_log_once, []() {
      log_private_display_control_availability();
    });
    std::lock_guard lock(virtual_display_layout_mutex);
    if (virtual_display_layout_active) {
      return true;
    }

    std::vector<CGDirectDisplayID> display_ids;
    auto display_count = refresh_active_display_ids(display_ids);
    if (display_count == 0) {
      BOOST_LOG(warning) << "Failed to enumerate active macOS displays for virtual layout isolation"sv;
      return false;
    }

    bool found_virtual_display = false;
    virtual_display_layout_snapshot.clear();
    virtual_display_layout_snapshot.reserve(display_count);
    for (uint32_t index = 0; index < display_count; ++index) {
      const auto display_id = display_ids[index];
      const auto bounds = CGDisplayBounds(display_id);
      virtual_display_layout_snapshot.push_back({
        display_id,
        bounds.origin,
        CGDisplayMirrorsDisplay(display_id)
      });
      found_virtual_display = found_virtual_display || display_id == virtual_display_id;
    }

    if (!found_virtual_display) {
      BOOST_LOG(warning) << "Virtual display "sv << virtual_display_id << " was not active during layout isolation"sv;
      virtual_display_layout_snapshot.clear();
      return false;
    }

    if (config::video.isolated_virtual_display_option) {
      apply_private_virtual_display_set(1);
      display_count = refresh_active_display_ids(display_ids);
      if (display_count == 0) {
        BOOST_LOG(warning) << "Active macOS displays disappeared after private display set selection"sv;
        apply_private_virtual_display_set(0);
        virtual_display_layout_snapshot.clear();
        return false;
      }
    }

    CGDisplayConfigRef config = nullptr;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || config == nullptr) {
      BOOST_LOG(warning) << "Failed to begin macOS display configuration for virtual layout isolation"sv;
      if (private_display_set_active) {
        apply_private_virtual_display_set(0);
      }
      virtual_display_layout_snapshot.clear();
      return false;
    }

    bool configuration_ok = true;
    configuration_ok = configuration_ok && (CGConfigureDisplayMirrorOfDisplay(config, virtual_display_id, kCGNullDirectDisplay) == kCGErrorSuccess);
    configuration_ok = configuration_ok && (CGConfigureDisplayOrigin(config, virtual_display_id, 0, 0) == kCGErrorSuccess);

    int32_t parked_display_index = 0;
    for (const auto &entry : virtual_display_layout_snapshot) {
      if (entry.display_id == virtual_display_id) {
        continue;
      }

      configuration_ok = configuration_ok &&
                         (CGConfigureDisplayMirrorOfDisplay(config, entry.display_id, kCGNullDirectDisplay) == kCGErrorSuccess);
      configuration_ok = configuration_ok &&
                         (CGConfigureDisplayOrigin(
                           config,
                           entry.display_id,
                           kVirtualIsolationParkOriginX,
                           kVirtualIsolationParkOriginY + (parked_display_index++ * kVirtualIsolationParkSpacingY)
                         ) == kCGErrorSuccess);
    }

    if (!configuration_ok || CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
      CGCancelDisplayConfiguration(config);
      BOOST_LOG(warning) << "Failed to isolate macOS virtual display layout"sv;
      if (private_display_set_active) {
        apply_private_virtual_display_set(0);
      }
      virtual_display_layout_snapshot.clear();
      return false;
    }

    virtual_display_layout_active = true;
    BOOST_LOG(info) << "Isolated macOS virtual display layout around display "sv << virtual_display_id;
    return true;
  }

  void log_private_display_control_availability() {
    const auto api = load_private_display_control_api();
    if (!api.handle) {
      BOOST_LOG(warning) << "CoreDisplay private framework was not available for macOS display isolation probing"sv;
      return;
    }

    BOOST_LOG(info) << "macOS private display control candidates: "
                    << "CGXCurrentDisplaySet="sv << (api.cgx_current_display_set ? "yes"sv : "no"sv)
                    << " CGXSelectDisplaySet="sv << (api.cgx_select_display_set ? "yes"sv : "no"sv)
                    << " CGXSetDisplaySet="sv << (api.cgx_set_display_set ? "yes"sv : "no"sv)
                    << " CoreDisplay_Display_IsMain="sv << (api.coredisplay_display_is_main ? "yes"sv : "no"sv)
                    << " WSCanonicalMirrorMasterForDisplayDevice="sv << (api.ws_canonical_mirror_master_for_display_device ? "yes"sv : "no"sv)
                    << " WSDisplayIsCanonicalMirrorMaster="sv << (api.ws_display_is_canonical_mirror_master ? "yes"sv : "no"sv)
                    << " CGXVFBSelectOnlineState="sv << (api.cgx_vfb_select_online_state ? "yes"sv : "no"sv);
  }

  void restore_virtual_display_isolation() {
    std::lock_guard lock(virtual_display_layout_mutex);
    if ((!virtual_display_layout_active || virtual_display_layout_snapshot.empty()) && !private_display_set_active) {
      return;
    }

    if (private_display_set_active) {
      const auto requested_restore_set = private_display_set_previous;
      apply_private_virtual_display_set(requested_restore_set);
      BOOST_LOG(info) << "Restored macOS private display set to "sv << requested_restore_set;
    }

    if (!virtual_display_layout_active || virtual_display_layout_snapshot.empty()) {
      return;
    }

    CGDisplayConfigRef config = nullptr;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || config == nullptr) {
      BOOST_LOG(warning) << "Failed to begin macOS display configuration for layout restore"sv;
      return;
    }

    bool configuration_ok = true;
    for (const auto &entry : virtual_display_layout_snapshot) {
      configuration_ok = configuration_ok &&
                         (CGConfigureDisplayMirrorOfDisplay(config, entry.display_id, entry.mirror_master) == kCGErrorSuccess);
      configuration_ok = configuration_ok &&
                         (CGConfigureDisplayOrigin(
                           config,
                           entry.display_id,
                           static_cast<int32_t>(entry.origin.x),
                           static_cast<int32_t>(entry.origin.y)
                         ) == kCGErrorSuccess);
    }

    if (!configuration_ok || CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
      CGCancelDisplayConfiguration(config);
      BOOST_LOG(warning) << "Failed to restore macOS display layout after virtual session"sv;
      return;
    }

    virtual_display_layout_snapshot.clear();
    virtual_display_layout_active = false;
    BOOST_LOG(info) << "Restored macOS display layout after virtual session"sv;
  }

  void focus_virtual_display_workspace(CGDirectDisplayID virtual_display_id) {
    const auto bounds = CGDisplayBounds(virtual_display_id);
    if (CGRectIsEmpty(bounds)) {
      BOOST_LOG(warning) << "Unable to focus macOS virtual display "sv << virtual_display_id << " because its bounds were empty"sv;
      return;
    }

    const CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGDisplayMoveCursorToPoint(virtual_display_id, center);
    CGWarpMouseCursorPosition(center);

    const auto trusted = AXIsProcessTrusted();
    if (!trusted) {
      request_accessibility_permission();
      BOOST_LOG(warning) << "Skipping macOS window migration to virtual display because Accessibility permission is not granted"sv;
      return;
    }

    const CFArrayRef window_info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (window_info == nullptr) {
      BOOST_LOG(warning) << "Unable to enumerate macOS windows for virtual display focus"sv;
      return;
    }

    const auto target_origin = CGPointMake(bounds.origin.x + 80.0, bounds.origin.y + 80.0);
    const auto entry_count = CFArrayGetCount(window_info);
    CFIndex moved_windows = 0;
    pid_t activated_pid = 0;
    pid_t fallback_pid = 0;
    AXUIElementRef activated_window = nullptr;
    for (CFIndex index = 0; index < entry_count; ++index) {
      const auto entry = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(window_info, index));
      if (entry == nullptr) {
        continue;
      }

      const auto owner_name = static_cast<CFStringRef>(CFDictionaryGetValue(entry, kCGWindowOwnerName));
      if (owner_name != nullptr) {
        if (CFStringCompare(owner_name, CFSTR("Window Server"), 0) == kCFCompareEqualTo ||
            CFStringCompare(owner_name, CFSTR("Dock"), 0) == kCFCompareEqualTo) {
          continue;
        }
      }

      const auto pid_number = static_cast<CFNumberRef>(CFDictionaryGetValue(entry, kCGWindowOwnerPID));
      if (pid_number == nullptr) {
        continue;
      }

      pid_t pid = 0;
      if (!CFNumberGetValue(pid_number, kCFNumberIntType, &pid) || pid <= 0 || pid == getpid()) {
        continue;
      }

      const auto app = AXUIElementCreateApplication(pid);
      if (app == nullptr) {
        continue;
      }

      CFArrayRef windows = nullptr;
      if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, reinterpret_cast<CFTypeRef *>(&windows)) != kAXErrorSuccess || windows == nullptr) {
        CFRelease(app);
        continue;
      }

      const auto window_count = CFArrayGetCount(windows);
      for (CFIndex window_index = 0; window_index < window_count; ++window_index) {
        const auto window = static_cast<AXUIElementRef>(CFArrayGetValueAtIndex(windows, window_index));
        if (window == nullptr) {
          continue;
        }

        auto position = AXValueCreate(static_cast<AXValueType>(kAXValueCGPointType), &target_origin);
        if (position != nullptr) {
          if (AXUIElementSetAttributeValue(window, kAXPositionAttribute, position) == kAXErrorSuccess) {
            ++moved_windows;
            if (fallback_pid == 0) {
              fallback_pid = pid;
            }
            if (activated_pid == 0) {
              if (auto *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid]; application != nil) {
                if (application.activationPolicy == NSApplicationActivationPolicyRegular) {
                  activated_pid = pid;
                  activated_window = static_cast<AXUIElementRef>(CFRetain(window));
                }
              }
            }
          }
          CFRelease(position);
        }
      }

      CFRelease(windows);
      CFRelease(app);
    }

    CFRelease(window_info);
    if (activated_pid == 0) {
      activated_pid = fallback_pid;
    }
    if (activated_pid == 0) {
      NSArray<NSRunningApplication *> *finderApplications =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"];
      if (finderApplications.count > 0) {
        activated_pid = finderApplications.firstObject.processIdentifier;
      }
    }
    if (activated_pid > 0) {
      if (auto *application = [NSRunningApplication runningApplicationWithProcessIdentifier:activated_pid]; application != nil) {
        const auto activated = [application activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
        if (activated_window != nullptr) {
          const auto activated_app_ax = AXUIElementCreateApplication(activated_pid);
          if (activated_app_ax != nullptr) {
            AXUIElementSetAttributeValue(activated_app_ax, kAXFrontmostAttribute, kCFBooleanTrue);
            AXUIElementSetAttributeValue(activated_app_ax, kAXFocusedWindowAttribute, activated_window);
            CFRelease(activated_app_ax);
          }
          AXUIElementSetAttributeValue(activated_window, kAXMainAttribute, kCFBooleanTrue);
          AXUIElementSetAttributeValue(activated_window, kAXFocusedAttribute, kCFBooleanTrue);
          AXUIElementPerformAction(activated_window, kAXRaiseAction);
          CFRelease(activated_window);
          activated_window = nullptr;
        }
        ensure_private_virtual_display_set_active("workspace-focus");
        BOOST_LOG(info) << "Activated macOS virtual display application pid="sv << activated_pid
                        << " name="sv
                        << (application.localizedName ? [application.localizedName UTF8String] : "unknown")
                        << " policy="sv << static_cast<int>(application.activationPolicy)
                        << " result="sv << activated;
      }
    }
    if (activated_window != nullptr) {
      CFRelease(activated_window);
    }
    BOOST_LOG(info) << "Focused macOS virtual display workspace around display "sv << virtual_display_id << " moved_windows="sv << moved_windows;
  }

  bool ensure_private_virtual_display_set_active(const char *reason) {
    if (!private_display_set_active) {
      return false;
    }

    const auto current_set = current_private_display_set();
    if (current_set == 1) {
      return true;
    }

    const auto restored = apply_private_virtual_display_set(1);
    BOOST_LOG(info) << "Ensured macOS private display set active reason="sv
                    << (reason ? reason : "unknown")
                    << " previous="sv << current_set
                    << " restored="sv << restored;
    return restored;
  }

  bool sleep_physical_displays() {
    boost::filesystem::path working_dir;
    boost::process::v1::environment env = boost::this_process::environment();
    std::error_code ec;
    auto child = run_command(false, false, "/usr/bin/pmset displaysleepnow", working_dir, env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Failed to sleep physical displays: "sv << ec.message();
      return false;
    }

    child.wait();
    if (child.exit_code() != 0) {
      BOOST_LOG(warning) << "pmset displaysleepnow exited with code "sv << child.exit_code();
      return false;
    }

    arm_display_wake_watchdog();
    BOOST_LOG(info) << "Requested macOS physical displays to sleep"sv;
    return true;
  }

  bool wake_physical_displays() {
    boost::filesystem::path working_dir;
    boost::process::v1::environment env = boost::this_process::environment();
    std::error_code ec;
    auto child = run_command(false, false, "/usr/bin/caffeinate -u -t 1", working_dir, env, nullptr, ec, nullptr);
    if (ec) {
      BOOST_LOG(warning) << "Failed to wake physical displays: "sv << ec.message();
      return false;
    }

    child.wait();
    if (child.exit_code() != 0) {
      BOOST_LOG(warning) << "caffeinate wake request exited with code "sv << child.exit_code();
      return false;
    }

    BOOST_LOG(info) << "Requested macOS physical displays to wake"sv;
    return true;
  }

  void mirror_capture_request_state(const capture_request_mirror_state_t &state) {
    @autoreleasepool {
      NSError *error = nil;
      auto *data = [NSPropertyListSerialization dataWithPropertyList:capture_request_dictionary(state)
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&error];
      if (data == nil) {
        BOOST_LOG(warning) << "Unable to serialize mirrored Apollo capture request: "sv
                           << (error ? [[error localizedDescription] UTF8String] : "unknown error");
        return;
      }

      if (![data writeToURL:capture_request_mirror_url() options:NSDataWritingAtomic error:&error]) {
        BOOST_LOG(warning) << "Unable to mirror Apollo capture request: "sv
                           << (error ? [[error localizedDescription] UTF8String] : "unknown error");
        return;
      }

      post_capture_request_mirror_notification();
    }
  }

  void clear_capture_request_state_mirror() {
    @autoreleasepool {
      NSError *error = nil;
      auto *url = capture_request_mirror_url();
      if ([[NSFileManager defaultManager] fileExistsAtPath:[url path]] &&
          ![[NSFileManager defaultManager] removeItemAtURL:url error:&error]) {
        BOOST_LOG(warning) << "Unable to clear mirrored Apollo capture request: "sv
                           << (error ? [[error localizedDescription] UTF8String] : "unknown error");
        return;
      }

      post_capture_request_mirror_notification();
    }
  }

  void post_runtime_event_notification(
    const std::string &identifier,
    const std::string &title,
    const std::string &body,
    const std::string &launch_path
  ) {
    NSString *identifier_string = [NSString stringWithUTF8String:identifier.c_str()] ?: @"";
    NSString *title_string = [NSString stringWithUTF8String:title.c_str()] ?: @"";
    NSString *body_string = [NSString stringWithUTF8String:body.c_str()] ?: @"";
    NSString *launch_path_string = [NSString stringWithUTF8String:launch_path.c_str()] ?: @"";

    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter]
        postNotificationName:kApolloRuntimeEventNotificationName
                      object:nil
                    userInfo:@ {
                      kApolloRuntimeEventIdentifierKey: identifier_string,
                      kApolloRuntimeEventTitleKey: title_string,
                      kApolloRuntimeEventBodyKey: body_string,
                      kApolloRuntimeEventLaunchPathKey: launch_path_string
                    }];
    });
  }

  void post_runtime_web_ui_ready_notification(const std::string &url) {
    NSString *url_string = [NSString stringWithUTF8String:url.c_str()] ?: @"";

    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter]
        postNotificationName:kApolloRuntimeWebUIReadyNotificationName
                      object:nil
                    userInfo:@ {kApolloRuntimeWebUIReadyURLKey: url_string}];
    });
  }

  namespace {
    constexpr double external_capture_hdr_edr_threshold = 1.001;

    NSScreen *screen_for_external_capture_display_id(CGDirectDisplayID display_id) {
      for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screen_number = screen.deviceDescription[@"NSScreenNumber"];
        if (screen_number != nil && screen_number.unsignedIntValue == display_id) {
          return screen;
        }
      }

      return nil;
    }

    bool screen_is_external_capture_hdr_capable(NSScreen *screen) {
      if (screen == nil) {
        return false;
      }

      if (@available(macOS 10.15, *)) {
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > external_capture_hdr_edr_threshold
          || screen.maximumExtendedDynamicRangeColorComponentValue > external_capture_hdr_edr_threshold;
      }

      return false;
    }

    bool screen_is_external_capture_hdr_active(NSScreen *screen) {
      if (screen == nil) {
        return false;
      }

      if (@available(macOS 10.11, *)) {
        return screen.maximumExtendedDynamicRangeColorComponentValue > external_capture_hdr_edr_threshold;
      }

      return false;
    }

    bool fallback_external_capture_hdr_metadata(NSScreen *screen, SS_HDR_METADATA &metadata) {
      std::memset(&metadata, 0, sizeof(metadata));
      if (!screen_is_external_capture_hdr_capable(screen)) {
        return false;
      }

      metadata.displayPrimaries[0] = {34000, 16000};
      metadata.displayPrimaries[1] = {13250, 34500};
      metadata.displayPrimaries[2] = {7500, 3000};
      metadata.whitePoint = {15635, 16450};

      double peak_edr = 1.0;
      if (@available(macOS 10.15, *)) {
        peak_edr = std::max(
          screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
          screen.maximumExtendedDynamicRangeColorComponentValue
        );
      }

      const auto estimated_peak_nits = static_cast<uint16_t>(std::clamp(std::lround(peak_edr * 1000.0), 400l, 2000l));
      metadata.maxDisplayLuminance = estimated_peak_nits;
      metadata.maxFullFrameLuminance = estimated_peak_nits;
      metadata.minDisplayLuminance = 1;
      metadata.maxContentLightLevel = estimated_peak_nits;
      metadata.maxFrameAverageLightLevel = estimated_peak_nits;
      return true;
    }

    CGDirectDisplayID parse_external_capture_display_id(const std::string &display_name) {
      if (!display_name.empty()) {
        char *end_ptr = nullptr;
        const auto parsed_display_id = std::strtoul(display_name.c_str(), &end_ptr, 10);
        if (end_ptr != nullptr && *end_ptr == '\0') {
          return static_cast<CGDirectDisplayID>(parsed_display_id);
        }
      }

      return CGMainDisplayID();
    }
  }  // namespace

  effective_display_state_t resolve_capture_request_effective_display_state(
    std::uint32_t display_id,
    video::dynamic_range_transport_e requested_dynamic_range_transport,
    int client_sink_gamut,
    int client_sink_transfer
  ) {
    return resolve_capture_request_effective_display_state_impl(
      screen_for_external_capture_display_id(static_cast<CGDirectDisplayID>(display_id)),
      requested_dynamic_range_transport,
      client_sink_gamut,
      client_sink_transfer
    );
  }

  bool resolve_effective_display_hdr_metadata(
    int effective_sink_gamut,
    int effective_sink_transfer,
    float client_sink_current_edr_headroom,
    float client_sink_potential_edr_headroom,
    int client_sink_current_peak_luminance_nits,
    int client_sink_potential_peak_luminance_nits,
    SS_HDR_METADATA &metadata
  ) {
    return resolve_effective_display_hdr_metadata_impl(
      effective_sink_gamut,
      effective_sink_transfer,
      client_sink_current_edr_headroom,
      client_sink_potential_edr_headroom,
      client_sink_current_peak_luminance_nits,
      client_sink_potential_peak_luminance_nits,
      nullptr,
      metadata
    );
  }

  bool query_external_capture_display_metadata(
    const std::string &display_name,
    int target_width,
    int target_height,
    external_capture_display_metadata_t &metadata
  ) {
    const auto display_id = parse_external_capture_display_id(display_name);
    const auto bounds = CGDisplayBounds(display_id);
    const auto capture_width = std::max(1.0, static_cast<double>(CGRectGetWidth(bounds)));
    const auto capture_height = std::max(1.0, static_cast<double>(CGRectGetHeight(bounds)));
    const auto pixel_width = std::max(1.0, static_cast<double>(CGDisplayPixelsWide(display_id)));
    const auto pixel_height = std::max(1.0, static_cast<double>(CGDisplayPixelsHigh(display_id)));
    const auto output_width = std::max(1.0, static_cast<double>(target_width));
    const auto output_height = std::max(1.0, static_cast<double>(target_height));
    const auto scalar = std::fmin(output_width / capture_width, output_height / capture_height);

    metadata.viewport = {
      static_cast<int>(std::lround(bounds.origin.x)),
      static_cast<int>(std::lround(bounds.origin.y)),
      target_width,
      target_height,
    };
    metadata.env_width = static_cast<int>(std::lround(capture_width));
    metadata.env_height = static_cast<int>(std::lround(capture_height));
    metadata.client_offset_x = static_cast<float>((output_width - (scalar * capture_width)) * 0.5);
    metadata.client_offset_y = static_cast<float>((output_height - (scalar * capture_height)) * 0.5);
    metadata.scalar_inv = static_cast<float>(1.0 / scalar);

    BOOST_LOG(info) << "macOS external capture display metadata: displayID="sv
                    << display_id
                    << " stream="sv << target_width << "x"sv << target_height
                    << " logical="sv << capture_width << "x"sv << capture_height
                    << " pixels="sv << pixel_width << "x"sv << pixel_height
                    << " offset="sv << metadata.client_offset_x << "x"sv << metadata.client_offset_y
                    << " scalar-inv="sv << metadata.scalar_inv;

    const auto *screen = screen_for_external_capture_display_id(display_id);
    metadata.hdr_active = false;
    std::memset(&metadata.hdr_metadata, 0, sizeof(metadata.hdr_metadata));
    if (screen_is_external_capture_hdr_active(const_cast<NSScreen *>(screen))) {
      if (auto preferences = read_capture_request_hdr_preferences();
          preferences && bridge_aligned_external_capture_hdr_metadata(*preferences, const_cast<NSScreen *>(screen), metadata.hdr_metadata)) {
        metadata.hdr_active = true;
        BOOST_LOG(info) << "macOS external capture HDR metadata aligned to mirrored capture request"
                        << " gamut="sv << preferences->client_sink_gamut
                        << " transfer="sv << preferences->client_sink_transfer
                        << " current-edr-headroom="sv << preferences->client_sink_current_edr_headroom
                        << " potential-edr-headroom="sv << preferences->client_sink_potential_edr_headroom
                        << " current-peak-nits="sv << preferences->client_sink_current_peak_luminance_nits
                        << " potential-peak-nits="sv << preferences->client_sink_potential_peak_luminance_nits
                        << " max-display-nits="sv << metadata.hdr_metadata.maxDisplayLuminance;
      } else if (fallback_external_capture_hdr_metadata(const_cast<NSScreen *>(screen), metadata.hdr_metadata)) {
        metadata.hdr_active = true;
      }
    }

    return true;
  }
}  // namespace platf

namespace dyn {
  void *handle(const std::vector<const char *> &libs) {
    void *handle;

    for (auto lib : libs) {
      handle = dlopen(lib, RTLD_LAZY | RTLD_LOCAL);
      if (handle) {
        return handle;
      }
    }

    std::stringstream ss;
    ss << "Couldn't find any of the following libraries: ["sv << libs.front();
    std::for_each(std::begin(libs) + 1, std::end(libs), [&](auto lib) {
      ss << ", "sv << lib;
    });

    ss << ']';

    BOOST_LOG(error) << ss.str();

    return nullptr;
  }

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict) {
    int err = 0;
    for (auto &func : funcs) {
      TUPLE_2D_REF(fn, name, func);

      *fn = (void (*)()) dlsym(handle, name);

      if (!*fn && strict) {
        BOOST_LOG(error) << "Couldn't find function: "sv << name;

        err = -1;
      }
    }

    return err;
  }
}  // namespace dyn
