/**
 * @file src/platform/macos/av_video.m
 * @brief Definitions for video capture on macOS.
 */
// local includes
#import "av_video.h"

static NSString *const kSunshineVideoCaptureQueue = @"dev.lizardbyte.sunshine.video.capture";

@implementation AVVideo

+ (BOOL)shouldUseScreenCaptureKit {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if (@available(macOS 12.3, *)) {
    return YES;
  }
#endif

  return NO;
}

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
+ (SCShareableContent *)shareableContent:(NSError **)error API_AVAILABLE(macos(12.3)) {
  __block SCShareableContent *shareableContent = nil;
  __block NSError *shareableContentError = nil;
  dispatch_semaphore_t signal = dispatch_semaphore_create(0);

  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                            onScreenWindowsOnly:NO
                                              completionHandler:^(SCShareableContent *content, NSError *contentError) {
                                                shareableContent = [content retain];
                                                shareableContentError = [contentError retain];
                                                dispatch_semaphore_signal(signal);
                                              }];

  dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

  if (error != NULL) {
    *error = [shareableContentError autorelease];
  } else if (shareableContentError != nil) {
    [shareableContentError release];
  }

  return [shareableContent autorelease];
}

+ (SCDisplay *)shareableDisplayWithID:(CGDirectDisplayID)displayID error:(NSError **)error API_AVAILABLE(macos(12.3)) {
  SCShareableContent *content = [self shareableContent:error];
  if (content == nil) {
    return nil;
  }

  for (SCDisplay *display in content.displays) {
    if (display.displayID == displayID) {
      return display;
    }
  }

  return nil;
}
#endif

// XXX: Currently, this function only returns the screen IDs as names,
// which is not very helpful to the user. The API to retrieve names
// was deprecated with 10.9+.
// However, there is a solution with little external code that can be used:
// https://stackoverflow.com/questions/20025868/cgdisplayioserviceport-is-deprecated-in-os-x-10-9-how-to-replace
+ (NSArray<NSDictionary *> *)displayNames {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if ([self shouldUseScreenCaptureKit]) {
    NSError *error = nil;
    SCShareableContent *content = [self shareableContent:&error];
    if (content != nil) {
      NSMutableArray *result = [NSMutableArray arrayWithCapacity:content.displays.count];

      for (SCDisplay *display in content.displays) {
        [result addObject:@{
          @"id": [NSNumber numberWithUnsignedInt:display.displayID],
          @"name": [NSString stringWithFormat:@"%u", display.displayID],
          @"displayName": [self getDisplayName:display.displayID] ?: [NSString stringWithFormat:@"%u", display.displayID],
        }];
      }

      return result;
    }
  }
#endif

  CGDirectDisplayID displays[kMaxDisplays];
  uint32_t count;
  if (CGGetActiveDisplayList(kMaxDisplays, displays, &count) != kCGErrorSuccess) {
    return [NSArray array];
  }

  NSMutableArray *result = [NSMutableArray array];

  for (uint32_t i = 0; i < count; i++) {
    [result addObject:@{
      @"id": [NSNumber numberWithUnsignedInt:displays[i]],
      @"name": [NSString stringWithFormat:@"%d", displays[i]],
      @"displayName": [self getDisplayName:displays[i]],
    }];
  }

  return [NSArray arrayWithArray:result];
}

+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID {
  for (NSScreen *screen in [NSScreen screens]) {
    if ([screen.deviceDescription[@"NSScreenNumber"] isEqualToNumber:[NSNumber numberWithUnsignedInt:displayID]]) {
      return screen.localizedName;
    }
  }
  return nil;
}

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];

  if (self == nil) {
    return nil;
  }

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);

  self.displayID = displayID;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
  self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
  self.minFrameDuration = CMTimeMake(1, frameRate);

  CFRelease(mode);

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if ([AVVideo shouldUseScreenCaptureKit]) {
    NSError *error = nil;
    self.shareableDisplay = [[AVVideo shareableDisplayWithID:self.displayID error:&error] retain];
    if (self.shareableDisplay != nil) {
      return self;
    }
  }
#endif

  self.session = [[AVCaptureSession alloc] init];
  self.legacyVideoOutputs = [[NSMapTable alloc] init];
  self.legacyCaptureCallbacks = [[NSMapTable alloc] init];
  self.legacyCaptureSignals = [[NSMapTable alloc] init];

  AVCaptureScreenInput *screenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:self.displayID];
  [screenInput setMinFrameDuration:self.minFrameDuration];

  if ([self.session canAddInput:screenInput]) {
    [self.session addInput:screenInput];
    [screenInput release];
  } else {
    [screenInput release];
    return nil;
  }

  [self.session startRunning];

  return self;
}

