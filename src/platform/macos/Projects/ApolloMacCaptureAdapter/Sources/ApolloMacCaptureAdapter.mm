#import <ApolloMacCaptureAdapter/ApolloMacCaptureAdapter.h>

#import <atomic>
#import <chrono>
#import <cstring>

@class ApolloMacCaptureAdapter;

@interface ApolloMacCaptureAdapter ()
- (void)postStatusDidChangeNotification;
@end

namespace {
  struct ApolloMacCaptureAdapterCallbackState {
    __unsafe_unretained ApolloMacCaptureAdapter *adapter;
    std::atomic<uint64_t> frame_callback_count {0};
    std::atomic<uint64_t> event_callback_count {0};
    std::atomic<uint64_t> audio_frame_callback_count {0};
    std::atomic<uint64_t> audio_event_callback_count {0};
    std::atomic<uint64_t> last_status_notification_nanoseconds {0};
  };

  constexpr uint64_t status_notification_interval_nanoseconds = 100000000ULL;

  void maybe_post_status_notification(ApolloMacCaptureAdapterCallbackState *state) {
    if (!state || !state->adapter) {
      return;
    }

    const auto now = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()
      ).count()
    );
    auto expected = state->last_status_notification_nanoseconds.load(std::memory_order_relaxed);
    if (expected != 0 && now - expected < status_notification_interval_nanoseconds) {
      return;
    }

    if (!state->last_status_notification_nanoseconds.compare_exchange_strong(
          expected,
          now,
          std::memory_order_relaxed,
          std::memory_order_relaxed
        )) {
      return;
    }

    ApolloMacCaptureAdapter *adapter = state->adapter;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (adapter) {
        [adapter postStatusDidChangeNotification];
      }
    });
  }

  void handle_encoded_frame(
    void *context,
    ApolloCoreEncodedCaptureFrameRecord,
    CMSampleBufferRef
  ) {
    auto *state = static_cast<ApolloMacCaptureAdapterCallbackState *>(context);
    state->frame_callback_count.fetch_add(1, std::memory_order_relaxed);
    maybe_post_status_notification(state);
  }

  void handle_capture_event(
    void *context,
    ApolloCoreEncodedCaptureEventRecord,
    const char *
  ) {
    auto *state = static_cast<ApolloMacCaptureAdapterCallbackState *>(context);
    state->event_callback_count.fetch_add(1, std::memory_order_relaxed);
    maybe_post_status_notification(state);
  }

  void handle_audio_frame(
    void *context,
    ApolloMacBridgeAudioCaptureFrameRecord,
    const void *,
    size_t
  ) {
    auto *state = static_cast<ApolloMacCaptureAdapterCallbackState *>(context);
    state->audio_frame_callback_count.fetch_add(1, std::memory_order_relaxed);
    maybe_post_status_notification(state);
  }

  void handle_audio_capture_event(
    void *context,
    ApolloMacBridgeAudioCaptureEventRecord,
    const char *
  ) {
    auto *state = static_cast<ApolloMacCaptureAdapterCallbackState *>(context);
    state->audio_event_callback_count.fetch_add(1, std::memory_order_relaxed);
    maybe_post_status_notification(state);
  }

  NSString *string_from_c_buffer(const char *buffer) {
    if (!buffer || buffer[0] == '\0') {
      return @"";
    }

    return [NSString stringWithUTF8String:buffer] ?: @"";
  }

  NSError *adapter_error(NSString *description) {
    return [NSError errorWithDomain:@"ApolloMacCaptureAdapter"
                               code:1
                           userInfo:@ {
                             NSLocalizedDescriptionKey: description ?: @"ApolloMacCaptureAdapter failed."
                           }];
  }
}

NSNotificationName const ApolloMacCaptureAdapterStatusDidChangeNotification =
  @"ApolloMacCaptureAdapterStatusDidChangeNotification";
static NSNotificationName const ApolloBridgeRuntimeStatusDidChangeNotification =
  @"ApolloBridgeRuntimeStatusDidChange";

