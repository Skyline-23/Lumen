#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <LumenMacBridge/LumenMacBridge-Swift.h>
#import <LumenMacBridge/LumenMacBridge.h>
#import <os/lock.h>

#include "lumen_host.h"
#include <opus/opus_multistream.h>

static const size_t LumenWorkerMaximumVideoBytes = 32 * 1024 * 1024;
static const size_t LumenWorkerMaximumPCMBytes = 1024 * 1024;
static NSString *const LumenRuntimeEventNotification = @"LumenRuntimeEventNotification";
static const int LumenWorkerAudioFrameCount = 240;

static uint32_t LumenWorkerAudioTimestamp(uint64_t nanoseconds) {
  const uint64_t seconds = nanoseconds / 1000000000ULL;
  const uint64_t remainder = nanoseconds % 1000000000ULL;
  return (uint32_t) ((seconds * 48000ULL) + ((remainder * 48000ULL) / 1000000000ULL));
}

static void LumenWorkerAppendStartCode(NSMutableData *data) {
  static const uint8_t startCode[] = {0, 0, 0, 1};
  [data appendBytes:startCode length:sizeof(startCode)];
}

static BOOL LumenWorkerAppendParameterSets(
  NSMutableData *output,
  CMFormatDescriptionRef format,
  LumenMacCaptureCodec codec,
  int *nalLengthSize
) {
  size_t count = 0;
  const uint8_t *bytes = NULL;
  size_t length = 0;
  OSStatus status = noErr;

  if (codec == LumenMacCaptureCodecH264) {
    status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      format,
      0,
      &bytes,
      &length,
      &count,
      nalLengthSize
    );
  } else {
    status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
      format,
      0,
      &bytes,
      &length,
      &count,
      nalLengthSize
    );
  }
  if (status != noErr || count == 0 || *nalLengthSize < 1 || *nalLengthSize > 4) {
    return NO;
  }

  for (size_t index = 0; index < count; ++index) {
    if (codec == LumenMacCaptureCodecH264) {
      status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format,
        index,
        &bytes,
        &length,
        NULL,
        NULL
      );
    } else {
      status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        format,
        index,
        &bytes,
        &length,
        NULL,
        NULL
      );
    }
    if (status != noErr || !bytes || length == 0) {
      return NO;
    }
    LumenWorkerAppendStartCode(output);
    [output appendBytes:bytes length:length];
  }
  return YES;
}

static NSData *LumenWorkerCopyAnnexBFrame(
  CMSampleBufferRef sampleBuffer,
  LumenMacCaptureCodec codec,
  BOOL keyFrame
) {
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
  if (!format || !block) {
    return nil;
  }

  int nalLengthSize = 0;
  NSMutableData *output = [NSMutableData data];
  if (!LumenWorkerAppendParameterSets(
        keyFrame ? output : [NSMutableData data],
        format,
        codec,
        &nalLengthSize
      )) {
    return nil;
  }
  if (!keyFrame) {
    [output setLength:0];
  }

  const size_t inputLength = CMBlockBufferGetDataLength(block);
  if (inputLength == 0 || inputLength > LumenWorkerMaximumVideoBytes) {
    return nil;
  }
  NSMutableData *input = [NSMutableData dataWithLength:inputLength];
  if (CMBlockBufferCopyDataBytes(block, 0, inputLength, input.mutableBytes) != noErr) {
    return nil;
  }

  const uint8_t *cursor = input.bytes;
  size_t offset = 0;
  while (offset + (size_t) nalLengthSize <= inputLength) {
    uint32_t nalLength = 0;
    for (int index = 0; index < nalLengthSize; ++index) {
      nalLength = (nalLength << 8) | cursor[offset + (size_t) index];
    }
    offset += (size_t) nalLengthSize;
    if (nalLength == 0 || offset + nalLength > inputLength) {
      return nil;
    }
    LumenWorkerAppendStartCode(output);
    [output appendBytes:cursor + offset length:nalLength];
    offset += nalLength;
  }
  if (offset != inputLength || output.length > LumenWorkerMaximumVideoBytes) {
    return nil;
  }
  return output;
}

