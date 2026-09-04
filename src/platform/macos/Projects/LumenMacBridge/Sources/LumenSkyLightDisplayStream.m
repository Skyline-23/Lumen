#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "LumenMacBridge.h"

#include <dlfcn.h>
#include <limits.h>

static NSString *const LumenSkyLightContentStreamErrorDomain =
  @"dev.skyline23.lumen.skylight-content-stream";
static NSString *const LumenSkyLightDisplayStreamErrorDomain =
  @"dev.skyline23.lumen.skylight-display-stream";

typedef NS_ENUM(NSInteger, LumenSkyLightContentStreamErrorCode) {
  LumenSkyLightContentStreamErrorUnsupportedRuntime = 1,
  LumenSkyLightContentStreamErrorInvalidGeometry = 2,
  LumenSkyLightContentStreamErrorFilterCreationFailed = 3,
  LumenSkyLightContentStreamErrorStreamCreationFailed = 4,
  LumenSkyLightContentStreamErrorStartFailed = 5,
};

static NSError *LumenSkyLightDisplayStreamError(
  NSString *symbol,
  CGError code,
  NSString *description
) {
  return [NSError errorWithDomain:LumenSkyLightDisplayStreamErrorDomain
                             code:(NSInteger)code
                         userInfo:@{
                           NSLocalizedDescriptionKey: description,
                           @"symbol": symbol,
                           @"backend": @"skylight-display-stream",
                           @"code": @(code),
                         }];
}

typedef CGDisplayStreamRef (*LumenSLDisplayStreamCreateWithDispatchQueue)(
  CGDirectDisplayID display,
  size_t outputWidth,
  size_t outputHeight,
  int pixelFormat,
  CFDictionaryRef properties,
  dispatch_queue_t queue,
  CGDisplayStreamFrameAvailableHandler handler
);
typedef CGError (*LumenSLDisplayStreamStart)(CGDisplayStreamRef stream);
typedef CGError (*LumenSLDisplayStreamStop)(CGDisplayStreamRef stream);
typedef size_t (*LumenSLDisplayStreamUpdateGetDropCount)(
  CGDisplayStreamUpdateRef update
);

static void *LumenSkyLightHandle(void) {
  static void *handle = NULL;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    handle = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
      RTLD_NOW | RTLD_LOCAL
    );
  });
  return handle;
}

static NSString *LumenSkyLightStringConstant(const char *symbolName) {
  void *handle = LumenSkyLightHandle();
  if (handle == NULL || symbolName == NULL) {
    return nil;
  }
  const void *const *storage =
    (const void *const *)dlsym(handle, symbolName);
  if (storage == NULL || *storage == NULL) {
    return nil;
  }
  return (__bridge NSString *)*storage;
}

static void *LumenSkyLightFunction(const char *symbolName) {
  void *handle = LumenSkyLightHandle();
  return handle == NULL || symbolName == NULL
    ? NULL
    : dlsym(handle, symbolName);
}

// macOS 27 marks the legacy CGDisplayStream constants unavailable at compile
// time even though the SL primitive consumes the same runtime key objects.
// Resolve the constants from CoreGraphics just like the private symbols.
static NSString *LumenCoreGraphicsStringConstant(const char *symbolName) {
  static void *handle = NULL;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    handle = dlopen(
      "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
      RTLD_NOW | RTLD_LOCAL);
  });
  if (handle == NULL || symbolName == NULL) {
    return nil;
  }
  const void *const *storage =
    (const void *const *)dlsym(handle, symbolName);
  return storage == NULL || *storage == NULL
    ? nil
    : (__bridge NSString *)*storage;
}

static LumenSLDisplayStreamCreateWithDispatchQueue
LumenSLDisplayStreamCreateFunction(void) {
  return (LumenSLDisplayStreamCreateWithDispatchQueue)
    LumenSkyLightFunction("SLDisplayStreamCreateWithDispatchQueue");
}

static LumenSLDisplayStreamStart LumenSLDisplayStreamStartFunction(void) {
  return (LumenSLDisplayStreamStart)
    LumenSkyLightFunction("SLDisplayStreamStart");
}

static LumenSLDisplayStreamStop LumenSLDisplayStreamStopFunction(void) {
  return (LumenSLDisplayStreamStop)
    LumenSkyLightFunction("SLDisplayStreamStop");
}

static LumenSLDisplayStreamUpdateGetDropCount
LumenSLDisplayStreamUpdateGetDropCountFunction(void) {
  return (LumenSLDisplayStreamUpdateGetDropCount)
    LumenSkyLightFunction("SLDisplayStreamUpdateGetDropCount");
}

