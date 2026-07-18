//! Route-aware synchronous UPnP IGD discovery and fixed port mapping.

#![forbid(unsafe_code)]

use std::fmt;
use std::net::{SocketAddr, UdpSocket};
use std::str;
use std::time::{Duration, Instant};

use attohttpc::{Method, RequestBuilder};
use roxmltree::Document;
use url::Url;

const SEARCH_TARGET: &str = "urn:schemas-upnp-org:device:InternetGatewayDevice:1";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PortMappingProtocol {
    Tcp,
    Udp,
}

impl fmt::Display for PortMappingProtocol {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Tcp => "TCP",
            Self::Udp => "UDP",
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiscoveryOptions {
    pub bind_address: SocketAddr,
    pub discovery_address: SocketAddr,
    pub timeout: Duration,
}

#[derive(Clone, Debug)]
pub struct Gateway {
    discovery_address: SocketAddr,
    control_url: Url,
    service_type: String,
    timeout: Duration,
}

impl Gateway {
    pub fn discovery_address(&self) -> SocketAddr {
        self.discovery_address
    }

    pub fn control_url(&self) -> &Url {
        &self.control_url
    }

    pub fn service_type(&self) -> &str {
        &self.service_type
    }

    pub fn add_port(
        &self,
        protocol: PortMappingProtocol,
        external_port: u16,
        internal_address: SocketAddr,
        lease_duration_seconds: u32,
        description: &str,
    ) -> Result<(), MappingError> {
        if external_port == 0 || internal_address.port() == 0 {
            return Err(MappingError::InvalidPort);
        }
        let body = format!(
            "<NewRemoteHost></NewRemoteHost><NewExternalPort>{external_port}</NewExternalPort><NewProtocol>{protocol}</NewProtocol><NewInternalPort>{}</NewInternalPort><NewInternalClient>{}</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>{}</NewPortMappingDescription><NewLeaseDuration>{lease_duration_seconds}</NewLeaseDuration>",
            internal_address.port(),
            internal_address.ip(),
            escape_xml(description),
        );
        self.soap_action("AddPortMapping", &body)
    }

    pub fn remove_port(
        &self,
        protocol: PortMappingProtocol,
        external_port: u16,
    ) -> Result<(), MappingError> {
        if external_port == 0 {
            return Err(MappingError::InvalidPort);
        }
        match self.soap_action(
            "DeletePortMapping",
            &format!(
                "<NewRemoteHost></NewRemoteHost><NewExternalPort>{external_port}</NewExternalPort><NewProtocol>{protocol}</NewProtocol>"
            ),
        ) {
            Err(MappingError::Upnp { code: 714, .. }) => Ok(()),
            result => result,
        }
    }

    fn soap_action(&self, action: &str, body: &str) -> Result<(), MappingError> {
        let envelope = format!(
            "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:{action} xmlns:u=\"{}\">{body}</u:{action}></s:Body></s:Envelope>",
            self.service_type,
        );
        let response = RequestBuilder::try_new(Method::POST, self.control_url.clone())
            .map_err(|error| MappingError::Transport(error.to_string()))?
            .timeout(self.timeout)
            .header("Content-Type", "text/xml; charset=\"utf-8\"")
            .header("SOAPAction", format!("\"{}#{action}\"", self.service_type))
            .text(envelope)
            .send()
            .map_err(|error| MappingError::Transport(error.to_string()))?;
        let success = response.is_success();
        let status = response.status().as_u16();
        let bytes = response
            .bytes()
            .map_err(|error| MappingError::Transport(error.to_string()))?;
        if success {
            return Ok(());
        }
        Err(parse_mapping_fault(status, &bytes))
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum DiscoveryError {
    Io(String),
    Timeout,
    InvalidResponse(String),
    Http(String),
    MissingIgdService,
}

impl fmt::Display for DiscoveryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(message) => write!(formatter, "I/O error: {message}"),
            Self::Timeout => formatter.write_str("gateway discovery timed out"),
            Self::InvalidResponse(message) => write!(formatter, "invalid SSDP response: {message}"),
            Self::Http(message) => {
                write!(formatter, "gateway description request failed: {message}")
            }
            Self::MissingIgdService => {
                formatter.write_str("gateway description has no WAN connection service")
            }
        }
    }
}

impl std::error::Error for DiscoveryError {}

#[derive(Debug, Eq, PartialEq)]
pub enum MappingError {
    InvalidPort,
    PortInUse,
    Upnp { code: u32, description: String },
    HttpStatus(u16),
    Transport(String),
}

