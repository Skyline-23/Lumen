const HOST_ABI: &str =
    include_str!("../../../../../../engine/lumen-host/src/platform/windows/driver_abi.rs");
const HOST_DRIVER: &str = include_str!(
    "../../../../../../engine/lumen-host/src/platform/windows/native_display_driver.rs"
);
const DRIVER_HEADER: &str = include_str!("../../include/lumen_driver_abi.h");

#[test]
fn host_and_driver_share_the_first_party_guid_layout_and_control_codes() {
    // Given: the independently compiled host boundary and driver public header.
    let shared_markers = [
        "f04b8b5a",
        "a603",
        "4d32",
        "IOCTL_QUERY_CAPABILITIES",
        "IOCTL_CREATE_MONITOR",
        "IOCTL_REMOVE_MONITOR",
        "IOCTL_QUERY_HEALTH",
        "IOCTL_QUERY_MONITOR",
        "IOCTL_ADOPT_MONITOR",
    ];

    // When: stable ABI markers and fixed request sizes are compared.
    let markers_match = shared_markers
        .iter()
        .all(|marker| HOST_ABI.contains(marker) && DRIVER_HEADER.contains(marker));

    // Then: the host sends the first-party 80-byte request and 48-byte response only.
    assert!(markers_match);
    assert!(HOST_ABI.contains("ABI_REQUEST_SIZE: u32 = 80"));
    assert!(HOST_ABI.contains("ABI_RESPONSE_SIZE: u32 = 48"));
    assert!(DRIVER_HEADER.contains("sizeof(LumenDriverCoreRequest) == 80"));
    assert!(DRIVER_HEADER.contains("sizeof(LumenDriverCoreResponse) == 48"));
    assert!(HOST_DRIVER.contains("CreateFileW"));
    assert!(HOST_DRIVER.contains("IOCTL_QUERY_CAPABILITIES"));
    assert!(HOST_DRIVER.contains("IOCTL_QUERY_HEALTH"));
}

#[test]
fn retired_sudovda_contract_is_absent_from_the_host() {
    // Given: the complete first-party host driver boundary.
    let retired = [
        "e5bcc234",
        "VirtualDisplayAddParameters",
        "IOCTL_ADD_VIRTUAL_DISPLAY",
        "IOCTL_GET_PROTOCOL_VERSION",
        "0x0022_2000",
    ];

    // When: retired SudoVDA symbols and codes are searched.
    let present = retired
        .iter()
        .any(|marker| HOST_ABI.contains(marker) || HOST_DRIVER.contains(marker));

    // Then: no retired protocol fragment can be reached by production host code.
    assert!(!present);
}