static BOOL LumenSLDisplayStreamFunctionsAvailable(void) {
  return LumenSLDisplayStreamCreateFunction() != NULL &&
    LumenSLDisplayStreamStartFunction() != NULL &&
    LumenSLDisplayStreamStopFunction() != NULL;
}

static void LumenReleaseRawDisplayStreamAfterStopped(
  CGDisplayStreamRef stream,
  dispatch_semaphore_t stoppedSemaphore
) {
  if (stream == NULL || stoppedSemaphore == NULL) {
    return;
  }

  // The CoreGraphics contract requires waiting for .stopped before release.
  // Keep the transferred CF reference alive for a bounded period; if a
  // broken private implementation never delivers the terminal callback,
  // intentionally leak this one reference instead of risking use-after-free.
  dispatch_async(
    dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
    ^{
      const dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW,
        (int64_t)(5 * NSEC_PER_SEC)
      );
      if (dispatch_semaphore_wait(stoppedSemaphore, deadline) == 0) {
        CFRelease(stream);
      }
    }
  );
}

static void LumenAssignContentStreamError(
  NSError **error,
  LumenSkyLightContentStreamErrorCode code,
  NSString *description
) {
  if (error == NULL) {
    return;
  }
  *error = [NSError errorWithDomain:LumenSkyLightContentStreamErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL LumenProcessHasSkyLightContentStreamEntitlement(void) {
  SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
  if (task == NULL) {
    return NO;
  }

  CFTypeRef value = SecTaskCopyValueForEntitlement(
    task,
    CFSTR("com.apple.selectivesharing.session_system"),
    NULL
  );
  const BOOL granted = value != NULL &&
    CFGetTypeID(value) == CFBooleanGetTypeID() &&
    CFBooleanGetValue((CFBooleanRef)value);
  if (value != NULL) {
    CFRelease(value);
  }
  CFRelease(task);
  return granted;
}

static NSDictionary *LumenCGRectDictionary(CGRect rect) {
  return CFBridgingRelease(CGRectCreateDictionaryRepresentation(rect));
}

static BOOL LumenSetContentStreamProperty(
  NSMutableDictionary<NSString *, id> *properties,
  const char *symbolName,
  id value
) {
  NSString *key = LumenSkyLightStringConstant(symbolName);
  if (key == nil || value == nil) {
    return NO;
  }
  properties[key] = value;
  return YES;
}

static BOOL LumenContentStreamSelectorsAvailable(void) {
  Class filterClass = NSClassFromString(@"SLContentFilter");
  Class streamClass = NSClassFromString(@"SLContentStream");
  Class updateClass = NSClassFromString(@"SLContentStreamUpdate");
  if (filterClass == Nil || streamClass == Nil || updateClass == Nil) {
    return NO;
  }
  Method startMethod = class_getInstanceMethod(
    streamClass,
    sel_registerName("start:")
  );
  Method stopMethod = class_getInstanceMethod(
    streamClass,
    sel_registerName("stop:")
  );
  // The wrapper calls these selectors as BOOL (NSError **). Checking the
  // method shape before objc_msgSend avoids treating a same-named private
  // method with a different ABI as a usable stream implementation.
  BOOL (^hasNSErrorOutSignature)(Method) = ^BOOL(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
      return NO;
    }
    char returnType[8] = {0};
    char argumentType[8] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const BOOL booleanReturn = returnType[0] == 'B' || returnType[0] == 'c';
    return booleanReturn && argumentType[0] == '^';
  };
  return [filterClass instancesRespondToSelector:sel_registerName("initWithDisplay:")] &&
    [streamClass instancesRespondToSelector:
      sel_registerName("initWithFilter:properties:queue:handler:")] &&
    hasNSErrorOutSignature(startMethod) &&
    hasNSErrorOutSignature(stopMethod) &&
    [streamClass instancesRespondToSelector:sel_registerName("stream")] &&
    [streamClass instancesRespondToSelector:sel_registerName("session")] &&
    [updateClass instancesRespondToSelector:sel_registerName("status")] &&
    [updateClass instancesRespondToSelector:sel_registerName("displayTime")] &&
    [updateClass instancesRespondToSelector:sel_registerName("frameSurface")] &&
    [updateClass instancesRespondToSelector:sel_registerName("dropCount")];
}

static BOOL LumenContentStreamKeysAvailable(void) {
  const char *requiredSymbols[] = {
    "kSLContentStreamPixelFormatKey",
    "kSLContentStreamFrameSizeKey",
    "kSLContentStreamMinimumFrameTimeKey",
    "kSLContentStreamSourceRectKey",
    "kSLContentStreamDestinationRectKey",
    "kSLContentStreamPreserveAspectRatioKey",
    "kSLContentStreamAlwaysScaleToFitKey",
    "kSLContentStreamShowCursorKey",
    "kSLContentStreamQueueDepthKey",
    "kSLContentStreamDynamicRangeModeKey",
    "kSLContentStreamRequestedOverrideResolutionKey",
    "kSLContentStreamNominalResolutionKey",
    "kSLContentStreamBestResolutionKey",
    "kSLContentStreamIOSurfacePropertiesKey",
    "kSLContentStreamGPUBoostKey",
    "kSLContentStreamUseVideoToolboxKey",
  };
  const size_t symbolCount = sizeof(requiredSymbols) / sizeof(requiredSymbols[0]);
  for (size_t index = 0; index < symbolCount; index += 1) {
    if (LumenSkyLightStringConstant(requiredSymbols[index]) == nil) {
      return NO;
    }
  }
  return YES;
}

static BOOL LumenContentStreamAvailable(void) {
  return LumenProcessHasSkyLightContentStreamEntitlement() &&
    LumenSkyLightHandle() != NULL &&
    LumenContentStreamSelectorsAvailable() &&
    LumenContentStreamKeysAvailable();
}

@interface LumenMacSkyLightDisplayStreamFrameLease ()
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                             surface:(IOSurfaceRef)surface;
@end

@implementation LumenMacSkyLightDisplayStreamFrameLease {
  CVPixelBufferRef _leasedPixelBuffer;
  IOSurfaceRef _leasedSurface;
}

+ (nullable instancetype)leaseWithPixelBuffer:(CVPixelBufferRef)pixelBuffer {
  if (pixelBuffer == NULL) {
    return nil;
  }
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
  if (surface == NULL) {
    return nil;
  }

  LumenMacSkyLightDisplayStreamFrameLease *lease =
    [[LumenMacSkyLightDisplayStreamFrameLease alloc]
      initWithPixelBuffer:pixelBuffer
                  surface:surface];
  return lease;
}

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                             surface:(IOSurfaceRef)surface {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  _leasedPixelBuffer = CVPixelBufferRetain(pixelBuffer);
  _leasedSurface = (IOSurfaceRef)CFRetain(surface);
  IOSurfaceIncrementUseCount(surface);
  return self;
}

- (void)dealloc {
  if (_leasedSurface != NULL) {
    IOSurfaceDecrementUseCount(_leasedSurface);
    CFRelease(_leasedSurface);
    _leasedSurface = NULL;
  }
  if (_leasedPixelBuffer != NULL) {
    CVPixelBufferRelease(_leasedPixelBuffer);
    _leasedPixelBuffer = NULL;
  }
}

@end

@interface LumenMacSkyLightDisplayStream ()
- (void)refreshPrivateStreamIdentity;
- (void)handleContentStreamUpdate:(id)update;
- (void)handleDisplayStreamStatus:(CGDisplayStreamFrameStatus)status
                     displayTime:(uint64_t)displayTime
                          surface:(IOSurfaceRef)surface
                           update:(CGDisplayStreamUpdateRef)update
                  dropCountOverride:(size_t)dropCountOverride;
@end

@implementation LumenMacSkyLightDisplayStream {
  id _contentFilter;
  id _contentStream;
  CGDisplayStreamRef _displayStream;
  BOOL _usesSLDisplayStream;
  dispatch_queue_t _callbackQueue;
  LumenMacSkyLightDisplayStreamFrameHandler _frameHandler;
  BOOL _running;
  NSString *_contentStreamClassName;
  NSString *_contentStreamSessionClassName;
  BOOL _underlyingDisplayStreamAvailable;
  uint64_t _underlyingDisplayStreamTypeID;
  uint64_t _firstFrameDropCount;
  uint64_t _cumulativeDropCount;
  BOOL _recordedFirstFrameDropCount;
  NSError *_lastError;
  BOOL _displayStreamStarted;
  BOOL _displayStreamStopRequested;
  dispatch_semaphore_t _displayStreamStoppedSemaphore;
}

+ (BOOL)isSupported {
  // The restricted content API is preferred only when the process has the
  // entitlement and the complete private ObjC contract is present. The raw
  // SLDisplayStream ABI is independently usable without that entitlement.
  return LumenContentStreamAvailable() ||
    LumenSLDisplayStreamFunctionsAvailable();
}

- (instancetype)initWithDisplayID:(uint32_t)displayID
                       outputWidth:(size_t)outputWidth
                      outputHeight:(size_t)outputHeight
                       pixelFormat:(OSType)pixelFormat
                  minimumFrameTime:(double)minimumFrameTime
                        queueDepth:(NSInteger)queueDepth
                        showCursor:(BOOL)showCursor
                       yCbCrMatrix:(nullable NSString *)yCbCrMatrix
                     dynamicRangeMode:(NSInteger)dynamicRangeMode
                       colorSpaceName:(nullable NSString *)colorSpaceName
                       callbackQueue:(dispatch_queue_t)callbackQueue
                      frameHandler:(LumenMacSkyLightDisplayStreamFrameHandler)frameHandler {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  if (![[self class] isSupported] || callbackQueue == nil || frameHandler == nil ||
      outputWidth == 0 || outputHeight == 0) {
    return nil;
  }

  CGRect displayBounds = CGDisplayBounds(displayID);
  if (CGRectIsEmpty(displayBounds)) {
    return nil;
  }
  CGRect sourceRect = CGRectMake(
    0,
    0,
    CGRectGetWidth(displayBounds),
    CGRectGetHeight(displayBounds)
  );
  CGRect destinationRect = CGRectMake(
    0,
    0,
    (CGFloat)outputWidth,
    (CGFloat)outputHeight
  );
  NSSize outputSize = NSMakeSize((CGFloat)outputWidth, (CGFloat)outputHeight);

  _callbackQueue = callbackQueue;
  _frameHandler = [frameHandler copy];
  __weak LumenMacSkyLightDisplayStream *weakSelf = self;
  void (^contentUpdateHandler)(id) = ^(id update) {
    LumenMacSkyLightDisplayStream *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    [strongSelf handleContentStreamUpdate:update];
  };
  BOOL useContentStream = LumenContentStreamAvailable();
  BOOL contentStreamCreated = NO;
  if (useContentStream) {
    NSMutableDictionary<NSString *, id> *properties =
      [NSMutableDictionary dictionary];
    BOOL hasRequiredProperties = YES;
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamPixelFormatKey", @(pixelFormat));
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamFrameSizeKey",
      [NSValue valueWithSize:outputSize]);
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamMinimumFrameTimeKey",
      @(MAX(minimumFrameTime, 0.0)));
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamSourceRectKey",
      LumenCGRectDictionary(sourceRect));
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamDestinationRectKey",
      LumenCGRectDictionary(destinationRect));
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamPreserveAspectRatioKey", @YES);
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamAlwaysScaleToFitKey", @YES);
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamShowCursorKey", @(showCursor));
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamQueueDepthKey",
      @(MAX(1, MIN(queueDepth, 2))));
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamDynamicRangeModeKey", @(dynamicRangeMode));
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamRequestedOverrideResolutionKey",
      [NSValue valueWithSize:outputSize]);
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamNominalResolutionKey", @NO);
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamBestResolutionKey", @YES);
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamIOSurfacePropertiesKey", @{});
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamGPUBoostKey", @YES);
    hasRequiredProperties &= LumenSetContentStreamProperty(
      properties, "kSLContentStreamUseVideoToolboxKey", @NO);
    if (yCbCrMatrix != nil) {
      hasRequiredProperties &= LumenSetContentStreamProperty(
        properties, "kSLContentStreamYCbCrMatrixKey", yCbCrMatrix);
    }
    if (colorSpaceName != nil) {
      hasRequiredProperties &= LumenSetContentStreamProperty(
        properties, "kSLContentStreamColorSpaceKey", colorSpaceName);
    }
    if (hasRequiredProperties) {
      Class filterClass = NSClassFromString(@"SLContentFilter");
      Class streamClass = NSClassFromString(@"SLContentStream");
      typedef id (*LumenContentFilterInitializer)(id, SEL, uint32_t);
      _contentFilter = ((LumenContentFilterInitializer)objc_msgSend)(
        [filterClass alloc], sel_registerName("initWithDisplay:"), displayID);
      if (_contentFilter != nil) {
        typedef id (*LumenContentStreamInitializer)(
          id, SEL, id, NSDictionary *, dispatch_queue_t, void (^)(id));
        _contentStream = ((LumenContentStreamInitializer)objc_msgSend)(
          [streamClass alloc],
          sel_registerName("initWithFilter:properties:queue:handler:"),
          _contentFilter,
          [properties copy],
          callbackQueue,
          contentUpdateHandler);
        contentStreamCreated = _contentStream != nil;
      }
    }
    if (contentStreamCreated) {
      _contentStreamClassName = NSStringFromClass([_contentStream class]);
    } else {
      // A missing/changed private content key or initializer must not prevent
      // the entitlement-free raw ABI from being attempted below.
      _contentFilter = nil;
      _contentStream = nil;
    }
  }
  if (!contentStreamCreated) {
    LumenSLDisplayStreamCreateWithDispatchQueue createFunction =
      LumenSLDisplayStreamCreateFunction();
    if (createFunction == NULL) {
      return nil;
    }
    _usesSLDisplayStream = YES;
    NSMutableDictionary<NSString *, id> *properties =
      [NSMutableDictionary dictionary];
    NSString *sourceRectKey =
      LumenCoreGraphicsStringConstant("kCGDisplayStreamSourceRect");
    NSString *destinationRectKey =
      LumenCoreGraphicsStringConstant("kCGDisplayStreamDestinationRect");
    NSString *preserveAspectKey =
      LumenCoreGraphicsStringConstant("kCGDisplayStreamPreserveAspectRatio");
    NSString *minimumFrameTimeKey =
      LumenCoreGraphicsStringConstant("kCGDisplayStreamMinimumFrameTime");
    NSString *showCursorKey =
      LumenCoreGraphicsStringConstant("kCGDisplayStreamShowCursor");
    NSString *queueDepthKey =
      LumenCoreGraphicsStringConstant("kCGDisplayStreamQueueDepth");
    NSString *matrixKey =
      LumenCoreGraphicsStringConstant("kCGDisplayStreamYCbCrMatrix");
    NSString *colorSpaceKey =
      LumenCoreGraphicsStringConstant("kCGDisplayStreamColorSpace");
    if (sourceRectKey == nil || destinationRectKey == nil ||
        preserveAspectKey == nil || minimumFrameTimeKey == nil ||
        showCursorKey == nil || queueDepthKey == nil) {
      return nil;
    }
    properties[sourceRectKey] = LumenCGRectDictionary(sourceRect);
    properties[destinationRectKey] = LumenCGRectDictionary(destinationRect);
    properties[preserveAspectKey] = @YES;
    properties[minimumFrameTimeKey] = @(MAX(minimumFrameTime, 0.0));
    properties[showCursorKey] = @(showCursor);
    properties[queueDepthKey] = @(MAX(1, MIN(queueDepth, 2)));
    if (yCbCrMatrix != nil) {
      if (matrixKey == nil) { return nil; }
      properties[matrixKey] = yCbCrMatrix;
    }
    if (colorSpaceName != nil) {
      CGColorSpaceRef colorSpace =
        CGColorSpaceCreateWithName((CFStringRef)colorSpaceName);
      if (colorSpace == NULL) {
        return nil;
      }
      if (colorSpaceKey == nil) { CFRelease(colorSpace); return nil; }
      properties[colorSpaceKey] = (__bridge id)colorSpace;
      CFRelease(colorSpace);
    }
    dispatch_semaphore_t stoppedSemaphore = dispatch_semaphore_create(0);
    _displayStreamStoppedSemaphore = stoppedSemaphore;
    void (^displayHandler)(CGDisplayStreamFrameStatus, uint64_t, IOSurfaceRef,
                           CGDisplayStreamUpdateRef) =
      ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
        IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
        LumenMacSkyLightDisplayStream *strongSelf = weakSelf;
        if (strongSelf != nil) {
          [strongSelf handleDisplayStreamStatus:status
                                     displayTime:displayTime
                                          surface:surface
                                           update:update
                                  dropCountOverride:0];
        }
        if (status == kCGDisplayStreamFrameStatusStopped) {
          // Signal on a block queued behind this callback. That guarantees
          // the transferred stream reference is not released while the
          // terminal callback is still executing.
          dispatch_async(callbackQueue, ^{
            dispatch_semaphore_signal(stoppedSemaphore);
          });
        }
      };
    _displayStream = createFunction(
      displayID,
      outputWidth,
      outputHeight,
      (int)pixelFormat,
      (__bridge CFDictionaryRef)[properties copy],
      callbackQueue,
      displayHandler);
    if (_displayStream == NULL) {
      NSError *creationError = LumenSkyLightDisplayStreamError(
        @"SLDisplayStreamCreateWithDispatchQueue",
        (CGError)kCGErrorFailure,
        @"SLDisplayStreamCreateWithDispatchQueue returned NULL.");
      _usesSLDisplayStream = YES;
      _lastError = creationError;
      _displayStreamStoppedSemaphore = nil;
      // Keep the wrapper alive so start() can return the actual create
      // diagnostic through NSError rather than collapsing it to a nil init.
      return self;
    }
  }
  [self refreshPrivateStreamIdentity];
  return self;
}

