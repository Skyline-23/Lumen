#ifndef LUMEN_HOST_RUNTIME_BRIDGE_H
#define LUMEN_HOST_RUNTIME_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LumenHostRuntimeController LumenHostRuntimeController;

#define LumenHostRuntimeDidStopNotification "LumenHostRuntimeDidStopNotification"

LumenHostRuntimeController *LumenHostRuntimeControllerCreate(void);
void LumenHostRuntimeControllerDestroy(LumenHostRuntimeController *controller);

bool LumenHostRuntimeControllerStart(
  LumenHostRuntimeController *controller,
  char *error_destination,
  size_t error_capacity
);
void LumenHostRuntimeControllerStop(LumenHostRuntimeController *controller);
bool LumenHostRuntimeControllerFactoryReset(
  LumenHostRuntimeController *controller,
  char *error_destination,
  size_t error_capacity
);
bool LumenHostRuntimeControllerIsRunning(const LumenHostRuntimeController *controller);
int32_t LumenHostRuntimeControllerCopyLastExitCode(const LumenHostRuntimeController *controller);
void LumenHostRuntimeControllerForceStopStream(LumenHostRuntimeController *controller);
void LumenHostRuntimeControllerReloadApplications(LumenHostRuntimeController *controller);

bool LumenHostRuntimeIsAccessibilityPermissionGranted(void);
void LumenHostRuntimeRequestAccessibilityPermission(void);
bool LumenHostRuntimeIsScreenCapturePermissionGranted(void);
void LumenHostRuntimeRequestScreenCapturePermission(void);

#ifdef __cplusplus
}
#endif

#endif
