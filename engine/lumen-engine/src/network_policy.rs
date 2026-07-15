use std::ffi::{c_char, CStr};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::str::FromStr;

use crate::LumenEngineStatus;

pub const NETWORK_PC: u32 = 0;
pub const NETWORK_LAN: u32 = 1;
pub const NETWORK_WAN: u32 = 2;

fn classify_ipv4(address: Ipv4Addr) -> u32 {
    let octets = address.octets();
    if address.is_loopback() {
        NETWORK_PC
    } else if address.is_private()
        || address.is_link_local()
        || (octets[0] == 100 && (64..=127).contains(&octets[1]))
    {
        NETWORK_LAN
    } else {
        NETWORK_WAN
    }
}

fn classify_ipv6(address: Ipv6Addr) -> u32 {
    if let Some(mapped) = address.to_ipv4_mapped() {
        return classify_ipv4(mapped);
    }
    let segments = address.segments();
    if address.is_loopback() {
        NETWORK_PC
    } else if segments[0] & 0xfe00 == 0xfc00
        || (segments[0] == 0xfe80 && segments[1] == 0 && segments[2] == 0 && segments[3] == 0)
    {
        NETWORK_LAN
    } else {
        NETWORK_WAN
    }
}

fn classify_address(address: &str) -> u32 {
    let without_scope = address.split_once('%').map_or(address, |(host, _)| host);
    match IpAddr::from_str(without_scope) {
        Ok(IpAddr::V4(address)) => classify_ipv4(address),
        Ok(IpAddr::V6(address)) => classify_ipv6(address),
        Err(_) => NETWORK_WAN,
    }
}

pub fn classify_network_address(address: IpAddr) -> u32 {
    match address {
        IpAddr::V4(address) => classify_ipv4(address),
        IpAddr::V6(address) => classify_ipv6(address),
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_classify_network_address(
    address: *const c_char,
    network_out: *mut u32,
) -> LumenEngineStatus {
    let Some(address) = NonNull::new(address.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut network_out) = NonNull::new(network_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        let address = unsafe { CStr::from_ptr(address.as_ptr()) }
            .to_str()
            .map_err(|_| LumenEngineStatus::InvalidArgument)?;
        Ok::<u32, LumenEngineStatus>(classify_address(address))
    })) {
        Ok(Ok(network)) => {
            unsafe { *network_out.as_mut() = network };
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_pc_lan_and_wan_ipv4_ranges() {
        for address in ["127.0.0.1", "127.255.255.254"] {
            assert_eq!(classify_address(address), NETWORK_PC);
        }
        for address in [
            "10.0.0.1",
            "172.31.255.254",
            "192.168.1.1",
            "100.64.0.1",
            "100.127.255.254",
            "169.254.1.1",
        ] {
            assert_eq!(classify_address(address), NETWORK_LAN, "{address}");
        }
        for address in ["8.8.8.8", "100.128.0.1", "invalid"] {
            assert_eq!(classify_address(address), NETWORK_WAN, "{address}");
        }
    }

    #[test]
    fn classifies_ipv6_scopes_and_mapped_ipv4() {
        assert_eq!(classify_address("::1"), NETWORK_PC);
        assert_eq!(classify_address("fc00::1"), NETWORK_LAN);
        assert_eq!(classify_address("fdff::1"), NETWORK_LAN);
        assert_eq!(classify_address("fe80::1%en0"), NETWORK_LAN);
        assert_eq!(classify_address("fe80:0:0:1::1"), NETWORK_WAN);
        assert_eq!(classify_address("febf::1"), NETWORK_WAN);
        assert_eq!(classify_address("::ffff:192.168.1.2"), NETWORK_LAN);
        assert_eq!(classify_address("2001:4860:4860::8888"), NETWORK_WAN);
    }
}
