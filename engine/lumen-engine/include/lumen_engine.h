#ifndef LUMEN_ENGINE_H
#define LUMEN_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUMEN_ENGINE_ABI_VERSION 61u
#define LUMEN_ENCRYPTED_CONTROL_HEADER_SIZE 8u
#define LUMEN_CONTROL_FEEDBACK_MAX_SIZE 29u
#define LUMEN_CONTROL_TERMINATION_SIZE 8u
#define LUMEN_AUDIO_STREAM_PROFILE_COUNT 6u

typedef enum LumenEngineStatus {
  LumenEngineStatusOk = 0,
  LumenEngineStatusNoCommand = 1,
  LumenEngineStatusInvalidArgument = 2,
  LumenEngineStatusInvalidState = 3,
  LumenEngineStatusCommandMismatch = 4,
  LumenEngineStatusCommandFailed = 5,
  LumenEngineStatusPanic = 6,
  LumenEngineStatusAlreadyExists = 7,
  LumenEngineStatusAuthenticationFailed = 8,
  LumenEngineStatusStorageError = 9,
  LumenEngineStatusCorruptData = 10
} LumenEngineStatus;

typedef enum LumenOwnerState {
  LumenOwnerStateUninitialized = 0,
  LumenOwnerStateReady = 1,
  LumenOwnerStateCorrupt = 2,
  LumenOwnerStateUnavailable = 3
} LumenOwnerState;

typedef enum LumenWorkspacePolicy {
  LumenWorkspacePolicyCoexist = 0,
  LumenWorkspacePolicyPromoteVirtualMain = 1,
  LumenWorkspacePolicyFocusedWorkspace = 2,
  LumenWorkspacePolicyIsolatedWorkspace = 3
} LumenWorkspacePolicy;

typedef enum LumenWorkspaceState {
  LumenWorkspaceStateIdle = 0,
  LumenWorkspaceStateStarting = 1,
  LumenWorkspaceStateActive = 2,
  LumenWorkspaceStateStopping = 3
} LumenWorkspaceState;

typedef enum LumenWorkspaceCommandKind {
  LumenWorkspaceCommandSnapshotWorkspace = 0,
  LumenWorkspaceCommandCreateVirtualDisplay = 1,
  LumenWorkspaceCommandConfigureVirtualDisplay = 2,
  LumenWorkspaceCommandPromoteVirtualMain = 3,
  LumenWorkspaceCommandMoveTargetWindows = 4,
  LumenWorkspaceCommandApplyIsolation = 5,
  LumenWorkspaceCommandStartCapture = 6,
  LumenWorkspaceCommandStopCapture = 7,
  LumenWorkspaceCommandRestoreWorkspace = 8,
  LumenWorkspaceCommandDestroyVirtualDisplay = 9
} LumenWorkspaceCommandKind;

typedef struct LumenWorkspaceSessionRequest {
  LumenWorkspacePolicy policy;
  bool move_target_windows;
  bool manage_capture;
} LumenWorkspaceSessionRequest;

typedef struct LumenWorkspaceCommand {
  LumenWorkspaceCommandKind kind;
  uint64_t generation;
  uint32_t sequence;
} LumenWorkspaceCommand;

typedef enum LumenHostRuntimeState {
  LumenHostRuntimeStateStopped = 0,
  LumenHostRuntimeStateStarting = 1,
  LumenHostRuntimeStateRunning = 2,
  LumenHostRuntimeStateStopping = 3,
  LumenHostRuntimeStateResetting = 4,
  LumenHostRuntimeStateFailed = 5
} LumenHostRuntimeState;

typedef enum LumenHostRuntimeCommandKind {
  LumenHostRuntimeCommandStart = 0,
  LumenHostRuntimeCommandStop = 1,
  LumenHostRuntimeCommandReset = 2,
  LumenHostRuntimeCommandForceStopStream = 3
} LumenHostRuntimeCommandKind;

typedef struct LumenHostRuntimeCommand {
  LumenHostRuntimeCommandKind kind;
  uint64_t generation;
  uint32_t sequence;
} LumenHostRuntimeCommand;

typedef struct LumenHostResetStorageRequest {
  const char *app_data_path;
  const char *config_file_path;
  const char *app_catalog_file_path;
  const char *state_file_path;
  const char *credential_file_path;
} LumenHostResetStorageRequest;

typedef struct LumenHostResetStorageResult {
  uint32_t attempted_path_count;
  uint32_t removed_path_count;
  uint32_t failed_path_count;
} LumenHostResetStorageResult;

typedef struct LumenDisplayModeRequest {
  uint32_t width;
  uint32_t height;
  uint32_t scale_percent;
  bool dimensions_are_logical;
} LumenDisplayModeRequest;

