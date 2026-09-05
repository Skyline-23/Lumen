#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
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
  _window = [[NSPanel alloc]
    initWithContentRect:frame
              styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
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
@property(nonatomic) uint64_t bootstrapAcknowledgementCount;
@property(nonatomic) uint64_t bootstrapAcknowledgementFailureCount;
@property(nonatomic) uint64_t captureFailureCount;
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
    NSDate *slice = [NSDate dateWithTimeIntervalSinceNow:MIN(.005, MAX(0,deadline.timeIntervalSinceNow))];
    NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
      untilDate:slice inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
    [NSApp updateWindows];
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

// Public capture adapter for the same callback, virtual display and encoder.
// This is probe-only DI; production backend selection is unchanged.
@interface LumenProbeSCKSource : NSObject <SCStreamOutput>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, copy) LumenMacSkyLightDisplayStreamFrameHandler handler;
- (BOOL)startDisplay:(CGDirectDisplayID)displayID width:(size_t)width height:(size_t)height
  hdr:(BOOL)hdr queue:(dispatch_queue_t)queue error:(NSError **)error;
- (int32_t)stop;
@end

static BOOL LumenProbeWaitPumping(dispatch_semaphore_t semaphore) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0) {
    if (deadline.timeIntervalSinceNow <= 0) return NO;
    LumenProbeRunApplicationForDuration(.01);
  }
  return YES;
}

