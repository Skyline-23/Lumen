use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Duration;

use mdns_sd::{ServiceDaemon, ServiceInfo};

use crate::network_ports::HostPorts;
use crate::{HostArguments, HostAuthorities};

const SERVICE_TYPE: &str = "_lumen._udp.local.";
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Default)]
pub(crate) struct MdnsService {
    active: Option<ActiveService>,
}

struct ActiveService {
    daemon: ServiceDaemon,
    fullname: String,
}

impl MdnsService {
    pub(crate) fn start(
        &mut self,
        arguments: &HostArguments,
        authorities: &HostAuthorities,
    ) -> Result<(), String> {
        if self.active.is_some() {
            return Err("mDNS service is already running".to_owned());
        }
        if arguments.get("enable_discovery") != Some("true") {
            return Ok(());
        }

        let ports = HostPorts::from_arguments(arguments)?;
        let snapshot = authorities.settings().snapshot();
        let instance = instance_name(&snapshot.settings.general.name);
        let hostname = format!("{}.local.", dns_label(&instance));
        let addresses = advertised_addresses_from_interfaces(
            netdev::get_interfaces(),
            arguments.get("address_family").unwrap_or("ipv4"),
        );
        if addresses.is_empty() {
            return Err("no multicast LAN interface has a routable address".to_owned());
        }
        let mut properties = HashMap::from([
            ("protocol-major".to_owned(), "2".to_owned()),
            (
                "quic-port".to_owned(),
                ports.native_session_quic.to_string(),
            ),
            ("media-port".to_owned(), ports.native_media_udp.to_string()),
            ("control-port".to_owned(), ports.control_https.to_string()),
            (
                "host-identity".to_owned(),
                authorities.host_identity().unique_id().to_owned(),
            ),
            ("enrollment-required".to_owned(), "true".to_owned()),
        ]);
        if let Some(authority_host) = authorities.host_identity().authority_host() {
            properties.insert("authority-host".to_owned(), authority_host.to_owned());
        }
        let service = ServiceInfo::new(
            SERVICE_TYPE,
            &instance,
            &hostname,
            &addresses[..],
            ports.native_session_quic,
            properties,
        )
        .map_err(|error| format!("could not describe mDNS service: {error}"))?;
        let fullname = service.get_fullname().to_owned();
        let daemon = ServiceDaemon::new()
            .map_err(|error| format!("could not create mDNS daemon: {error}"))?;
        daemon
            .register(service)
            .map_err(|error| format!("could not register mDNS service: {error}"))?;
        self.active = Some(ActiveService { daemon, fullname });
        Ok(())
    }

    pub(crate) fn stop(&mut self) -> Result<(), String> {
        let Some(active) = self.active.take() else {
            return Ok(());
        };
        let mut failures = Vec::new();
        match active.daemon.unregister(&active.fullname) {
            Ok(receiver) => {
                if receiver.recv_timeout(SHUTDOWN_TIMEOUT).is_err() {
                    failures.push("mDNS service did not confirm unregistration".to_owned());
                }
            }
            Err(error) => failures.push(format!("could not unregister mDNS service: {error}")),
        }
        match active.daemon.shutdown() {
            Ok(receiver) => {
                if receiver.recv_timeout(SHUTDOWN_TIMEOUT).is_err() {
                    failures.push("mDNS daemon did not confirm shutdown".to_owned());
                }
            }
            Err(error) => failures.push(format!("could not stop mDNS daemon: {error}")),
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("; "))
        }
    }
}