- (instancetype)initWithDisplayID:(uint32_t)displayID
                       outputWidth:(size_t)outputWidth
                      outputHeight:(size_t)outputHeight
                       pixelFormat:(OSType)pixelFormat
                  minimumFrameTime:(double)minimumFrameTime
                        queueDepth:(NSInteger)queueDepth
                        showCursor:(BOOL)showCursor
                       yCbCrMatrix:(nullable NSString *)yCbCrMatrix
                      callbackQueue:(dispatch_queue_t)callbackQueue
                       frameHandler:(LumenMacSkyLightDisplayStreamFrameHandler)frameHandler {
  return [self initWithDisplayID:displayID
                    outputWidth:outputWidth
                   outputHeight:outputHeight
                    pixelFormat:pixelFormat
               minimumFrameTime:minimumFrameTime
                     queueDepth:queueDepth
                     showCursor:showCursor
                    yCbCrMatrix:yCbCrMatrix
               dynamicRangeMode:0
                 colorSpaceName:nil
                  callbackQueue:callbackQueue
                   frameHandler:frameHandler];
}

- (NSString *)backendName {
  @synchronized (self) {
    return _usesSLDisplayStream
      ? @"skylight-display-stream"
      : @"skylight-content-stream";
  }
}

- (BOOL)isRunning {
  @synchronized (self) {
    return _running;
  }
}

