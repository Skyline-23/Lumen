/**
 * @file src/video.cpp
 * @brief Definitions for video.
 */
// standard includes
#include <array>
#include <atomic>
#include <bitset>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <list>
#include <mutex>
#include <thread>

// lib includes
#include <boost/pointer_cast.hpp>

extern "C" {
#include <libavutil/imgutils.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
}

// local includes
#include "process.h"
#include "cbs.h"
#include "config.h"
#include "display_device.h"
#include "globals.h"
#include "input.h"
#include "logging.h"
#include "nvenc/nvenc_base.h"
#include "platform/common.h"
#include "sync.h"
#include "video.h"

#ifdef __APPLE__
  #include <CoreFoundation/CoreFoundation.h>
  #include <CoreMedia/CoreMedia.h>
  #include <VideoToolbox/VideoToolbox.h>
  #include <mach/mach_time.h>
  #include "LumenCore.h"
  #include "LumenMacBridge.h"
  #include "platform/macos/av_img_t.h"
  #include "platform/macos/misc.h"
#endif

#ifdef _WIN32
  #include "platform/windows/virtual_display.h"
extern "C" {
  #include <libavutil/hwcontext_d3d11va.h>
}
#endif

using namespace std::literals;

namespace video {

  /**
   * @brief Check if we can allow probing for the encoders.
   * @return True if there should be no issues with the probing, false if we should prevent it.
   */
  bool allow_encoder_probing() {
    const auto devices {display_device::enumerate_devices()};

    // // If there are no devices, then either the API is not working correctly or OS does not support the lib.
    // // Either way we should not block the probing in this case as we can't tell what's wrong.
    // if (devices.empty()) {
    //   return true;
    // }

    if (devices.empty()) {
      #ifdef _WIN32
      // We'll create a temporary virtual display for probing anyways.
      if (proc::vDisplayDriverStatus == VDISPLAY::DRIVER_STATUS::OK) {
        return false;
      }
      #endif
        return true;
    }

    // Since Windows 11 24H2, it is possible that there will be no active devices present
    // for some reason (probably a bug). Trying to probe encoders in such a state locks/breaks the DXGI
    // and also the display device for Windows. So we must have at least 1 active device.
    const bool at_least_one_device_is_active = std::any_of(std::begin(devices), std::end(devices), [](const auto &device) {
      // If device has additional info, it is active.
      return static_cast<bool>(device.m_info);
    });

    if (at_least_one_device_is_active) {
      return true;
    }

    BOOST_LOG(error) << "No display devices are active at the moment! Cannot probe the encoders.";
    return false;
  }

  void free_ctx(AVCodecContext *ctx) {
    avcodec_free_context(&ctx);
  }

  void free_frame(AVFrame *frame) {
    av_frame_free(&frame);
  }

  void free_buffer(AVBufferRef *ref) {
    av_buffer_unref(&ref);
  }

#ifdef __APPLE__
  namespace {
    constexpr uint32_t lumen_core_ingress_wait_timeout_ms = 5000;
    constexpr auto lumen_core_ingress_progress_log_interval = 3s;

    class lumen_core_display_time_clock_t {
    public:
      std::optional<std::chrono::steady_clock::time_point> frame_timestamp(std::uint64_t source_display_time) {
        if (source_display_time == 0) {
          return std::nullopt;
        }

        if (!epoch_initialized || source_display_time < epoch_source_display_time) {
          epoch_source_display_time = source_display_time;
          epoch_timestamp = std::chrono::steady_clock::now();
          epoch_initialized = true;
          return epoch_timestamp;
        }

        const auto delta_nanoseconds = display_time_delta_to_nanoseconds(source_display_time - epoch_source_display_time);
        return epoch_timestamp + delta_nanoseconds;
      }

      static double display_time_delta_milliseconds(std::uint64_t delta_display_time) {
        return static_cast<double>(display_time_delta_to_nanoseconds(delta_display_time).count()) / 1'000'000.0;
      }

    private:
      static std::chrono::nanoseconds display_time_delta_to_nanoseconds(std::uint64_t delta_display_time) {
        static mach_timebase_info_data_t timebase_info {};
        static const auto timebase_ready = []() {
          mach_timebase_info(&timebase_info);
          return true;
        }();
        (void) timebase_ready;

        const auto numerator = static_cast<unsigned long long>(timebase_info.numer);
        const auto denominator = static_cast<unsigned long long>(std::max(timebase_info.denom, 1u));
        const auto quotient = delta_display_time / denominator;
        const auto remainder = delta_display_time % denominator;
        const auto nanoseconds_from_quotient = quotient * numerator;
        const auto nanoseconds_from_remainder = (remainder * numerator) / denominator;
        const auto total_nanoseconds = nanoseconds_from_quotient + nanoseconds_from_remainder;

        return std::chrono::nanoseconds(total_nanoseconds);
      }

      bool epoch_initialized = false;
      std::uint64_t epoch_source_display_time = 0;
      std::chrono::steady_clock::time_point epoch_timestamp {};
    };

    std::string_view lumen_core_codec_name(LumenCoreCaptureCodec codec) {
      switch (codec) {
        case LumenCoreCaptureCodecH264:
          return "h264"sv;
        case LumenCoreCaptureCodecHEVC:
          return "hevc"sv;
        case LumenCoreCaptureCodecProResProxy:
          return "prores-proxy"sv;
        default:
          return "unknown"sv;
      }
    }

    video::encoded_tile_metadata_t lumen_core_tile_metadata(
      const LumenCoreEncodedCaptureTileMetadata &metadata
    ) {
      video::encoded_tile_metadata_t result {};
      result.frame_group_id = metadata.frame_group_id;
      result.tile_index = metadata.tile_index;
      result.tile_count = std::max<std::uint32_t>(1, metadata.tile_count);
      result.encoded_lane_index = metadata.encoded_lane_index;
      result.encoded_lane_count = std::max<std::uint32_t>(1, metadata.encoded_lane_count);
      result.has_tile_region = metadata.has_tile_region;
      result.tile_origin_x = metadata.has_tile_region ? metadata.tile_origin_x : 0;
      result.tile_origin_y = metadata.has_tile_region ? metadata.tile_origin_y : 0;
      result.tile_width = metadata.has_tile_region ? metadata.tile_width : 0;
      result.tile_height = metadata.has_tile_region ? metadata.tile_height : 0;
      return result;
    }

    std::string_view requested_video_format_name(int video_format) {
      switch (video_format) {
        case 0:
          return "h264"sv;
        case 1:
          return "hevc"sv;
        case 2:
          return "av1"sv;
        default:
          return "unknown"sv;
      }
    }

    video::hdr_frame_state_t negotiated_hdr_frame_state(
      const config_t &config,
      bool frame_is_hdr_signaled,
      const SS_HDR_METADATA *metadata = nullptr
    ) {
      return video::make_default_hdr_frame_state(
        video::effective_dynamic_range_transport(config),
        config.width,
        config.height,
        frame_is_hdr_signaled,
        metadata
      );
    }

    video::hdr_frame_state_t negotiated_hdr_frame_state(
      video::dynamic_range_transport_e transport,
      int frame_width,
      int frame_height,
      bool frame_is_hdr_signaled,
      const SS_HDR_METADATA *metadata = nullptr
    ) {
      return video::make_default_hdr_frame_state(
        transport,
        frame_width,
        frame_height,
        frame_is_hdr_signaled,
        metadata
      );
    }

    std::optional<video::hdr_frame_state_t> negotiated_optional_hdr_frame_state(
      const config_t &config,
      bool frame_is_hdr_signaled,
      const SS_HDR_METADATA *metadata = nullptr
    ) {
      if (!video::dynamic_range_transport_uses_hdr_frame_state(video::effective_dynamic_range_transport(config))) {
        return std::nullopt;
      }

      return negotiated_hdr_frame_state(
        config,
        frame_is_hdr_signaled,
        metadata
      );
    }

    std::optional<video::hdr_frame_state_t> negotiated_optional_hdr_frame_state(
      video::dynamic_range_transport_e transport,
      int frame_width,
      int frame_height,
      bool frame_is_hdr_signaled,
      const SS_HDR_METADATA *metadata = nullptr
    ) {
      if (!video::dynamic_range_transport_uses_hdr_frame_state(transport)) {
        return std::nullopt;
      }

      return negotiated_hdr_frame_state(
        transport,
        frame_width,
        frame_height,
        frame_is_hdr_signaled,
        metadata
      );
    }

    video::hdr_frame_state_t negotiated_external_overlay_hdr_frame_state(
      const config_t &config,
      const platf::external_capture_display_metadata_t &external_metadata,
      bool frame_is_hdr_signaled,
      const SS_HDR_METADATA *metadata = nullptr
    ) {
      const auto transport = video::effective_dynamic_range_transport(config);
      if (transport != video::dynamic_range_transport_e::sdr_base_hdr_overlay || !frame_is_hdr_signaled) {
        return negotiated_hdr_frame_state(config, frame_is_hdr_signaled, metadata);
      }

      const auto scalar = external_metadata.scalar_inv > 0.0f ? (1.0f / external_metadata.scalar_inv) : 0.0f;
      const auto content_width = std::clamp(
        static_cast<int>(std::lround(static_cast<float>(external_metadata.env_width) * scalar)),
        0,
        config.width
      );
      const auto content_height = std::clamp(
        static_cast<int>(std::lround(static_cast<float>(external_metadata.env_height) * scalar)),
        0,
        config.height
      );
      const auto content_x = std::clamp(
        static_cast<int>(std::lround(external_metadata.client_offset_x)),
        0,
        std::max(config.width - content_width, 0)
      );
      const auto content_y = std::clamp(
        static_cast<int>(std::lround(external_metadata.client_offset_y)),
        0,
        std::max(config.height - content_height, 0)
      );

      if (content_x == 0 &&
          content_y == 0 &&
          content_width == config.width &&
          content_height == config.height) {
        return video::make_full_frame_overlay_hdr_frame_state(
          config.width,
          config.height,
          metadata
        );
      }

      return video::make_overlay_hdr_frame_state(
        video::make_coarse_overlay_regions(
          content_x,
          content_y,
          content_width,
          content_height,
          nullptr
        ),
        metadata
      );
    }

    double callback_latency_resync_threshold_milliseconds(const config_t &config) {
      const auto frame_interval_ms = config.framerate > 0 ?
        (1000.0 / static_cast<double>(config.framerate)) :
        (1000.0 / 60.0);
      if (config.framerate >= 110) {
        return std::max(80.0, frame_interval_ms * 8.0);
      }
      if (config.framerate >= 90) {
        return std::max(80.0, frame_interval_ms * 7.0);
      }
      return std::max(80.0, frame_interval_ms * 6.0);
    }

    double packet_timestamp_resync_threshold_milliseconds(const config_t &config) {
      const auto frame_interval_ms = config.framerate > 0 ?
        (1000.0 / static_cast<double>(config.framerate)) :
        (1000.0 / 60.0);
      if (config.framerate >= 110) {
        return std::max(80.0, frame_interval_ms * 8.0);
      }
      if (config.framerate >= 90) {
        return std::max(80.0, frame_interval_ms * 7.0);
      }
      return std::max(80.0, frame_interval_ms * 6.0);
    }

    void refresh_external_capture_metadata(
      safe::mail_t mail,
      const config_t &config,
      platf::external_capture_display_metadata_t &external_metadata
    ) {
      platf::query_external_capture_display_metadata(
        proc::proc.display_name,
        config.width,
        config.height,
        external_metadata
      );

      auto touch_port_event = mail->event<input::touch_port_t>(mail::touch_port);
      touch_port_event->raise(input::touch_port_t {
        external_metadata.viewport,
        external_metadata.env_width,
        external_metadata.env_height,
        external_metadata.client_offset_x,
        external_metadata.client_offset_y,
        external_metadata.scalar_inv,
      });
    }

    void request_external_encoded_capture_key_frame() {
      LumenMacBridgeRequestImmediateCaptureKeyFrame();
    }

    void restart_external_encoded_capture_session(std::string_view reason) {
      std::string owned_reason {reason};
      LumenMacBridgeRestartMacDisplayKitCapture(owned_reason.c_str());
    }

    std::string lumen_core_cfstring_to_utf8(CFStringRef value) {
      if (!value) {
        return {};
      }

      if (const auto *direct = CFStringGetCStringPtr(value, kCFStringEncodingUTF8)) {
        return direct;
      }

      const auto length = CFStringGetLength(value);
      const auto max_size = static_cast<std::size_t>(CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1);
      std::string result(max_size, '\0');
      if (!CFStringGetCString(value, result.data(), static_cast<CFIndex>(result.size()), kCFStringEncodingUTF8)) {
        return {};
      }

      result.resize(std::strlen(result.c_str()));
      return result;
    }

    std::string lumen_core_sample_buffer_extension_string(CMSampleBufferRef sample_buffer, CFStringRef key) {
      const auto format_description = CMSampleBufferGetFormatDescription(sample_buffer);
      if (!format_description) {
        return {};
      }

      const auto extensions = CMFormatDescriptionGetExtensions(format_description);
      if (!extensions) {
        return {};
      }

      return lumen_core_cfstring_to_utf8(static_cast<CFStringRef>(CFDictionaryGetValue(extensions, key)));
    }

    bool lumen_core_sample_buffer_extension_present(CMSampleBufferRef sample_buffer, CFStringRef key) {
      const auto format_description = CMSampleBufferGetFormatDescription(sample_buffer);
      if (!format_description) {
        return false;
      }

      const auto extensions = CMFormatDescriptionGetExtensions(format_description);
      return extensions && CFDictionaryContainsKey(extensions, key);
    }

    bool lumen_core_transfer_function_is_hdr(std::string_view transfer_function) {
      return transfer_function == "SMPTE_ST_2084_PQ"sv ||
             transfer_function == "ITU_R_2100_PQ"sv ||
             transfer_function == "ITU_R_2100_HLG"sv ||
             transfer_function == "ARIB_STD_B67_HLG"sv;
    }

    bool lumen_core_sample_buffer_indicates_hdr(CMSampleBufferRef sample_buffer) {
      if (lumen_core_sample_buffer_extension_present(sample_buffer, kCMFormatDescriptionExtension_MasteringDisplayColorVolume) ||
          lumen_core_sample_buffer_extension_present(sample_buffer, kCMFormatDescriptionExtension_ContentLightLevelInfo)) {
        return true;
      }

      return lumen_core_transfer_function_is_hdr(
        lumen_core_sample_buffer_extension_string(sample_buffer, kCMFormatDescriptionExtension_TransferFunction)
      );
    }

    std::uint64_t fnv1a64_hash(const std::uint8_t *data, std::size_t size) {
      constexpr std::uint64_t offset_basis = 1469598103934665603ull;
      constexpr std::uint64_t prime = 1099511628211ull;
      auto hash = offset_basis;
      for (std::size_t index = 0; index < size; ++index) {
        hash ^= static_cast<std::uint64_t>(data[index]);
        hash *= prime;
      }
      return hash;
    }

    std::uint64_t packet_payload_hash(const std::vector<std::uint8_t> &payload) {
      return fnv1a64_hash(payload.data(), payload.size());
    }

    std::string lumen_core_sample_buffer_dimensions(CMSampleBufferRef sample_buffer) {
      const auto format_description = CMSampleBufferGetFormatDescription(sample_buffer);
      if (!format_description) {
        return "unknown";
      }

      const auto dimensions = CMVideoFormatDescriptionGetDimensions(format_description);
      if (dimensions.width <= 0 || dimensions.height <= 0) {
        return "unknown";
      }

      return std::to_string(dimensions.width) + "x" + std::to_string(dimensions.height);
    }

    CMVideoCodecType lumen_core_codec_type(LumenCoreCaptureCodec codec) {
      switch (codec) {
        case LumenCoreCaptureCodecH264:
          return kCMVideoCodecType_H264;
        case LumenCoreCaptureCodecHEVC:
          return kCMVideoCodecType_HEVC;
        case LumenCoreCaptureCodecProResProxy:
          return kCMVideoCodecType_AppleProRes422Proxy;
        default:
          return 0;
      }
    }

    bool lumen_core_codec_matches_video_format(LumenCoreCaptureCodec codec, int video_format) {
      switch (video_format) {
        case 0:
          return codec == LumenCoreCaptureCodecH264;
        case 1:
          return codec == LumenCoreCaptureCodecHEVC;
        default:
          return false;
      }
    }

    std::optional<int> lumen_core_video_format_for_codec(LumenCoreCaptureCodec codec) {
      switch (codec) {
        case LumenCoreCaptureCodecH264:
          return 0;
        case LumenCoreCaptureCodecHEVC:
          return 1;
        default:
          return std::nullopt;
      }
    }

    bool external_sample_buffer_is_idr(CMSampleBufferRef sampleBuffer) {
      CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
      if (!attachments || CFArrayGetCount(attachments) == 0) {
        return true;
      }

      CFDictionaryRef attachment = (CFDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
      CFBooleanRef not_sync = (CFBooleanRef) CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_NotSync);
      return not_sync == nullptr || not_sync == kCFBooleanFalse;
    }

    const uint8_t *copy_or_map_external_sample_bytes(CMBlockBufferRef data_buffer, std::vector<uint8_t> &scratch, size_t &total_length) {
      total_length = (size_t) CMBlockBufferGetDataLength(data_buffer);
      size_t contiguous_length = 0;
      char *contiguous_ptr = nullptr;
      if (CMBlockBufferGetDataPointer(data_buffer, 0, &contiguous_length, nullptr, &contiguous_ptr) == kCMBlockBufferNoErr &&
          contiguous_ptr != nullptr &&
          contiguous_length >= total_length) {
        return reinterpret_cast<const uint8_t *>(contiguous_ptr);
      }

      scratch.resize(total_length);
      if (CMBlockBufferCopyDataBytes(data_buffer, 0, total_length, scratch.data()) != noErr) {
        return nullptr;
      }
      return scratch.data();
    }

    void append_parameter_sets_for_codec(CMSampleBufferRef sampleBuffer, CMVideoCodecType codec_type, std::vector<uint8_t> &output) {
      auto format_description = CMSampleBufferGetFormatDescription(sampleBuffer);
      if (!format_description) {
        return;
      }

      if (codec_type == kCMVideoCodecType_H264) {
        size_t set_count = 0;
        int header_length = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format_description, 0, nullptr, nullptr, &set_count, &header_length) != noErr) {
          return;
        }

