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
#include <mach/mach_time.h>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

extern "C" bool LumenMacBridgeControllerCopyCaptureDiagnostics(
  LumenMacBridgeController *controller,
  char *diagnostics_destination,
  size_t diagnostics_capacity
);

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
  uint64_t frameRecords = 0;
  uint64_t tiledFrameRecords = 0;
  uint64_t completeFrameGroups = 0;
  uint64_t tileFreshCompositeUpdates = 0;
  uint64_t tileFreshCompositeWithinFrameBudget = 0;
  uint64_t tileFreshCompositeWithinTwoFrameBudget = 0;
  uint64_t tileReceiverArbitratedOneFrameUpdates = 0;
  uint64_t tileReceiverArbitratedTwoFrameUpdates = 0;
  uint64_t tileReceiverArbitratedThreeFrameUpdates = 0;
  uint64_t tileReceiverArbitratedFourFrameUpdates = 0;
  uint64_t tileReceiverArbitratedOneFrameHeldUpdates = 0;
  uint64_t tileReceiverArbitratedTwoFrameHeldUpdates = 0;
  uint64_t tileReceiverArbitratedThreeFrameHeldUpdates = 0;
  uint64_t tileReceiverArbitratedFourFrameHeldUpdates = 0;
  double tileReceiverArbitratedTwoFrameMaxSkewMilliseconds = 0.0;
  uint64_t tileArrivalTransitions = 0;
  uint64_t tileArrivalSameTileRuns = 0;
  uint64_t tileArrivalLongestSameTileRun = 0;
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
  uint32_t maxTileCount = 1;
  uint32_t maxEncodedLaneCount = 1;
  std::vector<double> callbackLatencies;
};

struct TileGroupProgress {
  uint32_t expectedTileCount = 1;
  bool isHDRSignaled = false;
  bool isComplete = false;
  std::unordered_set<uint32_t> observedTileIndexes;
};

struct TileFreshCompositeProgress {
  uint32_t expectedTileCount = 1;
  std::unordered_set<uint32_t> observedTileIndexes;
  std::unordered_map<uint32_t, uint64_t> latestDisplayTimeByTile;
};

struct TileReceiverArbitrationPolicy {
  double budgetMilliseconds = 0.0;
  uint64_t presentedUpdates = 0;
  uint64_t heldUpdates = 0;
  double maxPresentedSkewMilliseconds = 0.0;
  uint32_t expectedTileCount = 1;
  std::unordered_set<uint32_t> observedTileIndexes;
  std::unordered_map<uint32_t, uint64_t> pendingDisplayTimeByTile;
  std::unordered_map<uint32_t, bool> pendingHDRByTile;
  std::unordered_map<uint32_t, uint64_t> displayedDisplayTimeByTile;
  std::unordered_map<uint32_t, bool> displayedHDRByTile;
};

struct TileReceiverArbitrationProgress {
  TileReceiverArbitrationPolicy oneFrame {8.333};
  TileReceiverArbitrationPolicy twoFrame {16.667};
  TileReceiverArbitrationPolicy threeFrame {25.0};
  TileReceiverArbitrationPolicy fourFrame {33.333};
};

struct TileArrivalProgress {
  bool hasLastTileIndex = false;
  uint32_t lastTileIndex = 0;
  uint64_t currentSameTileRun = 0;
};

double displayTimeDeltaMilliseconds(uint64_t delta) {
  static const mach_timebase_info_data_t timebase = [] {
    mach_timebase_info_data_t value {};
    mach_timebase_info(&value);
    return value;
  }();
  if (timebase.denom == 0) {
    return 0.0;
  }
  const double nanoseconds =
    (static_cast<double>(delta) * static_cast<double>(timebase.numer)) /
    static_cast<double>(timebase.denom);
  return nanoseconds / 1000000.0;
}

