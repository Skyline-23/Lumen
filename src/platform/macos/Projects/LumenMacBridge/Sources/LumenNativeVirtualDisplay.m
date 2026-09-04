#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

#import "LumenMacBridge.h"

#include <dlfcn.h>
#include <math.h>

static NSString *const LumenMacVirtualDisplayErrorDomain = @"dev.skyline23.lumen.virtual-display";

typedef NS_ENUM(NSInteger, LumenMacVirtualDisplayErrorCode) {
  LumenMacVirtualDisplayErrorInvalidConfiguration = 1,
  LumenMacVirtualDisplayErrorUnsupportedRuntime = 2,
  LumenMacVirtualDisplayErrorObjectCreationFailed = 3,
  LumenMacVirtualDisplayErrorSettingsRejected = 4,
  LumenMacVirtualDisplayErrorMissingDisplayID = 5,
  LumenMacVirtualDisplayErrorModeSelectionFailed = 6,
};

static void LumenAssignVirtualDisplayError(
  NSError **error,
  LumenMacVirtualDisplayErrorCode code,
  NSString *description
) {
  if (error == NULL) {
    return;
  }
  *error = [NSError errorWithDomain:LumenMacVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSString *LumenMacDisplayStringConstant(const char *symbolName) {
  static void *coreDisplay = NULL;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    coreDisplay = dlopen(
      "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
      RTLD_LAZY | RTLD_LOCAL
    );
  });
  if (coreDisplay == NULL || symbolName == NULL) {
    return nil;
  }

  const void *const *constant = (const void *const *)dlsym(coreDisplay, symbolName);
  return constant == NULL || *constant == NULL ? nil : (__bridge NSString *)*constant;
}

static NSSize LumenPhysicalDisplaySize(uint32_t width, uint32_t height) {
  const double pixelsPerInch = 218.0;
  const double millimetersPerInch = 25.4;
  const double widthMM = fmin(fmax(((double)MAX(width, 1u) / pixelsPerInch) * millimetersPerInch, 120.0), 1200.0);
  const double heightMM = fmin(fmax(((double)MAX(height, 1u) / pixelsPerInch) * millimetersPerInch, 80.0), 900.0);
  return NSMakeSize(widthMM, heightMM);
}

// SkyLight's private virtual-display API is intentionally resolved at runtime.
// These are the ABI shapes used by macOS 27's SLVirtualDisplay classes; keeping
// them local avoids making the private framework part of the public build SDK.
typedef struct {
  float width;
  float height;
} LumenSkyLightSize;

typedef struct {
  unsigned int width;
  unsigned int height;
} LumenSkyLightPixels;

typedef struct {
  float x;
  float y;
} LumenSkyLightPoint;

typedef struct {
  LumenSkyLightPoint red;
  LumenSkyLightPoint green;
  LumenSkyLightPoint blue;
  LumenSkyLightPoint white;
} LumenSkyLightChromaticities;

static BOOL LumenSkyLightClassesAvailable(void) {
  return NSClassFromString(@"SLVirtualDisplay") != nil &&
         NSClassFromString(@"SLVirtualDisplayMode") != nil &&
         NSClassFromString(@"SLVirtualDisplaySettings") != nil &&
         NSClassFromString(@"SLVirtualDisplayConfiguration") != nil;
}

static BOOL LumenCGVirtualDisplayClassesAvailable(void) {
  return NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
         NSClassFromString(@"CGVirtualDisplayMode") != nil &&
         NSClassFromString(@"CGVirtualDisplaySettings") != nil &&
         NSClassFromString(@"CGVirtualDisplay") != nil;
}

static NSUInteger LumenSkyLightEOTF(
  LumenMacVirtualDisplayConfiguration *configuration
) {
  return configuration.hdrEnabled ||
         configuration.transfer != LumenMacVirtualDisplayTransferSDR
    ? 1u
    : 0u;
}

static uint32_t LumenEvenPointsForScale(uint32_t backingDimension, double scale) {
  if (backingDimension == 0 || scale <= 0.0) {
    return 0;
  }
  uint64_t points = (uint64_t)llround((double)backingDimension / scale);
  points = MAX(points, 2u);
  if (points > UINT32_MAX) {
    points = UINT32_MAX;
  }
  return (uint32_t)points & ~1u;
}

static id LumenCreateSkyLightMode(
  Class modeClass,
  uint32_t pixelWidth,
  uint32_t pixelHeight,
  uint32_t logicalWidth,
  uint32_t logicalHeight,
  double refreshRate,
  NSUInteger eotf,
  NSError **error
) {
  if (modeClass == Nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"SLVirtualDisplayMode is unavailable."
    );
    return nil;
  }

  SEL selector = sel_registerName(
    "initWithSizeInPixels:sizeInPoints:refreshRate:error:"
  );
  if (![modeClass instancesRespondToSelector:selector]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"SLVirtualDisplayMode does not expose its size-in-pixels initializer."
    );
    return nil;
  }

  typedef id (*LumenSkyLightModeInitializer)(
    id,
    SEL,
    LumenSkyLightPixels,
    LumenSkyLightPixels,
    float,
    NSError **
  );
  LumenSkyLightModeInitializer initializer =
    (LumenSkyLightModeInitializer)objc_msgSend;
  const LumenSkyLightPixels sizeInPixels = {
    pixelWidth,
    pixelHeight
  };
  const LumenSkyLightPixels sizeInPoints = {
    MAX(logicalWidth, 1u),
    MAX(logicalHeight, 1u)
  };
  id mode = initializer(
    [modeClass alloc],
    selector,
    sizeInPixels,
    sizeInPoints,
    (float)refreshRate,
    error
  );
  if (mode != nil) {
    SEL eotfSelector = sel_registerName("setEotf:");
    if ([mode respondsToSelector:eotfSelector]) {
      typedef void (*LumenSkyLightEOTFSetter)(id, SEL, NSUInteger);
      ((LumenSkyLightEOTFSetter)objc_msgSend)(mode, eotfSelector, eotf);
    }
  }
  return mode;
}