        for (size_t index = 0; index < set_count; ++index) {
          const uint8_t *set_ptr = nullptr;
          size_t set_size = 0;
          if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format_description, index, &set_ptr, &set_size, nullptr, nullptr) == noErr && set_ptr && set_size > 0) {
            output.insert(output.end(), {0, 0, 0, 1});
            output.insert(output.end(), set_ptr, set_ptr + set_size);
          }
        }
      } else if (codec_type == kCMVideoCodecType_HEVC) {
        size_t set_count = 0;
        int header_length = 0;
        if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format_description, 0, nullptr, nullptr, &set_count, &header_length) != noErr) {
          return;
        }

        for (size_t index = 0; index < set_count; ++index) {
          const uint8_t *set_ptr = nullptr;
          size_t set_size = 0;
          if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format_description, index, &set_ptr, &set_size, nullptr, nullptr) == noErr && set_ptr && set_size > 0) {
            output.insert(output.end(), {0, 0, 0, 1});
            output.insert(output.end(), set_ptr, set_ptr + set_size);
          }
        }
      }
    }

    void append_external_sample_buffer_payload(CMSampleBufferRef sampleBuffer, CMVideoCodecType codec_type, std::vector<uint8_t> &output) {
      auto data_buffer = CMSampleBufferGetDataBuffer(sampleBuffer);
      if (!data_buffer) {
        return;
      }

      size_t total_length = 0;
      std::vector<uint8_t> scratch;
      const uint8_t *buffer = copy_or_map_external_sample_bytes(data_buffer, scratch, total_length);
      if (!buffer) {
        return;
      }

      if (codec_type != kCMVideoCodecType_H264 && codec_type != kCMVideoCodecType_HEVC) {
        output.insert(output.end(), buffer, buffer + total_length);
        return;
      }

      output.reserve(output.size() + total_length + (total_length / 32) + 16);
      size_t offset = 0;
      while (offset + 4 <= total_length) {
        uint32_t nal_length =
          (uint32_t(buffer[offset]) << 24) |
          (uint32_t(buffer[offset + 1]) << 16) |
          (uint32_t(buffer[offset + 2]) << 8) |
          uint32_t(buffer[offset + 3]);
        offset += 4;
        if (offset + nal_length > total_length) {
          break;
        }
        output.insert(output.end(), {0, 0, 0, 1});
        output.insert(output.end(), buffer + offset, buffer + offset + nal_length);
        offset += nal_length;
      }
    }

    struct external_hevc_hdr_static_metadata_presence_t {
      bool has_mastering_display_color_volume;
      bool has_content_light_level_info;

      [[nodiscard]] bool is_complete() const {
        return has_mastering_display_color_volume && has_content_light_level_info;
      }
    };

    int external_hevc_nal_unit_header_length(CMSampleBufferRef sample_buffer) {
      const auto format_description = CMSampleBufferGetFormatDescription(sample_buffer);
      if (!format_description) {
        return 4;
      }

      size_t parameter_set_count = 0;
      int nal_unit_header_length = 0;
      const auto status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        format_description,
        0,
        nullptr,
        nullptr,
        &parameter_set_count,
        &nal_unit_header_length
      );
      if (status != noErr || parameter_set_count == 0 || nal_unit_header_length <= 0) {
        return 4;
      }

      return nal_unit_header_length;
    }

    external_hevc_hdr_static_metadata_presence_t parse_external_hevc_sei_presence(
      const uint8_t *nal_unit,
      size_t nal_unit_length
    ) {
      if (!nal_unit || nal_unit_length <= 2) {
        return {false, false};
      }

      std::vector<uint8_t> rbsp;
      rbsp.reserve(nal_unit_length - 2);
      int consecutive_zero_count = 0;
      for (size_t index = 2; index < nal_unit_length; ++index) {
        const auto byte = nal_unit[index];
        if (consecutive_zero_count >= 2 && byte == 0x03) {
          consecutive_zero_count = 0;
          continue;
        }

        rbsp.push_back(byte);
        consecutive_zero_count = byte == 0x00 ? consecutive_zero_count + 1 : 0;
      }

      external_hevc_hdr_static_metadata_presence_t presence {
        .has_mastering_display_color_volume = false,
        .has_content_light_level_info = false,
      };

      size_t offset = 0;
      while (offset < rbsp.size()) {
        if (offset == rbsp.size() - 1 && rbsp[offset] == 0x80) {
          break;
        }

        uint32_t payload_type = 0;
        while (offset < rbsp.size()) {
          const auto value = rbsp[offset++];
          payload_type += value;
          if (value != 0xFF) {
            break;
          }
        }

        uint32_t payload_size = 0;
        while (offset < rbsp.size()) {
          const auto value = rbsp[offset++];
          payload_size += value;
          if (value != 0xFF) {
            break;
          }
        }

        if (offset + payload_size > rbsp.size()) {
          break;
        }

        if (payload_type == 137) {
          presence.has_mastering_display_color_volume = true;
        } else if (payload_type == 144) {
          presence.has_content_light_level_info = true;
        }

        if (presence.is_complete()) {
          break;
        }

        offset += payload_size;
      }

      return presence;
    }

    external_hevc_hdr_static_metadata_presence_t external_hevc_payload_static_metadata_presence(CMSampleBufferRef sample_buffer) {
      auto data_buffer = CMSampleBufferGetDataBuffer(sample_buffer);
      if (!data_buffer) {
        return {false, false};
      }

      size_t total_length = 0;
      std::vector<uint8_t> scratch;
      const uint8_t *buffer = copy_or_map_external_sample_bytes(data_buffer, scratch, total_length);
      if (!buffer) {
        return {false, false};
      }

      const auto nal_unit_header_length = std::clamp(external_hevc_nal_unit_header_length(sample_buffer), 1, 4);
      external_hevc_hdr_static_metadata_presence_t presence {
        .has_mastering_display_color_volume = false,
        .has_content_light_level_info = false,
      };

      size_t offset = 0;
      while (offset + static_cast<size_t>(nal_unit_header_length) <= total_length) {
        size_t nal_unit_length = 0;
        for (int byte_index = 0; byte_index < nal_unit_header_length; ++byte_index) {
          nal_unit_length = (nal_unit_length << 8) | buffer[offset + static_cast<size_t>(byte_index)];
        }
        offset += static_cast<size_t>(nal_unit_header_length);
        if (nal_unit_length == 0 || offset + nal_unit_length > total_length) {
          break;
        }

        const auto nal_unit_type = static_cast<int>((buffer[offset] >> 1) & 0x3F);
        if (nal_unit_type == 39 || nal_unit_type == 40) {
          const auto sei_presence = parse_external_hevc_sei_presence(buffer + offset, nal_unit_length);
          presence.has_mastering_display_color_volume =
            presence.has_mastering_display_color_volume || sei_presence.has_mastering_display_color_volume;
          presence.has_content_light_level_info =
            presence.has_content_light_level_info || sei_presence.has_content_light_level_info;
          if (presence.is_complete()) {
            break;
          }
        }

        offset += nal_unit_length;
      }

      return presence;
    }

    external_hevc_hdr_static_metadata_presence_t external_hevc_annexb_static_metadata_presence(
      const std::vector<uint8_t> &payload
    ) {
      external_hevc_hdr_static_metadata_presence_t presence {
        .has_mastering_display_color_volume = false,
        .has_content_light_level_info = false,
      };

      const auto find_start_code = [&](size_t search_offset) -> std::optional<std::pair<size_t, size_t>> {
        for (size_t index = search_offset; index + 3 < payload.size(); ++index) {
          if (payload[index] == 0x00 && payload[index + 1] == 0x00) {
            if (payload[index + 2] == 0x01) {
              return std::pair<size_t, size_t> {index, 3};
            }
            if (index + 4 < payload.size() && payload[index + 2] == 0x00 && payload[index + 3] == 0x01) {
              return std::pair<size_t, size_t> {index, 4};
            }
          }
        }
        return std::nullopt;
      };

      size_t offset = 0;
      while (true) {
        const auto start_code = find_start_code(offset);
        if (!start_code.has_value()) {
          break;
        }

        const auto nal_offset = start_code->first + start_code->second;
        const auto next_start_code = find_start_code(nal_offset);
        const auto nal_end = next_start_code.has_value() ? next_start_code->first : payload.size();
        if (nal_offset >= nal_end || nal_offset >= payload.size()) {
          break;
        }

        const auto nal_unit_type = static_cast<int>((payload[nal_offset] >> 1) & 0x3F);
        if (nal_unit_type == 39 || nal_unit_type == 40) {
          const auto sei_presence = parse_external_hevc_sei_presence(payload.data() + nal_offset, nal_end - nal_offset);
          presence.has_mastering_display_color_volume =
            presence.has_mastering_display_color_volume || sei_presence.has_mastering_display_color_volume;
          presence.has_content_light_level_info =
            presence.has_content_light_level_info || sei_presence.has_content_light_level_info;
          if (presence.is_complete()) {
            break;
          }
        }

        offset = nal_end;
      }

      return presence;
    }

    bool external_hdr_static_metadata_is_valid(const SS_HDR_METADATA &metadata) {
      return metadata.displayPrimaries[0].x != 0 &&
             metadata.displayPrimaries[1].x != 0 &&
             metadata.displayPrimaries[2].x != 0 &&
             metadata.whitePoint.x != 0 &&
             metadata.maxDisplayLuminance != 0;
    }

    void append_sei_payload_header(std::vector<uint8_t> &rbsp, uint32_t payload_type, uint32_t payload_size) {
      while (payload_type >= 0xFF) {
        rbsp.push_back(0xFF);
        payload_type -= 0xFF;
      }
      rbsp.push_back(static_cast<uint8_t>(payload_type));

      while (payload_size >= 0xFF) {
        rbsp.push_back(0xFF);
        payload_size -= 0xFF;
      }
      rbsp.push_back(static_cast<uint8_t>(payload_size));
    }

    void append_rbsp_with_emulation_prevention(const std::vector<uint8_t> &rbsp, std::vector<uint8_t> &output) {
      int zero_count = 0;
      for (const auto byte : rbsp) {
        if (zero_count >= 2 && byte <= 0x03) {
          output.push_back(0x03);
          zero_count = 0;
        }

        output.push_back(byte);
        zero_count = byte == 0x00 ? zero_count + 1 : 0;
      }
    }

    std::vector<uint8_t> make_external_hevc_hdr_static_metadata_sei(
      const SS_HDR_METADATA &metadata,
      bool include_mastering_display_color_volume,
      bool include_content_light_level_info
    ) {
      if (!external_hdr_static_metadata_is_valid(metadata) ||
          (!include_mastering_display_color_volume && !include_content_light_level_info)) {
        return {};
      }

      constexpr uint8_t mastering_display_payload_type = 137;
      constexpr uint8_t content_light_payload_type = 144;
      constexpr uint8_t hevc_prefix_sei_header_bytes[] = {0x4E, 0x01};

      const auto write_be16 = [](uint8_t *dst, uint16_t value) {
        dst[0] = static_cast<uint8_t>((value >> 8) & 0xFF);
        dst[1] = static_cast<uint8_t>(value & 0xFF);
      };
      const auto write_be32 = [](uint8_t *dst, uint32_t value) {
        dst[0] = static_cast<uint8_t>((value >> 24) & 0xFF);
        dst[1] = static_cast<uint8_t>((value >> 16) & 0xFF);
        dst[2] = static_cast<uint8_t>((value >> 8) & 0xFF);
        dst[3] = static_cast<uint8_t>(value & 0xFF);
      };

      std::vector<uint8_t> rbsp;
      rbsp.reserve(48);

      if (include_mastering_display_color_volume) {
        std::array<uint8_t, 24> mastering_display_payload {};
        write_be16(mastering_display_payload.data() + 0, static_cast<uint16_t>(metadata.displayPrimaries[0].x));
        write_be16(mastering_display_payload.data() + 2, static_cast<uint16_t>(metadata.displayPrimaries[0].y));
        write_be16(mastering_display_payload.data() + 4, static_cast<uint16_t>(metadata.displayPrimaries[1].x));
        write_be16(mastering_display_payload.data() + 6, static_cast<uint16_t>(metadata.displayPrimaries[1].y));
        write_be16(mastering_display_payload.data() + 8, static_cast<uint16_t>(metadata.displayPrimaries[2].x));
        write_be16(mastering_display_payload.data() + 10, static_cast<uint16_t>(metadata.displayPrimaries[2].y));
        write_be16(mastering_display_payload.data() + 12, static_cast<uint16_t>(metadata.whitePoint.x));
        write_be16(mastering_display_payload.data() + 14, static_cast<uint16_t>(metadata.whitePoint.y));
        write_be32(mastering_display_payload.data() + 16, metadata.maxDisplayLuminance);
        write_be32(mastering_display_payload.data() + 20, metadata.minDisplayLuminance);
        append_sei_payload_header(rbsp, mastering_display_payload_type, mastering_display_payload.size());
        rbsp.insert(rbsp.end(), mastering_display_payload.begin(), mastering_display_payload.end());
      }

      if (include_content_light_level_info &&
          (metadata.maxContentLightLevel != 0 || metadata.maxFrameAverageLightLevel != 0)) {
        std::array<uint8_t, 4> content_light_payload {};
        write_be16(content_light_payload.data() + 0, static_cast<uint16_t>(metadata.maxContentLightLevel));
        write_be16(content_light_payload.data() + 2, static_cast<uint16_t>(metadata.maxFrameAverageLightLevel));
        append_sei_payload_header(rbsp, content_light_payload_type, content_light_payload.size());
        rbsp.insert(rbsp.end(), content_light_payload.begin(), content_light_payload.end());
      }

      rbsp.push_back(0x80);  // rbsp_trailing_bits()

      std::vector<uint8_t> nal_unit;
      nal_unit.reserve(4 + sizeof(hevc_prefix_sei_header_bytes) + rbsp.size() + 8);
      nal_unit.insert(nal_unit.end(), {0, 0, 0, 1});
      nal_unit.insert(nal_unit.end(), std::begin(hevc_prefix_sei_header_bytes), std::end(hevc_prefix_sei_header_bytes));
      append_rbsp_with_emulation_prevention(rbsp, nal_unit);
      return nal_unit;
    }

    bool append_external_hdr_static_metadata_if_needed(
      CMSampleBufferRef sample_buffer,
      CMVideoCodecType codec_type,
      const SS_HDR_METADATA &metadata,
      bool hdr_signaled,
      std::vector<uint8_t> &output
    ) {
      if (!hdr_signaled || codec_type != kCMVideoCodecType_HEVC) {
        return false;
      }

      const bool extension_has_mastering_display =
        lumen_core_sample_buffer_extension_present(sample_buffer, kCMFormatDescriptionExtension_MasteringDisplayColorVolume);
      const bool extension_has_content_light =
        lumen_core_sample_buffer_extension_present(sample_buffer, kCMFormatDescriptionExtension_ContentLightLevelInfo);
      const auto payload_presence = external_hevc_payload_static_metadata_presence(sample_buffer);
      if (payload_presence.is_complete()) {
        return false;
      }

      auto sei = make_external_hevc_hdr_static_metadata_sei(
        metadata,
        !payload_presence.has_mastering_display_color_volume,
        !payload_presence.has_content_light_level_info
      );
      if (sei.empty()) {
        return false;
      }

      output.insert(output.end(), sei.begin(), sei.end());
      BOOST_LOG(info) << "External macOS encoded ingress repaired HEVC HDR static metadata"
                      << " extension-mastering="sv << extension_has_mastering_display
                      << " extension-cll="sv << extension_has_content_light
                      << " payload-mastering="sv << payload_presence.has_mastering_display_color_volume
                      << " payload-cll="sv << payload_presence.has_content_light_level_info;
      return true;
    }
  }  // namespace
#endif

  namespace nv {

    enum class profile_h264_e : int {
      high = 2,  ///< High profile
      high_444p = 3,  ///< High 4:4:4 Predictive profile
    };

    enum class profile_hevc_e : int {
      main = 0,  ///< Main profile
      main_10 = 1,  ///< Main 10 profile
      rext = 2,  ///< Rext profile
    };

  }  // namespace nv

  namespace qsv {

    enum class profile_h264_e : int {
      high = 100,  ///< High profile
      high_444p = 244,  ///< High 4:4:4 Predictive profile
    };

    enum class profile_hevc_e : int {
      main = 1,  ///< Main profile
      main_10 = 2,  ///< Main 10 profile
      rext = 4,  ///< RExt profile
    };

    enum class profile_av1_e : int {
      main = 1,  ///< Main profile
      high = 2,  ///< High profile
    };

  }  // namespace qsv

  util::Either<avcodec_buffer_t, int> dxgi_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *);
  util::Either<avcodec_buffer_t, int> vaapi_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *);
  util::Either<avcodec_buffer_t, int> cuda_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *);
  util::Either<avcodec_buffer_t, int> vt_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *);

  class avcodec_software_encode_device_t: public platf::avcodec_encode_device_t {
  public:
    int convert(platf::img_t &img) override {
      // If we need to add aspect ratio padding, we need to scale into an intermediate output buffer
      bool requires_padding = (sw_frame->width != sws_output_frame->width || sw_frame->height != sws_output_frame->height);

      // Setup the input frame using the caller's img_t
      sws_input_frame->data[0] = img.data;
      sws_input_frame->linesize[0] = img.row_pitch;

      // Perform color conversion and scaling to the final size
      auto status = sws_scale_frame(sws.get(), requires_padding ? sws_output_frame.get() : sw_frame.get(), sws_input_frame.get());
      if (status < 0) {
        char string[AV_ERROR_MAX_STRING_SIZE];
        BOOST_LOG(error) << "Couldn't scale frame: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
        return -1;
      }

      // If we require aspect ratio padding, copy the output frame into the final padded frame
      if (requires_padding) {
        auto fmt_desc = av_pix_fmt_desc_get((AVPixelFormat) sws_output_frame->format);
        auto planes = av_pix_fmt_count_planes((AVPixelFormat) sws_output_frame->format);
        for (int plane = 0; plane < planes; plane++) {
          auto shift_h = plane == 0 ? 0 : fmt_desc->log2_chroma_h;
          auto shift_w = plane == 0 ? 0 : fmt_desc->log2_chroma_w;
          auto offset = ((offsetW >> shift_w) * fmt_desc->comp[plane].step) + (offsetH >> shift_h) * sw_frame->linesize[plane];

          // Copy line-by-line to preserve leading padding for each row
          for (int line = 0; line < sws_output_frame->height >> shift_h; line++) {
            memcpy(sw_frame->data[plane] + offset + (line * sw_frame->linesize[plane]), sws_output_frame->data[plane] + (line * sws_output_frame->linesize[plane]), (size_t) (sws_output_frame->width >> shift_w) * fmt_desc->comp[plane].step);
          }
        }
      }

      // If frame is not a software frame, it means we still need to transfer from main memory
      // to vram memory
      if (frame->hw_frames_ctx) {
        auto status = av_hwframe_transfer_data(frame, sw_frame.get(), 0);
        if (status < 0) {
          char string[AV_ERROR_MAX_STRING_SIZE];
          BOOST_LOG(error) << "Failed to transfer image data to hardware frame: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
          return -1;
        }
      }

      return 0;
    }

    int set_frame(AVFrame *frame, AVBufferRef *hw_frames_ctx) override {
      this->frame = frame;

      // If it's a hwframe, allocate buffers for hardware
      if (hw_frames_ctx) {
        hw_frame.reset(frame);

        if (av_hwframe_get_buffer(hw_frames_ctx, frame, 0)) {
          return -1;
        }
      } else {
        sw_frame.reset(frame);
      }

      return 0;
    }

    void apply_colorspace() override {
      auto avcodec_colorspace = avcodec_colorspace_from_stream_colorspace(colorspace);
      sws_setColorspaceDetails(sws.get(), sws_getCoefficients(SWS_CS_DEFAULT), 0, sws_getCoefficients(avcodec_colorspace.software_format), avcodec_colorspace.range - 1, 0, 1 << 16, 1 << 16);
    }

    /**
     * When preserving aspect ratio, ensure that padding is black
     */
    void prefill() {
      auto frame = sw_frame ? sw_frame.get() : this->frame;
      av_frame_get_buffer(frame, 0);
      av_frame_make_writable(frame);
      ptrdiff_t linesize[4] = {frame->linesize[0], frame->linesize[1], frame->linesize[2], frame->linesize[3]};
      av_image_fill_black(frame->data, linesize, (AVPixelFormat) frame->format, frame->color_range, frame->width, frame->height);
    }

    int init(int in_width, int in_height, AVFrame *frame, AVPixelFormat format, bool hardware) {
      // If the device used is hardware, yet the image resides on main memory
      if (hardware) {
        sw_frame.reset(av_frame_alloc());

        sw_frame->width = frame->width;
        sw_frame->height = frame->height;
        sw_frame->format = format;
      } else {
        this->frame = frame;
      }

      // Fill aspect ratio padding in the destination frame
      prefill();

      auto out_width = frame->width;
      auto out_height = frame->height;

      // Ensure aspect ratio is maintained
      auto scalar = std::fminf((float) out_width / in_width, (float) out_height / in_height);
      out_width = in_width * scalar;
      out_height = in_height * scalar;

      sws_input_frame.reset(av_frame_alloc());
      sws_input_frame->width = in_width;
      sws_input_frame->height = in_height;
      sws_input_frame->format = AV_PIX_FMT_BGR0;

      sws_output_frame.reset(av_frame_alloc());
      sws_output_frame->width = out_width;
      sws_output_frame->height = out_height;
      sws_output_frame->format = format;

      // Result is always positive
      offsetW = (frame->width - out_width) / 2;
      offsetH = (frame->height - out_height) / 2;

      sws.reset(sws_alloc_context());
      if (!sws) {
        return -1;
      }

      AVDictionary *options {nullptr};
      av_dict_set_int(&options, "srcw", sws_input_frame->width, 0);
      av_dict_set_int(&options, "srch", sws_input_frame->height, 0);
      av_dict_set_int(&options, "src_format", sws_input_frame->format, 0);
      av_dict_set_int(&options, "dstw", sws_output_frame->width, 0);
      av_dict_set_int(&options, "dsth", sws_output_frame->height, 0);
      av_dict_set_int(&options, "dst_format", sws_output_frame->format, 0);
      av_dict_set_int(&options, "sws_flags", SWS_LANCZOS | SWS_ACCURATE_RND, 0);
      av_dict_set_int(&options, "threads", config::video.min_threads, 0);

      auto status = av_opt_set_dict(sws.get(), &options);
      av_dict_free(&options);
      if (status < 0) {
        char string[AV_ERROR_MAX_STRING_SIZE];
        BOOST_LOG(error) << "Failed to set SWS options: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
        return -1;
      }

      status = sws_init_context(sws.get(), nullptr, nullptr);
      if (status < 0) {
        char string[AV_ERROR_MAX_STRING_SIZE];
        BOOST_LOG(error) << "Failed to initialize SWS: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
        return -1;
      }

      return 0;
    }

    // Store ownership when frame is hw_frame
    avcodec_frame_t hw_frame;

    avcodec_frame_t sw_frame;
    avcodec_frame_t sws_input_frame;
    avcodec_frame_t sws_output_frame;
    sws_t sws;

    // Offset of input image to output frame in pixels
    int offsetW;
    int offsetH;
  };

  enum flag_e : uint32_t {
    DEFAULT = 0,  ///< Default flags
    PARALLEL_ENCODING = 1 << 1,  ///< Capture and encoding can run concurrently on separate threads
    H264_ONLY = 1 << 2,  ///< When HEVC is too heavy
    LIMITED_GOP_SIZE = 1 << 3,  ///< Some encoders don't like it when you have an infinite GOP_SIZE. e.g. VAAPI
    SINGLE_SLICE_ONLY = 1 << 4,  ///< Never use multiple slices. Older intel iGPU's ruin it for everyone else
    CBR_WITH_VBR = 1 << 5,  ///< Use a VBR rate control mode to simulate CBR
    RELAXED_COMPLIANCE = 1 << 6,  ///< Use FF_COMPLIANCE_UNOFFICIAL compliance mode
    NO_RC_BUF_LIMIT = 1 << 7,  ///< Don't set rc_buffer_size
    REF_FRAMES_INVALIDATION = 1 << 8,  ///< Support reference frames invalidation
    ALWAYS_REPROBE = 1 << 9,  ///< This is an encoder of last resort and we want to aggressively probe for a better one
    YUV444_SUPPORT = 1 << 10,  ///< Encoder may support 4:4:4 chroma sampling depending on hardware
    ASYNC_TEARDOWN = 1 << 11,  ///< Encoder supports async teardown on a different thread
  };

  class avcodec_encode_session_t: public encode_session_t {
  public:
    avcodec_encode_session_t() = default;

    avcodec_encode_session_t(avcodec_ctx_t &&avcodec_ctx, std::unique_ptr<platf::avcodec_encode_device_t> encode_device, int inject, bool skip_flush = false):
        avcodec_ctx {std::move(avcodec_ctx)},
        device {std::move(encode_device)},
        inject {inject},
        skip_flush {skip_flush} {
    }

    avcodec_encode_session_t(avcodec_encode_session_t &&other) noexcept = default;

    ~avcodec_encode_session_t() {
      // Flush any remaining frames in the encoder
      if (!skip_flush && avcodec_send_frame(avcodec_ctx.get(), nullptr) == 0) {
        packet_raw_avcodec pkt;
        while (avcodec_receive_packet(avcodec_ctx.get(), pkt.av_packet) == 0);
      }

      // Order matters here because the context relies on the hwdevice still being valid
      avcodec_ctx.reset();
      device.reset();
    }

    // Ensure objects are destroyed in the correct order
    avcodec_encode_session_t &operator=(avcodec_encode_session_t &&other) {
      device = std::move(other.device);
      avcodec_ctx = std::move(other.avcodec_ctx);
      replacements = std::move(other.replacements);
      sps = std::move(other.sps);
      vps = std::move(other.vps);

      inject = other.inject;
      skip_flush = other.skip_flush;

      return *this;
    }

    int convert(platf::img_t &img) override {
      if (!device) {
        return -1;
      }
      return device->convert(img);
    }

    void request_idr_frame() override {
      if (device && device->frame) {
        auto &frame = device->frame;
        frame->pict_type = AV_PICTURE_TYPE_I;
        frame->flags |= AV_FRAME_FLAG_KEY;
      }
    }

    void request_normal_frame() override {
      if (device && device->frame) {
        auto &frame = device->frame;
        frame->pict_type = AV_PICTURE_TYPE_NONE;
        frame->flags &= ~AV_FRAME_FLAG_KEY;
      }
    }

    void invalidate_ref_frames(int64_t first_frame, int64_t last_frame) override {
      BOOST_LOG(error) << "Encoder doesn't support reference frame invalidation";
      request_idr_frame();
    }

    avcodec_ctx_t avcodec_ctx;
    std::unique_ptr<platf::avcodec_encode_device_t> device;

    std::vector<packet_raw_t::replace_t> replacements;

    cbs::nal_t sps;
    cbs::nal_t vps;

    // inject sps/vps data into idr pictures
    int inject;
    bool skip_flush = false;
  };

  class nvenc_encode_session_t: public encode_session_t {
  public:
    nvenc_encode_session_t(std::unique_ptr<platf::nvenc_encode_device_t> encode_device):
        device(std::move(encode_device)) {
    }

    int convert(platf::img_t &img) override {
      if (!device) {
        return -1;
      }
      return device->convert(img);
    }

    void request_idr_frame() override {
      force_idr = true;
    }

    void request_normal_frame() override {
      force_idr = false;
    }

    void invalidate_ref_frames(int64_t first_frame, int64_t last_frame) override {
      if (!device || !device->nvenc) {
        return;
      }

      if (!device->nvenc->invalidate_ref_frames(first_frame, last_frame)) {
        force_idr = true;
      }
    }

    nvenc::nvenc_encoded_frame encode_frame(uint64_t frame_index) {
      if (!device || !device->nvenc) {
        return {};
      }

      auto result = device->nvenc->encode_frame(frame_index, force_idr);
      force_idr = false;
      return result;
    }

  private:
    std::unique_ptr<platf::nvenc_encode_device_t> device;
    bool force_idr = false;
  };

