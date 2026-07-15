use std::mem::size_of;

pub(super) const DEVICE_INTERFACE_GUID: u128 = 0xf04b8b5a_a603_4d32_96f8_5f8c2108a1d0;
pub(super) const ABI_MAGIC: u32 = 0x4C55_4D4E;
pub(super) const ABI_MAJOR: u16 = 1;
pub(super) const ABI_MINOR: u16 = 3;
pub(super) const ABI_REQUEST_SIZE: u32 = 80;
pub(super) const ABI_RESPONSE_SIZE: u32 = 48;

const FILE_DEVICE_UNKNOWN: u32 = 0x22;
const METHOD_BUFFERED: u32 = 0;
const FILE_READ_ACCESS: u32 = 1;
const FILE_WRITE_ACCESS: u32 = 2;

const fn control_code(function: u32, access: u32) -> u32 {
    (FILE_DEVICE_UNKNOWN << 16) | (access << 14) | (function << 2) | METHOD_BUFFERED
}

pub(super) const IOCTL_QUERY_CAPABILITIES: u32 = control_code(0x900, FILE_READ_ACCESS);
pub(super) const IOCTL_CREATE_MONITOR: u32 =
    control_code(0x903, FILE_READ_ACCESS | FILE_WRITE_ACCESS);
pub(super) const IOCTL_REMOVE_MONITOR: u32 =
    control_code(0x904, FILE_READ_ACCESS | FILE_WRITE_ACCESS);
pub(super) const IOCTL_QUERY_HEALTH: u32 = control_code(0x90A, FILE_READ_ACCESS);
pub(super) const IOCTL_QUERY_MONITOR: u32 = control_code(0x90C, FILE_READ_ACCESS);
pub(super) const IOCTL_ADOPT_MONITOR: u32 =
    control_code(0x90D, FILE_READ_ACCESS | FILE_WRITE_ACCESS);

pub(super) const OPERATION_QUERY_CAPABILITIES: u32 = 1;
pub(super) const OPERATION_CREATE_MONITOR: u32 = 4;
pub(super) const OPERATION_REMOVE_MONITOR: u32 = 5;
pub(super) const OPERATION_QUERY_HEALTH: u32 = 12;
pub(super) const OPERATION_QUERY_MONITOR: u32 = 18;
pub(super) const OPERATION_ADOPT_MONITOR: u32 = 20;

pub(super) const STATUS_OK: u32 = 0;
pub(super) const STATE_MONITOR_ACTIVE: u32 = 1 << 0;
pub(super) const STATE_MONITOR_ORPHANED: u32 = 1 << 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct AbiHeader {
    pub magic: u32,
    pub major: u16,
    pub minor: u16,
    pub structure_size: u32,
    pub operation: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct CoreRequest {
    pub header: AbiHeader,
    pub owner_id: u64,
    pub generation: u64,
    pub request_id: u64,
    pub arguments: [u64; 5],
}

impl CoreRequest {
    pub(super) const fn new(operation: u32, generation: u64) -> Self {
        Self {
            header: AbiHeader {
                magic: ABI_MAGIC,
                major: ABI_MAJOR,
                minor: ABI_MINOR,
                structure_size: ABI_REQUEST_SIZE,
                operation,
            },
            owner_id: 0,
            generation,
            request_id: 0,
            arguments: [0; 5],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct CoreResponse {
    pub header: AbiHeader,
    pub status: u32,
    pub reserved: u32,
    pub generation: u64,
    pub values: [u64; 2],
}

impl CoreResponse {
    pub(super) fn validate(self, operation: u32) -> Result<Self, String> {
        if self.header.magic != ABI_MAGIC
            || self.header.major != ABI_MAJOR
            || self.header.minor > ABI_MINOR
            || self.header.structure_size != ABI_RESPONSE_SIZE
            || self.header.operation != operation
        {
            return Err("Windows driver returned an incompatible ABI response".to_owned());
        }
        Ok(self)
    }
}

const _: [(); 16] = [(); size_of::<AbiHeader>()];
const _: [(); 80] = [(); size_of::<CoreRequest>()];
const _: [(); 48] = [(); size_of::<CoreResponse>()];
const _: () = assert!(IOCTL_QUERY_CAPABILITIES == 0x0022_6400);
const _: () = assert!(IOCTL_CREATE_MONITOR == 0x0022_E40C);
const _: () = assert!(IOCTL_REMOVE_MONITOR == 0x0022_E410);
const _: () = assert!(IOCTL_QUERY_HEALTH == 0x0022_6428);
const _: () = assert!(IOCTL_QUERY_MONITOR == 0x0022_6430);
const _: () = assert!(IOCTL_ADOPT_MONITOR == 0x0022_E434);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_layout_and_control_codes_are_stable() {
        let request = CoreRequest::new(OPERATION_CREATE_MONITOR, 7);
        assert_eq!(size_of::<CoreRequest>(), 80);
        assert_eq!(size_of::<CoreResponse>(), 48);
        assert_eq!(request.header.structure_size, 80);
        assert_eq!(request.header.operation, 4);
        assert_eq!(IOCTL_QUERY_CAPABILITIES, 0x0022_6400);
        assert_eq!(IOCTL_CREATE_MONITOR, 0x0022_E40C);
        assert_eq!(IOCTL_REMOVE_MONITOR, 0x0022_E410);
        assert_eq!(IOCTL_QUERY_HEALTH, 0x0022_6428);
        assert_eq!(IOCTL_QUERY_MONITOR, 0x0022_6430);
        assert_eq!(IOCTL_ADOPT_MONITOR, 0x0022_E434);
    }
}