- (void)dealloc {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if (self.stream != nil) {
    dispatch_semaphore_t stopSignal = dispatch_semaphore_create(0);
    [self.stream stopCaptureWithCompletionHandler:^(__unused NSError *stopError) {
      dispatch_semaphore_signal(stopSignal);
    }];
    dispatch_semaphore_wait(stopSignal, DISPATCH_TIME_FOREVER);
  }

  [self.shareableDisplay release];
  [self.stream release];
#endif

  if (self.pendingSampleBuffer != nil) {
    CFRelease(self.pendingSampleBuffer);
    self.pendingSampleBuffer = nil;
  }

  [self.captureCallback release];
  [self.legacyVideoOutputs release];
  [self.legacyCaptureCallbacks release];
  [self.legacyCaptureSignals release];
  [self.session stopRunning];
  [self.session release];
  [super dealloc];
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  self.frameWidth = frameWidth;
  self.frameHeight = frameHeight;
}

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
- (BOOL)screenCaptureKitAvailableForDisplay {
  if (![AVVideo shouldUseScreenCaptureKit]) {
    return NO;
  }

  return self.shareableDisplay != nil;
}

- (BOOL)sampleBufferIsComplete:(CMSampleBufferRef)sampleBuffer API_AVAILABLE(macos(12.3)) {
  if (sampleBuffer == nil || !CMSampleBufferIsValid(sampleBuffer)) {
    return NO;
  }

  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (attachments == nil || CFArrayGetCount(attachments) == 0) {
    return YES;
  }

  CFDictionaryRef attachment = (CFDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
  CFTypeRef statusValue = CFDictionaryGetValue(attachment, SCStreamFrameInfoStatus);
  if (statusValue == nil) {
    return YES;
  }

  NSInteger status = [(__bridge NSNumber *) statusValue integerValue];
  return status == SCFrameStatusComplete || status == SCFrameStatusStarted;
}

- (BOOL)startScreenCaptureKitStream:(NSError **)error API_AVAILABLE(macos(12.3)) {
  if (![self screenCaptureKitAvailableForDisplay]) {
    return NO;
  }

  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:self.shareableDisplay
                                               excludingApplications:@[]
                                                    exceptingWindows:@[]];
  SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
  configuration.width = (size_t) MAX(self.frameWidth, 1);
  configuration.height = (size_t) MAX(self.frameHeight, 1);
  configuration.minimumFrameInterval = self.minFrameDuration;
  configuration.pixelFormat = self.pixelFormat;
  configuration.showsCursor = YES;
  configuration.queueDepth = 3;

  if (@available(macOS 13.0, *)) {
    configuration.capturesAudio = NO;
  }

  self.sampleHandlerQueue = dispatch_queue_create(kSunshineVideoCaptureQueue.UTF8String, DISPATCH_QUEUE_SERIAL);
  self.stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];

  NSError *streamError = nil;
  if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.sampleHandlerQueue error:&streamError]) {
    if (error != NULL) {
      *error = streamError;
    }

    [self.stream release];
    self.stream = nil;
    [configuration release];
    [filter release];
    return NO;
  }

  dispatch_semaphore_t signal = dispatch_semaphore_create(0);
  __block NSError *startError = nil;
  [self.stream startCaptureWithCompletionHandler:^(NSError *captureError) {
    startError = [captureError retain];
    dispatch_semaphore_signal(signal);
  }];
  dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

  [configuration release];
  [filter release];

  if (startError != nil) {
    if (error != NULL) {
      *error = [startError autorelease];
    } else {
      [startError release];
    }

    NSError *removeError = nil;
    [self.stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:&removeError];
    [self.stream release];
    self.stream = nil;
    return NO;
  }

  return YES;
}

- (void)stopScreenCaptureKitStream API_AVAILABLE(macos(12.3)) {
  if (self.stream == nil) {
    return;
  }

  NSError *removeError = nil;
  [self.stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:&removeError];

  dispatch_semaphore_t signal = dispatch_semaphore_create(0);
  SCStream *stream = [self.stream retain];
  self.stream = nil;

  [stream stopCaptureWithCompletionHandler:^(__unused NSError *stopError) {
    dispatch_semaphore_signal(signal);
  }];
  dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

  [stream release];
}

