use std::fs::File;
use std::io::{self, BufReader};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use rustls::pki_types::PrivateKeyDer;
use rustls::{ServerConfig, ServerConnection, StreamOwned};

use super::http::{bad_request, internal_error, read_request, write_response};
use super::{NativeControlTransport, ServerSurface, SharedControlRouter};
use crate::network_ports::CONTROL_HTTPS_OFFSET;
use crate::HostArguments;

const CONNECTION_TIMEOUT: Duration = Duration::from_secs(2);
const SERVER_START_TIMEOUT: Duration = Duration::from_secs(2);
const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(10);
const CONNECTION_WORKERS: usize = 4;
const PENDING_CONNECTIONS: usize = 16;

#[derive(Default)]
pub struct TlsControlTransport {
    server: Option<ServerHandle>,
}

impl NativeControlTransport for TlsControlTransport {
    fn start(
        &mut self,
        arguments: &HostArguments,
        router: SharedControlRouter,
    ) -> Result<(), String> {
        start_transport(&mut self.server, arguments, router, ServerSurface::Control)
    }

    fn stop(&mut self) -> Result<(), String> {
        stop_transport(&mut self.server, ServerSurface::Control)
    }
}

impl Drop for TlsControlTransport {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

struct ServerHandle {
    local_address: SocketAddr,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

fn start_transport(
    server: &mut Option<ServerHandle>,
    arguments: &HostArguments,
    router: SharedControlRouter,
    surface: ServerSurface,
) -> Result<(), String> {
    if server.is_some() {
        return Err(format!(
            "TLS {} server is already running",
            surface_name(surface)
        ));
    }
    let address = server_address(arguments, surface)?;
    let tls = load_server_config(
        required_path(arguments, "cert")?,
        required_path(arguments, "pkey")?,
    )?;
    let listener = TcpListener::bind(address).map_err(|error| {
        format!(
            "could not bind TLS {} server at {address}: {error}",
            surface_name(surface)
        )
    })?;
    listener.set_nonblocking(true).map_err(|error| {
        format!(
            "could not make TLS {} listener nonblocking: {error}",
            surface_name(surface)
        )
    })?;
    let local_address = listener.local_addr().map_err(|error| {
        format!(
            "could not read TLS {} listener address: {error}",
            surface_name(surface)
        )
    })?;
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let (ready, ready_result) = mpsc::sync_channel(1);
    let thread = thread::Builder::new()
        .name(format!("lumen-{}-tls", surface_name(surface)))
        .spawn(move || run_server(listener, tls, router, surface, thread_stop, ready))
        .map_err(|error| {
            format!(
                "could not start TLS {} server: {error}",
                surface_name(surface)
            )
        })?;
    match ready_result.recv_timeout(SERVER_START_TIMEOUT) {
        Ok(Ok(())) => {}
        Ok(Err(error)) => {
            stop.store(true, Ordering::Release);
            wake_listener(local_address);
            let _ = thread.join();
            return Err(error);
        }
        Err(_) => {
            stop.store(true, Ordering::Release);
            wake_listener(local_address);
            let _ = thread.join();
            return Err(format!(
                "TLS {} server did not become ready",
                surface_name(surface)
            ));
        }
    }
    *server = Some(ServerHandle {
        local_address,
        stop,
        thread: Some(thread),
    });
    Ok(())
}

fn stop_transport(server: &mut Option<ServerHandle>, surface: ServerSurface) -> Result<(), String> {
    let Some(mut server) = server.take() else {
        return Ok(());
    };
    server.stop.store(true, Ordering::Release);
    wake_listener(server.local_address);
    if let Some(thread) = server.thread.take() {
        thread
            .join()
            .map_err(|_| format!("TLS {} server thread panicked", surface_name(surface)))?;
    }
    Ok(())
}

fn run_server(
    listener: TcpListener,
    tls: Arc<ServerConfig>,
    router: SharedControlRouter,
    surface: ServerSurface,
    stop: Arc<AtomicBool>,
    ready: mpsc::SyncSender<Result<(), String>>,
) {
    let (connections, receiver) = mpsc::sync_channel(PENDING_CONNECTIONS);
    let receiver = Arc::new(Mutex::new(receiver));
    let mut workers = Vec::with_capacity(CONNECTION_WORKERS);
    for index in 0..CONNECTION_WORKERS {
        let receiver = Arc::clone(&receiver);
        let tls = Arc::clone(&tls);
        let router = Arc::clone(&router);
        let worker_stop = Arc::clone(&stop);
        match thread::Builder::new()
            .name(format!("lumen-{}-tls-{index}", surface_name(surface)))
            .spawn(move || connection_worker(receiver, tls, router, surface, worker_stop))
        {
            Ok(worker) => workers.push(worker),
            Err(error) => {
                stop.store(true, Ordering::Release);
                drop(connections);
                for worker in workers {
                    let _ = worker.join();
                }
                let _ = ready.send(Err(format!("could not start TLS control worker: {error}")));
                return;
            }
        }
    }
    if ready.send(Ok(())).is_err() {
        stop.store(true, Ordering::Release);
    }
    while !stop.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, _peer)) => {
                if stream.set_nonblocking(false).is_ok() {
                    match connections.try_send(stream) {
                        Ok(()) => {}
                        Err(TrySendError::Full(_)) => {}
                        Err(TrySendError::Disconnected(_)) => break,
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL_INTERVAL);
            }
            Err(_) => thread::sleep(ACCEPT_POLL_INTERVAL),
        }
    }
    drop(connections);
    for worker in workers {
        let _ = worker.join();
    }
}

