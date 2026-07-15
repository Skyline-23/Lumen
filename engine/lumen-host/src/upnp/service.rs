use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use igd_next::{search_gateway, Gateway, SearchOptions};

use super::ipv6;
use super::mapping::{mappings, PortMapping};
use crate::HostArguments;

const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(2);
const REFRESH_INTERVAL: Duration = Duration::from_secs(120);
const LEASE_SECONDS: u32 = 3_600;

#[derive(Default)]
pub(crate) struct UpnpService {
    worker: Option<Worker>,
}

struct Worker {
    shutdown: Sender<()>,
    thread: JoinHandle<()>,
}

struct ActiveMappings {
    gateway: Gateway,
    mappings: Vec<PortMapping>,
}

impl UpnpService {
    pub(crate) fn start(&mut self, arguments: &HostArguments) -> Result<(), String> {
        if self.worker.is_some() {
            return Err("UPnP service is already running".to_owned());
        }
        if arguments.get("upnp") != Some("true") {
            return Ok(());
        }
        let plan = mappings(arguments)?;
        let ipv6_runtime = (arguments.get("address_family") == Some("both"))
            .then(|| {
                tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .map_err(|error| format!("could not create UPnP IPv6 runtime: {error}"))
            })
            .transpose()?;
        let (shutdown, receiver) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("lumen-upnp".to_owned())
            .spawn(move || {
                let mut active = None;
                let mut ipv6_pinholes = None;
                loop {
                    refresh_mappings(&plan, &mut active);
                    if let Some(runtime) = &ipv6_runtime {
                        if let Err(error) =
                            runtime.block_on(ipv6::refresh(&plan, &mut ipv6_pinholes))
                        {
                            eprintln!("Lumen UPnP IPv6 pinhole refresh failed: {error}");
                        }
                    }
                    match receiver.recv_timeout(REFRESH_INTERVAL) {
                        Ok(()) | Err(RecvTimeoutError::Disconnected) => break,
                        Err(RecvTimeoutError::Timeout) => {}
                    }
                }
                if let Some(active) = active {
                    remove_mappings(&active);
                }
                if let (Some(runtime), Some(pinholes)) = (ipv6_runtime, ipv6_pinholes) {
                    runtime.block_on(ipv6::remove(pinholes));
                }
            })
            .map_err(|error| format!("could not start UPnP worker: {error}"))?;
        self.worker = Some(Worker { shutdown, thread });
        Ok(())
    }

    pub(crate) fn stop(&mut self) -> Result<(), String> {
        let Some(worker) = self.worker.take() else {
            return Ok(());
        };
        let _ = worker.shutdown.send(());
        worker
            .thread
            .join()
            .map_err(|_| "UPnP worker panicked".to_owned())
    }
}

impl Drop for UpnpService {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

fn refresh_mappings(plan: &[PortMapping], active: &mut Option<ActiveMappings>) {
    let gateway = match search_gateway(SearchOptions {
        timeout: Some(DISCOVERY_TIMEOUT),
        single_search_timeout: Some(DISCOVERY_TIMEOUT),
        ..Default::default()
    }) {
        Ok(gateway) => gateway,
        Err(error) => {
            eprintln!("Lumen UPnP gateway discovery failed: {error}");
            return;
        }
    };
    let local_ip = match local_ip_for_gateway(&gateway) {
        Ok(address) => address,
        Err(error) => {
            eprintln!("Lumen UPnP local address discovery failed: {error}");
            return;
        }
    };

    if active
        .as_ref()
        .is_some_and(|current| current.gateway.control_url != gateway.control_url)
    {
        if let Some(previous) = active.take() {
            remove_mappings(&previous);
        }
    }

    let mut mapped = active
        .as_ref()
        .map(|current| current.mappings.clone())
        .unwrap_or_default();
    for mapping in plan {
        let local_address = SocketAddr::new(local_ip, mapping.port);
        match add_mapping(&gateway, *mapping, local_address) {
            Ok(()) => {
                if !mapped.contains(mapping) {
                    mapped.push(*mapping);
                }
            }
            Err(error) => eprintln!(
                "Lumen UPnP could not map {} {}: {error}",
                mapping.protocol, mapping.port
            ),
        }
    }
    *active = Some(ActiveMappings {
        gateway,
        mappings: mapped,
    });
}

fn add_mapping(
    gateway: &Gateway,
    mapping: PortMapping,
    local_address: SocketAddr,
) -> Result<(), String> {
    match gateway.add_port(
        mapping.protocol,
        mapping.port,
        local_address,
        LEASE_SECONDS,
        mapping.description,
    ) {
        Ok(()) => Ok(()),
        Err(leased_error) => gateway
            .add_port(
                mapping.protocol,
                mapping.port,
                local_address,
                0,
                mapping.description,
            )
            .map_err(|static_error| {
                format!(
                    "leased mapping failed: {leased_error}; static mapping failed: {static_error}"
                )
            }),
    }
}

fn local_ip_for_gateway(gateway: &Gateway) -> Result<IpAddr, String> {
    let bind_address = match gateway.addr {
        SocketAddr::V4(_) => SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
        SocketAddr::V6(_) => SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0),
    };
    let socket = UdpSocket::bind(bind_address)
        .map_err(|error| format!("could not bind route probe: {error}"))?;
    socket
        .connect(gateway.addr)
        .map_err(|error| format!("could not route to gateway {}: {error}", gateway.addr))?;
    socket
        .local_addr()
        .map(|address| address.ip())
        .map_err(|error| format!("could not read route address: {error}"))
}

fn remove_mappings(active: &ActiveMappings) {
    for mapping in &active.mappings {
        if let Err(error) = active.gateway.remove_port(mapping.protocol, mapping.port) {
            eprintln!(
                "Lumen UPnP could not remove {} {}: {error}",
                mapping.protocol, mapping.port
            );
        }
    }
}