typedef struct LumenDisplayGeometry {
  uint32_t stream_width;
  uint32_t stream_height;
  uint32_t logical_width;
  uint32_t logical_height;
  uint32_t backing_width;
  uint32_t backing_height;
} LumenDisplayGeometry;

typedef enum LumenVirtualDisplayReason {
  LumenVirtualDisplayReasonNone = 0,
  LumenVirtualDisplayReasonSessionRequested = 1u << 0,
  LumenVirtualDisplayReasonAppRequested = 1u << 1,
  LumenVirtualDisplayReasonHDRDisplayRequired = 1u << 2,
  LumenVirtualDisplayReasonHiDPIRequested = 1u << 3,
  LumenVirtualDisplayReasonLogicalDimensions = 1u << 4,
  LumenVirtualDisplayReasonScaledDesktop = 1u << 5
} LumenVirtualDisplayReason;

typedef struct LumenVirtualDisplayRequest {
  bool session_requested;
  bool app_requested;
  bool hdr_display_required;
  bool hidpi_requested;
  bool dimensions_are_logical;
  uint32_t scale_percent;
} LumenVirtualDisplayRequest;

typedef struct LumenVirtualDisplayPlan {
  bool required;
  uint32_t reason_flags;
} LumenVirtualDisplayPlan;

typedef enum LumenDisplayGamut {
  LumenDisplayGamutSRGB = 0,
  LumenDisplayGamutDisplayP3 = 1,
  LumenDisplayGamutRec2020 = 2
} LumenDisplayGamut;

typedef enum LumenDisplayTransfer {
  LumenDisplayTransferSDR = 0,
  LumenDisplayTransferPQ = 1,
  LumenDisplayTransferHLG = 2
} LumenDisplayTransfer;

typedef struct LumenDisplayColorRequest {
  bool hdr_enabled;
  int32_t client_gamut;
  int32_t client_transfer;
} LumenDisplayColorRequest;

typedef struct LumenDisplayColorProfile {
  LumenDisplayGamut gamut;
  LumenDisplayTransfer transfer;
  double red_x;
  double red_y;
  double green_x;
  double green_y;
  double blue_x;
  double blue_y;
  double white_x;
  double white_y;
  bool hdr_capable;
} LumenDisplayColorProfile;

typedef enum LumenProtocolDynamicRangeTransport {
  LumenProtocolDynamicRangeTransportUnknown = 0,
  LumenProtocolDynamicRangeTransportSDR = 1,
  LumenProtocolDynamicRangeTransportFullFrameHDR = 2,
  LumenProtocolDynamicRangeTransportFrameGatedHDR = 3,
  LumenProtocolDynamicRangeTransportSDRBaseHDROverlay = 4
} LumenProtocolDynamicRangeTransport;

typedef enum LumenProtocolPresentationContract {
  LumenProtocolPresentationContractSingleFrame = 0
} LumenProtocolPresentationContract;

typedef enum LumenProtocolPresentationCompletionRule {
  LumenProtocolPresentationCompletionRuleFullFrame = 0
} LumenProtocolPresentationCompletionRule;

typedef struct LumenProtocolSinkCapability {
  bool prefers_hdr;
  bool supports_hdr_tile_overlay;
  bool supports_per_frame_hdr_metadata;
} LumenProtocolSinkCapability;

typedef struct LumenProtocolSourceCapability {
  bool hdr_enabled;
  bool supports_hdr_overlay_encode;
} LumenProtocolSourceCapability;

typedef struct LumenProtocolNegotiationRequest {
  uint32_t requested_transport;
  LumenProtocolSinkCapability sink;
  LumenProtocolSourceCapability source;
} LumenProtocolNegotiationRequest;

typedef struct LumenProtocolAdapterRequest {
  uint32_t requested_transport;
  uint32_t negotiated_transport;
  LumenProtocolSinkCapability sink;
} LumenProtocolAdapterRequest;

typedef struct LumenProtocolAdapterResult {
  uint32_t requested_transport;
  uint32_t negotiated_transport;
  LumenProtocolSinkCapability sink;
  uint32_t presentation_contract;
  uint32_t presentation_completion_rule;
} LumenProtocolAdapterResult;

typedef struct LumenSessionOffer {
  int32_t version;
  bool hidpi;
  bool scale_explicit;
  bool mode_is_logical;
  int32_t scale_percent;
  int32_t gamut;
  int32_t transfer;
  float current_edr_headroom;
  float potential_edr_headroom;
  int32_t current_peak_luminance_nits;
  int32_t potential_peak_luminance_nits;
  bool supports_frame_gated_hdr;
  bool supports_hdr_tile_overlay;
  bool supports_per_frame_hdr_metadata;
  uint32_t requested_transport;
} LumenSessionOffer;

