#import <AppKit/AppKit.h>
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
  if (![displayInfo isKindOfClass:NSDictionary.class] || displayInfo.count == 0) {
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
    if (key != nil && displayInfo[key] != nil) {
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
@property(nonatomic) uint32_t logicalWidth;
@property(nonatomic) uint32_t logicalHeight;
@property(nonatomic, strong) id descriptor;
@property(nonatomic, strong) id mode;
@property(nonatomic, strong) id settings;
@property(nonatomic, strong) id display;
@property(nonatomic, strong) dispatch_queue_t callbackQueue;
@property(nonatomic) LumenMacVirtualDisplayTransfer transfer;
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
  return NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
         NSClassFromString(@"CGVirtualDisplayMode") != nil &&
         NSClassFromString(@"CGVirtualDisplaySettings") != nil &&
         NSClassFromString(@"CGVirtualDisplay") != nil;
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
  if (configuration.backingWidth == 0 || configuration.backingHeight == 0 ||
      configuration.logicalWidth == 0 || configuration.logicalHeight == 0 ||
      configuration.refreshRate <= 0) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      @"Virtual display geometry and refresh rate must be positive."
    );
    return nil;
  }
  if (![self.class isSupported]) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorUnsupportedRuntime,
      @"The current macOS runtime does not expose the virtual display classes."
    );
    return nil;
  }

  @try {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    _descriptor = [[descriptorClass alloc] init];
    _settings = [[settingsClass alloc] init];
    _callbackQueue = dispatch_queue_create(
      "dev.skyline23.lumen.native-virtual-display",
      DISPATCH_QUEUE_SERIAL
    );
    if (_descriptor == nil || _settings == nil || _callbackQueue == nil) {
      LumenAssignVirtualDisplayError(
        error,
        LumenMacVirtualDisplayErrorObjectCreationFailed,
        @"Failed to allocate the virtual display descriptor."
      );
      return nil;
    }

    NSPoint red;
    NSPoint green;
    NSPoint blue;
    NSPoint white;
    LumenColorPrimaries(configuration.gamut, &red, &green, &blue, &white);
    [_descriptor setValue:@(configuration.vendorID) forKey:@"vendorID"];
    [_descriptor setValue:@(configuration.productID) forKey:@"productID"];
    [_descriptor setValue:@(configuration.serialNumber) forKey:@"serialNumber"];
    [_descriptor setValue:configuration.name forKey:@"name"];
    [_descriptor setValue:[NSValue valueWithSize:LumenPhysicalDisplaySize(
      configuration.backingWidth,
      configuration.backingHeight
    )] forKey:@"sizeInMillimeters"];
    [_descriptor setValue:@(configuration.backingWidth) forKey:@"maxPixelsWide"];
    [_descriptor setValue:@(configuration.backingHeight) forKey:@"maxPixelsHigh"];
    [_descriptor setValue:[NSValue valueWithPoint:red] forKey:@"redPrimary"];
    [_descriptor setValue:[NSValue valueWithPoint:green] forKey:@"greenPrimary"];
    [_descriptor setValue:[NSValue valueWithPoint:blue] forKey:@"bluePrimary"];
    [_descriptor setValue:[NSValue valueWithPoint:white] forKey:@"whitePoint"];
    [_descriptor setValue:_callbackQueue forKey:@"queue"];
    LumenConfigureHDRDisplayInfo(_descriptor, configuration);

    if (![self createModeWithLogicalWidth:configuration.logicalWidth
                            logicalHeight:configuration.logicalHeight
                              refreshRate:configuration.refreshRate
                                 transfer:configuration.transfer
                              hdrEnabled:configuration.hdrEnabled
                                    error:error]) {
      return nil;
    }
    [_settings setValue:@[_mode] forKey:@"modes"];
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

    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    _display = ((id (*)(id, SEL, id))objc_msgSend)(
      [displayClass alloc],
      sel_registerName("initWithDescriptor:"),
      _descriptor
    );
    if (_display == nil) {
      LumenAssignVirtualDisplayError(
        error,
        LumenMacVirtualDisplayErrorObjectCreationFailed,
        @"Failed to create the virtual display instance."
      );
      return nil;
    }

    BOOL applied = ((BOOL (*)(id, SEL, id))objc_msgSend)(
      _display,
      sel_registerName("applySettings:"),
      _settings
    );
    if (!applied) {
      LumenAssignVirtualDisplayError(
        error,
        LumenMacVirtualDisplayErrorSettingsRejected,
        @"macOS rejected the virtual display settings."
      );
      [self destroy];
      return nil;
    }

    NSNumber *displayID = [_display valueForKey:@"displayID"];
    if (displayID == nil || displayID.unsignedIntValue == 0) {
      LumenAssignVirtualDisplayError(
        error,
        LumenMacVirtualDisplayErrorMissingDisplayID,
        @"The virtual display did not publish a display identifier."
      );
      [self destroy];
      return nil;
    }
    _displayID = displayID.unsignedIntValue;
    _backingWidth = configuration.backingWidth;
    _backingHeight = configuration.backingHeight;
    _logicalWidth = configuration.logicalWidth;
    _logicalHeight = configuration.logicalHeight;
    _transfer = configuration.transfer;
  } @catch (NSException *exception) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      exception.reason ?: @"Virtual display creation raised an Objective-C exception."
    );
    [self destroy];
    return nil;
  }
  return self;
}

