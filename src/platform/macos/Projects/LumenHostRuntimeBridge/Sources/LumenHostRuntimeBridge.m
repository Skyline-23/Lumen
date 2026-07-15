#import "LumenHostRuntimeBridge.h"

#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <LumenMacBridge/LumenMacBridge-Swift.h>

#include "lumen_engine.h"
#include <stdio.h>
#include <stdlib.h>

static NSString *const lumen_host_runtime_did_stop_notification =
  @LumenHostRuntimeDidStopNotification;

static NSString *LumenHostSupportDirectoryPath(void) {
  NSURL *supportURL = [[NSFileManager defaultManager]
    URLForDirectory:NSApplicationSupportDirectory
    inDomain:NSUserDomainMask
    appropriateForURL:nil
    create:YES
    error:nil];
  NSURL *lumenURL = [supportURL URLByAppendingPathComponent:@"Lumen" isDirectory:YES];
  [[NSFileManager defaultManager]
    createDirectoryAtURL:lumenURL
    withIntermediateDirectories:YES
    attributes:nil
    error:nil];
  return lumenURL.path ?: @"/tmp/Lumen";
}

static NSString *LumenHostWorkerPath(void) {
  return [NSBundle.mainBundle pathForAuxiliaryExecutable:@"LumenHostWorker"] ?: @"";
}

static NSString *LumenHostBootstrapLogPath(void) {
  return [LumenHostSupportDirectoryPath()
    stringByAppendingPathComponent:@"lumen-bootstrap.log"];
}

static NSArray<NSString *> *LumenHostRuntimeArguments(void) {
  LumenNativeRuntimeSettingsSnapshot *settings =
    [[LumenNativeRuntimeSettingsSnapshot alloc] init];
  return settings.runtimeArguments;
}

static void LumenHostPostRuntimeStatus(
  bool willRestart,
  int32_t exitCode,
  uint32_t restartAttempt,
  double restartDelaySeconds
) {
  NSDictionary *userInfo = @{
    @"willRestart": @(willRestart),
    @"exitCode": @(exitCode),
    @"attempt": @(restartAttempt),
    @"delaySeconds": @(restartDelaySeconds),
  };
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter]
      postNotificationName:lumen_host_runtime_did_stop_notification
      object:nil
      userInfo:userInfo];
  });
}

static void LumenHostHandleRuntimeStatus(
  bool willRestart,
  int32_t exitCode,
  uint32_t restartAttempt,
  double restartDelaySeconds,
  void *context
) {
  (void) context;
  NSError *recoveryError = nil;
  const BOOL recovered = [LumenMacWorkspaceSessionFacade.shared
    recoverPendingWorkspaceSyncWithError:&recoveryError];
  (void) recovered;
  if (recoveryError) {
    fprintf(
      stderr,
      "Lumen workspace watchdog recovery failed after worker exit: %s\n",
      recoveryError.localizedDescription.UTF8String ?: "unknown error"
    );
  }
  LumenHostPostRuntimeStatus(
    willRestart,
    exitCode,
    restartAttempt,
    restartDelaySeconds
  );
}

static void LumenHostCopyLiteral(
  const char *message,
  char *destination,
  size_t capacity
) {
  if (destination && capacity > 0) {
    snprintf(destination, capacity, "%s", message ?: "");
  }
}

static void LumenHostCopySupervisorError(
  const LumenHostRuntimeSupervisor *supervisor,
  LumenEngineStatus status,
  char *destination,
  size_t capacity
) {
  if (!destination || capacity == 0) {
    return;
  }
  if (lumen_host_runtime_supervisor_copy_last_error(
        supervisor,
        destination,
        capacity
      ) == 0 && status != LumenEngineStatusOk) {
    snprintf(
      destination,
      capacity,
      "Rust host runtime supervisor failed with status %u.",
      (unsigned) status
    );
  }
}

struct LumenHostRuntimeController {
  LumenHostRuntimeSupervisor *supervisor;
};

LumenHostRuntimeController *LumenHostRuntimeControllerCreate(void) {
  LumenHostRuntimeController *controller = calloc(1, sizeof(*controller));
  if (!controller) {
    return NULL;
  }
  controller->supervisor = lumen_host_runtime_supervisor_create();
  if (!controller->supervisor) {
    free(controller);
    return NULL;
  }
  return controller;
}

void LumenHostRuntimeControllerDestroy(LumenHostRuntimeController *controller) {
  if (!controller) {
    return;
  }
  lumen_host_runtime_supervisor_destroy(controller->supervisor);
  free(controller);
}

