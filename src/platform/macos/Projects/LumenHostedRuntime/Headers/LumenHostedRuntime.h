#ifndef LUMEN_HOSTED_RUNTIME_H
#define LUMEN_HOSTED_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LumenHostedRuntimeController LumenHostedRuntimeController;

#define LumenHostedRuntimeDidStopNotification "LumenHostedRuntimeDidStopNotification"

LumenHostedRuntimeController *LumenHostedRuntimeControllerCreate(void);
void LumenHostedRuntimeControllerDestroy(LumenHostedRuntimeController *controller);

bool LumenHostedRuntimeControllerStart(
  LumenHostedRuntimeController *controller,
  char *error_destination,
  size_t error_capacity
);

void LumenHostedRuntimeControllerStop(LumenHostedRuntimeController *controller);

bool LumenHostedRuntimeControllerIsRunning(const LumenHostedRuntimeController *controller);

int32_t LumenHostedRuntimeControllerCopyLastExitCode(const LumenHostedRuntimeController *controller);

void LumenHostedRuntimeControllerForceStopStream(LumenHostedRuntimeController *controller);
bool LumenHostedRuntimeIsAccessibilityPermissionGranted(void);
void LumenHostedRuntimeRequestAccessibilityPermission(void);
bool LumenHostedRuntimeIsScreenCapturePermissionGranted(void);
void LumenHostedRuntimeRequestScreenCapturePermission(void);

#ifdef __cplusplus
}
#endif

#endif