static NSArray *LumenCreateSkyLightOptionalModes(
  Class modeClass,
  uint32_t pixelWidth,
  uint32_t pixelHeight,
  uint32_t preferredWidth,
  uint32_t preferredHeight,
  double refreshRate,
  NSUInteger eotf
) {
  NSMutableArray *modes = [NSMutableArray array];
  NSMutableSet<NSString *> *emitted = [NSMutableSet set];
  const double scaleSteps[] = {1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0};

  void (^appendMode)(uint32_t, uint32_t) = ^(uint32_t logicalWidth, uint32_t logicalHeight) {
    if (logicalWidth == 0 || logicalHeight == 0 ||
        logicalWidth > pixelWidth || logicalHeight > pixelHeight) {
      return;
    }
    const double backingAspect = (double)pixelWidth / (double)pixelHeight;
    const double logicalAspect = (double)logicalWidth / (double)logicalHeight;
    const double aspectDelta = fabs(logicalAspect - backingAspect) / backingAspect;
    if (aspectDelta > 0.02) {
      return;
    }
    NSString *key = [NSString stringWithFormat:@"%u:%u", logicalWidth, logicalHeight];
    if ([emitted containsObject:key]) {
      return;
    }
    id mode = LumenCreateSkyLightMode(
      modeClass,
      pixelWidth,
      pixelHeight,
      logicalWidth,
      logicalHeight,
      refreshRate,
      eotf,
      NULL
    );
    if (mode != nil) {
      [modes addObject:mode];
      [emitted addObject:key];
    }
  };

  for (NSUInteger index = 0;
       index < sizeof(scaleSteps) / sizeof(scaleSteps[0]);
       index++) {
    appendMode(
      LumenEvenPointsForScale(pixelWidth, scaleSteps[index]),
      LumenEvenPointsForScale(pixelHeight, scaleSteps[index])
    );
  }
  appendMode(preferredWidth, preferredHeight);
  return modes;
}

static BOOL LumenDisplayModeMatches(
  CGDisplayModeRef mode,
  uint32_t logicalWidth,
  uint32_t logicalHeight,
  uint32_t backingWidth,
  uint32_t backingHeight,
  double refreshRate
) {
  if (mode == NULL) {
    return NO;
  }
  const double candidateRefreshRate = CGDisplayModeGetRefreshRate(mode);
  const BOOL refreshMatches = candidateRefreshRate <= 0 ||
    fabs(candidateRefreshRate - refreshRate) < 0.5;
  return CGDisplayModeGetWidth(mode) == logicalWidth &&
         CGDisplayModeGetHeight(mode) == logicalHeight &&
         CGDisplayModeGetPixelWidth(mode) == backingWidth &&
         CGDisplayModeGetPixelHeight(mode) == backingHeight &&
         refreshMatches;
}

static BOOL LumenSelectPublishedHiDPIMode(
  CGDirectDisplayID displayID,
  uint32_t logicalWidth,
  uint32_t logicalHeight,
  uint32_t backingWidth,
  uint32_t backingHeight,
  double refreshRate,
  NSError **error
) {
  const void *keys[] = {kCGDisplayShowDuplicateLowResolutionModes};
  const void *values[] = {kCFBooleanTrue};
  CFDictionaryRef options = CFDictionaryCreate(
    kCFAllocatorDefault,
    keys,
    values,
    1,
    &kCFTypeDictionaryKeyCallBacks,
    &kCFTypeDictionaryValueCallBacks
  );
  CGDisplayModeRef selectedMode = NULL;
  NSMutableArray<NSString *> *observedModes = [NSMutableArray array];
  CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, options);
  if (modes != NULL) {
    const CFIndex count = CFArrayGetCount(modes);
    for (CFIndex index = 0; index < count; index++) {
      CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(
        modes,
        index
      );
      const double candidateRefreshRate = CGDisplayModeGetRefreshRate(mode);
      [observedModes addObject:[NSString stringWithFormat:
        @"%zux%zu pixels=%zux%zu refresh=%.3f flags=0x%08x",
        CGDisplayModeGetWidth(mode),
        CGDisplayModeGetHeight(mode),
        CGDisplayModeGetPixelWidth(mode),
        CGDisplayModeGetPixelHeight(mode),
        candidateRefreshRate,
        (unsigned int)CGDisplayModeGetIOFlags(mode)
      ]];
      if (LumenDisplayModeMatches(
        mode,
        logicalWidth,
        logicalHeight,
        backingWidth,
        backingHeight,
        refreshRate
      )) {
        selectedMode = CGDisplayModeRetain(mode);
        break;
      }
    }
    CFRelease(modes);
  }
  if (options != NULL) {
    CFRelease(options);
  }
  if (selectedMode == NULL) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorModeSelectionFailed,
      [NSString stringWithFormat:
        @"The published HiDPI mode %ux%u (pixels %ux%u) @ %.0fHz was not available. Observed modes: %@",
        logicalWidth,
        logicalHeight,
        backingWidth,
        backingHeight,
        refreshRate,
        observedModes.count == 0
          ? @"none"
          : [observedModes componentsJoinedByString:@"; "]]
    );
    return NO;
  }
  const CGError result = CGDisplaySetDisplayMode(displayID, selectedMode, NULL);
  CGDisplayModeRelease(selectedMode);
  if (result != kCGErrorSuccess) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorModeSelectionFailed,
      [NSString stringWithFormat:
        @"Failed to select the published HiDPI display mode (%d).",
        result]
    );
    return NO;
  }
  CGDisplayModeRef appliedMode = CGDisplayCopyDisplayMode(displayID);
  const BOOL applied = LumenDisplayModeMatches(
    appliedMode,
    logicalWidth,
    logicalHeight,
    backingWidth,
    backingHeight,
    refreshRate
  );
  if (appliedMode != NULL) {
    CGDisplayModeRelease(appliedMode);
  }
  if (!applied) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorModeSelectionFailed,
      @"The selected HiDPI display mode has not settled yet."
    );
    return NO;
  }
  return YES;
}

static void LumenColorPrimaries(
  LumenMacVirtualDisplayGamut gamut,
  NSPoint *red,
  NSPoint *green,
  NSPoint *blue,
  NSPoint *white
) {
  *white = NSMakePoint(0.3127, 0.3290);
  switch (gamut) {
    case LumenMacVirtualDisplayGamutDisplayP3:
      *red = NSMakePoint(0.6800, 0.3200);
      *green = NSMakePoint(0.2650, 0.6900);
      *blue = NSMakePoint(0.1500, 0.0600);
      break;
    case LumenMacVirtualDisplayGamutRec2020:
      *red = NSMakePoint(0.7080, 0.2920);
      *green = NSMakePoint(0.1700, 0.7970);
      *blue = NSMakePoint(0.1310, 0.0460);
      break;
    case LumenMacVirtualDisplayGamutSRGB:
    default:
      *red = NSMakePoint(0.6400, 0.3300);
      *green = NSMakePoint(0.3000, 0.6000);
      *blue = NSMakePoint(0.1500, 0.0600);
      break;
  }
}

