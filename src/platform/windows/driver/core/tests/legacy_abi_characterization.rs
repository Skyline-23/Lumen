use std::mem::size_of;

const LEGACY_SOURCE: &str =
    include_str!("../../../../../../engine/lumen-host/src/platform/windows/native_display.rs");

#[repr(C)]
struct LegacyVersion {
    major: u8,
    minor: u8,
    incremental: u8,
    test_build: u8,
}

#[repr(C)]
struct LegacyAddMonitor {
    width: u32,
    height: u32,
    refresh_millihertz: u32,
    monitor_guid: [u8; 16],
    device_name: [i8; 14],
    serial_number: [i8; 14],
}

#[repr(C)]
struct LegacyRemoveMonitor {
    monitor_guid: [u8; 16],
}

#[repr(C)]
struct LegacyAddMonitorOutput {
    adapter_luid: [u32; 2],
    target_id: u32,
}

const fn legacy_control_code(function: u32) -> u32 {
    (0x22 << 16) | (function << 2)
}

#[test]
fn characterizes_sudovda_shaped_layout_and_version() {
    // Given: the current external-driver client contract.
    let version = LegacyVersion {
        major: 0,
        minor: 2,
        incremental: 1,
        test_build: 1,
    };

    // When: its layout and control codes are observed without changing production code.
    let ioctl_add = legacy_control_code(0x800);
    let ioctl_remove = legacy_control_code(0x801);
    let ioctl_version = legacy_control_code(0x8ff);

    // Then: replacement work starts from the exact retired ABI rather than an inference.
    assert_eq!(
        [
            version.major,
            version.minor,
            version.incremental,
            version.test_build
        ],
        [0, 2, 1, 1]
    );
    assert_eq!(size_of::<LegacyVersion>(), 4);
    assert_eq!(size_of::<LegacyAddMonitor>(), 56);
    assert_eq!(size_of::<LegacyRemoveMonitor>(), 16);
    assert_eq!(size_of::<LegacyAddMonitorOutput>(), 12);
    assert_eq!(
        [ioctl_add, ioctl_remove, ioctl_version],
        [0x0022_2000, 0x0022_2004, 0x0022_23fc]
    );
}

#[test]
fn characterizes_existing_process_local_ownership_and_shared_open() {
    // Given: the current client's ownership and CreateFile contract.
    // When: the source-level boundary is characterized before it is replaced.
    // Then: it has one process-local active monitor but permits shared driver handles.
    assert!(LEGACY_SOURCE.contains("active: Mutex<Option<ActiveDisplay>>"));
    assert!(LEGACY_SOURCE.contains("if active.is_some()"));
    assert!(LEGACY_SOURCE.contains("FILE_SHARE_READ | FILE_SHARE_WRITE"));
}