bool LumenHostRuntimeControllerStart(
  LumenHostRuntimeController *controller,
  char *errorDestination,
  size_t errorCapacity
) {
  if (!controller || !controller->supervisor) {
    LumenHostCopyLiteral(
      "LumenHostRuntimeControllerStart called with a null controller.",
      errorDestination,
      errorCapacity
    );
    return false;
  }

  NSError *recoveryError = nil;
  const BOOL recovered = [LumenMacWorkspaceSessionFacade.shared
    recoverPendingWorkspaceSyncWithError:&recoveryError];
  (void) recovered;
  if (recoveryError) {
    LumenHostCopyLiteral(
      recoveryError.localizedDescription.UTF8String,
      errorDestination,
      errorCapacity
    );
    return false;
  }

  NSString *workerPath = LumenHostWorkerPath();
  NSArray<NSString *> *arguments = LumenHostRuntimeArguments();
  const char **argumentValues = NULL;
  if (arguments.count > 0) {
    argumentValues = calloc(arguments.count, sizeof(*argumentValues));
    if (!argumentValues) {
      LumenHostCopyLiteral(
        "Could not allocate runtime arguments.",
        errorDestination,
        errorCapacity
      );
      return false;
    }
    for (NSUInteger index = 0; index < arguments.count; ++index) {
      argumentValues[index] = arguments[index].UTF8String ?: "";
    }
  }

  LumenEngineStatus status = lumen_host_runtime_supervisor_start(
    controller->supervisor,
    workerPath.UTF8String,
    argumentValues,
    arguments.count,
    LumenHostBootstrapLogPath().UTF8String,
    LumenHostHandleRuntimeStatus,
    NULL
  );
  free(argumentValues);
  LumenHostCopySupervisorError(
    controller->supervisor,
    status,
    errorDestination,
    errorCapacity
  );
  return status == LumenEngineStatusOk;
}

void LumenHostRuntimeControllerStop(LumenHostRuntimeController *controller) {
  if (controller && controller->supervisor) {
    lumen_host_runtime_supervisor_stop(controller->supervisor);
  }
}

bool LumenHostRuntimeControllerFactoryReset(
  LumenHostRuntimeController *controller,
  char *errorDestination,
  size_t errorCapacity
) {
  if (!controller || !controller->supervisor) {
    LumenHostCopyLiteral(
      "Factory reset called with a null controller.",
      errorDestination,
      errorCapacity
    );
    return false;
  }

  lumen_host_runtime_supervisor_stop(controller->supervisor);
  LumenNativeRuntimeSettingsSnapshot *settings =
    [[LumenNativeRuntimeSettingsSnapshot alloc] init];
  NSString *appDataPath = LumenHostSupportDirectoryPath();
  NSString *configPath = [appDataPath stringByAppendingPathComponent:@"lumen.conf"];
  LumenHostResetStorageResult result = {0};
  LumenHostResetStorageRequest request = {
    .app_data_path = appDataPath.UTF8String,
    .config_file_path = configPath.UTF8String,
    .app_catalog_file_path = settings.applicationsFilePath.UTF8String,
    .state_file_path = settings.stateFilePath.UTF8String,
    .credential_file_path = settings.credentialsFilePath.UTF8String,
  };
  LumenEngineStatus status = lumen_host_runtime_supervisor_reset_storage(
    controller->supervisor,
    request,
    &result
  );
  LumenHostCopySupervisorError(
    controller->supervisor,
    status,
    errorDestination,
    errorCapacity
  );
  return status == LumenEngineStatusOk;
}

bool LumenHostRuntimeControllerIsRunning(const LumenHostRuntimeController *controller) {
  return controller && controller->supervisor &&
    lumen_host_runtime_supervisor_state(controller->supervisor) ==
      LumenHostRuntimeStateRunning;
}

int32_t LumenHostRuntimeControllerCopyLastExitCode(
  const LumenHostRuntimeController *controller
) {
  return controller && controller->supervisor
    ? lumen_host_runtime_supervisor_last_exit_code(controller->supervisor)
    : 0;
}

void LumenHostRuntimeControllerForceStopStream(LumenHostRuntimeController *controller) {
  if (controller && controller->supervisor) {
    lumen_host_runtime_supervisor_force_stop_stream(controller->supervisor);
  }
}

void LumenHostRuntimeControllerReloadApplications(LumenHostRuntimeController *controller) {
  if (controller && controller->supervisor) {
    lumen_host_runtime_supervisor_reload_applications(controller->supervisor);
  }
}

bool LumenHostRuntimeIsAccessibilityPermissionGranted(void) {
  return AXIsProcessTrusted();
}

void LumenHostRuntimeRequestAccessibilityPermission(void) {
  NSDictionary *options = @{(__bridge NSString *) kAXTrustedCheckOptionPrompt: @YES};
  AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
}

bool LumenHostRuntimeIsScreenCapturePermissionGranted(void) {
  return CGPreflightScreenCaptureAccess();
}

void LumenHostRuntimeRequestScreenCapturePermission(void) {
  CGRequestScreenCaptureAccess();
}