- (NSString *)contentStreamClassName {
  @synchronized (self) {
    return [_contentStreamClassName copy];
  }
}

- (NSString *)contentStreamSessionClassName {
  @synchronized (self) {
    return [_contentStreamSessionClassName copy];
  }
}

- (BOOL)underlyingDisplayStreamAvailable {
  @synchronized (self) {
    return _underlyingDisplayStreamAvailable;
  }
}

- (uint64_t)underlyingDisplayStreamTypeID {
  @synchronized (self) {
    return _underlyingDisplayStreamTypeID;
  }
}

- (uint64_t)firstFrameDropCount {
  @synchronized (self) {
    return _firstFrameDropCount;
  }
}

- (uint64_t)cumulativeDropCount {
  @synchronized (self) {
    return _cumulativeDropCount;
  }
}

- (NSError *)lastError {
  @synchronized (self) {
    return [_lastError copy];
  }
}

- (BOOL)startWithError:(NSError **)error {
  id contentStream = nil;
  CGDisplayStreamRef displayStream = NULL;
  BOOL usesDisplayStream = NO;
  @synchronized (self) {
    if (_running) {
      return YES;
    }
    contentStream = _contentStream;
    displayStream = _displayStream;
    usesDisplayStream = _usesSLDisplayStream;
  }
  if (usesDisplayStream) {
    if (displayStream == NULL) {
      NSError *reportedError = nil;
      @synchronized (self) { reportedError = [_lastError copy]; }
      if (reportedError == nil) {
        reportedError = LumenSkyLightDisplayStreamError(
          @"SLDisplayStreamStart", (CGError)kCGErrorFailure,
          @"SLDisplayStream was not created.");
      }
      @synchronized (self) { _lastError = [reportedError copy]; }
      if (error != NULL) { *error = reportedError; }
      return NO;
    }
    LumenSLDisplayStreamStart startFunction =
      LumenSLDisplayStreamStartFunction();
    if (startFunction == NULL) {
      NSError *reportedError = LumenSkyLightDisplayStreamError(
        @"SLDisplayStreamStart", (CGError)kCGErrorFailure,
        @"SLDisplayStreamStart symbol is unavailable.");
      @synchronized (self) { _lastError = [reportedError copy]; }
      if (error != NULL) { *error = reportedError; }
      return NO;
    }
    CGError status = startFunction(displayStream);
    if (status != kCGErrorSuccess) {
      NSError *reportedError = LumenSkyLightDisplayStreamError(
        @"SLDisplayStreamStart", status,
        [NSString stringWithFormat:@"SLDisplayStreamStart failed (%d).", status]);
      @synchronized (self) { _lastError = [reportedError copy]; }
      if (error != NULL) { *error = reportedError; }
      return NO;
    }
    @synchronized (self) {
      _lastError = nil;
      _running = YES;
      _displayStreamStarted = YES;
    }
    [self refreshPrivateStreamIdentity];
    return YES;
  }
  if (contentStream == nil) {
    LumenAssignContentStreamError(
      error,
      LumenSkyLightContentStreamErrorStreamCreationFailed,
      @"SLContentStream was not created."
    );
    return NO;
  }

  SEL selector = sel_registerName("start:");
  typedef BOOL (*LumenContentStreamStart)(id, SEL, NSError **);
  NSError *underlyingError = nil;
  BOOL started = ((LumenContentStreamStart)objc_msgSend)(
    contentStream,
    selector,
    &underlyingError
  );
  if (!started) {
    NSError *reportedError = underlyingError;
    if (reportedError == nil) {
      reportedError = [NSError errorWithDomain:LumenSkyLightContentStreamErrorDomain
                                           code:LumenSkyLightContentStreamErrorStartFailed
                                       userInfo:@{NSLocalizedDescriptionKey: @"SLContentStream rejected start."}];
    }
    @synchronized (self) {
      _lastError = [reportedError copy];
    }
    if (error != NULL) {
      *error = reportedError;
    }
    return NO;
  }

  @synchronized (self) {
    _lastError = nil;
    _running = YES;
  }
  [self refreshPrivateStreamIdentity];
  return YES;
}