impl fmt::Display for MappingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPort => formatter.write_str("port zero is invalid"),
            Self::PortInUse => formatter.write_str("port is already owned by another mapping"),
            Self::Upnp { code, description } => {
                write!(formatter, "UPnP error {code}: {description}")
            }
            Self::HttpStatus(status) => write!(formatter, "gateway returned HTTP status {status}"),
            Self::Transport(message) => write!(formatter, "gateway transport failed: {message}"),
        }
    }
}

impl std::error::Error for MappingError {}

pub fn discover_gateway(options: DiscoveryOptions) -> Result<Gateway, DiscoveryError> {
    let socket = UdpSocket::bind(options.bind_address)
        .map_err(|error| DiscoveryError::Io(error.to_string()))?;
    socket
        .set_read_timeout(Some(options.timeout))
        .map_err(|error| DiscoveryError::Io(error.to_string()))?;
    socket
        .send_to(search_request().as_bytes(), options.discovery_address)
        .map_err(|error| DiscoveryError::Io(error.to_string()))?;

    let started = Instant::now();
    let mut buffer = [0_u8; 2_048];
    while started.elapsed() < options.timeout {
        let remaining = options.timeout.saturating_sub(started.elapsed());
        socket
            .set_read_timeout(Some(remaining))
            .map_err(|error| DiscoveryError::Io(error.to_string()))?;
        let (read, peer) = match socket.recv_from(&mut buffer) {
            Ok(response) => response,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return Err(DiscoveryError::Timeout)
            }
            Err(error) => return Err(DiscoveryError::Io(error.to_string())),
        };
        if peer.ip() != options.discovery_address.ip() {
            continue;
        }
        let response = str::from_utf8(&buffer[..read])
            .map_err(|error| DiscoveryError::InvalidResponse(error.to_string()))?;
        let Some(location) = header_value(response, "location") else {
            continue;
        };
        let location = Url::parse(location)
            .map_err(|error| DiscoveryError::InvalidResponse(error.to_string()))?;
        return gateway_from_description(options.discovery_address, location, options.timeout);
    }
    Err(DiscoveryError::Timeout)
}

fn gateway_from_description(
    discovery_address: SocketAddr,
    location: Url,
    timeout: Duration,
) -> Result<Gateway, DiscoveryError> {
    let response = RequestBuilder::try_new(Method::GET, location.clone())
        .map_err(|error| DiscoveryError::Http(error.to_string()))?
        .timeout(timeout)
        .send()
        .map_err(|error| DiscoveryError::Http(error.to_string()))?
        .error_for_status()
        .map_err(|error| DiscoveryError::Http(error.to_string()))?;
    let bytes = response
        .bytes()
        .map_err(|error| DiscoveryError::Http(error.to_string()))?;
    let (service_type, control_path) = parse_igd_service(&bytes)?;
    let control_url = location
        .join(&control_path)
        .map_err(|error| DiscoveryError::InvalidResponse(error.to_string()))?;
    Ok(Gateway {
        discovery_address,
        control_url,
        service_type,
        timeout,
    })
}

fn search_request() -> String {
    format!(
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: {SEARCH_TARGET}\r\n\r\n"
    )
}

fn header_value<'a>(response: &'a str, name: &str) -> Option<&'a str> {
    response.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.trim().eq_ignore_ascii_case(name).then(|| value.trim())
    })
}

fn parse_igd_service(bytes: &[u8]) -> Result<(String, String), DiscoveryError> {
    let text = str::from_utf8(bytes)
        .map_err(|error| DiscoveryError::InvalidResponse(error.to_string()))?;
    let document = Document::parse(text)
        .map_err(|error| DiscoveryError::InvalidResponse(error.to_string()))?;
    for service in document
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "service")
    {
        let service_type = child_text(service, "serviceType");
        let control_url = child_text(service, "controlURL");
        if let (Some(service_type), Some(control_url)) = (service_type, control_url) {
            if service_type.contains(":service:WANIPConnection:")
                || service_type.contains(":service:WANPPPConnection:")
            {
                return Ok((service_type.to_owned(), control_url.to_owned()));
            }
        }
    }
    Err(DiscoveryError::MissingIgdService)
}

fn child_text<'a, 'input>(node: roxmltree::Node<'a, 'input>, name: &str) -> Option<&'a str> {
    node.children()
        .find(|child| child.is_element() && child.tag_name().name() == name)
        .and_then(|child| child.text())
        .map(str::trim)
}

