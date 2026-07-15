#ifndef LUMEN_SETTINGS_H
#define LUMEN_SETTINGS_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#include "lumen_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

#define LUMEN_SETTINGS_ABI_VERSION 2u

typedef struct LumenSettingsAuthority LumenSettingsAuthority;

typedef enum LumenSettingsHostPlatform {
  LumenSettingsHostPlatformMacOS = 0,
  LumenSettingsHostPlatformWindows = 1
} LumenSettingsHostPlatform;

typedef enum LumenSettingsOperation {
  LumenSettingsOperationSnapshot = 0,
  LumenSettingsOperationApplyPatch = 1,
  LumenSettingsOperationEventsSince = 2,
  LumenSettingsOperationMarkNextSessionStarted = 3,
  LumenSettingsOperationMarkWorkerRestarted = 4,
  LumenSettingsOperationApplyLocalUpdate = 5,
  LumenSettingsOperationFactoryReset = 6,
  LumenSettingsOperationPreviewApplyPatch = 7,
  LumenSettingsOperationPreviewNextSessionStarted = 8,
  LumenSettingsOperationPreviewWorkerRestarted = 9,
  LumenSettingsOperationPreviewFactoryReset = 10
} LumenSettingsOperation;

typedef struct LumenSettingsResponse {
  uint16_t status_code;
  char *body;
  size_t body_length;
} LumenSettingsResponse;

typedef enum LumenSettingsTransaction {
  LumenSettingsTransactionApplyPatch = 0,
  LumenSettingsTransactionNextSessionStarted = 1,
  LumenSettingsTransactionWorkerRestarted = 2,
  LumenSettingsTransactionFactoryReset = 3
} LumenSettingsTransaction;

typedef const char *(*LumenSettingsPrepareRuntimeCallback)(
  const uint8_t *effective_json,
  size_t effective_json_length,
  void *context
);

typedef void (*LumenSettingsCommitRuntimeCallback)(void *context);

typedef const char *(*LumenSettingsSnapshotRuntimeCallback)(
  const uint8_t **settings_json_out,
  size_t *settings_json_length_out,
  void *context
);

typedef struct LumenSettingsRuntimeTransactionCallbacks {
  LumenSettingsPrepareRuntimeCallback prepare;
  LumenSettingsCommitRuntimeCallback commit;
  void *context;
} LumenSettingsRuntimeTransactionCallbacks;

uint32_t lumen_settings_abi_version(void);

LumenEngineStatus lumen_settings_authority_open(
  const char *file_path,
  uint32_t platform,
  LumenSettingsAuthority **authority_out
);

void lumen_settings_authority_destroy(LumenSettingsAuthority *authority);

LumenEngineStatus lumen_settings_authority_dispatch_json(
  LumenSettingsAuthority *authority,
  uint32_t operation,
  const uint8_t *request_body,
  size_t request_body_length,
  uint64_t after_revision,
  LumenSettingsResponse *response_out
);

LumenEngineStatus lumen_settings_authority_transact_json(
  LumenSettingsAuthority *authority,
  uint32_t transaction,
  const uint8_t *request_body,
  size_t request_body_length,
  bool commit_runtime_when_revision_unchanged,
  LumenSettingsRuntimeTransactionCallbacks callbacks,
  LumenSettingsResponse *response_out
);

LumenEngineStatus lumen_settings_authority_reconcile_local_json(
  LumenSettingsAuthority *authority,
  LumenSettingsSnapshotRuntimeCallback snapshot,
  void *context,
  LumenSettingsResponse *response_out
);

void lumen_settings_response_destroy(LumenSettingsResponse *response);

#ifdef __cplusplus
}
#endif

#endif