@implementation ApolloMacCaptureAdapterStatus

- (instancetype)initWithCoreVersion:(NSString *)coreVersion
                             runtimeDescription:(NSString *)runtimeDescription
                              integrationStatus:(NSString *)integrationStatus
                           captureSessionRunning:(BOOL)captureSessionRunning
                      audioCaptureSessionRunning:(BOOL)audioCaptureSessionRunning
             automaticCaptureOrchestrationRunning:(BOOL)automaticCaptureOrchestrationRunning
                           forwardingPumpRunning:(BOOL)forwardingPumpRunning
                      forwardedFrameCallbackCount:(NSUInteger)forwardedFrameCallbackCount
                      forwardedEventCallbackCount:(NSUInteger)forwardedEventCallbackCount
                 forwardedAudioFrameCallbackCount:(NSUInteger)forwardedAudioFrameCallbackCount
                 forwardedAudioEventCallbackCount:(NSUInteger)forwardedAudioEventCallbackCount
                           coreForwardingSnapshot:(ApolloCoreEncodedCaptureIngressSnapshot)coreForwardingSnapshot
                        audioForwardingSnapshot:(ApolloMacBridgeAudioForwardingSnapshot)audioForwardingSnapshot {
  self = [super init];
  if (!self) {
    return nil;
  }

  _coreVersion = [coreVersion copy];
  _runtimeDescription = [runtimeDescription copy];
  _integrationStatus = [integrationStatus copy];
  _captureSessionRunning = captureSessionRunning;
  _audioCaptureSessionRunning = audioCaptureSessionRunning;
  _automaticCaptureOrchestrationRunning = automaticCaptureOrchestrationRunning;
  _forwardingPumpRunning = forwardingPumpRunning;
  _forwardedFrameCallbackCount = forwardedFrameCallbackCount;
  _forwardedEventCallbackCount = forwardedEventCallbackCount;
  _forwardedAudioFrameCallbackCount = forwardedAudioFrameCallbackCount;
  _forwardedAudioEventCallbackCount = forwardedAudioEventCallbackCount;
  _coreForwardingSnapshot = coreForwardingSnapshot;
  _audioForwardingSnapshot = audioForwardingSnapshot;
  return self;
}

@end

@implementation ApolloMacCaptureAdapter {
  ApolloMacBridgeController *_controller;
  ApolloMacCaptureAdapterCallbackState _callback_state;
  BOOL _forwarding_pump_running;
  id _bridge_status_observer;
}

- (instancetype)init {
  self = [super init];
  if (!self) {
    return nil;
  }

  _controller = ApolloMacBridgeControllerCreate();
  _callback_state.adapter = self;
  __weak typeof(self) weak_self = self;
  _bridge_status_observer = [[NSNotificationCenter defaultCenter]
    addObserverForName:ApolloBridgeRuntimeStatusDidChangeNotification
                object:nil
                 queue:[NSOperationQueue mainQueue]
            usingBlock:^(__unused NSNotification *notification) {
              [weak_self postStatusDidChangeNotification];
            }];
  return self;
}

- (void)dealloc {
  if (_bridge_status_observer) {
    [[NSNotificationCenter defaultCenter] removeObserver:_bridge_status_observer];
    _bridge_status_observer = nil;
  }
  if (_controller) {
    ApolloMacBridgeControllerStopApolloCoreCaptureAutomation(_controller);
    ApolloMacBridgeControllerStopCoreForwardingPump(_controller);
    ApolloMacBridgeControllerStopMacDisplayKitAudioCapture(_controller);
    ApolloMacBridgeControllerStopMacDisplayKitCapture(_controller);
    ApolloMacBridgeControllerDestroy(_controller);
    _controller = nullptr;
  }
}

- (ApolloMacBridgeCaptureConfiguration)makePanelNativeConfigurationForDisplayID:(uint32_t)displayID {
  return ApolloMacBridgeControllerMakePanelNativeConfiguration(displayID);
}

