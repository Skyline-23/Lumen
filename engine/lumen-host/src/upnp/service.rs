use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use igd_next::{search_gateway, Gateway, SearchOptions};

use super::ipv6;
use super::mapping::{mappings, PortMapping};
use crate::{
    HostArguments, IdlePlatformSessionControl, PlatformRuntimeEvent, PlatformRuntimeEventCode,
    PlatformRuntimeEventDisposition, PlatformRuntimeEventSeverity, PlatformSessionControl,
};

const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(2);
const REFRESH_INTERVAL: Duration = Duration::from_secs(120);
const LEASE_SECONDS: u32 = 3_600;
const WARNING_CODES: [PlatformRuntimeEventCode; 5] = [
    PlatformRuntimeEventCode::UpnpGatewayDiscovery,
    PlatformRuntimeEventCode::UpnpLocalAddressDiscovery,
    PlatformRuntimeEventCode::UpnpPortMapping,
    PlatformRuntimeEventCode::UpnpIpv6Pinhole,
    PlatformRuntimeEventCode::UpnpPortRemoval,
];

pub(crate) struct UpnpService {
    worker: Option<Worker>,
    event_sink: Arc<dyn PlatformSessionControl>,
}

impl Default for UpnpService {
    fn default() -> Self {
        Self::with_event_sink(Arc::new(IdlePlatformSessionControl))
    }
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
    pub(crate) fn with_event_sink(event_sink: Arc<dyn PlatformSessionControl>) -> Self {
        Self {
            worker: None,
            event_sink,
        }
    }

    pub(crate) fn start(&mut self, arguments: &HostArguments) -> Result<(), String> {
        if self.worker.is_some() {
            return Err("UPnP service is already running".to_owned());
        }
        if arguments.get("upnp") != Some("true") {
            for code in WARNING_CODES {
                clear_warning(self.event_sink.as_ref(), code);
            }
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
        let event_sink = Arc::clone(&self.event_sink);
        let thread = thread::Builder::new()
            .name("lumen-upnp".to_owned())
            .spawn(move || {
                let mut active = None;
                let mut ipv6_pinholes = None;
                loop {
                    refresh_mappings(&plan, &mut active, event_sink.as_ref());
                    if let Some(runtime) = &ipv6_runtime {
                        match runtime.block_on(ipv6::refresh(&plan, &mut ipv6_pinholes)) {
                            Ok(()) => clear_warning(
                                event_sink.as_ref(),
                                PlatformRuntimeEventCode::UpnpIpv6Pinhole,
                            ),
                            Err(error) => report_warning(
                                event_sink.as_ref(),
                                PlatformRuntimeEventCode::UpnpIpv6Pinhole,
                                format!("Lumen UPnP IPv6 pinhole refresh failed: {error}"),
                            ),
                        }
                    }
                    match receiver.recv_timeout(REFRESH_INTERVAL) {
                        Ok(()) | Err(RecvTimeoutError::Disconnected) => break,
                        Err(RecvTimeoutError::Timeout) => {}
                    }
                }
                if let Some(active) = active {
                    remove_mappings(&active, event_sink.as_ref());
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

fn refresh_mappings(
    plan: &[PortMapping],
    active: &mut Option<ActiveMappings>,
    event_sink: &dyn PlatformSessionControl,
) {
    let gateway = match search_gateway(SearchOptions {
        timeout: Some(DISCOVERY_TIMEOUT),
        single_search_timeout: Some(DISCOVERY_TIMEOUT),
        ..Default::default()
    }) {
        Ok(gateway) => gateway,
        Err(error) => {
            report_warning(
                event_sink,
                PlatformRuntimeEventCode::UpnpGatewayDiscovery,
                format!("Lumen UPnP gateway discovery failed: {error}"),
            );
            return;
        }
    };
    clear_warning(event_sink, PlatformRuntimeEventCode::UpnpGatewayDiscovery);
    let local_ip = match local_ip_for_gateway(&gateway) {
        Ok(address) => address,
        Err(error) => {
            report_warning(
                event_sink,
                PlatformRuntimeEventCode::UpnpLocalAddressDiscovery,
                format!("Lumen UPnP local address discovery failed: {error}"),
            );
            return;
        }
    };
    clear_warning(
        event_sink,
        PlatformRuntimeEventCode::UpnpLocalAddressDiscovery,
    );

    if active
        .as_ref()
        .is_some_and(|current| current.gateway.control_url != gateway.control_url)
    {
        if let Some(previous) = active.take() {
            remove_mappings(&previous, event_sink);
        }
    }

    let mut mapped = active
        .as_ref()
        .map(|current| current.mappings.clone())
        .unwrap_or_default();
    let mut failures = Vec::new();
    for mapping in plan {
        let local_address = SocketAddr::new(local_ip, mapping.port);
        match add_mapping(&gateway, *mapping, local_address) {
            Ok(()) => {
                if !mapped.contains(mapping) {
                    mapped.push(*mapping);
                }
            }
            Err(error) => failures.push(format!(
                "Lumen UPnP could not map {} {}: {error}",
                mapping.protocol, mapping.port
            )),
        }
    }
    if failures.is_empty() {
        clear_warning(event_sink, PlatformRuntimeEventCode::UpnpPortMapping);
    } else {
        report_warning(
            event_sink,
            PlatformRuntimeEventCode::UpnpPortMapping,
            failures.join("; "),
        );
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

fn remove_mappings(active: &ActiveMappings, event_sink: &dyn PlatformSessionControl) {
    let mut failures = Vec::new();
    for mapping in &active.mappings {
        if let Err(error) = active.gateway.remove_port(mapping.protocol, mapping.port) {
            failures.push(format!(
                "Lumen UPnP could not remove {} {}: {error}",
                mapping.protocol, mapping.port
            ));
        }
    }
    if failures.is_empty() {
        clear_warning(event_sink, PlatformRuntimeEventCode::UpnpPortRemoval);
    } else {
        report_warning(
            event_sink,
            PlatformRuntimeEventCode::UpnpPortRemoval,
            failures.join("; "),
        );
    }
}

fn report_warning(
    event_sink: &dyn PlatformSessionControl,
    code: PlatformRuntimeEventCode,
    message: String,
) {
    eprintln!("{message}");
    let _ = event_sink.publish_runtime_event(PlatformRuntimeEvent {
        disposition: PlatformRuntimeEventDisposition::Raised,
        severity: PlatformRuntimeEventSeverity::Warning,
        code,
        message: Some(message),
    });
}

fn clear_warning(event_sink: &dyn PlatformSessionControl, code: PlatformRuntimeEventCode) {
    let _ = event_sink.publish_runtime_event(PlatformRuntimeEvent {
        disposition: PlatformRuntimeEventDisposition::Cleared,
        severity: PlatformRuntimeEventSeverity::Warning,
        code,
        message: None,
    });
}
