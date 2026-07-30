//! Route-aware synchronous UPnP IGD discovery and fixed port mapping.

#![forbid(unsafe_code)]

use std::fmt;
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::str;
use std::time::{Duration, Instant};

use roxmltree::Document;
use socket2::{Domain, Protocol, Socket, Type};
use url::Url;

const SEARCH_TARGET: &str = "urn:schemas-upnp-org:device:InternetGatewayDevice:1";
const MAX_HTTP_RESPONSE_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PortMappingProtocol {
    Tcp,
    Udp,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PortMappingEntry {
    pub internal_address: SocketAddr,
    pub enabled: bool,
    pub description: String,
    pub lease_duration_seconds: u32,
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
    bind_address: SocketAddr,
    discovery_address: SocketAddr,
    control_url: Url,
    service_type: String,
    timeout: Duration,
}

impl Gateway {
    pub fn bind_address(&self) -> SocketAddr {
        self.bind_address
    }

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

    pub fn port_mapping(
        &self,
        protocol: PortMappingProtocol,
        external_port: u16,
    ) -> Result<Option<PortMappingEntry>, MappingError> {
        if external_port == 0 {
            return Err(MappingError::InvalidPort);
        }
        let body = format!(
            "<NewRemoteHost></NewRemoteHost><NewExternalPort>{external_port}</NewExternalPort><NewProtocol>{protocol}</NewProtocol>"
        );
        match self.soap_action_response("GetSpecificPortMappingEntry", &body) {
            Ok(bytes) => parse_port_mapping_entry(&bytes).map(Some),
            Err(MappingError::Upnp { code: 714, .. }) => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn soap_action(&self, action: &str, body: &str) -> Result<(), MappingError> {
        self.soap_action_response(action, body).map(|_| ())
    }

    fn soap_action_response(&self, action: &str, body: &str) -> Result<Vec<u8>, MappingError> {
        let envelope = format!(
            "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:{action} xmlns:u=\"{}\">{body}</u:{action}></s:Body></s:Envelope>",
            self.service_type,
        );
        let soap_action = format!("\"{}#{action}\"", self.service_type);
        let response = http_request(
            &self.control_url,
            "POST",
            &[
                ("Content-Type", "text/xml; charset=\"utf-8\""),
                ("SOAPAction", soap_action.as_str()),
            ],
            envelope.as_bytes(),
            self.bind_address.ip(),
            self.timeout,
        )
        .map_err(MappingError::Transport)?;
        if (200..300).contains(&response.status) {
            return Ok(response.body);
        }
        Err(parse_mapping_fault(response.status, &response.body))
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
    InvalidResponse(String),
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
            Self::InvalidResponse(message) => {
                write!(
                    formatter,
                    "gateway returned an invalid mapping response: {message}"
                )
            }
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
        .send_to(
            search_request(options.discovery_address).as_bytes(),
            options.discovery_address,
        )
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
        return gateway_from_description(
            options.bind_address,
            options.discovery_address,
            location,
            options.timeout,
        );
    }
    Err(DiscoveryError::Timeout)
}

fn gateway_from_description(
    bind_address: SocketAddr,
    discovery_address: SocketAddr,
    location: Url,
    timeout: Duration,
) -> Result<Gateway, DiscoveryError> {
    let response = http_request(&location, "GET", &[], &[], bind_address.ip(), timeout)
        .map_err(DiscoveryError::Http)?;
    if !(200..300).contains(&response.status) {
        return Err(DiscoveryError::Http(format!(
            "gateway returned HTTP status {}",
            response.status
        )));
    }
    let (service_type, control_path) = parse_igd_service(&response.body)?;
    let control_url = location
        .join(&control_path)
        .map_err(|error| DiscoveryError::InvalidResponse(error.to_string()))?;
    Ok(Gateway {
        bind_address,
        discovery_address,
        control_url,
        service_type,
        timeout,
    })
}

#[derive(Debug)]
struct HttpResponse {
    status: u16,
    body: Vec<u8>,
}

fn http_request(
    url: &Url,
    method: &str,
    headers: &[(&str, &str)],
    body: &[u8],
    bind_ip: IpAddr,
    timeout: Duration,
) -> Result<HttpResponse, String> {
    if url.scheme() != "http" {
        return Err(format!("unsupported gateway URL scheme: {}", url.scheme()));
    }
    let host = url
        .host_str()
        .ok_or_else(|| "gateway URL has no host".to_owned())?;
    let port = url
        .port_or_known_default()
        .ok_or_else(|| "gateway URL has no port".to_owned())?;
    let remote_address = (host, port)
        .to_socket_addrs()
        .map_err(|error| error.to_string())?
        .find(|address| address.is_ipv4() == bind_ip.is_ipv4())
        .ok_or_else(|| "gateway host has no address matching the selected LAN route".to_owned())?;

    let socket = Socket::new(
        Domain::for_address(remote_address),
        Type::STREAM,
        Some(Protocol::TCP),
    )
    .map_err(|error| error.to_string())?;
    socket
        .bind(&SocketAddr::new(bind_ip, 0).into())
        .map_err(|error| format!("could not bind gateway request to {bind_ip}: {error}"))?;
    socket
        .connect_timeout(&remote_address.into(), timeout)
        .map_err(|error| error.to_string())?;
    let mut stream = TcpStream::from(socket);
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|error| error.to_string())?;

    let mut target = if url.path().is_empty() {
        "/".to_owned()
    } else {
        url.path().to_owned()
    };
    if let Some(query) = url.query() {
        target.push('?');
        target.push_str(query);
    }
    let host_header = match url.host() {
        Some(url::Host::Ipv6(address)) => format!("[{address}]"),
        Some(host) => host.to_string(),
        None => return Err("gateway URL has no host".to_owned()),
    };
    let host_header = if url.port().is_some() {
        format!("{host_header}:{port}")
    } else {
        host_header
    };
    write!(
        stream,
        "{method} {target} HTTP/1.1\r\nHost: {host_header}\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    )
    .map_err(|error| error.to_string())?;
    for (name, value) in headers {
        write!(stream, "{name}: {value}\r\n").map_err(|error| error.to_string())?;
    }
    stream
        .write_all(b"\r\n")
        .and_then(|()| stream.write_all(body))
        .map_err(|error| error.to_string())?;

    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 8_192];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                bytes.extend_from_slice(&buffer[..read]);
                if bytes.len() as u64 > MAX_HTTP_RESPONSE_BYTES {
                    return Err("gateway HTTP response exceeded 2 MiB".to_owned());
                }
                if http_response_is_complete(&bytes)? {
                    break;
                }
            }
            Err(error)
                if error.kind() == std::io::ErrorKind::ConnectionReset && !bytes.is_empty() =>
            {
                break;
            }
            Err(error) => return Err(error.to_string()),
        }
    }
    parse_http_response(bytes)
}

