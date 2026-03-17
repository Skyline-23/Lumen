#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

#include "src/logging.h"
#include "src/video.h"
#include "src/platform/macos/virtual_display.h"

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

  color_profile_t probeHostDisplayColorProfile(bool hdr_enabled, int client_display_gamut) {
    NSScreen *reference_screen = [NSScreen mainScreen];
    if (reference_screen == nil && [NSScreen screens].count > 0) {
      reference_screen = [NSScreen screens].firstObject;
    }

    const bool use_display_p3 =
      client_display_gamut == static_cast<int>(video::client_display_gamut_e::display_p3) ? true :
      client_display_gamut == static_cast<int>(video::client_display_gamut_e::srgb) ? false :
      screen_prefers_display_p3(reference_screen);
    color_profile_t profile =
      client_display_gamut == static_cast<int>(video::client_display_gamut_e::rec2020) ? kRec2020ColorProfile :
      use_display_p3 ? kDisplayP3ColorProfile :
      kSrgbColorProfile;
    profile.hdr_capable = screen_is_hdr_capable(reference_screen);

    const auto profile_gamut =
      client_display_gamut == static_cast<int>(video::client_display_gamut_e::rec2020) ? "rec2020"sv :
      profile.display_p3 ? "display-p3"sv :
      "srgb"sv;
    BOOST_LOG(info) << "macOS virtual display color profile: gamut="sv
                    << profile_gamut
                    << " hdr_capable="sv << profile.hdr_capable
                    << " hdr_intent="sv << hdr_enabled
                    << " client_gamut="sv << client_display_gamut;

    return profile;
  }

  std::string createVirtualDisplay(
    const char *client_uid,
    const char *client_name,
    std::uint32_t width,
    std::uint32_t height,
    std::uint32_t fps_millihz,
    bool hdr_enabled,
    int client_display_gamut
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
    using apply_settings_t = BOOL (*)(id, SEL, id);

    auto handle = std::make_unique<virtual_display_handle_t>();
    const auto host_profile = probeHostDisplayColorProfile(hdr_enabled, client_display_gamut);
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
    [handle->descriptor setValue:[NSValue valueWithSize:NSMakeSize(600.0, 340.0)] forKey:@"sizeInMillimeters"];
    [handle->descriptor setValue:@(width) forKey:@"maxPixelsWide"];
    [handle->descriptor setValue:@(height) forKey:@"maxPixelsHigh"];
    [handle->descriptor setValue:[NSValue valueWithPoint:NSMakePoint(host_profile.red.x, host_profile.red.y)] forKey:@"redPrimary"];
    [handle->descriptor setValue:[NSValue valueWithPoint:NSMakePoint(host_profile.green.x, host_profile.green.y)] forKey:@"greenPrimary"];
    [handle->descriptor setValue:[NSValue valueWithPoint:NSMakePoint(host_profile.blue.x, host_profile.blue.y)] forKey:@"bluePrimary"];
    [handle->descriptor setValue:[NSValue valueWithPoint:NSMakePoint(host_profile.white.x, host_profile.white.y)] forKey:@"whitePoint"];
    [handle->descriptor setValue:handle->queue forKey:@"queue"];

    handle->mode = ((init_mode_t) objc_msgSend)(
      [mode_class alloc],
      sel_registerName("initWithWidth:height:refreshRate:"),
      static_cast<NSUInteger>(std::max(width, 1u)),
      static_cast<NSUInteger>(std::max(height, 1u)),
      normalize_refresh_rate(fps_millihz)
    );
    if (handle->mode == nil) {
      BOOST_LOG(error) << "macOS virtual display mode creation failed"sv;
      return {};
    }

    [handle->settings setValue:@[handle->mode] forKey:@"modes"];
    [handle->settings setValue:@(1) forKey:@"hiDPI"];

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
    BOOST_LOG(info) << "macOS virtual display created displayID="sv << handle->display_id;

    std::lock_guard lock(display_mutex);
    active_displays[display_key] = std::move(handle);
    return active_displays[display_key]->display_id;
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