static uint32_t LumenWorkerVideoTimestamp(CMSampleBufferRef sampleBuffer) {
  CMTime time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  if (!CMTIME_IS_NUMERIC(time) || time.timescale <= 0) {
    return 0;
  }
  CMTime scaled = CMTimeConvertScale(time, 90000, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
  return (uint32_t) scaled.value;
}

@interface LumenHostWorkerPlatform : NSObject {
  os_unfair_lock _lock;
  LumenMacBridgeController *_bridge;
  NSString *_workspaceKey;
  uint32_t _displayID;
  NSData *_pendingVideo;
  uint32_t _pendingVideoTimestamp;
  BOOL _pendingVideoKeyFrame;
  NSData *_pendingAudio;
  uint32_t _pendingAudioTimestamp;
  NSMutableData *_pcm;
  NSMutableData *_audioScratch;
  uint32_t _nextAudioTimestamp;
  BOOL _hasAudioTimestamp;
  int _audioChannels;
  OpusMSEncoder *_opus;
}
- (int32_t)startSession:(const LumenHostPlatformSessionPlan *)plan;
- (int32_t)stopSession;
- (int32_t)pollVideo:(uint8_t *)destination
            capacity:(size_t)capacity
               frame:(LumenHostPlatformEncodedVideoFrame *)frame;
- (int32_t)pollAudio:(uint8_t *)destination
            capacity:(size_t)capacity
              packet:(LumenHostPlatformEncodedAudioPacket *)packet;
- (int32_t)handleControlEvent:(const LumenHostPlatformControlEvent *)event;
@end

@implementation LumenHostWorkerPlatform

- (instancetype)init {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _bridge = LumenMacBridgeControllerCreate();
    _pcm = [NSMutableData data];
    _audioScratch = [NSMutableData dataWithLength:LumenWorkerMaximumPCMBytes];
  }
  return self;
}

- (void)dealloc {
  [self stopSession];
  if (_bridge) {
    LumenMacBridgeControllerDestroy(_bridge);
    _bridge = NULL;
  }
}

- (BOOL)createOpusEncoder:(const LumenHostPlatformSessionPlan *)plan {
  int streams = 0;
  int coupled = 0;
  int bitrate = 0;
  const int encoder_complexity = plan->enhanced_audio_quality ? 10 : 5;
  unsigned char mapping[8] = {0, 1, 2, 3, 4, 5, 6, 7};
  switch (plan->audio_channels) {
    case 2:
      streams = 1;
      coupled = 1;
      bitrate = plan->enhanced_audio_quality ? 512000 : 96000;
      break;
    case 6:
      streams = plan->enhanced_audio_quality ? 6 : 4;
      coupled = plan->enhanced_audio_quality ? 0 : 2;
      bitrate = plan->enhanced_audio_quality ? 1536000 : 256000;
      break;
    case 8:
      streams = plan->enhanced_audio_quality ? 8 : 5;
      coupled = plan->enhanced_audio_quality ? 0 : 3;
      bitrate = plan->enhanced_audio_quality ? 2048000 : 450000;
      break;
    default:
      return NO;
  }

  int error = OPUS_OK;
  _opus = opus_multistream_encoder_create(
    48000,
    plan->audio_channels,
    streams,
    coupled,
    mapping,
    OPUS_APPLICATION_RESTRICTED_LOWDELAY,
    &error
  );
  if (!_opus || error != OPUS_OK) {
    _opus = NULL;
    return NO;
  }
  if (opus_multistream_encoder_ctl(_opus, OPUS_SET_BITRATE(bitrate)) != OPUS_OK ||
      opus_multistream_encoder_ctl(_opus, OPUS_SET_COMPLEXITY(encoder_complexity)) != OPUS_OK ||
      opus_multistream_encoder_ctl(_opus, OPUS_SET_VBR(0)) != OPUS_OK) {
    opus_multistream_encoder_destroy(_opus);
    _opus = NULL;
    return NO;
  }
  _audioChannels = plan->audio_channels;
  return YES;
}