fn http_response_is_complete(bytes: &[u8]) -> Result<bool, String> {
    let Some(header_end) = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|position| position + 4)
    else {
        return Ok(false);
    };
    let headers = str::from_utf8(&bytes[..header_end])
        .map_err(|error| format!("gateway returned invalid HTTP headers: {error}"))?;
    reject_unsupported_transfer_encoding(headers)?;
    let Some(content_length) = header_value(headers, "content-length") else {
        return Ok(false);
    };
    let content_length = content_length
        .parse::<usize>()
        .map_err(|error| format!("gateway returned an invalid content length: {error}"))?;
    Ok(bytes.len().saturating_sub(header_end) >= content_length)
}

fn parse_http_response(bytes: Vec<u8>) -> Result<HttpResponse, String> {
    let header_end = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|position| position + 4)
        .ok_or_else(|| "gateway returned an incomplete HTTP response".to_owned())?;
    let headers = str::from_utf8(&bytes[..header_end])
        .map_err(|error| format!("gateway returned invalid HTTP headers: {error}"))?;
    reject_unsupported_transfer_encoding(headers)?;
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| "gateway returned an invalid HTTP status line".to_owned())?;
    let body = bytes[header_end..].to_vec();
    let content_length = header_value(headers, "content-length")
        .map(|value| value.parse::<usize>())
        .transpose()
        .map_err(|error| format!("gateway returned an invalid content length: {error}"))?;
    if let Some(content_length) = content_length {
        if body.len() < content_length {
            return Err("gateway returned a truncated HTTP body".to_owned());
        }
        return Ok(HttpResponse {
            status,
            body: body[..content_length].to_vec(),
        });
    }
    Ok(HttpResponse { status, body })
}