- (BOOL)createModeWithLogicalWidth:(uint32_t)logicalWidth
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

  if ([modeClass instancesRespondToSelector:sel_registerName("initWithWidth:height:refreshRate:transferFunction:")]) {
    _mode = ((id (*)(id, SEL, NSUInteger, NSUInteger, double, unsigned int))objc_msgSend)(
      [modeClass alloc],
      sel_registerName("initWithWidth:height:refreshRate:transferFunction:"),
      (NSUInteger)logicalWidth,
      (NSUInteger)logicalHeight,
      refreshRate,
      (unsigned int)MAX(transferCode, 0)
    );
  } else {
    _mode = ((id (*)(id, SEL, NSUInteger, NSUInteger, double))objc_msgSend)(
      [modeClass alloc],
      sel_registerName("initWithWidth:height:refreshRate:"),
      (NSUInteger)logicalWidth,
      (NSUInteger)logicalHeight,
      refreshRate
    );
  }
  if (_mode == nil) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorObjectCreationFailed,
      @"Failed to create the requested virtual display mode."
    );
    return NO;
  }
  return YES;
}

- (BOOL)updateLogicalWidth:(uint32_t)logicalWidth
             logicalHeight:(uint32_t)logicalHeight
               refreshRate:(double)refreshRate
                      error:(NSError **)error {
  if (_display == nil || logicalWidth == 0 || logicalHeight == 0 || refreshRate <= 0) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorInvalidConfiguration,
      @"Cannot update an inactive virtual display or apply an empty mode."
    );
    return NO;
  }

  @try {
    if (![self createModeWithLogicalWidth:logicalWidth
                            logicalHeight:logicalHeight
                              refreshRate:refreshRate
                                 transfer:_transfer
                               hdrEnabled:_transfer != LumenMacVirtualDisplayTransferSDR
                                    error:error]) {
      return NO;
    }
    [_settings setValue:@[_mode] forKey:@"modes"];
    BOOL applied = ((BOOL (*)(id, SEL, id))objc_msgSend)(
      _display,
      sel_registerName("applySettings:"),
      _settings
    );
    if (!applied) {
      LumenAssignVirtualDisplayError(
        error,
        LumenMacVirtualDisplayErrorSettingsRejected,
        @"macOS rejected the updated virtual display mode."
      );
    }
    if (applied) {
      _logicalWidth = logicalWidth;
      _logicalHeight = logicalHeight;
    }
    return applied;
  } @catch (NSException *exception) {
    LumenAssignVirtualDisplayError(
      error,
      LumenMacVirtualDisplayErrorSettingsRejected,
      exception.reason ?: @"Virtual display mode update raised an Objective-C exception."
    );
    return NO;
  }
}

- (void)destroy {
  id display = _display;
  _display = nil;
  _displayID = 0;
  _backingWidth = 0;
  _backingHeight = 0;
  _logicalWidth = 0;
  _logicalHeight = 0;
  if (display != nil && [display respondsToSelector:sel_registerName("destroy")]) {
    ((void (*)(id, SEL))objc_msgSend)(display, sel_registerName("destroy"));
  }
  _settings = nil;
  _mode = nil;
  _descriptor = nil;
  _callbackQueue = nil;
}

- (void)dealloc {
  [self destroy];
}

@end