#ifdef __APPLE__
  namespace {
    void native_macos_vt_probe_callback(
      void *outputCallbackRefCon,
      void *sourceFrameRefCon,
      OSStatus status,
      VTEncodeInfoFlags infoFlags,
      CMSampleBufferRef sampleBuffer
    ) {
      (void) outputCallbackRefCon;
      (void) sourceFrameRefCon;
      (void) status;
      (void) infoFlags;
      (void) sampleBuffer;
    }

    CMVideoCodecType native_macos_vt_codec_type_for_video_format(int video_format) {
      switch (video_format) {
        case 0:
          return kCMVideoCodecType_H264;
        case 1:
          return kCMVideoCodecType_HEVC;
        case 2:
          return kCMVideoCodecType_AV1;
        default:
          return 0;
      }
    }

    bool native_macos_vt_codec_session_creatable(CMVideoCodecType codec_type, int width = 1920, int height = 1080) {
      VTCompressionSessionRef session = nullptr;
      auto status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        width,
        height,
        codec_type,
        nullptr,
        nullptr,
        nullptr,
        native_macos_vt_probe_callback,
        nullptr,
        &session
      );
      if (session != nullptr) {
        VTCompressionSessionInvalidate(session);
        CFRelease(session);
      }
      return status == noErr;
    }

    bool native_macos_vt_codec_supported(CMVideoCodecType codec_type, int width = 1920, int height = 1080) {
      if (codec_type == 0) {
        return false;
      }

      CFDictionaryRef supported_properties = nullptr;
      auto status = VTCopySupportedPropertyDictionaryForEncoder(
        width,
        height,
        codec_type,
        nullptr,
        nullptr,
        &supported_properties
      );
      if (supported_properties != nullptr) {
        CFRelease(supported_properties);
      }
      if (status == noErr) {
        return true;
      }

      return native_macos_vt_codec_session_creatable(codec_type, width, height);
    }

    std::size_t native_macos_vt_max_inflight_frames_for_framerate(int framerate) {
      if (framerate >= 120) {
        return 1;
      }
      if (framerate >= 90) {
        return 2;
      }
      if (framerate >= 60) {
        return 3;
      }
      return 4;
    }
  }  // namespace

  bool native_macos_vt_hevc_main10_supported() {
    return native_macos_vt_codec_supported(kCMVideoCodecType_HEVC);
  }

  bool native_macos_vt_av1_supported() {
    return native_macos_vt_codec_supported(kCMVideoCodecType_AV1);
  }

  class vt_compression_encode_session_t: public encode_session_t {
  public:
    struct hdr_metadata_state_t {
      bool valid {false};
      SS_HDR_METADATA metadata {};
    };

    vt_compression_encode_session_t(
      std::unique_ptr<platf::avcodec_encode_device_t> encode_device,
      CMVideoCodecType codec_type,
      int width,
      int height,
      int bitrate,
      int framerate,
      bool ten_bit,
      video::dynamic_range_transport_e dynamic_range_transport,
      video::stream_colorspace_t colorspace,
      hdr_metadata_state_t hdr_metadata_state
    ):
        device(std::move(encode_device)),
        codec_type(codec_type),
        width(width),
        height(height),
        bitrate(bitrate),
        framerate(framerate),
        ten_bit(ten_bit),
        dynamic_range_transport(dynamic_range_transport),
        colorspace(colorspace),
        hdr_metadata_state(std::move(hdr_metadata_state)) {
    }

    ~vt_compression_encode_session_t() override {
      if (compression_session) {
        if (inflight_frames == 0) {
          VTCompressionSessionCompleteFrames(compression_session, kCMTimeInvalid);
        } else {
          BOOST_LOG(info) << "Skipping VTCompressionSessionCompleteFrames during teardown with "sv
                          << inflight_frames
                          << " frames still in flight"sv;
        }
        VTCompressionSessionInvalidate(compression_session);
        CFRelease(compression_session);
      }
      if (current_pixel_buffer_ref) {
        current_pixel_buffer_ref.reset();
      }
    }

    int init() {
      cf_dict_t encoder_specification = make_encoder_specification();
      cf_dict_t source_attrs = make_source_image_buffer_attributes();

      auto status = VTCompressionSessionCreate(
        nullptr,
        width,
        height,
        codec_type,
        encoder_specification.get(),
        source_attrs.get(),
        nullptr,
        &vt_compression_encode_session_t::compression_output_callback,
        this,
        &compression_session
      );
      if (status != noErr) {
        BOOST_LOG(error) << "VTCompressionSessionCreate failed: "sv << status;
        return -1;
      }

      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_ProgressiveScan, kCFBooleanTrue);
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse);
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse);
      auto max_frame_delay_count = cfnumber_from_int(1);
      if (max_frame_delay_count) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_MaxFrameDelayCount, max_frame_delay_count.get());
      }
      if (auto expected_duration = cfnumber_from_double(1.0 / std::max(framerate, 1))) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_ExpectedDuration, expected_duration.get());
      }

      auto expected_framerate = cfnumber_from_int(framerate);
      if (expected_framerate) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_ExpectedFrameRate, expected_framerate.get());
      }

      auto average_bitrate = cfnumber_from_int(bitrate);
      if (average_bitrate) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_AverageBitRate, average_bitrate.get());
      }
      auto data_rate_limit = cfarray_from_ints({bitrate * 2 / 8, 1});
      if (data_rate_limit) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_DataRateLimits, data_rate_limit.get());
      }
      auto max_keyframe_interval = cfnumber_from_int(std::numeric_limits<int>::max());
      if (max_keyframe_interval) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, max_keyframe_interval.get());
      }

      apply_color_properties();
      apply_hdr_properties();

      if (codec_type == kCMVideoCodecType_H264) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
      } else if (codec_type == kCMVideoCodecType_HEVC) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_ProfileLevel, ten_bit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel);
      }

      status = VTCompressionSessionPrepareToEncodeFrames(compression_session);
      if (status != noErr) {
        BOOST_LOG(error) << "VTCompressionSessionPrepareToEncodeFrames failed: "sv << status;
        return -1;
      }

      return 0;
    }

    int convert(platf::img_t &img) override {
      auto *av_img = dynamic_cast<platf::av_img_t *>(&img);
      if (!av_img || !av_img->pixel_buffer_ref || !av_img->pixel_buffer_ref->buf) {
        return -1;
      }

      current_pixel_buffer_ref = av_img->pixel_buffer_ref;
      return 0;
    }

    void request_idr_frame() override {
      force_idr = true;
    }

    void request_normal_frame() override {
      force_idr = false;
    }

    void invalidate_ref_frames(int64_t first_frame, int64_t last_frame) override {
      force_idr = true;
    }

    int encode_frame(int64_t frame_nr, safe::mail_raw_t::queue_t<packet_t> &packets, void *channel_data, std::optional<std::chrono::steady_clock::time_point> frame_timestamp) {
      if (!compression_session || !current_pixel_buffer_ref || !current_pixel_buffer_ref->buf) {
        return -1;
      }
      if (fatal_error.load(std::memory_order_acquire)) {
        BOOST_LOG(error) << "Native VT session is in a failed state"sv;
        return -1;
      }
      {
        std::unique_lock<std::mutex> lock(inflight_mutex);
        inflight_cv.wait(lock, [&] {
          return inflight_frames < max_inflight_frames || fatal_error.load(std::memory_order_acquire);
        });
      }
      if (fatal_error.load(std::memory_order_acquire)) {
        BOOST_LOG(error) << "Native VT session entered failed state while throttling in-flight frames"sv;
        return -1;
      }

      auto *frame_context = new vt_frame_context_t {
        packets,
        channel_data,
        frame_timestamp,
        frame_nr,
        negotiated_optional_hdr_frame_state(
          dynamic_range_transport,
          width,
          height,
          video::colorspace_is_hdr(colorspace),
          hdr_metadata_state.valid ? &hdr_metadata_state.metadata : nullptr
        ),
        current_pixel_buffer_ref,
      };

      cf_dict_t frame_properties;
      if (force_idr) {
        const void *keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
        const void *values[] = {kCFBooleanTrue};
        frame_properties.reset(CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
      }

      CMTime pts = CMTimeMake(frame_nr, framerate > 0 ? framerate : 60);
      {
        std::lock_guard<std::mutex> lock(inflight_mutex);
        ++inflight_frames;
      }
      const auto submitted_pixel_format = CVPixelBufferGetPixelFormatType(frame_context->pixel_buffer_ref->buf);
      auto status = VTCompressionSessionEncodeFrame(
        compression_session,
        frame_context->pixel_buffer_ref->buf,
        pts,
        kCMTimeInvalid,
        frame_properties.get(),
        frame_context,
        nullptr
      );
      if (status != noErr) {
        release_frame_context(frame_context);
        {
          std::lock_guard<std::mutex> lock(inflight_mutex);
          --inflight_frames;
        }
        inflight_cv.notify_one();
        BOOST_LOG(error) << "VTCompressionSessionEncodeFrame failed: "sv << status;
        return -1;
      }

      auto submitted = submitted_frames.fetch_add(1, std::memory_order_relaxed) + 1;
      if (submitted <= 5 || submitted % 120 == 0) {
        BOOST_LOG(info) << "Native VT submitted frame #"sv << submitted
                        << " index="sv << frame_nr
                        << " pixelFormat="sv << submitted_pixel_format;
      }

      force_idr = false;
      return 0;
    }

  private:
    struct vt_frame_context_t {
      safe::mail_raw_t::queue_t<packet_t> packets;
      void *channel_data;
      std::optional<std::chrono::steady_clock::time_point> frame_timestamp;
      int64_t frame_index;
      std::optional<video::hdr_frame_state_t> hdr_frame_state;
      std::shared_ptr<platf::av_pixel_ref_t> pixel_buffer_ref;
    };

    struct cfnumber_deleter {
      void operator()(CFNumberRef value) const {
        if (value) {
          CFRelease(value);
        }
      }
    };

    struct cf_releaser {
      template<class T>
      void operator()(T value) const {
        if (value) {
          CFRelease(value);
        }
      }
    };

    using cfnumber_t = std::unique_ptr<std::remove_pointer_t<CFNumberRef>, cfnumber_deleter>;
    using cf_dict_t = std::unique_ptr<std::remove_pointer_t<CFDictionaryRef>, cf_releaser>;
    using cf_array_t = std::unique_ptr<std::remove_pointer_t<CFArrayRef>, cf_releaser>;
    using cf_data_t = std::unique_ptr<std::remove_pointer_t<CFDataRef>, cf_releaser>;

    static cfnumber_t cfnumber_from_int(int value) {
      auto number = CFNumberCreate(nullptr, kCFNumberIntType, &value);
      return cfnumber_t(number);
    }

    static cfnumber_t cfnumber_from_double(double value) {
      auto number = CFNumberCreate(nullptr, kCFNumberDoubleType, &value);
      return cfnumber_t(number);
    }

    static cf_array_t cfarray_from_ints(std::initializer_list<int> values) {
      std::vector<CFNumberRef> numbers;
      numbers.reserve(values.size());
      for (int value : values) {
        numbers.push_back(CFNumberCreate(nullptr, kCFNumberIntType, &value));
      }

      auto array = CFArrayCreate(nullptr, reinterpret_cast<const void **>(numbers.data()), (CFIndex) numbers.size(), &kCFTypeArrayCallBacks);
      for (auto *number : numbers) {
        if (number) {
          CFRelease(number);
        }
      }
      return cf_array_t(array);
    }

    static void write_be16(uint8_t *dst, uint16_t value) {
      dst[0] = (uint8_t) ((value >> 8) & 0xFF);
      dst[1] = (uint8_t) (value & 0xFF);
    }

    static void write_be32(uint8_t *dst, uint32_t value) {
      dst[0] = (uint8_t) ((value >> 24) & 0xFF);
      dst[1] = (uint8_t) ((value >> 16) & 0xFF);
      dst[2] = (uint8_t) ((value >> 8) & 0xFF);
      dst[3] = (uint8_t) (value & 0xFF);
    }

    cf_dict_t make_encoder_specification() const {
      return cf_dict_t(CFDictionaryCreate(nullptr, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    }

    cf_dict_t make_source_image_buffer_attributes() const {
      int pixel_format = ten_bit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      auto pixel_format_number = cfnumber_from_int(pixel_format);
      auto width_number = cfnumber_from_int(width);
      auto height_number = cfnumber_from_int(height);
      const void *surface_keys[] = {};
      const void *surface_values[] = {};
      cf_dict_t empty_surface_dictionary(CFDictionaryCreate(nullptr, surface_keys, surface_values, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

      const void *keys[] = {
        kCVPixelBufferPixelFormatTypeKey,
        kCVPixelBufferWidthKey,
        kCVPixelBufferHeightKey,
        kCVPixelBufferMetalCompatibilityKey,
        kCVPixelBufferIOSurfacePropertiesKey,
      };
      const void *values[] = {
        pixel_format_number.get(),
        width_number.get(),
        height_number.get(),
        kCFBooleanTrue,
        empty_surface_dictionary.get(),
      };
      return cf_dict_t(CFDictionaryCreate(nullptr, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    }

    static CFStringRef color_primaries_for_colorspace(const video::stream_colorspace_t &colorspace) {
      switch (colorspace.colorspace) {
        case video::colorspace_e::rec601:
          return kCVImageBufferColorPrimaries_SMPTE_C;
        case video::colorspace_e::rec709:
          return kCVImageBufferColorPrimaries_ITU_R_709_2;
        case video::colorspace_e::bt2020sdr:
        case video::colorspace_e::bt2020:
          return kCVImageBufferColorPrimaries_ITU_R_2020;
      }
    }

    static CFStringRef transfer_function_for_colorspace(const video::stream_colorspace_t &colorspace) {
      switch (colorspace.colorspace) {
        case video::colorspace_e::rec601:
        case video::colorspace_e::rec709:
          return kCVImageBufferTransferFunction_ITU_R_709_2;
        case video::colorspace_e::bt2020sdr:
          return kCVImageBufferTransferFunction_ITU_R_2020;
        case video::colorspace_e::bt2020:
          return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
      }
    }

    static CFStringRef ycbcr_matrix_for_colorspace(const video::stream_colorspace_t &colorspace) {
      switch (colorspace.colorspace) {
        case video::colorspace_e::rec601:
          return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
        case video::colorspace_e::rec709:
          return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        case video::colorspace_e::bt2020sdr:
        case video::colorspace_e::bt2020:
          return kCVImageBufferYCbCrMatrix_ITU_R_2020;
      }
    }

    void apply_color_properties() const {
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_ColorPrimaries, color_primaries_for_colorspace(colorspace));
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_TransferFunction, transfer_function_for_colorspace(colorspace));
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_YCbCrMatrix, ycbcr_matrix_for_colorspace(colorspace));
    }

    cf_data_t make_mastering_display_color_volume() const {
      if (!hdr_metadata_state.valid) {
        return cf_data_t(nullptr);
      }

      std::array<uint8_t, 24> payload {};
      write_be16(payload.data() + 0, (uint16_t) hdr_metadata_state.metadata.displayPrimaries[0].x);
      write_be16(payload.data() + 2, (uint16_t) hdr_metadata_state.metadata.displayPrimaries[0].y);
      write_be16(payload.data() + 4, (uint16_t) hdr_metadata_state.metadata.displayPrimaries[1].x);
      write_be16(payload.data() + 6, (uint16_t) hdr_metadata_state.metadata.displayPrimaries[1].y);
      write_be16(payload.data() + 8, (uint16_t) hdr_metadata_state.metadata.displayPrimaries[2].x);
      write_be16(payload.data() + 10, (uint16_t) hdr_metadata_state.metadata.displayPrimaries[2].y);
      write_be16(payload.data() + 12, (uint16_t) hdr_metadata_state.metadata.whitePoint.x);
      write_be16(payload.data() + 14, (uint16_t) hdr_metadata_state.metadata.whitePoint.y);
      write_be32(payload.data() + 16, hdr_metadata_state.metadata.maxDisplayLuminance);
      write_be32(payload.data() + 20, hdr_metadata_state.metadata.minDisplayLuminance);
      return cf_data_t(CFDataCreate(nullptr, payload.data(), (CFIndex) payload.size()));
    }

    cf_data_t make_content_light_level_info() const {
      if (!hdr_metadata_state.valid) {
        return cf_data_t(nullptr);
      }

      std::array<uint8_t, 4> payload {};
      write_be16(payload.data() + 0, (uint16_t) hdr_metadata_state.metadata.maxContentLightLevel);
      write_be16(payload.data() + 2, (uint16_t) hdr_metadata_state.metadata.maxFrameAverageLightLevel);
      return cf_data_t(CFDataCreate(nullptr, payload.data(), (CFIndex) payload.size()));
    }

    void apply_hdr_properties() const {
      if (!video::colorspace_is_hdr(colorspace)) {
        return;
      }

      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_Auto);
      VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_PreserveDynamicHDRMetadata, kCFBooleanTrue);

      if (auto mastering_display = make_mastering_display_color_volume()) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_MasteringDisplayColorVolume, mastering_display.get());
      }
      if (auto content_light = make_content_light_level_info()) {
        VTSessionSetProperty(compression_session, kVTCompressionPropertyKey_ContentLightLevelInfo, content_light.get());
      }
    }

    static void release_frame_context(vt_frame_context_t *frame_context) {
      if (!frame_context) {
        return;
      }
      delete frame_context;
    }

    static void compression_output_callback(
      void *outputCallbackRefCon,
      void *sourceFrameRefCon,
      OSStatus status,
      VTEncodeInfoFlags infoFlags,
      CMSampleBufferRef sampleBuffer
    ) {
      static_cast<vt_compression_encode_session_t *>(outputCallbackRefCon)->handle_compression_output(status, infoFlags, static_cast<vt_frame_context_t *>(sourceFrameRefCon), sampleBuffer);
    }

    void handle_compression_output(OSStatus status, VTEncodeInfoFlags infoFlags, vt_frame_context_t *frame_context, CMSampleBufferRef sampleBuffer) {
      auto inflight_guard = util::fail_guard([&] {
        {
          std::lock_guard<std::mutex> lock(inflight_mutex);
          --inflight_frames;
        }
        inflight_cv.notify_one();
        release_frame_context(frame_context);
      });

      if (status != noErr) {
        fatal_error.store(true, std::memory_order_release);
        BOOST_LOG(error) << "Native VT callback failed: "sv << status;
        return;
      }

      if (!sampleBuffer) {
        if (infoFlags & kVTEncodeInfo_FrameDropped) {
          auto dropped = dropped_frames.fetch_add(1, std::memory_order_relaxed) + 1;
          if (dropped <= 5 || dropped % 120 == 0) {
            BOOST_LOG(warning) << "Native VT dropped frame #"sv << dropped << " frame_index="sv << frame_context->frame_index << " infoFlags="sv << infoFlags;
          }
          return;
        }
        BOOST_LOG(error) << "Native VT callback produced no sample buffer"sv;
        return;
      }

      if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        auto make_ready_status = CMSampleBufferMakeDataReady(sampleBuffer);
        if (make_ready_status != noErr || !CMSampleBufferDataIsReady(sampleBuffer)) {
          BOOST_LOG(error) << "Native VT callback produced no ready sample buffer"
                           << " infoFlags="sv << infoFlags
                           << " makeReadyStatus="sv << make_ready_status;
          return;
        }
      }

      std::vector<uint8_t> packet_data;
      const bool packet_is_idr = sample_buffer_is_idr(sampleBuffer);
      if (packet_is_idr) {
        append_parameter_sets(sampleBuffer, packet_data);
      }
      append_sample_buffer_payload(sampleBuffer, packet_data);
      if (packet_data.empty()) {
        BOOST_LOG(error) << "Native VT callback produced empty payload"sv;
        return;
      }

      auto packet = std::make_unique<packet_raw_generic>(std::move(packet_data), frame_context->frame_index, packet_is_idr);
      packet->channel_data = frame_context->channel_data;
      packet->frame_timestamp = frame_context->frame_timestamp;
      packet->hdr_frame_state = frame_context->hdr_frame_state;
      frame_context->packets->raise(std::move(packet));

      auto emitted = emitted_packets.fetch_add(1, std::memory_order_relaxed) + 1;
      if (emitted <= 5 || emitted % 120 == 0) {
        BOOST_LOG(info) << "Native VT emitted packet #"sv << emitted << " frame_index="sv << frame_context->frame_index << " idr="sv << packet_is_idr;
      }
    }

    static bool sample_buffer_is_idr(CMSampleBufferRef sampleBuffer) {
      CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
      if (!attachments || CFArrayGetCount(attachments) == 0) {
        return true;
      }

      CFDictionaryRef attachment = (CFDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
      CFBooleanRef not_sync = (CFBooleanRef) CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_NotSync);
      return not_sync == nullptr || not_sync == kCFBooleanFalse;
    }

    void append_parameter_sets(CMSampleBufferRef sampleBuffer, std::vector<uint8_t> &output) {
      auto format_description = CMSampleBufferGetFormatDescription(sampleBuffer);
      if (!format_description) {
        return;
      }

      if (codec_type == kCMVideoCodecType_H264) {
        size_t set_count = 0;
        int header_length = 0;
        OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format_description, 0, nullptr, nullptr, &set_count, &header_length);
        if (status != noErr) {
          return;
        }

        for (size_t index = 0; index < set_count; ++index) {
          const uint8_t *set_ptr = nullptr;
          size_t set_size = 0;
          if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format_description, index, &set_ptr, &set_size, nullptr, nullptr) == noErr && set_ptr && set_size > 0) {
            output.insert(output.end(), {0, 0, 0, 1});
            output.insert(output.end(), set_ptr, set_ptr + set_size);
          }
        }
      } else if (codec_type == kCMVideoCodecType_HEVC) {
        size_t set_count = 0;
        int header_length = 0;
        OSStatus status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format_description, 0, nullptr, nullptr, &set_count, &header_length);
        if (status != noErr) {
          return;
        }

        for (size_t index = 0; index < set_count; ++index) {
          const uint8_t *set_ptr = nullptr;
          size_t set_size = 0;
          if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format_description, index, &set_ptr, &set_size, nullptr, nullptr) == noErr && set_ptr && set_size > 0) {
            output.insert(output.end(), {0, 0, 0, 1});
            output.insert(output.end(), set_ptr, set_ptr + set_size);
          }
        }
      }
    }

    static const uint8_t *copy_or_map_sample_bytes(CMBlockBufferRef data_buffer, std::vector<uint8_t> &scratch, size_t &total_length) {
      total_length = (size_t) CMBlockBufferGetDataLength(data_buffer);
      size_t contiguous_length = 0;
      char *contiguous_ptr = nullptr;
      if (CMBlockBufferGetDataPointer(data_buffer, 0, &contiguous_length, nullptr, &contiguous_ptr) == kCMBlockBufferNoErr &&
          contiguous_ptr != nullptr &&
          contiguous_length >= total_length) {
        return reinterpret_cast<const uint8_t *>(contiguous_ptr);
      }

      scratch.resize(total_length);
      if (CMBlockBufferCopyDataBytes(data_buffer, 0, total_length, scratch.data()) != noErr) {
        return nullptr;
      }
      return scratch.data();
    }

    void append_sample_buffer_payload(CMSampleBufferRef sampleBuffer, std::vector<uint8_t> &output) {
      auto data_buffer = CMSampleBufferGetDataBuffer(sampleBuffer);
      if (!data_buffer) {
        return;
      }

      size_t total_length = 0;
      std::vector<uint8_t> scratch;
      const uint8_t *buffer = copy_or_map_sample_bytes(data_buffer, scratch, total_length);
      if (!buffer) {
        return;
      }

      if (codec_type == kCMVideoCodecType_AV1) {
        output.insert(output.end(), buffer, buffer + total_length);
        return;
      }

      output.reserve(output.size() + total_length + (total_length / 32) + 16);
      size_t offset = 0;
      while (offset + 4 <= total_length) {
        uint32_t nal_length = (uint32_t(buffer[offset]) << 24) | (uint32_t(buffer[offset + 1]) << 16) | (uint32_t(buffer[offset + 2]) << 8) | uint32_t(buffer[offset + 3]);
        offset += 4;
        if (offset + nal_length > total_length) {
          break;
        }
        output.insert(output.end(), {0, 0, 0, 1});
        output.insert(output.end(), buffer + offset, buffer + offset + nal_length);
        offset += nal_length;
      }
    }

    std::unique_ptr<platf::avcodec_encode_device_t> device;
    VTCompressionSessionRef compression_session {nullptr};
    std::shared_ptr<platf::av_pixel_ref_t> current_pixel_buffer_ref;
    CMVideoCodecType codec_type {};
    int width {};
    int height {};
    int bitrate {};
    int framerate {};
    bool ten_bit {false};
    video::dynamic_range_transport_e dynamic_range_transport {video::dynamic_range_transport_e::unknown};
    video::stream_colorspace_t colorspace;
    hdr_metadata_state_t hdr_metadata_state;
    bool force_idr {false};
    std::mutex inflight_mutex;
    std::condition_variable inflight_cv;
    std::size_t inflight_frames {0};
    const std::size_t max_inflight_frames {native_macos_vt_max_inflight_frames_for_framerate(framerate)};
    std::atomic<bool> fatal_error {false};
    std::atomic<uint64_t> submitted_frames {0};
    std::atomic<uint64_t> emitted_packets {0};
    std::atomic<uint64_t> dropped_frames {0};
  };

  std::unique_ptr<encode_session_t> make_vtcompression_encode_session(
    platf::display_t *disp,
    const config_t &config,
    int width,
    int height,
    std::unique_ptr<platf::avcodec_encode_device_t> encode_device
  ) {
    BOOST_LOG(info) << "Attempting native VTCompressionSession path"sv;
    CMVideoCodecType codec_type = native_macos_vt_codec_type_for_video_format(config.videoFormat);
    if (codec_type == 0) {
      return nullptr;
    }

    typename vt_compression_encode_session_t::hdr_metadata_state_t hdr_metadata_state;
    auto native_colorspace = encode_device->colorspace;
    if (video::colorspace_is_hdr(native_colorspace)) {
      hdr_metadata_state.valid = disp != nullptr && disp->get_hdr_metadata(hdr_metadata_state.metadata);
    }

    auto session = std::make_unique<vt_compression_encode_session_t>(
      std::move(encode_device),
      codec_type,
      width,
      height,
      config.bitrate * 1000,
      std::max(config.encodingFramerate, config.framerate),
      video::config_uses_hdr_stream(config),
      video::effective_dynamic_range_transport(config),
      native_colorspace,
      hdr_metadata_state
    );

    if (session->init()) {
      BOOST_LOG(error) << "Native VTCompressionSession init failed"sv;
      return nullptr;
    }

    BOOST_LOG(info) << "Native VTCompressionSession path selected"sv;
    return session;
  }
#else
  bool native_macos_vt_hevc_main10_supported() {
    return false;
  }

  bool native_macos_vt_av1_supported() {
    return false;
  }
#endif

  struct sync_session_ctx_t {
    safe::signal_t *join_event;
    safe::mail_raw_t::event_t<bool> shutdown_event;
    safe::mail_raw_t::queue_t<packet_t> packets;
    safe::mail_raw_t::event_t<bool> idr_events;
    safe::mail_raw_t::event_t<input::touch_port_t> touch_port_events;

    config_t config;
    int frame_nr;
    void *channel_data;
  };

  struct sync_session_t {
    sync_session_ctx_t *ctx;
    std::unique_ptr<encode_session_t> session;
  };

  using encode_session_ctx_queue_t = safe::queue_t<sync_session_ctx_t>;
  using encode_e = platf::capture_e;

  struct capture_ctx_t {
    img_event_t images;
    config_t config;
  };

  struct capture_thread_async_ctx_t {
    std::shared_ptr<safe::queue_t<capture_ctx_t>> capture_ctx_queue;
    std::thread capture_thread;

    safe::signal_t reinit_event;
    const encoder_t *encoder_p;
    sync_util::sync_t<std::weak_ptr<platf::display_t>> display_wp;
  };

  struct capture_thread_sync_ctx_t {
    encode_session_ctx_queue_t encode_session_ctx_queue {30};
  };

  void configure_capture_format_for_encoder(platf::display_t &disp, const encoder_t &encoder, const config_t &config);
  int start_capture_sync(capture_thread_sync_ctx_t &ctx);
  void end_capture_sync(capture_thread_sync_ctx_t &ctx);
  int start_capture_async(capture_thread_async_ctx_t &ctx);
  void end_capture_async(capture_thread_async_ctx_t &ctx);

  // Keep a reference counter to ensure the capture thread only runs when other threads have a reference to the capture thread
  auto capture_thread_async = safe::make_shared<capture_thread_async_ctx_t>(start_capture_async, end_capture_async);
  auto capture_thread_sync = safe::make_shared<capture_thread_sync_ctx_t>(start_capture_sync, end_capture_sync);

#ifdef _WIN32
  encoder_t nvenc {
    "nvenc"sv,
    std::make_unique<encoder_platform_formats_nvenc>(
      platf::mem_type_e::dxgi,
      platf::pix_fmt_e::nv12,
      platf::pix_fmt_e::p010,
      platf::pix_fmt_e::ayuv,
      platf::pix_fmt_e::yuv444p16
    ),
    {
      {},  // Common options
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_nvenc"s,
    },
    {
      {},  // Common options
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_nvenc"s,
    },
    {
      {},  // Common options
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "h264_nvenc"s,
    },
    PARALLEL_ENCODING | REF_FRAMES_INVALIDATION | YUV444_SUPPORT | ASYNC_TEARDOWN  // flags
  };
