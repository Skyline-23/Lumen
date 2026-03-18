#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

#include <dlfcn.h>

#include "src/logging.h"
#include "src/video.h"
#include "src/platform/macos/virtual_display.h"

#include <algorithm>
#include <mutex>
#include <unordered_map>

using namespace std::literals;

namespace VDISPLAY {
  namespace {
    constexpr VDISPLAY::color_profile_t kSrgbColorProfile {
      {0.6400, 0.3300},
      {0.3000, 0.6000},
      {0.1500, 0.0600},
      {0.3127, 0.3290},
      false,
      false,
    };

    constexpr VDISPLAY::color_profile_t kDisplayP3ColorProfile {
      {0.6800, 0.3200},
      {0.2650, 0.6900},
      {0.1500, 0.0600},
      {0.3127, 0.3290},
      true,
      true,
    };

    constexpr VDISPLAY::color_profile_t kRec2020ColorProfile {
      {0.7080, 0.2920},
      {0.1700, 0.7970},
      {0.1310, 0.0460},
      {0.3127, 0.3290},
      false,
      true,
    };

    struct virtual_display_handle_t {
      id descriptor {nil};
      id mode {nil};
      id settings {nil};
      id display {nil};
      dispatch_queue_t queue {nil};
      std::string display_id;
      std::uint32_t pixel_width {0};
      std::uint32_t pixel_height {0};
      std::uint32_t logical_width {0};
      std::uint32_t logical_height {0};

      ~virtual_display_handle_t() {
        if (display != nil) {
          [display release];
          display = nil;
        }
        if (settings != nil) {
          [settings release];
          settings = nil;
        }
        if (mode != nil) {
          [mode release];
          mode = nil;
        }
        if (descriptor != nil) {
          [descriptor release];
          descriptor = nil;
        }
        if (queue != nil) {
          dispatch_release(queue);
          queue = nil;
        }
      }
    };

    std::mutex display_mutex;
    std::unordered_map<std::string, std::unique_ptr<virtual_display_handle_t>> active_displays;
    DRIVER_STATUS driver_status = DRIVER_STATUS::UNKNOWN;

    double normalize_refresh_rate(std::uint32_t fps_millihz) {
      if (fps_millihz == 0) {
        return 60.0;
      }

      if (fps_millihz >= 1000) {
        return static_cast<double>(fps_millihz) / 1000.0;
      }

      return static_cast<double>(fps_millihz);
    }

    NSSize virtual_display_size_for_pixels(std::uint32_t width, std::uint32_t height) {
      constexpr double kRetinaPixelsPerInch = 218.0;
      constexpr double kMillimetersPerInch = 25.4;

      const auto width_mm = std::clamp((static_cast<double>(std::max(width, 1u)) / kRetinaPixelsPerInch) * kMillimetersPerInch, 120.0, 1200.0);
      const auto height_mm = std::clamp((static_cast<double>(std::max(height, 1u)) / kRetinaPixelsPerInch) * kMillimetersPerInch, 80.0, 900.0);
      return NSMakeSize(width_mm, height_mm);
    }

    std::uint32_t backing_dimension_for_scale_factor(std::uint32_t logical_dimension, int scale_factor, bool hi_dpi) {
      if (!hi_dpi) {
        return std::max<std::uint32_t>(2u, logical_dimension) & ~1u;
      }

      const auto clamped_scale = std::max(scale_factor, 100);
      const auto scaled_dimension = (static_cast<std::uint64_t>(std::max(logical_dimension, 1u)) * static_cast<std::uint64_t>(clamped_scale)) / 100u;
      return std::max<std::uint32_t>(2u, static_cast<std::uint32_t>(scaled_dimension)) & ~1u;
    }

    NSString *core_display_string_constant(const char *symbol_name) {
      if (symbol_name == nullptr || symbol_name[0] == '\0') {
        return nil;
      }

      static void *core_display_handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
      if (core_display_handle == nullptr) {
        return nil;
      }

      auto *symbol = dlsym(core_display_handle, symbol_name);
      if (symbol == nullptr) {
        return nil;
      }

      auto *constant_ptr = reinterpret_cast<const void * const *>(symbol);
      if (constant_ptr == nullptr || *constant_ptr == nullptr) {
        return nil;
      }

      return (__bridge NSString *) *constant_ptr;
    }

