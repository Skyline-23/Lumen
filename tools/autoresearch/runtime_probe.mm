#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <LumenCore/LumenCore.h>
#import <LumenMacBridge/LumenMacBridge.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

namespace {

constexpr int32_t kDisplayP3Gamut = 1;
constexpr int32_t kPQTransfer = 2;

LumenCoreCaptureCodec codecFromArgument(const char *value) {
  if (value == nullptr) {
    return LumenCoreCaptureCodecHEVC;
  }

  if (std::strcmp(value, "h264") == 0) {
    return LumenCoreCaptureCodecH264;
  }
  if (std::strcmp(value, "prores-proxy") == 0) {
    return LumenCoreCaptureCodecProResProxy;
  }

  return LumenCoreCaptureCodecHEVC;
}

const char *codecName(LumenCoreCaptureCodec codec) {
  switch (codec) {
    case LumenCoreCaptureCodecH264:
      return "h264";
    case LumenCoreCaptureCodecProResProxy:
      return "prores-proxy";
    case LumenCoreCaptureCodecHEVC:
      return "hevc";
    default:
      return "unknown";
  }
}

struct ProbeMetrics {
  uint64_t frames = 0;
  uint64_t hdrFrames = 0;
  bool firstFrameSeen = false;
  bool firstFrameHDR = false;
  double startupMilliseconds = -1.0;
  uint64_t restartEvents = 0;
  uint64_t failureEvents = 0;
  uint64_t dropEvents = 0;
  uint64_t queuedFrames = 0;
  uint64_t droppedFrames = 0;
  uint64_t lastSeq = 0;
  bool lastHDRSignaled = false;
  std::vector<double> callbackLatencies;
};

double averageLatency(const std::vector<double> &samples) {
  if (samples.empty()) {
    return 0.0;
  }
  double total = 0.0;
  for (double sample : samples) {
    total += sample;
  }
  return total / static_cast<double>(samples.size());
}

double maxLatency(const std::vector<double> &samples) {
  if (samples.empty()) {
    return 0.0;
  }
  return *std::max_element(samples.begin(), samples.end());
}

bool selectiveHDROverlayActive(uint32_t displayID) {
  NSScreen *matchedScreen = nil;
  for (NSScreen *screen in NSScreen.screens) {
    NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
    if (screenNumber != nil && static_cast<uint32_t>(screenNumber.unsignedIntValue) == displayID) {
      matchedScreen = screen;
      break;
    }
  }

  if (matchedScreen == nil) {
    return false;
  }

  if (@available(macOS 10.11, *)) {
    constexpr CGFloat kExternalCaptureHDREDRThreshold = 1.05;
    CGFloat effectiveEDR = matchedScreen.maximumExtendedDynamicRangeColorComponentValue;
    if (@available(macOS 10.15, *)) {
      effectiveEDR = std::max(
        effectiveEDR,
        matchedScreen.maximumPotentialExtendedDynamicRangeColorComponentValue
      );
    }
    return effectiveEDR > kExternalCaptureHDREDRThreshold;
  }

  return false;
}

void drainForwardedFrames(
  LumenMacBridgeController *controller,
  ProbeMetrics &metrics,
  bool selectiveOverlayTransport,
  bool overlayHDRActive
) {
  while (true) {
    CMSampleBufferRef sampleBuffer = nullptr;
    LumenCoreEncodedCaptureFrameRecord record =
      LumenMacBridgeControllerPopNextForwardedFrame(controller, &sampleBuffer);
    if (sampleBuffer != nullptr) {
      CFRelease(sampleBuffer);
    }
    if (!record.has_value) {
      break;
    }

    const bool effectiveHDRSignaled =
      selectiveOverlayTransport ? overlayHDRActive : record.is_hdr_signaled;

    metrics.frames += 1;
    if (!metrics.firstFrameSeen) {
      metrics.firstFrameSeen = true;
      metrics.firstFrameHDR = effectiveHDRSignaled;
    }
    if (effectiveHDRSignaled) {
      metrics.hdrFrames += 1;
    }
    metrics.lastSeq = record.source_sequence_number;
    metrics.lastHDRSignaled = effectiveHDRSignaled;
    if (record.has_output_callback_latency_milliseconds) {
      metrics.callbackLatencies.push_back(record.output_callback_latency_milliseconds);
    }
  }
}

void drainForwardedEvents(LumenMacBridgeController *controller, ProbeMetrics &metrics) {
  char message[1024];
  while (true) {
    std::memset(message, 0, sizeof(message));
    LumenCoreEncodedCaptureEventRecord record =
      LumenMacBridgeControllerPopNextForwardedEvent(controller, message, sizeof(message));
    if (!record.has_value) {
      break;
    }
    switch (record.kind) {
      case LumenCoreCaptureEventKindRestarted:
        metrics.restartEvents += 1;
        break;
      case LumenCoreCaptureEventKindFailed:
        metrics.failureEvents += 1;
        break;
      case LumenCoreCaptureEventKindDroppedFrame:
        metrics.dropEvents += 1;
        break;
      default:
        break;
    }
  }
}

void printErrorAndExit(const char *message) {
  std::printf("AUTORESEARCH_RUNTIME_PROBE_STATUS=error\n");
  std::printf("AUTORESEARCH_RUNTIME_PROBE_ERROR=%s\n", message);
  std::fflush(stdout);
}

}  // namespace

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 4) {
      printErrorAndExit("usage: runtime_probe <width> <height> <fps> [codec]");
      return 1;
    }

    int32_t width = std::atoi(argv[1]);
    int32_t height = std::atoi(argv[2]);
    int32_t fps = std::atoi(argv[3]);
    LumenCoreCaptureCodec codec = codecFromArgument(argc >= 5 ? argv[4] : nullptr);
    uint32_t displayID = CGMainDisplayID();

    LumenMacBridgeController *controller = LumenMacBridgeControllerCreate();
    if (controller == nullptr) {
      printErrorAndExit("failed to create bridge controller");
      return 1;
    }

    LumenMacBridgeControllerConfigureCoreForwarding(controller, 512, 64);

    LumenMacBridgeCaptureConfiguration configuration =
      LumenMacBridgeControllerMakePanelNativeConfiguration(displayID);
    configuration.display_id = displayID;
    configuration.codec = codec;
    configuration.target_frame_rate = fps;
    configuration.requested_width = width;
    configuration.requested_height = height;
    configuration.sink_request.capability.gamut = kDisplayP3Gamut;
    configuration.sink_request.capability.transfer = kPQTransfer;
    configuration.sink_request.capability.supports_frame_gated_hdr = true;
    configuration.sink_request.capability.supports_hdr_tile_overlay = true;
    configuration.sink_request.capability.supports_per_frame_hdr_metadata = true;
    configuration.sink_request.dynamic_range_transport =
      LumenCoreDynamicRangeTransportSDRBaseHDROverlay;
    configuration.effective_display_state.gamut = kDisplayP3Gamut;
    configuration.effective_display_state.transfer = kPQTransfer;

    char errorBuffer[1024];
    std::memset(errorBuffer, 0, sizeof(errorBuffer));
    if (!LumenMacBridgeControllerStartMacDisplayKitCapture(
          controller,
          configuration,
          errorBuffer,
          sizeof(errorBuffer))) {
      printErrorAndExit(errorBuffer[0] == '\0' ? "capture start failed" : errorBuffer);
      LumenMacBridgeControllerDestroy(controller);
      return 1;
    }

    ProbeMetrics metrics;
    const bool selectiveOverlayTransport =
      configuration.sink_request.dynamic_range_transport ==
      LumenCoreDynamicRangeTransportSDRBaseHDROverlay;
    const auto captureStartTime = std::chrono::steady_clock::now();
    const auto startupDeadline = captureStartTime + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < startupDeadline && !metrics.firstFrameSeen) {
      drainForwardedFrames(
        controller,
        metrics,
        selectiveOverlayTransport,
        selectiveHDROverlayActive(displayID)
      );
      drainForwardedEvents(controller, metrics);
      if (metrics.firstFrameSeen && metrics.startupMilliseconds < 0.0) {
        metrics.startupMilliseconds = std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - captureStartTime
        ).count();
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    if (metrics.firstFrameSeen) {
      const auto sampleDeadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1000);
      while (std::chrono::steady_clock::now() < sampleDeadline) {
        drainForwardedFrames(
          controller,
          metrics,
          selectiveOverlayTransport,
          selectiveHDROverlayActive(displayID)
        );
        drainForwardedEvents(controller, metrics);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
    }

    drainForwardedFrames(
      controller,
      metrics,
      selectiveOverlayTransport,
      selectiveHDROverlayActive(displayID)
    );
    drainForwardedEvents(controller, metrics);
    if (metrics.firstFrameSeen && metrics.startupMilliseconds < 0.0) {
      metrics.startupMilliseconds = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - captureStartTime
      ).count();
    }

    LumenCoreEncodedCaptureIngressSnapshot snapshot =
      LumenMacBridgeControllerCopyCoreForwardingSnapshot(controller);

    metrics.queuedFrames = snapshot.queued_frame_count;
    metrics.droppedFrames = snapshot.dropped_frame_count;
    if (snapshot.has_last_frame) {
      metrics.lastSeq = snapshot.last_frame_source_sequence_number;
      metrics.lastHDRSignaled =
        selectiveOverlayTransport ?
          selectiveHDROverlayActive(displayID) :
          snapshot.last_frame_is_hdr_signaled;
    }

    LumenMacBridgeControllerStopMacDisplayKitCapture(controller);
    LumenMacBridgeControllerDestroy(controller);

    std::printf("AUTORESEARCH_RUNTIME_PROBE_STATUS=ok\n");
    std::printf("AUTORESEARCH_RUNTIME_PROBE_WIDTH=%d\n", width);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_HEIGHT=%d\n", height);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_FPS=%d\n", fps);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_CODEC=%s\n", codecName(codec));
    std::printf("AUTORESEARCH_RUNTIME_PROBE_FRAMES=%llu\n", metrics.frames);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_HDR_FRAMES=%llu\n", metrics.hdrFrames);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_FIRST_FRAME_HDR=%d\n", metrics.firstFrameHDR ? 1 : 0);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_STARTUP_MS=%.3f\n", metrics.startupMilliseconds);
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_AVG_CALLBACK_LATENCY_MS=%.3f\n",
      averageLatency(metrics.callbackLatencies)
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_MAX_CALLBACK_LATENCY_MS=%.3f\n",
      maxLatency(metrics.callbackLatencies)
    );
    std::printf("AUTORESEARCH_RUNTIME_PROBE_RESTART_EVENTS=%llu\n", metrics.restartEvents);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_FAILURE_EVENTS=%llu\n", metrics.failureEvents);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_DROP_EVENTS=%llu\n", metrics.dropEvents);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_QUEUED_FRAMES=%llu\n", metrics.queuedFrames);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_DROPPED_FRAMES=%llu\n", metrics.droppedFrames);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_LAST_SEQ=%llu\n", metrics.lastSeq);
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_LAST_HDR_SIGNALLED=%d\n",
      metrics.lastHDRSignaled ? 1 : 0
    );
    std::fflush(stdout);
    return 0;
  }
}