- (uint32_t)createDisplayForPlan:(const LumenHostPlatformSessionPlan *)plan error:(NSError **)error {
  if (!plan->virtual_display) {
    return CGMainDisplayID();
  }
  LumenMacWorkspaceSessionRequestBox *request = [[LumenMacWorkspaceSessionRequestBox alloc] init];
  _workspaceKey = NSUUID.UUID.UUIDString;
  request.displayKey = _workspaceKey;
  request.displayName = @"Lumen Display";
  request.width = plan->width;
  request.height = plan->height;
  request.refreshRate = plan->frames_per_second;
  request.scalePercent = 100;
  request.dimensionsAreLogical = NO;
  request.hdrEnabled = plan->dynamic_range == LumenHostPlatformDynamicRangeHDR10;
  return [LumenMacWorkspaceSessionFacade.shared prepareSessionSync:request error:error];
}

- (int32_t)startSession:(const LumenHostPlatformSessionPlan *)plan {
  if (!plan || !_bridge) {
    return LumenHostPlatformStartSessionStatusInvalidConfiguration;
  }
  os_unfair_lock_lock(&_lock);
  if ([self stopSessionLocked] != 0) {
    os_unfair_lock_unlock(&_lock);
    return LumenHostPlatformStartSessionStatusInvalidConfiguration;
  }

  NSError *displayError = nil;
  _displayID = [self createDisplayForPlan:plan error:&displayError];
  if (_displayID == 0 || displayError) {
    fprintf(
      stderr,
      "Lumen display creation failed: %s\n",
      displayError.localizedDescription.UTF8String ?: "unknown display error"
    );
    os_unfair_lock_unlock(&_lock);
    return LumenHostPlatformStartSessionStatusDisplayCreationFailed;
  }
  fprintf(
    stderr,
    "Lumen platform session stage=display-ready virtual=%s display-id=%u\n",
    plan->virtual_display ? "true" : "false",
    _displayID
  );
  if (![self createOpusEncoder:plan]) {
    fprintf(stderr, "Lumen audio encoder creation failed for %u channels\n", plan->audio_channels);
    (void) [self stopSessionLocked];
    os_unfair_lock_unlock(&_lock);
    return LumenHostPlatformStartSessionStatusAudioEncoderFailed;
  }

  LumenMacBridgeControllerConfigureVideoForwarding(_bridge, 3, 16);
  LumenMacBridgeControllerConfigureAudioForwarding(_bridge, 8, 16);
  LumenMacBridgeCaptureConfiguration video =
    LumenMacBridgeControllerMakePanelNativeConfiguration(_displayID);
  video.codec = plan->video_codec == LumenHostPlatformVideoCodecH264
    ? LumenMacCaptureCodecH264
    : LumenMacCaptureCodecHEVC;
  video.video_profile = (LumenMacCaptureVideoProfile) plan->video_profile;
  video.chroma_subsampling = (LumenMacCaptureChromaSubsampling) plan->chroma_subsampling;
  video.bit_depth = plan->bit_depth;
  video.dynamic_range = (LumenMacCaptureDynamicRange) plan->dynamic_range;
  video.color_range = (LumenMacCaptureColorRange) plan->color_range;
  video.target_frame_rate = (int32_t) plan->frames_per_second;
  video.target_video_bitrate_kbps = (int32_t) plan->bitrate_kbps;
  video.requested_width = (int32_t) plan->width;
  video.requested_height = (int32_t) plan->height;
  video.sink_request.mode.hidpi = plan->sink_hidpi;
  video.sink_request.mode.scale_explicit = plan->sink_scale_explicit;
  video.sink_request.mode.mode_is_logical = plan->sink_mode_is_logical;
  video.sink_request.mode.scale_percent = plan->sink_scale_percent;
  video.sink_request.capability.gamut = plan->sink_gamut;
  video.sink_request.capability.transfer = plan->sink_transfer;
  video.sink_request.capability.current_edr_headroom = plan->sink_current_edr_headroom;
  video.sink_request.capability.potential_edr_headroom = plan->sink_potential_edr_headroom;
  video.sink_request.capability.current_peak_luminance_nits = plan->sink_current_peak_luminance_nits;
  video.sink_request.capability.potential_peak_luminance_nits = plan->sink_potential_peak_luminance_nits;
  video.sink_request.capability.supports_frame_gated_hdr = plan->sink_supports_frame_gated_hdr;
  video.sink_request.capability.supports_hdr_tile_overlay = plan->sink_supports_hdr_tile_overlay;
  video.sink_request.capability.supports_per_frame_hdr_metadata = plan->sink_supports_per_frame_hdr_metadata;
  video.sink_request.dynamic_range_transport =
    (LumenMacDynamicRangeTransport) plan->negotiated_dynamic_range_transport;
  video.effective_display_state.gamut = plan->sink_gamut;
  video.effective_display_state.transfer = plan->sink_transfer;

  LumenMacBridgeAudioCaptureConfiguration audio =
    LumenMacBridgeControllerMakeSystemOutputAudioConfiguration(_displayID);
  audio.sample_rate = 48000;
  audio.channel_count = plan->audio_channels;
  audio.frame_size = LumenWorkerAudioFrameCount;

  char error[1024] = {0};
  LumenMacBridgeCapturePairStartStatus captureStatus =
    LumenMacBridgeControllerStartCapturePair(_bridge, video, audio, error, sizeof(error));
  if (captureStatus != LumenMacBridgeCapturePairStartStatusReady) {
    fprintf(stderr, "Lumen capture startup failed status=%d: %s\n", captureStatus, error);
    (void) [self stopSessionLocked];
    os_unfair_lock_unlock(&_lock);
    if (captureStatus == LumenMacBridgeCapturePairStartStatusVideoFailed) {
      return LumenHostPlatformStartSessionStatusVideoCaptureFailed;
    }
    if (captureStatus == LumenMacBridgeCapturePairStartStatusAudioFailed) {
      return LumenHostPlatformStartSessionStatusAudioCaptureFailed;
    }
    return LumenHostPlatformStartSessionStatusInvalidConfiguration;
  }
  fprintf(stderr, "Lumen platform session stage=capture-pair-ready display-id=%u\n", _displayID);

  if (plan->virtual_display) {
    NSError *activationError = nil;
    if (![LumenMacWorkspaceSessionFacade.shared
          activateSessionSyncWithDisplayKey:_workspaceKey
          error:&activationError]) {
      fprintf(
        stderr,
        "Lumen workspace activation failed after capture readiness: %s\n",
        activationError.localizedDescription.UTF8String ?: "unknown error"
      );
      (void) [self stopSessionLocked];
      os_unfair_lock_unlock(&_lock);
      return LumenHostPlatformStartSessionStatusInvalidConfiguration;
    }
    fprintf(stderr, "Lumen platform session stage=workspace-active display-id=%u\n", _displayID);
  } else {
    fprintf(stderr, "Lumen platform session stage=workspace-bypassed display-id=%u\n", _displayID);
  }

  os_unfair_lock_unlock(&_lock);
  return LumenHostPlatformStartSessionStatusReady;
}

