#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>

#import "LumenMacBridge.h"

#include <math.h>
#include <time.h>
#include <unistd.h>

@interface LumenContentStreamProbeState : NSObject
@property(nonatomic) uint64_t callbackCount;
@property(nonatomic) uint64_t completeCount;
@property(nonatomic) uint64_t idleCount;
@property(nonatomic) uint64_t blankCount;
@property(nonatomic) uint64_t stoppedCount;
@property(nonatomic) uint64_t wrapFailureCount;
@property(nonatomic) uint64_t firstCallbackNanos;
@property(nonatomic) uint64_t lastCallbackNanos;
@property(nonatomic) size_t surfaceWidth;
@property(nonatomic) size_t surfaceHeight;
@property(nonatomic) OSType surfacePixelFormat;
@property(nonatomic) BOOL hasIOSurface;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *displayTimes;
@end

// Optional compositor-owned motion keeps source cadence comparable between
// raw SkyLight and production capture-to-VideoToolbox measurements.
@interface LumenProbeStimulus : NSObject
- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID;
- (void)start;
- (void)stop;
- (NSDictionary<NSString *, id> *)metrics;
@end

@implementation LumenProbeStimulus {
  NSWindow *_window;
  CALayer *_movingLayer;
  CADisplayLink *_displayLink;
  uint64_t _tickCount;
  uint64_t _firstTickNanos;
  uint64_t _lastTickNanos;
  CGFloat _phase;
}

static NSScreen *LumenProbeScreenForDisplayID(CGDirectDisplayID displayID) {
  for (NSScreen *screen in NSScreen.screens) {
    NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
    if (screenNumber.unsignedIntValue == displayID) {
      return screen;
    }
  }
  return nil;
}

- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  NSScreen *screen = LumenProbeScreenForDisplayID(displayID);
  NSRect screenFrame = screen == nil
    ? NSMakeRect(
        CGRectGetMinX(CGDisplayBounds(displayID)),
        CGRectGetMinY(CGDisplayBounds(displayID)),
        CGRectGetWidth(CGDisplayBounds(displayID)),
        CGRectGetHeight(CGDisplayBounds(displayID))
      )
    : screen.frame;
  CGFloat width = MIN(800.0, MAX(320.0, screenFrame.size.width * 0.45));
  CGFloat height = MIN(480.0, MAX(240.0, screenFrame.size.height * 0.35));
  NSRect frame = NSMakeRect(
    NSMidX(screenFrame) - width * 0.5,
    NSMidY(screenFrame) - height * 0.5,
    width,
    height
  );
  _window = [[NSWindow alloc]
    initWithContentRect:frame
              styleMask:NSWindowStyleMaskBorderless
                backing:NSBackingStoreBuffered
                  defer:NO
                 screen:screen];
  _window.backgroundColor = [NSColor blackColor];
  _window.opaque = YES;
  _window.hasShadow = YES;
  _window.ignoresMouseEvents = YES;
  _window.level = NSFloatingWindowLevel;
  _window.collectionBehavior =
    NSWindowCollectionBehaviorCanJoinAllSpaces |
    NSWindowCollectionBehaviorFullScreenAuxiliary;

  NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
  contentView.wantsLayer = YES;
  contentView.layer.backgroundColor = [NSColor blackColor].CGColor;
  contentView.layer.contentsScale = 2.0;
  _window.contentView = contentView;

  _movingLayer = [CALayer layer];
  _movingLayer.bounds = CGRectMake(0, 0, 96, 96);
  _movingLayer.position = CGPointMake(width * 0.5, height * 0.5);
  _movingLayer.backgroundColor = [NSColor whiteColor].CGColor;
  _movingLayer.borderWidth = 8.0;
  _movingLayer.borderColor = [NSColor systemRedColor].CGColor;
  _movingLayer.cornerRadius = 8.0;
  [contentView.layer addSublayer:_movingLayer];

  return self;
}

- (void)start {
  [_window orderFrontRegardless];
  [_window displayIfNeeded];
  [NSApp activateIgnoringOtherApps:YES];
  _displayLink = [_window displayLinkWithTarget:self
                                       selector:@selector(displayLinkTick:)];
  _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(
    120.0,
    120.0,
    120.0
  );
  [_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                     forMode:NSRunLoopCommonModes];
  [self displayLinkTick:_displayLink];
}

- (void)stop {
  [_displayLink invalidate];
  _displayLink = nil;
  [_movingLayer removeAllAnimations];
  [_window orderOut:nil];
}