typedef struct LumenSinkTransportRequest {
  uint32_t requested_transport;
  int32_t sink_transfer;
  bool supports_frame_gated_hdr;
  bool supports_hdr_tile_overlay;
  bool supports_per_frame_hdr_metadata;
} LumenSinkTransportRequest;

typedef struct LumenSinkTransportPlan {
  uint32_t requested_transport;
  uint32_t negotiated_transport;
  bool sink_prefers_hdr;
  bool uses_hdr_stream;
  bool uses_hdr_frame_state;
  bool requires_hdr_display;
} LumenSinkTransportPlan;

typedef struct LumenRectI32 {
  int32_t x;
  int32_t y;
  int32_t width;
  int32_t height;
} LumenRectI32;

typedef struct LumenHdrOverlayRegionRequest {
  int32_t x;
  int32_t y;
  int32_t width;
  int32_t height;
} LumenHdrOverlayRegionRequest;

typedef struct LumenHdrOverlayRegionPlan {
  uint32_t region_count;
  LumenRectI32 regions[6];
} LumenHdrOverlayRegionPlan;

typedef enum LumenHdrFrameContent {
  LumenHdrFrameContentSDR = 0,
  LumenHdrFrameContentFullFrameHDR = 1,
  LumenHdrFrameContentPartialHDROverlay = 2
} LumenHdrFrameContent;

typedef struct LumenHdrFrameStateRequest {
  uint32_t transport;
  bool frame_is_hdr_signaled;
  bool include_overlay_regions;
  int32_t frame_width;
  int32_t frame_height;
} LumenHdrFrameStateRequest;

typedef struct LumenHdrFrameStatePlan {
  uint32_t content;
  LumenHdrOverlayRegionPlan overlay_regions;
} LumenHdrFrameStatePlan;

typedef struct LumenWorkspaceEngine LumenWorkspaceEngine;
typedef struct LumenHostRuntimeEngine LumenHostRuntimeEngine;
typedef struct LumenHostRuntimeSupervisor LumenHostRuntimeSupervisor;
typedef struct LumenOwnerStore LumenOwnerStore;
typedef struct LumenDeviceStore LumenDeviceStore;
typedef struct LumenApplicationCatalog LumenApplicationCatalog;
typedef struct LumenAuthAuthority LumenAuthAuthority;
typedef struct LumenSessionRegistry LumenSessionRegistry;
typedef struct LumenStreamSessionFleet LumenStreamSessionFleet;
typedef struct LumenStreamSessionState LumenStreamSessionState;
typedef struct LumenExternalIngressPolicy LumenExternalIngressPolicy;
typedef struct LumenAudioIngressPolicy LumenAudioIngressPolicy;

typedef enum LumenStreamSessionStateValue {
  LumenStreamSessionStateStopped = 0,
  LumenStreamSessionStateStarting = 1,
  LumenStreamSessionStateRunning = 2,
  LumenStreamSessionStateStopping = 3
} LumenStreamSessionStateValue;

typedef struct LumenVideoFecBlockPlan {
  uint64_t requested_block_count;
  uint32_t block_count;
  uint32_t effective_fec_percentage;
  uint64_t aligned_block_size;
  bool packet_index_overflow;
} LumenVideoFecBlockPlan;

typedef struct LumenVideoFecShardPlan {
  uint64_t data_shards;
  uint64_t parity_shards;
  uint64_t total_shards;
  uint32_t effective_fec_percentage;
  bool parity_limited;
} LumenVideoFecShardPlan;

typedef enum LumenAudioChannelMode {
  LumenAudioChannelModeStereo = 0,
  LumenAudioChannelModeFivePointOne = 1,
  LumenAudioChannelModeSevenPointOne = 2
} LumenAudioChannelMode;

typedef struct LumenAudioSelectionRequest {
  const uint8_t *channel_mode;
  size_t channel_mode_length;
  bool enhanced_audio_quality;
} LumenAudioSelectionRequest;

typedef struct LumenAudioSelectionPlan {
  LumenAudioChannelMode channel_mode;
  bool enhanced_audio_quality;
  int32_t channel_count;
  uint32_t channel_mask;
  int32_t packet_duration_milliseconds;
  int32_t qos_traffic_type;
} LumenAudioSelectionPlan;

typedef struct LumenLaunchQueryField {
  const uint8_t *name;
  size_t name_length;
  const uint8_t *value;
  size_t value_length;
} LumenLaunchQueryField;

typedef struct LumenLaunchRequestPlan {
  uint32_t application_id;
  uint32_t width;
  uint32_t height;
  uint32_t frames_per_second;
  uint8_t remote_input_key[16];
  uint32_t remote_input_key_id;
  bool play_audio_on_host;
  LumenAudioSelectionPlan audio;
  bool virtual_display;
  LumenSessionOffer session_offer;
} LumenLaunchRequestPlan;