- (int32_t)stopSessionLocked {
  int32_t status = 0;
  if (_bridge) {
    LumenMacBridgeControllerStopAudioCapture(_bridge);
    LumenMacBridgeControllerStopCapture(_bridge);
  }
  if (_workspaceKey) {
    NSError *error = nil;
    BOOL stopped = [LumenMacWorkspaceSessionFacade.shared
      stopSessionSyncWithDisplayKey:_workspaceKey
      error:&error];
    if (!stopped) {
      fprintf(
        stderr,
        "Lumen workspace cleanup failed display-key=%s: %s\n",
        _workspaceKey.UTF8String ?: "unknown",
        error.localizedDescription.UTF8String ?: "workspace session was not found"
      );
      status = -1;
    }
    _workspaceKey = nil;
  }
  if (_opus) {
    opus_multistream_encoder_destroy(_opus);
    _opus = NULL;
  }
  _displayID = 0;
  _pendingVideo = nil;
  _pendingAudio = nil;
  [_pcm setLength:0];
  _hasAudioTimestamp = NO;
  _audioChannels = 0;
  return status;
}

- (int32_t)stopSession {
  os_unfair_lock_lock(&_lock);
  int32_t status = [self stopSessionLocked];
  os_unfair_lock_unlock(&_lock);
  return status;
}

- (int32_t)handleControlEvent:(const LumenHostPlatformControlEvent *)event {
  if (!event) {
    return -1;
  }
  switch (event->kind) {
    case LumenHostPlatformControlEventKindRequestIdrFrame:
    case LumenHostPlatformControlEventKindInvalidateReferenceFrames:
      LumenMacBridgeRequestImmediateCaptureKeyFrame();
      return 0;
    case LumenHostPlatformControlEventKindResetInput:
      return 0;
  }
  return -1;
}