    void configure_hdr_display_info(id descriptor, bool hdr_enabled, const color_profile_t &host_profile) {
      if (!hdr_enabled || descriptor == nil) {
        return;
      }

      const auto set_display_info = sel_registerName("setDisplayInfoValue:forKey:");
      if (![descriptor respondsToSelector:set_display_info]) {
        return;
      }

      const auto max_hdr_luminance_key = core_display_string_constant("kCDDisplayPresetMaxHDRLuminanceKey");
      const auto max_sdr_luminance_key = core_display_string_constant("kCDDisplayPresetMaxSDRLuminanceKey");
      const auto min_luminance_key = core_display_string_constant("kCDDisplayPresetMinLuminanceKey");
      const auto expected_luminance_key = core_display_string_constant("kCDDisplayUserAdjustmentExpectedLuminanceKey");

      const auto peak_luminance = host_profile.hdr_capable ? 1000.0 : 600.0;
      const auto sdr_luminance = host_profile.display_p3 ? 300.0 : 200.0;
      const auto minimum_luminance = 0.001;

      if (max_hdr_luminance_key != nil) {
        [descriptor performSelector:set_display_info withObject:@(peak_luminance) withObject:max_hdr_luminance_key];
      }
      if (max_sdr_luminance_key != nil) {
        [descriptor performSelector:set_display_info withObject:@(sdr_luminance) withObject:max_sdr_luminance_key];
      }
      if (min_luminance_key != nil) {
        [descriptor performSelector:set_display_info withObject:@(minimum_luminance) withObject:min_luminance_key];
      }
      if (expected_luminance_key != nil) {
        [descriptor performSelector:set_display_info withObject:@(peak_luminance) withObject:expected_luminance_key];
      }

      BOOST_LOG(info) << "macOS virtual display HDR displayInfo configured peak="sv
                      << peak_luminance
                      << " sdr="sv
                      << sdr_luminance
                      << " min="sv
                      << minimum_luminance;
    }