- (ApolloMacBridgeAudioCaptureConfiguration)makeDefaultMicrophoneAudioConfiguration {
  return ApolloMacBridgeControllerMakeDefaultMicrophoneAudioConfiguration();
}

- (ApolloMacBridgeAudioCaptureConfiguration)makeSystemOutputAudioConfigurationForDisplayID:(uint32_t)displayID {
  return ApolloMacBridgeControllerMakeSystemOutputAudioConfiguration(displayID);
}

- (BOOL)startManagedCaptureSessionWithConfiguration:(ApolloMacBridgeCaptureConfiguration)configuration
                                      frameCapacity:(NSUInteger)frameCapacity
                                      eventCapacity:(NSUInteger)eventCapacity
                                              error:(NSError * _Nullable __autoreleasing *)error {
  [self stopManagedCaptureSession];
  [self configureCoreForwardingWithFrameCapacity:frameCapacity eventCapacity:eventCapacity];

  if (![self startMacDisplayKitCaptureWithConfiguration:configuration error:error]) {
    return NO;
  }

  if (![self startForwardingPumpWithError:error]) {
    [self stopMacDisplayKitCapture];
    return NO;
  }

  return YES;
}

- (void)stopManagedCaptureSession {
  [self stopForwardingPump];
  [self stopMacDisplayKitCapture];
}

- (BOOL)startManagedAudioCaptureSessionWithConfiguration:(ApolloMacBridgeAudioCaptureConfiguration)configuration
                                           frameCapacity:(NSUInteger)frameCapacity
                                           eventCapacity:(NSUInteger)eventCapacity
                                                   error:(NSError * _Nullable __autoreleasing *)error {
  [self stopManagedAudioCaptureSession];
  [self configureAudioForwardingWithFrameCapacity:frameCapacity eventCapacity:eventCapacity];

  if (![self startMacDisplayKitAudioCaptureWithConfiguration:configuration error:error]) {
    return NO;
  }

  if (!_forwarding_pump_running && ![self startForwardingPumpWithError:error]) {
    [self stopMacDisplayKitAudioCapture];
    return NO;
  }

  return YES;
}

- (void)stopManagedAudioCaptureSession {
  [self stopMacDisplayKitAudioCapture];
}

- (void)configureCoreForwardingWithFrameCapacity:(NSUInteger)frameCapacity
                                   eventCapacity:(NSUInteger)eventCapacity {
  ApolloMacBridgeControllerConfigureCoreForwarding(_controller, frameCapacity, eventCapacity);
}

- (void)configureAudioForwardingWithFrameCapacity:(NSUInteger)frameCapacity
                                    eventCapacity:(NSUInteger)eventCapacity {
  ApolloMacBridgeControllerConfigureAudioForwarding(_controller, frameCapacity, eventCapacity);
}

- (BOOL)startMacDisplayKitCaptureWithConfiguration:(ApolloMacBridgeCaptureConfiguration)configuration
                                             error:(NSError * _Nullable __autoreleasing *)error {
  char error_buffer[512] = {};
  BOOL started = ApolloMacBridgeControllerStartMacDisplayKitCapture(
    _controller,
    configuration,
    error_buffer,
    sizeof(error_buffer)
  );
  if (!started) {
    if (error) {
      *error = adapter_error(string_from_c_buffer(error_buffer));
    }
    return NO;
  }

  [self postStatusDidChangeNotification];
  return YES;
}

- (void)stopMacDisplayKitCapture {
  ApolloMacBridgeControllerStopMacDisplayKitCapture(_controller);
  [self postStatusDidChangeNotification];
}

- (BOOL)startMacDisplayKitAudioCaptureWithConfiguration:(ApolloMacBridgeAudioCaptureConfiguration)configuration
                                                  error:(NSError * _Nullable __autoreleasing *)error {
  char error_buffer[512] = {};
  BOOL started = ApolloMacBridgeControllerStartMacDisplayKitAudioCapture(
    _controller,
    configuration,
    error_buffer,
    sizeof(error_buffer)
  );
  if (!started) {
    if (error) {
      *error = adapter_error(string_from_c_buffer(error_buffer));
    }
    return NO;
  }

  [self postStatusDidChangeNotification];
  return YES;
}

