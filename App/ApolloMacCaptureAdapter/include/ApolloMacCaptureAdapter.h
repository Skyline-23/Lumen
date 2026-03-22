#ifndef APOLLO_MAC_CAPTURE_ADAPTER_H
#define APOLLO_MAC_CAPTURE_ADAPTER_H

#import <ApolloMacBridge/ApolloMacBridge.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ApolloMacCaptureAdapterStatus : NSObject

@property(nonatomic, readonly, copy) NSString *coreVersion;
@property(nonatomic, readonly, copy) NSString *runtimeDescription;
@property(nonatomic, readonly, copy) NSString *integrationStatus;
@property(nonatomic, readonly) BOOL forwardingPumpRunning;
@property(nonatomic, readonly) NSUInteger forwardedFrameCallbackCount;
@property(nonatomic, readonly) NSUInteger forwardedEventCallbackCount;
@property(nonatomic, readonly) ApolloCoreEncodedCaptureIngressSnapshot coreForwardingSnapshot;

- (instancetype)initWithCoreVersion:(NSString *)coreVersion
                             runtimeDescription:(NSString *)runtimeDescription
                              integrationStatus:(NSString *)integrationStatus
                           forwardingPumpRunning:(BOOL)forwardingPumpRunning
                      forwardedFrameCallbackCount:(NSUInteger)forwardedFrameCallbackCount
                      forwardedEventCallbackCount:(NSUInteger)forwardedEventCallbackCount
                           coreForwardingSnapshot:(ApolloCoreEncodedCaptureIngressSnapshot)coreForwardingSnapshot NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface ApolloMacCaptureAdapter : NSObject

- (ApolloMacBridgeCaptureConfiguration)makePanelNativeConfigurationForDisplayID:(uint32_t)displayID;
- (void)configureCoreForwardingWithFrameCapacity:(NSUInteger)frameCapacity
                                   eventCapacity:(NSUInteger)eventCapacity;
- (BOOL)startMacDisplayKitCaptureWithConfiguration:(ApolloMacBridgeCaptureConfiguration)configuration
                                             error:(NSError * _Nullable * _Nullable)error;
- (void)stopMacDisplayKitCapture;
- (BOOL)startForwardingPumpWithError:(NSError * _Nullable * _Nullable)error;
- (void)stopForwardingPump;
- (ApolloMacCaptureAdapterStatus *)copyStatusSnapshot;

@end

NS_ASSUME_NONNULL_END

#endif
