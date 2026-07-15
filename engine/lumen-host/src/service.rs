use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::discovery::MdnsService;
use crate::upnp::UpnpService;
use crate::{
    ControlRouter, HostArguments, HostAuthorities, HostAuthorityPaths, HostDiscoveryState,
    HostService, IdleControlTransport, IdlePlatformSessionControl, NativeControlTransport,
    PlatformSessionControl, QuicSessionTransport, TlsControlTransport,
};

pub trait NativeStreamControl {
    fn start(
        &mut self,
        arguments: &HostArguments,
        router: Arc<Mutex<ControlRouter>>,
        platform: Arc<dyn PlatformSessionControl>,
    ) -> Result<(), String>;
    fn force_stop(&mut self) -> Result<(), String>;
    fn stop(&mut self) -> Result<(), String>;
}

#[derive(Default)]
pub struct IdleStreamControl;

impl NativeStreamControl for IdleStreamControl {
    fn start(
        &mut self,
        _arguments: &HostArguments,
        _router: Arc<Mutex<ControlRouter>>,
        _platform: Arc<dyn PlatformSessionControl>,
    ) -> Result<(), String> {
        Ok(())
    }

    fn force_stop(&mut self) -> Result<(), String> {
        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        Ok(())
    }
}

pub struct NativeHostService<Stream = IdleStreamControl, Control = IdleControlTransport> {
    router: Option<Arc<Mutex<ControlRouter>>>,
    stream: Stream,
    control: Control,
    platform: Arc<dyn PlatformSessionControl>,
    mdns: MdnsService,
    upnp: UpnpService,
}

impl Default for NativeHostService<IdleStreamControl, IdleControlTransport> {
    fn default() -> Self {
        Self::with_stream_control(IdleStreamControl)
    }
}

impl NativeHostService<QuicSessionTransport, TlsControlTransport> {
    pub fn production() -> Self {
        Self::with_transports(
            QuicSessionTransport::default(),
            TlsControlTransport::default(),
        )
    }

    pub fn production_with_platform(platform: Arc<dyn PlatformSessionControl>) -> Self {
        Self::with_transports_and_platform(
            QuicSessionTransport::default(),
            TlsControlTransport::default(),
            platform,
        )
    }
}

impl<Stream> NativeHostService<Stream, IdleControlTransport> {
    pub fn with_stream_control(stream: Stream) -> Self {
        Self::with_transports(stream, IdleControlTransport)
    }
}

impl<Stream, Control> NativeHostService<Stream, Control> {
    pub fn with_transports(stream: Stream, control: Control) -> Self {
        Self::with_transports_and_platform(stream, control, Arc::new(IdlePlatformSessionControl))
    }

    pub fn with_transports_and_platform(
        stream: Stream,
        control: Control,
        platform: Arc<dyn PlatformSessionControl>,
    ) -> Self {
        let upnp = UpnpService::with_event_sink(Arc::clone(&platform));
        Self {
            router: None,
            stream,
            control,
            platform,
            mdns: MdnsService::default(),
            upnp,
        }
    }

    pub fn router(&self) -> Option<MutexGuard<'_, ControlRouter>> {
        self.router.as_ref()?.lock().ok()
    }

    pub fn router_mut(&self) -> Option<MutexGuard<'_, ControlRouter>> {
        self.router()
    }

    pub fn stream_control(&self) -> &Stream {
        &self.stream
    }

    pub fn control_transport(&self) -> &Control {
        &self.control
    }
}