typedef struct LumenAudioStreamRequest {
  int32_t channels;
  int32_t packet_duration_milliseconds;
  bool enhanced_audio_quality;
} LumenAudioStreamRequest;

typedef struct LumenAudioStreamPlan {
  int32_t sample_rate;
  int32_t channel_count;
  int32_t streams;
  int32_t coupled_streams;
  uint8_t mapping[8];
  int32_t bitrate;
  int32_t frame_count;
  size_t sample_count;
  size_t pcm_byte_count;
  uint32_t packet_queue_capacity;
} LumenAudioStreamPlan;

typedef struct LumenVideoRateRequest {
  int32_t requested_frame_rate;
  int32_t session_frame_rate_millihertz;
  int64_t configured_bitrate_kbps;
} LumenVideoRateRequest;

typedef struct LumenVideoRatePlan {
  int32_t normalized_frame_rate;
  uint32_t warp_factor;
  int64_t restored_bitrate_kbps;
} LumenVideoRatePlan;

typedef struct LumenAudioIngressRequest {
  int32_t sample_rate;
  int32_t channel_count;
  int32_t frame_count;
  size_t sample_count;
  size_t pcm_byte_count;
} LumenAudioIngressRequest;

typedef struct LumenAudioIngressFrame {
  int32_t sample_rate;
  int32_t channel_count;
  int32_t frame_count;
  size_t copied_pcm_byte_count;
} LumenAudioIngressFrame;

typedef struct LumenAudioIngressDecision {
  bool accepted;
  bool should_log_mismatch;
} LumenAudioIngressDecision;

typedef enum LumenAudioSinkKind {
  LumenAudioSinkHost = 0,
  LumenAudioSinkConfigured = 1,
  LumenAudioSinkUnavailable = 2
} LumenAudioSinkKind;

typedef struct LumenAudioSinkRequest {
  bool host_audio_enabled;
  bool host_sink_available;
  bool configured_sink_available;
} LumenAudioSinkRequest;

typedef struct LumenAudioSinkPlan {
  uint32_t kind;
} LumenAudioSinkPlan;

typedef struct LumenVideoIngressThresholds {
  double callback_latency_milliseconds;
  double packet_timestamp_milliseconds;
} LumenVideoIngressThresholds;

typedef struct LumenVideoColorspaceRequest {
  int32_t encoder_csc_mode;
  uint32_t negotiated_transport;
  bool hdr_display;
} LumenVideoColorspaceRequest;

typedef struct LumenVideoColorspacePlan {
  uint32_t colorspace;
  bool full_range;
  uint32_t bit_depth;
  bool recognized_csc;
} LumenVideoColorspacePlan;

typedef struct LumenVideoColorMatrix {
  float color_vec_y[4];
  float color_vec_u[4];
  float color_vec_v[4];
  float range_y[2];
  float range_uv[2];
} LumenVideoColorMatrix;

typedef enum LumenNetworkClass {
  LumenNetworkPC = 0,
  LumenNetworkLAN = 1,
  LumenNetworkWAN = 2
} LumenNetworkClass;

typedef struct LumenOwnedBytes {
  uint8_t *data;
  size_t length;
} LumenOwnedBytes;

typedef enum LumenExternalIngressAction {
  LumenExternalIngressAccept = 0,
  LumenExternalIngressDropDuplicateIdentity = 1,
  LumenExternalIngressResyncCadence = 2,
  LumenExternalIngressResyncDuplicatePayload = 3,
  LumenExternalIngressRestartDuplicatePayload = 4
} LumenExternalIngressAction;

typedef struct LumenExternalIngressFrame {
  uint64_t source_sequence;
  uint64_t source_display_time_nanoseconds;
  bool has_packet_timestamp;
  int64_t packet_timestamp_microseconds;
  bool has_callback_latency;
  double callback_latency_milliseconds;
  bool is_replay;
  bool is_idr;
  double callback_latency_threshold_milliseconds;
  double packet_timestamp_threshold_milliseconds;
} LumenExternalIngressFrame;

typedef struct LumenExternalIngressDecision {
  uint32_t action;
  uint64_t sequence_delta;
  bool has_source_display_delta;
  double source_display_delta_milliseconds;
  bool has_packet_timestamp_delta;
  double packet_timestamp_delta_milliseconds;
  bool has_callback_latency;
  double callback_latency_milliseconds;
  bool duplicate_payload;
  bool cadence_anomaly;
  bool callback_latency_spike;
  bool packet_timestamp_drift;
  uint32_t duplicate_payload_run;
  uint32_t duplicate_payload_recovery_attempts;
} LumenExternalIngressDecision;

