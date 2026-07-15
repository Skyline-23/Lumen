use netdev::Interface;

const AUTOMATIC_WAKE_UDP_PORT: u16 = 9;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum WakeOnLanCapability {
    Unsupported,
    Supported {
        mac_address: MacAddress,
        udp_port: u16,
    },
}

impl WakeOnLanCapability {
    pub(super) fn detect() -> Self {
        if let Some(capability) = netdev::get_default_interface()
            .ok()
            .and_then(Self::from_interface)
        {
            return capability;
        }
        let mut candidates = netdev::get_interfaces()
            .into_iter()
            .filter_map(Self::from_interface);
        match (candidates.next(), candidates.next()) {
            (Some(capability), None) => capability,
            (None, _) | (Some(_), Some(_)) => Self::Unsupported,
        }
    }

    fn from_interface(interface: Interface) -> Option<Self> {
        if !interface.is_physical() || !interface.is_running() {
            return None;
        }
        let address = interface.mac_addr?;
        let mac_address = MacAddress::new(address.octets())?;
        Some(Self::Supported {
            mac_address,
            udp_port: AUTOMATIC_WAKE_UDP_PORT,
        })
    }

    #[cfg(test)]
    pub(super) fn test_supported(octets: [u8; 6]) -> Self {
        Self::Supported {
            mac_address: MacAddress::new(octets).expect("test MAC address must be unicast"),
            udp_port: AUTOMATIC_WAKE_UDP_PORT,
        }
    }

    pub(super) fn descriptor(&self) -> WakeOnLanDescriptor<'_> {
        match self {
            Self::Unsupported => WakeOnLanDescriptor {
                supported: false,
                mac_address: None,
                udp_port: None,
            },
            Self::Supported {
                mac_address,
                udp_port,
            } => WakeOnLanDescriptor {
                supported: true,
                mac_address: Some(&mac_address.0),
                udp_port: Some(*udp_port),
            },
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct MacAddress(String);

impl MacAddress {
    fn new(octets: [u8; 6]) -> Option<Self> {
        if octets == [0; 6] || octets[0] & 1 != 0 {
            return None;
        }
        Some(Self(format!(
            "{:02X}:{:02X}:{:02X}:{:02X}:{:02X}:{:02X}",
            octets[0], octets[1], octets[2], octets[3], octets[4], octets[5]
        )))
    }
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WakeOnLanDescriptor<'a> {
    supported: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    mac_address: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    udp_port: Option<u16>,
}
