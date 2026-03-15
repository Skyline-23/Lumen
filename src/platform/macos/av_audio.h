/**
 * @file src/platform/macos/av_audio.h
 * @brief Declarations for audio capture on macOS.
 */
#pragma once

// platform includes
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  #import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

// lib includes
#include "third-party/TPCircularBuffer/TPCircularBuffer.h"

#define kBufferLength 4096

@interface AVAudio: NSObject <AVCaptureAudioDataOutputSampleBufferDelegate
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
, SCStreamOutput, SCStreamDelegate
#endif
> {
@public
  TPCircularBuffer audioSampleBuffer;
}

@property (nonatomic, assign) AVCaptureSession *audioCaptureSession;
@property (nonatomic, assign) AVCaptureConnection *audioConnection;
@property (nonatomic, assign) NSCondition *samplesArrivedSignal;
@property (nonatomic, assign) UInt32 sampleRate;
@property (nonatomic, assign) UInt32 frameSize;
@property (nonatomic, assign) UInt8 channels;

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
@property (nonatomic, assign) SCDisplay *shareableDisplay;
@property (nonatomic, assign) SCStream *stream;
@property (nonatomic, assign) dispatch_queue_t sampleHandlerQueue;
#endif

+ (NSArray *)microphoneNames;
+ (AVCaptureDevice *)findMicrophone:(NSString *)name;

- (int)setupMicrophone:(AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;
- (int)setupSystemAudioWithDisplayID:(CGDirectDisplayID)displayID sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

@end