static int LumenTransferFunctionCode(LumenMacVirtualDisplayConfiguration *configuration) {
  if (!configuration.hdrEnabled || configuration.transfer == LumenMacVirtualDisplayTransferSDR) {
    return CVTransferFunctionGetIntegerCodePointForString(
      kCVImageBufferTransferFunction_ITU_R_709_2
    );
  }
  if (configuration.transfer == LumenMacVirtualDisplayTransferHLG) {
    return CVTransferFunctionGetIntegerCodePointForString(
      kCVImageBufferTransferFunction_ITU_R_2100_HLG
    );
  }
  return CVTransferFunctionGetIntegerCodePointForString(
    kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
  );
}

static double LumenEffectivePeakLuminance(LumenMacVirtualDisplayConfiguration *configuration) {
  if (configuration.potentialPeakLuminanceNits > 0) {
    return configuration.potentialPeakLuminanceNits;
  }
  if (configuration.currentPeakLuminanceNits > 0) {
    return configuration.currentPeakLuminanceNits;
  }
  return configuration.gamut == LumenMacVirtualDisplayGamutSRGB ? 600.0 : 1000.0;
}

static double LumenEffectiveSDRLuminance(
  LumenMacVirtualDisplayConfiguration *configuration,
  double peakLuminance
) {
  double luminance = configuration.gamut == LumenMacVirtualDisplayGamutSRGB ? 200.0 : 300.0;
  if (configuration.currentPeakLuminanceNits > 0 && configuration.currentEDRHeadroom > 1.0) {
    luminance = configuration.currentPeakLuminanceNits / configuration.currentEDRHeadroom;
  } else if (configuration.potentialPeakLuminanceNits > 0 && configuration.potentialEDRHeadroom > 1.0) {
    luminance = configuration.potentialPeakLuminanceNits / configuration.potentialEDRHeadroom;
  }
  return fmin(fmax(luminance, 80.0), peakLuminance);
}

static void LumenConfigureHDRDisplayInfo(
  id descriptor,
  LumenMacVirtualDisplayConfiguration *configuration
) {
  if (!configuration.hdrEnabled) {
    return;
  }

  SEL displayInfoSelector = sel_registerName("displayInfo");
  SEL setterSelector = sel_registerName("setDisplayInfoValue:forKey:");
  if (![descriptor respondsToSelector:displayInfoSelector] ||
      ![descriptor respondsToSelector:setterSelector]) {
    return;
  }

  NSDictionary *displayInfo = ((id (*)(id, SEL))objc_msgSend)(descriptor, displayInfoSelector);
  if (![displayInfo isKindOfClass:NSDictionary.class]) {
    return;
  }

  const double peak = LumenEffectivePeakLuminance(configuration);
  const double sdr = LumenEffectiveSDRLuminance(configuration, peak);
  NSDictionary<NSString *, NSNumber *> *values = @{
    @"kCDDisplayPresetMaxHDRLuminanceKey": @(peak),
    @"kCDDisplayPresetMaxSDRLuminanceKey": @(sdr),
    @"kCDDisplayPresetMinLuminanceKey": @0.001,
    @"kCDDisplayUserAdjustmentExpectedLuminanceKey": @(sdr),
  };
  void (*setDisplayInfo)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
  [values enumerateKeysAndObjectsUsingBlock:^(NSString *symbol, NSNumber *value, BOOL *stop) {
    (void)stop;
    NSString *key = LumenMacDisplayStringConstant(symbol.UTF8String);
    if (key != nil) {
      setDisplayInfo(descriptor, setterSelector, value, key);
    }
  }];
}

@implementation LumenMacVirtualDisplayConfiguration

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _name = @"Lumen Display";
    _vendorID = 6973u;
    _productID = 0xA901u;
    _serialNumber = 1u;
    _refreshRate = 60.0;
    _highDensity = YES;
    _gamut = LumenMacVirtualDisplayGamutSRGB;
    _transfer = LumenMacVirtualDisplayTransferSDR;
  }
  return self;
}

@end

@interface LumenMacVirtualDisplay ()
@property(nonatomic) uint32_t displayID;
@property(nonatomic) uint32_t backingWidth;
@property(nonatomic) uint32_t backingHeight;
@property(nonatomic) uint32_t maximumBackingWidth;
@property(nonatomic) uint32_t maximumBackingHeight;
@property(nonatomic) uint32_t logicalWidth;
@property(nonatomic) uint32_t logicalHeight;
@property(nonatomic) double refreshRate;
@property(nonatomic) BOOL highDensity;
@property(nonatomic) BOOL usesSkyLightBackend;
@property(nonatomic, strong) id descriptor;
@property(nonatomic, strong) id mode;
@property(nonatomic, strong) id nativeMode;
@property(nonatomic, strong) id settings;
@property(nonatomic, strong) id display;
@property(nonatomic, strong) dispatch_queue_t callbackQueue;
@property(nonatomic) LumenMacVirtualDisplayTransfer transfer;
@property(nonatomic) BOOL hdrEnabled;

- (nullable id)createModeWithLogicalWidth:(uint32_t)logicalWidth
                            logicalHeight:(uint32_t)logicalHeight
                              refreshRate:(double)refreshRate
                                 transfer:(LumenMacVirtualDisplayTransfer)transfer
                               hdrEnabled:(BOOL)hdrEnabled
                                    error:(NSError **)error;
- (BOOL)configureCGVirtualDisplayWithConfiguration:(LumenMacVirtualDisplayConfiguration *)configuration
                                maximumBackingWidth:(uint32_t)maximumBackingWidth
                               maximumBackingHeight:(uint32_t)maximumBackingHeight
                                               error:(NSError **)error;
- (BOOL)configureSkyLightVirtualDisplayWithConfiguration:(LumenMacVirtualDisplayConfiguration *)configuration
                                      maximumBackingWidth:(uint32_t)maximumBackingWidth
                                     maximumBackingHeight:(uint32_t)maximumBackingHeight
                                                     error:(NSError **)error;
- (BOOL)updateSkyLightModeWithLogicalWidth:(uint32_t)logicalWidth
                              logicalHeight:(uint32_t)logicalHeight
                                refreshRate:(double)refreshRate
                         requiredBackingWidth:(uint32_t)requiredBackingWidth
                        requiredBackingHeight:(uint32_t)requiredBackingHeight
                                       error:(NSError **)error;
