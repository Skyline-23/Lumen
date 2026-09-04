use std::mem::size_of;

pub const ABI_MAGIC: u32 = 0x4C55_4D4E;
pub const ABI_MAJOR: u16 = 1;
pub const ABI_MINOR: u16 = 6;
pub const ABI_HEADER_SIZE: u32 = 16;
pub const ABI_REQUEST_SIZE: u32 = 80;
pub const ABI_RESPONSE_SIZE: u32 = 48;
pub const FRAME_RECORD_BYTES: u64 = 80;
pub const MAX_EVENT_BYTES: u64 = 256;
pub const FRAME_QUEUE_DEPTH: u64 = 8;
pub const EVENT_QUEUE_DEPTH: u64 = 32;
pub const PENDING_READ_DEPTH: usize = 4;

pub const IDDCX_VERSION_1_11: u64 = 0x1B00;
pub const IDDCX_FEATURE_D3D12: u64 = 1 << 0;
pub const ADAPTER_DEVICE_D3D11: u64 = 1 << 0;
pub const ADAPTER_DEVICE_D3D12: u64 = 1 << 1;

pub const BACKEND_D3D11: u32 = 1;
pub const BACKEND_D3D12: u32 = 2;
pub const SURFACE_D3D11_TEXTURE2D: u32 = 1;
pub const SURFACE_D3D12_RESOURCE: u32 = 2;

pub const ADAPTER_FEATURES_PROBED: u32 = 1 << 0;
pub const ADAPTER_PREPARED: u32 = 1 << 1;
pub const ADAPTER_INITIALIZED: u32 = 1 << 2;
pub const ADAPTER_REMOVED: u32 = 1 << 4;
pub const BACKEND_CAPABILITY_D3D11: u32 = 1 << 0;
pub const BACKEND_CAPABILITY_D3D12: u32 = 1 << 1;

pub const STATE_MONITOR_ACTIVE: u32 = 1 << 0;
pub const STATE_ENCODER_ACTIVE: u32 = 1 << 1;
pub const STATE_KEYFRAME_PENDING: u32 = 1 << 2;
pub const STATE_MONITOR_ORPHANED: u32 = 1 << 3;
pub const STATE_SWAPCHAIN_ASSIGNED: u32 = 1 << 4;

pub const MONITOR_FLAG_HDR_CAPABLE: u32 = 1 << 0;
pub const MONITOR_FLAG_MASK: u32 = MONITOR_FLAG_HDR_CAPABLE;

pub const EVENT_ADAPTER_REMOVED: u64 = 1;
pub const EVENT_SWAPCHAIN_LOST: u64 = 2;

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Operation {
    QueryCapabilities = 1,
    ClaimOwner = 2,
    ReleaseOwner = 3,
    CreateMonitor = 4,
    RemoveMonitor = 5,
    StartEncoder = 6,
    StopEncoder = 7,
    RequestKeyframe = 8,
    DequeueFrame = 9,
    DequeueEvent = 10,
    CancelPending = 11,
    QueryHealth = 12,
    QueryBackendCapability = 13,
    RecordOsFeatures = 14,
    PrepareAdapter = 15,
    CompleteAdapterInitialization = 16,
    AssignSwapchain = 17,
    QueryMonitor = 18,
    AdapterRemoved = 19,
    AdoptMonitor = 20,
    UnassignSwapchain = 21,
    CompleteFrame = 22,
}

impl Operation {
    pub const fn raw(self) -> u32 {
        match self {
            Self::QueryCapabilities => 1,
            Self::ClaimOwner => 2,
            Self::ReleaseOwner => 3,
            Self::CreateMonitor => 4,
            Self::RemoveMonitor => 5,
            Self::StartEncoder => 6,
            Self::StopEncoder => 7,
            Self::RequestKeyframe => 8,
            Self::DequeueFrame => 9,
            Self::DequeueEvent => 10,
            Self::CancelPending => 11,
            Self::QueryHealth => 12,
            Self::QueryBackendCapability => 13,
            Self::RecordOsFeatures => 14,
            Self::PrepareAdapter => 15,
            Self::CompleteAdapterInitialization => 16,
            Self::AssignSwapchain => 17,
            Self::QueryMonitor => 18,
            Self::AdapterRemoved => 19,
            Self::AdoptMonitor => 20,
            Self::UnassignSwapchain => 21,
            Self::CompleteFrame => 22,
        }
    }