- (void)stopMacDisplayKitAudioCapture {
  ApolloMacBridgeControllerStopMacDisplayKitAudioCapture(_controller);
  [self postStatusDidChangeNotification];
}

- (void)startAutomaticApolloCoreCaptureOrchestration {
  ApolloMacBridgeControllerStartApolloCoreCaptureAutomation(_controller);
  [self postStatusDidChangeNotification];
}

- (void)stopAutomaticApolloCoreCaptureOrchestration {
  ApolloMacBridgeControllerStopApolloCoreCaptureAutomation(_controller);
  [self postStatusDidChangeNotification];
}

- (BOOL)startForwardingPumpWithError:(NSError * _Nullable __autoreleasing *)error {
  ApolloMacBridgeForwardingCallbacks callbacks {};
  callbacks.context = &_callback_state;
  callbacks.encoded_frame_handler = handle_encoded_frame;
  callbacks.capture_event_handler = handle_capture_event;
  callbacks.audio_frame_handler = handle_audio_frame;
  callbacks.audio_capture_event_handler = handle_audio_capture_event;

  char error_buffer[512] = {};
  BOOL started = ApolloMacBridgeControllerStartCoreForwardingPump(
    _controller,
    callbacks,
    1,
    error_buffer,
    sizeof(error_buffer)
  );
  if (!started) {
    if (error) {
      *error = adapter_error(string_from_c_buffer(error_buffer));
    }
    return NO;
  }

  _forwarding_pump_running = YES;
  [self postStatusDidChangeNotification];
  return YES;
}

- (void)stopForwardingPump {
  ApolloMacBridgeControllerStopCoreForwardingPump(_controller);
  _forwarding_pump_running = NO;
  [self postStatusDidChangeNotification];
}

- (ApolloMacCaptureAdapterStatus *)copyStatusSnapshot {
  ApolloMacBridgeStatusSnapshot bridge_status = ApolloMacBridgeControllerCopyStatusSnapshot(_controller);
  ApolloCoreEncodedCaptureIngressSnapshot core_snapshot =
    ApolloMacBridgeControllerCopyCoreForwardingSnapshot(_controller);
  ApolloMacBridgeAudioForwardingSnapshot audio_snapshot =
    ApolloMacBridgeControllerCopyAudioForwardingSnapshot(_controller);
  return [[ApolloMacCaptureAdapterStatus alloc]
               initWithCoreVersion:string_from_c_buffer(bridge_status.core_version)
                 runtimeDescription:string_from_c_buffer(bridge_status.runtime_description)
                  integrationStatus:string_from_c_buffer(bridge_status.integration_status)
              captureSessionRunning:bridge_status.capture_session_running
          audioCaptureSessionRunning:bridge_status.audio_capture_session_running
    automaticCaptureOrchestrationRunning:bridge_status.automatic_capture_orchestration_running
               forwardingPumpRunning:_forwarding_pump_running
          forwardedFrameCallbackCount:static_cast<NSUInteger>(
            _callback_state.frame_callback_count.load(std::memory_order_relaxed)
          )
          forwardedEventCallbackCount:static_cast<NSUInteger>(
            _callback_state.event_callback_count.load(std::memory_order_relaxed)
          )
    forwardedAudioFrameCallbackCount:static_cast<NSUInteger>(
      _callback_state.audio_frame_callback_count.load(std::memory_order_relaxed)
    )
    forwardedAudioEventCallbackCount:static_cast<NSUInteger>(
      _callback_state.audio_event_callback_count.load(std::memory_order_relaxed)
    )
               coreForwardingSnapshot:core_snapshot
                        audioForwardingSnapshot:audio_snapshot];
}

- (void)postStatusDidChangeNotification {
  [[NSNotificationCenter defaultCenter]
    postNotificationName:ApolloMacCaptureAdapterStatusDidChangeNotification
                  object:self];
}

@end