- (int32_t)pollVideo:(uint8_t *)destination
            capacity:(size_t)capacity
               frame:(LumenHostPlatformEncodedVideoFrame *)frame {
  if (!frame) {
    return LumenHostPlatformPollStatusError;
  }
  os_unfair_lock_lock(&_lock);
  if (!_pendingVideo) {
    CMSampleBufferRef sampleBuffer = NULL;
    LumenMacEncodedCaptureFrameRecord record =
      LumenMacBridgeControllerPopNextForwardedFrame(_bridge, &sampleBuffer);
    if (record.has_value && sampleBuffer) {
      _pendingVideo = LumenWorkerCopyAnnexBFrame(
        sampleBuffer,
        record.codec,
        record.is_key_frame
      );
      _pendingVideoTimestamp = LumenWorkerVideoTimestamp(sampleBuffer);
      _pendingVideoKeyFrame = record.is_key_frame;
      CFRelease(sampleBuffer);
      if (!_pendingVideo) {
        os_unfair_lock_unlock(&_lock);
        return LumenHostPlatformPollStatusError;
      }
    }
  }
  if (!_pendingVideo) {
    os_unfair_lock_unlock(&_lock);
    return LumenHostPlatformPollStatusEmpty;
  }

  frame->payload_size = _pendingVideo.length;
  frame->presentation_time_90khz = _pendingVideoTimestamp;
  frame->key_frame = _pendingVideoKeyFrame;
  if (!destination || capacity < _pendingVideo.length) {
    os_unfair_lock_unlock(&_lock);
    return LumenHostPlatformPollStatusBufferTooSmall;
  }
  memcpy(destination, _pendingVideo.bytes, _pendingVideo.length);
  _pendingVideo = nil;
  os_unfair_lock_unlock(&_lock);
  return LumenHostPlatformPollStatusReady;
}

- (BOOL)fillPendingAudio {
  if (_pendingAudio || !_opus || _audioChannels == 0) {
    return _pendingAudio != nil;
  }
  const size_t packetPCMBytes =
    (size_t) LumenWorkerAudioFrameCount * (size_t) _audioChannels * sizeof(float);
  for (int attempt = 0; attempt < 8 && _pcm.length < packetPCMBytes; ++attempt) {
    size_t copied = 0;
    LumenMacBridgeAudioCaptureFrameRecord record =
      LumenMacBridgeControllerPopNextForwardedAudioFrame(
        _bridge,
        _audioScratch.mutableBytes,
        _audioScratch.length,
        &copied
      );
    if (!record.has_value) {
      break;
    }
    if (record.sample_rate != 48000 || record.channel_count != _audioChannels ||
        copied != record.pcm_byte_count || copied > _audioScratch.length) {
      [_pcm setLength:0];
      _hasAudioTimestamp = NO;
      continue;
    }
    if (!_hasAudioTimestamp) {
      _nextAudioTimestamp = LumenWorkerAudioTimestamp(record.host_time_nanoseconds);
      _hasAudioTimestamp = YES;
    }
    [_pcm appendBytes:_audioScratch.bytes length:copied];
  }
  if (_pcm.length < packetPCMBytes || !_hasAudioTimestamp) {
    return NO;
  }

  unsigned char encoded[65536];
  int length = opus_multistream_encode_float(
    _opus,
    (const float *) _pcm.bytes,
    LumenWorkerAudioFrameCount,
    encoded,
    (opus_int32) sizeof(encoded)
  );
  if (length < 0) {
    [_pcm setLength:0];
    _hasAudioTimestamp = NO;
    return NO;
  }
  _pendingAudio = [NSData dataWithBytes:encoded length:(NSUInteger) length];
  _pendingAudioTimestamp = _nextAudioTimestamp;
  _nextAudioTimestamp += LumenWorkerAudioFrameCount;
  [_pcm replaceBytesInRange:NSMakeRange(0, packetPCMBytes) withBytes:NULL length:0];
  if (_pcm.length == 0) {
    _hasAudioTimestamp = NO;
  }
  return YES;
}