typedef enum LumenExternalIngressEventKind {
  LumenExternalIngressEventSaturatedDrop = 0,
  LumenExternalIngressEventForwarderOverflow = 1,
  LumenExternalIngressEventOtherDrop = 2
} LumenExternalIngressEventKind;

typedef enum LumenExternalIngressEventAction {
  LumenExternalIngressEventNoAction = 0,
  LumenExternalIngressEventResync = 1,
  LumenExternalIngressEventRestart = 2
} LumenExternalIngressEventAction;

typedef struct LumenExternalIngressEventDecision {
  uint32_t action;
  uint32_t saturated_drop_run;
} LumenExternalIngressEventDecision;

typedef enum LumenExternalIngressPacketAction {
  LumenExternalIngressPacketAccept = 0,
  LumenExternalIngressPacketDropUnsupportedCodec = 1,
  LumenExternalIngressPacketDropCodecMismatch = 2,
  LumenExternalIngressPacketDropWaitingForIDR = 3
} LumenExternalIngressPacketAction;

typedef struct LumenExternalIngressPacketAdmission {
  int32_t frame_codec;
  int32_t requested_video_format;
  bool is_idr;
} LumenExternalIngressPacketAdmission;

typedef struct LumenExternalIngressPacketDecision {
  uint32_t action;
  int32_t effective_video_format;
  bool codec_adopted;
  bool should_log_codec_mismatch;
  bool should_log_waiting_for_idr;
} LumenExternalIngressPacketDecision;

typedef struct LumenExternalIngressPacketAllocation {
  int64_t frame_index;
  bool is_first_packet;
} LumenExternalIngressPacketAllocation;

typedef struct LumenExternalIngressProgressDecision {
  bool stalled;
  bool should_log_stall;
} LumenExternalIngressProgressDecision;

typedef void (*LumenHostRuntimeStatusCallback)(
  bool will_restart,
  int32_t exit_code,
  uint32_t restart_attempt,
  double restart_delay_seconds,
  void *context
);

typedef enum LumenAuthHttpOperation {
  LumenAuthHttpOperationEnrollmentChallenge = 0,
  LumenAuthHttpOperationEnroll = 1,
  LumenAuthHttpOperationTokenChallenge = 2,
  LumenAuthHttpOperationToken = 3,
  LumenAuthHttpOperationRevoke = 4
} LumenAuthHttpOperation;

typedef struct LumenAuthHttpResponse {
  uint16_t status_code;
  char *body;
  size_t body_length;
} LumenAuthHttpResponse;

uint32_t lumen_engine_abi_version(void);

LumenEngineStatus lumen_auth_authority_open(
  const char *owner_file_path,
  const char *device_registry_file_path,
  LumenAuthAuthority **authority_out
);

void lumen_auth_authority_destroy(LumenAuthAuthority *authority);

LumenEngineStatus lumen_auth_authority_set_device_enrollment_enabled(
  LumenAuthAuthority *authority,
  uint8_t enabled
);

LumenEngineStatus lumen_auth_authority_dispatch_json(
  LumenAuthAuthority *authority,
  uint32_t operation,
  const uint8_t *request_body,
  size_t request_body_length,
  LumenAuthHttpResponse *response_out
);

LumenEngineStatus lumen_auth_authority_verify_access_token(
  LumenAuthAuthority *authority,
  const char *device_id,
  const char *access_token,
  LumenAuthHttpResponse *response_out
);

void lumen_auth_http_response_destroy(LumenAuthHttpResponse *response);

LumenEngineStatus lumen_session_registry_create(
  LumenSessionRegistry **registry_out
);

void lumen_session_registry_destroy(LumenSessionRegistry *registry);

LumenEngineStatus lumen_session_registry_offer_pending(
  LumenSessionRegistry *registry,
  uint32_t launch_id
);

LumenEngineStatus lumen_session_registry_clear_pending(
  LumenSessionRegistry *registry,
  uint32_t launch_id
);

LumenEngineStatus lumen_session_registry_activate(
  LumenSessionRegistry *registry,
  const char *device_id
);

LumenEngineStatus lumen_session_registry_deactivate(
  LumenSessionRegistry *registry,
  const char *device_id
);

LumenEngineStatus lumen_session_registry_active_count(
  const LumenSessionRegistry *registry,
  size_t *count_out
);

LumenEngineStatus lumen_session_registry_contains(
  const LumenSessionRegistry *registry,
  const char *device_id,
  bool *contains_out
);

LumenEngineStatus lumen_stream_session_state_create(
  LumenStreamSessionState **state_out
);

void lumen_stream_session_state_destroy(LumenStreamSessionState *state);

LumenEngineStatus lumen_stream_session_state_load(
  const LumenStreamSessionState *state,
  uint32_t *value_out
);

LumenEngineStatus lumen_stream_session_state_mark_running(
  const LumenStreamSessionState *state
);