- (void)displayLinkTick:(CADisplayLink *)displayLink {
  (void)displayLink;
  uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  if (_firstTickNanos == 0) {
    _firstTickNanos = now;
  }
  _lastTickNanos = now;
  _tickCount += 1;
  _phase = fmod(_phase + 0.03125, 1.0);

  CGFloat width = _window.contentView.bounds.size.width;
  CGFloat height = _window.contentView.bounds.size.height;
  CGFloat x = 96.0 + _phase * MAX(width - 192.0, 1.0);
  CGFloat y = height * (0.30 + 0.40 * _phase);
  CGFloat red = 0.20 + 0.80 * _phase;
  CGFloat green = 0.80 - 0.60 * _phase;
  CGColorRef color = [NSColor colorWithCalibratedRed:red
                                                green:green
                                                 blue:1.0 - _phase
                                                alpha:1.0].CGColor;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _movingLayer.position = CGPointMake(x, y);
  _movingLayer.backgroundColor = color;
  [CATransaction commit];
}

- (NSDictionary<NSString *, id> *)metrics {
  static const double requestedFPS = 120.0;
  double durationSeconds = _lastTickNanos > _firstTickNanos
    ? (double)(_lastTickNanos - _firstTickNanos) / 1e9
    : 0.0;
  double tickFPS = durationSeconds > 0.0 && _tickCount > 1
    ? (double)(_tickCount - 1) / durationSeconds
    : 0.0;
  return @{
    @"stimulusMode": @"cadisplaylink-dirty-layer",
    @"stimulusRequestedFPS": @(requestedFPS),
    @"stimulusTickCount": @(_tickCount),
    @"stimulusTickFPS": @(tickFPS),
    // Preserve slow runs as diagnostic evidence, but do not let a throttled
    // compositor stimulus count as a valid 120 FPS performance comparison.
    @"stimulusCadenceValid": @(tickFPS >= requestedFPS * 0.90)
  };
}
@end

@implementation LumenContentStreamProbeState
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _displayTimes = [NSMutableArray array];
  }
  return self;
}
@end

@interface LumenPipelineProbeCounters : NSObject
@property(nonatomic) uint64_t encodedFrameCount;
@property(nonatomic) uint64_t inferredSourceFrameCount;
@property(nonatomic) uint64_t sourceSequenceGapCount;
@property(nonatomic) uint64_t encodedBytes;
@property(nonatomic) uint64_t lastSourceSequence;
@property(nonatomic) BOOL hasLastSourceSequence;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *outputCallbackLatencies;
@end

@implementation LumenPipelineProbeCounters
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _outputCallbackLatencies = [NSMutableArray array];
  }
  return self;
}
@end

static void LumenProbeRunApplicationForDuration(double duration) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
  while ([deadline timeIntervalSinceNow] > 0) {
    NSDate *slice = [NSDate dateWithTimeIntervalSinceNow:0.050];
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:slice];
  }
}

static NSString *LumenProbeArgument(
  int argc,
  const char *argv[],
  NSString *name
) {
  for (int index = 1; index + 1 < argc; index += 1) {
    if ([name isEqualToString:[NSString stringWithUTF8String:argv[index]]]) {
      return [NSString stringWithUTF8String:argv[index + 1]];
    }
  }
  return nil;
}

static BOOL LumenProbeHasFlag(
  int argc,
  const char *argv[],
  NSString *name
) {
  for (int index = 1; index < argc; index += 1) {
    if ([name isEqualToString:[NSString stringWithUTF8String:argv[index]]]) {
      return YES;
    }
  }
  return NO;
}

static NSString *LumenProbeFourCC(OSType value) {
  char text[5] = {
    (char)((value >> 24) & 0xff),
    (char)((value >> 16) & 0xff),
    (char)((value >> 8) & 0xff),
    (char)(value & 0xff),
    0
  };
  for (NSUInteger index = 0; index < 4; index += 1) {
    if (text[index] < 0x20 || text[index] > 0x7e) {
      return [NSString stringWithFormat:@"0x%08x", value];
    }
  }
  return [NSString stringWithUTF8String:text];
}

static double LumenProbeMachTicksToMilliseconds(uint64_t ticks) {
  static mach_timebase_info_data_t timebase;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    mach_timebase_info(&timebase);
  });
  return (double)ticks * (double)timebase.numer /
    (double)timebase.denom / 1e6;
}

static double LumenProbePercentile(
  NSArray<NSNumber *> *values,
  double percentile
) {
  if (values.count == 0) {
    return 0;
  }
  NSArray<NSNumber *> *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
  double position = percentile * (double)(sorted.count - 1);
  NSUInteger index = (NSUInteger)ceil(position);
  return sorted[MIN(index, sorted.count - 1)].doubleValue;
}