fn reject_unsupported_transfer_encoding(headers: &str) -> Result<(), String> {
    if let Some(encoding) = header_value(headers, "transfer-encoding") {
        if !encoding.eq_ignore_ascii_case("identity") {
            return Err(format!(
                "gateway returned unsupported HTTP transfer encoding: {encoding}"
            ));
        }
    }
    Ok(())
}

fn search_request(discovery_address: SocketAddr) -> String {
    format!(
        "M-SEARCH * HTTP/1.1\r\nHOST: {discovery_address}\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: {SEARCH_TARGET}\r\n\r\n"
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

fn parse_port_mapping_entry(bytes: &[u8]) -> Result<PortMappingEntry, MappingError> {
    let text =
        str::from_utf8(bytes).map_err(|error| MappingError::InvalidResponse(error.to_string()))?;
    let document =
        Document::parse(text).map_err(|error| MappingError::InvalidResponse(error.to_string()))?;
    let value = |name: &str| {
        document
            .descendants()
            .find(|node| node.is_element() && node.tag_name().name() == name)
            .and_then(|node| node.text())
            .map(str::trim)
    };
    let internal_port = value("NewInternalPort")
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|port| *port != 0)
        .ok_or_else(|| MappingError::InvalidResponse("missing internal port".to_owned()))?;
    let internal_ip = value("NewInternalClient")
        .and_then(|value| value.parse::<IpAddr>().ok())
        .ok_or_else(|| MappingError::InvalidResponse("missing internal client".to_owned()))?;
    let enabled = match value("NewEnabled") {
        Some("1" | "true" | "yes") => true,
        Some("0" | "false" | "no") => false,
        _ => {
            return Err(MappingError::InvalidResponse(
                "missing enabled state".to_owned(),
            ))
        }
    };
    let description = value("NewPortMappingDescription")
        .unwrap_or_default()
        .to_owned();
    let lease_duration_seconds = value("NewLeaseDuration")
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(|| MappingError::InvalidResponse("missing lease duration".to_owned()))?;
    Ok(PortMappingEntry {
        internal_address: SocketAddr::new(internal_ip, internal_port),
        enabled,
        description,
        lease_duration_seconds,
    })
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
        #[cfg(target_os = "macos")]
        let selected_local_ip = Ipv4Addr::LOCALHOST;
        #[cfg(not(target_os = "macos"))]
        let selected_local_ip = Ipv4Addr::new(127, 0, 0, 2);
        let http_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let http_address = http_listener.local_addr().unwrap();
        let discovery_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let discovery_address = discovery_socket.local_addr().unwrap();

        let discovery_thread = thread::spawn(move || {
            let mut request = [0_u8; 2_048];
            let (read, peer) = discovery_socket.recv_from(&mut request).unwrap();
            let request = str::from_utf8(&request[..read]).unwrap();
            assert!(request.starts_with("M-SEARCH * HTTP/1.1"));
            assert!(request.contains(&format!("HOST: {discovery_address}")));
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
            for index in 0..4 {
                let (mut stream, peer) = http_listener.accept().unwrap();
                assert_eq!(peer.ip(), IpAddr::V4(selected_local_ip));
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut request = Vec::new();
                let mut buffer = [0_u8; 8_192];
                loop {
                    let read = stream.read(&mut buffer).unwrap();
                    request.extend_from_slice(&buffer[..read]);
                    if http_response_is_complete(&request).unwrap() {
                        break;
                    }
                }
                requests.push(String::from_utf8_lossy(&request).into_owned());
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
                } else if index == 2 {
                    let mapping = r#"<?xml version="1.0"?>
                        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
                          <u:GetSpecificPortMappingEntryResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
                            <NewInternalPort>48990</NewInternalPort>
                            <NewInternalClient>127.0.0.1</NewInternalClient>
                            <NewEnabled>1</NewEnabled>
                            <NewPortMappingDescription>Lumen &amp; HTTPS</NewPortMappingDescription>
                            <NewLeaseDuration>600</NewLeaseDuration>
                          </u:GetSpecificPortMappingEntryResponse>
                        </s:Body></s:Envelope>"#;
                    stream
                        .write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{mapping}",
                                mapping.len()
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

        let local_ip = IpAddr::V4(selected_local_ip);
        let gateway = discover_gateway(DiscoveryOptions {
            bind_address: SocketAddr::new(local_ip, 0),
            discovery_address,
            timeout: Duration::from_secs(2),
        })
        .unwrap();
        assert_eq!(gateway.bind_address(), SocketAddr::new(local_ip, 0));
        gateway
            .add_port(
                PortMappingProtocol::Tcp,
                48_990,
                SocketAddr::new(local_ip, 48_990),
                600,
                "Lumen & HTTPS",
            )
            .unwrap();
        assert_eq!(
            gateway
                .port_mapping(PortMappingProtocol::Tcp, 48_990)
                .unwrap(),
            Some(PortMappingEntry {
                internal_address: SocketAddr::new(local_ip, 48_990),
                enabled: true,
                description: "Lumen & HTTPS".to_owned(),
                lease_duration_seconds: 600,
            })
        );
        gateway
            .remove_port(PortMappingProtocol::Tcp, 48_990)
            .unwrap();

        discovery_thread.join().unwrap();
        let requests = http_thread.join().unwrap();
        assert!(
            requests[0].starts_with("GET /root.xml HTTP/1.1"),
            "unexpected request: {}",
            requests[0]
        );
        assert!(requests[1].contains("AddPortMapping"));
        assert!(requests[1].contains("<NewInternalClient>127.0.0.1</NewInternalClient>"));
        assert!(requests[1].contains("Lumen &amp; HTTPS"));
        assert!(requests[2].contains("GetSpecificPortMappingEntry"));
        assert!(requests[3].contains("DeletePortMapping"));
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
    fn parses_specific_mapping_entry_for_reconciliation_verification() {
        let response = br#"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetSpecificPortMappingEntryResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"><NewInternalPort>48010</NewInternalPort><NewInternalClient>192.168.0.52</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>Lumen - Native Session QUIC</NewPortMappingDescription><NewLeaseDuration>3596</NewLeaseDuration></u:GetSpecificPortMappingEntryResponse></s:Body></s:Envelope>"#;

        assert_eq!(
            parse_port_mapping_entry(response).unwrap(),
            PortMappingEntry {
                internal_address: "192.168.0.52:48010".parse().unwrap(),
                enabled: true,
                description: "Lumen - Native Session QUIC".to_owned(),
                lease_duration_seconds: 3_596,
            }
        );
    }

    #[test]
    fn missing_specific_mapping_is_a_normal_absent_result() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            let mut buffer = [0_u8; 8_192];
            loop {
                let read = stream.read(&mut buffer).unwrap();
                request.extend_from_slice(&buffer[..read]);
                if http_response_is_complete(&request).unwrap() {
                    break;
                }
            }
            assert!(String::from_utf8_lossy(&request).contains("GetSpecificPortMappingEntry"));
            let fault = r#"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>714</errorCode><errorDescription>NoSuchEntryInArray</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"#;
            stream
                .write_all(
                    format!(
                        "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{fault}",
                        fault.len()
                    )
                    .as_bytes(),
                )
                .unwrap();
        });
        let gateway = Gateway {
            bind_address: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
            discovery_address: address,
            control_url: Url::parse(&format!("http://{address}/control")).unwrap(),
            service_type: "urn:schemas-upnp-org:service:WANIPConnection:1".to_owned(),
            timeout: Duration::from_secs(2),
        };

        assert_eq!(
            gateway
                .port_mapping(PortMappingProtocol::Tcp, 47_990)
                .unwrap(),
            None
        );
        server.join().unwrap();
    }

    #[test]
    fn escapes_user_visible_mapping_descriptions() {
        assert_eq!(
            escape_xml("A&B <control> \"quoted\""),
            "A&amp;B &lt;control&gt; &quot;quoted&quot;"
        );
    }

    #[test]
    fn rejects_unsupported_chunked_gateway_responses() {
        let response =
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n";

        assert_eq!(
            parse_http_response(response.to_vec()).unwrap_err(),
            "gateway returned unsupported HTTP transfer encoding: chunked"
        );
    }
}
