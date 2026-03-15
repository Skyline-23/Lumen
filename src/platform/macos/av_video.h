/**
 * @file src/platform/macos/av_video.h
 * @brief Declarations for video capture on macOS.
 */
#pragma once

// platform includes
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  #import <ScreenCaptureKit/ScreenCaptureKit.h>
  #define SUNSHINE_HAVE_SCREENCAPTUREKIT 1
#else
  #define SUNSHINE_HAVE_SCREENCAPTUREKIT 0
#endif

@interface AVVideo: NSObject <AVCaptureVideoDataOutputSampleBufferDelegate
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
, SCStreamDelegate, SCStreamOutput
#endif
>

#define kMaxDisplays 32

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) CMTime minFrameDuration;
@property (nonatomic, assign) OSType pixelFormat;
@property (nonatomic, assign) int frameWidth;
@property (nonatomic, assign) int frameHeight;

typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

@property (nonatomic, assign) AVCaptureSession *session;
@property (nonatomic, assign) NSMapTable<AVCaptureConnection *, AVCaptureVideoDataOutput *> *legacyVideoOutputs;
@property (nonatomic, assign) NSMapTable<AVCaptureConnection *, FrameCallbackBlock> *legacyCaptureCallbacks;
@property (nonatomic, assign) NSMapTable<AVCaptureConnection *, dispatch_semaphore_t> *legacyCaptureSignals;
@property (nonatomic, copy) FrameCallbackBlock captureCallback;
@property (nonatomic, assign) dispatch_semaphore_t captureSignal;
@property (nonatomic, assign) dispatch_semaphore_t frameAvailableSignal;
@property (nonatomic, assign) CMSampleBufferRef pendingSampleBuffer;
@property (nonatomic, assign) BOOL captureStopped;
@property (nonatomic, assign) uint64_t screenCaptureFrameCount;

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
@property (nonatomic, assign) SCDisplay *shareableDisplay;
@property (nonatomic, assign) SCStream *stream;
@property (nonatomic, assign) dispatch_queue_t sampleHandlerQueue;

- (BOOL)screenCaptureKitAvailableForDisplay API_AVAILABLE(macos(12.3));
- (BOOL)beginScreenCaptureKitCapture:(NSError **)error API_AVAILABLE(macos(12.3));
- (CMSampleBufferRef)copyNextScreenCaptureKitSampleBuffer API_AVAILABLE(macos(12.3));
- (void)finishScreenCaptureKitCapture API_AVAILABLE(macos(12.3));
#endif

+ (NSArray<NSDictionary *> *)displayNames;
+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID;

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback;

@end