double tileSkewMilliseconds(const std::unordered_map<uint32_t, uint64_t> &displayTimes) {
  if (displayTimes.empty()) {
    return 0.0;
  }
  uint64_t minDisplayTime = UINT64_MAX;
  uint64_t maxDisplayTime = 0;
  for (const auto &entry : displayTimes) {
    minDisplayTime = std::min(minDisplayTime, entry.second);
    maxDisplayTime = std::max(maxDisplayTime, entry.second);
  }
  return displayTimeDeltaMilliseconds(maxDisplayTime >= minDisplayTime ? maxDisplayTime - minDisplayTime : 0);
}

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

uint64_t tileGroupKey(const LumenCoreEncodedCaptureFrameRecord &record) {
  if (record.tile_metadata.frame_group_id != 0) {
    return record.tile_metadata.frame_group_id;
  }
  return record.source_sequence_number;
}

bool tryPresentPendingTile(TileReceiverArbitrationPolicy &policy, uint32_t tileIndex) {
  const auto pendingEntry = policy.pendingDisplayTimeByTile.find(tileIndex);
  if (pendingEntry == policy.pendingDisplayTimeByTile.end()) {
    return false;
  }
  const auto displayedEntry = policy.displayedDisplayTimeByTile.find(tileIndex);
  if (displayedEntry != policy.displayedDisplayTimeByTile.end() &&
      displayedEntry->second == pendingEntry->second) {
    policy.pendingDisplayTimeByTile.erase(pendingEntry);
    policy.pendingHDRByTile.erase(tileIndex);
    return true;
  }

  auto candidate = policy.displayedDisplayTimeByTile;
  candidate[tileIndex] = pendingEntry->second;
  if (candidate.size() < static_cast<size_t>(policy.expectedTileCount)) {
    return false;
  }
  const double candidateSkewMilliseconds = tileSkewMilliseconds(candidate);
  if (candidateSkewMilliseconds > policy.budgetMilliseconds) {
    return false;
  }

  policy.displayedDisplayTimeByTile[tileIndex] = pendingEntry->second;
  const auto pendingHDREntry = policy.pendingHDRByTile.find(tileIndex);
  policy.displayedHDRByTile[tileIndex] =
    pendingHDREntry != policy.pendingHDRByTile.end() && pendingHDREntry->second;
  policy.pendingDisplayTimeByTile.erase(tileIndex);
  policy.pendingHDRByTile.erase(tileIndex);
  policy.presentedUpdates += 1;
  policy.maxPresentedSkewMilliseconds =
    std::max(policy.maxPresentedSkewMilliseconds, candidateSkewMilliseconds);
  return true;
}

bool tryBootstrapPendingTiles(TileReceiverArbitrationPolicy &policy) {
  if (!policy.displayedDisplayTimeByTile.empty() ||
      policy.pendingDisplayTimeByTile.size() < static_cast<size_t>(policy.expectedTileCount)) {
    return false;
  }

  const double candidateSkewMilliseconds = tileSkewMilliseconds(policy.pendingDisplayTimeByTile);
  if (candidateSkewMilliseconds > policy.budgetMilliseconds) {
    return false;
  }

  for (const auto &entry : policy.pendingDisplayTimeByTile) {
    const uint32_t tileIndex = entry.first;
    policy.displayedDisplayTimeByTile[tileIndex] = entry.second;
    const auto pendingHDREntry = policy.pendingHDRByTile.find(tileIndex);
    policy.displayedHDRByTile[tileIndex] =
      pendingHDREntry != policy.pendingHDRByTile.end() && pendingHDREntry->second;
    policy.presentedUpdates += 1;
  }
  policy.pendingDisplayTimeByTile.clear();
  policy.pendingHDRByTile.clear();
  policy.maxPresentedSkewMilliseconds =
    std::max(policy.maxPresentedSkewMilliseconds, candidateSkewMilliseconds);
  return true;
}

