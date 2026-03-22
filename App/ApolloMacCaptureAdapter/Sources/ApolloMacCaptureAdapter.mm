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
  _forwardingPumpRunning = forwardingPumpRunning;
  _forwardedFrameCallbackCount = forwardedFrameCallbackCount;
  _forwardedEventCallbackCount = forwardedEventCallbackCount;
  _coreForwardingSnapshot = coreForwardingSnapshot;
  return self;
}

@end

@implementation ApolloMacCaptureAdapter {
  apollo::macbridge::Controller _controller;
  ApolloMacCaptureAdapterCallbackState _callback_state;
  BOOL _forwarding_pump_running;
}

- (ApolloMacBridgeCaptureConfiguration)makePanelNativeConfigurationForDisplayID:(uint32_t)displayID {
  return apollo::macbridge::Controller::make_panel_native_configuration(displayID);
}

- (void)configureCoreForwardingWithFrameCapacity:(NSUInteger)frameCapacity
                                   eventCapacity:(NSUInteger)eventCapacity {
  _controller.configure_core_forwarding(frameCapacity, eventCapacity);
}

- (BOOL)startMacDisplayKitCaptureWithConfiguration:(ApolloMacBridgeCaptureConfiguration)configuration
                                             error:(NSError * _Nullable __autoreleasing *)error {
  auto result = _controller.start_mac_display_kit_capture(configuration);
  if (!result.started) {
    if (error) {
      *error = adapter_error(string_from_c_buffer(result.error_message.c_str()));
    }
    return NO;
  }

  return YES;
}

- (void)stopMacDisplayKitCapture {
  _controller.stop_mac_display_kit_capture();
}

- (BOOL)startForwardingPumpWithError:(NSError * _Nullable __autoreleasing *)error {
  ApolloMacBridgeForwardingCallbacks callbacks {};
  callbacks.context = &_callback_state;
  callbacks.encoded_frame_handler = handle_encoded_frame;
  callbacks.capture_event_handler = handle_capture_event;

  auto result = _controller.start_core_forwarding_pump(callbacks);
  if (!result.started) {
    if (error) {
      *error = adapter_error(string_from_c_buffer(result.error_message.c_str()));
    }
    return NO;
  }

  _forwarding_pump_running = YES;
  return YES;
}

- (void)stopForwardingPump {
  _controller.stop_core_forwarding_pump();
  _forwarding_pump_running = NO;
}

- (ApolloMacCaptureAdapterStatus *)copyStatusSnapshot {
  ApolloMacBridgeStatusSnapshot bridge_status = _controller.copy_status_snapshot();
  ApolloCoreEncodedCaptureIngressSnapshot core_snapshot = _controller.copy_core_forwarding_snapshot();
  return [[ApolloMacCaptureAdapterStatus alloc]
               initWithCoreVersion:string_from_c_buffer(bridge_status.core_version)
                 runtimeDescription:string_from_c_buffer(bridge_status.runtime_description)
                  integrationStatus:string_from_c_buffer(bridge_status.integration_status)
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
