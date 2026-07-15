#ifndef LUMEN_DRIVER_ABI_H
#define LUMEN_DRIVER_ABI_H

#include <stddef.h>
#include <stdint.h>

#define LUMEN_DRIVER_ABI_MAGIC 0x4C554D4Eu
#define LUMEN_DRIVER_ABI_MAJOR 1u
#define LUMEN_DRIVER_ABI_MINOR 3u
#define LUMEN_METHOD_BUFFERED 0u
#define LUMEN_METHOD_OUT_DIRECT 2u
#define LUMEN_FILE_READ_ACCESS 1u
#define LUMEN_FILE_WRITE_ACCESS 2u
#define LUMEN_FILE_DEVICE_UNKNOWN 0x22u
#define LUMEN_MAX_ACCESS_UNIT_BYTES (4u * 1024u * 1024u)
#define LUMEN_MAX_EVENT_BYTES 256u
#define LUMEN_ACCESS_UNIT_QUEUE_DEPTH 8u
#define LUMEN_EVENT_QUEUE_DEPTH 32u
#define LUMEN_PENDING_READ_DEPTH 4u
#define LUMEN_IDDCX_VERSION_1_11 0x1B00u
#define LUMEN_IDDCX_FEATURE_D3D12 (1u << 0u)
#define LUMEN_ADAPTER_DEVICE_D3D11 (1u << 0u)
#define LUMEN_ADAPTER_DEVICE_D3D12 (1u << 1u)
#define LUMEN_STATE_MONITOR_ACTIVE (1u << 0u)
#define LUMEN_STATE_ENCODER_ACTIVE (1u << 1u)
#define LUMEN_STATE_KEYFRAME_PENDING (1u << 2u)
#define LUMEN_STATE_MONITOR_ORPHANED (1u << 3u)
#define LUMEN_DEVICE_INTERFACE_GUID_INIT \
  {0xf04b8b5a, 0xa603, 0x4d32, {0x96, 0xf8, 0x5f, 0x8c, 0x21, 0x08, 0xa1, 0xd0}}

#define LUMEN_CTL_CODE(function, method, access) \
  ((LUMEN_FILE_DEVICE_UNKNOWN << 16u) | ((access) << 14u) | \
   ((function) << 2u) | (method))

#define LUMEN_IOCTL_QUERY_CAPABILITIES \
  LUMEN_CTL_CODE(0x900u, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS)
#define LUMEN_IOCTL_CREATE_MONITOR \
  LUMEN_CTL_CODE(0x903u, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS | LUMEN_FILE_WRITE_ACCESS)
#define LUMEN_IOCTL_REMOVE_MONITOR \
  LUMEN_CTL_CODE(0x904u, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS | LUMEN_FILE_WRITE_ACCESS)
#define LUMEN_IOCTL_START_ENCODER \
  LUMEN_CTL_CODE(0x905u, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS | LUMEN_FILE_WRITE_ACCESS)
#define LUMEN_IOCTL_STOP_ENCODER \
  LUMEN_CTL_CODE(0x906u, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS | LUMEN_FILE_WRITE_ACCESS)
#define LUMEN_IOCTL_REQUEST_KEYFRAME \
  LUMEN_CTL_CODE(0x907u, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS | LUMEN_FILE_WRITE_ACCESS)
#define LUMEN_IOCTL_DEQUEUE_ACCESS_UNIT \
  LUMEN_CTL_CODE(0x908u, LUMEN_METHOD_OUT_DIRECT, LUMEN_FILE_READ_ACCESS | LUMEN_FILE_WRITE_ACCESS)
#define LUMEN_IOCTL_DEQUEUE_EVENT \
  LUMEN_CTL_CODE(0x909u, LUMEN_METHOD_OUT_DIRECT, LUMEN_FILE_READ_ACCESS | LUMEN_FILE_WRITE_ACCESS)
#define LUMEN_IOCTL_QUERY_HEALTH \
  LUMEN_CTL_CODE(0x90Au, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS)
#define LUMEN_IOCTL_QUERY_BACKEND_CAPABILITY \
  LUMEN_CTL_CODE(0x90Bu, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS)
#define LUMEN_IOCTL_QUERY_MONITOR \
  LUMEN_CTL_CODE(0x90Cu, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS)
#define LUMEN_IOCTL_ADOPT_MONITOR \
  LUMEN_CTL_CODE(0x90Du, LUMEN_METHOD_BUFFERED, LUMEN_FILE_READ_ACCESS | LUMEN_FILE_WRITE_ACCESS)