impl<Stream: NativeStreamControl, Control: NativeControlTransport> HostService
    for NativeHostService<Stream, Control>
{
    fn start(&mut self, arguments: &HostArguments) -> Result<(), String> {
        if self.router.is_some() {
            return Err(ServiceError::AlreadyRunning.to_string());
        }
        crate::credentials::ensure_server_identity(arguments)
            .map_err(|error| ServiceError::Authority(error).to_string())?;
        let paths = HostAuthorityPaths::from_arguments(arguments)
            .map_err(|error| ServiceError::Authority(error.to_string()).to_string())?;
        let mut authorities = HostAuthorities::open_native_configured(paths, arguments)
            .map_err(|error| ServiceError::Authority(error.to_string()).to_string())?;
        authorities
            .reconcile_native_settings(arguments)
            .map_err(|error| ServiceError::Authority(error.to_string()).to_string())?;
        authorities.set_device_enrollment_enabled(
            arguments.get("device_enrollment_enabled") == Some("true"),
        );
        let discovery = HostDiscoveryState::from_arguments(arguments)
            .map_err(|error| ServiceError::Authority(error).to_string())?;
        self.mdns
            .start(arguments, &authorities)
            .map_err(|error| ServiceError::Discovery(error).to_string())?;
        let router = Arc::new(Mutex::new(ControlRouter::new_with_platform(
            authorities,
            discovery,
            Arc::clone(&self.platform),
        )));
        self.control
            .start(arguments, Arc::clone(&router))
            .map_err(|error| {
                let discovery_error = self.mdns.stop().err();
                match discovery_error {
                    Some(discovery_error) => format!(
                        "{}; mDNS rollback also failed: {discovery_error}",
                        ServiceError::Control(error)
                    ),
                    None => ServiceError::Control(error).to_string(),
                }
            })?;
        if let Err(error) =
            self.stream
                .start(arguments, Arc::clone(&router), Arc::clone(&self.platform))
        {
            let control_error = self.control.stop().err();
            let discovery_error = self.mdns.stop().err();
            return Err(match control_error {
                Some(control_error) => {
                    let mut message = format!(
                        "{}; TLS control rollback also failed: {control_error}",
                        ServiceError::Stream(error)
                    );
                    if let Some(discovery_error) = discovery_error {
                        message
                            .push_str(&format!("; mDNS rollback also failed: {discovery_error}"));
                    }
                    message
                }
                None => match discovery_error {
                    Some(discovery_error) => format!(
                        "{}; mDNS rollback also failed: {discovery_error}",
                        ServiceError::Stream(error)
                    ),
                    None => ServiceError::Stream(error).to_string(),
                },
            });
        }
        if let Err(error) = self.upnp.start(arguments) {
            let stream_error = self.stream.stop().err();
            let control_error = self.control.stop().err();
            let discovery_error = self.mdns.stop().err();
            let mut failures = vec![ServiceError::PortMapping(error).to_string()];
            if let Some(error) = stream_error {
                failures.push(ServiceError::Stream(error).to_string());
            }
            if let Some(error) = control_error {
                failures.push(ServiceError::Control(error).to_string());
            }
            if let Some(error) = discovery_error {
                failures.push(ServiceError::Discovery(error).to_string());
            }
            return Err(failures.join("; "));
        }
        self.router = Some(router);
        Ok(())
    }

    fn force_stop_stream(&mut self) -> Result<(), String> {
        let mut router = self.require_running()?;
        router
            .force_stop_stream()
            .map_err(|error| ServiceError::Stream(error).to_string())?;
        drop(router);
        self.stream.force_stop()
    }

    fn reload_applications(&mut self) -> Result<(), String> {
        let mut router = self.require_running()?;
        router
            .authorities_mut()
            .reload_applications()
            .map_err(|error| ServiceError::Authority(error.to_string()).to_string())
    }

    fn stop(&mut self) -> Result<(), String> {
        let platform_error = self
            .require_running()?
            .force_stop_stream()
            .err()
            .map(|error| ServiceError::Stream(error).to_string());
        let stream_error = self.stream.stop().err();
        let upnp_error = self.upnp.stop().err();
        let discovery_error = self.mdns.stop().err();
        let control_error = self.control.stop().err();
        self.router = None;
        let mut errors = Vec::new();
        if let Some(error) = platform_error {
            errors.push(error);
        }
        if let Some(error) = stream_error {
            errors.push(error);
        }
        if let Some(error) = upnp_error {
            errors.push(ServiceError::PortMapping(error).to_string());
        }
        if let Some(error) = discovery_error {
            errors.push(ServiceError::Discovery(error).to_string());
        }
        if let Some(error) = control_error {
            errors.push(ServiceError::Control(error).to_string());
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }
}

impl<Stream, Control> NativeHostService<Stream, Control> {
    fn require_running(&self) -> Result<MutexGuard<'_, ControlRouter>, String> {
        self.router
            .as_ref()
            .ok_or_else(|| ServiceError::NotRunning.to_string())?
            .lock()
            .map_err(|_| {
                ServiceError::Control("control router lock is poisoned".into()).to_string()
            })
    }
}

enum ServiceError {
    AlreadyRunning,
    NotRunning,
    Authority(String),
    Control(String),
    Stream(String),
    Discovery(String),
    PortMapping(String),
}

impl fmt::Display for ServiceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyRunning => formatter.write_str("native host service is already running"),
            Self::NotRunning => formatter.write_str("native host service is not running"),
            Self::Authority(message) => {
                write!(formatter, "native host authority failed: {message}")
            }
            Self::Control(message) => write!(formatter, "native host control failed: {message}"),
            Self::Stream(message) => write!(formatter, "native host stream failed: {message}"),
            Self::Discovery(message) => {
                write!(formatter, "native host discovery failed: {message}")
            }
            Self::PortMapping(message) => {
                write!(formatter, "native host port mapping failed: {message}")
            }
        }
    }
}

#[cfg(test)]
mod tests;