static NSArray<NSDictionary<NSString *, id> *> *LumenProbeOnlineDisplays(void) {
  uint32_t count = 0;
  if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
    return @[];
  }
  CGDirectDisplayID *displayIDs = calloc(count, sizeof(CGDirectDisplayID));
  if (displayIDs == NULL) {
    return @[];
  }
  CGError status = CGGetOnlineDisplayList(count, displayIDs, &count);
  NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
  if (status == kCGErrorSuccess) {
    for (uint32_t index = 0; index < count; index += 1) {
      CGDirectDisplayID displayID = displayIDs[index];
      CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
      double refreshRate = mode == NULL ? 0 : CGDisplayModeGetRefreshRate(mode);
      [result addObject:@{
        @"displayID": @(displayID),
        @"builtin": @(CGDisplayIsBuiltin(displayID) != 0),
        @"active": @(CGDisplayIsActive(displayID) != 0),
        @"main": @(CGDisplayIsMain(displayID) != 0),
        @"logicalWidth": @(CGRectGetWidth(CGDisplayBounds(displayID))),
        @"logicalHeight": @(CGRectGetHeight(CGDisplayBounds(displayID))),
        @"pixelWidth": @(CGDisplayPixelsWide(displayID)),
        @"pixelHeight": @(CGDisplayPixelsHigh(displayID)),
        @"refreshRate": @(refreshRate)
      }];
      if (mode != NULL) {
        CGDisplayModeRelease(mode);
      }
    }
  }
  free(displayIDs);
  return result;
}

static void LumenProbePrintJSON(NSDictionary<NSString *, id> *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  if (data == nil) {
    fprintf(stderr, "{\"error\":\"json-serialization-failed\"}\n");
    return;
  }
  fwrite(data.bytes, 1, data.length, stdout);
  fputc('\n', stdout);
  fflush(stdout);
}

static NSDictionary<NSString *, NSString *> *LumenProbeParseDiagnostics(
  const char *diagnostics
) {
  if (diagnostics == NULL || diagnostics[0] == '\0') {
    return @{};
  }
  NSString *text = [NSString stringWithUTF8String:diagnostics];
  if (text == nil || [text isEqualToString:@"n/a"]) {
    return @{};
  }
  NSMutableDictionary<NSString *, NSString *> *result =
    [NSMutableDictionary dictionary];
  for (NSString *component in [text componentsSeparatedByString:@";"]) {
    NSRange separator = [component rangeOfString:@"="];
    if (separator.location == NSNotFound || separator.location == 0) {
      continue;
    }
    NSString *key = [component substringToIndex:separator.location];
    NSString *value = [component substringFromIndex:separator.location + 1];
    result[key] = value;
  }
  return result;
}

static NSDictionary<NSString *, NSString *> *LumenProbeSelectedDiagnostics(
  NSDictionary<NSString *, NSString *> *diagnostics
) {
  NSArray<NSString *> *keys = @[
    @"sourceBackend",
    @"privateContentStreamBackend",
    @"privateContentStreamCumulativeDropCount",
    @"privateContentStreamRequestedPixelFormat",
    @"privateContentStreamDynamicRangeMode",
    @"sourceCaptureSampleCount",
    @"sourceDisplayIntervalSampleCount",
    @"sourceDisplayIntervalAverageMilliseconds",
    @"sourceDisplayIntervalMinimumMilliseconds",
    @"sourceDisplayIntervalMaximumMilliseconds",
    @"sourceDisplayApproxFrameRate",
    @"sourceDisplayToCallbackAverageMilliseconds",
    @"sourceDisplayToCallbackMaximumMilliseconds",
    @"sourceCallbackWindowFrameRate",
    @"sourceCallbackServiceAverageMilliseconds",
    @"sourceCallbackServiceMaximumMilliseconds",
    @"videoToolboxUsingHardwareEncoder",
    @"videoToolboxSubmittedFrameCount",
    @"videoToolboxSubmissionWindowFrameRate",
    @"videoToolboxPendingAdmissionDropCount",
    @"videoToolboxPendingAdmissionDropWindowRate",
    @"videoToolboxAppliedBitrateKbps",
    @"videoToolboxConfiguredPrioritizeEncodingSpeedOverQuality",
    @"videoToolboxConfiguredThroughputMode",
    @"videoToolboxEstimatedOutputBitrateKbps",
    @"videoToolboxMaxInflightStagingSlots",
    @"videoToolboxOutputWindowFrameRate",
    @"videoToolboxAdmissionWaitAverageMilliseconds",
    @"videoToolboxAdmissionWaitMaximumMilliseconds",
    @"videoToolboxEncodeInvocationAverageMilliseconds",
    @"videoToolboxEncodeInvocationMaximumMilliseconds",
    @"videoToolboxEncodeToCallbackAverageMilliseconds",
    @"videoToolboxEncodeToCallbackMaximumMilliseconds",
    @"videoToolboxOutputOwnerQueueWaitAverageMilliseconds",
    @"videoToolboxOutputOwnerQueueWaitMaximumMilliseconds",
    @"videoToolboxOutputServiceAverageMilliseconds",
    @"videoToolboxOutputServiceMaximumMilliseconds",
    @"videoToolboxFrameHandlerAverageMilliseconds",
    @"videoToolboxFrameHandlerMaximumMilliseconds"
  ];
  NSMutableDictionary<NSString *, NSString *> *result =
    [NSMutableDictionary dictionary];
  for (NSString *key in keys) {
    NSString *value = diagnostics[key];
    if (value != nil) {
      result[key] = value;
    }
  }
  return result;
}