- (BOOL)beginScreenCaptureKitCapture:(NSError **)error API_AVAILABLE(macos(12.3)) {
  self.frameAvailableSignal = dispatch_semaphore_create(0);
  self.captureStopped = NO;
  self.captureSignal = nil;
  self.captureCallback = nil;
  if (self.pendingSampleBuffer != nil) {
    CFRelease(self.pendingSampleBuffer);
    self.pendingSampleBuffer = nil;
  }

  if (![self startScreenCaptureKitStream:error]) {
    self.frameAvailableSignal = nil;
    return NO;
  }

  return YES;
}

- (CMSampleBufferRef)copyNextScreenCaptureKitSampleBuffer API_AVAILABLE(macos(12.3)) {
  while (true) {
    dispatch_semaphore_wait(self.frameAvailableSignal, DISPATCH_TIME_FOREVER);

    CMSampleBufferRef sampleBuffer = nil;
    BOOL captureStopped = NO;
    @synchronized(self) {
      sampleBuffer = self.pendingSampleBuffer;
      self.pendingSampleBuffer = nil;
      captureStopped = self.captureStopped;
    }

    if (sampleBuffer == nil) {
      if (captureStopped) {
        NSLog(@"AVVideo ScreenCaptureKit capture loop stopping because captureStopped=YES");
        break;
      }
      NSLog(@"AVVideo ScreenCaptureKit capture loop woke without sample buffer");
      continue;
    }
    NSLog(@"AVVideo ScreenCaptureKit produced sample buffer");
    return sampleBuffer;
  }

  return nil;
}

- (void)finishScreenCaptureKitCapture API_AVAILABLE(macos(12.3)) {
  @synchronized(self) {
    self.captureStopped = YES;
  }
  NSLog(@"AVVideo finishScreenCaptureKitCapture called");
  [self stopScreenCaptureKitStream];
  self.frameAvailableSignal = nil;
}
#endif

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if ([self screenCaptureKitAvailableForDisplay]) {
    return nil;
  }
#endif

  @synchronized(self) {
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];

    [videoOutput setVideoSettings:@{
      (NSString *) kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:self.pixelFormat],
      (NSString *) kCVPixelBufferWidthKey: [NSNumber numberWithInt:self.frameWidth],
      (NSString *) kCVPixelBufferHeightKey: [NSNumber numberWithInt:self.frameHeight],
      (NSString *) AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    }];

    dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
    dispatch_queue_t recordingQueue = dispatch_queue_create("videoCaptureQueue", qos);
    [videoOutput setSampleBufferDelegate:self queue:recordingQueue];

    [self.session stopRunning];

    if ([self.session canAddOutput:videoOutput]) {
      [self.session addOutput:videoOutput];
    } else {
      [videoOutput release];
      return nil;
    }

    AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);

    [self.legacyVideoOutputs setObject:videoOutput forKey:videoConnection];
    [self.legacyCaptureCallbacks setObject:frameCallback forKey:videoConnection];
    [self.legacyCaptureSignals setObject:signal forKey:videoConnection];

    [self.session startRunning];

    return signal;
  }
}

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen || ![self sampleBufferIsComplete:sampleBuffer]) {
    return;
  }

  dispatch_semaphore_t frameSignal = self.frameAvailableSignal;
  if (frameSignal == nil) {
    return;
  }

  @synchronized(self) {
    if (self.pendingSampleBuffer != nil) {
      CFRelease(self.pendingSampleBuffer);
    }
    self.pendingSampleBuffer = (CMSampleBufferRef) CFRetain(sampleBuffer);
  }
  NSLog(@"AVVideo didOutputSampleBuffer queued screen sample");
  dispatch_semaphore_signal(frameSignal);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
  dispatch_semaphore_t frameSignal = self.frameAvailableSignal;
  NSLog(@"AVVideo ScreenCaptureKit stream stopped with error: %@", error);
  @synchronized(self) {
    self.captureStopped = YES;
    if (self.pendingSampleBuffer != nil) {
      CFRelease(self.pendingSampleBuffer);
      self.pendingSampleBuffer = nil;
    }
  }

  if (frameSignal != nil) {
    dispatch_semaphore_signal(frameSignal);
  }
}
#endif

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  FrameCallbackBlock callback = [self.legacyCaptureCallbacks objectForKey:connection];

  if (callback != nil) {
    if (!callback(sampleBuffer)) {
      @synchronized(self) {
        [self.session stopRunning];
        [self.legacyCaptureCallbacks removeObjectForKey:connection];
        [self.session removeOutput:[self.legacyVideoOutputs objectForKey:connection]];
        [self.legacyVideoOutputs removeObjectForKey:connection];
        dispatch_semaphore_signal([self.legacyCaptureSignals objectForKey:connection]);
        [self.legacyCaptureSignals removeObjectForKey:connection];
        [self.session startRunning];
      }
    }
  }
}

@end