- (BOOL)configureWithConfiguration:(LumenMacVirtualDisplayConfiguration *)configuration
                             error:(NSError **)error;
- (BOOL)applyVirtualDisplaySettings:(id)settings;
@end

@implementation LumenMacVirtualDisplay

+ (NSMutableDictionary<NSString *, LumenMacVirtualDisplay *> *)displayRegistry {
  static NSMutableDictionary<NSString *, LumenMacVirtualDisplay *> *registry;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    registry = [NSMutableDictionary dictionary];
  });
  return registry;
}

+ (NSMutableSet<NSString *> *)displayRegistryReservations {
  static NSMutableSet<NSString *> *reservations;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    reservations = [NSMutableSet set];
  });
  return reservations;
}

+ (dispatch_queue_t)displayRegistryQueue {
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create(
      "dev.skyline23.lumen.virtual-display-registry",
      DISPATCH_QUEUE_SERIAL
    );
  });
  return queue;
}

+ (BOOL)isSupported {
  return LumenSkyLightClassesAvailable() ||
         LumenCGVirtualDisplayClassesAvailable();
}

+ (nullable instancetype)createRegisteredDisplayForKey:(NSString *)key
                                          configuration:(LumenMacVirtualDisplayConfiguration *)configuration
                                                  error:(NSError **)error {
  if (key.length == 0) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      @"A stable virtual display key is required."
    );
    return nil;
  }

  __block BOOL reserved = NO;
  dispatch_sync(self.displayRegistryQueue, ^{
    if (self.displayRegistry[key] == nil &&
        ![self.displayRegistryReservations containsObject:key]) {
      [self.displayRegistryReservations addObject:key];
      reserved = YES;
    }
  });
  if (!reserved) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      @"The virtual display key is already owned."
    );
    return nil;
  }

  LumenMacVirtualDisplay *display = [[self alloc] initWithConfiguration:configuration error:error];
  if (display == nil) {
    dispatch_sync(self.displayRegistryQueue, ^{
      [self.displayRegistryReservations removeObject:key];
    });
    return nil;
  }

  __block BOOL inserted = NO;
  dispatch_sync(self.displayRegistryQueue, ^{
    [self.displayRegistryReservations removeObject:key];
    if (self.displayRegistry[key] == nil) {
      self.displayRegistry[key] = display;
      inserted = YES;
    }
  });
  if (!inserted) {
    [display destroy];
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      @"The virtual display key is already owned."
    );
    return nil;
  }
  return display;
}

+ (nullable instancetype)registeredDisplayForKey:(NSString *)key {
  __block LumenMacVirtualDisplay *display;
  dispatch_sync(self.displayRegistryQueue, ^{
    display = self.displayRegistry[key];
  });
  return display;
}

+ (nullable instancetype)registeredDisplayForDisplayID:(uint32_t)displayID {
  __block LumenMacVirtualDisplay *match;
  dispatch_sync(self.displayRegistryQueue, ^{
    for (LumenMacVirtualDisplay *display in self.displayRegistry.allValues) {
      if (display.displayID == displayID) {
        match = display;
        break;
      }
    }
  });
  return match;
}

+ (BOOL)removeRegisteredDisplayForKey:(NSString *)key {
  __block LumenMacVirtualDisplay *display;
  dispatch_sync(self.displayRegistryQueue, ^{
    display = self.displayRegistry[key];
    [self.displayRegistry removeObjectForKey:key];
  });
  [display destroy];
  return display != nil;
}

+ (BOOL)removeRegisteredDisplayForKey:(NSString *)key
                  ifMatchingDisplay:(LumenMacVirtualDisplay *)expectedDisplay {
  __block LumenMacVirtualDisplay *display;
  dispatch_sync(self.displayRegistryQueue, ^{
    display = self.displayRegistry[key];
    if (display != expectedDisplay) {
      display = nil;
      return;
    }
    [self.displayRegistry removeObjectForKey:key];
  });
  [display destroy];
  return display != nil;
}

+ (void)destroyAllRegisteredDisplays {
  __block NSArray<LumenMacVirtualDisplay *> *displays;
  dispatch_sync(self.displayRegistryQueue, ^{
    displays = self.displayRegistry.allValues;
    [self.displayRegistry removeAllObjects];
  });
  for (LumenMacVirtualDisplay *display in displays) {
    [display destroy];
  }
}

- (nullable instancetype)initWithConfiguration:(LumenMacVirtualDisplayConfiguration *)configuration
                                          error:(NSError **)error {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  __block NSError *mainThreadError = nil;
  __block BOOL configured = NO;
  if (![NSThread isMainThread]) {
    dispatch_sync(dispatch_get_main_queue(), ^{
      configured = [self configureWithConfiguration:configuration
                                               error:&mainThreadError];
    });
  } else {
    configured = [self configureWithConfiguration:configuration
                                             error:&mainThreadError];
  }
  if (!configured && error != NULL) {
    *error = mainThreadError;
  }
  return configured ? self : nil;
}