    pub const fn parse(raw: u32) -> Option<Self> {
        match raw {
            1 => Some(Self::QueryCapabilities),
            2 => Some(Self::ClaimOwner),
            3 => Some(Self::ReleaseOwner),
            4 => Some(Self::CreateMonitor),
            5 => Some(Self::RemoveMonitor),
            6 => Some(Self::StartEncoder),
            7 => Some(Self::StopEncoder),
            8 => Some(Self::RequestKeyframe),
            9 => Some(Self::DequeueFrame),
            10 => Some(Self::DequeueEvent),
            11 => Some(Self::CancelPending),
            12 => Some(Self::QueryHealth),
            13 => Some(Self::QueryBackendCapability),
            14 => Some(Self::RecordOsFeatures),
            15 => Some(Self::PrepareAdapter),
            16 => Some(Self::CompleteAdapterInitialization),
            17 => Some(Self::AssignSwapchain),
            18 => Some(Self::QueryMonitor),
            19 => Some(Self::AdapterRemoved),
            20 => Some(Self::AdoptMonitor),
            21 => Some(Self::UnassignSwapchain),
            22 => Some(Self::CompleteFrame),
            _ => None,
        }
    }
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    Ok = 0,
    InvalidVersion = 1,
    AccessDenied = 2,
    Busy = 3,
    InvalidArgument = 4,
    Oversize = 5,
    StaleGeneration = 6,
    Cancelled = 7,
    InvalidState = 8,
    QueueFull = 9,
    NotReady = 10,
    Pending = 11,
    FeatureUnavailable = 12,
    LuidMismatch = 13,
    DeviceRemoved = 14,
    ProcessorUnavailable = 15,
}