void updateReceiverArbitrationPolicy(
  TileReceiverArbitrationPolicy &policy,
  const LumenCoreEncodedCaptureFrameRecord &record
) {
  policy.expectedTileCount = std::max(policy.expectedTileCount, record.tile_metadata.tile_count);
  policy.observedTileIndexes.insert(record.tile_metadata.tile_index);
  const bool hadPendingForTile =
    policy.pendingDisplayTimeByTile.find(record.tile_metadata.tile_index) !=
    policy.pendingDisplayTimeByTile.end();
  policy.pendingDisplayTimeByTile[record.tile_metadata.tile_index] = record.source_display_time;
  policy.pendingHDRByTile[record.tile_metadata.tile_index] = record.is_hdr_signaled;
  if (hadPendingForTile) {
    policy.heldUpdates += 1;
  }
  if (policy.observedTileIndexes.size() < static_cast<size_t>(policy.expectedTileCount)) {
    return;
  }
  if (tryBootstrapPendingTiles(policy)) {
    return;
  }

  bool presentedAny = true;
  while (presentedAny) {
    presentedAny = false;
    std::vector<uint32_t> pendingTileIndexes;
    pendingTileIndexes.reserve(policy.pendingDisplayTimeByTile.size());
    for (const auto &entry : policy.pendingDisplayTimeByTile) {
      pendingTileIndexes.push_back(entry.first);
    }
    std::sort(pendingTileIndexes.begin(), pendingTileIndexes.end());
    for (uint32_t tileIndex : pendingTileIndexes) {
      presentedAny = tryPresentPendingTile(policy, tileIndex) || presentedAny;
    }
  }
}

void updateReceiverArbitration(
  TileReceiverArbitrationProgress &arbitration,
  const LumenCoreEncodedCaptureFrameRecord &record
) {
  updateReceiverArbitrationPolicy(arbitration.oneFrame, record);
  updateReceiverArbitrationPolicy(arbitration.twoFrame, record);
  updateReceiverArbitrationPolicy(arbitration.threeFrame, record);
  updateReceiverArbitrationPolicy(arbitration.fourFrame, record);
}

void updateTileArrivalProgress(
  ProbeMetrics &metrics,
  TileArrivalProgress &arrival,
  uint32_t tileIndex
) {
  if (!arrival.hasLastTileIndex) {
    arrival.hasLastTileIndex = true;
    arrival.lastTileIndex = tileIndex;
    arrival.currentSameTileRun = 1;
    metrics.tileArrivalLongestSameTileRun =
      std::max(metrics.tileArrivalLongestSameTileRun, arrival.currentSameTileRun);
    return;
  }

  if (arrival.lastTileIndex == tileIndex) {
    arrival.currentSameTileRun += 1;
    metrics.tileArrivalSameTileRuns += 1;
  } else {
    metrics.tileArrivalTransitions += 1;
    arrival.lastTileIndex = tileIndex;
    arrival.currentSameTileRun = 1;
  }
  metrics.tileArrivalLongestSameTileRun =
    std::max(metrics.tileArrivalLongestSameTileRun, arrival.currentSameTileRun);
}

void countLogicalFrame(ProbeMetrics &metrics, bool isHDRSignaled) {
  metrics.frames += 1;
  if (!metrics.firstFrameSeen) {
    metrics.firstFrameSeen = true;
    metrics.firstFrameHDR = isHDRSignaled;
  }
  if (isHDRSignaled) {
    metrics.hdrFrames += 1;
  }
}

const char *trimLeadingSpaces(const char *value) {
  while (value != nullptr && (*value == ' ' || *value == '\t')) {
    value += 1;
  }
  return value;
}

