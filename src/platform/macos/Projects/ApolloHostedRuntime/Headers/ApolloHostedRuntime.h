#ifndef APOLLO_HOSTED_RUNTIME_H
#define APOLLO_HOSTED_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ApolloHostedRuntimeController ApolloHostedRuntimeController;

#define ApolloHostedRuntimeDidStopNotification "ApolloHostedRuntimeDidStopNotification"

ApolloHostedRuntimeController *ApolloHostedRuntimeControllerCreate(void);
void ApolloHostedRuntimeControllerDestroy(ApolloHostedRuntimeController *controller);

bool ApolloHostedRuntimeControllerStart(
  ApolloHostedRuntimeController *controller,
  char *error_destination,
  size_t error_capacity
);

void ApolloHostedRuntimeControllerStop(ApolloHostedRuntimeController *controller);

bool ApolloHostedRuntimeControllerIsRunning(const ApolloHostedRuntimeController *controller);

int32_t ApolloHostedRuntimeControllerCopyLastExitCode(const ApolloHostedRuntimeController *controller);

void ApolloHostedRuntimeControllerForceStopStream(ApolloHostedRuntimeController *controller);
bool ApolloHostedRuntimeIsAccessibilityPermissionGranted(void);
void ApolloHostedRuntimeRequestAccessibilityPermission(void);
bool ApolloHostedRuntimeIsScreenCapturePermissionGranted(void);
void ApolloHostedRuntimeRequestScreenCapturePermission(void);

#ifdef __cplusplus
}
#endif

#endif