static void LumenProbeDrainForwardedFrames(
  LumenMacBridgeController *controller,
  LumenPipelineProbeCounters *counters
) {
  while (true) {
    CMSampleBufferRef sampleBuffer = NULL;
    LumenMacEncodedCaptureFrameRecord frame =
      LumenMacBridgeControllerPopNextForwardedFrame(
        controller,
        &sampleBuffer
      );
    if (sampleBuffer != NULL) {
      CFRelease(sampleBuffer);
    }
    if (!frame.has_value) {
      return;
    }
    if (counters != nil) {
      counters.encodedFrameCount += 1;
      counters.encodedBytes += frame.payload_size;
      if (counters.hasLastSourceSequence &&
          frame.source_sequence_number > counters.lastSourceSequence + 1) {
        counters.sourceSequenceGapCount +=
          frame.source_sequence_number - counters.lastSourceSequence - 1;
      }
      counters.lastSourceSequence = frame.source_sequence_number;
      counters.hasLastSourceSequence = YES;
      counters.inferredSourceFrameCount =
        counters.encodedFrameCount + counters.sourceSequenceGapCount;
      if (frame.has_output_callback_latency_milliseconds) {
        [counters.outputCallbackLatencies addObject:@(
          frame.output_callback_latency_milliseconds
        )];
      }
    }
  }
}

