#ifndef APOLLO_MAC_CAPTURE_ADAPTER_H
#define APOLLO_MAC_CAPTURE_ADAPTER_H

#import <ApolloMacBridge/ApolloMacBridge.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const ApolloMacCaptureAdapterStatusDidChangeNotification;

@interface ApolloMacCaptureAdapterStatus : NSObject

@property(nonatomic, readonly, copy) NSString *coreVersion;
@property(nonatomic, readonly, copy) NSString *runtimeDescription;
@property(nonatomic, readonly, copy) NSString *integrationStatus;
@property(nonatomic, readonly) BOOL captureSessionRunning;
@property(nonatomic, readonly) BOOL audioCaptureSessionRunning;
@property(nonatomic, readonly) BOOL automaticCaptureOrchestrationRunning;
@property(nonatomic, readonly) BOOL forwardingPumpRunning;
@property(nonatomic, readonly) NSUInteger forwardedFrameCallbackCount;
@property(nonatomic, readonly) NSUInteger forwardedEventCallbackCount;
@property(nonatomic, readonly) NSUInteger forwardedAudioFrameCallbackCount;
@property(nonatomic, readonly) NSUInteger forwardedAudioEventCallbackCount;
@property(nonatomic, readonly) ApolloCoreEncodedCaptureIngressSnapshot coreForwardingSnapshot;
@property(nonatomic, readonly) ApolloMacBridgeAudioForwardingSnapshot audioForwardingSnapshot;

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
                        audioForwardingSnapshot:(ApolloMacBridgeAudioForwardingSnapshot)audioForwardingSnapshot NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface ApolloMacCaptureAdapter : NSObject

- (ApolloMacBridgeCaptureConfiguration)makePanelNativeConfigurationForDisplayID:(uint32_t)displayID;
- (ApolloMacBridgeAudioCaptureConfiguration)makeDefaultMicrophoneAudioConfiguration;
- (ApolloMacBridgeAudioCaptureConfiguration)makeSystemOutputAudioConfigurationForDisplayID:(uint32_t)displayID;
- (BOOL)startManagedCaptureSessionWithConfiguration:(ApolloMacBridgeCaptureConfiguration)configuration
                                      frameCapacity:(NSUInteger)frameCapacity
                                      eventCapacity:(NSUInteger)eventCapacity
                                              error:(NSError * _Nullable * _Nullable)error;
- (void)stopManagedCaptureSession;
- (BOOL)startManagedAudioCaptureSessionWithConfiguration:(ApolloMacBridgeAudioCaptureConfiguration)configuration
                                           frameCapacity:(NSUInteger)frameCapacity
                                           eventCapacity:(NSUInteger)eventCapacity
                                                   error:(NSError * _Nullable * _Nullable)error;
- (void)stopManagedAudioCaptureSession;
- (void)configureCoreForwardingWithFrameCapacity:(NSUInteger)frameCapacity
                                   eventCapacity:(NSUInteger)eventCapacity;
- (void)configureAudioForwardingWithFrameCapacity:(NSUInteger)frameCapacity
                                    eventCapacity:(NSUInteger)eventCapacity;
- (BOOL)startMacDisplayKitCaptureWithConfiguration:(ApolloMacBridgeCaptureConfiguration)configuration
                                             error:(NSError * _Nullable * _Nullable)error;
- (void)stopMacDisplayKitCapture;
- (BOOL)startMacDisplayKitAudioCaptureWithConfiguration:(ApolloMacBridgeAudioCaptureConfiguration)configuration
                                                  error:(NSError * _Nullable * _Nullable)error;
- (void)stopMacDisplayKitAudioCapture;
- (void)startAutomaticApolloCoreCaptureOrchestration;
- (void)stopAutomaticApolloCoreCaptureOrchestration;
- (BOOL)startForwardingPumpWithError:(NSError * _Nullable * _Nullable)error;
- (void)stopForwardingPump;
- (ApolloMacCaptureAdapterStatus *)copyStatusSnapshot;

@end

NS_ASSUME_NONNULL_END

#endif