- (BOOL)configureCGVirtualDisplayWithConfiguration:(LumenMacVirtualDisplayConfiguration *)configuration
                                maximumBackingWidth:(uint32_t)maximumBackingWidth
                               maximumBackingHeight:(uint32_t)maximumBackingHeight
                                               error:(NSError **)error {
  Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
  Class displayClass = NSClassFromString(@"CGVirtualDisplay");
  Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
  _descriptor = [[descriptorClass alloc] init];
  _callbackQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  if (_descriptor == nil || _callbackQueue == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      @"Failed to allocate the CG virtual display descriptor."
    );
    return NO;
  }

  NSPoint red;
  NSPoint green;
  NSPoint blue;
  NSPoint white;
  LumenColorPrimaries(configuration.gamut, &red, &green, &blue, &white);
  [_descriptor setValue:@(configuration.vendorID) forKey:@"vendorID"];
  [_descriptor setValue:@(configuration.productID) forKey:@"productID"];
  BOOL assignedSerial = NO;
  SEL serialNumberSelector = sel_registerName("setSerialNumber:");
  if ([_descriptor respondsToSelector:serialNumberSelector]) {
    ((void (*)(id, SEL, unsigned int))objc_msgSend)(
      _descriptor,
      serialNumberSelector,
      configuration.serialNumber
    );
    assignedSerial = YES;
  }
  SEL serialNumSelector = sel_registerName("setSerialNum:");
  if ([_descriptor respondsToSelector:serialNumSelector]) {
    ((void (*)(id, SEL, unsigned int))objc_msgSend)(
      _descriptor,
      serialNumSelector,
      configuration.serialNumber
    );
    assignedSerial = YES;
  }
  if (!assignedSerial) {
    [_descriptor setValue:@(configuration.serialNumber) forKey:@"serialNumber"];
  }
  [_descriptor setValue:configuration.name forKey:@"name"];
  [_descriptor setValue:[NSValue valueWithSize:LumenPhysicalDisplaySize(
    configuration.backingWidth,
    configuration.backingHeight
  )] forKey:@"sizeInMillimeters"];
  [_descriptor setValue:@(maximumBackingWidth) forKey:@"maxPixelsWide"];
  [_descriptor setValue:@(maximumBackingHeight) forKey:@"maxPixelsHigh"];
  [_descriptor setValue:[NSValue valueWithPoint:red] forKey:@"redPrimary"];
  [_descriptor setValue:[NSValue valueWithPoint:green] forKey:@"greenPrimary"];
  [_descriptor setValue:[NSValue valueWithPoint:blue] forKey:@"bluePrimary"];
  [_descriptor setValue:[NSValue valueWithPoint:white] forKey:@"whitePoint"];
  BOOL assignedQueue = NO;
  SEL queueSelector = sel_registerName("setQueue:");
  if ([_descriptor respondsToSelector:queueSelector]) {
    ((void (*)(id, SEL, dispatch_queue_t))objc_msgSend)(
      _descriptor,
      queueSelector,
      _callbackQueue
    );
    assignedQueue = YES;
  }
  SEL dispatchQueueSelector = sel_registerName("setDispatchQueue:");
  if ([_descriptor respondsToSelector:dispatchQueueSelector]) {
    ((void (*)(id, SEL, dispatch_queue_t))objc_msgSend)(
      _descriptor,
      dispatchQueueSelector,
      _callbackQueue
    );
    assignedQueue = YES;
  }
  if (!assignedQueue) {
    [_descriptor setValue:_callbackQueue forKey:@"queue"];
  }
  SEL terminationSelector = sel_registerName("setTerminationHandler:");
  if ([_descriptor respondsToSelector:terminationSelector]) {
    void (^terminationHandler)(id, id) = ^(__unused id reason, __unused id display) {};
    ((void (*)(id, SEL, id))objc_msgSend)(
      _descriptor,
      terminationSelector,
      terminationHandler
    );
  }
  LumenConfigureHDRDisplayInfo(_descriptor, configuration);

  _display = ((id (*)(id, SEL, id))objc_msgSend)(
    [displayClass alloc],
    sel_registerName("initWithDescriptor:"),
    _descriptor
  );
  if (_display == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      @"Failed to create the CG virtual display instance."
    );
    return NO;
  }

  _settings = [[settingsClass alloc] init];
  if (_settings == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      @"Failed to allocate the CG virtual display settings."
    );
    return NO;
  }

  id backingMode = [self createModeWithLogicalWidth:configuration.backingWidth
                                      logicalHeight:configuration.backingHeight
                                        refreshRate:configuration.refreshRate
                                           transfer:configuration.transfer
                                         hdrEnabled:configuration.hdrEnabled
                                              error:error];
  if (backingMode == nil) {
    return NO;
  }
  id initialMode = [self createModeWithLogicalWidth:configuration.logicalWidth
                                       logicalHeight:configuration.logicalHeight
                                         refreshRate:configuration.refreshRate
                                            transfer:configuration.transfer
                                          hdrEnabled:configuration.hdrEnabled
                                               error:error];
  if (initialMode == nil) {
    return NO;
  }
  // CGVirtualDisplay does not infer the backing pixel geometry from the
  // logical mode on macOS 27. Publish the logical mode first and its native
  // backing-pixel peer second, matching the mode pair consumed by WindowServer
  // when hiDPI is enabled.
  NSArray *publishedModes = @[initialMode, backingMode];
  [_settings setValue:publishedModes forKey:@"modes"];
  [_settings setValue:@(configuration.highDensity) forKey:@"hiDPI"];
  [_settings setValue:@0 forKey:@"rotation"];
  [_settings setValue:@(configuration.hdrEnabled) forKey:@"isReference"];
  if ([_settings respondsToSelector:sel_registerName("setRefreshDeadline:")]) {
    ((void (*)(id, SEL, double))objc_msgSend)(
      _settings,
      sel_registerName("setRefreshDeadline:"),
      0.0
    );
  }
  if (![self applyVirtualDisplaySettings:_settings]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorSettingsRejected,
      @"macOS rejected the CG virtual display settings."
    );
    return NO;
  }
  _mode = initialMode;
  _nativeMode = backingMode;
  _usesSkyLightBackend = NO;
  return YES;
}

