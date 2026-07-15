use std::net::Ipv6Addr;
use std::time::Duration;

use futures_util::TryStreamExt;
use if_addrs::{get_if_addrs, IfAddr};
use igd_next::PortMappingProtocol;
use rupnp::http::Uri;
use rupnp::ssdp::{SearchTarget, URN};
use rupnp::Service;

use super::mapping::PortMapping;

const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(2);
const LEASE_SECONDS: u32 = 3_600;
const IPV6_FIREWALL: URN = URN::service("schemas-upnp-org", "WANIPv6FirewallControl", 1);

pub(super) struct Ipv6Pinholes {
    device_url: Uri,
    service: Service,
    unique_ids: Vec<String>,
}

pub(super) async fn refresh(
    plan: &[PortMapping],
    active: &mut Option<Ipv6Pinholes>,
) -> Result<(), String> {
    if let Some(pinholes) = active {
        if pinholes.unique_ids.len() == plan.len() && update(pinholes).await.is_ok() {
            return Ok(());
        }
    }
    if let Some(previous) = active.take() {
        remove(previous).await;
    }

    let internal_client = local_ipv6_address()?;
    let search_target = SearchTarget::URN(IPV6_FIREWALL.clone());
    let devices = rupnp::discover(&search_target, DISCOVERY_TIMEOUT, None)
        .await
        .map_err(|error| format!("could not discover an IPv6 firewall service: {error}"))?;
    futures_util::pin_mut!(devices);
    while let Some(device) = devices
        .try_next()
        .await
        .map_err(|error| format!("IPv6 firewall discovery failed: {error}"))?
    {
        let Some(service) = device.find_service(&IPV6_FIREWALL).cloned() else {
            continue;
        };
        let status = service
            .action(device.url(), "GetFirewallStatus", "")
            .await
            .map_err(|error| format!("could not read IPv6 firewall status: {error}"))?;
        if !status
            .get("InboundPinholeAllowed")
            .is_some_and(|value| upnp_boolean(value))
        {
            return Err("the gateway does not allow inbound IPv6 pinholes".to_owned());
        }

        let mut unique_ids = Vec::with_capacity(plan.len());
        let mut failures = Vec::new();
        for mapping in plan {
            let payload = add_payload(internal_client, *mapping);
            match service.action(device.url(), "AddPinhole", &payload).await {
                Ok(response) => match response.get("UniqueID") {
                    Some(unique_id) => unique_ids.push(unique_id.clone()),
                    None => failures.push(format!(
                        "{} {} returned no UniqueID",
                        mapping.protocol, mapping.port
                    )),
                },
                Err(error) => failures.push(format!(
                    "{} {} could not be opened: {error}",
                    mapping.protocol, mapping.port
                )),
            }
        }
        if unique_ids.is_empty() {
            return Err(failures.join("; "));
        }
        *active = Some(Ipv6Pinholes {
            device_url: device.url().clone(),
            service,
            unique_ids,
        });
        return if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("; "))
        };
    }
    Err("no gateway advertised WANIPv6FirewallControl:1".to_owned())
}

pub(super) async fn remove(pinholes: Ipv6Pinholes) {
    for unique_id in pinholes.unique_ids {
        let payload = format!("<UniqueID>{unique_id}</UniqueID>");
        if let Err(error) = pinholes
            .service
            .action(&pinholes.device_url, "DeletePinhole", &payload)
            .await
        {
            eprintln!("Lumen UPnP could not remove IPv6 pinhole {unique_id}: {error}");
        }
    }
}

async fn update(pinholes: &Ipv6Pinholes) -> Result<(), String> {
    for unique_id in &pinholes.unique_ids {
        let payload =
            format!("<UniqueID>{unique_id}</UniqueID><NewLeaseTime>{LEASE_SECONDS}</NewLeaseTime>");
        pinholes
            .service
            .action(&pinholes.device_url, "UpdatePinhole", &payload)
            .await
            .map_err(|error| format!("could not refresh IPv6 pinhole {unique_id}: {error}"))?;
    }
    Ok(())
}

fn local_ipv6_address() -> Result<Ipv6Addr, String> {
    get_if_addrs()
        .map_err(|error| format!("could not enumerate local interfaces: {error}"))?
        .into_iter()
        .filter_map(|interface| match interface.addr {
            IfAddr::V6(address) => Some(address.ip),
            IfAddr::V4(_) => None,
        })
        .find(|address| {
            !address.is_unspecified()
                && !address.is_loopback()
                && !address.is_multicast()
                && !address.is_unicast_link_local()
        })
        .ok_or_else(|| "no routable local IPv6 address is available".to_owned())
}

fn add_payload(internal_client: Ipv6Addr, mapping: PortMapping) -> String {
    format!(
        "<RemoteHost></RemoteHost><RemotePort>0</RemotePort><InternalClient>{internal_client}</InternalClient><InternalPort>{}</InternalPort><Protocol>{}</Protocol><LeaseTime>{LEASE_SECONDS}</LeaseTime>",
        mapping.port,
        protocol_number(mapping.protocol)
    )
}

fn protocol_number(protocol: PortMappingProtocol) -> u8 {
    match protocol {
        PortMappingProtocol::TCP => 6,
        PortMappingProtocol::UDP => 17,
    }
}

fn upnp_boolean(value: &str) -> bool {
    value == "1" || value.eq_ignore_ascii_case("true") || value.eq_ignore_ascii_case("yes")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_mapping_builds_the_standard_ipv6_pinhole_arguments() {
        let mapping = PortMapping {
            protocol: PortMappingProtocol::TCP,
            port: 48_000,
            description: "Lumen test",
        };
        assert_eq!(
            add_payload("2001:db8::23".parse().unwrap(), mapping),
            "<RemoteHost></RemoteHost><RemotePort>0</RemotePort><InternalClient>2001:db8::23</InternalClient><InternalPort>48000</InternalPort><Protocol>6</Protocol><LeaseTime>3600</LeaseTime>"
        );
    }
}