- (int32_t)stop {
  id contentStream = nil;
  CGDisplayStreamRef displayStream = NULL;
  BOOL usesDisplayStream = NO;
  BOOL displayStreamStarted = NO;
  dispatch_semaphore_t stoppedSemaphore = nil;
  @synchronized (self) {
    contentStream = _contentStream;
    displayStream = _displayStream;
    usesDisplayStream = _usesSLDisplayStream;
    if (usesDisplayStream) {
      if (displayStream == NULL) {
        return 0;
      }
      if (_displayStreamStopRequested) {
        // A second stop must not call the private stop entry point twice or
        // transfer the same Core Foundation reference to two waiters.
        return 0;
      }
      _running = NO;
      displayStreamStarted = _displayStreamStarted;
      _displayStreamStarted = NO;
      _displayStreamStopRequested = displayStreamStarted;
      stoppedSemaphore = _displayStreamStoppedSemaphore;
    } else {
      if (!_running || contentStream == nil) {
        return 0;
      }
      _running = NO;
    }
  }
  if (usesDisplayStream) {
    if (!displayStreamStarted) {
      @synchronized (self) {
        _displayStream = NULL;
        _displayStreamStoppedSemaphore = nil;
        _underlyingDisplayStreamAvailable = NO;
        _underlyingDisplayStreamTypeID = 0;
      }
      CFRelease(displayStream);
      return 0;
    }
    LumenSLDisplayStreamStop stopFunction =
      LumenSLDisplayStreamStopFunction();
    CGError status = stopFunction == NULL
      ? (CGError)kCGErrorFailure
      : stopFunction(displayStream);
    NSError *reportedError = status == kCGErrorSuccess
      ? nil
      : LumenSkyLightDisplayStreamError(
          @"SLDisplayStreamStop", status,
          stopFunction == NULL
            ? @"SLDisplayStreamStop symbol is unavailable."
            : [NSString stringWithFormat:
                @"SLDisplayStreamStop failed (%d).", status]);
    @synchronized (self) {
      _lastError = [reportedError copy];
      // Transfer the wrapper-owned CF reference to the terminal-callback
      // waiter.  The callback will signal stoppedSemaphore even if the weak
      // wrapper reference is already gone.
      _displayStream = NULL;
      _displayStreamStoppedSemaphore = nil;
      _underlyingDisplayStreamAvailable = NO;
      _underlyingDisplayStreamTypeID = 0;
    }
    LumenReleaseRawDisplayStreamAfterStopped(
      displayStream,
      stoppedSemaphore
    );
    // Preserve the original CGError for callers; do not collapse a private
    // stop failure into a generic -1.
    return (int32_t)status;
  }
  if (contentStream == nil) {
    return 0;
  }

  SEL selector = sel_registerName("stop:");
  typedef BOOL (*LumenContentStreamStop)(id, SEL, NSError **);
  NSError *underlyingError = nil;
  BOOL stopped = ((LumenContentStreamStop)objc_msgSend)(
    contentStream,
    selector,
    &underlyingError
  );
  @synchronized (self) {
    _lastError = [underlyingError copy];
  }
  if (stopped) {
    return 0;
  }
  return -1;
}