@implementation LumenProbeSCKSource
- (BOOL)startDisplay:(CGDirectDisplayID)displayID width:(size_t)width height:(size_t)height
  hdr:(BOOL)hdr queue:(dispatch_queue_t)queue error:(NSError **)error {
  if (!CGPreflightScreenCaptureAccess()) {
    if (error) *error = [NSError errorWithDomain:@"LumenProbe" code:1
      userInfo:@{NSLocalizedDescriptionKey:@"SCK capture permission unavailable; no prompt requested"}];
    return NO;
  }
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block SCShareableContent *content;
  __block NSError *failure;
  [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
    completionHandler:^(SCShareableContent *value, NSError *e) {
      content = value; failure = e; dispatch_semaphore_signal(done);
    }];
  if (!LumenProbeWaitPumping(done) || !content) {
    if (error) *error = failure; return NO;
  }
  SCDisplay *display;
  for (SCDisplay *candidate in content.displays) if (candidate.displayID == displayID) display = candidate;
  if (!display) return NO;
  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
  SCStreamConfiguration *configuration = [SCStreamConfiguration new];
  configuration.captureDynamicRange = hdr ? SCCaptureDynamicRangeHDRCanonicalDisplay : SCCaptureDynamicRangeSDR;
  configuration.width = width; configuration.height = height;
  configuration.pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  configuration.colorSpaceName = hdr ? kCGColorSpaceITUR_2100_PQ : kCGColorSpaceITUR_709;
  configuration.colorMatrix = hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2;
  configuration.minimumFrameInterval = CMTimeMake(1,120); configuration.queueDepth = 2;
  configuration.showsCursor = YES; configuration.capturesAudio = NO;
  configuration.scalesToFit = YES; configuration.preservesAspectRatio = YES;
  self.stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:nil];
  if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:queue error:error]) return NO;
  [self.stream startCaptureWithCompletionHandler:^(NSError *e) { failure = e; dispatch_semaphore_signal(done); }];
  BOOL completed = LumenProbeWaitPumping(done);
  if (error) *error = failure;
  return completed && !failure;
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
  NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
  NSDictionary *info = attachments.firstObject;
  if (!info || [info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
  CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
  self.handler(kCGDisplayStreamFrameStatusFrameComplete,
    [info[SCStreamFrameInfoDisplayTime] unsignedLongLongValue],buffer,buffer ? kCVReturnSuccess : kCVReturnInvalidArgument);
}
- (int32_t)stop {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSError *failure;
  [self.stream stopCaptureWithCompletionHandler:^(NSError *error) { failure = error; dispatch_semaphore_signal(done); }];
  BOOL completed = LumenProbeWaitPumping(done);
  return completed && !failure ? 0 : -1;
}
@end

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
    @"videoToolboxStagingMode",
    @"videoToolboxStagedSourceReleaseMode",
    @"videoToolboxMetalStagePoolCapacity",
    @"videoToolboxMetalStageGPUCopyInFlight",
    @"videoToolboxMetalStageSubmissionCount",
    @"videoToolboxMetalStageCompletionCount",
    @"videoToolboxMetalStageBusyDropCount",
    @"videoToolboxMetalStagePoolAllocationFailureCount",
    @"videoToolboxMetalStageTextureFailureCount",
    @"videoToolboxMetalStageCommandBufferFailureCount",
    @"videoToolboxMetalStageValidationFailureCount",
    @"videoToolboxMetalStageLastError",
    @"videoToolboxEstimatedOutputBitrateKbps",
    @"videoToolboxMaxInflightStagingSlots",
    @"videoToolboxOutputWindowFrameRate",
    @"videoToolboxAdmissionWaitAverageMilliseconds",
    @"videoToolboxAdmissionWaitMaximumMilliseconds",
    @"videoToolboxEncodeInvocationAverageMilliseconds",
    @"videoToolboxEncodeInvocationMaximumMilliseconds",
    @"videoToolboxMetalStageAverageMilliseconds",
    @"videoToolboxMetalStageMaximumMilliseconds",
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
  LumenPipelineProbeCounters *counters,
  BOOL acknowledgeBootstrapFrames
) {
  while (true) {
    LumenMacEncodedCaptureEventRecord event =
      LumenMacBridgeControllerPopNextForwardedEvent(controller, NULL, 0);
    if (!event.has_value) {
      break;
    }
    if (counters != nil && event.kind == LumenMacCaptureEventKindFailed) {
      counters.captureFailureCount += 1;
    }
  }

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
    if (acknowledgeBootstrapFrames &&
        frame.requires_bootstrap_acknowledgement) {
      BOOL resumed = LumenMacBridgeResumeVideoEncodingAfterCodecAck();
      if (counters != nil) {
        if (resumed) {
          counters.bootstrapAcknowledgementCount += 1;
        } else {
          counters.bootstrapAcknowledgementFailureCount += 1;
        }
      }
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
      LumenProbeRunApplicationForDuration(.001);
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
  LumenProbeDrainForwardedFrames(controller, nil, NO);
  initialSnapshot =
    LumenMacBridgeControllerCopyVideoForwardingSnapshot(controller);

  LumenPipelineProbeCounters *counters =
    [[LumenPipelineProbeCounters alloc] init];
  uint64_t measurementStartNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  uint64_t measurementDeadline = measurementStartNanos +
    (uint64_t)(duration * (double)NSEC_PER_SEC);
  while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < measurementDeadline) {
    LumenProbeDrainForwardedFrames(controller, counters, YES);
    if (stimulusWindow != nil) {
      LumenProbeRunApplicationForDuration(.001);
    } else {
      usleep(1000);
    }
  }
  LumenProbeDrainForwardedFrames(controller, counters, YES);
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
    @"bootstrapAcknowledgementCount": @(
      counters.bootstrapAcknowledgementCount
    ),
    @"bootstrapAcknowledgementFailureCount": @(
      counters.bootstrapAcknowledgementFailureCount
    ),
    @"captureFailureCount": @(counters.captureFailureCount),
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
  return acknowledged &&
      counters.bootstrapAcknowledgementFailureCount == 0 &&
      counters.captureFailureCount == 0
    ? 0
    : 9;
}

// The existing capture callback queue owns this diagnostic state. VT callbacks
// return to that queue; no new coordination queue or lock is introduced.
@interface LumenProbeEncoder : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue width:(int)width height:(int)height
                         hdr:(BOOL)hdr bitrate:(int)bitrate lowLatency:(BOOL)lowLatency;
- (void)accept:(CVPixelBufferRef)buffer displayTime:(uint64_t)displayTime;
- (NSDictionary *)finish;
@property(nonatomic, readonly) BOOL ready;
@end

