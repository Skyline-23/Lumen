use std::collections::HashMap;
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
        let instance = instance_name(&snapshot.settings.general.host_name);
        let hostname = format!("{}.local.", dns_label(&instance));
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
            "",
            ports.native_session_quic,
            properties,
        )
        .map_err(|error| format!("could not describe mDNS service: {error}"))?
        .enable_addr_auto();
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