#elif !defined(__APPLE__)
  encoder_t nvenc {
    "nvenc"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
  #ifdef _WIN32
      AV_HWDEVICE_TYPE_D3D11VA,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_D3D11,
  #else
      AV_HWDEVICE_TYPE_CUDA,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_CUDA,
  #endif
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_NONE,
  #ifdef _WIN32
      dxgi_init_avcodec_hardware_input_buffer
  #else
      cuda_init_avcodec_hardware_input_buffer
  #endif
    ),
    {
      // Common options
      {
        {"delay"s, 0},
        {"forced-idr"s, 1},
        {"zerolatency"s, 1},
        {"surfaces"s, 1},
        {"cbr_padding"s, false},
        {"preset"s, &config::video.nv_legacy.preset},
        {"tune"s, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY},
        {"rc"s, NV_ENC_PARAMS_RC_CBR},
        {"multipass"s, &config::video.nv_legacy.multipass},
        {"aq"s, &config::video.nv_legacy.aq},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_nvenc"s,
    },
    {
      // Common options
      {
        {"delay"s, 0},
        {"forced-idr"s, 1},
        {"zerolatency"s, 1},
        {"surfaces"s, 1},
        {"cbr_padding"s, false},
        {"preset"s, &config::video.nv_legacy.preset},
        {"tune"s, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY},
        {"rc"s, NV_ENC_PARAMS_RC_CBR},
        {"multipass"s, &config::video.nv_legacy.multipass},
        {"aq"s, &config::video.nv_legacy.aq},
      },
      {
        // SDR-specific options
        {"profile"s, (int) nv::profile_hevc_e::main},
      },
      {
        // HDR-specific options
        {"profile"s, (int) nv::profile_hevc_e::main_10},
      },
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_nvenc"s,
    },
    {
      {
        {"delay"s, 0},
        {"forced-idr"s, 1},
        {"zerolatency"s, 1},
        {"surfaces"s, 1},
        {"cbr_padding"s, false},
        {"preset"s, &config::video.nv_legacy.preset},
        {"tune"s, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY},
        {"rc"s, NV_ENC_PARAMS_RC_CBR},
        {"coder"s, &config::video.nv_legacy.h264_coder},
        {"multipass"s, &config::video.nv_legacy.multipass},
        {"aq"s, &config::video.nv_legacy.aq},
      },
      {
        // SDR-specific options
        {"profile"s, (int) nv::profile_h264_e::high},
      },
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "h264_nvenc"s,
    },
    PARALLEL_ENCODING
  };
#endif