- (void)dealloc {
  [self stop];
}

- (void)refreshPrivateStreamIdentity {
  if (_usesSLDisplayStream) {
    @synchronized (self) {
      _contentStreamSessionClassName = nil;
      _underlyingDisplayStreamAvailable = _displayStream != NULL;
      _underlyingDisplayStreamTypeID = _displayStream == NULL
        ? 0
        : (uint64_t)CFGetTypeID(_displayStream);
    }
    return;
  }
  id contentStream = _contentStream;
  if (contentStream == nil) {
    return;
  }

  id session = nil;
  SEL sessionSelector = sel_registerName("session");
  if ([contentStream respondsToSelector:sessionSelector]) {
    typedef id (*LumenContentStreamSessionGetter)(id, SEL);
    session = ((LumenContentStreamSessionGetter)objc_msgSend)(
      contentStream,
      sessionSelector
    );
  }

  CGDisplayStreamRef displayStream = NULL;
  SEL streamSelector = sel_registerName("stream");
  if ([contentStream respondsToSelector:streamSelector]) {
    typedef CGDisplayStreamRef (*LumenContentStreamGetter)(id, SEL);
    displayStream = ((LumenContentStreamGetter)objc_msgSend)(
      contentStream,
      streamSelector
    );
  }

  @synchronized (self) {
    _contentStreamSessionClassName = session == nil
      ? nil
      : NSStringFromClass([session class]);
    _underlyingDisplayStreamAvailable = displayStream != NULL;
    _underlyingDisplayStreamTypeID = displayStream == NULL
      ? 0
      : (uint64_t)CFGetTypeID(displayStream);
  }
}