- (BOOL)configureSkyLightVirtualDisplayWithConfiguration:(LumenMacVirtualDisplayConfiguration *)configuration
                                      maximumBackingWidth:(uint32_t)maximumBackingWidth
                                     maximumBackingHeight:(uint32_t)maximumBackingHeight
                                                     error:(NSError **)error {
  Class descriptorClass = NSClassFromString(@"SLVirtualDisplayConfiguration");
  Class modeClass = NSClassFromString(@"SLVirtualDisplayMode");
  Class settingsClass = NSClassFromString(@"SLVirtualDisplaySettings");
  Class displayClass = NSClassFromString(@"SLVirtualDisplay");
  SEL configurationSelector = sel_registerName(
    "initWithName:vendorID:productID:serialNumber:sizeInMillimeters:maximumSizeInPixels:chromaticities:error:"
  );
  if (![descriptorClass instancesRespondToSelector:configurationSelector]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"SLVirtualDisplayConfiguration does not expose its initializer."
    );
    return NO;
  }

  NSPoint red;
  NSPoint green;
  NSPoint blue;
  NSPoint white;
  LumenColorPrimaries(configuration.gamut, &red, &green, &blue, &white);
  const NSSize physicalSize = LumenPhysicalDisplaySize(
    configuration.backingWidth,
    configuration.backingHeight
  );
  const LumenSkyLightSize millimeters = {
    (float)physicalSize.width,
    (float)physicalSize.height
  };
  const LumenSkyLightPixels maximumPixels = {
    maximumBackingWidth,
    maximumBackingHeight
  };
  const LumenSkyLightChromaticities chromaticities = {
    {(float)red.x, (float)red.y},
    {(float)green.x, (float)green.y},
    {(float)blue.x, (float)blue.y},
    {(float)white.x, (float)white.y}
  };
  typedef id (*LumenSkyLightConfigurationInitializer)(
    id,
    SEL,
    id,
    unsigned long long,
    unsigned long long,
    unsigned long long,
    LumenSkyLightSize,
    LumenSkyLightPixels,
    LumenSkyLightChromaticities,
    NSError **
  );
  NSError *skyLightError = nil;
  _descriptor = ((LumenSkyLightConfigurationInitializer)objc_msgSend)(
    [descriptorClass alloc],
    configurationSelector,
    configuration.name,
    (unsigned long long)configuration.vendorID,
    (unsigned long long)configuration.productID,
    (unsigned long long)configuration.serialNumber,
    millimeters,
    maximumPixels,
    chromaticities,
    &skyLightError
  );
  if (_descriptor == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      skyLightError.localizedDescription ?: @"Failed to create the SkyLight virtual display configuration."
    );
    return NO;
  }

  const NSUInteger eotf = LumenSkyLightEOTF(configuration);
  id preferredMode = LumenCreateSkyLightMode(
    modeClass,
    configuration.backingWidth,
    configuration.backingHeight,
    configuration.logicalWidth,
    configuration.logicalHeight,
    configuration.refreshRate,
    eotf,
    &skyLightError
  );
  if (preferredMode == nil) {
    if (error != NULL && skyLightError != nil) {
      *error = skyLightError;
    }
    return NO;
  }
  id nativeMode = LumenCreateSkyLightMode(
    modeClass,
    configuration.backingWidth,
    configuration.backingHeight,
    configuration.backingWidth,
    configuration.backingHeight,
    configuration.refreshRate,
    eotf,
    &skyLightError
  );
  if (nativeMode == nil) {
    if (error != NULL && skyLightError != nil) {
      *error = skyLightError;
    }
    return NO;
  }
  NSArray *optionalModes = LumenCreateSkyLightOptionalModes(
    modeClass,
    configuration.backingWidth,
    configuration.backingHeight,
    configuration.logicalWidth,
    configuration.logicalHeight,
    configuration.refreshRate,
    eotf
  );

  SEL settingsSelector = sel_registerName(
    "initWithNativeMode:preferredMode:optionalModes:rotations:error:"
  );
  if (![settingsClass instancesRespondToSelector:settingsSelector]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"SLVirtualDisplaySettings does not expose its initializer."
    );
    return NO;
  }
  typedef id (*LumenSkyLightSettingsInitializer)(
    id,
    SEL,
    id,
    id,
    id,
    unsigned long long,
    NSError **
  );
  _settings = ((LumenSkyLightSettingsInitializer)objc_msgSend)(
    [settingsClass alloc],
    settingsSelector,
    nativeMode,
    preferredMode,
    optionalModes,
    0ULL,
    &skyLightError
  );
  if (_settings == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      skyLightError.localizedDescription ?: @"Failed to create the SkyLight virtual display settings."
    );
    return NO;
  }

  SEL displaySelector = sel_registerName("initWithConfiguration:error:");
  if (![displayClass instancesRespondToSelector:displaySelector]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"SLVirtualDisplay does not expose its configuration initializer."
    );
    return NO;
  }
  typedef id (*LumenSkyLightDisplayInitializer)(id, SEL, id, NSError **);
  _display = ((LumenSkyLightDisplayInitializer)objc_msgSend)(
    [displayClass alloc],
    displaySelector,
    _descriptor,
    &skyLightError
  );
  if (_display == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      skyLightError.localizedDescription ?: @"Failed to create the SkyLight virtual display."
    );
    return NO;
  }

  SEL applySelector = sel_registerName("applySettings:error:");
  if (![self->_display respondsToSelector:applySelector]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"SLVirtualDisplay does not expose applySettings:error:."
    );
    return NO;
  }
  typedef BOOL (*LumenSkyLightSettingsApplier)(id, SEL, id, NSError **);
  if (!((LumenSkyLightSettingsApplier)objc_msgSend)(
    _display,
    applySelector,
    _settings,
    &skyLightError
  )) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorSettingsRejected,
      skyLightError.localizedDescription ?: @"macOS rejected the SkyLight virtual display settings."
    );
    return NO;
  }
  _mode = preferredMode;
  _nativeMode = nativeMode;
  _usesSkyLightBackend = YES;
  return YES;
}

- (BOOL)configureWithConfiguration:(LumenMacVirtualDisplayConfiguration *)configuration
                             error:(NSError **)error {
  if (configuration.backingWidth == 0 || configuration.backingHeight == 0 ||
      configuration.logicalWidth == 0 || configuration.logicalHeight == 0 ||
      configuration.refreshRate <= 0) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      @"Virtual display geometry and refresh rate must be positive."
    );
    return NO;
  }
  if (![self.class isSupported]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"The current macOS runtime does not expose the virtual display classes."
    );
    return NO;
  }
  const uint32_t maximumBackingWidth = MAX(
    configuration.maximumBackingWidth,
    configuration.backingWidth
  );
  const uint32_t maximumBackingHeight = MAX(
    configuration.maximumBackingHeight,
    configuration.backingHeight
  );
  // The CG backend exposes the same retained virtual-display primitive used by
  // MacVirtualDisplay and permits selecting its published HiDPI mode through
  // CoreGraphics. macOS 27's newer SLVirtualDisplay publishes the pair but
  // rejects CGDisplaySetDisplayMode for that display class.
  const BOOL useSkyLightBackend =
    !LumenCGVirtualDisplayClassesAvailable() && LumenSkyLightClassesAvailable();

  @try {
    const BOOL configured = useSkyLightBackend
      ? [self configureSkyLightVirtualDisplayWithConfiguration:configuration
                                            maximumBackingWidth:maximumBackingWidth
                                           maximumBackingHeight:maximumBackingHeight
                                                           error:error]
      : [self configureCGVirtualDisplayWithConfiguration:configuration
                                     maximumBackingWidth:maximumBackingWidth
                                    maximumBackingHeight:maximumBackingHeight
                                                    error:error];
    if (!configured) {
      [self destroy];
      return NO;
    }

    NSNumber *displayID = [_display valueForKey:@"displayID"];
    if (displayID == nil || displayID.unsignedIntValue == 0) {
      LumenAssignVirtualDisplayError(
        error,
        LumenMacVirtualDisplayErrorMissingDisplayID,
        @"The virtual display did not publish a display identifier."
      );
      [self destroy];
      return NO;
    }
    _displayID = displayID.unsignedIntValue;
    _backingWidth = configuration.backingWidth;
    _backingHeight = configuration.backingHeight;
    _maximumBackingWidth = maximumBackingWidth;
    _maximumBackingHeight = maximumBackingHeight;
    _logicalWidth = configuration.logicalWidth;
    _logicalHeight = configuration.logicalHeight;
    _refreshRate = configuration.refreshRate;
    _highDensity = configuration.highDensity;
    _transfer = configuration.transfer;
    _hdrEnabled = configuration.hdrEnabled;
  } @catch (NSException *exception) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      exception.reason ?: @"Virtual display creation raised an Objective-C exception."
    );
    [self destroy];
    return NO;
  }
  return YES;
}