@implementation LumenProbeEncoder {
  dispatch_queue_t _queue;
  VTCompressionSessionRef _session;
  NSMutableDictionary *_properties;
  NSMutableArray<NSNumber *> *_latencies;
  NSMutableArray *_recoverySamples;
  uint64_t _submitted, _outputs, _busyDrops, _errors, _idrs, _bytes;
  uint64_t _start, _end;
  NSUInteger _inflight;
  BOOL _lowLatency, _hdr, _validHDR, _ready;
}
@synthesize ready = _ready;
- (instancetype)initWithQueue:(dispatch_queue_t)queue width:(int)width height:(int)height
                         hdr:(BOOL)hdr bitrate:(int)bitrate lowLatency:(BOOL)lowLatency {
  self = [super init];
  if (!self) return nil;
  _queue = queue; _lowLatency = lowLatency; _hdr = hdr; _validHDR = YES;
  _properties = [NSMutableDictionary dictionary];
  _latencies = [NSMutableArray array]; _recoverySamples = [NSMutableArray array];
  NSMutableDictionary *spec = [@{(__bridge id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES} mutableCopy];
  if (lowLatency) spec[(__bridge id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = @YES;
  OSType pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  OSStatus status = VTCompressionSessionCreate(NULL,width,height,kCMVideoCodecType_HEVC,
    (__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferPixelFormatTypeKey:@(pixelFormat)},
    NULL,NULL,NULL,&_session);
  _properties[@"create"] = @(status);
  if (status != noErr) return self;
  NSDictionary *properties = @{
    (__bridge id)kVTCompressionPropertyKey_RealTime:@YES,
    (__bridge id)kVTCompressionPropertyKey_AllowFrameReordering:@NO,
    (__bridge id)kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality:@YES,
    (__bridge id)kVTCompressionPropertyKey_ExpectedFrameRate:@120,
    (__bridge id)kVTCompressionPropertyKey_AverageBitRate:@((int64_t)bitrate*1000),
    (__bridge id)kVTCompressionPropertyKey_DataRateLimits:@[@((int64_t)bitrate*1000/8),@1],
    (__bridge id)kVTCompressionPropertyKey_ProfileLevel:(__bridge id)(hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel),
    (__bridge id)kVTCompressionPropertyKey_ColorPrimaries:(__bridge id)(hdr ? kCMFormatDescriptionColorPrimaries_ITU_R_2020 : kCMFormatDescriptionColorPrimaries_ITU_R_709_2),
    (__bridge id)kVTCompressionPropertyKey_TransferFunction:(__bridge id)(hdr ? kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ : kCMFormatDescriptionTransferFunction_ITU_R_709_2),
    (__bridge id)kVTCompressionPropertyKey_YCbCrMatrix:(__bridge id)(hdr ? kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 : kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
  };
  BOOL requiredPassed = YES;
  for (NSString *key in properties) {
    status = VTSessionSetProperty(_session,(__bridge CFStringRef)key,(__bridge CFTypeRef)properties[key]);
    _properties[key] = @(status);
    // Low-latency HEVC does not expose the ordinary encoder's speed hint.
    // Preserve all format/rate requirements; report this unsupported hint.
    if (status != noErr && !(lowLatency &&
        [key isEqualToString:(__bridge NSString *)kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality])) requiredPassed = NO;
  }
  status = VTSessionSetProperty(_session,kVTCompressionPropertyKey_AllowOpenGOP,kCFBooleanFalse);
  _properties[@"AllowOpenGOP"] = @(status);
  if (!lowLatency && status != noErr) requiredPassed = NO;
  _properties[@"MaxFrameDelayCount"] = @(VTSessionSetProperty(_session,kVTCompressionPropertyKey_MaxFrameDelayCount,(__bridge CFNumberRef)@1));
  status = VTCompressionSessionPrepareToEncodeFrames(_session);
  _properties[@"prepare"] = @(status);
  _ready = requiredPassed && status == noErr;
  return self;
}
- (void)accept:(CVPixelBufferRef)buffer displayTime:(uint64_t)displayTime {
  if (!_ready) return;
  if (_inflight >= 2) { _busyDrops++; return; }
  LumenMacSkyLightDisplayStreamFrameLease *lease = [LumenMacSkyLightDisplayStreamFrameLease leaseWithPixelBuffer:buffer];
  if (!lease) { _errors++; return; }
  uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  if (!_start) _start = started;
  BOOL force = (_submitted % 120) == 0;
  CMTime pts = CMTimeMake(_submitted++,120);
  _inflight++;
  OSStatus status = VTCompressionSessionEncodeFrameWithOutputHandler(_session,buffer,pts,CMTimeMake(1,120),
    (__bridge CFDictionaryRef)@{(__bridge id)kVTEncodeFrameOptionKey_ForceKeyFrame:@(force)},NULL,
    ^(OSStatus result, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
      uint64_t callback = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
      if (sample) CFRetain(sample);
      dispatch_async(self->_queue, ^{
        (void)lease; // Keep compositor ownership through the actual VT callback.
        self->_inflight--;
        if (result != noErr || !sample || (flags & kVTEncodeInfo_FrameDropped)) {
          self->_errors++;
        } else {
          self->_outputs++; self->_end = callback;
          [self->_latencies addObject:@((callback-started)/1e6)];
          CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
          size_t count = CMBlockBufferGetDataLength(block);
          self->_bytes += count;
          NSMutableData *data = [NSMutableData dataWithLength:count];
          CMBlockBufferCopyDataBytes(block,0,count,data.mutableBytes);
          const uint8_t *p = data.bytes;
          BOOL idr = NO;
          for (size_t offset=0; offset+6<=count;) {
            uint32_t length = ((uint32_t)p[offset]<<24)|((uint32_t)p[offset+1]<<16)|((uint32_t)p[offset+2]<<8)|p[offset+3];
            if (length < 2 || length > count-offset-4) { self->_errors++; break; }
            uint8_t type = (p[offset+4]>>1)&63;
            idr |= type == 19 || type == 20;
            offset += 4+length;
          }
          if (idr) { self->_idrs++; if (self->_recoverySamples.count < 3) [self->_recoverySamples removeAllObjects]; }
          if (self->_idrs > 1 && self->_recoverySamples.count < 3)
            [self->_recoverySamples addObject:(__bridge id)sample];
          CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
          if (self->_hdr) {
            CFTypeRef transfer = CMFormatDescriptionGetExtension(format,kCMFormatDescriptionExtension_TransferFunction);
            self->_validHDR &= transfer && CFEqual(transfer,kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
          }
        }
        if (sample) CFRelease(sample);
      });
    });
  if (status != noErr) { _inflight--; _errors++; }
}
- (NSDictionary *)finish {
  if (!_session) return @{@"encoderReady":@NO,@"encoderProperties":_properties};
  VTCompressionSessionCompleteFrames(_session,kCMTimeInvalid);
  __block NSDictionary *result;
  __block NSArray *samples;
  dispatch_sync(_queue, ^{
    double seconds = (self->_end-self->_start)/1e9;
    result = @{@"encoderReady":@(self->_ready),@"encoderLowLatency":@(self->_lowLatency),
      @"encoderProperties":self->_properties,@"encoderOutputCount":@(self->_outputs),
      @"encoderSubmissionCount":@(self->_submitted),@"encoderBusyDrops":@(self->_busyDrops),
      @"encoderErrors":@(self->_errors),@"encoderIDRCount":@(self->_idrs),@"encoderBytes":@(self->_bytes),
      @"encoderOutputFPS":@(seconds>0 ? self->_outputs/seconds : 0),@"encoderHDRTransferValid":@(self->_validHDR && self->_outputs>0),
      @"encoderCallbackP50Milliseconds":@(LumenProbePercentile(self->_latencies,.5)),
      @"encoderCallbackP95Milliseconds":@(LumenProbePercentile(self->_latencies,.95))};
    samples = [self->_recoverySamples copy];
  });
  VTCompressionSessionInvalidate(_session); CFRelease(_session); _session = NULL;
  // Decode a later IDR and its successors in a fresh hardware-required session.
  __block NSUInteger decoded = 0;
  OSStatus decodeStatus = -1;
  if (samples.count == 3) {
    VTDecompressionSessionRef decoder = NULL;
    decodeStatus = VTDecompressionSessionCreate(NULL,CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)samples[0]),
      (__bridge CFDictionaryRef)@{(__bridge id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:@YES},NULL,NULL,&decoder);
    if (decodeStatus == noErr) {
      for (id object in samples) {
        OSStatus status = VTDecompressionSessionDecodeFrameWithOutputHandler(decoder,(__bridge CMSampleBufferRef)object,0,NULL,
          ^(OSStatus s, VTDecodeInfoFlags f, CVImageBufferRef image, CMTime pts, CMTime duration) {
            dispatch_async(self->_queue, ^{ if (s == noErr && image != NULL) decoded++; });
          });
        if (status != noErr) decodeStatus = status;
      }
      VTDecompressionSessionWaitForAsynchronousFrames(decoder);
      VTDecompressionSessionInvalidate(decoder); CFRelease(decoder);
      dispatch_sync(_queue, ^{});
    }
  }
  NSMutableDictionary *output = [result mutableCopy];
  output[@"freshHardwareDecodeStatus"] = @(decodeStatus);
  output[@"freshHardwareDecodedFrames"] = @(decoded);
  return output;
}
@end

static LumenMacVirtualDisplay *LumenProbeOwnedDisplay;
static void LumenProbeDestroyOwnedDisplay(void) { [LumenProbeOwnedDisplay destroy]; LumenProbeOwnedDisplay = nil; }

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
    NSString *sourceMode = LumenProbeArgument(argc,argv,@"--source") ?: @"private";
    BOOL useSCK = [sourceMode isEqualToString:@"sck"];
    if (!useSCK && ![sourceMode isEqualToString:@"private"]) return 13;
    if (LumenProbeHasFlag(argc,argv,@"--pipeline") &&
        (useSCK || LumenProbeArgument(argc,argv,@"--encoder-mode"))) {
      LumenProbePrintJSON(@{@"error":@"source-and-encoder-selectors-only-raw"}); return 13;
    }
    if (LumenProbeHasFlag(argc, argv, @"--virtual-display")) {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      [NSApp finishLaunching];
      LumenMacVirtualDisplayConfiguration *configuration = [LumenMacVirtualDisplayConfiguration new];
      configuration.name = @"Lumen Isolated Measurement";
      configuration.vendorID = 0xF0F0; configuration.productID = 0x5151; configuration.serialNumber = (uint32_t)getpid();
      configuration.backingWidth = configuration.maximumBackingWidth = configuration.logicalWidth = (uint32_t)outputWidth;
      configuration.backingHeight = configuration.maximumBackingHeight = configuration.logicalHeight = (uint32_t)outputHeight;
      configuration.refreshRate = 120; configuration.highDensity = NO; configuration.hdrEnabled = hdr;
      configuration.gamut = hdr ? LumenMacVirtualDisplayGamutRec2020 : LumenMacVirtualDisplayGamutSRGB;
      configuration.transfer = hdr ? LumenMacVirtualDisplayTransferPQ : LumenMacVirtualDisplayTransferSDR;
      configuration.currentEDRHeadroom = configuration.potentialEDRHeadroom = hdr ? 5 : 1;
      configuration.currentPeakLuminanceNits = configuration.potentialPeakLuminanceNits = hdr ? 1000 : 200;
      NSError *error;
      LumenProbeOwnedDisplay = [[LumenMacVirtualDisplay alloc] initWithConfiguration:configuration error:&error];
      atexit(LumenProbeDestroyOwnedDisplay);
      // WindowServer publishes modes asynchronously after creation.
      BOOL selected = NO;
      for (NSUInteger attempt = 0; LumenProbeOwnedDisplay && attempt < 80; attempt++) {
        LumenProbeRunApplicationForDuration(.1);
        selected = [LumenProbeOwnedDisplay selectPublishedModeWithError:&error];
        if (selected) break;
      }
      if (!selected) {
        LumenProbePrintJSON(@{@"error":@"isolated-display-create-failed",@"message":error.localizedDescription ?: @"unknown",
          @"displayID":@(LumenProbeOwnedDisplay.displayID),@"onlineDisplays":LumenProbeOnlineDisplays()}); return 10;
      }
      displayID = LumenProbeOwnedDisplay.displayID;
      LumenProbeRunApplicationForDuration(.5);
      if (CGDisplayIsMain(displayID) || CGDisplayIsBuiltin(displayID) ||
          CGDisplayPixelsWide(displayID) != outputWidth || CGDisplayPixelsHigh(displayID) != outputHeight) {
        LumenProbePrintJSON(@{@"error":@"isolated-display-contract-failed"}); return 11;
      }
      onlineDisplays = LumenProbeOnlineDisplays();
    }
    if (stimulus && (CGDisplayIsMain(displayID) || CGDisplayIsBuiltin(displayID))) {
      LumenProbePrintJSON(@{@"error":@"stimulus-requires-independent-display"}); return 12;
    }
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

    if (!useSCK && ![LumenMacSkyLightDisplayStream isSupported]) {
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
    NSString *encoderMode = LumenProbeArgument(argc,argv,@"--encoder-mode");
    if (encoderMode && ![@[@"regular",@"low-latency"] containsObject:encoderMode]) {
      LumenProbePrintJSON(@{@"error":@"invalid-encoder-mode"}); return 13;
    }
    LumenProbeEncoder *encoder = encoderMode ? [[LumenProbeEncoder alloc]
      initWithQueue:callbackQueue width:(int)outputWidth height:(int)outputHeight hdr:hdr
      bitrate:targetBitrateKbps lowLatency:[encoderMode isEqualToString:@"low-latency"]] : nil;
    if (encoder && !encoder.ready) { LumenProbePrintJSON([encoder finish]); return 14; }
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

    LumenMacSkyLightDisplayStreamFrameHandler handler = ^(CGDisplayStreamFrameStatus status,
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
      if (status == kCGDisplayStreamFrameStatusFrameComplete && pixelBufferStatus == kCVReturnSuccess && pixelBuffer)
        [encoder accept:pixelBuffer displayTime:displayTime];
    };
    LumenMacSkyLightDisplayStream *stream = useSCK ? nil : [[LumenMacSkyLightDisplayStream alloc]
      initWithDisplayID:displayID outputWidth:outputWidth outputHeight:outputHeight pixelFormat:pixelFormat
      minimumFrameTime:0 queueDepth:2 showCursor:YES yCbCrMatrix:matrix dynamicRangeMode:hdr ? 2 : 0
      colorSpaceName:colorSpace callbackQueue:callbackQueue frameHandler:handler];
    LumenProbeSCKSource *sck = useSCK ? [LumenProbeSCKSource new] : nil;
    sck.handler = handler;
    if (!useSCK && stream == nil) {
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
    BOOL started = useSCK ? [sck startDisplay:displayID width:outputWidth height:outputHeight
      hdr:hdr queue:callbackQueue error:&startError] : [stream startWithError:&startError];
    if (!started) {
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
    int32_t stopStatus = useSCK ? [sck stop] : [stream stop];
    dispatch_sync(callbackQueue, ^{});
    NSDictionary *encoderMetrics = encoder ? [encoder finish] : @{};
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
      @"backend": useSCK ? @"screencapturekit" : stream.backendName,
      @"encoderComparison": encoderMetrics,
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
    BOOL encoderPassed = !encoder || ([encoderMetrics[@"encoderErrors"] unsignedIntegerValue] == 0 &&
      [encoderMetrics[@"encoderHDRTransferValid"] boolValue] &&
      [encoderMetrics[@"freshHardwareDecodeStatus"] intValue] == 0 &&
      [encoderMetrics[@"freshHardwareDecodedFrames"] intValue] == 3);
    return firstFrameWait == 0 && wrapFailureCount == 0 && encoderPassed ? 0 : 5;
  }
}