- (int32_t)pollAudio:(uint8_t *)destination
            capacity:(size_t)capacity
              packet:(LumenHostPlatformEncodedAudioPacket *)packet {
  if (!packet) {
    return LumenHostPlatformPollStatusError;
  }
  os_unfair_lock_lock(&_lock);
  if (![self fillPendingAudio]) {
    os_unfair_lock_unlock(&_lock);
    return LumenHostPlatformPollStatusEmpty;
  }
  packet->payload_size = _pendingAudio.length;
  packet->presentation_time_48khz = _pendingAudioTimestamp;
  packet->duration_frames = LumenWorkerAudioFrameCount;
  if (!destination || capacity < _pendingAudio.length) {
    os_unfair_lock_unlock(&_lock);
    return LumenHostPlatformPollStatusBufferTooSmall;
  }
  memcpy(destination, _pendingAudio.bytes, _pendingAudio.length);
  _pendingAudio = nil;
  os_unfair_lock_unlock(&_lock);
  return LumenHostPlatformPollStatusReady;
}

@end

static int32_t LumenWorkerStartSession(
  void *context,
  const LumenHostPlatformSessionPlan *plan
) {
  return [(__bridge LumenHostWorkerPlatform *) context startSession:plan];
}

static int32_t LumenWorkerStopSession(void *context) {
  return [(__bridge LumenHostWorkerPlatform *) context stopSession];
}

static int32_t LumenWorkerPollVideo(
  void *context,
  uint8_t *destination,
  size_t capacity,
  LumenHostPlatformEncodedVideoFrame *frame
) {
  return [(__bridge LumenHostWorkerPlatform *) context
    pollVideo:destination
    capacity:capacity
    frame:frame];
}

static int32_t LumenWorkerPollAudio(
  void *context,
  uint8_t *destination,
  size_t capacity,
  LumenHostPlatformEncodedAudioPacket *packet
) {
  return [(__bridge LumenHostWorkerPlatform *) context
    pollAudio:destination
    capacity:capacity
    packet:packet];
}

static int32_t LumenWorkerHandleControlEvent(
  void *context,
  const LumenHostPlatformControlEvent *event
) {
  return [(__bridge LumenHostWorkerPlatform *) context
    handleControlEvent:event];
}

static int32_t LumenWorkerPollControlFeedback(
  void *context,
  LumenHostPlatformControlFeedback *feedback
) {
  (void) context;
  return feedback ? LumenHostPlatformPollStatusEmpty : LumenHostPlatformPollStatusError;
}

static int32_t LumenWorkerPublishRuntimeEvent(
  void *context,
  const LumenHostPlatformRuntimeEvent *event
) {
  (void) context;
  if (!event) {
    return -1;
  }
  NSString *message = event->message
    ? [NSString stringWithUTF8String:event->message]
    : nil;
  if (event->disposition == LumenHostPlatformRuntimeEventDispositionRaised && !message) {
    return -1;
  }
  NSDictionary *userInfo = @{
    @"identifier": [NSString stringWithFormat:@"runtime-event-%u", (unsigned) event->code],
    @"disposition": @((NSUInteger) event->disposition),
    @"severity": @((NSUInteger) event->severity),
    @"code": @((NSUInteger) event->code),
    @"body": message ?: @"",
    @"launchPath": @"/diagnostics",
  };
  [[NSDistributedNotificationCenter defaultCenter]
    postNotificationName:LumenRuntimeEventNotification
    object:nil
    userInfo:userInfo
    deliverImmediately:YES];
  return 0;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    LumenHostWorkerPlatform *platform = [[LumenHostWorkerPlatform alloc] init];
    LumenHostPlatformCallbacks callbacks = {
      .context = (__bridge void *) platform,
      .start_session = LumenWorkerStartSession,
      .stop_session = LumenWorkerStopSession,
      .poll_encoded_video = LumenWorkerPollVideo,
      .poll_encoded_audio = LumenWorkerPollAudio,
      .handle_control_event = LumenWorkerHandleControlEvent,
      .poll_control_feedback = LumenWorkerPollControlFeedback,
      .publish_runtime_event = LumenWorkerPublishRuntimeEvent,
    };
    return lumen_host_run_with_platform(argc, argv, &callbacks);
  }
}