fn parse_mapping_fault(status: u16, bytes: &[u8]) -> MappingError {
    let Ok(text) = str::from_utf8(bytes) else {
        return MappingError::HttpStatus(status);
    };
    let Ok(document) = Document::parse(text) else {
        return MappingError::HttpStatus(status);
    };
    let code = document
        .descendants()
        .find(|node| node.is_element() && node.tag_name().name() == "errorCode")
        .and_then(|node| node.text())
        .and_then(|value| value.trim().parse::<u32>().ok());
    let description = document
        .descendants()
        .find(|node| node.is_element() && node.tag_name().name() == "errorDescription")
        .and_then(|node| node.text())
        .map(str::trim)
        .unwrap_or("unknown UPnP error")
        .to_owned();
    match code {
        Some(718) => MappingError::PortInUse,
        Some(code) => MappingError::Upnp { code, description },
        None => MappingError::HttpStatus(status),
    }
}

fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::{IpAddr, Ipv4Addr, TcpListener};
    use std::thread;

    use super::*;

    const ROOT_DESCRIPTION: &str = r#"<?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device><serviceList><service>
            <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
            <controlURL>/upnp/control/WANIPConn1</controlURL>
          </service></serviceList></device>
        </root>"#;

    #[test]
    fn discovers_and_maps_through_an_explicit_unicast_gateway_route() {
        let http_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let http_address = http_listener.local_addr().unwrap();
        let discovery_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let discovery_address = discovery_socket.local_addr().unwrap();

        let discovery_thread = thread::spawn(move || {
            let mut request = [0_u8; 2_048];
            let (read, peer) = discovery_socket.recv_from(&mut request).unwrap();
            let request = str::from_utf8(&request[..read]).unwrap();
            assert!(request.starts_with("M-SEARCH * HTTP/1.1"));
            discovery_socket
                .send_to(
                    format!(
                        "HTTP/1.1 200 OK\r\nLOCATION: http://{http_address}/root.xml\r\nST: {SEARCH_TARGET}\r\n\r\n"
                    )
                    .as_bytes(),
                    peer,
                )
                .unwrap();
        });
        let http_thread = thread::spawn(move || {
            let mut requests = Vec::new();
            for index in 0..3 {
                let (mut stream, _) = http_listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut request = [0_u8; 8_192];
                let read = stream.read(&mut request).unwrap();
                requests.push(String::from_utf8_lossy(&request[..read]).into_owned());
                if index == 0 {
                    stream
                        .write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{ROOT_DESCRIPTION}",
                                ROOT_DESCRIPTION.len()
                            )
                            .as_bytes(),
                        )
                        .unwrap();
                } else {
                    stream
                        .write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        )
                        .unwrap();
                }
            }
            requests
        });

        let local_ip = IpAddr::V4(Ipv4Addr::LOCALHOST);
        let gateway = discover_gateway(DiscoveryOptions {
            bind_address: SocketAddr::new(local_ip, 0),
            discovery_address,
            timeout: Duration::from_secs(2),
        })
        .unwrap();
        gateway
            .add_port(
                PortMappingProtocol::Tcp,
                48_990,
                SocketAddr::new(local_ip, 48_990),
                600,
                "Lumen & HTTPS",
            )
            .unwrap();
        gateway
            .remove_port(PortMappingProtocol::Tcp, 48_990)
            .unwrap();

        discovery_thread.join().unwrap();
        let requests = http_thread.join().unwrap();
        assert!(requests[0].starts_with("GET /root.xml HTTP/1.1"));
        assert!(requests[1].contains("AddPortMapping"));
        assert!(requests[1].contains("<NewInternalClient>127.0.0.1</NewInternalClient>"));
        assert!(requests[1].contains("Lumen &amp; HTTPS"));
        assert!(requests[2].contains("DeletePortMapping"));
    }

    #[test]
    fn parses_wan_ip_connection_and_resolves_relative_control_url() {
        assert_eq!(
            parse_igd_service(ROOT_DESCRIPTION.as_bytes()).unwrap(),
            (
                "urn:schemas-upnp-org:service:WANIPConnection:1".to_owned(),
                "/upnp/control/WANIPConn1".to_owned(),
            )
        );
    }

    #[test]
    fn extracts_case_insensitive_ssdp_location() {
        let response = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.0.1:1900/root.xml\r\n\r\n";
        assert_eq!(
            header_value(response, "location"),
            Some("http://192.168.0.1:1900/root.xml")
        );
    }

    #[test]
    fn maps_conflict_fault_to_typed_port_in_use() {
        let fault = br#"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>718</errorCode><errorDescription>ConflictInMappingEntry</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"#;
        assert_eq!(parse_mapping_fault(500, fault), MappingError::PortInUse);
    }

    #[test]
    fn escapes_user_visible_mapping_descriptions() {
        assert_eq!(
            escape_xml("A&B <control> \"quoted\""),
            "A&amp;B &lt;control&gt; &quot;quoted&quot;"
        );
    }
}