LumenEngineStatus lumen_stream_session_state_request_stop(
  const LumenStreamSessionState *state
);

LumenEngineStatus lumen_stream_session_state_mark_stopped(
  const LumenStreamSessionState *state
);

LumenEngineStatus lumen_stream_session_fleet_create(
  LumenStreamSessionFleet **fleet_out
);

void lumen_stream_session_fleet_destroy(LumenStreamSessionFleet *fleet);

LumenEngineStatus lumen_stream_session_fleet_enter(
  const LumenStreamSessionFleet *fleet,
  bool *is_first_out
);

LumenEngineStatus lumen_stream_session_fleet_leave(
  const LumenStreamSessionFleet *fleet,
  bool *is_last_out
);

LumenEngineStatus lumen_engine_plan_video_fec_blocks(
  uint64_t payload_size,
  uint64_t block_size,
  uint32_t fec_percentage,
  LumenVideoFecBlockPlan *plan_out
);

LumenEngineStatus lumen_engine_plan_video_fec_shards(
  uint64_t payload_size,
  uint64_t block_size,
  uint32_t fec_percentage,
  uint32_t minimum_parity_shards,
  LumenVideoFecShardPlan *plan_out
);

LumenEngineStatus lumen_engine_resolve_audio_stream(
  LumenAudioStreamRequest request,
  LumenAudioStreamPlan *plan_out
);

LumenEngineStatus lumen_engine_resolve_audio_selection(
  LumenAudioSelectionRequest request,
  LumenAudioSelectionPlan *plan_out
);

LumenEngineStatus lumen_engine_parse_launch_request(
  const LumenLaunchQueryField *fields,
  size_t field_count,
  LumenLaunchRequestPlan *plan_out
);

LumenEngineStatus lumen_audio_ingress_policy_create(
  LumenAudioIngressRequest request,
  LumenAudioIngressPolicy **policy_out
);

void lumen_audio_ingress_policy_destroy(LumenAudioIngressPolicy *policy);

LumenEngineStatus lumen_audio_ingress_policy_evaluate(
  const LumenAudioIngressPolicy *policy,
  LumenAudioIngressFrame frame,
  LumenAudioIngressDecision *decision_out
);

LumenEngineStatus lumen_engine_resolve_audio_sink(
  LumenAudioSinkRequest request,
  LumenAudioSinkPlan *plan_out
);

LumenEngineStatus lumen_engine_video_ingress_thresholds(
  int32_t frame_rate,
  LumenVideoIngressThresholds *thresholds_out
);

LumenEngineStatus lumen_engine_resolve_video_rate(
  LumenVideoRateRequest request,
  LumenVideoRatePlan *plan_out
);

LumenEngineStatus lumen_engine_resolve_video_colorspace(
  LumenVideoColorspaceRequest request,
  LumenVideoColorspacePlan *plan_out
);

LumenEngineStatus lumen_engine_resolve_video_color_matrix(
  uint32_t colorspace,
  bool full_range,
  uint32_t bit_depth,
  bool integer_range,
  LumenVideoColorMatrix *matrix_out
);

LumenEngineStatus lumen_engine_classify_network_address(
  const char *address,
  uint32_t *network_out
);

void lumen_engine_owned_bytes_destroy(LumenOwnedBytes value);

LumenEngineStatus lumen_engine_file_parent_directory(
  const char *path,
  LumenOwnedBytes *value_out
);

LumenEngineStatus lumen_engine_directory_create(
  const char *path,
  bool *available_out
);

LumenEngineStatus lumen_engine_file_read(
  const char *path,
  bool *found_out,
  LumenOwnedBytes *value_out
);

LumenEngineStatus lumen_engine_file_write(
  const char *path,
  const uint8_t *data,
  size_t length
);

LumenEngineStatus lumen_external_ingress_policy_create(
  LumenExternalIngressPolicy **policy_out
);

void lumen_external_ingress_policy_destroy(LumenExternalIngressPolicy *policy);

LumenEngineStatus lumen_external_ingress_policy_reset(
  const LumenExternalIngressPolicy *policy,
  bool preserve_recovery_attempts
);

LumenEngineStatus lumen_external_ingress_policy_evaluate(
  const LumenExternalIngressPolicy *policy,
  LumenExternalIngressFrame frame,
  const uint8_t *payload,
  size_t payload_length,
  LumenExternalIngressDecision *decision_out
);

LumenEngineStatus lumen_external_ingress_policy_record_event(
  const LumenExternalIngressPolicy *policy,
  uint32_t event_kind,
  LumenExternalIngressEventDecision *decision_out
);

LumenEngineStatus lumen_external_ingress_policy_admit_packet(
  const LumenExternalIngressPolicy *policy,
  LumenExternalIngressPacketAdmission packet,
  LumenExternalIngressPacketDecision *decision_out
);

