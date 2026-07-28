use lumen_upnp::PortMappingProtocol;

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
            protocol: PortMappingProtocol::Tcp,
            port: ports.control_https,
            description: "Lumen - HTTPS Control",
        },
        PortMapping {
            protocol: PortMappingProtocol::Udp,
            port: ports.native_session_quic,
            description: "Lumen - Native Session QUIC",
        },
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::tests::valid_arguments_for_runtime_tests;

    #[test]
    fn v4_exposes_only_https_and_quic_over_upnp() {
        let mappings = mappings(&valid_arguments_for_runtime_tests()).unwrap();

        assert_eq!(
            mappings,
            [
                PortMapping {
                    protocol: PortMappingProtocol::Tcp,
                    port: 47_990,
                    description: "Lumen - HTTPS Control",
                },
                PortMapping {
                    protocol: PortMappingProtocol::Udp,
                    port: 48_010,
                    description: "Lumen - Native Session QUIC",
                },
            ]
        );
    }
}