void emitSelectedDiagnostics(const char *diagnostics) {
  if (diagnostics == nullptr || diagnostics[0] == '\0') {
    return;
  }

  struct DiagnosticEmission {
    const char *sourceKey;
    const char *probeKey;
  };
  static constexpr DiagnosticEmission emissions[] = {
    {"sourceBackend", "SOURCE_BACKEND"},
    {"rawPrivateDisplayStream", "RAW_PRIVATE_DISPLAY_STREAM"},
    {"rawPrivateDisplayStreamRequestedPixelFormat", "RAW_PRIVATE_DISPLAY_STREAM_REQUESTED_PIXEL_FORMAT"},
    {"rawPrivateDisplayStreamRequestedMatrix", "RAW_PRIVATE_DISPLAY_STREAM_REQUESTED_MATRIX"},
    {"skyLightSyntheticIdleReplay", "SKYLIGHT_SYNTHETIC_IDLE_REPLAY"},
    {"skyLightSyntheticIdleReplayIntervalMilliseconds", "SKYLIGHT_SYNTHETIC_IDLE_REPLAY_INTERVAL_MS"},
    {"skyLightPendingPolicy", "SKYLIGHT_PENDING_POLICY"},
    {"skyLightRecommendedPendingFrameCount", "SKYLIGHT_RECOMMENDED_PENDING_FRAME_COUNT"},
    {"sourceFrameCount", "SOURCE_FRAME_COUNT"},
    {"sourceDisplayDeltaCount", "SOURCE_DISPLAY_DELTA_COUNT"},
    {"sourceLastDisplayDeltaMilliseconds", "SOURCE_LAST_DISPLAY_DELTA_MS"},
    {"sourceMinDisplayDeltaMilliseconds", "SOURCE_MIN_DISPLAY_DELTA_MS"},
    {"sourceMaxDisplayDeltaMilliseconds", "SOURCE_MAX_DISPLAY_DELTA_MS"},
    {"sourceAverageDisplayDeltaMilliseconds", "SOURCE_AVG_DISPLAY_DELTA_MS"},
    {"sourceApproxFrameRate", "SOURCE_APPROX_FRAME_RATE"},
    {"sourceCadenceClassification", "SOURCE_CADENCE"},
    {"sourceReducedDirtySampleCount", "SOURCE_REDUCED_DIRTY_SAMPLE_COUNT"},
    {"sourceAverageReducedDirtyCoverageRatio", "SOURCE_AVG_REDUCED_DIRTY_COVERAGE_RATIO"},
    {"sourceMaxReducedDirtyCoverageRatio", "SOURCE_MAX_REDUCED_DIRTY_COVERAGE_RATIO"},
    {"sourceAverageReducedDirtyRectCount", "SOURCE_AVG_REDUCED_DIRTY_RECT_COUNT"},
    {"sourceMaxReducedDirtyRectCount", "SOURCE_MAX_REDUCED_DIRTY_RECT_COUNT"},
    {"sourceUpdateDropSampleCount", "SOURCE_UPDATE_DROP_SAMPLE_COUNT"},
    {"sourceAverageUpdateDropCount", "SOURCE_AVG_UPDATE_DROP_COUNT"},
    {"sourceMaxUpdateDropCount", "SOURCE_MAX_UPDATE_DROP_COUNT"},
    {"sourceHotPathDiagnostics", "SOURCE_HOT_PATH_DIAGNOSTICS"},
    {"privateCaptureSourcePixelFormat", "PRIVATE_CAPTURE_SOURCE_PIXEL_FORMAT"},
    {"privateCaptureRequestedPixelFormat", "PRIVATE_CAPTURE_REQUESTED_PIXEL_FORMAT"},
    {"privateCaptureExtendedRange", "PRIVATE_CAPTURE_EXTENDED_RANGE"},
    {"privateCaptureCursorComposition", "PRIVATE_CAPTURE_CURSOR_COMPOSITION"},
    {"privateCaptureSourceColorTransform", "PRIVATE_CAPTURE_SOURCE_COLOR_TRANSFORM"},
    {"videoToolboxUsingHardwareEncoder", "VT_USING_HARDWARE_ENCODER"},
    {"videoToolboxRecommendedParallelizationLimit", "VT_RECOMMENDED_PARALLELIZATION_LIMIT"},
    {"videoToolboxPixelBufferPoolIsShared", "VT_PIXEL_BUFFER_POOL_IS_SHARED"},
    {"videoToolboxStagingMode", "VT_STAGING_MODE"},
    {"videoToolboxStagedSourceReleaseMode", "VT_STAGED_SOURCE_RELEASE_MODE"},
    {"videoToolboxEncoderInputStrategy", "VT_ENCODER_INPUT_STRATEGY"},
    {"videoToolboxEncoderInputPixelFormat", "VT_ENCODER_INPUT_PIXEL_FORMAT"},
    {"videoToolboxSourcePixelFormat", "VT_SOURCE_PIXEL_FORMAT"},
    {"videoToolboxSourceColorPrimaries", "VT_SOURCE_COLOR_PRIMARIES"},
    {"videoToolboxSignalColorPrimaries", "VT_SIGNAL_COLOR_PRIMARIES"},
    {"videoToolboxColorConversionMode", "VT_COLOR_CONVERSION_MODE"},
    {"videoToolboxTargetFrameRateHint", "VT_TARGET_FRAME_RATE_HINT"},
    {"videoToolboxConfiguredAverageBitRate", "VT_CONFIGURED_AVG_BIT_RATE"},
    {"videoToolboxConfiguredAverageBitRateSource", "VT_CONFIGURED_AVG_BIT_RATE_SOURCE"},
    {"videoToolboxConfiguredDataRateLimits", "VT_CONFIGURED_DATA_RATE_LIMITS"},
    {"videoToolboxConfiguredDataRateLimitsSource", "VT_CONFIGURED_DATA_RATE_LIMITS_SOURCE"},
    {"videoToolboxConfiguredProfileLevel", "VT_CONFIGURED_PROFILE_LEVEL"},
    {"videoToolboxDirectSubmissionFrameCount", "VT_DIRECT_SUBMISSION_FRAME_COUNT"},
    {"videoToolboxStagedSubmissionFrameCount", "VT_STAGED_SUBMISSION_FRAME_COUNT"},
    {"videoToolboxSubmittedFrameCount", "VT_SUBMITTED_FRAME_COUNT"},
    {"videoToolboxImmediateReplaySubmissionCount", "VT_IMMEDIATE_REPLAY_SUBMISSION_COUNT"},
    {"videoToolboxSuppressedImmediateReplayCount", "VT_SUPPRESSED_IMMEDIATE_REPLAY_COUNT"},
    {"videoToolboxMaxInflightStagingSlots", "VT_MAX_INFLIGHT_STAGING_SLOTS"},
    {"videoToolboxPixelBufferCacheSize", "VT_PIXEL_BUFFER_CACHE_SIZE"},
    {"videoToolboxEncodeQueueWaitSampleCount", "VT_ENCODE_QUEUE_WAIT_SAMPLE_COUNT"},
    {"videoToolboxEncodeQueueWaitAverageMilliseconds", "VT_ENCODE_QUEUE_WAIT_AVG_MS"},
    {"videoToolboxEncodeQueueWaitMaxMilliseconds", "VT_ENCODE_QUEUE_WAIT_MAX_MS"},
    {"videoToolboxEncodeInvocationSampleCount", "VT_ENCODE_INVOCATION_SAMPLE_COUNT"},
    {"videoToolboxEncodeInvocationAverageMilliseconds", "VT_ENCODE_INVOCATION_AVG_MS"},
    {"videoToolboxEncodeInvocationMaxMilliseconds", "VT_ENCODE_INVOCATION_MAX_MS"},
    {"videoToolboxMetalStageSampleCount", "VT_METAL_STAGE_SAMPLE_COUNT"},
    {"videoToolboxMetalStageAverageMilliseconds", "VT_METAL_STAGE_AVG_MS"},
    {"videoToolboxMetalStageMaxMilliseconds", "VT_METAL_STAGE_MAX_MS"},
    {"videoToolboxVTEncodeCallSampleCount", "VT_ENCODE_CALL_SAMPLE_COUNT"},
    {"videoToolboxVTEncodeCallAverageMilliseconds", "VT_ENCODE_CALL_AVG_MS"},
    {"videoToolboxVTEncodeCallMaxMilliseconds", "VT_ENCODE_CALL_MAX_MS"},
  };

  std::string remaining(diagnostics);
  while (!remaining.empty()) {
    std::size_t separator = remaining.find(';');
    std::string token = separator == std::string::npos ? remaining : remaining.substr(0, separator);
    if (separator == std::string::npos) {
      remaining.clear();
    } else {
      remaining.erase(0, separator + 1);
    }

    if (token.empty()) {
      continue;
    }

    const std::size_t equals = token.find('=');
    if (equals == std::string::npos || equals == 0 || equals == (token.size() - 1)) {
      continue;
    }

    const std::string key = token.substr(0, equals);
    const char *value = trimLeadingSpaces(token.c_str() + equals + 1);
    for (const DiagnosticEmission &emission : emissions) {
      if (key == emission.sourceKey) {
        std::printf("AUTORESEARCH_RUNTIME_PROBE_%s=%s\n", emission.probeKey, value);
        break;
      }
    }
  }
}