LumenEngineStatus lumen_external_ingress_policy_allocate_packet(
  const LumenExternalIngressPolicy *policy,
  LumenExternalIngressPacketAllocation *allocation_out
);

LumenEngineStatus lumen_external_ingress_policy_record_progress(
  const LumenExternalIngressPolicy *policy,
  uint64_t frame_count,
  bool producer_active,
  LumenExternalIngressProgressDecision *decision_out
);

LumenEngineStatus lumen_engine_resolve_display_geometry(
  LumenDisplayModeRequest request,
  LumenDisplayGeometry *geometry_out
);

LumenEngineStatus lumen_engine_resolve_virtual_display_plan(
  LumenVirtualDisplayRequest request,
  LumenVirtualDisplayPlan *plan_out
);

LumenEngineStatus lumen_engine_resolve_display_color(
  LumenDisplayColorRequest request,
  LumenDisplayColorProfile *profile_out
);

LumenEngineStatus lumen_engine_resolve_protocol_transport(
  LumenProtocolNegotiationRequest request,
  uint32_t *transport_out
);

LumenEngineStatus lumen_engine_resolve_protocol_adapter(
  LumenProtocolAdapterRequest request,
  LumenProtocolAdapterResult *result_out
);

LumenEngineStatus lumen_engine_parse_session_offer(
  const uint8_t *value,
  size_t value_length,
  LumenSessionOffer *offer_out
);

LumenEngineStatus lumen_engine_resolve_sink_transport(
  LumenSinkTransportRequest request,
  LumenSinkTransportPlan *plan_out
);

LumenEngineStatus lumen_engine_resolve_video_transport(
  int32_t video_format,
  LumenSinkTransportRequest request,
  LumenSinkTransportPlan *plan_out
);

LumenEngineStatus lumen_engine_normalize_capture_frame_rate(
  int32_t requested_frame_rate,
  bool millihz,
  int32_t *frame_rate_out
);

LumenEngineStatus lumen_engine_resolve_hdr_overlay_regions(
  LumenHdrOverlayRegionRequest request,
  LumenHdrOverlayRegionPlan *plan_out
);

LumenEngineStatus lumen_engine_resolve_hdr_frame_state(
  LumenHdrFrameStateRequest request,
  LumenHdrFrameStatePlan *plan_out
);

LumenEngineStatus lumen_owner_store_open(
  const char *file_path,
  LumenOwnerStore **store_out
);

void lumen_owner_store_destroy(LumenOwnerStore *store);

LumenOwnerState lumen_owner_store_state(
  const LumenOwnerStore *store
);

LumenEngineStatus lumen_owner_store_create_owner(
  LumenOwnerStore *store,
  const char *username,
  const char *password
);

LumenEngineStatus lumen_owner_store_verify_owner(
  const LumenOwnerStore *store,
  const char *username,
  const char *password
);

LumenEngineStatus lumen_owner_store_copy_username(
  const LumenOwnerStore *store,
  char *destination,
  size_t capacity
);

LumenEngineStatus lumen_device_store_open(
  const char *file_path,
  LumenDeviceStore **store_out
);

void lumen_device_store_destroy(LumenDeviceStore *store);

LumenEngineStatus lumen_device_store_enroll(
  LumenDeviceStore *store,
  const LumenOwnerStore *owner_store,
  const char *owner_username,
  const char *owner_password,
  const char *device_name,
  const char *platform,
  const char *public_key,
  char *device_id_destination,
  size_t device_id_capacity,
  char *refresh_token_destination,
  size_t refresh_token_capacity
);

LumenEngineStatus lumen_device_store_verify_refresh_token(
  const LumenDeviceStore *store,
  const char *device_id,
  const char *refresh_token
);

LumenEngineStatus lumen_device_store_revoke(
  LumenDeviceStore *store,
  const LumenOwnerStore *owner_store,
  const char *owner_username,
  const char *owner_password,
  const char *device_id
);

uint32_t lumen_device_store_active_count(
  const LumenDeviceStore *store
);

LumenEngineStatus lumen_application_catalog_open(
  const char *file_path,
  LumenApplicationCatalog **catalog_out
);

void lumen_application_catalog_destroy(
  LumenApplicationCatalog *catalog
);

size_t lumen_application_catalog_json_size(
  const LumenApplicationCatalog *catalog
);

LumenEngineStatus lumen_application_catalog_copy_json(
  const LumenApplicationCatalog *catalog,
  char *destination,
  size_t capacity
);

LumenEngineStatus lumen_application_catalog_upsert_json(
  LumenApplicationCatalog *catalog,
  const char *application_json
);

LumenEngineStatus lumen_application_catalog_delete(
  LumenApplicationCatalog *catalog,
  const char *application_id
);

