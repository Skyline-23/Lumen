#import <ApolloMacCaptureAdapter/ApolloMacCaptureAdapter.h>

#import <atomic>
#import <cstring>

namespace {
  struct ApolloMacCaptureAdapterCallbackState {
    std::atomic<uint64_t> frame_callback_count {0};
    std::atomic<uint64_t> event_callback_count {0};
  };

  void handle_encoded_frame(
    void *context,
    ApolloCoreEncodedCaptureFrameRecord,
    CMSampleBufferRef
  ) {
    auto *state = static_cast<ApolloMacCaptureAdapterCallbackState *>(context);
    state->frame_callback_count.fetch_add(1, std::memory_order_relaxed);
  }

  void handle_capture_event(
    void *context,
    ApolloCoreEncodedCaptureEventRecord,
    const char *
  ) {
    auto *state = static_cast<ApolloMacCaptureAdapterCallbackState *>(context);
    state->event_callback_count.fetch_add(1, std::memory_order_relaxed);
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

@implementation ApolloMacCaptureAdapterStatus

- (instancetype)initWithCoreVersion:(NSString *)coreVersion
                             runtimeDescription:(NSString *)runtimeDescription
                              integrationStatus:(NSString *)integrationStatus
                           captureSessionRunning:(BOOL)captureSessionRunning
                           forwardingPumpRunning:(BOOL)forwardingPumpRunning
                      forwardedFrameCallbackCount:(NSUInteger)forwardedFrameCallbackCount
                      forwardedEventCallbackCount:(NSUInteger)forwardedEventCallbackCount
                           coreForwardingSnapshot:(ApolloCoreEncodedCaptureIngressSnapshot)coreForwardingSnapshot {
  self = [super init];
  if (!self) {
    return nil;
  }

  _coreVersion = [coreVersion copy];
  _runtimeDescription = [runtimeDescription copy];
  _integrationStatus = [integrationStatus copy];
  _captureSessionRunning = captureSessionRunning;
  _forwardingPumpRunning = forwardingPumpRunning;
  _forwardedFrameCallbackCount = forwardedFrameCallbackCount;
  _forwardedEventCallbackCount = forwardedEventCallbackCount;
  _coreForwardingSnapshot = coreForwardingSnapshot;
  return self;
}

@end

@implementation ApolloMacCaptureAdapter {
  ApolloMacBridgeController *_controller;
  ApolloMacCaptureAdapterCallbackState _callback_state;
  BOOL _capture_session_running;
  BOOL _forwarding_pump_running;
}

- (instancetype)init {
  self = [super init];
  if (!self) {
    return nil;
  }

  _controller = ApolloMacBridgeControllerCreate();
  return self;
}

- (void)dealloc {
  if (_controller) {
    ApolloMacBridgeControllerStopCoreForwardingPump(_controller);
    ApolloMacBridgeControllerStopMacDisplayKitCapture(_controller);
    ApolloMacBridgeControllerDestroy(_controller);
    _controller = nullptr;
  }
}

- (ApolloMacBridgeCaptureConfiguration)makePanelNativeConfigurationForDisplayID:(uint32_t)displayID {
  return ApolloMacBridgeControllerMakePanelNativeConfiguration(displayID);
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

- (void)configureCoreForwardingWithFrameCapacity:(NSUInteger)frameCapacity
                                   eventCapacity:(NSUInteger)eventCapacity {
  ApolloMacBridgeControllerConfigureCoreForwarding(_controller, frameCapacity, eventCapacity);
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
    _capture_session_running = NO;
    return NO;
  }

  _capture_session_running = YES;
  return YES;
}

- (void)stopMacDisplayKitCapture {
  ApolloMacBridgeControllerStopMacDisplayKitCapture(_controller);
  _capture_session_running = NO;
}

- (BOOL)startForwardingPumpWithError:(NSError * _Nullable __autoreleasing *)error {
  ApolloMacBridgeForwardingCallbacks callbacks {};
  callbacks.context = &_callback_state;
  callbacks.encoded_frame_handler = handle_encoded_frame;
  callbacks.capture_event_handler = handle_capture_event;

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
  return YES;
}

- (void)stopForwardingPump {
  ApolloMacBridgeControllerStopCoreForwardingPump(_controller);
  _forwarding_pump_running = NO;
}

- (ApolloMacCaptureAdapterStatus *)copyStatusSnapshot {
  ApolloMacBridgeStatusSnapshot bridge_status = ApolloMacBridgeControllerCopyStatusSnapshot(_controller);
  ApolloCoreEncodedCaptureIngressSnapshot core_snapshot =
    ApolloMacBridgeControllerCopyCoreForwardingSnapshot(_controller);
  return [[ApolloMacCaptureAdapterStatus alloc]
               initWithCoreVersion:string_from_c_buffer(bridge_status.core_version)
                 runtimeDescription:string_from_c_buffer(bridge_status.runtime_description)
                  integrationStatus:string_from_c_buffer(bridge_status.integration_status)
              captureSessionRunning:_capture_session_running
               forwardingPumpRunning:_forwarding_pump_running
          forwardedFrameCallbackCount:static_cast<NSUInteger>(
            _callback_state.frame_callback_count.load(std::memory_order_relaxed)
          )
          forwardedEventCallbackCount:static_cast<NSUInteger>(
            _callback_state.event_callback_count.load(std::memory_order_relaxed)
          )
               coreForwardingSnapshot:core_snapshot];
}

@end