- (BOOL)selectPublishedHiDPIModeWithError:(NSError **)error {
  if (![NSThread isMainThread]) {
    __block BOOL selected = NO;
    __block NSError *mainThreadError = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      selected = [self selectPublishedHiDPIModeWithError:&mainThreadError];
    });
    if (!selected && error != NULL) {
      *error = mainThreadError;
    }
    return selected;
  }
  if (_display == nil || _displayID == 0 || !_highDensity) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      @"The retained HiDPI display is unavailable for mode selection."
    );
    return NO;
  }
  CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(_displayID);
  const BOOL currentModeMatches = LumenDisplayModeMatches(
    currentMode,
    _logicalWidth,
    _logicalHeight,
    _backingWidth,
    _backingHeight,
    _refreshRate
  );
  if (currentMode != NULL) {
    CGDisplayModeRelease(currentMode);
  }
  if (currentModeMatches) {
    return YES;
  }
  return LumenSelectPublishedHiDPIMode(
    _displayID,
    _logicalWidth,
    _logicalHeight,
    _backingWidth,
    _backingHeight,
    _refreshRate,
    error
  );
}

- (nullable id)createModeWithLogicalWidth:(uint32_t)logicalWidth
                            logicalHeight:(uint32_t)logicalHeight
                              refreshRate:(double)refreshRate
                                 transfer:(LumenMacVirtualDisplayTransfer)transfer
                               hdrEnabled:(BOOL)hdrEnabled
                                    error:(NSError **)error {
  Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
  LumenMacVirtualDisplayConfiguration *transferConfiguration = [LumenMacVirtualDisplayConfiguration new];
  transferConfiguration.transfer = transfer;
  transferConfiguration.hdrEnabled = hdrEnabled;
  const int transferCode = LumenTransferFunctionCode(transferConfiguration);
  id mode;

  if (hdrEnabled &&
      [modeClass instancesRespondToSelector:sel_registerName(
        "initWithWidth:height:refreshRate:transferFunction:"
      )]) {
    mode = ((id (*)(id, SEL, NSUInteger, NSUInteger, double, unsigned int))objc_msgSend)(
      [modeClass alloc],
      sel_registerName("initWithWidth:height:refreshRate:transferFunction:"),
      (NSUInteger)logicalWidth,
      (NSUInteger)logicalHeight,
      refreshRate,
      (unsigned int)MAX(transferCode, 0)
    );
  } else {
    mode = ((id (*)(id, SEL, NSUInteger, NSUInteger, double))objc_msgSend)(
      [modeClass alloc],
      sel_registerName("initWithWidth:height:refreshRate:"),
      (NSUInteger)logicalWidth,
      (NSUInteger)logicalHeight,
      refreshRate
    );
  }
  if (mode == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      @"Failed to create the requested virtual display mode."
    );
    return nil;
  }
  return mode;
}

- (BOOL)applyVirtualDisplaySettings:(id)settings {
  return ((BOOL (*)(id, SEL, id))objc_msgSend)(
    _display,
    sel_registerName("applySettings:"),
    settings
  );
}

- (BOOL)updateSkyLightModeWithLogicalWidth:(uint32_t)logicalWidth
                              logicalHeight:(uint32_t)logicalHeight
                                refreshRate:(double)refreshRate
                         requiredBackingWidth:(uint32_t)requiredBackingWidth
                        requiredBackingHeight:(uint32_t)requiredBackingHeight
                                       error:(NSError **)error {
  Class modeClass = NSClassFromString(@"SLVirtualDisplayMode");
  Class settingsClass = NSClassFromString(@"SLVirtualDisplaySettings");
  SEL settingsSelector = sel_registerName(
    "initWithNativeMode:preferredMode:optionalModes:rotations:error:"
  );
  if (modeClass == Nil || settingsClass == Nil ||
      ![settingsClass instancesRespondToSelector:settingsSelector]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"The SkyLight virtual display mode update API is unavailable."
    );
    return NO;
  }

  LumenMacVirtualDisplayConfiguration *modeConfiguration =
    [LumenMacVirtualDisplayConfiguration new];
  modeConfiguration.transfer = _transfer;
  modeConfiguration.hdrEnabled = _hdrEnabled;
  const NSUInteger eotf = LumenSkyLightEOTF(modeConfiguration);
  NSError *skyLightError = nil;
  id preferredMode = LumenCreateSkyLightMode(
    modeClass,
    requiredBackingWidth,
    requiredBackingHeight,
    logicalWidth,
    logicalHeight,
    refreshRate,
    eotf,
    &skyLightError
  );
  if (preferredMode == nil) {
    if (error != NULL && skyLightError != nil) {
      *error = skyLightError;
    }
    return NO;
  }
  id nativeMode = LumenCreateSkyLightMode(
    modeClass,
    requiredBackingWidth,
    requiredBackingHeight,
    requiredBackingWidth,
    requiredBackingHeight,
    refreshRate,
    eotf,
    &skyLightError
  );
  if (nativeMode == nil) {
    if (error != NULL && skyLightError != nil) {
      *error = skyLightError;
    }
    return NO;
  }
  NSArray *optionalModes = LumenCreateSkyLightOptionalModes(
    modeClass,
    requiredBackingWidth,
    requiredBackingHeight,
    logicalWidth,
    logicalHeight,
    refreshRate,
    eotf
  );

  typedef id (*LumenSkyLightSettingsInitializer)(
    id,
    SEL,
    id,
    id,
    id,
    unsigned long long,
    NSError **
  );
  id newSettings = ((LumenSkyLightSettingsInitializer)objc_msgSend)(
    [settingsClass alloc],
    settingsSelector,
    nativeMode,
    preferredMode,
    optionalModes,
    0ULL,
    &skyLightError
  );
  if (newSettings == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      skyLightError.localizedDescription ?: @"Failed to create the updated SkyLight settings."
    );
    return NO;
  }

  SEL applySelector = sel_registerName("applySettings:error:");
  typedef BOOL (*LumenSkyLightSettingsApplier)(id, SEL, id, NSError **);
  if (!((LumenSkyLightSettingsApplier)objc_msgSend)(
    _display,
    applySelector,
    newSettings,
    &skyLightError
  )) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorSettingsRejected,
      skyLightError.localizedDescription ?: @"macOS rejected the updated SkyLight virtual display settings."
    );
    return NO;
  }

  _nativeMode = nativeMode;
  _mode = preferredMode;
  _settings = newSettings;
  _backingWidth = requiredBackingWidth;
  _backingHeight = requiredBackingHeight;
  _logicalWidth = logicalWidth;
  _logicalHeight = logicalHeight;
  _refreshRate = refreshRate;
  return YES;
}