void drainForwardedFrames(
  LumenMacBridgeController *controller,
  ProbeMetrics &metrics,
  std::unordered_map<uint64_t, TileGroupProgress> &tileGroups,
  TileFreshCompositeProgress &tileFreshComposite,
  TileReceiverArbitrationProgress &receiverArbitration,
  TileArrivalProgress &tileArrival,
  bool countEncodedTileRecordsAsFrames
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

    metrics.frameRecords += 1;
    metrics.lastSeq = record.source_sequence_number;
    metrics.lastHDRSignaled = record.is_hdr_signaled;
    metrics.maxTileCount = std::max(metrics.maxTileCount, record.tile_metadata.tile_count);
    metrics.maxEncodedLaneCount =
      std::max(metrics.maxEncodedLaneCount, record.tile_metadata.encoded_lane_count);
    if (record.has_output_callback_latency_milliseconds) {
      metrics.callbackLatencies.push_back(record.output_callback_latency_milliseconds);
    }

    if (record.tile_metadata.tile_count <= 1 &&
        record.tile_metadata.encoded_lane_count <= 1) {
      countLogicalFrame(metrics, record.is_hdr_signaled);
      continue;
    }

    metrics.tiledFrameRecords += 1;
    updateTileArrivalProgress(metrics, tileArrival, record.tile_metadata.tile_index);

    tileFreshComposite.expectedTileCount =
      std::max(tileFreshComposite.expectedTileCount, record.tile_metadata.tile_count);
    tileFreshComposite.observedTileIndexes.insert(record.tile_metadata.tile_index);
    tileFreshComposite.latestDisplayTimeByTile[record.tile_metadata.tile_index] =
      record.source_display_time;
    if (tileFreshComposite.observedTileIndexes.size() >=
        static_cast<size_t>(tileFreshComposite.expectedTileCount)) {
      const double latestSkewMilliseconds =
        tileSkewMilliseconds(tileFreshComposite.latestDisplayTimeByTile);
      metrics.tileFreshCompositeUpdates += 1;
      if (latestSkewMilliseconds <= 8.333) {
        metrics.tileFreshCompositeWithinFrameBudget += 1;
      }
      if (latestSkewMilliseconds <= 16.667) {
        metrics.tileFreshCompositeWithinTwoFrameBudget += 1;
      }
    }
    updateReceiverArbitration(receiverArbitration, record);

    const bool countsTileRecordAsFrame =
      countEncodedTileRecordsAsFrames &&
      record.tile_metadata.encoded_lane_count > 1;
    if (countsTileRecordAsFrame) {
      countLogicalFrame(metrics, record.is_hdr_signaled);
    }

    const uint64_t groupKey = tileGroupKey(record);
    TileGroupProgress &group = tileGroups[groupKey];
    group.expectedTileCount = std::max(group.expectedTileCount, record.tile_metadata.tile_count);
    group.isHDRSignaled = group.isHDRSignaled || record.is_hdr_signaled;
    group.observedTileIndexes.insert(record.tile_metadata.tile_index);
    if (!group.isComplete &&
        group.observedTileIndexes.size() >= static_cast<size_t>(group.expectedTileCount)) {
      group.isComplete = true;
      metrics.completeFrameGroups += 1;
      if (!countsTileRecordAsFrame) {
        countLogicalFrame(metrics, group.isHDRSignaled);
      }
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
    configuration.sink_request.capability.supports_encoded_tile_stream = true;
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
    std::unordered_map<uint64_t, TileGroupProgress> tileGroups;
    TileFreshCompositeProgress tileFreshComposite;
    TileReceiverArbitrationProgress receiverArbitration;
    TileArrivalProgress tileArrival;
    const bool countEncodedTileRecordsAsFrames =
      configuration.sink_request.capability.supports_encoded_tile_stream;
    const auto captureStartTime = std::chrono::steady_clock::now();
    const auto startupDeadline = captureStartTime + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < startupDeadline && !metrics.firstFrameSeen) {
      drainForwardedFrames(
        controller,
        metrics,
        tileGroups,
        tileFreshComposite,
        receiverArbitration,
        tileArrival,
        countEncodedTileRecordsAsFrames
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
          tileGroups,
          tileFreshComposite,
          receiverArbitration,
          tileArrival,
          countEncodedTileRecordsAsFrames
        );
        drainForwardedEvents(controller, metrics);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
    }

    drainForwardedFrames(
      controller,
      metrics,
      tileGroups,
      tileFreshComposite,
      receiverArbitration,
      tileArrival,
      countEncodedTileRecordsAsFrames
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
    metrics.tileReceiverArbitratedOneFrameUpdates =
      receiverArbitration.oneFrame.presentedUpdates;
    metrics.tileReceiverArbitratedTwoFrameUpdates =
      receiverArbitration.twoFrame.presentedUpdates;
    metrics.tileReceiverArbitratedThreeFrameUpdates =
      receiverArbitration.threeFrame.presentedUpdates;
    metrics.tileReceiverArbitratedFourFrameUpdates =
      receiverArbitration.fourFrame.presentedUpdates;
    metrics.tileReceiverArbitratedOneFrameHeldUpdates =
      receiverArbitration.oneFrame.heldUpdates;
    metrics.tileReceiverArbitratedTwoFrameHeldUpdates =
      receiverArbitration.twoFrame.heldUpdates;
    metrics.tileReceiverArbitratedThreeFrameHeldUpdates =
      receiverArbitration.threeFrame.heldUpdates;
    metrics.tileReceiverArbitratedFourFrameHeldUpdates =
      receiverArbitration.fourFrame.heldUpdates;
    metrics.tileReceiverArbitratedTwoFrameMaxSkewMilliseconds =
      receiverArbitration.twoFrame.maxPresentedSkewMilliseconds;
    if (snapshot.has_last_frame) {
      metrics.lastSeq = snapshot.last_frame_source_sequence_number;
      metrics.lastHDRSignaled = snapshot.last_frame_is_hdr_signaled;
    }

    char captureDiagnostics[8192];
    std::memset(captureDiagnostics, 0, sizeof(captureDiagnostics));
    LumenMacBridgeControllerCopyCaptureDiagnostics(
      controller,
      captureDiagnostics,
      sizeof(captureDiagnostics)
    );

    LumenMacBridgeControllerStopMacDisplayKitCapture(controller);
    LumenMacBridgeControllerDestroy(controller);

    uint64_t incompleteFrameGroups = 0;
    for (const auto &entry : tileGroups) {
      if (!entry.second.isComplete) {
        incompleteFrameGroups += 1;
      }
    }

    std::printf("AUTORESEARCH_RUNTIME_PROBE_STATUS=ok\n");
    std::printf("AUTORESEARCH_RUNTIME_PROBE_WIDTH=%d\n", width);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_HEIGHT=%d\n", height);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_FPS=%d\n", fps);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_CODEC=%s\n", codecName(codec));
    std::printf("AUTORESEARCH_RUNTIME_PROBE_FRAMES=%llu\n", metrics.frames);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_FRAME_RECORDS=%llu\n", metrics.frameRecords);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_TILED_FRAME_RECORDS=%llu\n", metrics.tiledFrameRecords);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_COMPLETE_FRAME_GROUPS=%llu\n", metrics.completeFrameGroups);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_INCOMPLETE_FRAME_GROUPS=%llu\n", incompleteFrameGroups);
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_FRESH_COMPOSITE_UPDATES=%llu\n",
      metrics.tileFreshCompositeUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_FRESH_COMPOSITE_WITHIN_FRAME_BUDGET=%llu\n",
      metrics.tileFreshCompositeWithinFrameBudget
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_FRESH_COMPOSITE_WITHIN_TWO_FRAME_BUDGET=%llu\n",
      metrics.tileFreshCompositeWithinTwoFrameBudget
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_ONE_FRAME_UPDATES=%llu\n",
      metrics.tileReceiverArbitratedOneFrameUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_TWO_FRAME_UPDATES=%llu\n",
      metrics.tileReceiverArbitratedTwoFrameUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_THREE_FRAME_UPDATES=%llu\n",
      metrics.tileReceiverArbitratedThreeFrameUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_FOUR_FRAME_UPDATES=%llu\n",
      metrics.tileReceiverArbitratedFourFrameUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_ONE_FRAME_HELD_UPDATES=%llu\n",
      metrics.tileReceiverArbitratedOneFrameHeldUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_TWO_FRAME_HELD_UPDATES=%llu\n",
      metrics.tileReceiverArbitratedTwoFrameHeldUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_THREE_FRAME_HELD_UPDATES=%llu\n",
      metrics.tileReceiverArbitratedThreeFrameHeldUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_FOUR_FRAME_HELD_UPDATES=%llu\n",
      metrics.tileReceiverArbitratedFourFrameHeldUpdates
    );
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_RECEIVER_ARBITRATED_TWO_FRAME_MAX_SKEW_MS=%.3f\n",
      metrics.tileReceiverArbitratedTwoFrameMaxSkewMilliseconds
    );
    std::printf("AUTORESEARCH_RUNTIME_PROBE_TILE_ARRIVAL_TRANSITIONS=%llu\n", metrics.tileArrivalTransitions);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_TILE_ARRIVAL_SAME_TILE_RUNS=%llu\n", metrics.tileArrivalSameTileRuns);
    std::printf(
      "AUTORESEARCH_RUNTIME_PROBE_TILE_ARRIVAL_LONGEST_SAME_TILE_RUN=%llu\n",
      metrics.tileArrivalLongestSameTileRun
    );
    std::printf("AUTORESEARCH_RUNTIME_PROBE_MAX_TILE_COUNT=%u\n", metrics.maxTileCount);
    std::printf("AUTORESEARCH_RUNTIME_PROBE_MAX_ENCODED_LANE_COUNT=%u\n", metrics.maxEncodedLaneCount);
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
    emitSelectedDiagnostics(captureDiagnostics);
    std::fflush(stdout);
    return 0;
  }
}