fn connection_worker(
    connections: Arc<Mutex<mpsc::Receiver<TcpStream>>>,
    tls: Arc<ServerConfig>,
    router: SharedControlRouter,
    surface: ServerSurface,
    stop: Arc<AtomicBool>,
) {
    while !stop.load(Ordering::Acquire) {
        let stream = match connections.lock() {
            Ok(receiver) => receiver.recv(),
            Err(_) => return,
        };
        match stream {
            Ok(stream) if !stop.load(Ordering::Acquire) => {
                handle_connection(stream, Arc::clone(&tls), &router, surface);
            }
            Ok(_) | Err(_) => return,
        }
    }
}

fn handle_connection(
    stream: TcpStream,
    tls: Arc<ServerConfig>,
    router: &SharedControlRouter,
    surface: ServerSurface,
) {
    let _ = stream.set_read_timeout(Some(CONNECTION_TIMEOUT));
    let _ = stream.set_write_timeout(Some(CONNECTION_TIMEOUT));
    let Ok(connection) = ServerConnection::new(tls) else {
        return;
    };
    let mut stream = StreamOwned::new(connection, stream);
    let response = match read_request(&mut stream) {
        Ok(request) => match router.lock() {
            Ok(mut router) => match surface {
                ServerSurface::Control => router.dispatch(&request),
            },
            Err(_) => internal_error(),
        },
        Err(super::http::HttpReadError::InvalidRequest(message)) => bad_request(message),
        Err(super::http::HttpReadError::Io(_)) => return,
    };
    let _ = write_response(&mut stream, &response);
}

fn server_address(arguments: &HostArguments, surface: ServerSurface) -> Result<SocketAddr, String> {
    let base_port = arguments
        .get("port")
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| format!("TLS {} base port is invalid", surface_name(surface)))?;
    let port = match surface {
        ServerSurface::Control => base_port
            .checked_add(CONTROL_HTTPS_OFFSET)
            .ok_or_else(|| "TLS control port overflowed".to_owned())?,
    };
    let address = match arguments.get("address_family") {
        Some("ipv4") => IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        Some("both") => IpAddr::V6(Ipv6Addr::UNSPECIFIED),
        _ => {
            return Err(format!(
                "TLS {} address family is invalid",
                surface_name(surface)
            ))
        }
    };
    Ok(SocketAddr::new(address, port))
}

fn surface_name(surface: ServerSurface) -> &'static str {
    match surface {
        ServerSurface::Control => "control",
    }
}

fn required_path(arguments: &HostArguments, key: &'static str) -> Result<PathBuf, String> {
    arguments
        .get(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| format!("TLS {key} path is missing"))
}

fn load_server_config(cert_path: PathBuf, key_path: PathBuf) -> Result<Arc<ServerConfig>, String> {
    let mut cert_reader = BufReader::new(File::open(&cert_path).map_err(|error| {
        format!(
            "could not open TLS certificate {}: {error}",
            cert_path.display()
        )
    })?);
    let certificates = rustls_pemfile::certs(&mut cert_reader)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| {
            format!(
                "could not parse TLS certificate {}: {error}",
                cert_path.display()
            )
        })?;
    if certificates.is_empty() {
        return Err(format!(
            "TLS certificate {} contains no certificates",
            cert_path.display()
        ));
    }
    let key = load_private_key(&key_path)?;
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certificates, key)
        .map_err(|error| format!("TLS certificate and private key do not match: {error}"))?;
    Ok(Arc::new(config))
}

fn load_private_key(path: &Path) -> Result<PrivateKeyDer<'static>, String> {
    let mut reader =
        BufReader::new(File::open(path).map_err(|error| {
            format!("could not open TLS private key {}: {error}", path.display())
        })?);
    rustls_pemfile::private_key(&mut reader)
        .map_err(|error| {
            format!(
                "could not parse TLS private key {}: {error}",
                path.display()
            )
        })?
        .ok_or_else(|| {
            format!(
                "TLS private key {} contains no supported key",
                path.display()
            )
        })
}

fn wake_listener(address: SocketAddr) {
    let loopback = match address {
        SocketAddr::V4(address) => SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), address.port()),
        SocketAddr::V6(address) => SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), address.port()),
    };
    let _ = TcpStream::connect_timeout(&loopback, Duration::from_millis(50));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derives_the_control_port_and_requested_address_family() {
        let ipv4 = arguments_with("address_family", "ipv4");
        assert_eq!(
            server_address(&ipv4, ServerSurface::Control).unwrap(),
            SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 47_990)
        );
        let both = arguments_with("address_family", "both");
        assert_eq!(
            server_address(&both, ServerSurface::Control).unwrap(),
            SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 47_990)
        );
    }

    #[test]
    fn rejects_missing_or_malformed_tls_material() {
        let root = tempfile::tempdir().unwrap();
        let cert = root.path().join("cert.pem");
        let key = root.path().join("key.pem");
        std::fs::write(&cert, "not a certificate").unwrap();
        std::fs::write(&key, "not a key").unwrap();
        assert!(load_server_config(cert, key).is_err());
    }

    fn arguments_with(key: &str, replacement: &str) -> HostArguments {
        let mut values = crate::config::tests::valid_arguments();
        let value = values
            .iter_mut()
            .find(|value| value.starts_with(&format!("{key}=")))
            .unwrap();
        *value = format!("{key}={replacement}");
        HostArguments::parse(values).unwrap()
    }
}
