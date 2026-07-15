use std::sync::{Arc, Mutex};

use crate::{ControlRouter, HostArguments};

mod http;
mod media;
mod quic;
mod tls;

pub(crate) type SharedControlRouter = Arc<Mutex<ControlRouter>>;

pub trait NativeControlTransport {
    fn start(
        &mut self,
        arguments: &HostArguments,
        router: Arc<Mutex<ControlRouter>>,
    ) -> Result<(), String>;
    fn stop(&mut self) -> Result<(), String>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ServerSurface {
    Control,
}

#[derive(Default)]
pub struct IdleControlTransport;

impl NativeControlTransport for IdleControlTransport {
    fn start(
        &mut self,
        _arguments: &HostArguments,
        _router: Arc<Mutex<ControlRouter>>,
    ) -> Result<(), String> {
        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        Ok(())
    }
}

pub use quic::QuicSessionTransport;
pub use tls::TlsControlTransport;
