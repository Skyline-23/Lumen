use igd_next::PortMappingProtocol;

use crate::network_ports::HostPorts;
use crate::HostArguments;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct PortMapping {
    pub(super) protocol: PortMappingProtocol,
    pub(super) port: u16,
    pub(super) description: &'static str,
}

pub(super) fn mappings(arguments: &HostArguments) -> Result<[PortMapping; 2], String> {
    let ports = HostPorts::from_arguments(arguments)?;
    Ok([
        PortMapping {
            protocol: PortMappingProtocol::UDP,
            port: ports.native_session_quic,
            description: "Lumen - Native Session QUIC",
        },
        PortMapping {
            protocol: PortMappingProtocol::UDP,
            port: ports.native_media_udp,
            description: "Lumen - Native Media",
        },
    ])
}