impl Status {
    pub const fn raw(self) -> u32 {
        match self {
            Self::Ok => 0,
            Self::InvalidVersion => 1,
            Self::AccessDenied => 2,
            Self::Busy => 3,
            Self::InvalidArgument => 4,
            Self::Oversize => 5,
            Self::StaleGeneration => 6,
            Self::Cancelled => 7,
            Self::InvalidState => 8,
            Self::QueueFull => 9,
            Self::NotReady => 10,
            Self::Pending => 11,
            Self::FeatureUnavailable => 12,
            Self::LuidMismatch => 13,
            Self::DeviceRemoved => 14,
            Self::ProcessorUnavailable => 15,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AbiHeader {
    pub magic: u32,
    pub major: u16,
    pub minor: u16,
    pub structure_size: u32,
    pub operation: u32,
}

impl AbiHeader {
    pub const fn request(operation: Operation) -> Self {
        Self {
            magic: ABI_MAGIC,
            major: ABI_MAJOR,
            minor: ABI_MINOR,
            structure_size: ABI_REQUEST_SIZE,
            operation: operation.raw(),
        }
    }

    pub const fn response(operation: u32) -> Self {
        Self {
            magic: ABI_MAGIC,
            major: ABI_MAJOR,
            minor: ABI_MINOR,
            structure_size: ABI_RESPONSE_SIZE,
            operation,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CoreRequest {
    pub header: AbiHeader,
    pub owner_id: u64,
    pub generation: u64,
    pub request_id: u64,
    pub arguments: [u64; 5],
}

impl CoreRequest {
    pub const fn new(operation: Operation, owner_id: u64, generation: u64) -> Self {
        Self {
            header: AbiHeader::request(operation),
            owner_id,
            generation,
            request_id: 0,
            arguments: [0; 5],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CoreResponse {
    pub header: AbiHeader,
    pub status: u32,
    pub reserved: u32,
    pub generation: u64,
    pub values: [u64; 2],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct VideoSignalMode {
    pub pixel_rate: u64,
    pub width: u32,
    pub height: u32,
    pub horizontal_sync_numerator: u32,
    pub horizontal_sync_denominator: u32,
    pub vertical_sync_numerator: u32,
    pub vertical_sync_denominator: u32,
    pub vertical_sync_divider: u32,
    pub video_standard: u32,
    pub scan_line_ordering: i32,
}

impl VideoSignalMode {
    pub(crate) const fn new(
        width: u32,
        height: u32,
        refresh_millihertz: u32,
        vertical_sync_divider: u32,
    ) -> Self {
        let rational_divisor = gcd(refresh_millihertz, 1_000);
        let sync_numerator = refresh_millihertz / rational_divisor;
        let sync_denominator = 1_000 / rational_divisor;
        Self {
            pixel_rate: (refresh_millihertz as u64)
                .saturating_mul(width as u64)
                .saturating_mul(height as u64)
                / 1_000,
            width,
            height,
            horizontal_sync_numerator: sync_numerator.saturating_mul(height),
            horizontal_sync_denominator: sync_denominator,
            vertical_sync_numerator: sync_numerator,
            vertical_sync_denominator: sync_denominator,
            vertical_sync_divider,
            video_standard: 255,
            // DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE.
            scan_line_ordering: 1,
        }
    }
}

const fn gcd(mut left: u32, mut right: u32) -> u32 {
    while right != 0 {
        let remainder = left % right;
        left = right;
        right = remainder;
    }
    if left == 0 {
        1
    } else {
        left
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CoreState {
    pub owner_id: u64,
    pub generation: u64,
    pub monitor_id: u64,
    pub pending_frame_reads: [u64; PENDING_READ_DEPTH],
    pub pending_event_reads: [u64; PENDING_READ_DEPTH],
    pub last_frame_id: u64,
    pub flags: u32,
    pub last_status: u32,
    pub frame_queue_depth: u16,
    pub event_queue_depth: u16,
    pub reserved: [u8; 4],
    pub render_adapter_luid: u64,
    pub iddcx_version: u32,
    pub os_feature_flags: u32,
    pub adapter_flags: u32,
    pub backend_capability_mask: u32,
    pub pending_event_code: u32,
    pub pending_event_reserved: u32,
    pub pending_event_value: u64,
}

impl CoreState {
    pub const fn initial() -> Self {
        Self {
            owner_id: 0,
            generation: 1,
            monitor_id: 0,
            pending_frame_reads: [0; PENDING_READ_DEPTH],
            pending_event_reads: [0; PENDING_READ_DEPTH],
            last_frame_id: 0,
            flags: 0,
            last_status: Status::Ok.raw(),
            frame_queue_depth: 0,
            event_queue_depth: 0,
            reserved: [0; 4],
            render_adapter_luid: 0,
            iddcx_version: 0,
            os_feature_flags: 0,
            adapter_flags: 0,
            backend_capability_mask: 0,
            pending_event_code: 0,
            pending_event_reserved: 0,
            pending_event_value: 0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CoreTransition {
    pub state: CoreState,
    pub response: CoreResponse,
}

const _: () = assert!(size_of::<AbiHeader>() == 16);
const _: () = assert!(size_of::<CoreRequest>() == 80);
const _: () = assert!(size_of::<CoreResponse>() == 48);
const _: () = assert!(size_of::<VideoSignalMode>() == 48);
const _: () = assert!(size_of::<CoreState>() == 152);
const _: () = assert!(size_of::<CoreTransition>() == 200);

#[cfg(test)]
mod tests {
    use super::VideoSignalMode;

    #[test]
    fn video_signal_mode_uses_rust_owned_signal_math() {
        assert_eq!(
            VideoSignalMode::new(1920, 1080, 60_000, 0),
            VideoSignalMode {
                pixel_rate: 124_416_000,
                width: 1920,
                height: 1080,
                horizontal_sync_numerator: 64_800,
                horizontal_sync_denominator: 1,
                vertical_sync_numerator: 60,
                vertical_sync_denominator: 1,
                vertical_sync_divider: 0,
                video_standard: 255,
                scan_line_ordering: 1,
            }
        );
    }
}