typedef enum LumenDriverOperation {
  LumenDriverOperationQueryCapabilities = 1,
  LumenDriverOperationClaimOwner = 2,
  LumenDriverOperationReleaseOwner = 3,
  LumenDriverOperationCreateMonitor = 4,
  LumenDriverOperationRemoveMonitor = 5,
  LumenDriverOperationStartEncoder = 6,
  LumenDriverOperationStopEncoder = 7,
  LumenDriverOperationRequestKeyframe = 8,
  LumenDriverOperationDequeueAccessUnit = 9,
  LumenDriverOperationDequeueEvent = 10,
  LumenDriverOperationCancelPending = 11,
  LumenDriverOperationQueryHealth = 12,
  LumenDriverOperationQueryBackendCapability = 13,
  LumenDriverOperationRecordOsFeatures = 14,
  LumenDriverOperationPrepareAdapter = 15,
  LumenDriverOperationCompleteAdapterInitialization = 16,
  LumenDriverOperationValidateAndAbandonSwapchain = 17,
  LumenDriverOperationQueryMonitor = 18,
  LumenDriverOperationAdapterRemoved = 19,
  LumenDriverOperationAdoptMonitor = 20
} LumenDriverOperation;

typedef enum LumenDriverStatus {
  LumenDriverStatusOk = 0,
  LumenDriverStatusInvalidVersion = 1,
  LumenDriverStatusAccessDenied = 2,
  LumenDriverStatusBusy = 3,
  LumenDriverStatusInvalidArgument = 4,
  LumenDriverStatusOversize = 5,
  LumenDriverStatusStaleGeneration = 6,
  LumenDriverStatusCancelled = 7,
  LumenDriverStatusInvalidState = 8,
  LumenDriverStatusQueueFull = 9,
  LumenDriverStatusNotReady = 10,
  LumenDriverStatusPending = 11,
  LumenDriverStatusFeatureUnavailable = 12,
  LumenDriverStatusLuidMismatch = 13,
  LumenDriverStatusDeviceRemoved = 14,
  LumenDriverStatusProcessorUnavailable = 15
} LumenDriverStatus;

typedef enum LumenDriverEventCode {
  LumenDriverEventAdapterRemoved = 1
} LumenDriverEventCode;

typedef struct LumenDriverAbiHeader {
  uint32_t magic;
  uint16_t major;
  uint16_t minor;
  uint32_t structure_size;
  uint32_t operation;
} LumenDriverAbiHeader;

typedef struct LumenDriverCoreRequest {
  LumenDriverAbiHeader header;
  uint64_t owner_id;
  uint64_t generation;
  uint64_t request_id;
  uint64_t arguments[5];
} LumenDriverCoreRequest;

typedef struct LumenDriverCoreResponse {
  LumenDriverAbiHeader header;
  uint32_t status;
  uint32_t reserved;
  uint64_t generation;
  uint64_t values[2];
} LumenDriverCoreResponse;

typedef struct LumenDriverCoreState {
  uint64_t owner_id;
  uint64_t generation;
  uint64_t monitor_id;
  uint64_t pending_access_unit_reads[LUMEN_PENDING_READ_DEPTH];
  uint64_t pending_event_reads[LUMEN_PENDING_READ_DEPTH];
  uint64_t last_frame_id;
  uint32_t flags;
  uint32_t last_status;
  uint16_t access_unit_queue_depth;
  uint16_t event_queue_depth;
  uint8_t reserved[4];
  uint64_t render_adapter_luid;
  uint32_t iddcx_version;
  uint32_t os_feature_flags;
  uint32_t adapter_flags;
  uint32_t backend_capability_mask;
  uint32_t pending_event_code;
  uint32_t pending_event_reserved;
  uint64_t pending_event_value;
} LumenDriverCoreState;

typedef struct LumenDriverCoreTransition {
  LumenDriverCoreState state;
  LumenDriverCoreResponse response;
} LumenDriverCoreTransition;

#ifdef __cplusplus
extern "C" {
#endif

  LumenDriverCoreState lumen_driver_core_initial_state(void);
  LumenDriverCoreTransition
    lumen_driver_core_dispatch(LumenDriverCoreState state, LumenDriverCoreRequest request);

#ifdef __cplusplus
}

static_assert(sizeof(LumenDriverAbiHeader) == 16, "LumenDriverAbiHeader layout changed");
static_assert(sizeof(LumenDriverCoreRequest) == 80, "LumenDriverCoreRequest layout changed");
static_assert(sizeof(LumenDriverCoreResponse) == 48, "LumenDriverCoreResponse layout changed");
static_assert(sizeof(LumenDriverCoreState) == 152, "LumenDriverCoreState layout changed");
static_assert(sizeof(LumenDriverCoreTransition) == 200, "LumenDriverCoreTransition layout changed");
#endif

#endif