#ifdef _WIN32
  encoder_t quicksync {
    "quicksync"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_D3D11VA,
      AV_HWDEVICE_TYPE_QSV,
      AV_PIX_FMT_QSV,
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_VUYX,
      AV_PIX_FMT_XV30,
      dxgi_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options
      {
        {"preset"s, &config::video.qsv.qsv_preset},
        {"forced_idr"s, 1},
        {"async_depth"s, 1},
        {"low_delay_brc"s, 1},
        {"low_power"s, 1},
      },
      {
        // SDR-specific options
        {"profile"s, (int) qsv::profile_av1_e::main},
      },
      {
        // HDR-specific options
        {"profile"s, (int) qsv::profile_av1_e::main},
      },
      {
        // YUV444 SDR-specific options
        {"profile"s, (int) qsv::profile_av1_e::high},
      },
      {
        // YUV444 HDR-specific options
        {"profile"s, (int) qsv::profile_av1_e::high},
      },
      {},  // Fallback options
      "av1_qsv"s,
    },
    {
      // Common options
      {
        {"preset"s, &config::video.qsv.qsv_preset},
        {"forced_idr"s, 1},
        {"async_depth"s, 1},
        {"low_delay_brc"s, 1},
        {"low_power"s, 1},
        {"recovery_point_sei"s, 0},
        {"pic_timing_sei"s, 0},
      },
      {
        // SDR-specific options
        {"profile"s, (int) qsv::profile_hevc_e::main},
      },
      {
        // HDR-specific options
        {"profile"s, (int) qsv::profile_hevc_e::main_10},
      },
      {
        // YUV444 SDR-specific options
        {"profile"s, (int) qsv::profile_hevc_e::rext},
      },
      {
        // YUV444 HDR-specific options
        {"profile"s, (int) qsv::profile_hevc_e::rext},
      },
      {
        // Fallback options
        {"low_power"s, []() {
           return config::video.qsv.qsv_slow_hevc ? 0 : 1;
         }},
      },
      "hevc_qsv"s,
    },
    {
      // Common options
      {
        {"preset"s, &config::video.qsv.qsv_preset},
        {"cavlc"s, &config::video.qsv.qsv_cavlc},
        {"forced_idr"s, 1},
        {"async_depth"s, 1},
        {"low_delay_brc"s, 1},
        {"low_power"s, 1},
        {"recovery_point_sei"s, 0},
        {"vcm"s, 1},
        {"pic_timing_sei"s, 0},
        {"max_dec_frame_buffering"s, 1},
      },
      {
        // SDR-specific options
        {"profile"s, (int) qsv::profile_h264_e::high},
      },
      {},  // HDR-specific options
      {
        // YUV444 SDR-specific options
        {"profile"s, (int) qsv::profile_h264_e::high_444p},
      },
      {},  // YUV444 HDR-specific options
      {
        // Fallback options
        {"low_power"s, 0},  // Some old/low-end Intel GPUs don't support low power encoding
      },
      "h264_qsv"s,
    },
    PARALLEL_ENCODING | CBR_WITH_VBR | RELAXED_COMPLIANCE | NO_RC_BUF_LIMIT | YUV444_SUPPORT
  };

  encoder_t amdvce {
    "amdvce"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_D3D11VA,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_D3D11,
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_NONE,
      dxgi_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options
      {
        {"filler_data"s, false},
        {"forced_idr"s, 1},
        {"latency"s, "lowest_latency"s},
        {"async_depth"s, 1},
        {"skip_frame"s, 0},
        {"log_to_dbg"s, []() {
           return config::runtime.min_log_level < 2 ? 1 : 0;
         }},
        {"preencode"s, &config::video.amd.amd_preanalysis},
        {"quality"s, &config::video.amd.amd_quality_av1},
        {"rc"s, &config::video.amd.amd_rc_av1},
        {"usage"s, &config::video.amd.amd_usage_av1},
        {"enforce_hrd"s, &config::video.amd.amd_enforce_hrd},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_amf"s,
    },
    {
      // Common options
      {
        {"filler_data"s, false},
        {"forced_idr"s, 1},
        {"latency"s, 1},
        {"async_depth"s, 1},
        {"skip_frame"s, 0},
        {"log_to_dbg"s, []() {
           return config::runtime.min_log_level < 2 ? 1 : 0;
         }},
        {"gops_per_idr"s, 1},
        {"header_insertion_mode"s, "idr"s},
        {"preencode"s, &config::video.amd.amd_preanalysis},
        {"quality"s, &config::video.amd.amd_quality_hevc},
        {"rc"s, &config::video.amd.amd_rc_hevc},
        {"usage"s, &config::video.amd.amd_usage_hevc},
        {"vbaq"s, &config::video.amd.amd_vbaq},
        {"enforce_hrd"s, &config::video.amd.amd_enforce_hrd},
        {"level"s, [](const config_t &cfg) {
           auto size = cfg.width * cfg.height;
           // For 4K and below, try to use level 5.1 or 5.2 if possible
           if (size <= 8912896) {
             if (size * cfg.framerate <= 534773760) {
               return "5.1"s;
             } else if (size * cfg.framerate <= 1069547520) {
               return "5.2"s;
             }
           }
           return "auto"s;
         }},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_amf"s,
    },
    {
      // Common options
      {
        {"filler_data"s, false},
        {"forced_idr"s, 1},
        {"latency"s, 1},
        {"async_depth"s, 1},
        {"frame_skipping"s, 0},
        {"log_to_dbg"s, []() {
           return config::runtime.min_log_level < 2 ? 1 : 0;
         }},
        {"preencode"s, &config::video.amd.amd_preanalysis},
        {"quality"s, &config::video.amd.amd_quality_h264},
        {"rc"s, &config::video.amd.amd_rc_h264},
        {"usage"s, &config::video.amd.amd_usage_h264},
        {"vbaq"s, &config::video.amd.amd_vbaq},
        {"enforce_hrd"s, &config::video.amd.amd_enforce_hrd},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {
        // Fallback options
        {"usage"s, 2 /* AMF_VIDEO_ENCODER_USAGE_LOW_LATENCY */},  // Workaround for https://github.com/GPUOpen-LibrariesAndSDKs/AMF/issues/410
      },
      "h264_amf"s,
    },
    PARALLEL_ENCODING
  };
#endif

  encoder_t software {
    "software"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_NONE,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_YUV420P,
      AV_PIX_FMT_YUV420P10,
      AV_PIX_FMT_YUV444P,
      AV_PIX_FMT_YUV444P10,
      nullptr
    ),
    {
      // libsvtav1 takes different presets than libx264/libx265.
      // We set an infinite GOP length, use a low delay prediction structure,
      // force I frames to be key frames, and set max bitrate to default to work
      // around a FFmpeg bug with CBR mode.
      {
        {"svtav1-params"s, "keyint=-1:pred-struct=1:force-key-frames=1:mbr=0"s},
        {"preset"s, &config::video.sw.svtav1_preset},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options

#ifdef ENABLE_BROKEN_AV1_ENCODER
           // Due to bugs preventing on-demand IDR frames from working and very poor
           // real-time encoding performance, we do not enable libsvtav1 by default.
           // It is only suitable for testing AV1 until the IDR frame issue is fixed.
      "libsvtav1"s,
#else
      {},
#endif
    },
    {
      // x265's Info SEI is so long that it causes the IDR picture data to be
      // kicked to the 2nd packet in the frame, breaking the client packet parser.
      // It also looks like gop_size isn't passed on to x265, so we have to set
      // 'keyint=-1' in the parameters ourselves.
      {
        {"forced-idr"s, 1},
        {"x265-params"s, "info=0:keyint=-1"s},
        {"preset"s, &config::video.sw.sw_preset},
        {"tune"s, &config::video.sw.sw_tune},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "libx265"s,
    },
    {
      // Common options
      {
        {"preset"s, &config::video.sw.sw_preset},
        {"tune"s, &config::video.sw.sw_tune},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "libx264"s,
    },
    H264_ONLY | PARALLEL_ENCODING | ALWAYS_REPROBE | YUV444_SUPPORT
  };

#ifdef __linux__
  encoder_t vaapi {
    "vaapi"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_VAAPI,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_VAAPI,
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_NONE,
      vaapi_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options
      {
        {"async_depth"s, 1},
        {"idr_interval"s, std::numeric_limits<int>::max()},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_vaapi"s,
    },
    {
      // Common options
      {
        {"async_depth"s, 1},
        {"sei"s, 0},
        {"idr_interval"s, std::numeric_limits<int>::max()},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_vaapi"s,
    },
    {
      // Common options
      {
        {"async_depth"s, 1},
        {"sei"s, 0},
        {"idr_interval"s, std::numeric_limits<int>::max()},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "h264_vaapi"s,
    },
    // RC buffer size will be set in platform code if supported
    LIMITED_GOP_SIZE | PARALLEL_ENCODING | NO_RC_BUF_LIMIT
  };
#endif

#ifdef __APPLE__
  encoder_t videotoolbox {
    "videotoolbox"sv,
    std::make_unique<encoder_platform_formats_avcodec>(
      AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
      AV_HWDEVICE_TYPE_NONE,
      AV_PIX_FMT_VIDEOTOOLBOX,
      AV_PIX_FMT_NV12,
      AV_PIX_FMT_P010,
      AV_PIX_FMT_NONE,
      AV_PIX_FMT_NONE,
      vt_init_avcodec_hardware_input_buffer
    ),
    {
      // Common options
      {
        {"allow_sw"s, &config::video.vt.vt_allow_sw},
        {"require_sw"s, &config::video.vt.vt_require_sw},
        {"realtime"s, &config::video.vt.vt_realtime},
        {"max_ref_frames"s, 1},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "av1_videotoolbox"s,
    },
    {
      // Common options
      {
        {"allow_sw"s, &config::video.vt.vt_allow_sw},
        {"require_sw"s, &config::video.vt.vt_require_sw},
        {"realtime"s, &config::video.vt.vt_realtime},
        {"max_ref_frames"s, 1},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {},  // Fallback options
      "hevc_videotoolbox"s,
    },
    {
      // Common options
      {
        {"allow_sw"s, &config::video.vt.vt_allow_sw},
        {"require_sw"s, &config::video.vt.vt_require_sw},
        {"realtime"s, &config::video.vt.vt_realtime},
        {"max_ref_frames"s, 1},
      },
      {},  // SDR-specific options
      {},  // HDR-specific options
      {},  // YUV444 SDR-specific options
      {},  // YUV444 HDR-specific options
      {
        // Fallback options
        {"flags"s, "-low_delay"},
      },
      "h264_videotoolbox"s,
    },
    PARALLEL_ENCODING
  };
#endif

  static const std::vector<encoder_t *> encoders {
#ifndef __APPLE__
    &nvenc,
#endif
#ifdef _WIN32
    &quicksync,
    &amdvce,
#endif
#ifdef __linux__
    &vaapi,
#endif
#ifdef __APPLE__
    &videotoolbox,
#endif
    &software
  };

  static encoder_t *chosen_encoder;
  int active_hevc_mode;
  int active_av1_mode;
  bool last_encoder_probe_supported_ref_frames_invalidation = false;
  std::array<bool, 3> last_encoder_probe_supported_yuv444_for_codec = {
    true,
    true,
    true
  };

  void reset_display(std::shared_ptr<platf::display_t> &disp, const platf::mem_type_e &type, const std::string &display_name, const config_t &config) {
    // We try this twice, in case we still get an error on reinitialization
    for (int x = 0; x < 2; ++x) {
      disp.reset();
      disp = platf::display(type, display_name, config);
      if (disp) {
        break;
      }

      // The capture code depends on us to sleep between failures
      std::this_thread::sleep_for(200ms);
    }
  }

  /**
   * @brief Update the list of display names before or during a stream.
   * @details This will attempt to keep `current_display_index` pointing at the same display.
   * @param dev_type The encoder device type used for display lookup.
   * @param display_names The list of display names to repopulate.
   * @param current_display_index The current display index or -1 if not yet known.
   */
  void refresh_displays(platf::mem_type_e dev_type, std::vector<std::string> &display_names, int &current_display_index, std::string &preferred_display_name) {
    // It is possible that the output name may be empty even if it wasn't before (device disconnected) or vice-versa
    const auto output_name { display_device::map_output_name(config::video.output_name) };
    std::string current_display_name = preferred_display_name;

    // If we have a current display index, let's start with that
    if (current_display_name.empty() && current_display_index >= 0 && current_display_index < display_names.size()) {
      current_display_name = display_names.at(current_display_index);
    }

    // Refresh the display names
    auto old_display_names = std::move(display_names);
    display_names = platf::display_names(dev_type);

    // If we now have no displays, let's put the old display array back and fail
    if (display_names.empty() && !old_display_names.empty()) {
      BOOST_LOG(error) << "No displays were found after reenumeration!"sv;
      display_names = std::move(old_display_names);
      return;
    } else if (display_names.empty()) {
      display_names.emplace_back(output_name);
    }

    // We now have a new display name list, so reset the index back to 0
    current_display_index = 0;

    if (current_display_name.empty()) {
      current_display_name = display_device::map_output_name(config::video.output_name);
    }

    // If we had a name previously, let's try to find it in the new list
    if (!current_display_name.empty()) {
      for (int x = 0; x < display_names.size(); ++x) {
        if (display_names[x] == current_display_name) {
          current_display_index = x;
          return;
        }
      }

      // The old display was removed, so we'll start back at the first display again
      BOOST_LOG(warning) << "Previous active display ["sv << current_display_name << "] is no longer present"sv;
    } else {
      for (int x = 0; x < display_names.size(); ++x) {
        if (display_names[x] == output_name) {
          current_display_index = x;
          return;
        }
      }
    }
  }

  void refresh_displays(platf::mem_type_e dev_type, std::vector<std::string> &display_names, int &current_display_index) {
    static std::string empty_str = "";
    refresh_displays(dev_type, display_names, current_display_index, empty_str);
  }

  void captureThread(
    std::shared_ptr<safe::queue_t<capture_ctx_t>> capture_ctx_queue,
    sync_util::sync_t<std::weak_ptr<platf::display_t>> &display_wp,
    safe::signal_t &reinit_event,
    const encoder_t &encoder
  ) {
    std::vector<capture_ctx_t> capture_ctxs;

    auto fg = util::fail_guard([&]() {
      capture_ctx_queue->stop();

      // Stop all sessions listening to this thread
      for (auto &capture_ctx : capture_ctxs) {
        capture_ctx.images->stop();
      }
      for (auto &capture_ctx : capture_ctx_queue->unsafe()) {
        capture_ctx.images->stop();
      }
    });

    auto switch_display_event = mail::man->event<int>(mail::switch_display);

    // Wait for the initial capture context or a request to stop the queue
    auto initial_capture_ctx = capture_ctx_queue->pop();
    if (!initial_capture_ctx) {
      return;
    }
    capture_ctxs.emplace_back(std::move(*initial_capture_ctx));

    std::vector<std::string> display_names;
    int display_p = -1;
    std::shared_ptr<platf::display_t> disp;
    if (!proc::proc.display_name.empty()) {
      disp = platf::display(encoder.platform_formats->dev_type, proc::proc.display_name, capture_ctxs.front().config);
    }
    if (!disp) {
      // Get all the monitor names now, rather than at boot, to
      // get the most up-to-date list available monitors
      refresh_displays(encoder.platform_formats->dev_type, display_names, display_p);
      disp = platf::display(encoder.platform_formats->dev_type, display_names[display_p], capture_ctxs.front().config);
      if (disp) {
        proc::proc.display_name = display_names[display_p];
      } else {
        return;
      }
    }

    display_wp = disp;

    constexpr auto capture_buffer_size = 24;
    std::list<std::shared_ptr<platf::img_t>> imgs(capture_buffer_size);

    std::vector<std::optional<std::chrono::steady_clock::time_point>> imgs_used_timestamps;
    const std::chrono::seconds trim_timeot = 3s;
    auto trim_imgs = [&]() {
      // count allocated and used within current pool
      size_t allocated_count = 0;
      size_t used_count = 0;
      for (const auto &img : imgs) {
        if (img) {
          allocated_count += 1;
          if (img.use_count() > 1) {
            used_count += 1;
          }
        }
      }

      // remember the timestamp of currently used count
      const auto now = std::chrono::steady_clock::now();
      if (imgs_used_timestamps.size() <= used_count) {
        imgs_used_timestamps.resize(used_count + 1);
      }
      imgs_used_timestamps[used_count] = now;

      // decide whether to trim allocated unused above the currently used count
      // based on last used timestamp and universal timeout
      size_t trim_target = used_count;
      for (size_t i = used_count; i < imgs_used_timestamps.size(); i++) {
        if (imgs_used_timestamps[i] && now - *imgs_used_timestamps[i] < trim_timeot) {
          trim_target = i;
        }
      }

      // trim allocated unused above the newly decided trim target
      if (allocated_count > trim_target) {
        size_t to_trim = allocated_count - trim_target;
        // prioritize trimming least recently used
        for (auto it = imgs.rbegin(); it != imgs.rend(); it++) {
          auto &img = *it;
          if (img && img.use_count() == 1) {
            img.reset();
            to_trim -= 1;
            if (to_trim == 0) {
              break;
            }
          }
        }
        // forget timestamps that no longer relevant
        imgs_used_timestamps.resize(trim_target + 1);
      }
    };

    auto pull_free_image_callback = [&](std::shared_ptr<platf::img_t> &img_out) -> bool {
      img_out.reset();
      while (capture_ctx_queue->running()) {
        // pick first allocated but unused
        for (auto it = imgs.begin(); it != imgs.end(); it++) {
          if (*it && it->use_count() == 1) {
            img_out = *it;
            if (it != imgs.begin()) {
              // move image to the front of the list to prioritize its reusal
              imgs.erase(it);
              imgs.push_front(img_out);
            }
            break;
          }
        }
        // otherwise pick first unallocated
        if (!img_out) {
          for (auto it = imgs.begin(); it != imgs.end(); it++) {
            if (!*it) {
              // allocate image
              *it = disp->alloc_img();
              img_out = *it;
              if (it != imgs.begin()) {
                // move image to the front of the list to prioritize its reusal
                imgs.erase(it);
                imgs.push_front(img_out);
              }
              break;
            }
          }
        }
        if (img_out) {
          // trim allocated but unused portion of the pool based on timeouts
          trim_imgs();
          img_out->frame_timestamp.reset();
          return true;
        } else {
          // sleep and retry if image pool is full
          std::this_thread::sleep_for(1ms);
        }
      }
      return false;
    };

    // Capture takes place on this thread
    platf::adjust_thread_priority(platf::thread_priority_e::critical);
    uint64_t forwarded_capture_frames = 0;

    while (capture_ctx_queue->running()) {
      if (!capture_ctxs.empty()) {
        configure_capture_format_for_encoder(*disp, encoder, capture_ctxs.front().config);
      }

      bool artificial_reinit = false;

      auto push_captured_image_callback = [&](std::shared_ptr<platf::img_t> &&img, bool frame_captured) -> bool {
        KITTY_WHILE_LOOP(auto capture_ctx = std::begin(capture_ctxs), capture_ctx != std::end(capture_ctxs), {
          if (!capture_ctx->images->running()) {
            capture_ctx = capture_ctxs.erase(capture_ctx);

            continue;
          }

          if (frame_captured) {
            auto forwarded = ++forwarded_capture_frames;
            if (forwarded <= 5 || (forwarded % 120) == 0) {
              BOOST_LOG(info) << "Async capture forwarded frame #"sv << forwarded;
            }
            capture_ctx->images->raise(img);
          }

          ++capture_ctx;
        })

        if (!capture_ctx_queue->running()) {
          return false;
        }

        while (capture_ctx_queue->peek()) {
          capture_ctxs.emplace_back(std::move(*capture_ctx_queue->pop()));
        }

        if (switch_display_event->peek()) {
          artificial_reinit = true;
          return false;
        }

        return true;
      };

      auto status = disp->capture(push_captured_image_callback, pull_free_image_callback, &display_cursor);

      if (artificial_reinit && status != platf::capture_e::error) {
        status = platf::capture_e::reinit;

        artificial_reinit = false;
      }

      switch (status) {
        case platf::capture_e::reinit:
          {
            reinit_event.raise(true);

            // Some classes of images contain references to the display --> display won't delete unless img is deleted
            for (auto &img : imgs) {
              img.reset();
            }

            // display_wp is modified in this thread only
            // Wait for the other shared_ptr's of display to be destroyed.
            // New displays will only be created in this thread.
            while (display_wp->use_count() != 1) {
              // Free images that weren't consumed by the encoders. These can reference the display and prevent
              // the ref count from reaching 1. We do this here rather than on the encoder thread to avoid race
              // conditions where the encoding loop might free a good frame after reinitializing if we capture
              // a new frame here before the encoder has finished reinitializing.
              KITTY_WHILE_LOOP(auto capture_ctx = std::begin(capture_ctxs), capture_ctx != std::end(capture_ctxs), {
                if (!capture_ctx->images->running()) {
                  capture_ctx = capture_ctxs.erase(capture_ctx);
                  continue;
                }

                while (capture_ctx->images->peek()) {
                  capture_ctx->images->pop();
                }

                ++capture_ctx;
              });

              std::this_thread::sleep_for(20ms);
            }

            while (capture_ctx_queue->running()) {
              // Release the display before reenumerating displays, since some capture backends
              // only support a single display session per device/application.
              disp.reset();

              // Refresh display names since a display removal might have caused the reinitialization
              refresh_displays(encoder.platform_formats->dev_type, display_names, display_p, proc::proc.display_name);

              // Process any pending display switch with the new list of displays
              if (switch_display_event->peek()) {
                display_p = std::clamp(*switch_display_event->pop(), 0, (int) display_names.size() - 1);
              }

              // reset_display() will sleep between retries
              reset_display(disp, encoder.platform_formats->dev_type, display_names[display_p], capture_ctxs.front().config);
              if (disp) {
                proc::proc.display_name = display_names[display_p];
                break;
              }
            }
            if (!disp) {
              return;
            }

            display_wp = disp;

            reinit_event.reset();
            continue;
          }
        case platf::capture_e::error:
        case platf::capture_e::ok:
        case platf::capture_e::timeout:
        case platf::capture_e::interrupted:
          return;
        default:
          BOOST_LOG(error) << "Unrecognized capture status ["sv << (int) status << ']';
          return;
      }
    }
  }

  int encode_avcodec(int64_t frame_nr, avcodec_encode_session_t &session, const config_t &config, safe::mail_raw_t::queue_t<packet_t> &packets, void *channel_data, std::optional<std::chrono::steady_clock::time_point> frame_timestamp) {
    auto &frame = session.device->frame;
    frame->pts = frame_nr;

    auto &ctx = session.avcodec_ctx;

    auto &sps = session.sps;
    auto &vps = session.vps;

    // send the frame to the encoder
    BOOST_LOG(info) << "encode_avcodec send_frame start frame_nr="sv << frame_nr << " codec="sv << ctx->codec->name;
    BOOST_LOG(info) << "encode_avcodec frame format="sv << frame->format
                     << " width="sv << frame->width
                     << " height="sv << frame->height
                     << " key="sv << ((frame->flags & AV_FRAME_FLAG_KEY) ? 1 : 0)
                     << " pict_type="sv << frame->pict_type
                     << " color_range="sv << frame->color_range
                     << " color_primaries="sv << frame->color_primaries
                     << " color_trc="sv << frame->color_trc
                     << " colorspace="sv << frame->colorspace
                     << " chroma_location="sv << frame->chroma_location
                     << " hw_frames_ctx="sv << (frame->hw_frames_ctx ? "set" : "null");
    BOOST_LOG(info) << "encode_avcodec ctx pix_fmt="sv << ctx->pix_fmt
                     << " sw_pix_fmt="sv << ctx->sw_pix_fmt
                     << " width="sv << ctx->width
                     << " height="sv << ctx->height
                     << " hw_frames_ctx="sv << (ctx->hw_frames_ctx ? "set" : "null");
    auto ret = avcodec_send_frame(ctx.get(), frame);
    BOOST_LOG(info) << "encode_avcodec send_frame returned "sv << ret;
    if (ret < 0) {
      char err_str[AV_ERROR_MAX_STRING_SIZE] {0};
      BOOST_LOG(error) << "Could not send a frame for encoding: "sv << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, ret);

      return -1;
    }

    while (ret >= 0) {
      auto packet = std::make_unique<packet_raw_avcodec>();
      auto av_packet = packet.get()->av_packet;

      BOOST_LOG(info) << "encode_avcodec receive_packet start frame_nr="sv << frame_nr;
      ret = avcodec_receive_packet(ctx.get(), av_packet);
      BOOST_LOG(info) << "encode_avcodec receive_packet returned "sv << ret;
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        return 0;
      } else if (ret < 0) {
        return ret;
      }

      if (av_packet->flags & AV_PKT_FLAG_KEY) {
        BOOST_LOG(debug) << "Frame "sv << frame_nr << ": IDR Keyframe (AV_FRAME_FLAG_KEY)"sv;
      }

      if ((frame->flags & AV_FRAME_FLAG_KEY) && !(av_packet->flags & AV_PKT_FLAG_KEY)) {
        BOOST_LOG(error) << "Encoder did not produce IDR frame when requested!"sv;
      }

      if (session.inject) {
        if (session.inject == 1) {
          auto h264 = cbs::make_sps_h264(ctx.get(), av_packet);

          sps = std::move(h264.sps);
        } else {
          auto hevc = cbs::make_sps_hevc(ctx.get(), av_packet);

          sps = std::move(hevc.sps);
          vps = std::move(hevc.vps);

          session.replacements.emplace_back(
            std::string_view((char *) std::begin(vps.old), vps.old.size()),
            std::string_view((char *) std::begin(vps._new), vps._new.size())
          );
        }

        session.inject = 0;

        session.replacements.emplace_back(
          std::string_view((char *) std::begin(sps.old), sps.old.size()),
          std::string_view((char *) std::begin(sps._new), sps._new.size())
        );
      }

      if (av_packet && av_packet->pts == frame_nr) {
        packet->frame_timestamp = frame_timestamp;
      }

      packet->replacements = &session.replacements;
      packet->channel_data = channel_data;
      packet->hdr_frame_state = negotiated_optional_hdr_frame_state(
        config,
        true
      );
      packets->raise(std::move(packet));
    }

    return 0;
  }

  int encode_nvenc(int64_t frame_nr, nvenc_encode_session_t &session, const config_t &config, safe::mail_raw_t::queue_t<packet_t> &packets, void *channel_data, std::optional<std::chrono::steady_clock::time_point> frame_timestamp) {
    auto encoded_frame = session.encode_frame(frame_nr);
    if (encoded_frame.data.empty()) {
      BOOST_LOG(error) << "NvENC returned empty packet";
      return -1;
    }

    if (frame_nr != encoded_frame.frame_index) {
      BOOST_LOG(error) << "NvENC frame index mismatch " << frame_nr << " " << encoded_frame.frame_index;
    }

    auto packet = std::make_unique<packet_raw_generic>(std::move(encoded_frame.data), encoded_frame.frame_index, encoded_frame.idr);
    packet->channel_data = channel_data;
    packet->after_ref_frame_invalidation = encoded_frame.after_ref_frame_invalidation;
    packet->frame_timestamp = frame_timestamp;
    packet->hdr_frame_state = negotiated_optional_hdr_frame_state(
      config,
      true
    );
    packets->raise(std::move(packet));

    return 0;
  }

  int encode(int64_t frame_nr, encode_session_t &session, const config_t &config, safe::mail_raw_t::queue_t<packet_t> &packets, void *channel_data, std::optional<std::chrono::steady_clock::time_point> frame_timestamp) {
    if (auto avcodec_session = dynamic_cast<avcodec_encode_session_t *>(&session)) {
      return encode_avcodec(frame_nr, *avcodec_session, config, packets, channel_data, frame_timestamp);
    } else if (auto nvenc_session = dynamic_cast<nvenc_encode_session_t *>(&session)) {
      return encode_nvenc(frame_nr, *nvenc_session, config, packets, channel_data, frame_timestamp);
#ifdef __APPLE__
    } else if (auto vt_session = dynamic_cast<vt_compression_encode_session_t *>(&session)) {
      return vt_session->encode_frame(frame_nr, packets, channel_data, frame_timestamp);
#endif
    }

    return -1;
  }

  std::unique_ptr<avcodec_encode_session_t> make_avcodec_encode_session(
    platf::display_t *disp,
    const encoder_t &encoder,
    const config_t &config,
    int width,
    int height,
    std::unique_ptr<platf::avcodec_encode_device_t> encode_device,
    bool prepare_frame = true
  ) {
    auto platform_formats = dynamic_cast<const encoder_platform_formats_avcodec *>(encoder.platform_formats.get());
    if (!platform_formats) {
      return nullptr;
    }

    bool hardware = platform_formats->avcodec_base_dev_type != AV_HWDEVICE_TYPE_NONE;
    bool videotoolbox_direct_frames = platform_formats->avcodec_base_dev_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX;

    auto &video_format = encoder.codec_from_config(config);
    if (!video_format[encoder_t::PASSED] || !disp->is_codec_supported(video_format.name, config)) {
      BOOST_LOG(error) << encoder.name << ": "sv << video_format.name << " mode not supported"sv;
      return nullptr;
    }

    const bool hdr_stream = video::config_uses_hdr_stream(config);
    if (hdr_stream && !video_format[encoder_t::DYNAMIC_RANGE]) {
      BOOST_LOG(error) << video_format.name << ": dynamic range not supported"sv;
      return nullptr;
    }

    if (config.chromaSamplingType == 1 && !video_format[encoder_t::YUV444]) {
      BOOST_LOG(error) << video_format.name << ": YUV 4:4:4 not supported"sv;
      return nullptr;
    }

    auto codec = avcodec_find_encoder_by_name(video_format.name.c_str());
    if (!codec) {
      BOOST_LOG(error) << "Couldn't open ["sv << video_format.name << ']';

      return nullptr;
    }

    auto colorspace = encode_device->colorspace;
    auto sw_fmt = (colorspace.bit_depth == 8 && config.chromaSamplingType == 0)  ? platform_formats->avcodec_pix_fmt_8bit :
                  (colorspace.bit_depth == 8 && config.chromaSamplingType == 1)  ? platform_formats->avcodec_pix_fmt_yuv444_8bit :
                  (colorspace.bit_depth == 10 && config.chromaSamplingType == 0) ? platform_formats->avcodec_pix_fmt_10bit :
                  (colorspace.bit_depth == 10 && config.chromaSamplingType == 1) ? platform_formats->avcodec_pix_fmt_yuv444_10bit :
                                                                                   AV_PIX_FMT_NONE;

    // Allow up to 1 retry to apply the set of fallback options.
    //
    // Note: If we later end up needing multiple sets of
    // fallback options, we may need to allow more retries
    // to try applying each set.
    avcodec_ctx_t ctx;
    for (int retries = 0; retries < 2; retries++) {
      ctx.reset(avcodec_alloc_context3(codec));
      ctx->width = config.width;
      ctx->height = config.height;
      ctx->coded_width = config.width;
      ctx->coded_height = config.height;
      ctx->time_base = AVRational {1, config.framerate};
      ctx->framerate = AVRational {config.framerate, 1};

      switch (config.videoFormat) {
        case 0:
          // 10-bit h264 encoding is not supported by our streaming protocol
          assert(colorspace.bit_depth == 8);
          ctx->profile = (config.chromaSamplingType == 1) ? AV_PROFILE_H264_HIGH_444_PREDICTIVE : AV_PROFILE_H264_HIGH;
          break;

        case 1:
          if (config.chromaSamplingType == 1) {
            // HEVC uses the same RExt profile for both 8 and 10 bit YUV 4:4:4 encoding
            ctx->profile = AV_PROFILE_HEVC_REXT;
          } else {
            ctx->profile = colorspace.bit_depth > 8 ? AV_PROFILE_HEVC_MAIN_10 : AV_PROFILE_HEVC_MAIN;
          }
          break;

        case 2:
          // AV1 supports both 8 and 10 bit encoding with the same Main profile
          // but YUV 4:4:4 sampling requires High profile
          ctx->profile = (config.chromaSamplingType == 1) ? AV_PROFILE_AV1_HIGH : AV_PROFILE_AV1_MAIN;
          break;
      }

      // B-frames delay decoder output, so never use them
      ctx->max_b_frames = 0;

      // Use an infinite GOP length since I-frames are generated on demand
      ctx->gop_size = encoder.flags & LIMITED_GOP_SIZE ?
                        std::numeric_limits<std::int16_t>::max() :
                        std::numeric_limits<int>::max();

      ctx->keyint_min = std::numeric_limits<int>::max();

      // Some client decoders have limits on the number of reference frames
      if (config.numRefFrames) {
        if (video_format[encoder_t::REF_FRAMES_RESTRICT]) {
          ctx->refs = config.numRefFrames;
        } else {
          BOOST_LOG(warning) << "Client requested reference frame limit, but encoder doesn't support it!"sv;
        }
      }

      // We forcefully reset the flags to avoid clash on reuse of AVCodecContext
      ctx->flags = 0;
      ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
      if (!videotoolbox_direct_frames) {
        ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP;
      }

      ctx->flags2 |= AV_CODEC_FLAG2_FAST;

      auto avcodec_colorspace = avcodec_colorspace_from_stream_colorspace(colorspace);

      ctx->color_range = avcodec_colorspace.range;
      ctx->color_primaries = avcodec_colorspace.primaries;
      ctx->color_trc = avcodec_colorspace.transfer_function;
      ctx->colorspace = avcodec_colorspace.matrix;

      // Used by cbs::make_sps_hevc
      ctx->sw_pix_fmt = sw_fmt;

      if (hardware) {
        avcodec_buffer_t encoding_stream_context;

        ctx->pix_fmt = platform_formats->avcodec_dev_pix_fmt;

        if (!videotoolbox_direct_frames) {
          // Create the base hwdevice context
          auto buf_or_error = platform_formats->init_avcodec_hardware_input_buffer(encode_device.get());
          if (buf_or_error.has_right()) {
            return nullptr;
          }
          encoding_stream_context = std::move(buf_or_error.left());

          // If this encoder requires derivation from the base, derive the desired type
          if (platform_formats->avcodec_derived_dev_type != AV_HWDEVICE_TYPE_NONE) {
            avcodec_buffer_t derived_context;

            // Allow the hwdevice to prepare for this type of context to be derived
            if (encode_device->prepare_to_derive_context(platform_formats->avcodec_derived_dev_type)) {
              return nullptr;
            }

            auto err = av_hwdevice_ctx_create_derived(&derived_context, platform_formats->avcodec_derived_dev_type, encoding_stream_context.get(), 0);
            if (err) {
              char err_str[AV_ERROR_MAX_STRING_SIZE] {0};
              BOOST_LOG(error) << "Failed to derive device context: "sv << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, err);

              return nullptr;
            }

            encoding_stream_context = std::move(derived_context);
          }

          // Initialize avcodec hardware frames
          {
            avcodec_buffer_t frame_ref {av_hwframe_ctx_alloc(encoding_stream_context.get())};

            auto frame_ctx = (AVHWFramesContext *) frame_ref->data;
            frame_ctx->format = ctx->pix_fmt;
            frame_ctx->sw_format = sw_fmt;
            frame_ctx->height = ctx->height;
            frame_ctx->width = ctx->width;
            frame_ctx->initial_pool_size = 0;

            // Allow the hwdevice to modify hwframe context parameters
            encode_device->init_hwframes(frame_ctx);

            if (auto err = av_hwframe_ctx_init(frame_ref.get()); err < 0) {
              return nullptr;
            }

            ctx->hw_frames_ctx = av_buffer_ref(frame_ref.get());
          }
        }

        ctx->slices = config.slicesPerFrame;
      } else /* software */ {
        ctx->pix_fmt = sw_fmt;

        // Clients will request for the fewest slices per frame to get the
        // most efficient encode, but we may want to provide more slices than
        // requested to ensure we have enough parallelism for good performance.
        ctx->slices = std::max(config.slicesPerFrame, config::video.min_threads);
      }

      if (encoder.flags & SINGLE_SLICE_ONLY) {
        ctx->slices = 1;
      }

      ctx->thread_type = FF_THREAD_SLICE;
      ctx->thread_count = ctx->slices;

      AVDictionary *options {nullptr};
      auto handle_option = [&options, &config](const encoder_t::option_t &option) {
        std::visit(
          util::overloaded {
            [&](int v) {
              av_dict_set_int(&options, option.name.c_str(), v, 0);
            },
            [&](int *v) {
              av_dict_set_int(&options, option.name.c_str(), *v, 0);
            },
            [&](std::optional<int> *v) {
              if (*v) {
                av_dict_set_int(&options, option.name.c_str(), **v, 0);
              }
            },
            [&](const std::function<int()> &v) {
              av_dict_set_int(&options, option.name.c_str(), v(), 0);
            },
            [&](const std::string &v) {
              av_dict_set(&options, option.name.c_str(), v.c_str(), 0);
            },
            [&](std::string *v) {
              if (!v->empty()) {
                av_dict_set(&options, option.name.c_str(), v->c_str(), 0);
              }
            },
            [&](const std::function<const std::string(const config_t &cfg)> &v) {
              av_dict_set(&options, option.name.c_str(), v(config).c_str(), 0);
            }
          },
          option.value
        );
      };

      // Apply common options, then format-specific overrides
      for (auto &option : video_format.common_options) {
        handle_option(option);
      }
      for (auto &option : (hdr_stream ? video_format.hdr_options : video_format.sdr_options)) {
        handle_option(option);
      }
      if (config.chromaSamplingType == 1) {
        for (auto &option : (hdr_stream ? video_format.hdr444_options : video_format.sdr444_options)) {
          handle_option(option);
        }
      }
      if (retries > 0) {
        for (auto &option : video_format.fallback_options) {
          handle_option(option);
        }
      }

      auto bitrate = config.bitrate * 1000;
      ctx->rc_max_rate = bitrate;
      ctx->bit_rate = bitrate;

      if (encoder.flags & CBR_WITH_VBR) {
        // Ensure rc_max_bitrate != bit_rate to force VBR mode
        ctx->bit_rate--;
      } else {
        ctx->rc_min_rate = bitrate;
      }

      if (encoder.flags & RELAXED_COMPLIANCE) {
        ctx->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
      }

      if (!(encoder.flags & NO_RC_BUF_LIMIT)) {
        if (!hardware && (ctx->slices > 1 || config.videoFormat == 1)) {
          // Use a larger rc_buffer_size for software encoding when slices are enabled,
          // because libx264 can severely degrade quality if the buffer is too small.
          // libx265 encounters this issue more frequently, so always scale the
          // buffer by 1.5x for software HEVC encoding.
          ctx->rc_buffer_size = bitrate / ((config.framerate * 10) / 15);
        } else {
          ctx->rc_buffer_size = bitrate / config.framerate;

#ifndef __APPLE__
#endif
        }
      }

      // Allow the encoding device a final opportunity to set/unset or override any options
      encode_device->init_codec_options(ctx.get(), &options);

      if (auto status = avcodec_open2(ctx.get(), codec, &options)) {
        char err_str[AV_ERROR_MAX_STRING_SIZE] {0};

        if (!video_format.fallback_options.empty() && retries == 0) {
          BOOST_LOG(info)
            << "Retrying with fallback configuration options for ["sv << video_format.name << "] after error: "sv
            << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, status);

          continue;
        } else {
          BOOST_LOG(error)
            << "Could not open codec ["sv
            << video_format.name << "]: "sv
            << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, status);

          return nullptr;
        }
      }

      // Successfully opened the codec
      break;
    }

    std::unique_ptr<platf::avcodec_encode_device_t> encode_device_final;

    if (!encode_device->data) {
      auto software_encode_device = std::make_unique<avcodec_software_encode_device_t>();

      avcodec_frame_t frame {av_frame_alloc()};
      frame->format = ctx->pix_fmt;
      frame->width = ctx->width;
      frame->height = ctx->height;
      frame->color_range = ctx->color_range;
      frame->color_primaries = ctx->color_primaries;
      frame->color_trc = ctx->color_trc;
      frame->colorspace = ctx->colorspace;
      frame->chroma_location = ctx->chroma_sample_location;

      if (colorspace_is_hdr(colorspace)) {
        SS_HDR_METADATA hdr_metadata;
        if (disp->get_hdr_metadata(hdr_metadata)) {
          auto mdm = av_mastering_display_metadata_create_side_data(frame.get());

          mdm->display_primaries[0][0] = av_make_q(hdr_metadata.displayPrimaries[0].x, 50000);
          mdm->display_primaries[0][1] = av_make_q(hdr_metadata.displayPrimaries[0].y, 50000);
          mdm->display_primaries[1][0] = av_make_q(hdr_metadata.displayPrimaries[1].x, 50000);
          mdm->display_primaries[1][1] = av_make_q(hdr_metadata.displayPrimaries[1].y, 50000);
          mdm->display_primaries[2][0] = av_make_q(hdr_metadata.displayPrimaries[2].x, 50000);
          mdm->display_primaries[2][1] = av_make_q(hdr_metadata.displayPrimaries[2].y, 50000);

          mdm->white_point[0] = av_make_q(hdr_metadata.whitePoint.x, 50000);
          mdm->white_point[1] = av_make_q(hdr_metadata.whitePoint.y, 50000);

          mdm->min_luminance = av_make_q(hdr_metadata.minDisplayLuminance, 10000);
          mdm->max_luminance = av_make_q(hdr_metadata.maxDisplayLuminance, 1);

          mdm->has_luminance = hdr_metadata.maxDisplayLuminance != 0 ? 1 : 0;
          mdm->has_primaries = hdr_metadata.displayPrimaries[0].x != 0 ? 1 : 0;

          if (hdr_metadata.maxContentLightLevel != 0 || hdr_metadata.maxFrameAverageLightLevel != 0) {
            auto clm = av_content_light_metadata_create_side_data(frame.get());

            clm->MaxCLL = hdr_metadata.maxContentLightLevel;
            clm->MaxFALL = hdr_metadata.maxFrameAverageLightLevel;
          }
        } else {
          BOOST_LOG(error) << "Couldn't get display hdr metadata when colorspace selection indicates it should have one";
        }
      }

      if (software_encode_device->init(width, height, frame.get(), sw_fmt, hardware)) {
        return nullptr;
      }
      software_encode_device->colorspace = colorspace;

      if (prepare_frame && software_encode_device->set_frame(frame.release(), ctx->hw_frames_ctx)) {
        return nullptr;
      }

      encode_device_final = std::move(software_encode_device);
    } else {
      encode_device_final = std::move(encode_device);

      if (prepare_frame) {
        avcodec_frame_t frame {av_frame_alloc()};
        frame->format = ctx->pix_fmt;
        frame->width = ctx->width;
        frame->height = ctx->height;
        frame->color_range = ctx->color_range;
        frame->color_primaries = ctx->color_primaries;
        frame->color_trc = ctx->color_trc;
        frame->colorspace = ctx->colorspace;
        frame->chroma_location = ctx->chroma_sample_location;

        if (colorspace_is_hdr(colorspace)) {
          SS_HDR_METADATA hdr_metadata;
          if (disp->get_hdr_metadata(hdr_metadata)) {
            auto mdm = av_mastering_display_metadata_create_side_data(frame.get());
            mdm->display_primaries[0][0] = av_make_q(hdr_metadata.displayPrimaries[0].x, 50000);
            mdm->display_primaries[0][1] = av_make_q(hdr_metadata.displayPrimaries[0].y, 50000);
            mdm->display_primaries[1][0] = av_make_q(hdr_metadata.displayPrimaries[1].x, 50000);
            mdm->display_primaries[1][1] = av_make_q(hdr_metadata.displayPrimaries[1].y, 50000);
            mdm->display_primaries[2][0] = av_make_q(hdr_metadata.displayPrimaries[2].x, 50000);
            mdm->display_primaries[2][1] = av_make_q(hdr_metadata.displayPrimaries[2].y, 50000);
            mdm->white_point[0] = av_make_q(hdr_metadata.whitePoint.x, 50000);
            mdm->white_point[1] = av_make_q(hdr_metadata.whitePoint.y, 50000);
            mdm->min_luminance = av_make_q(hdr_metadata.minDisplayLuminance, 10000);
            mdm->max_luminance = av_make_q(hdr_metadata.maxDisplayLuminance, 1);
            mdm->has_luminance = hdr_metadata.maxDisplayLuminance != 0 ? 1 : 0;
            mdm->has_primaries = hdr_metadata.displayPrimaries[0].x != 0 ? 1 : 0;
          }
        }

        AVBufferRef *frame_hw_frames_ctx = videotoolbox_direct_frames ? nullptr : ctx->hw_frames_ctx;
        if (encode_device_final->set_frame(frame.release(), frame_hw_frames_ctx)) {
          return nullptr;
        }
      }
    }

    encode_device_final->apply_colorspace();

    auto session = std::make_unique<avcodec_encode_session_t>(
      std::move(ctx),
      std::move(encode_device_final),
      // 0 ==> don't inject, 1 ==> inject for h264, 2 ==> inject for hevc
      config.videoFormat <= 1 ? (1 - (int) video_format[encoder_t::VUI_PARAMETERS]) * (1 + config.videoFormat) : 0,
      // Direct VideoToolbox frames should not be flushed via a null frame in
      // teardown because the external frame ownership path is not compatible
      // with that flow during encoder probing.
      platform_formats->avcodec_base_dev_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX
    );

    return session;
  }

  std::unique_ptr<nvenc_encode_session_t> make_nvenc_encode_session(const config_t &client_config, std::unique_ptr<platf::nvenc_encode_device_t> encode_device) {
    if (!encode_device->init_encoder(client_config, encode_device->colorspace)) {
      return nullptr;
    }

    return std::make_unique<nvenc_encode_session_t>(std::move(encode_device));
  }

  std::unique_ptr<encode_session_t> make_encode_session(platf::display_t *disp, const encoder_t &encoder, const config_t &config, int width, int height, std::unique_ptr<platf::encode_device_t> encode_device, bool prepare_frame = true) {
    if (dynamic_cast<platf::avcodec_encode_device_t *>(encode_device.get())) {
      BOOST_LOG(info) << "make_encode_session avcodec device path encoder="sv << encoder.name << " videoFormat="sv << config.videoFormat;
      auto avcodec_encode_device = boost::dynamic_pointer_cast<platf::avcodec_encode_device_t>(std::move(encode_device));
#ifdef __APPLE__
      if (encoder.name == "videotoolbox"sv) {
        return make_vtcompression_encode_session(disp, config, width, height, std::move(avcodec_encode_device));
      }
#endif
      return make_avcodec_encode_session(disp, encoder, config, width, height, std::move(avcodec_encode_device), prepare_frame);
    } else if (dynamic_cast<platf::nvenc_encode_device_t *>(encode_device.get())) {
      auto nvenc_encode_device = boost::dynamic_pointer_cast<platf::nvenc_encode_device_t>(std::move(encode_device));
      return make_nvenc_encode_session(config, std::move(nvenc_encode_device));
    }

    return nullptr;
  }

  void encode_run(
    int &frame_nr,  // Store progress of the frame number
    safe::mail_t mail,
    img_event_t images,
    config_t config,
    std::shared_ptr<platf::display_t> disp,
    std::unique_ptr<platf::encode_device_t> encode_device,
    safe::signal_t &reinit_event,
    const encoder_t &encoder,
    void *channel_data
  ) {
    auto session = make_encode_session(disp.get(), encoder, config, disp->width, disp->height, std::move(encode_device));
    if (!session) {
      return;
    }
    const bool native_vt_session = dynamic_cast<vt_compression_encode_session_t *>(session.get()) != nullptr;
    constexpr uint64_t macos_display_sleep_threshold_frames = 120;

    // As a workaround for NVENC hangs and to generally speed up encoder reinit,
    // we will complete the encoder teardown in a separate thread if supported.
    // This will move expensive processing off the encoder thread to allow us
    // to restart encoding as soon as possible. For cases where the NVENC driver
    // hang occurs, this thread may probably never exit, but it will allow
    // streaming to continue without requiring a full restart of Lumen.
    auto fail_guard = util::fail_guard([&encoder, &session] {
      if (encoder.flags & ASYNC_TEARDOWN) {
        std::thread encoder_teardown_thread {[session = std::move(session)]() mutable {
          BOOST_LOG(info) << "Starting async encoder teardown";
          session.reset();
          BOOST_LOG(info) << "Async encoder teardown complete";
        }};
        encoder_teardown_thread.detach();
      }
    });

    auto streaming_profile = config::video.streaming_profile;
    std::transform(streaming_profile.begin(), streaming_profile.end(), streaming_profile.begin(), [](unsigned char ch) {
      return static_cast<char>(std::tolower(ch));
    });

    // Keep stale-frame recovery tied to the user-facing streaming profile instead
    // of a separate manual FPS floor knob.
    const double minimum_fps_target = [&]() -> double {
      if (streaming_profile == "low-latency") {
        return std::max(config.encodingFramerate / 3, 20000);
      }
      if (streaming_profile == "max-quality") {
        return std::max(config.encodingFramerate / 8, 6000);
      }
      return std::max(config.encodingFramerate / 5, 10000);
    }();
    auto max_frametime = std::chrono::nanoseconds(1000ms) * 1000 / minimum_fps_target;
    auto encode_frame_threshold = std::chrono::nanoseconds(1000ms) * 1000 / config.encodingFramerate;
    auto frame_variation_threshold = encode_frame_threshold / 4;
    BOOST_LOG(info) << "Streaming profile set to "sv << streaming_profile
                    << " with minimum frame cadence of ~"sv << (minimum_fps_target / 2000) << "fps ("sv << max_frametime * 2 << ")"sv;
    BOOST_LOG(info) << "Encoding Frame threshold: "sv << encode_frame_threshold;

    auto shutdown_event = mail->event<bool>(mail::shutdown);
    auto packets = mail::man->queue<packet_t>(mail::video_packets);
    auto idr_events = mail->event<bool>(mail::idr);
    auto invalidate_ref_frames_events = mail->event<std::pair<int64_t, int64_t>>(mail::invalidate_ref_frames);

    if (!native_vt_session) {
      // Load a dummy image into the AVFrame to ensure we have something to encode
      // even if we timeout waiting on the first frame. This is a relatively large
      // allocation which can be freed immediately after convert(), so we do this
      // in a separate scope.
      auto dummy_img = disp->alloc_img();
      if (!dummy_img || disp->dummy_img(dummy_img.get()) || session->convert(*dummy_img)) {
        return;
      }
    } else {
      BOOST_LOG(info) << "Native VT skipping dummy frame bootstrap"sv;
    }

    if (config.input_only) {
      BOOST_LOG(info) << "Input only session, video will not be captured."sv;

      // Encode the dummy img only once
      if (encode(frame_nr++, *session, config, packets, channel_data, std::chrono::steady_clock::now())) {
        BOOST_LOG(error) << "Could not encode dummy video packet"sv;
        return;
      }

      while (true) {
        if (shutdown_event->peek() || !images->running() || (reinit_event.peek())) {
          return;
        } else {
          std::this_thread::sleep_for(300ms);
        }
      }
    }

    std::chrono::steady_clock::time_point encode_frame_timestamp;
    bool encode_frame_timestamp_initialized = false;
    uint64_t received_capture_frames = 0;
    uint64_t capture_wait_timeouts = 0;
    bool logged_waiting_for_first_native_vt_frame = false;
    bool notified_capture_ready = false;
    BOOST_LOG(info) << "Async encode loop starting"sv;

    while (true) {
      // Break out of the encoding loop if any of the following are true:
      // a) The stream is ending
      // b) The host runtime is quitting
      // c) The capture side is waiting to reinit and we've encoded at least one frame
      //
      // If we have to reinit before we have received any captured frames, we will encode
      // the blank dummy frame just to let the client know that the stream is alive.
      if (shutdown_event->peek() || !images->running() || (reinit_event.peek() && frame_nr > 1)) {
        break;
      }

      bool requested_idr_frame = false;

      while (invalidate_ref_frames_events->peek()) {
        if (auto frames = invalidate_ref_frames_events->pop(0ms)) {
          session->invalidate_ref_frames(frames->first, frames->second);
        }
      }

      if (idr_events->peek()) {
        requested_idr_frame = true;
        idr_events->pop();
      }

      if (requested_idr_frame) {
        session->request_idr_frame();
      }

      std::optional<std::chrono::steady_clock::time_point> frame_timestamp;
      bool has_captured_frame = false;

      // Encode at a minimum FPS to avoid image quality issues with static content
      if (!requested_idr_frame || images->peek()) {
        auto wait_timeout = native_vt_session ? 250ms : max_frametime;
        if (auto img = images->pop(wait_timeout)) {
          has_captured_frame = true;
          auto received = ++received_capture_frames;
          if (!notified_capture_ready && (!native_vt_session || received >= macos_display_sleep_threshold_frames)) {
            proc::proc.on_video_capture_ready();
            notified_capture_ready = true;
            if (native_vt_session) {
              BOOST_LOG(info) << "macOS delaying physical display sleep until native capture reached frame #"sv << received;
            }
          }
          if (received <= 5 || (received % 120) == 0) {
            BOOST_LOG(info) << "Async encode received captured frame #"sv << received;
          }
          frame_timestamp = img->frame_timestamp;
          if (!frame_timestamp) {
            frame_timestamp = std::chrono::steady_clock::now();
          }

          if (session->convert(*img)) {
            BOOST_LOG(error) << "Could not convert image"sv;
            break;
          }
          if (!native_vt_session) {
            auto current_timestamp = *frame_timestamp;
            if (!encode_frame_timestamp_initialized) {
              encode_frame_timestamp = current_timestamp;
              encode_frame_timestamp_initialized = true;
            }
            auto time_diff = current_timestamp - encode_frame_timestamp;

            // If new frame comes in way too fast, just drop
            if (time_diff < -frame_variation_threshold) {
              continue;
            }

            if (time_diff < frame_variation_threshold) {
              *frame_timestamp = encode_frame_timestamp;
            } else {
              encode_frame_timestamp = current_timestamp;
            }

            encode_frame_timestamp += encode_frame_threshold;
          }
        } else if (!images->running()) {
          break;
        } else {
          auto timeout_count = ++capture_wait_timeouts;
          if (timeout_count <= 5 || (timeout_count % 60) == 0) {
            BOOST_LOG(info) << "Async encode timed out waiting for a captured frame #"sv << timeout_count;
          }
        }
      }

      if (native_vt_session && received_capture_frames == 0 && !frame_timestamp) {
        if (!logged_waiting_for_first_native_vt_frame) {
          BOOST_LOG(info) << "Native VT waiting for first captured frame before encoding"sv;
          logged_waiting_for_first_native_vt_frame = true;
        }
        continue;
      }
      if (native_vt_session && !has_captured_frame) {
        continue;
      }

      if (encode(frame_nr++, *session, config, packets, channel_data, frame_timestamp)) {
        BOOST_LOG(error) << "Could not encode video packet"sv;
        break;
      }

      session->request_normal_frame();
    }
  }

  input::touch_port_t make_port(platf::display_t *display, const config_t &config) {
    float wd = display->width;
    float hd = display->height;

    float wt = config.width;
    float ht = config.height;

    auto scalar = std::fminf(wt / wd, ht / hd);

    auto w2 = scalar * wd;
    auto h2 = scalar * hd;

    auto offsetX = (config.width - w2) * 0.5f;
    auto offsetY = (config.height - h2) * 0.5f;

    return input::touch_port_t {
      {
        display->offset_x,
        display->offset_y,
        config.width,
        config.height,
      },
      display->env_width,
      display->env_height,
      offsetX,
      offsetY,
      1.0f / scalar,
    };
  }

  namespace {
    void capture_external_encoded_ingress(
      safe::mail_t mail,
      const config_t &config,
      void *channel_data
    ) {
      auto shutdown_event = mail->event<bool>(mail::shutdown);
      auto idr_events = mail->event<bool>(mail::idr);
      auto invalidate_ref_frames_events = mail->event<std::pair<int64_t, int64_t>>(mail::invalidate_ref_frames);
      auto packets = mail::man->queue<packet_t>(mail::video_packets);
      auto ingress = LumenCoreSharedEncodedCaptureIngress();
      platf::external_capture_display_metadata_t external_metadata {};
      refresh_external_capture_metadata(mail, config, external_metadata);

      bool logged_codec_mismatch = false;
      bool logged_producer_stop = false;
      bool logged_frame_stall = false;
      bool logged_first_packet = false;
      bool logged_multi_tile_unsupported = false;
      bool waiting_for_initial_idr = true;
      bool logged_waiting_for_initial_idr = false;
      std::optional<int> adopted_video_format;
      int64_t next_packet_frame_index = 1;
      lumen_core_display_time_clock_t display_time_clock;
      auto last_ingress_stats_log = std::chrono::steady_clock::now();
      std::uint64_t last_logged_frame_count = 0;
      std::uint64_t last_forwarded_source_sequence_number = 0;
      std::uint64_t last_forwarded_source_display_time = 0;
      std::optional<std::chrono::steady_clock::time_point> last_forwarded_packet_timestamp;
      std::optional<double> last_forwarded_callback_latency_milliseconds;
      std::optional<double> last_forwarded_source_display_delta_milliseconds;
      std::optional<double> last_forwarded_packet_timestamp_delta_milliseconds;
      std::uint64_t last_forwarded_sequence_delta = 0;
      std::uint64_t last_forwarded_payload_hash = 0;
      std::size_t last_forwarded_payload_size = 0;
      std::uint32_t duplicate_payload_run = 0;
      std::uint32_t duplicate_payload_recovery_attempts = 0;
      std::uint32_t saturated_drop_event_run = 0;
      std::array<char, 512> event_message {};

      const auto arm_wait_for_next_idr = [&](std::string_view reason) {
        const auto ingress_snapshot = LumenCoreEncodedCaptureIngressCopySnapshot(ingress);
        LumenCoreEncodedCaptureIngressReset(ingress);
        refresh_external_capture_metadata(mail, config, external_metadata);
        display_time_clock = lumen_core_display_time_clock_t {};
        waiting_for_initial_idr = true;
        logged_waiting_for_initial_idr = false;
        logged_first_packet = false;
        logged_codec_mismatch = false;
        logged_multi_tile_unsupported = false;
        adopted_video_format.reset();
        last_forwarded_source_sequence_number = 0;
        last_forwarded_source_display_time = 0;
        last_forwarded_packet_timestamp.reset();
        last_forwarded_callback_latency_milliseconds.reset();
        last_forwarded_source_display_delta_milliseconds.reset();
        last_forwarded_packet_timestamp_delta_milliseconds.reset();
        last_forwarded_sequence_delta = 0;
        last_forwarded_payload_hash = 0;
        last_forwarded_payload_size = 0;
        duplicate_payload_run = 0;
        request_external_encoded_capture_key_frame();
        BOOST_LOG(info) << "External macOS encoded ingress requested decoder resync; flushed queued frames before waiting for the next IDR packet"
                        << " reason="sv << reason
                        << " flushed-queued="sv << ingress_snapshot.queued_frame_count
                        << " flushed-events="sv << ingress_snapshot.queued_event_count;
      };

      const auto restart_capture_session = [&](std::string_view reason) {
        duplicate_payload_run = 0;
        duplicate_payload_recovery_attempts = 0;
        saturated_drop_event_run = 0;
        restart_external_encoded_capture_session(reason);
        arm_wait_for_next_idr(reason);
      };

      if (!LumenCoreEncodedCaptureIngressIsProducerActive(ingress) &&
          !LumenCoreEncodedCaptureIngressWaitForProducerActive(ingress, lumen_core_ingress_wait_timeout_ms)) {
        BOOST_LOG(error) << "External macOS encoded ingress producer did not become active within "
                         << lumen_core_ingress_wait_timeout_ms << "ms";
        return;
      }

      while (!shutdown_event->peek()) {
        bool consumed_any = false;

        bool resync_to_next_idr = false;
        while (idr_events->peek()) {
          idr_events->pop();
          resync_to_next_idr = true;
        }
        while (invalidate_ref_frames_events->peek()) {
          invalidate_ref_frames_events->pop(0ms);
          resync_to_next_idr = true;
        }

        if (resync_to_next_idr) {
          arm_wait_for_next_idr("session-resync");
          consumed_any = true;
        }

        while (true) {
          auto event = LumenCoreEncodedCaptureIngressPopNextEvent(
            ingress,
            event_message.data(),
            event_message.size()
          );
          if (!event.has_value) {
            break;
          }

          consumed_any = true;
          std::string_view message {
            event_message.data(),
            strnlen(event_message.data(), event_message.size())
          };

          switch (event.kind) {
            case LumenCoreCaptureEventKindStarted:
            case LumenCoreCaptureEventKindRestarted:
              duplicate_payload_recovery_attempts = 0;
              saturated_drop_event_run = 0;
              arm_wait_for_next_idr("capture-restarted");
              BOOST_LOG(info) << "External macOS encoded ingress event kind="sv << static_cast<int>(event.kind)
                              << " message="sv << message;
              break;
            case LumenCoreCaptureEventKindDroppedFrame:
              BOOST_LOG(warning) << "External macOS encoded ingress dropped a frame"sv
                                 << " message="sv << message;
              if (message.find("capture processing queue is saturated"sv) != std::string_view::npos) {
                ++saturated_drop_event_run;
                arm_wait_for_next_idr("capture-queue-saturated");
              } else {
                saturated_drop_event_run = 0;
              }
              if (message == "core-forwarder-overflow"sv) {
                arm_wait_for_next_idr("core-forwarder-overflow");
              } else if (saturated_drop_event_run >= 3) {
                BOOST_LOG(warning) << "External macOS encoded ingress is restarting the capture session after repeated queue saturation events"sv
                                   << " run="sv << saturated_drop_event_run;
                restart_capture_session("capture-queue-saturated");
              }
              break;
            case LumenCoreCaptureEventKindFailed:
              BOOST_LOG(error) << "External macOS encoded ingress reported a failure: "sv << message;
              break;
            case LumenCoreCaptureEventKindStopped:
              BOOST_LOG(info) << "External macOS encoded ingress stopped"sv;
              break;
            default:
              break;
          }

          event_message.fill(0);
        }

        while (true) {
          CMSampleBufferRef retained_sample_buffer = nullptr;
          auto frame = LumenCoreEncodedCaptureIngressPopNextFrame(ingress, &retained_sample_buffer);
          if (!frame.has_value || !retained_sample_buffer) {
            if (retained_sample_buffer) {
              CFRelease(retained_sample_buffer);
            }
            break;
          }

          consumed_any = true;

          if (!CMSampleBufferDataIsReady(retained_sample_buffer)) {
            const auto make_ready_status = CMSampleBufferMakeDataReady(retained_sample_buffer);
            if (make_ready_status != noErr || !CMSampleBufferDataIsReady(retained_sample_buffer)) {
              BOOST_LOG(error) << "External macOS encoded ingress produced a non-ready sample buffer"
                               << " makeReadyStatus="sv << make_ready_status
                               << " codec="sv << lumen_core_codec_name(frame.codec);
              CFRelease(retained_sample_buffer);
              continue;
            }
          }

          const auto expected_video_format = adopted_video_format.value_or(config.videoFormat);
          if (!lumen_core_codec_matches_video_format(frame.codec, expected_video_format)) {
            const auto frame_video_format = lumen_core_video_format_for_codec(frame.codec);
            if (!logged_first_packet && frame_video_format.has_value()) {
              adopted_video_format = frame_video_format;
              BOOST_LOG(warning) << "External macOS encoded ingress adopted frame codec="sv
                                 << lumen_core_codec_name(frame.codec)
                                 << " because the streaming thread still expected "sv
                                 << requested_video_format_name(expected_video_format);
            } else if (!logged_codec_mismatch) {
              BOOST_LOG(error) << "External macOS encoded ingress codec mismatch frameCodec="sv
                               << lumen_core_codec_name(frame.codec)
                               << " requestedVideoFormat="sv
                               << requested_video_format_name(expected_video_format);
              logged_codec_mismatch = true;
              CFRelease(retained_sample_buffer);
              continue;
            } else {
              CFRelease(retained_sample_buffer);
              continue;
            }
          }

          const auto codec_type = lumen_core_codec_type(frame.codec);
          if (codec_type != kCMVideoCodecType_H264 && codec_type != kCMVideoCodecType_HEVC) {
            BOOST_LOG(error) << "External macOS encoded ingress only supports H.264 or HEVC packetization"sv;
            CFRelease(retained_sample_buffer);
            continue;
          }

          const auto encoded_tile_metadata = lumen_core_tile_metadata(frame.tile_metadata);
          const auto tile_count = encoded_tile_metadata.tile_count;
          const auto lane_count = encoded_tile_metadata.encoded_lane_count;
          const auto lumen_protocol_adapter = video::make_lumen_protocol_adapter(
            config,
            lumen::protocol::encoded_tile_layout {
              .tile_count = tile_count,
              .encoded_lane_count = lane_count,
            }
          );
          if ((tile_count > 1 || lane_count > 1) &&
              lumen_protocol_adapter.presentation_contract != lumen::protocol::presentation_contract::primed_per_tile_update) {
            if (!logged_multi_tile_unsupported) {
              BOOST_LOG(error) << "External macOS encoded ingress received multi-tile encoded frame before the Lumen encoded tile presentation contract was negotiated"
                               << " contract="sv << lumen_protocol_adapter.presentation_contract_name()
                               << " tile-index="sv << encoded_tile_metadata.tile_index
                               << " tile-count="sv << tile_count
                               << " lane-index="sv << encoded_tile_metadata.encoded_lane_index
                               << " lane-count="sv << lane_count
                               << " group-id="sv << encoded_tile_metadata.frame_group_id;
              logged_multi_tile_unsupported = true;
            }
            CFRelease(retained_sample_buffer);
            continue;
          }

          std::vector<uint8_t> packet_data;
          const bool sample_buffer_reports_idr = external_sample_buffer_is_idr(retained_sample_buffer);
          const bool packet_is_idr = frame.is_key_frame || sample_buffer_reports_idr;
          if (waiting_for_initial_idr && !packet_is_idr) {
            if (!logged_waiting_for_initial_idr) {
              BOOST_LOG(warning) << "External macOS encoded ingress is waiting for an initial IDR packet before forwarding to the client"sv;
              logged_waiting_for_initial_idr = true;
            }
            CFRelease(retained_sample_buffer);
            continue;
          }

          waiting_for_initial_idr = false;
          if (packet_is_idr) {
            append_parameter_sets_for_codec(retained_sample_buffer, codec_type, packet_data);
            if (append_external_hdr_static_metadata_if_needed(
                  retained_sample_buffer,
                  codec_type,
                  external_metadata.hdr_metadata,
                  frame.is_hdr_signaled || lumen_core_sample_buffer_indicates_hdr(retained_sample_buffer),
                  packet_data
                )) {
              BOOST_LOG(info) << "External macOS encoded ingress injected static HDR metadata SEI into HEVC IDR packet"sv;
            }
          }
          append_external_sample_buffer_payload(retained_sample_buffer, codec_type, packet_data);
          if (packet_data.empty()) {
            BOOST_LOG(error) << "External macOS encoded ingress produced an empty packet payload"sv;
            CFRelease(retained_sample_buffer);
            continue;
          }

          auto packet = std::make_unique<packet_raw_generic>(
            std::move(packet_data),
            next_packet_frame_index++,
            packet_is_idr
          );
          if (!logged_first_packet) {
            const auto payload_static_metadata_presence = external_hevc_payload_static_metadata_presence(retained_sample_buffer);
            const auto packet_static_metadata_presence =
              codec_type == kCMVideoCodecType_HEVC ?
                external_hevc_annexb_static_metadata_presence(packet->frame_data) :
                external_hevc_hdr_static_metadata_presence_t {false, false};
            const auto color_primaries = lumen_core_sample_buffer_extension_string(
              retained_sample_buffer,
              kCMFormatDescriptionExtension_ColorPrimaries
            );
            const auto transfer_function = lumen_core_sample_buffer_extension_string(
              retained_sample_buffer,
              kCMFormatDescriptionExtension_TransferFunction
            );
            const auto ycbcr_matrix = lumen_core_sample_buffer_extension_string(
              retained_sample_buffer,
              kCMFormatDescriptionExtension_YCbCrMatrix
            );
            BOOST_LOG(info) << "External macOS encoded ingress first accepted packet codec="sv
                            << lumen_core_codec_name(frame.codec)
                            << " idr="sv << packet_is_idr
                            << " bridge-key="sv << frame.is_key_frame
                            << " samplebuffer-idr="sv << sample_buffer_reports_idr
                            << " hdr="sv << frame.is_hdr_signaled
                            << " encoded="sv << lumen_core_sample_buffer_dimensions(retained_sample_buffer)
                            << " primaries="sv << (color_primaries.empty() ? "n/a"sv : std::string_view {color_primaries})
                            << " transfer="sv << (transfer_function.empty() ? "n/a"sv : std::string_view {transfer_function})
                            << " matrix="sv << (ycbcr_matrix.empty() ? "n/a"sv : std::string_view {ycbcr_matrix})
                            << " mastering="sv << lumen_core_sample_buffer_extension_present(retained_sample_buffer, kCMFormatDescriptionExtension_MasteringDisplayColorVolume)
                            << " cll="sv << lumen_core_sample_buffer_extension_present(retained_sample_buffer, kCMFormatDescriptionExtension_ContentLightLevelInfo)
                            << " sample-payload-mastering="sv << payload_static_metadata_presence.has_mastering_display_color_volume
                            << " sample-payload-cll="sv << payload_static_metadata_presence.has_content_light_level_info
                            << " packet-mastering="sv << packet_static_metadata_presence.has_mastering_display_color_volume
                            << " packet-cll="sv << packet_static_metadata_presence.has_content_light_level_info
                            << " tile-index="sv << encoded_tile_metadata.tile_index
                            << " tile-count="sv << tile_count
                            << " lane-index="sv << encoded_tile_metadata.encoded_lane_index
                            << " lane-count="sv << lane_count
                            << " seq="sv << frame.source_sequence_number
                            << " display-time="sv << frame.source_display_time;
            if (!packet_is_idr) {
              BOOST_LOG(warning) << "External macOS encoded ingress started without an IDR packet; client decoder may wait for recovery"sv;
            }
            logged_first_packet = true;
          }
          packet->channel_data = channel_data;
          packet->frame_timestamp = display_time_clock.frame_timestamp(frame.source_display_time);
          packet->encoded_tile_metadata = encoded_tile_metadata;
          const auto frame_is_hdr_signaled =
            frame.is_hdr_signaled || lumen_core_sample_buffer_indicates_hdr(retained_sample_buffer);
          if (video::dynamic_range_transport_uses_hdr_frame_state(video::effective_dynamic_range_transport(config))) {
            packet->hdr_frame_state = negotiated_external_overlay_hdr_frame_state(
              config,
              external_metadata,
              frame_is_hdr_signaled,
              external_metadata.hdr_active ? &external_metadata.hdr_metadata : nullptr
            );
          } else {
            packet->hdr_frame_state = std::nullopt;
          }
          if (!packet->frame_timestamp) {
            packet->frame_timestamp = std::chrono::steady_clock::now();
          }

          const auto previous_forwarded_source_sequence_number = last_forwarded_source_sequence_number;
          const auto previous_forwarded_source_display_time = last_forwarded_source_display_time;
          const auto previous_forwarded_packet_timestamp = last_forwarded_packet_timestamp;

          last_forwarded_sequence_delta =
            previous_forwarded_source_sequence_number > 0 && frame.source_sequence_number >= previous_forwarded_source_sequence_number ?
              frame.source_sequence_number - previous_forwarded_source_sequence_number :
              0;
          last_forwarded_source_display_delta_milliseconds =
            previous_forwarded_source_display_time > 0 && frame.source_display_time >= previous_forwarded_source_display_time ?
              std::optional<double> {lumen_core_display_time_clock_t::display_time_delta_milliseconds(frame.source_display_time - previous_forwarded_source_display_time)} :
              std::nullopt;
          last_forwarded_packet_timestamp_delta_milliseconds =
            previous_forwarded_packet_timestamp && packet->frame_timestamp ?
              std::optional<double> {static_cast<double>(std::chrono::duration_cast<std::chrono::microseconds>(*packet->frame_timestamp - *previous_forwarded_packet_timestamp).count()) / 1000.0} :
              std::nullopt;
          last_forwarded_callback_latency_milliseconds =
            frame.has_output_callback_latency_milliseconds ?
              std::optional<double> {frame.output_callback_latency_milliseconds} :
              std::nullopt;
          const auto current_payload_hash = packet_payload_hash(packet->frame_data);
          const auto duplicate_payload =
            last_forwarded_payload_size == packet->frame_data.size() &&
            last_forwarded_payload_hash == current_payload_hash;
          const auto duplicate_source_identity =
            previous_forwarded_source_sequence_number > 0 &&
            previous_forwarded_source_display_time > 0 &&
            frame.source_sequence_number == previous_forwarded_source_sequence_number &&
            frame.source_display_time == previous_forwarded_source_display_time;
          const auto replay_duplicate = duplicate_payload && frame.is_replay;

          if (duplicate_source_identity && duplicate_payload) {
            CFRelease(retained_sample_buffer);
            continue;
          }

          if (duplicate_payload &&
              !frame.is_replay &&
              last_forwarded_sequence_delta > 0 &&
              last_forwarded_source_display_delta_milliseconds &&
              *last_forwarded_source_display_delta_milliseconds > 0.0) {
            ++duplicate_payload_run;
          } else {
            duplicate_payload_run = 0;
            duplicate_payload_recovery_attempts = 0;
          }

          const auto has_cadence_anomaly =
            last_forwarded_source_display_delta_milliseconds &&
            *last_forwarded_source_display_delta_milliseconds <= 0.0;
          const auto has_callback_latency_spike =
            last_forwarded_callback_latency_milliseconds &&
            *last_forwarded_callback_latency_milliseconds > callback_latency_resync_threshold_milliseconds(config);
          const auto has_packet_timestamp_drift =
            last_forwarded_packet_timestamp_delta_milliseconds &&
            *last_forwarded_packet_timestamp_delta_milliseconds > packet_timestamp_resync_threshold_milliseconds(config);
          if (has_cadence_anomaly) {
            BOOST_LOG(warning) << "External macOS encoded ingress cadence anomaly seq="sv
                               << frame.source_sequence_number
                               << " seq-delta="sv << last_forwarded_sequence_delta
                               << " display-time="sv << frame.source_display_time
                               << " display-delta-ms="sv
                               << (last_forwarded_source_display_delta_milliseconds ? *last_forwarded_source_display_delta_milliseconds : -1.0)
                               << " packet-ts-delta-ms="sv
                               << (last_forwarded_packet_timestamp_delta_milliseconds ? *last_forwarded_packet_timestamp_delta_milliseconds : -1.0)
                               << " callback-latency-ms="sv
                               << (last_forwarded_callback_latency_milliseconds ? *last_forwarded_callback_latency_milliseconds : -1.0);
            if (!packet_is_idr) {
              arm_wait_for_next_idr("cadence-anomaly");
              CFRelease(retained_sample_buffer);
              continue;
            }
          }
          if (has_callback_latency_spike) {
            BOOST_LOG(warning) << "External macOS encoded ingress callback latency spike seq="sv
                               << frame.source_sequence_number
                               << " callback-latency-ms="sv
                               << *last_forwarded_callback_latency_milliseconds
                               << " threshold-ms="sv
                               << callback_latency_resync_threshold_milliseconds(config)
                               << " packet-ts-delta-ms="sv
                               << (last_forwarded_packet_timestamp_delta_milliseconds ? *last_forwarded_packet_timestamp_delta_milliseconds : -1.0);
          }
          if (has_packet_timestamp_drift) {
            BOOST_LOG(warning) << "External macOS encoded ingress packet timestamp drift seq="sv
                               << frame.source_sequence_number
                               << " packet-ts-delta-ms="sv
                               << *last_forwarded_packet_timestamp_delta_milliseconds
                               << " threshold-ms="sv
                               << packet_timestamp_resync_threshold_milliseconds(config)
                               << " callback-latency-ms="sv
                               << (last_forwarded_callback_latency_milliseconds ? *last_forwarded_callback_latency_milliseconds : -1.0);
          }
          if (duplicate_payload_run >= 2 && !packet_is_idr) {
            ++duplicate_payload_recovery_attempts;
            if (duplicate_payload_recovery_attempts >= 2) {
              BOOST_LOG(warning) << "External macOS encoded ingress is restarting the capture session after repeated duplicate payload recovery failures"sv
                                 << " duplicate-run="sv << duplicate_payload_run
                                 << " recovery-attempts="sv << duplicate_payload_recovery_attempts;
              restart_capture_session("duplicate-payload-restart");
            } else {
              arm_wait_for_next_idr("duplicate-payload");
            }
            CFRelease(retained_sample_buffer);
            continue;
          }

          if (replay_duplicate) {
            duplicate_payload_run = 0;
            duplicate_payload_recovery_attempts = 0;
          }

          last_forwarded_source_sequence_number = frame.source_sequence_number;
          last_forwarded_source_display_time = frame.source_display_time;
          last_forwarded_packet_timestamp = packet->frame_timestamp;
          last_forwarded_payload_hash = current_payload_hash;
          last_forwarded_payload_size = packet->frame_data.size();
          saturated_drop_event_run = 0;

          packets->raise(std::move(packet));
          CFRelease(retained_sample_buffer);
        }

        const auto now = std::chrono::steady_clock::now();
        if (now - last_ingress_stats_log >= lumen_core_ingress_progress_log_interval) {
          const auto snapshot = LumenCoreEncodedCaptureIngressCopySnapshot(ingress);
          const auto producer_active = LumenCoreEncodedCaptureIngressIsProducerActive(ingress);
          BOOST_LOG(info) << "External macOS encoded ingress stats: frames="sv
                          << snapshot.frame_count
                          << " queued="sv << snapshot.queued_frame_count
                          << " dropped="sv << snapshot.dropped_frame_count
                          << " last-seq="sv << snapshot.last_frame_source_sequence_number
                          << " producer-active="sv << producer_active
                          << " last-seq-delta="sv << last_forwarded_sequence_delta
                          << " last-display-delta-ms="sv
                          << (last_forwarded_source_display_delta_milliseconds ? *last_forwarded_source_display_delta_milliseconds : -1.0)
                          << " last-packet-ts-delta-ms="sv
                          << (last_forwarded_packet_timestamp_delta_milliseconds ? *last_forwarded_packet_timestamp_delta_milliseconds : -1.0)
                          << " last-callback-latency-ms="sv
                          << (last_forwarded_callback_latency_milliseconds ? *last_forwarded_callback_latency_milliseconds : -1.0);

          if (producer_active && snapshot.frame_count == last_logged_frame_count) {
            if (!logged_frame_stall) {
              BOOST_LOG(warning) << "External macOS encoded ingress has not advanced frame delivery in the last "
                                 << std::chrono::duration_cast<std::chrono::seconds>(lumen_core_ingress_progress_log_interval).count()
                                 << "s"sv;
              logged_frame_stall = true;
            }
          } else {
            logged_frame_stall = false;
          }

          last_logged_frame_count = snapshot.frame_count;
          last_ingress_stats_log = now;
        }

        if (consumed_any) {
          continue;
        }

        if (!LumenCoreEncodedCaptureIngressWaitForData(ingress, 50)) {
          if (!LumenCoreEncodedCaptureIngressIsProducerActive(ingress)) {
            if (LumenCoreEncodedCaptureIngressWaitForProducerActive(ingress, lumen_core_ingress_wait_timeout_ms)) {
              logged_producer_stop = false;
              continue;
            }
            if (!logged_producer_stop) {
              BOOST_LOG(error) << "External macOS encoded ingress producer became inactive and did not recover within "
                               << lumen_core_ingress_wait_timeout_ms << "ms";
              logged_producer_stop = true;
            }
            break;
          }
        }
      }

      const auto final_snapshot = LumenCoreEncodedCaptureIngressCopySnapshot(ingress);
      BOOST_LOG(info) << "External macOS encoded ingress final stats: frames="sv
                      << final_snapshot.frame_count
                      << " queued="sv << final_snapshot.queued_frame_count
                      << " dropped="sv << final_snapshot.dropped_frame_count
                      << " last-seq="sv << final_snapshot.last_frame_source_sequence_number;
    }
  }  // namespace

  std::unique_ptr<platf::encode_device_t> make_encode_device(platf::display_t &disp, const encoder_t &encoder, const config_t &config) {
    std::unique_ptr<platf::encode_device_t> result;

    auto colorspace = colorspace_from_client_config(config, disp.is_hdr());

    platf::pix_fmt_e pix_fmt;
    if (config.chromaSamplingType == 1) {
      // YUV 4:4:4
      if (!(encoder.flags & YUV444_SUPPORT)) {
        // Encoder can't support YUV 4:4:4 regardless of hardware capabilities
        return {};
      }
      pix_fmt = (colorspace.bit_depth == 10) ?
                  encoder.platform_formats->pix_fmt_yuv444_10bit :
                  encoder.platform_formats->pix_fmt_yuv444_8bit;
    } else {
      // YUV 4:2:0
      pix_fmt = (colorspace.bit_depth == 10) ?
                  encoder.platform_formats->pix_fmt_10bit :
                  encoder.platform_formats->pix_fmt_8bit;
    }

    {
      auto encoder_name = encoder.codec_from_config(config).name;

      BOOST_LOG(info) << "Creating encoder " << logging::bracket(encoder_name);

      auto color_coding = colorspace.colorspace == colorspace_e::bt2020    ? "HDR (Rec. 2020 + SMPTE 2084 PQ)" :
                          colorspace.colorspace == colorspace_e::rec601    ? "SDR (Rec. 601)" :
                          colorspace.colorspace == colorspace_e::rec709    ? "SDR (Rec. 709)" :
                          colorspace.colorspace == colorspace_e::bt2020sdr ? "SDR (Rec. 2020)" :
                                                                             "unknown";

      BOOST_LOG(info) << "Color coding: " << color_coding;
      BOOST_LOG(info) << "Color depth: " << colorspace.bit_depth << "-bit";
      BOOST_LOG(info) << "Color range: " << (colorspace.full_range ? "JPEG" : "MPEG");
    }

    if (dynamic_cast<const encoder_platform_formats_avcodec *>(encoder.platform_formats.get())) {
      result = disp.make_avcodec_encode_device(pix_fmt);
    } else if (dynamic_cast<const encoder_platform_formats_nvenc *>(encoder.platform_formats.get())) {
      result = disp.make_nvenc_encode_device(pix_fmt);
    }

    if (result) {
      result->colorspace = colorspace;
    }

    return result;
  }

  void configure_capture_format_for_encoder(platf::display_t &disp, const encoder_t &encoder, const config_t &config) {
    auto colorspace = colorspace_from_client_config(config, disp.is_hdr());

    platf::pix_fmt_e pix_fmt;
    if (config.chromaSamplingType == 1) {
      if (!(encoder.flags & YUV444_SUPPORT)) {
        return;
      }
      pix_fmt = (colorspace.bit_depth == 10) ?
                  encoder.platform_formats->pix_fmt_yuv444_10bit :
                  encoder.platform_formats->pix_fmt_yuv444_8bit;
    } else {
      pix_fmt = (colorspace.bit_depth == 10) ?
                  encoder.platform_formats->pix_fmt_10bit :
                  encoder.platform_formats->pix_fmt_8bit;
    }

    if (dynamic_cast<const encoder_platform_formats_avcodec *>(encoder.platform_formats.get())) {
      auto capture_device = disp.make_avcodec_encode_device(pix_fmt);
      if (capture_device) {
        capture_device->colorspace = colorspace;
        capture_device->apply_colorspace();
        BOOST_LOG(info) << "Configured capture format for encoder ["sv << encoder.name
                        << "] pix_fmt="sv << static_cast<int>(pix_fmt)
                        << " full_range="sv << colorspace.full_range
                        << " bit_depth="sv << colorspace.bit_depth;
      }
    }
  }

  std::optional<sync_session_t> make_synced_session(platf::display_t *disp, const encoder_t &encoder, platf::img_t &img, sync_session_ctx_t &ctx) {
    sync_session_t encode_session;

    encode_session.ctx = &ctx;

    auto encode_device = make_encode_device(*disp, encoder, ctx.config);
    if (!encode_device) {
      return std::nullopt;
    }

    // absolute mouse coordinates require that the dimensions of the screen are known
    ctx.touch_port_events->raise(make_port(disp, ctx.config));

    auto session = make_encode_session(disp, encoder, ctx.config, img.width, img.height, std::move(encode_device));
    if (!session) {
      BOOST_LOG(error) << "Failed to create synced encode session"sv;
      return std::nullopt;
    }

    // Load the initial image to prepare for encoding
    BOOST_LOG(info) << "Preparing initial video frame for synced session"sv;
    if (session->convert(img)) {
      BOOST_LOG(error) << "Could not convert initial image"sv;
      return std::nullopt;
    }
    BOOST_LOG(info) << "Initial video frame prepared for synced session"sv;

    encode_session.session = std::move(session);

    return encode_session;
  }

  encode_e encode_run_sync(
    std::vector<std::unique_ptr<sync_session_ctx_t>> &synced_session_ctxs,
    encode_session_ctx_queue_t &encode_session_ctx_queue,
    std::vector<std::string> &display_names,
    int &display_p
  ) {
    const auto &encoder = *chosen_encoder;

    std::shared_ptr<platf::display_t> disp;
    std::string preferred_display_name = proc::proc.display_name;

    auto switch_display_event = mail::man->event<int>(mail::switch_display);

    if (synced_session_ctxs.empty()) {
      auto ctx = encode_session_ctx_queue.pop();
      if (!ctx) {
        return encode_e::ok;
      }

      synced_session_ctxs.emplace_back(std::make_unique<sync_session_ctx_t>(std::move(*ctx)));
    }

    if (!preferred_display_name.empty()) {
      disp = platf::display(encoder.platform_formats->dev_type, preferred_display_name, synced_session_ctxs.front()->config);
    }

    while (encode_session_ctx_queue.running()) {
      if (disp) {
        proc::proc.display_name = preferred_display_name;
        break;
      }

      // Refresh display names since a display removal might have caused the reinitialization
      refresh_displays(encoder.platform_formats->dev_type, display_names, display_p, preferred_display_name);

      // Process any pending display switch with the new list of displays
      if (switch_display_event->peek()) {
        display_p = std::clamp(*switch_display_event->pop(), 0, (int) display_names.size() - 1);
      }

      // reset_display() will sleep between retries
      reset_display(disp, encoder.platform_formats->dev_type, display_names[display_p], synced_session_ctxs.front()->config);
      if (disp) {
        proc::proc.display_name = display_names[display_p];
        break;
      }
    }

    if (!disp) {
      return encode_e::error;
    }

    auto img = disp->alloc_img();
    if (!img || disp->dummy_img(img.get())) {
      return encode_e::error;
    }

    std::vector<sync_session_t> synced_sessions;
    for (auto &ctx : synced_session_ctxs) {
      auto synced_session = make_synced_session(disp.get(), encoder, *img, *ctx);
      if (!synced_session) {
        return encode_e::error;
      }

      synced_sessions.emplace_back(std::move(*synced_session));
    }

    auto ec = platf::capture_e::ok;
    while (encode_session_ctx_queue.running()) {
      auto push_captured_image_callback = [&](std::shared_ptr<platf::img_t> &&img, bool frame_captured) -> bool {
        while (encode_session_ctx_queue.peek()) {
          auto encode_session_ctx = encode_session_ctx_queue.pop();
          if (!encode_session_ctx) {
            return false;
          }

          synced_session_ctxs.emplace_back(std::make_unique<sync_session_ctx_t>(std::move(*encode_session_ctx)));

          auto encode_session = make_synced_session(disp.get(), encoder, *img, *synced_session_ctxs.back());
          if (!encode_session) {
            ec = platf::capture_e::error;
            return false;
          }

          synced_sessions.emplace_back(std::move(*encode_session));
        }

        KITTY_WHILE_LOOP(auto pos = std::begin(synced_sessions), pos != std::end(synced_sessions), {
          auto ctx = pos->ctx;
          if (ctx->shutdown_event->peek()) {
            // Let waiting thread know it can delete shutdown_event
            ctx->join_event->raise(true);

            pos = synced_sessions.erase(pos);
            synced_session_ctxs.erase(std::find_if(std::begin(synced_session_ctxs), std::end(synced_session_ctxs), [&ctx_p = ctx](auto &ctx) {
              return ctx.get() == ctx_p;
            }));

            if (synced_sessions.empty()) {
              return false;
            }

            continue;
          }

          if (ctx->idr_events->peek()) {
            pos->session->request_idr_frame();
            ctx->idr_events->pop();
          }

          if (frame_captured && pos->session->convert(*img)) {
            BOOST_LOG(error) << "Could not convert image"sv;
            ctx->shutdown_event->raise(true);

            continue;
          }

          std::optional<std::chrono::steady_clock::time_point> frame_timestamp;
          if (img) {
            frame_timestamp = img->frame_timestamp;
          }

          if (encode(ctx->frame_nr++, *pos->session, ctx->config, ctx->packets, ctx->channel_data, frame_timestamp)) {
            BOOST_LOG(error) << "Could not encode video packet"sv;
            ctx->shutdown_event->raise(true);

            continue;
          }

          pos->session->request_normal_frame();

          ++pos;
        })

        if (switch_display_event->peek()) {
          ec = platf::capture_e::reinit;
          return false;
        }

        return true;
      };

      auto pull_free_image_callback = [&img](std::shared_ptr<platf::img_t> &img_out) -> bool {
        img_out = img;
        img_out->frame_timestamp.reset();
        return true;
      };

      auto status = disp->capture(push_captured_image_callback, pull_free_image_callback, &display_cursor);
      BOOST_LOG(info) << "Display capture loop exited with status "sv << static_cast<int>(status);
      switch (status) {
        case platf::capture_e::reinit:
        case platf::capture_e::error:
        case platf::capture_e::ok:
        case platf::capture_e::timeout:
        case platf::capture_e::interrupted:
          return ec != platf::capture_e::ok ? ec : status;
      }
    }

    return encode_e::ok;
  }

  void captureThreadSync() {
    auto ref = capture_thread_sync.ref();

    std::vector<std::unique_ptr<sync_session_ctx_t>> synced_session_ctxs;

    auto &ctx = ref->encode_session_ctx_queue;
    auto lg = util::fail_guard([&]() {
      ctx.stop();

      for (auto &ctx : synced_session_ctxs) {
        ctx->shutdown_event->raise(true);
        ctx->join_event->raise(true);
      }

      for (auto &ctx : ctx.unsafe()) {
        ctx.shutdown_event->raise(true);
        ctx.join_event->raise(true);
      }
    });

    // Encoding and capture takes place on this thread
    platf::adjust_thread_priority(platf::thread_priority_e::high);

    std::vector<std::string> display_names;
    int display_p = -1;
    while (encode_run_sync(synced_session_ctxs, ctx, display_names, display_p) == encode_e::reinit) {}
  }

  void capture_async(
    safe::mail_t mail,
    config_t &config,
    void *channel_data
  ) {
    auto shutdown_event = mail->event<bool>(mail::shutdown);

    auto images = std::make_shared<img_event_t::element_type>(256);
    auto lg = util::fail_guard([&]() {
      images->stop();
      shutdown_event->raise(true);
    });

    auto ref = capture_thread_async.ref();
    if (!ref) {
      return;
    }

    ref->capture_ctx_queue->raise(capture_ctx_t {images, config});

    if (!ref->capture_ctx_queue->running()) {
      return;
    }

    int frame_nr = 1;

    auto touch_port_event = mail->event<input::touch_port_t>(mail::touch_port);

    // Encoding takes place on this thread
    platf::adjust_thread_priority(platf::thread_priority_e::high);

    while (!shutdown_event->peek() && images->running()) {
      // Wait for the main capture event when the display is being reinitialized
      if (ref->reinit_event.peek()) {
        std::this_thread::sleep_for(20ms);
        continue;
      }
      // Wait for the display to be ready
      std::shared_ptr<platf::display_t> display;
      {
        auto lg = ref->display_wp.lock();
        if (ref->display_wp->expired()) {
          continue;
        }

        display = ref->display_wp->lock();
      }

      auto &encoder = *chosen_encoder;

      auto encode_device = make_encode_device(*display, encoder, config);
      if (!encode_device) {
        return;
      }

      // absolute mouse coordinates require that the dimensions of the screen are known
      touch_port_event->raise(make_port(display.get(), config));

      encode_run(
        frame_nr,
        mail,
        images,
        config,
        display,
        std::move(encode_device),
        ref->reinit_event,
        *ref->encoder_p,
        channel_data
      );
    }
  }

  void capture(
    safe::mail_t mail,
    config_t config,
    void *channel_data
  ) {
    auto idr_events = mail->event<bool>(mail::idr);

    idr_events->raise(true);
#ifdef __APPLE__
    if (!config.input_only) {
      auto *external_ingress = LumenCoreSharedEncodedCaptureIngress();
      if (!external_ingress) {
        BOOST_LOG(error) << "LumenCore encoded ingress is unavailable on macOS";
        return;
      }
      capture_external_encoded_ingress(std::move(mail), config, channel_data);
      return;
    }
#endif
    if (chosen_encoder->flags & PARALLEL_ENCODING) {
      capture_async(std::move(mail), config, channel_data);
    } else {
      safe::signal_t join_event;
      auto ref = capture_thread_sync.ref();
      ref->encode_session_ctx_queue.raise(sync_session_ctx_t {
        &join_event,
        mail->event<bool>(mail::shutdown),
        mail::man->queue<packet_t>(mail::video_packets),
        std::move(idr_events),
        mail->event<input::touch_port_t>(mail::touch_port),
        config,
        1,
        channel_data,
      });

      // Wait for join signal
      join_event.view();
    }
  }

  enum validate_flag_e {
    VUI_PARAMS = 0x01,  ///< VUI parameters
  };

  int validate_config(std::shared_ptr<platf::display_t> disp, const encoder_t &encoder, const config_t &config) {
    auto encode_device = make_encode_device(*disp, encoder, config);
    if (!encode_device) {
      return -1;
    }

    const bool videotoolbox_direct = encoder.platform_formats->dev_type == platf::mem_type_e::videotoolbox;

    auto session = make_encode_session(disp.get(), encoder, config, disp->width, disp->height, std::move(encode_device), !videotoolbox_direct);
    if (!session) {
      return -1;
    }

    if (videotoolbox_direct) {
      return VUI_PARAMS;
    }

    {
      // Image buffers are large, so we use a separate scope to free it immediately after convert()
      auto img = disp->alloc_img();
      if (!img || disp->dummy_img(img.get()) || session->convert(*img)) {
        return -1;
      }
    }

    session->request_idr_frame();

    auto packets = mail::man->queue<packet_t>(mail::video_packets);
    if (auto *vt_session = dynamic_cast<vt_compression_encode_session_t *>(session.get())) {
      if (encode(1, *vt_session, config, packets, nullptr, {})) {
        return -1;
      }

      for (int attempt = 0; attempt < 50 && !packets->peek(); ++attempt) {
        std::this_thread::sleep_for(10ms);
      }
      if (!packets->peek()) {
        BOOST_LOG(error) << "Timed out waiting for native VT probe packet"sv;
        return -1;
      }
    } else {
      while (!packets->peek()) {
        if (encode(1, *session, config, packets, nullptr, {})) {
          return -1;
        }
      }
    }

    auto packet = packets->pop();
    if (!packet->is_idr()) {
      BOOST_LOG(error) << "First packet type is not an IDR frame"sv;

      return -1;
    }

    int flag = 0;

    // This check only applies for H.264 and HEVC
    if (config.videoFormat <= 1) {
      if (auto packet_avcodec = dynamic_cast<packet_raw_avcodec *>(packet.get())) {
        if (cbs::validate_sps(packet_avcodec->av_packet, config.videoFormat ? AV_CODEC_ID_H265 : AV_CODEC_ID_H264)) {
          flag |= VUI_PARAMS;
        }
      } else {
        // Don't check it for non-avcodec encoders.
        flag |= VUI_PARAMS;
      }
    }

    return flag;
  }

  bool validate_encoder(encoder_t &encoder, bool expect_failure) {
    const auto output_name {display_device::map_output_name(config::video.output_name)};
    std::shared_ptr<platf::display_t> disp;
    const bool is_macos_videotoolbox = encoder.name == "videotoolbox";

    BOOST_LOG(info) << "Trying encoder ["sv << encoder.name << ']';
    auto fg = util::fail_guard([&]() {
      BOOST_LOG(info) << "Encoder ["sv << encoder.name << "] failed"sv;
    });

    auto test_hevc = active_hevc_mode >= 2 || (active_hevc_mode == 0 && !(encoder.flags & H264_ONLY));
    auto test_av1 = active_av1_mode >= 2 || (active_av1_mode == 0 && !(encoder.flags & H264_ONLY));

    encoder.h264.capabilities.set();
    encoder.hevc.capabilities.set();
    encoder.av1.capabilities.set();

    // First, test encoder viability
    config_t config_max_ref_frames {1920, 1080, 60, 1000, 1, 1, 1, 0, 0, 0};
    config_t config_autoselect {1920, 1080, 60, 1000, 1, 0, 1, 0, 0, 0};

    // If the encoder isn't supported at all (not even H.264), bail early
    reset_display(disp, encoder.platform_formats->dev_type, output_name, config_autoselect);
    if (!disp) {
      return false;
    }
    if (!disp->is_codec_supported(encoder.h264.name, config_autoselect)) {
      fg.disable();
      BOOST_LOG(info) << "Encoder ["sv << encoder.name << "] is not supported on this GPU"sv;
      return false;
    }

    // If we're expecting failure, use the autoselect ref config first since that will always succeed
    // if the encoder is available.
    auto max_ref_frames_h264 = expect_failure ? -1 : validate_config(disp, encoder, config_max_ref_frames);
    auto autoselect_h264 = max_ref_frames_h264 >= 0 ? max_ref_frames_h264 : validate_config(disp, encoder, config_autoselect);
    if (autoselect_h264 < 0) {
      return false;
    } else if (expect_failure) {
      // We expected failure, but actually succeeded. Do the max_ref_frames probe we skipped.
      max_ref_frames_h264 = validate_config(disp, encoder, config_max_ref_frames);
    }

    if (is_macos_videotoolbox) {
      const bool native_h264_supported = native_macos_vt_codec_supported(kCMVideoCodecType_H264);
      const bool native_hevc_supported = native_macos_vt_codec_supported(kCMVideoCodecType_HEVC);
      const bool native_av1_supported = native_macos_vt_codec_supported(kCMVideoCodecType_AV1);

      encoder.h264[encoder_t::VUI_PARAMETERS] = true;
      encoder.h264[encoder_t::REF_FRAMES_RESTRICT] = false;
      encoder.h264[encoder_t::PASSED] = native_h264_supported;

      if (test_hevc && native_hevc_supported) {
        encoder.hevc[encoder_t::VUI_PARAMETERS] = true;
        encoder.hevc[encoder_t::REF_FRAMES_RESTRICT] = false;
        encoder.hevc[encoder_t::PASSED] = validate_config(disp, encoder, config_t {1920, 1080, 60, 1000, 1, 0, 1, 1, 0, 0}) >= 0;
        encoder.hevc[encoder_t::DYNAMIC_RANGE] = encoder.hevc[encoder_t::PASSED];
      } else {
        encoder.hevc.capabilities.reset();
      }

      if (test_av1 && native_av1_supported) {
        encoder.av1[encoder_t::VUI_PARAMETERS] = true;
        encoder.av1[encoder_t::REF_FRAMES_RESTRICT] = false;
        encoder.av1[encoder_t::PASSED] = validate_config(disp, encoder, config_t {1920, 1080, 60, 1000, 1, 0, 1, 2, 0, 0}) >= 0;
        encoder.av1[encoder_t::DYNAMIC_RANGE] = encoder.av1[encoder_t::PASSED];
      } else {
        encoder.av1.capabilities.reset();
      }

      encoder.h264[encoder_t::YUV444] = false;
      encoder.hevc[encoder_t::YUV444] = false;
      encoder.av1[encoder_t::YUV444] = false;
      encoder.h264[encoder_t::DYNAMIC_RANGE] = false;

      fg.disable();
      BOOST_LOG(info) << "Encoder ["sv << encoder.name << "] validated with macOS-conservative probing"sv;
      return true;
    }

    std::vector<std::pair<validate_flag_e, encoder_t::flag_e>> packet_deficiencies {
      {VUI_PARAMS, encoder_t::VUI_PARAMETERS},
    };

    for (auto [validate_flag, encoder_flag] : packet_deficiencies) {
      encoder.h264[encoder_flag] = (max_ref_frames_h264 & validate_flag && autoselect_h264 & validate_flag);
    }

    encoder.h264[encoder_t::REF_FRAMES_RESTRICT] = max_ref_frames_h264 >= 0;
    encoder.h264[encoder_t::PASSED] = true;

    if (test_hevc) {
      config_max_ref_frames.videoFormat = 1;
      config_autoselect.videoFormat = 1;

      if (disp->is_codec_supported(encoder.hevc.name, config_autoselect)) {
        auto max_ref_frames_hevc = validate_config(disp, encoder, config_max_ref_frames);

        // If H.264 succeeded with max ref frames specified, assume that we can count on
        // HEVC to also succeed with max ref frames specified if HEVC is supported.
        auto autoselect_hevc = (max_ref_frames_hevc >= 0 || max_ref_frames_h264 >= 0) ?
                                 max_ref_frames_hevc :
                                 validate_config(disp, encoder, config_autoselect);

        for (auto [validate_flag, encoder_flag] : packet_deficiencies) {
          encoder.hevc[encoder_flag] = (max_ref_frames_hevc & validate_flag && autoselect_hevc & validate_flag);
        }

        encoder.hevc[encoder_t::REF_FRAMES_RESTRICT] = max_ref_frames_hevc >= 0;
        encoder.hevc[encoder_t::PASSED] = max_ref_frames_hevc >= 0 || autoselect_hevc >= 0;
      } else {
        BOOST_LOG(info) << "Encoder ["sv << encoder.hevc.name << "] is not supported on this GPU"sv;
        encoder.hevc.capabilities.reset();
      }
    } else {
      // Clear all cap bits for HEVC if we didn't probe it
      encoder.hevc.capabilities.reset();
    }

    if (test_av1) {
      config_max_ref_frames.videoFormat = 2;
      config_autoselect.videoFormat = 2;

      if (disp->is_codec_supported(encoder.av1.name, config_autoselect)) {
        auto max_ref_frames_av1 = validate_config(disp, encoder, config_max_ref_frames);

        // If H.264 succeeded with max ref frames specified, assume that we can count on
        // AV1 to also succeed with max ref frames specified if AV1 is supported.
        auto autoselect_av1 = (max_ref_frames_av1 >= 0 || max_ref_frames_h264 >= 0) ?
                                max_ref_frames_av1 :
                                validate_config(disp, encoder, config_autoselect);

        for (auto [validate_flag, encoder_flag] : packet_deficiencies) {
          encoder.av1[encoder_flag] = (max_ref_frames_av1 & validate_flag && autoselect_av1 & validate_flag);
        }

        encoder.av1[encoder_t::REF_FRAMES_RESTRICT] = max_ref_frames_av1 >= 0;
        encoder.av1[encoder_t::PASSED] = max_ref_frames_av1 >= 0 || autoselect_av1 >= 0;
      } else {
        BOOST_LOG(info) << "Encoder ["sv << encoder.av1.name << "] is not supported on this GPU"sv;
        encoder.av1.capabilities.reset();
      }
    } else {
      // Clear all cap bits for AV1 if we didn't probe it
      encoder.av1.capabilities.reset();
    }

    // Test HDR and YUV444 support
    {
      // H.264 is special because encoders may support YUV 4:4:4 without supporting 10-bit color depth
      if (encoder.flags & YUV444_SUPPORT) {
        config_t config_h264_yuv444 {1920, 1080, 60, 1000, 1, 0, 1, 0, 0, 1};
        encoder.h264[encoder_t::YUV444] = disp->is_codec_supported(encoder.h264.name, config_h264_yuv444) &&
                                          validate_config(disp, encoder, config_h264_yuv444) >= 0;
      } else {
        encoder.h264[encoder_t::YUV444] = false;
      }

      const config_t generic_hdr_config = {1920, 1080, 60, 1000, 1, 0, 3, 1, 1, 0};

      // Reset the display since we're switching from SDR to HDR
      reset_display(disp, encoder.platform_formats->dev_type, output_name, generic_hdr_config);
      if (!disp) {
        return false;
      }

      auto test_hdr_and_yuv444 = [&](auto &flag_map, auto video_format) {
        auto config = generic_hdr_config;
        config.videoFormat = video_format;

        if (!flag_map[encoder_t::PASSED]) {
          return;
        }

        auto encoder_codec_name = encoder.codec_from_config(config).name;

        // Test 4:4:4 HDR first. If 4:4:4 is supported, 4:2:0 should also be supported.
        config.chromaSamplingType = 1;
        if ((encoder.flags & YUV444_SUPPORT) &&
            disp->is_codec_supported(encoder_codec_name, config) &&
            validate_config(disp, encoder, config) >= 0) {
          flag_map[encoder_t::DYNAMIC_RANGE] = true;
          flag_map[encoder_t::YUV444] = true;
          return;
        } else {
          flag_map[encoder_t::YUV444] = false;
        }

        // Test 4:2:0 HDR
        config.chromaSamplingType = 0;
        if (disp->is_codec_supported(encoder_codec_name, config) &&
            validate_config(disp, encoder, config) >= 0) {
          flag_map[encoder_t::DYNAMIC_RANGE] = true;
        } else {
          flag_map[encoder_t::DYNAMIC_RANGE] = false;
        }
      };

      // HDR is not supported with H.264. Don't bother even trying it.
      encoder.h264[encoder_t::DYNAMIC_RANGE] = false;

      test_hdr_and_yuv444(encoder.hevc, 1);
      test_hdr_and_yuv444(encoder.av1, 2);
    }

    encoder.h264[encoder_t::VUI_PARAMETERS] = encoder.h264[encoder_t::VUI_PARAMETERS] && !config::runtime.flags[config::flag::FORCE_VIDEO_HEADER_REPLACE];
    encoder.hevc[encoder_t::VUI_PARAMETERS] = encoder.hevc[encoder_t::VUI_PARAMETERS] && !config::runtime.flags[config::flag::FORCE_VIDEO_HEADER_REPLACE];

    if (!encoder.h264[encoder_t::VUI_PARAMETERS]) {
      BOOST_LOG(warning) << encoder.name << ": h264 missing sps->vui parameters"sv;
    }
    if (encoder.hevc[encoder_t::PASSED] && !encoder.hevc[encoder_t::VUI_PARAMETERS]) {
      BOOST_LOG(warning) << encoder.name << ": hevc missing sps->vui parameters"sv;
    }

    fg.disable();
    return true;
  }

  int probe_encoders() {
    if (!allow_encoder_probing()) {
      // Error already logged
      return -1;
    }

    auto encoder_list = encoders;

    // If we already have a good encoder, check to see if another probe is required
    if (chosen_encoder && !(chosen_encoder->flags & ALWAYS_REPROBE) && !platf::needs_encoder_reenumeration()) {
      return 0;
    }

#ifdef __APPLE__
    auto *bridge_encoder = &videotoolbox;
    chosen_encoder = bridge_encoder;
    active_hevc_mode = config::video.hevc_mode == 0 ? 3 : config::video.hevc_mode;
    active_av1_mode = 1;
    last_encoder_probe_supported_ref_frames_invalidation = false;
    last_encoder_probe_supported_yuv444_for_codec = {false, false, false};

    bridge_encoder->h264.capabilities.reset();
    bridge_encoder->hevc.capabilities.reset();
    bridge_encoder->av1.capabilities.reset();

    bridge_encoder->h264[encoder_t::PASSED] = true;
    bridge_encoder->h264[encoder_t::VUI_PARAMETERS] = true;
    bridge_encoder->h264[encoder_t::REF_FRAMES_RESTRICT] = false;
    bridge_encoder->h264[encoder_t::DYNAMIC_RANGE] = false;
    bridge_encoder->h264[encoder_t::YUV444] = false;

    bridge_encoder->hevc[encoder_t::PASSED] = true;
    bridge_encoder->hevc[encoder_t::VUI_PARAMETERS] = true;
    bridge_encoder->hevc[encoder_t::REF_FRAMES_RESTRICT] = false;
    bridge_encoder->hevc[encoder_t::DYNAMIC_RANGE] = true;
    bridge_encoder->hevc[encoder_t::YUV444] = false;

    BOOST_LOG(info) << "Using Lumen macOS bridge encoder path backed by MacDisplayKit"sv;
    BOOST_LOG(info) << "Found H.264 encoder: "sv << bridge_encoder->h264.name << " ["sv << bridge_encoder->name << ']';
    BOOST_LOG(info) << "Found HEVC encoder: "sv << bridge_encoder->hevc.name << " ["sv << bridge_encoder->name << ']';
    return 0;
#else

    // Restart encoder selection
    auto previous_encoder = chosen_encoder;
    chosen_encoder = nullptr;
    active_hevc_mode = config::video.hevc_mode;
    active_av1_mode = config::video.av1_mode;
    last_encoder_probe_supported_ref_frames_invalidation = false;

    auto adjust_encoder_constraints = [&](encoder_t *encoder) {
      // If we can't satisfy both the encoder and codec requirement, prefer the encoder over codec support
      if (active_hevc_mode == 3 && !encoder->hevc[encoder_t::DYNAMIC_RANGE]) {
        BOOST_LOG(warning) << "Encoder ["sv << encoder->name << "] does not support HEVC Main10 on this system"sv;
        active_hevc_mode = 0;
      } else if (active_hevc_mode == 2 && !encoder->hevc[encoder_t::PASSED]) {
        BOOST_LOG(warning) << "Encoder ["sv << encoder->name << "] does not support HEVC on this system"sv;
        active_hevc_mode = 0;
      }

      if (active_av1_mode == 3 && !encoder->av1[encoder_t::DYNAMIC_RANGE]) {
        BOOST_LOG(warning) << "Encoder ["sv << encoder->name << "] does not support AV1 Main10 on this system"sv;
        active_av1_mode = 0;
      } else if (active_av1_mode == 2 && !encoder->av1[encoder_t::PASSED]) {
        BOOST_LOG(warning) << "Encoder ["sv << encoder->name << "] does not support AV1 on this system"sv;
        active_av1_mode = 0;
      }
    };

    if (!config::video.encoder.empty()) {
      // If there is a specific encoder specified, use it if it passes validation
      KITTY_WHILE_LOOP(auto pos = std::begin(encoder_list), pos != std::end(encoder_list), {
        auto encoder = *pos;

        if (encoder->name == config::video.encoder) {
          // Remove the encoder from the list entirely if it fails validation
          if (!validate_encoder(*encoder, previous_encoder && previous_encoder != encoder)) {
            pos = encoder_list.erase(pos);
            break;
          }

          // We will return an encoder here even if it fails one of the codec requirements specified by the user
          adjust_encoder_constraints(encoder);

          chosen_encoder = encoder;
          break;
        }

        pos++;
      });

      if (chosen_encoder == nullptr) {
        BOOST_LOG(error) << "Couldn't find any working encoder matching ["sv << config::video.encoder << ']';
      }
    }

    BOOST_LOG(info) << "// Testing for available encoders, this may generate errors. You can safely ignore those errors. //"sv;

    // If we haven't found an encoder yet, but we want one with specific codec support, search for that now.
    if (chosen_encoder == nullptr && (active_hevc_mode >= 2 || active_av1_mode >= 2)) {
      KITTY_WHILE_LOOP(auto pos = std::begin(encoder_list), pos != std::end(encoder_list), {
        auto encoder = *pos;

        // Remove the encoder from the list entirely if it fails validation
        if (!validate_encoder(*encoder, previous_encoder && previous_encoder != encoder)) {
          pos = encoder_list.erase(pos);
          continue;
        }

        // Skip it if it doesn't support the specified codec at all
        if ((active_hevc_mode >= 2 && !encoder->hevc[encoder_t::PASSED]) ||
            (active_av1_mode >= 2 && !encoder->av1[encoder_t::PASSED])) {
          pos++;
          continue;
        }

        // Skip it if it doesn't support HDR on the specified codec
        if ((active_hevc_mode == 3 && !encoder->hevc[encoder_t::DYNAMIC_RANGE]) ||
            (active_av1_mode == 3 && !encoder->av1[encoder_t::DYNAMIC_RANGE])) {
          pos++;
          continue;
        }

        chosen_encoder = encoder;
        break;
      });

      if (chosen_encoder == nullptr) {
        BOOST_LOG(error) << "Couldn't find any working encoder that meets HEVC/AV1 requirements"sv;
      }
    }

    // If no encoder was specified or the specified encoder was unusable, keep trying
    // the remaining encoders until we find one that passes validation.
    if (chosen_encoder == nullptr) {
      KITTY_WHILE_LOOP(auto pos = std::begin(encoder_list), pos != std::end(encoder_list), {
        auto encoder = *pos;

        // If we've used a previous encoder and it's not this one, we expect this encoder to
        // fail to validate. It will use a slightly different order of checks to more quickly
        // eliminate failing encoders.
        if (!validate_encoder(*encoder, previous_encoder && previous_encoder != encoder)) {
          pos = encoder_list.erase(pos);
          continue;
        }

        // We will return an encoder here even if it fails one of the codec requirements specified by the user
        adjust_encoder_constraints(encoder);

        chosen_encoder = encoder;
        break;
      });
    }

    if (chosen_encoder == nullptr) {
      const auto output_name {display_device::map_output_name(config::video.output_name)};
      BOOST_LOG(fatal) << "Unable to find display or encoder during startup."sv;
      if (!config::video.adapter_name.empty() || !output_name.empty()) {
        BOOST_LOG(fatal) << "Please ensure your manually chosen GPU and monitor are connected and powered on."sv;
      } else {
        BOOST_LOG(fatal) << "Please check that a display is connected and powered on."sv;
      }
      return -1;
    }

    BOOST_LOG(info);
    BOOST_LOG(info) << "// Ignore any errors mentioned above, they are not relevant. //"sv;
    BOOST_LOG(info);

    auto &encoder = *chosen_encoder;

    last_encoder_probe_supported_ref_frames_invalidation = (encoder.flags & REF_FRAMES_INVALIDATION);
    last_encoder_probe_supported_yuv444_for_codec[0] = encoder.h264[encoder_t::PASSED] &&
                                                       encoder.h264[encoder_t::YUV444];
    last_encoder_probe_supported_yuv444_for_codec[1] = encoder.hevc[encoder_t::PASSED] &&
                                                       encoder.hevc[encoder_t::YUV444];
    last_encoder_probe_supported_yuv444_for_codec[2] = encoder.av1[encoder_t::PASSED] &&
                                                       encoder.av1[encoder_t::YUV444];

    BOOST_LOG(debug) << "------  h264 ------"sv;
    for (int x = 0; x < encoder_t::MAX_FLAGS; ++x) {
      auto flag = (encoder_t::flag_e) x;
      BOOST_LOG(debug) << encoder_t::from_flag(flag) << (encoder.h264[flag] ? ": supported"sv : ": unsupported"sv);
    }
    BOOST_LOG(debug) << "-------------------"sv;
    BOOST_LOG(info) << "Found H.264 encoder: "sv << encoder.h264.name << " ["sv << encoder.name << ']';

    if (encoder.hevc[encoder_t::PASSED]) {
      BOOST_LOG(debug) << "------  hevc ------"sv;
      for (int x = 0; x < encoder_t::MAX_FLAGS; ++x) {
        auto flag = (encoder_t::flag_e) x;
        BOOST_LOG(debug) << encoder_t::from_flag(flag) << (encoder.hevc[flag] ? ": supported"sv : ": unsupported"sv);
      }
      BOOST_LOG(debug) << "-------------------"sv;

      BOOST_LOG(info) << "Found HEVC encoder: "sv << encoder.hevc.name << " ["sv << encoder.name << ']';
    }

    if (encoder.av1[encoder_t::PASSED]) {
      BOOST_LOG(debug) << "------  av1 ------"sv;
      for (int x = 0; x < encoder_t::MAX_FLAGS; ++x) {
        auto flag = (encoder_t::flag_e) x;
        BOOST_LOG(debug) << encoder_t::from_flag(flag) << (encoder.av1[flag] ? ": supported"sv : ": unsupported"sv);
      }
      BOOST_LOG(debug) << "-------------------"sv;

      BOOST_LOG(info) << "Found AV1 encoder: "sv << encoder.av1.name << " ["sv << encoder.name << ']';
    }

    if (active_hevc_mode == 0) {
      active_hevc_mode = encoder.hevc[encoder_t::PASSED] ? (encoder.hevc[encoder_t::DYNAMIC_RANGE] ? 3 : 2) : 1;
    }

    if (active_av1_mode == 0) {
      active_av1_mode = encoder.av1[encoder_t::PASSED] ? (encoder.av1[encoder_t::DYNAMIC_RANGE] ? 3 : 2) : 1;
    }

    return 0;
#endif
  }

  // Linux only declaration
  typedef int (*vaapi_init_avcodec_hardware_input_buffer_fn)(platf::avcodec_encode_device_t *encode_device, AVBufferRef **hw_device_buf);

  util::Either<avcodec_buffer_t, int> vaapi_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *encode_device) {
    avcodec_buffer_t hw_device_buf;

    // If an egl hwdevice
    if (encode_device->data) {
      if (((vaapi_init_avcodec_hardware_input_buffer_fn) encode_device->data)(encode_device, &hw_device_buf)) {
        return -1;
      }

      return hw_device_buf;
    }

    auto render_device = config::video.adapter_name.empty() ? nullptr : config::video.adapter_name.c_str();

    auto status = av_hwdevice_ctx_create(&hw_device_buf, AV_HWDEVICE_TYPE_VAAPI, render_device, nullptr, 0);
    if (status < 0) {
      char string[AV_ERROR_MAX_STRING_SIZE];
      BOOST_LOG(error) << "Failed to create a VAAPI device: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
      return -1;
    }

    return hw_device_buf;
  }

  util::Either<avcodec_buffer_t, int> cuda_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *encode_device) {
    avcodec_buffer_t hw_device_buf;

    auto status = av_hwdevice_ctx_create(&hw_device_buf, AV_HWDEVICE_TYPE_CUDA, nullptr, nullptr, 1 /* AV_CUDA_USE_PRIMARY_CONTEXT */);
    if (status < 0) {
      char string[AV_ERROR_MAX_STRING_SIZE];
      BOOST_LOG(error) << "Failed to create a CUDA device: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
      return -1;
    }

    return hw_device_buf;
  }

  util::Either<avcodec_buffer_t, int> vt_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *encode_device) {
    avcodec_buffer_t hw_device_buf;

    auto status = av_hwdevice_ctx_create(&hw_device_buf, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0);
    if (status < 0) {
      char string[AV_ERROR_MAX_STRING_SIZE];
      BOOST_LOG(error) << "Failed to create a VideoToolbox device: "sv << av_make_error_string(string, AV_ERROR_MAX_STRING_SIZE, status);
      return -1;
    }

    return hw_device_buf;
  }