static int LumenProbeRunProductionPipeline(
  CGDirectDisplayID displayID,
  size_t outputWidth,
  size_t outputHeight,
  int32_t targetBitrateKbps,
  double duration,
  BOOL hdr,
  BOOL stimulus,
  NSArray<NSDictionary<NSString *, id> *> *onlineDisplays
) {
  LumenProbeStimulus *stimulusWindow = nil;
  if (stimulus) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    stimulusWindow = [[LumenProbeStimulus alloc] initWithDisplayID:displayID];
    [stimulusWindow start];
  }

  LumenMacBridgeController *controller = LumenMacBridgeControllerCreate();
  if (controller == NULL) {
    [stimulusWindow stop];
    LumenProbePrintJSON(@{@"error": @"pipeline-controller-create-failed"});
    return 6;
  }

  LumenMacBridgeCaptureConfiguration configuration =
    LumenMacBridgeControllerMakePanelNativeConfiguration(displayID);
  configuration.codec = LumenMacCaptureCodecHEVC;
  configuration.video_profile = hdr
    ? LumenMacCaptureVideoProfileHEVCMain10
    : LumenMacCaptureVideoProfileHEVCMain;
  configuration.chroma_subsampling = LumenMacCaptureChromaSubsamplingYUV420;
  configuration.bit_depth = hdr ? 10 : 8;
  configuration.dynamic_range = hdr
    ? LumenMacCaptureDynamicRangeHDR10
    : LumenMacCaptureDynamicRangeSDR;
  configuration.color_range = LumenMacCaptureColorRangeLimited;
  configuration.preprocess_strategy = LumenMacBridgePreprocessStrategyNone;
  configuration.queue_profile = LumenMacBridgeQueueProfileAuto;
  configuration.target_frame_rate = 120;
  configuration.target_video_bitrate_kbps = targetBitrateKbps;
  configuration.requested_width = (int32_t)outputWidth;
  configuration.requested_height = (int32_t)outputHeight;
  configuration.sink_request.capability.gamut = hdr ? 3 : 1;
  configuration.sink_request.capability.transfer = hdr ? 2 : 1;
  configuration.sink_request.capability.supports_frame_gated_hdr = true;
  configuration.sink_request.capability.supports_per_frame_hdr_metadata = true;
  configuration.sink_request.dynamic_range_transport = hdr
    ? LumenMacDynamicRangeTransportFrameGatedHDR
    : LumenMacDynamicRangeTransportSDR;
  configuration.effective_display_state.gamut = hdr ? 3 : 1;
  configuration.effective_display_state.transfer = hdr ? 2 : 1;

  char error[2048] = {0};
  uint64_t startupNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  if (!LumenMacBridgeControllerStartCapture(
        controller,
        configuration,
        error,
        sizeof(error)
      )) {
    LumenProbePrintJSON(@{
      @"error": @"pipeline-capture-start-failed",
      @"message": error[0] == '\0'
        ? @"unknown"
        : [NSString stringWithUTF8String:error],
      @"displayID": @(displayID),
      @"onlineDisplays": onlineDisplays
    });
    [stimulusWindow stop];
    LumenMacBridgeControllerDestroy(controller);
    return 7;
  }

  LumenMacEncodedCaptureIngressSnapshot initialSnapshot = {0};
  uint64_t firstFrameDeadline = startupNanos + 10ULL * NSEC_PER_SEC;
  while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < firstFrameDeadline) {
    initialSnapshot =
      LumenMacBridgeControllerCopyVideoForwardingSnapshot(controller);
    if (initialSnapshot.frame_count > 0) {
      break;
    }
    if (stimulusWindow != nil) {
      NSDate *slice = [NSDate dateWithTimeIntervalSinceNow:0.001];
      [[NSRunLoop currentRunLoop]
        runMode:NSDefaultRunLoopMode
        beforeDate:slice];
    } else {
      usleep(1000);
    }
  }
  if (initialSnapshot.frame_count == 0) {
    LumenMacBridgeControllerStopCapture(controller);
    LumenMacBridgeControllerDestroy(controller);
    [stimulusWindow stop];
    LumenProbePrintJSON(@{
      @"error": @"pipeline-first-frame-timeout",
      @"displayID": @(displayID),
      @"onlineDisplays": onlineDisplays
    });
    return 8;
  }

  BOOL acknowledged = LumenMacBridgeResumeVideoEncodingAfterCodecAck();
  LumenProbeDrainForwardedFrames(controller, nil);
  initialSnapshot =
    LumenMacBridgeControllerCopyVideoForwardingSnapshot(controller);

  LumenPipelineProbeCounters *counters =
    [[LumenPipelineProbeCounters alloc] init];
  uint64_t measurementStartNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  uint64_t measurementDeadline = measurementStartNanos +
    (uint64_t)(duration * (double)NSEC_PER_SEC);
  while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < measurementDeadline) {
    LumenProbeDrainForwardedFrames(controller, counters);
    if (stimulusWindow != nil) {
      NSDate *slice = [NSDate dateWithTimeIntervalSinceNow:0.001];
      [[NSRunLoop currentRunLoop]
        runMode:NSDefaultRunLoopMode
        beforeDate:slice];
    } else {
      usleep(1000);
    }
  }
  LumenProbeDrainForwardedFrames(controller, counters);
  uint64_t measurementEndNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

  LumenMacEncodedCaptureIngressSnapshot finalSnapshot =
    LumenMacBridgeControllerCopyVideoForwardingSnapshot(controller);
  char finalDiagnosticsBuffer[65536] = {0};
  LumenMacBridgeControllerCopyCaptureDiagnostics(
    controller,
    finalDiagnosticsBuffer,
    sizeof(finalDiagnosticsBuffer)
  );
  NSDictionary<NSString *, NSString *> *finalDiagnostics =
    LumenProbeParseDiagnostics(finalDiagnosticsBuffer);
  NSDictionary<NSString *, id> *stimulusMetrics = stimulusWindow == nil
    ? @{}
    : [stimulusWindow metrics];
  [stimulusWindow stop];
  LumenMacBridgeControllerStopCapture(controller);
  LumenMacBridgeControllerDestroy(controller);

  double measuredSeconds =
    (double)(measurementEndNanos - measurementStartNanos) / 1e9;
  uint64_t sourceDelta = counters.inferredSourceFrameCount;
  uint64_t submittedDelta = counters.encodedFrameCount;
  uint64_t outputDelta = counters.encodedFrameCount;
  uint64_t pendingDropDelta = counters.sourceSequenceGapCount;
  uint64_t forwardingDropDelta =
    finalSnapshot.dropped_frame_count >= initialSnapshot.dropped_frame_count
      ? finalSnapshot.dropped_frame_count - initialSnapshot.dropped_frame_count
      : 0;

  NSMutableDictionary<NSString *, id> *result = [@{
    @"mode": @"production-pipeline",
    @"displayID": @(displayID),
    @"requestedWidth": @(outputWidth),
    @"requestedHeight": @(outputHeight),
    @"targetBitrateKbps": @(targetBitrateKbps),
    @"hdr": @(hdr),
    @"stimulus": @(stimulus),
    @"stimulusMode": stimulus ? @"cadisplaylink-dirty-layer" : @"none",
    @"targetFPS": @120,
    @"codecAcknowledged": @(acknowledged),
    @"startupToFirstFrameMilliseconds": @(
      (double)(measurementStartNanos - startupNanos) / 1e6
    ),
    @"measurementMilliseconds": @(measuredSeconds * 1000.0),
    @"sourceFrameCount": @(sourceDelta),
    @"submittedFrameCount": @(submittedDelta),
    @"encodedFrameCount": @(outputDelta),
    @"pendingAdmissionDropCount": @(pendingDropDelta),
    @"forwardingDropCount": @(forwardingDropDelta),
    @"encodedBytes": @(counters.encodedBytes),
    @"outputCallbackLatencyP50Milliseconds": @(
      LumenProbePercentile(counters.outputCallbackLatencies, 0.50)
    ),
    @"outputCallbackLatencyP95Milliseconds": @(
      LumenProbePercentile(counters.outputCallbackLatencies, 0.95)
    ),
    @"sourceFPS": @(sourceDelta / MAX(measuredSeconds, 0.000001)),
    @"submissionFPS": @(submittedDelta / MAX(measuredSeconds, 0.000001)),
    @"outputFPS": @(outputDelta / MAX(measuredSeconds, 0.000001)),
    @"pipelineDiagnostics": LumenProbeSelectedDiagnostics(finalDiagnostics),
    @"onlineDisplays": onlineDisplays
  } mutableCopy];
  [result addEntriesFromDictionary:stimulusMetrics];
  LumenProbePrintJSON(result);
  return acknowledged ? 0 : 9;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSArray<NSDictionary<NSString *, id> *> *onlineDisplays =
      LumenProbeOnlineDisplays();
    if (LumenProbeHasFlag(argc, argv, @"--list")) {
      LumenProbePrintJSON(@{@"onlineDisplays": onlineDisplays});
      return 0;
    }

    NSString *displayArgument = LumenProbeArgument(
      argc,
      argv,
      @"--display-id"
    );
    CGDirectDisplayID displayID = displayArgument == nil
      ? CGMainDisplayID()
      : (CGDirectDisplayID)displayArgument.longLongValue;
    size_t defaultWidth = CGDisplayPixelsWide(displayID);
    size_t defaultHeight = CGDisplayPixelsHigh(displayID);
    NSString *widthArgument = LumenProbeArgument(argc, argv, @"--width");
    NSString *heightArgument = LumenProbeArgument(argc, argv, @"--height");
    size_t outputWidth = widthArgument == nil
      ? defaultWidth
      : (size_t)MAX(widthArgument.longLongValue, 1);
    size_t outputHeight = heightArgument == nil
      ? defaultHeight
      : (size_t)MAX(heightArgument.longLongValue, 1);
    NSString *durationArgument = LumenProbeArgument(argc, argv, @"--duration");
    double duration = durationArgument == nil
      ? 8.0
      : MAX(durationArgument.doubleValue, 1.0);
    NSString *bitrateArgument = LumenProbeArgument(
      argc,
      argv,
      @"--bitrate-kbps"
    );
    int32_t targetBitrateKbps = bitrateArgument == nil
      ? 0
      : (int32_t)MAX(MIN(bitrateArgument.longLongValue, INT32_MAX), 0);
    BOOL hdr = LumenProbeHasFlag(argc, argv, @"--hdr");
    BOOL stimulus = LumenProbeHasFlag(argc, argv, @"--stimulus");
    NSString *pixelFormatArgument = LumenProbeArgument(
      argc,
      argv,
      @"--pixel-format"
    );
    NSString *pixelFormatSelection = pixelFormatArgument == nil
      ? (hdr ? @"x420" : @"420v")
      : pixelFormatArgument.lowercaseString;
    OSType pixelFormat = 0;
    NSString *matrix = nil;
    NSString *colorSpace = nil;
    NSString *pixelFormatError = nil;
    if ([pixelFormatSelection isEqualToString:@"bgra"] ||
        [pixelFormatSelection isEqualToString:@"32bgra"]) {
      pixelFormatSelection = @"bgra";
      pixelFormat = kCVPixelFormatType_32BGRA;
      if (hdr) {
        pixelFormatError =
          @"BGRA is an 8-bit SDR format; omit --hdr for this selector.";
      }
    } else if ([pixelFormatSelection isEqualToString:@"420v"]) {
      pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      matrix = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2;
      if (hdr) {
        pixelFormatError =
          @"420v is an 8-bit SDR format; omit --hdr for this selector.";
      }
    } else if ([pixelFormatSelection isEqualToString:@"x420"]) {
      pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
      matrix = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_2020;
      colorSpace = (__bridge NSString *)kCGColorSpaceITUR_2100_PQ;
      if (!hdr) {
        pixelFormatError =
          @"x420 is reserved for the HDR condition; add --hdr for this selector.";
      }
    } else {
      pixelFormatError =
        @"--pixel-format must be one of: bgra, 420v, x420.";
    }

    if (pixelFormatError != nil) {
      LumenProbePrintJSON(@{
        @"error": @"invalid-pixel-format-selector",
        @"message": pixelFormatError,
        @"pixelFormat": pixelFormatArgument ?: @"default",
        @"hdr": @(hdr),
        @"displayID": @(displayID),
        @"onlineDisplays": onlineDisplays
      });
      return 2;
    }

    if (LumenProbeHasFlag(argc, argv, @"--pipeline")) {
      if (pixelFormatArgument != nil) {
        LumenProbePrintJSON(@{
          @"error": @"pixel-format-selector-only-raw",
          @"message": @"--pixel-format applies only to the raw probe.",
          @"pixelFormat": pixelFormatSelection,
          @"displayID": @(displayID),
          @"onlineDisplays": onlineDisplays
        });
        return 2;
      }
      return LumenProbeRunProductionPipeline(
        displayID,
        outputWidth,
        outputHeight,
        targetBitrateKbps,
        duration,
        hdr,
        stimulus,
        onlineDisplays
      );
    }

    if (![LumenMacSkyLightDisplayStream isSupported]) {
      LumenProbePrintJSON(@{
        @"error": @"slcontentstream-runtime-unavailable",
        @"onlineDisplays": onlineDisplays
      });
      return 2;
    }

    dispatch_queue_t callbackQueue = dispatch_queue_create(
      "dev.skyline23.lumen.slcontentstream-probe.callback",
      DISPATCH_QUEUE_SERIAL
    );
    dispatch_semaphore_t firstFrame = dispatch_semaphore_create(0);
    LumenContentStreamProbeState *state =
      [[LumenContentStreamProbeState alloc] init];
    LumenProbeStimulus *stimulusWindow = nil;
    if (stimulus) {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      [NSApp finishLaunching];
      stimulusWindow = [[LumenProbeStimulus alloc] initWithDisplayID:displayID];
      [stimulusWindow start];
    }
    uint64_t startNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

    LumenMacSkyLightDisplayStream *stream =
      [[LumenMacSkyLightDisplayStream alloc]
        initWithDisplayID:displayID
                 outputWidth:outputWidth
                outputHeight:outputHeight
                 pixelFormat:pixelFormat
            minimumFrameTime:0
                  queueDepth:2
                  showCursor:YES
                 yCbCrMatrix:matrix
           dynamicRangeMode:hdr ? 2 : 0
             colorSpaceName:colorSpace
              callbackQueue:callbackQueue
               frameHandler:^(CGDisplayStreamFrameStatus status,
                              uint64_t displayTime,
                              CVPixelBufferRef pixelBuffer,
                              CVReturn pixelBufferStatus) {
      uint64_t callbackNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
      BOOL signalFirstFrame = NO;
      @synchronized (state) {
        state.callbackCount += 1;
        switch (status) {
          case kCGDisplayStreamFrameStatusFrameComplete:
            state.completeCount += 1;
            if (pixelBufferStatus != kCVReturnSuccess || pixelBuffer == NULL) {
              state.wrapFailureCount += 1;
              break;
            }
            if (state.firstCallbackNanos == 0) {
              state.firstCallbackNanos = callbackNanos;
              signalFirstFrame = YES;
            }
            state.lastCallbackNanos = callbackNanos;
            state.surfaceWidth = CVPixelBufferGetWidth(pixelBuffer);
            state.surfaceHeight = CVPixelBufferGetHeight(pixelBuffer);
            state.surfacePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
            state.hasIOSurface = CVPixelBufferGetIOSurface(pixelBuffer) != NULL;
            [state.displayTimes addObject:@(displayTime)];
            break;
          case kCGDisplayStreamFrameStatusFrameIdle:
            state.idleCount += 1;
            break;
          case kCGDisplayStreamFrameStatusFrameBlank:
            state.blankCount += 1;
            break;
          case kCGDisplayStreamFrameStatusStopped:
            state.stoppedCount += 1;
            break;
        }
      }
      if (signalFirstFrame) {
        dispatch_semaphore_signal(firstFrame);
      }
    }];
    if (stream == nil) {
      [stimulusWindow stop];
      LumenProbePrintJSON(@{
        @"error": @"slcontentstream-create-failed",
        @"displayID": @(displayID),
        @"onlineDisplays": onlineDisplays
      });
      return 3;
    }

    fprintf(
      stdout,
      "probe-start pid=%d display=%u output=%zux%zu format=%s hdr=%s\n",
      getpid(),
      displayID,
      outputWidth,
      outputHeight,
      LumenProbeFourCC(pixelFormat).UTF8String,
      hdr ? "true" : "false"
    );
    fflush(stdout);

    NSError *startError = nil;
    if (![stream startWithError:&startError]) {
      [stimulusWindow stop];
      LumenProbePrintJSON(@{
        @"error": @"slcontentstream-start-failed",
        @"message": startError.localizedDescription ?: @"unknown",
        @"domain": startError.domain ?: @"unknown",
        @"code": @(startError.code),
        @"displayID": @(displayID),
        @"onlineDisplays": onlineDisplays
      });
      return 4;
    }

    long firstFrameWait = dispatch_semaphore_wait(
      firstFrame,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))
    );
    if (firstFrameWait == 0) {
      if (stimulusWindow != nil) {
        LumenProbeRunApplicationForDuration(duration);
      } else {
        usleep((useconds_t)(duration * 1e6));
      }
    }
    int32_t stopStatus = [stream stop];
    NSDictionary<NSString *, id> *stimulusMetrics = stimulusWindow == nil
      ? @{}
      : [stimulusWindow metrics];
    [stimulusWindow stop];

    uint64_t callbackCount = 0;
    uint64_t completeCount = 0;
    uint64_t idleCount = 0;
    uint64_t blankCount = 0;
    uint64_t stoppedCount = 0;
    uint64_t wrapFailureCount = 0;
    uint64_t firstCallbackNanos = 0;
    uint64_t lastCallbackNanos = 0;
    size_t surfaceWidth = 0;
    size_t surfaceHeight = 0;
    OSType surfacePixelFormat = 0;
    BOOL hasIOSurface = NO;
    NSArray<NSNumber *> *displayTimes = nil;
    @synchronized (state) {
      callbackCount = state.callbackCount;
      completeCount = state.completeCount;
      idleCount = state.idleCount;
      blankCount = state.blankCount;
      stoppedCount = state.stoppedCount;
      wrapFailureCount = state.wrapFailureCount;
      firstCallbackNanos = state.firstCallbackNanos;
      lastCallbackNanos = state.lastCallbackNanos;
      surfaceWidth = state.surfaceWidth;
      surfaceHeight = state.surfaceHeight;
      surfacePixelFormat = state.surfacePixelFormat;
      hasIOSurface = state.hasIOSurface;
      displayTimes = [state.displayTimes copy];
    }

    NSMutableArray<NSNumber *> *displayDeltas = [NSMutableArray array];
    for (NSUInteger index = 1; index < displayTimes.count; index += 1) {
      uint64_t previous = displayTimes[index - 1].unsignedLongLongValue;
      uint64_t current = displayTimes[index].unsignedLongLongValue;
      if (current > previous) {
        [displayDeltas addObject:@(
          LumenProbeMachTicksToMilliseconds(current - previous)
        )];
      }
    }
    double callbackDurationSeconds = lastCallbackNanos > firstCallbackNanos
      ? (double)(lastCallbackNanos - firstCallbackNanos) / 1e9
      : 0;
    double callbackFPS = callbackDurationSeconds > 0 && completeCount > 1
      ? (double)(completeCount - 1) / callbackDurationSeconds
      : 0;
    double firstFrameMilliseconds = firstCallbackNanos > startNanos
      ? (double)(firstCallbackNanos - startNanos) / 1e6
      : 0;

    NSMutableDictionary<NSString *, id> *result = [@{
      @"backend": stream.backendName,
      @"contentStreamClass": stream.contentStreamClassName ?: @"unavailable",
      @"sharingSessionClass": stream.contentStreamSessionClassName ?: @"unavailable",
      @"underlyingCGDisplayStream": @(stream.underlyingDisplayStreamAvailable),
      @"underlyingCGDisplayStreamTypeID": @(stream.underlyingDisplayStreamTypeID),
      @"displayID": @(displayID),
      @"requestedWidth": @(outputWidth),
      @"requestedHeight": @(outputHeight),
      @"requestedPixelFormat": LumenProbeFourCC(pixelFormat),
      @"pixelFormatSelection": pixelFormatSelection,
      @"hdr": @(hdr),
      @"stimulus": @(stimulus),
      @"stimulusMode": stimulus ? @"cadisplaylink-dirty-layer" : @"none",
      @"firstFrameReceived": @(firstFrameWait == 0),
      @"firstFrameMilliseconds": @(firstFrameMilliseconds),
      @"callbackCount": @(callbackCount),
      @"completeCount": @(completeCount),
      @"idleCount": @(idleCount),
      @"blankCount": @(blankCount),
      @"stoppedCount": @(stoppedCount),
      @"wrapFailureCount": @(wrapFailureCount),
      @"surfaceWidth": @(surfaceWidth),
      @"surfaceHeight": @(surfaceHeight),
      @"surfacePixelFormat": LumenProbeFourCC(surfacePixelFormat),
      @"surfaceHasIOSurface": @(hasIOSurface),
      @"callbackFPS": @(callbackFPS),
      @"displayDeltaP50Milliseconds": @(
        LumenProbePercentile(displayDeltas, 0.50)
      ),
      @"displayDeltaP95Milliseconds": @(
        LumenProbePercentile(displayDeltas, 0.95)
      ),
      @"firstFrameDropCount": @(stream.firstFrameDropCount),
      @"cumulativeDropCount": @(stream.cumulativeDropCount),
      @"stopStatus": @(stopStatus),
      @"onlineDisplays": onlineDisplays
    } mutableCopy];
    [result addEntriesFromDictionary:stimulusMetrics];
    LumenProbePrintJSON(result);
    return firstFrameWait == 0 && wrapFailureCount == 0 ? 0 : 5;
  }
}