    int virtual_display_transfer_function(bool hdr_enabled, int client_display_transfer) {
      switch (static_cast<video::client_display_transfer_e>(client_display_transfer)) {
        case video::client_display_transfer_e::pq:
          return CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ);
        case video::client_display_transfer_e::hlg:
          return CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_ITU_R_2100_HLG);
        case video::client_display_transfer_e::sdr:
          return CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_ITU_R_709_2);
        case video::client_display_transfer_e::unknown:
        default:
          break;
      }

      return hdr_enabled ?
               CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) :
               CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_ITU_R_709_2);
    }

    bool force_virtual_display_mode(CGDirectDisplayID display_id, std::uint32_t logical_width, std::uint32_t logical_height, double refresh_rate) {
      CFArrayRef display_modes = CGDisplayCopyAllDisplayModes(display_id, nullptr);
      if (display_modes == nullptr) {
        BOOST_LOG(warning) << "Unable to enumerate macOS display modes for virtual display "sv << display_id;
        return false;
      }

      CGDisplayModeRef selected_mode = nullptr;
      double best_refresh_delta = std::numeric_limits<double>::max();
      const auto requested_refresh = refresh_rate > 0.0 ? refresh_rate : 60.0;

      const auto mode_count = CFArrayGetCount(display_modes);
      for (CFIndex index = 0; index < mode_count; ++index) {
        auto mode = static_cast<CGDisplayModeRef>(const_cast<void *>(CFArrayGetValueAtIndex(display_modes, index)));
        if (mode == nullptr) {
          continue;
        }

        if (CGDisplayModeGetWidth(mode) != logical_width || CGDisplayModeGetHeight(mode) != logical_height) {
          continue;
        }

        const auto candidate_refresh = CGDisplayModeGetRefreshRate(mode);
        const auto refresh_delta = std::fabs((candidate_refresh > 0.0 ? candidate_refresh : requested_refresh) - requested_refresh);
        if (selected_mode == nullptr || refresh_delta < best_refresh_delta) {
          selected_mode = mode;
          best_refresh_delta = refresh_delta;
        }
      }

      bool success = false;
      if (selected_mode != nullptr) {
        const auto result = CGDisplaySetDisplayMode(display_id, selected_mode, nullptr);
        success = result == kCGErrorSuccess;
        BOOST_LOG(info) << "Forced macOS display mode selection displayID="sv << display_id
                        << " logical="sv << logical_width << "x"sv << logical_height
                        << " refresh="sv << requested_refresh
                        << " success="sv << success;
      } else {
        BOOST_LOG(warning) << "No matching macOS display mode found for virtual display "sv << display_id
                           << " logical="sv << logical_width << "x"sv << logical_height;
      }

      CFRelease(display_modes);
      return success;
    }

    bool is_reasonable_hidpi_logical_size(const virtual_display_handle_t &handle, std::uint32_t logical_width, std::uint32_t logical_height) {
      if (logical_width == 0 || logical_height == 0 || handle.pixel_width == 0 || handle.pixel_height == 0) {
        return false;
      }

      if (logical_width >= handle.pixel_width || logical_height >= handle.pixel_height) {
        return false;
      }

      const auto backing_aspect = static_cast<double>(handle.pixel_width) / static_cast<double>(handle.pixel_height);
      const auto logical_aspect = static_cast<double>(logical_width) / static_cast<double>(logical_height);
      const auto aspect_delta = std::fabs(logical_aspect - backing_aspect) / backing_aspect;
      return aspect_delta <= 0.02;
    }

    NSString *display_name_for_client(const char *client_name) {
      if (client_name && client_name[0] != '\0') {
        return [NSString stringWithFormat:@"Apollo (%s)", client_name];
      }

      return @"Apollo Virtual Display";
    }

    bool classes_available() {
      return NSClassFromString(@"CGVirtualDisplay") != nil &&
             NSClassFromString(@"CGVirtualDisplayMode") != nil &&
             NSClassFromString(@"CGVirtualDisplaySettings") != nil &&
             NSClassFromString(@"CGVirtualDisplayDescriptor") != nil;
    }

    bool screen_is_hdr_capable(NSScreen *screen) {
      if (screen == nil) {
        return false;
      }

      if (@available(macOS 10.15, *)) {
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.001 ||
               screen.maximumExtendedDynamicRangeColorComponentValue > 1.001;
      }

      return false;
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
      if ([localized_name containsString:@"display p3"] || [localized_name containsString:@"p3"]) {
        return true;
      }

      return false;
    }
  }  // namespace

  DRIVER_STATUS openVDisplayDevice() {
    driver_status = classes_available() ? DRIVER_STATUS::OK : DRIVER_STATUS::FAILED;
    return driver_status;
  }

  void closeVDisplayDevice() {
    std::lock_guard lock(display_mutex);
    active_displays.clear();
    driver_status = DRIVER_STATUS::UNKNOWN;
  }

  color_profile_t probeHostDisplayColorProfile(bool hdr_enabled, int client_display_gamut, int client_display_transfer) {
    NSScreen *reference_screen = [NSScreen mainScreen];
    if (reference_screen == nil && [NSScreen screens].count > 0) {
      reference_screen = [NSScreen screens].firstObject;
    }

    const auto client_transfer = static_cast<video::client_display_transfer_e>(client_display_transfer);
    const bool client_wants_hdr =
      hdr_enabled ||
      client_transfer == video::client_display_transfer_e::pq ||
      client_transfer == video::client_display_transfer_e::hlg;
    const bool use_display_p3 =
      client_display_gamut == static_cast<int>(video::client_display_gamut_e::display_p3) ? true :
      client_display_gamut == static_cast<int>(video::client_display_gamut_e::srgb) ? false :
      client_wants_hdr ? true :
      screen_prefers_display_p3(reference_screen);
    color_profile_t profile =
      client_display_gamut == static_cast<int>(video::client_display_gamut_e::rec2020) ? kRec2020ColorProfile :
      use_display_p3 ? kDisplayP3ColorProfile :
      kSrgbColorProfile;
    profile.hdr_capable = client_wants_hdr || screen_is_hdr_capable(reference_screen);

    const auto profile_gamut =
      client_display_gamut == static_cast<int>(video::client_display_gamut_e::rec2020) ? "rec2020"sv :
      profile.display_p3 ? "display-p3"sv :
      "srgb"sv;
    const auto transfer_name =
      client_transfer == video::client_display_transfer_e::pq ? "pq"sv :
      client_transfer == video::client_display_transfer_e::hlg ? "hlg"sv :
      client_transfer == video::client_display_transfer_e::sdr ? "sdr"sv :
      "unknown"sv;
    BOOST_LOG(info) << "macOS virtual display color profile: gamut="sv
                    << profile_gamut
                    << " hdr_capable="sv << profile.hdr_capable
                    << " hdr_intent="sv << hdr_enabled
                    << " client_gamut="sv << client_display_gamut
                    << " client_transfer="sv << transfer_name;

    return profile;
  }

  std::string createVirtualDisplay(
    const char *client_uid,
    const char *client_name,
    std::uint32_t logical_width,
    std::uint32_t logical_height,
    std::uint32_t fps_millihz,
    int scale_factor,
    bool hi_dpi,
    bool hdr_enabled,
    int client_display_gamut,
    int client_display_transfer
  ) {
    const std::string display_key = client_uid ? client_uid : "";
    if (display_key.empty()) {
      BOOST_LOG(error) << "macOS virtual display requires a stable client uid"sv;
      return {};
    }

    if (openVDisplayDevice() != DRIVER_STATUS::OK) {
      BOOST_LOG(error) << "macOS virtual display classes are unavailable"sv;
      return {};
    }

    Class descriptor_class = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class mode_class = NSClassFromString(@"CGVirtualDisplayMode");
    Class settings_class = NSClassFromString(@"CGVirtualDisplaySettings");
    Class display_class = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptor_class || !mode_class || !settings_class || !display_class) {
      BOOST_LOG(error) << "macOS virtual display runtime lookup failed"sv;
      return {};
    }

    using init_with_descriptor_t = id (*)(id, SEL, id);
    using init_mode_t = id (*)(id, SEL, NSUInteger, NSUInteger, double);
    using init_mode_with_transfer_t = id (*)(id, SEL, NSUInteger, NSUInteger, double, unsigned int);
    using apply_settings_t = BOOL (*)(id, SEL, id);

    auto handle = std::make_unique<virtual_display_handle_t>();
    const auto width = backing_dimension_for_scale_factor(logical_width, scale_factor, hi_dpi);
    const auto height = backing_dimension_for_scale_factor(logical_height, scale_factor, hi_dpi);
    const auto host_profile = probeHostDisplayColorProfile(hdr_enabled, client_display_gamut, client_display_transfer);
    const auto physical_size = virtual_display_size_for_pixels(width, height);
    const auto transfer_function = virtual_display_transfer_function(hdr_enabled, client_display_transfer);
    handle->queue = dispatch_queue_create("dev.lizardbyte.sunshine.virtual-display", DISPATCH_QUEUE_SERIAL);
    handle->descriptor = [[descriptor_class alloc] init];
    handle->settings = [[settings_class alloc] init];
    if (handle->queue == nil || handle->descriptor == nil || handle->settings == nil) {
      BOOST_LOG(error) << "macOS virtual display bootstrap allocation failed"sv;
      return {};
    }

    [handle->descriptor setValue:@(6973u) forKey:@"vendorID"];
    [handle->descriptor setValue:@(static_cast<unsigned int>(width ^ height ^ 0xA901u)) forKey:@"productID"];
    [handle->descriptor setValue:@(1u) forKey:@"serialNumber"];
    [handle->descriptor setValue:display_name_for_client(client_name) forKey:@"name"];
    [handle->descriptor setValue:[NSValue valueWithSize:physical_size] forKey:@"sizeInMillimeters"];
    [handle->descriptor setValue:@(width) forKey:@"maxPixelsWide"];
    [handle->descriptor setValue:@(height) forKey:@"maxPixelsHigh"];
    [handle->descriptor setValue:[NSValue valueWithPoint:NSMakePoint(host_profile.red.x, host_profile.red.y)] forKey:@"redPrimary"];
    [handle->descriptor setValue:[NSValue valueWithPoint:NSMakePoint(host_profile.green.x, host_profile.green.y)] forKey:@"greenPrimary"];
    [handle->descriptor setValue:[NSValue valueWithPoint:NSMakePoint(host_profile.blue.x, host_profile.blue.y)] forKey:@"bluePrimary"];
    [handle->descriptor setValue:[NSValue valueWithPoint:NSMakePoint(host_profile.white.x, host_profile.white.y)] forKey:@"whitePoint"];
    [handle->descriptor setValue:handle->queue forKey:@"queue"];
    configure_hdr_display_info(handle->descriptor, hdr_enabled, host_profile);

    if ([mode_class instancesRespondToSelector:sel_registerName("initWithWidth:height:refreshRate:transferFunction:")]) {
      handle->mode = ((init_mode_with_transfer_t) objc_msgSend)(
        [mode_class alloc],
        sel_registerName("initWithWidth:height:refreshRate:transferFunction:"),
        static_cast<NSUInteger>(logical_width),
        static_cast<NSUInteger>(logical_height),
        normalize_refresh_rate(fps_millihz),
        static_cast<unsigned int>(std::max(transfer_function, 0))
      );
    } else {
      handle->mode = ((init_mode_t) objc_msgSend)(
        [mode_class alloc],
        sel_registerName("initWithWidth:height:refreshRate:"),
        static_cast<NSUInteger>(logical_width),
        static_cast<NSUInteger>(logical_height),
        normalize_refresh_rate(fps_millihz)
      );
    }
    if (handle->mode == nil) {
      BOOST_LOG(error) << "macOS virtual display mode creation failed"sv;
      return {};
    }

    [handle->settings setValue:@[handle->mode] forKey:@"modes"];
    [handle->settings setValue:@(hi_dpi ? 1 : 0) forKey:@"hiDPI"];
    BOOST_LOG(info) << "macOS virtual display mode: pixels="sv << width << "x"sv << height
                    << " logical="sv << logical_width << "x"sv << logical_height
                    << " physical-mm="sv << physical_size.width << "x"sv << physical_size.height
                    << " transfer-function="sv << transfer_function;

    handle->display = ((init_with_descriptor_t) objc_msgSend)(
      [display_class alloc],
      sel_registerName("initWithDescriptor:"),
      handle->descriptor
    );
    if (handle->display == nil) {
      BOOST_LOG(error) << "macOS virtual display initWithDescriptor failed"sv;
      return {};
    }

    if (!((apply_settings_t) objc_msgSend)(handle->display, sel_registerName("applySettings:"), handle->settings)) {
      BOOST_LOG(error) << "macOS virtual display applySettings failed"sv;
      return {};
    }

    NSNumber *display_id_number = [handle->display valueForKey:@"displayID"];
    if (display_id_number == nil) {
      BOOST_LOG(error) << "macOS virtual display did not expose a displayID"sv;
      return {};
    }

    handle->display_id = std::to_string(display_id_number.unsignedIntValue);
    handle->pixel_width = width;
    handle->pixel_height = height;
    handle->logical_width = logical_width;
    handle->logical_height = logical_height;
    BOOST_LOG(info) << "macOS virtual display created displayID="sv << handle->display_id;
    force_virtual_display_mode(display_id_number.unsignedIntValue, logical_width, logical_height, normalize_refresh_rate(fps_millihz));

    std::lock_guard lock(display_mutex);
    active_displays[display_key] = std::move(handle);
    return active_displays[display_key]->display_id;
  }

  bool updateVirtualDisplayMode(
    const std::string &client_uid,
    std::uint32_t logical_width,
    std::uint32_t logical_height,
    std::uint32_t fps_millihz,
    int client_display_transfer
  ) {
    if (client_uid.empty()) {
      return false;
    }

    using init_mode_t = id (*)(id, SEL, NSUInteger, NSUInteger, double);
    using init_mode_with_transfer_t = id (*)(id, SEL, NSUInteger, NSUInteger, double, unsigned int);
    using apply_settings_t = BOOL (*)(id, SEL, id);

    Class mode_class = NSClassFromString(@"CGVirtualDisplayMode");
    if (mode_class == nil) {
      return false;
    }

    std::lock_guard lock(display_mutex);
    auto it = active_displays.find(client_uid);
    if (it == active_displays.end() || it->second->display == nil || it->second->settings == nil) {
      return false;
    }

    auto &handle = *it->second;
    if (!is_reasonable_hidpi_logical_size(handle, logical_width, logical_height)) {
      BOOST_LOG(info) << "Ignoring macOS virtual display mode update for displayID="sv << handle.display_id
                      << " logical="sv << logical_width << "x"sv << logical_height
                      << " backing="sv << handle.pixel_width << "x"sv << handle.pixel_height;
      return false;
    }

    const auto transfer_function = virtual_display_transfer_function(
      static_cast<video::client_display_transfer_e>(client_display_transfer) != video::client_display_transfer_e::sdr,
      client_display_transfer
    );

    id new_mode = nil;
    if ([mode_class instancesRespondToSelector:sel_registerName("initWithWidth:height:refreshRate:transferFunction:")]) {
      new_mode = ((init_mode_with_transfer_t) objc_msgSend)(
        [mode_class alloc],
        sel_registerName("initWithWidth:height:refreshRate:transferFunction:"),
        static_cast<NSUInteger>(std::max(logical_width, 1u)),
        static_cast<NSUInteger>(std::max(logical_height, 1u)),
        normalize_refresh_rate(fps_millihz),
        static_cast<unsigned int>(std::max(transfer_function, 0))
      );
    } else {
      new_mode = ((init_mode_t) objc_msgSend)(
        [mode_class alloc],
        sel_registerName("initWithWidth:height:refreshRate:"),
        static_cast<NSUInteger>(std::max(logical_width, 1u)),
        static_cast<NSUInteger>(std::max(logical_height, 1u)),
        normalize_refresh_rate(fps_millihz)
      );
    }

    if (new_mode == nil) {
      BOOST_LOG(warning) << "macOS virtual display mode update failed to create a new mode"sv;
      return false;
    }

    [handle.settings setValue:@[new_mode] forKey:@"modes"];
    [handle.settings setValue:@(1) forKey:@"hiDPI"];
    const auto ok = ((apply_settings_t) objc_msgSend)(handle.display, sel_registerName("applySettings:"), handle.settings);
    if (!ok) {
      [new_mode release];
      BOOST_LOG(warning) << "macOS virtual display mode update failed for displayID="sv << handle.display_id;
      return false;
    }

    [handle.mode release];
    handle.mode = [new_mode retain];
    [new_mode release];

    BOOST_LOG(info) << "Updated macOS virtual display mode for displayID="sv << handle.display_id
                    << " logical="sv << logical_width << "x"sv << logical_height
                    << " transfer-function="sv << transfer_function;
    handle.logical_width = logical_width;
    handle.logical_height = logical_height;
    force_virtual_display_mode(static_cast<CGDirectDisplayID>(std::strtoul(handle.display_id.c_str(), nullptr, 10)), logical_width, logical_height, normalize_refresh_rate(fps_millihz));
    return true;
  }

  bool removeVirtualDisplay(const std::string &client_uid) {
    std::lock_guard lock(display_mutex);
    auto it = active_displays.find(client_uid);
    if (it == active_displays.end()) {
      return false;
    }

    BOOST_LOG(info) << "macOS virtual display removed displayID="sv << it->second->display_id;
    active_displays.erase(it);
    return true;
  }
}  // namespace VDISPLAY