- (BOOL)updateLogicalWidth:(uint32_t)logicalWidth
             logicalHeight:(uint32_t)logicalHeight
               refreshRate:(double)refreshRate
                      error:(NSError **)error {
  if (![NSThread isMainThread]) {
    __block BOOL updated = NO;
    __block NSError *mainThreadError = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      updated = [self updateLogicalWidth:logicalWidth
                           logicalHeight:logicalHeight
                             refreshRate:refreshRate
                                    error:&mainThreadError];
    });
    if (!updated && error != NULL) {
      *error = mainThreadError;
    }
    return updated;
  }
  if (_display == nil || logicalWidth == 0 || logicalHeight == 0 || refreshRate <= 0) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      @"Cannot update an inactive virtual display or apply an empty mode."
    );
    return NO;
  }
  if (_logicalWidth == logicalWidth &&
      _logicalHeight == logicalHeight &&
      _refreshRate == refreshRate) {
    return YES;
  }
  const uint64_t backingScale = _highDensity ? 2u : 1u;
  const uint64_t requiredBackingWidth = (uint64_t)logicalWidth * backingScale;
  const uint64_t requiredBackingHeight = (uint64_t)logicalHeight * backingScale;
  if (requiredBackingWidth > _maximumBackingWidth ||
      requiredBackingHeight > _maximumBackingHeight) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      [NSString stringWithFormat:
        @"Requested virtual display mode requires %llux%llu backing pixels, "
         @"which exceeds the retained display capacity %ux%u.",
        (unsigned long long)requiredBackingWidth,
        (unsigned long long)requiredBackingHeight,
        _maximumBackingWidth,
        _maximumBackingHeight]
    );
    return NO;
  }
  if (_usesSkyLightBackend) {
    return [self updateSkyLightModeWithLogicalWidth:logicalWidth
                                      logicalHeight:logicalHeight
                                        refreshRate:refreshRate
                                 requiredBackingWidth:(uint32_t)requiredBackingWidth
                                requiredBackingHeight:(uint32_t)requiredBackingHeight
                                               error:error];
  }
  id previousMode = _mode;
  id previousModes = [_settings valueForKey:@"modes"];
  id restoreModes = previousModes;
  if (restoreModes == nil && previousMode != nil) {
    restoreModes = @[previousMode];
  }
  @try {
    id candidateBackingMode = [self createModeWithLogicalWidth:(uint32_t)requiredBackingWidth
                                                  logicalHeight:(uint32_t)requiredBackingHeight
                                                    refreshRate:refreshRate
                                                       transfer:_transfer
                                                     hdrEnabled:_hdrEnabled
                                                          error:error];
    if (candidateBackingMode == nil) {
      return NO;
    }
    id candidateMode = [self createModeWithLogicalWidth:logicalWidth
                                          logicalHeight:logicalHeight
                                            refreshRate:refreshRate
                                               transfer:_transfer
                                             hdrEnabled:_hdrEnabled
                                                  error:error];
    if (candidateMode == nil) {
      return NO;
    }
    NSArray *candidateModes =
      _highDensity &&
      (requiredBackingWidth != logicalWidth || requiredBackingHeight != logicalHeight)
        ? @[candidateMode, candidateBackingMode]
        : @[candidateMode];
    [_settings setValue:candidateModes forKey:@"modes"];
    [_settings setValue:@(_highDensity) forKey:@"hiDPI"];
    BOOL applied = [self applyVirtualDisplaySettings:_settings];
    if (!applied) {
      if (restoreModes != nil) {
        [_settings setValue:restoreModes forKey:@"modes"];
      }
      LumenAssignVirtualDisplayError(
        error,
        LumenMacVirtualDisplayErrorSettingsRejected,
        @"macOS rejected the updated virtual display mode."
      );
      return NO;
    }
    _mode = candidateMode;
    _nativeMode = candidateBackingMode;
    _backingWidth = (uint32_t)requiredBackingWidth;
    _backingHeight = (uint32_t)requiredBackingHeight;
    _logicalWidth = logicalWidth;
    _logicalHeight = logicalHeight;
    _refreshRate = refreshRate;
    return YES;
  } @catch (NSException *exception) {
    if (restoreModes != nil) {
      @try {
        [_settings setValue:restoreModes forKey:@"modes"];
      } @catch (__unused NSException *restoreException) {
      }
    }
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorSettingsRejected,
      exception.reason ?: @"Virtual display mode update raised an Objective-C exception."
    );
    return NO;
  }
}

- (void)destroy {
  if (![NSThread isMainThread]) {
    __unsafe_unretained LumenMacVirtualDisplay *unretainedSelf = self;
    dispatch_sync(dispatch_get_main_queue(), ^{
      [unretainedSelf destroy];
    });
    return;
  }
  id display = _display;
  _display = nil;
  _displayID = 0;
  _backingWidth = 0;
  _backingHeight = 0;
  _maximumBackingWidth = 0;
  _maximumBackingHeight = 0;
  _logicalWidth = 0;
  _logicalHeight = 0;
  _refreshRate = 0;
  _highDensity = NO;
  _usesSkyLightBackend = NO;
  _hdrEnabled = NO;
  if (display != nil && [display respondsToSelector:sel_registerName("destroy")]) {
    ((void (*)(id, SEL))objc_msgSend)(display, sel_registerName("destroy"));
  }
  _settings = nil;
  _mode = nil;
  _nativeMode = nil;
  _descriptor = nil;
  _callbackQueue = nil;
}

- (void)dealloc {
  [self destroy];
}

@end