LumenEngineStatus lumen_application_catalog_reorder_json(
  LumenApplicationCatalog *catalog,
  const char *application_ids_json
);

LumenHostRuntimeEngine *lumen_host_runtime_engine_create(void);
void lumen_host_runtime_engine_destroy(LumenHostRuntimeEngine *engine);

LumenEngineStatus lumen_host_runtime_engine_request_start(
  LumenHostRuntimeEngine *engine
);

LumenEngineStatus lumen_host_runtime_engine_request_stop(
  LumenHostRuntimeEngine *engine
);

LumenEngineStatus lumen_host_runtime_engine_request_reset(
  LumenHostRuntimeEngine *engine
);

LumenEngineStatus lumen_host_runtime_engine_request_force_stop_stream(
  LumenHostRuntimeEngine *engine
);

LumenEngineStatus lumen_host_runtime_engine_next_command(
  LumenHostRuntimeEngine *engine,
  LumenHostRuntimeCommand *command_out
);

LumenEngineStatus lumen_host_runtime_engine_complete_command(
  LumenHostRuntimeEngine *engine,
  LumenHostRuntimeCommand command,
  bool succeeded
);

LumenEngineStatus lumen_host_runtime_engine_report_exit(
  LumenHostRuntimeEngine *engine,
  int32_t exit_code
);

LumenEngineStatus lumen_host_runtime_engine_reset_storage(
  LumenHostRuntimeEngine *engine,
  LumenHostResetStorageRequest request,
  LumenHostResetStorageResult *result_out
);

LumenHostRuntimeState lumen_host_runtime_engine_state(
  const LumenHostRuntimeEngine *engine
);

int32_t lumen_host_runtime_engine_last_exit_code(
  const LumenHostRuntimeEngine *engine
);

LumenEngineStatus lumen_host_runtime_engine_last_failure(
  const LumenHostRuntimeEngine *engine
);

LumenHostRuntimeSupervisor *lumen_host_runtime_supervisor_create(void);
void lumen_host_runtime_supervisor_destroy(
  LumenHostRuntimeSupervisor *supervisor
);

LumenEngineStatus lumen_host_runtime_supervisor_start(
  LumenHostRuntimeSupervisor *supervisor,
  const char *worker_path,
  const char *const *arguments,
  size_t argument_count,
  const char *log_path,
  LumenHostRuntimeStatusCallback callback,
  void *callback_context
);

LumenEngineStatus lumen_host_runtime_supervisor_stop(
  LumenHostRuntimeSupervisor *supervisor
);

LumenHostRuntimeState lumen_host_runtime_supervisor_state(
  const LumenHostRuntimeSupervisor *supervisor
);

int32_t lumen_host_runtime_supervisor_last_exit_code(
  const LumenHostRuntimeSupervisor *supervisor
);

LumenEngineStatus lumen_host_runtime_supervisor_last_failure(
  const LumenHostRuntimeSupervisor *supervisor
);

LumenEngineStatus lumen_host_runtime_supervisor_force_stop_stream(
  LumenHostRuntimeSupervisor *supervisor
);

LumenEngineStatus lumen_host_runtime_supervisor_reload_applications(
  LumenHostRuntimeSupervisor *supervisor
);

LumenEngineStatus lumen_host_runtime_supervisor_reset_storage(
  LumenHostRuntimeSupervisor *supervisor,
  LumenHostResetStorageRequest request,
  LumenHostResetStorageResult *result_out
);

size_t lumen_host_runtime_supervisor_copy_last_error(
  const LumenHostRuntimeSupervisor *supervisor,
  char *destination,
  size_t capacity
);

LumenWorkspaceEngine *lumen_workspace_engine_create(void);
void lumen_workspace_engine_destroy(LumenWorkspaceEngine *engine);

LumenEngineStatus lumen_workspace_engine_begin_session(
  LumenWorkspaceEngine *engine,
  LumenWorkspaceSessionRequest request
);

LumenEngineStatus lumen_workspace_engine_next_command(
  LumenWorkspaceEngine *engine,
  LumenWorkspaceCommand *command_out
);

LumenEngineStatus lumen_workspace_engine_complete_command(
  LumenWorkspaceEngine *engine,
  LumenWorkspaceCommand command,
  bool succeeded
);

LumenEngineStatus lumen_workspace_engine_end_session(
  LumenWorkspaceEngine *engine
);

LumenWorkspaceState lumen_workspace_engine_state(
  const LumenWorkspaceEngine *engine
);

uint64_t lumen_workspace_engine_generation(
  const LumenWorkspaceEngine *engine
);

LumenEngineStatus lumen_workspace_engine_last_failure(
  const LumenWorkspaceEngine *engine
);

#ifdef __cplusplus
}
#endif

#endif