#ifdef _WIN32
}

void do_nothing(void *) {
}

namespace video {
  util::Either<avcodec_buffer_t, int> dxgi_init_avcodec_hardware_input_buffer(platf::avcodec_encode_device_t *encode_device) {
    avcodec_buffer_t ctx_buf {av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA)};
    auto ctx = (AVD3D11VADeviceContext *) ((AVHWDeviceContext *) ctx_buf->data)->hwctx;

    std::fill_n((std::uint8_t *) ctx, sizeof(AVD3D11VADeviceContext), 0);

    auto device = (ID3D11Device *) encode_device->data;

    device->AddRef();
    ctx->device = device;

    ctx->lock_ctx = (void *) 1;
    ctx->lock = do_nothing;
    ctx->unlock = do_nothing;

    auto err = av_hwdevice_ctx_init(ctx_buf.get());
    if (err) {
      char err_str[AV_ERROR_MAX_STRING_SIZE] {0};
      BOOST_LOG(error) << "Failed to create FFMpeg hardware device context: "sv << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, err);

      return err;
    }

    return ctx_buf;
  }
#endif

  int start_capture_async(capture_thread_async_ctx_t &capture_thread_ctx) {
    capture_thread_ctx.encoder_p = chosen_encoder;
    capture_thread_ctx.reinit_event.reset();

    capture_thread_ctx.capture_ctx_queue = std::make_shared<safe::queue_t<capture_ctx_t>>(30);

    capture_thread_ctx.capture_thread = std::thread {
      captureThread,
      capture_thread_ctx.capture_ctx_queue,
      std::ref(capture_thread_ctx.display_wp),
      std::ref(capture_thread_ctx.reinit_event),
      std::ref(*capture_thread_ctx.encoder_p)
    };

    return 0;
  }

  void end_capture_async(capture_thread_async_ctx_t &capture_thread_ctx) {
    capture_thread_ctx.capture_ctx_queue->stop();
    if (auto display = capture_thread_ctx.display_wp->lock()) {
      display->interrupt();
    }

    capture_thread_ctx.capture_thread.join();
  }

  int start_capture_sync(capture_thread_sync_ctx_t &ctx) {
    std::thread {&captureThreadSync}.detach();
    return 0;
  }

  void end_capture_sync(capture_thread_sync_ctx_t &ctx) {
  }

  platf::mem_type_e map_base_dev_type(AVHWDeviceType type) {
    switch (type) {
      case AV_HWDEVICE_TYPE_D3D11VA:
        return platf::mem_type_e::dxgi;
      case AV_HWDEVICE_TYPE_VAAPI:
        return platf::mem_type_e::vaapi;
      case AV_HWDEVICE_TYPE_CUDA:
        return platf::mem_type_e::cuda;
      case AV_HWDEVICE_TYPE_NONE:
        return platf::mem_type_e::system;
      case AV_HWDEVICE_TYPE_VIDEOTOOLBOX:
        return platf::mem_type_e::videotoolbox;
      default:
        return platf::mem_type_e::unknown;
    }

    return platf::mem_type_e::unknown;
  }

  platf::pix_fmt_e map_pix_fmt(AVPixelFormat fmt) {
    switch (fmt) {
      case AV_PIX_FMT_VUYX:
        return platf::pix_fmt_e::ayuv;
      case AV_PIX_FMT_XV30:
        return platf::pix_fmt_e::y410;
      case AV_PIX_FMT_YUV420P10:
        return platf::pix_fmt_e::yuv420p10;
      case AV_PIX_FMT_YUV420P:
        return platf::pix_fmt_e::yuv420p;
      case AV_PIX_FMT_NV12:
        return platf::pix_fmt_e::nv12;
      case AV_PIX_FMT_P010:
        return platf::pix_fmt_e::p010;
      default:
        return platf::pix_fmt_e::unknown;
    }

    return platf::pix_fmt_e::unknown;
  }

}  // namespace video