- (void)handleContentStreamUpdate:(id)update {
  if (update == nil) {
    return;
  }

  typedef int32_t (*LumenContentStreamUpdateStatusGetter)(id, SEL);
  typedef uint64_t (*LumenContentStreamUpdateUInt64Getter)(id, SEL);
  typedef id (*LumenContentStreamUpdateObjectGetter)(id, SEL);
  const int32_t rawStatus =
    ((LumenContentStreamUpdateStatusGetter)objc_msgSend)(
      update,
      sel_registerName("status")
    );
  const uint64_t displayTime =
    ((LumenContentStreamUpdateUInt64Getter)objc_msgSend)(
      update,
      sel_registerName("displayTime")
    );
  const uint64_t dropCount =
    ((LumenContentStreamUpdateUInt64Getter)objc_msgSend)(
      update,
      sel_registerName("dropCount")
    );
  id surfaceObject = ((LumenContentStreamUpdateObjectGetter)objc_msgSend)(
    update,
    sel_registerName("frameSurface")
  );

  IOSurfaceRef surface = NULL;
  if (surfaceObject != nil &&
      CFGetTypeID((__bridge CFTypeRef)surfaceObject) == IOSurfaceGetTypeID()) {
    surface = (__bridge IOSurfaceRef)surfaceObject;
  }
  [self handleDisplayStreamStatus:(CGDisplayStreamFrameStatus)rawStatus
                       displayTime:displayTime
                            surface:surface
                             update:NULL
                    dropCountOverride:(size_t)dropCount];
}

