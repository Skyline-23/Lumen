use std::net::{IpAddr, SocketAddr};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use lumen_upnp::{discover_gateway, DiscoveryOptions, Gateway, MappingError};

use super::ipv6;
use super::mapping::{mappings, PortMapping};
use crate::{
    discovery::preferred_multicast_lan_ipv4_route, HostArguments, IdlePlatformSessionControl,
    PlatformRuntimeEvent, PlatformRuntimeEventCode, PlatformRuntimeEventDisposition,
    PlatformRuntimeEventSeverity, PlatformSessionControl,
};

const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(2);
const REFRESH_INTERVAL: Duration = Duration::from_secs(120);
const FAILURE_BACKOFF: [Duration; 6] = [
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(5),
    Duration::from_secs(10),
    Duration::from_secs(30),
    Duration::from_secs(60),
];
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MappingRefreshOutcome {
    Ready {
        local_ip: IpAddr,
        gateway_ip: IpAddr,
    },
    Retry,
}

#[derive(Default)]
struct ReconciliationSchedule {
    consecutive_failures: usize,
    was_ready: bool,
}

struct ReconciliationDecision {
    delay: Duration,
    became_ready: bool,
}

enum AddMappingAttemptError {
    PortInUse,
    Other(String),
}

impl ReconciliationSchedule {
    fn record(&mut self, outcome: MappingRefreshOutcome) -> ReconciliationDecision {
        match outcome {
            MappingRefreshOutcome::Ready { .. } => {
                let became_ready = !self.was_ready;
                self.was_ready = true;
                self.consecutive_failures = 0;
                ReconciliationDecision {
                    delay: REFRESH_INTERVAL,
                    became_ready,
                }
            }
            MappingRefreshOutcome::Retry => {
                self.was_ready = false;
                let delay = FAILURE_BACKOFF[self
                    .consecutive_failures
                    .min(FAILURE_BACKOFF.len().saturating_sub(1))];
                self.consecutive_failures = self.consecutive_failures.saturating_add(1);
                ReconciliationDecision {
                    delay,
                    became_ready: false,
                }
            }
        }
    }
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
                let mut schedule = ReconciliationSchedule::default();
                loop {
                    let outcome = refresh_mappings(&plan, &mut active, event_sink.as_ref());
                    let decision = schedule.record(outcome);
                    if decision.became_ready {
                        let MappingRefreshOutcome::Ready {
                            local_ip,
                            gateway_ip,
                        } = outcome
                        else {
                            unreachable!("ready transition requires a ready outcome")
                        };
                        eprintln!(
                            "Lumen UPnP reconciliation ready local-address={local_ip} gateway-address={gateway_ip} mappings={} refresh-seconds={}",
                            mapping_summary(&plan),
                            REFRESH_INTERVAL.as_secs()
                        );
                    }
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
                    match receiver.recv_timeout(decision.delay) {
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
) -> MappingRefreshOutcome {
    let Some(route) = preferred_multicast_lan_ipv4_route() else {
        report_warning(
            event_sink,
            PlatformRuntimeEventCode::UpnpLocalAddressDiscovery,
            "Lumen UPnP route discovery failed: no routable multicast LAN interface with a gateway is ready"
                .to_owned(),
        );
        return MappingRefreshOutcome::Retry;
    };
    clear_warning(
        event_sink,
        PlatformRuntimeEventCode::UpnpLocalAddressDiscovery,
    );
    let local_ip = IpAddr::V4(route.local_address);
    let gateway = match discover_gateway(DiscoveryOptions {
        bind_address: SocketAddr::new(local_ip, 0),
        discovery_address: SocketAddr::new(IpAddr::V4(route.gateway_address), 1900),
        timeout: DISCOVERY_TIMEOUT,
    }) {
        Ok(gateway) => gateway,
        Err(error) => {
            report_warning(
                event_sink,
                PlatformRuntimeEventCode::UpnpGatewayDiscovery,
                format!("Lumen UPnP gateway discovery failed: {error}"),
            );
            return MappingRefreshOutcome::Retry;
        }
    };
    clear_warning(event_sink, PlatformRuntimeEventCode::UpnpGatewayDiscovery);

    if active
        .as_ref()
        .is_some_and(|current| current.gateway.control_url() != gateway.control_url())
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
    if failures.is_empty() {
        MappingRefreshOutcome::Ready {
            local_ip,
            gateway_ip: IpAddr::V4(route.gateway_address),
        }
    } else {
        MappingRefreshOutcome::Retry
    }
}

fn add_mapping(
    gateway: &Gateway,
    mapping: PortMapping,
    local_address: SocketAddr,
) -> Result<(), String> {
    match add_mapping_with_lease_fallback(gateway, mapping, local_address) {
        Ok(()) => Ok(()),
        Err(AddMappingAttemptError::PortInUse) => {
            gateway
                .remove_port(mapping.protocol, mapping.port)
                .map_err(|error| {
                    format!(
                        "conflicting mapping could not be removed before reconciliation: {error}"
                    )
                })?;
            add_mapping_with_lease_fallback(gateway, mapping, local_address).map_err(|error| {
                format!(
                    "mapping remained unavailable after stale ownership removal: {}",
                    error.message()
                )
            })
        }
        Err(AddMappingAttemptError::Other(error)) => Err(error),
    }
}

fn add_mapping_with_lease_fallback(
    gateway: &Gateway,
    mapping: PortMapping,
    local_address: SocketAddr,
) -> Result<(), AddMappingAttemptError> {
    match gateway.add_port(
        mapping.protocol,
        mapping.port,
        local_address,
        LEASE_SECONDS,
        mapping.description,
    ) {
        Ok(()) => Ok(()),
        Err(leased_error) => match gateway.add_port(
            mapping.protocol,
            mapping.port,
            local_address,
            0,
            mapping.description,
        ) {
            Ok(()) => Ok(()),
            Err(static_error) => match (&leased_error, &static_error) {
                (MappingError::PortInUse, _) | (_, MappingError::PortInUse) => {
                    Err(AddMappingAttemptError::PortInUse)
                }
                _ => Err(AddMappingAttemptError::Other(format!(
                    "leased mapping failed: {leased_error}; static mapping failed: {static_error}"
                ))),
            },
        },
    }
}

impl AddMappingAttemptError {
    fn message(&self) -> String {
        match self {
            Self::PortInUse => "port is still owned by another mapping".to_owned(),
            Self::Other(message) => message.clone(),
        }
    }
}

fn mapping_summary(plan: &[PortMapping]) -> String {
    plan.iter()
        .map(|mapping| format!("{} {}", mapping.protocol, mapping.port))
        .collect::<Vec<_>>()
        .join(",")
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transient_route_failure_reconciles_quickly_then_returns_to_lease_refresh() {
        let mut schedule = ReconciliationSchedule::default();

        let first = schedule.record(MappingRefreshOutcome::Retry);
        let second = schedule.record(MappingRefreshOutcome::Retry);
        let recovered = schedule.record(MappingRefreshOutcome::Ready {
            local_ip: "192.168.0.51".parse().unwrap(),
            gateway_ip: "192.168.0.1".parse().unwrap(),
        });
        let steady = schedule.record(MappingRefreshOutcome::Ready {
            local_ip: "192.168.0.51".parse().unwrap(),
            gateway_ip: "192.168.0.1".parse().unwrap(),
        });

        assert_eq!(first.delay, Duration::from_secs(1));
        assert_eq!(second.delay, Duration::from_secs(2));
        assert_eq!(recovered.delay, REFRESH_INTERVAL);
        assert!(recovered.became_ready);
        assert_eq!(steady.delay, REFRESH_INTERVAL);
        assert!(!steady.became_ready);
    }

    #[test]
    fn repeated_route_failure_is_bounded_without_a_busy_loop() {
        let mut schedule = ReconciliationSchedule::default();
        let delays = (0..10)
            .map(|_| schedule.record(MappingRefreshOutcome::Retry).delay)
            .collect::<Vec<_>>();

        assert_eq!(
            delays,
            vec![
                Duration::from_secs(1),
                Duration::from_secs(2),
                Duration::from_secs(5),
                Duration::from_secs(10),
                Duration::from_secs(30),
                Duration::from_secs(60),
                Duration::from_secs(60),
                Duration::from_secs(60),
                Duration::from_secs(60),
                Duration::from_secs(60),
            ]
        );
    }
}