impl Drop for MdnsService {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

fn advertised_addresses_from_interfaces(
    interfaces: Vec<netdev::Interface>,
    address_family: &str,
) -> Vec<IpAddr> {
    let mut candidates = interfaces
        .into_iter()
        .filter(|interface| {
            interface.is_up()
                && interface.is_running()
                && interface.is_multicast()
                && !interface.is_loopback()
                && !interface.is_point_to_point()
        })
        .filter_map(|interface| {
            let addresses = advertised_addresses(&interface, address_family);
            (!addresses.is_empty()).then_some((interface.name, addresses))
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| left.0.cmp(&right.0));
    candidates
        .into_iter()
        .next()
        .map(|(_, addresses)| addresses)
        .unwrap_or_default()
}

pub(crate) fn preferred_multicast_lan_ipv4_address() -> Option<Ipv4Addr> {
    preferred_multicast_lan_ipv4_address_from_interfaces(netdev::get_interfaces())
}

fn preferred_multicast_lan_ipv4_address_from_interfaces(
    interfaces: Vec<netdev::Interface>,
) -> Option<Ipv4Addr> {
    advertised_addresses_from_interfaces(interfaces, "ipv4")
        .into_iter()
        .find_map(|address| match address {
            IpAddr::V4(address) => Some(address),
            IpAddr::V6(_) => None,
        })
}

fn advertised_addresses(interface: &netdev::Interface, address_family: &str) -> Vec<IpAddr> {
    let mut addresses = interface
        .ipv4
        .iter()
        .map(|network| network.addr())
        .filter(|address| is_routable_ipv4(*address))
        .map(IpAddr::V4)
        .collect::<Vec<_>>();
    if address_family == "both" {
        addresses.extend(
            interface
                .ipv6
                .iter()
                .map(|network| network.addr())
                .filter(|address| is_routable_ipv6(*address))
                .map(IpAddr::V6),
        );
    }
    addresses
}

fn is_routable_ipv4(address: Ipv4Addr) -> bool {
    !address.is_loopback()
        && !address.is_link_local()
        && !address.is_unspecified()
        && !address.is_multicast()
        && address != Ipv4Addr::BROADCAST
}

fn is_routable_ipv6(address: Ipv6Addr) -> bool {
    !address.is_loopback()
        && !address.is_unicast_link_local()
        && !address.is_unspecified()
        && !address.is_multicast()
}

fn instance_name(hostname: &str) -> String {
    let mut output = String::with_capacity(hostname.len().min(63));
    for byte in hostname.bytes().take(63) {
        match byte {
            b' ' => output.push('-'),
            b'-' | b'0'..=b'9' | b'A'..=b'Z' | b'a'..=b'z' => output.push(char::from(byte)),
            _ => break,
        }
    }
    if output.is_empty() {
        "Lumen".to_owned()
    } else {
        output
    }
}

fn dns_label(instance: &str) -> String {
    let label = instance.trim_matches('-');
    if label.is_empty() {
        "lumen".to_owned()
    } else {
        label.to_ascii_lowercase()
    }
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    #[cfg(not(target_os = "windows"))]
    use netdev::interface::flags::IFF_RUNNING;
    use netdev::interface::flags::{IFF_MULTICAST, IFF_POINTOPOINT, IFF_UP};
    use netdev::ipnet::{Ipv4Net, Ipv6Net};

    use super::*;

    fn active_multicast_flags() -> u32 {
        let flags = (IFF_UP | IFF_MULTICAST) as u32;
        #[cfg(target_os = "windows")]
        {
            flags
        }
        #[cfg(not(target_os = "windows"))]
        {
            flags | IFF_RUNNING as u32
        }
    }

    #[test]
    fn filters_non_routable_addresses_from_an_interface() {
        let mut interface = netdev::Interface::dummy();
        interface.ipv4 = vec![
            Ipv4Net::new(Ipv4Addr::LOCALHOST, 8).unwrap(),
            Ipv4Net::new(Ipv4Addr::new(169, 254, 1, 2), 16).unwrap(),
            Ipv4Net::new(Ipv4Addr::new(192, 168, 0, 51), 24).unwrap(),
        ];
        interface.ipv6 = vec![
            Ipv6Net::new(Ipv6Addr::LOCALHOST, 128).unwrap(),
            Ipv6Net::new("fe80::1".parse().unwrap(), 64).unwrap(),
            Ipv6Net::new("fd00::51".parse().unwrap(), 64).unwrap(),
        ];

        assert_eq!(
            advertised_addresses(&interface, "ipv4"),
            [IpAddr::V4(Ipv4Addr::new(192, 168, 0, 51))]
        );
        assert_eq!(
            advertised_addresses(&interface, "both"),
            [
                IpAddr::V4(Ipv4Addr::new(192, 168, 0, 51)),
                IpAddr::V6("fd00::51".parse().unwrap()),
            ]
        );
    }

    #[test]
    fn prefers_a_multicast_lan_interface_over_the_default_tunnel() {
        let mut tunnel = netdev::Interface::dummy();
        tunnel.name = "utun7".to_owned();
        tunnel.flags = active_multicast_flags() | IFF_POINTOPOINT as u32;
        tunnel.ipv4 = vec![Ipv4Net::new(Ipv4Addr::new(100, 85, 138, 127), 32).unwrap()];

        let mut lan = netdev::Interface::dummy();
        lan.name = "en0".to_owned();
        lan.flags = active_multicast_flags();
        lan.ipv4 = vec![Ipv4Net::new(Ipv4Addr::new(192, 168, 0, 51), 24).unwrap()];

        assert_eq!(
            advertised_addresses_from_interfaces(vec![tunnel.clone(), lan.clone()], "ipv4"),
            [IpAddr::V4(Ipv4Addr::new(192, 168, 0, 51))]
        );
        assert_eq!(
            preferred_multicast_lan_ipv4_address_from_interfaces(vec![tunnel, lan]),
            Some(Ipv4Addr::new(192, 168, 0, 51))
        );
    }
}