- (void)handleDisplayStreamStatus:(CGDisplayStreamFrameStatus)status
                     displayTime:(uint64_t)displayTime
                          surface:(IOSurfaceRef)surface
                           update:(CGDisplayStreamUpdateRef)update
                  dropCountOverride:(size_t)dropCountOverride {
  CGDisplayStreamRef streamToRelease = NULL;
  BOOL suppressRequestedStop = NO;
  @synchronized (self) {
    if (_usesSLDisplayStream &&
        status == kCGDisplayStreamFrameStatusStopped) {
      suppressRequestedStop = _displayStreamStopRequested;
      _running = NO;
      _displayStreamStarted = NO;
      // An unsolicited terminal callback has no stop() waiter. Transfer the
      // owned reference to a block queued behind the current callback.
      if (!suppressRequestedStop && _displayStream != NULL) {
        streamToRelease = _displayStream;
        _displayStream = NULL;
        _underlyingDisplayStreamAvailable = NO;
        _underlyingDisplayStreamTypeID = 0;
      }
    }
  }
  size_t rawDropCount = dropCountOverride;
  if (update != NULL) {
    LumenSLDisplayStreamUpdateGetDropCount getDropCount =
      LumenSLDisplayStreamUpdateGetDropCountFunction();
    if (getDropCount != NULL) {
      rawDropCount = getDropCount(update);
    }
  }
  const uint64_t dropCount = (uint64_t)rawDropCount;
  @synchronized (self) {
    if (!_recordedFirstFrameDropCount &&
        status == kCGDisplayStreamFrameStatusFrameComplete) {
      _firstFrameDropCount = dropCount;
      _recordedFirstFrameDropCount = YES;
    }
    if (UINT64_MAX - _cumulativeDropCount < dropCount) {
      _cumulativeDropCount = UINT64_MAX;
    } else {
      _cumulativeDropCount += dropCount;
    }
  }

  CVPixelBufferRef pixelBuffer = NULL;
  CVReturn pixelBufferStatus = kCVReturnSuccess;
  if (surface != NULL) {
    pixelBufferStatus = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault, surface, NULL, &pixelBuffer);
  } else if (status == kCGDisplayStreamFrameStatusFrameComplete) {
    pixelBufferStatus = kCVReturnInvalidArgument;
  }
  LumenMacSkyLightDisplayStreamFrameHandler handler = _frameHandler;
  if (handler != nil && !suppressRequestedStop) {
    handler(status, displayTime, pixelBuffer, pixelBufferStatus);
  }
  if (pixelBuffer != NULL) {
    CVPixelBufferRelease(pixelBuffer);
  }
  if (streamToRelease != NULL) {
    dispatch_async(_callbackQueue, ^{
      CFRelease(streamToRelease);
    });
  }
}

@end
