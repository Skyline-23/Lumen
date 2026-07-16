use igd_next::PortMappingProtocol;

use crate::network_ports::HostPorts;
use crate::HostArguments;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct PortMapping {
    pub(super) protocol: PortMappingProtocol,
    pub(super) port: u16,
    pub(super) description: &'static str,
}

pub(super) fn mappings(arguments: &HostArguments) -> Result<[PortMapping; 3], String> {
    let ports = HostPorts::from_arguments(arguments)?;
    Ok([
        PortMapping {
            protocol: PortMappingProtocol::TCP,
            port: ports.control_https,
            description: "Lumen - HTTPS Control",
        },
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::tests::valid_arguments_for_runtime_tests;

    #[test]
    fn v3_exposes_https_quic_and_native_media_over_upnp() {
        let mappings = mappings(&valid_arguments_for_runtime_tests()).unwrap();

        assert_eq!(
            mappings,
            [
                PortMapping {
                    protocol: PortMappingProtocol::TCP,
                    port: 47_990,
                    description: "Lumen - HTTPS Control",
                },
                PortMapping {
                    protocol: PortMappingProtocol::UDP,
                    port: 48_010,
                    description: "Lumen - Native Session QUIC",
                },
                PortMapping {
                    protocol: PortMappingProtocol::UDP,
                    port: 47_998,
                    description: "Lumen - Native Media",
                },
            ]
        );
    }
}
