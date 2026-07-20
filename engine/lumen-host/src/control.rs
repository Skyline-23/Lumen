use serde::Serialize;
use std::sync::Arc;
use tokio::sync::Notify;

use crate::{HostAuthorities, IdlePlatformSessionControl, PlatformSessionControl};

mod auth;
mod discovery;
mod native_session;
mod settings;
mod wake_on_lan;

pub(crate) use native_session::{NativeConnectionContext, NativeMediaFeedbackDisposition};

pub use discovery::HostDiscoveryState;

const MAXIMUM_JSON_REQUEST_BYTES: usize = 32 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct VideoDeliveryState {
    pub(crate) video_format: crate::PlatformVideoFormat,
    pub(crate) acknowledged_configuration_id: Option<u32>,
    pub(crate) acknowledged_generation_id: Option<u32>,
    pub(crate) bootstrap_pending: bool,
    pub(crate) repair_keyframe_requested: bool,
    pub(crate) session_epoch: u32,
    pub(crate) policy_revision: u16,
    pub(crate) maximum_datagram_payload: usize,
    pub(crate) maximum_object_delay_us: u32,
    pub(crate) fec_percentage: u16,
    pub(crate) target_bitrate_kbps: u32,
    pub(crate) admission_divisor: u8,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct AudioDeliveryState {
    pub(crate) session_epoch: u32,
    pub(crate) policy_revision: u16,
    pub(crate) maximum_datagram_payload: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct InputMotionDeliveryState {
    pub(crate) session_epoch: u32,
    pub(crate) policy_revision: u16,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ControlMethod {
    Get,
    Patch,
    Post,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ControlRequest {
    pub method: ControlMethod,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub query: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl ControlRequest {
    pub fn new(method: ControlMethod, path: impl Into<String>) -> Self {
        Self {
            method,
            path: path.into(),
            headers: Vec::new(),
            query: Vec::new(),
            body: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ControlResponse {
    pub status_code: u16,
    pub body: Vec<u8>,
    pub content_type: &'static str,
    pub cache_control: &'static str,
}

impl ControlResponse {
    fn json(status_code: u16, value: &impl Serialize) -> Self {
        match serde_json::to_vec(value) {
            Ok(body) => Self::json_bytes(status_code, body),
            Err(_) => Self::json_bytes(
                500,
                br#"{"code":"storage-error","message":"control response could not be serialized"}"#
                    .to_vec(),
            ),
        }
    }

    fn json_bytes(status_code: u16, body: Vec<u8>) -> Self {
        Self {
            status_code,
            body,
            content_type: "application/json",
            cache_control: "no-store",
        }
    }

    fn empty(status_code: u16) -> Self {
        Self::json_bytes(status_code, Vec::new())
    }
}

pub struct ControlRouter {
    authorities: HostAuthorities,
    discovery: HostDiscoveryState,
    platform: Arc<dyn PlatformSessionControl>,
    native: native_session::NativeSessionState,
    codec_configuration_notify: Arc<Notify>,
    video_bootstrap_notify: Arc<Notify>,
}

impl ControlRouter {
    pub fn new(authorities: HostAuthorities, discovery: HostDiscoveryState) -> Self {
        Self::new_with_platform(authorities, discovery, Arc::new(IdlePlatformSessionControl))
    }

    pub fn new_with_platform(
        authorities: HostAuthorities,
        discovery: HostDiscoveryState,
        platform: Arc<dyn PlatformSessionControl>,
    ) -> Self {
        Self {
            authorities,
            discovery,
            platform,
            native: native_session::NativeSessionState::default(),
            codec_configuration_notify: Arc::new(Notify::new()),
            video_bootstrap_notify: Arc::new(Notify::new()),
        }
    }

    pub(crate) fn native_codec_configuration_notify(&self) -> Arc<Notify> {
        Arc::clone(&self.codec_configuration_notify)
    }

    pub(crate) fn native_video_bootstrap_notify(&self) -> Arc<Notify> {
        Arc::clone(&self.video_bootstrap_notify)
    }

    pub fn authorities(&self) -> &HostAuthorities {
        &self.authorities
    }

    pub fn authorities_mut(&mut self) -> &mut HostAuthorities {
        &mut self.authorities
    }

    pub fn dispatch(&mut self, request: &ControlRequest) -> ControlResponse {
        if let Some(operation) = auth::operation(request.method, &request.path) {
            return self.dispatch_auth(operation, request);
        }
        match (request.method, request.path.as_str()) {
            (ControlMethod::Get, "/api/v1/settings") => {
                if let Some(error) = self.authorize(request) {
                    return error;
                }
                self.dispatch_settings_snapshot(request)
            }
            (ControlMethod::Get, "/api/discovery/apps") => {
                if let Some(error) = self.authorize(request) {
                    return error;
                }
                self.dispatch_discovery_apps()
            }
            (ControlMethod::Get, "/api/discovery/host") => {
                if let Some(error) = self.authorize(request) {
                    return error;
                }
                self.dispatch_discovery_host()
            }
            (ControlMethod::Patch, "/api/v1/settings") => {
                if let Some(error) = self.authorize(request) {
                    return error;
                }
                self.dispatch_settings_patch(request)
            }
            (ControlMethod::Get, "/api/v1/settings/events") => {
                if let Some(error) = self.authorize(request) {
                    return error;
                }
                self.dispatch_settings_events(request)
            }
            _ => ControlResponse::empty(404),
        }
    }

    pub fn force_stop_stream(&mut self) -> Result<(), String> {
        let (session_active, application_started) = self.take_native_cleanup_state();
        let session_result = if session_active {
            self.platform.stop_session()
        } else {
            Ok(())
        };
        let application_result =
            if application_started || self.discovery.current_application_id() != 0 {
                self.platform.stop_application()
            } else {
                Ok(())
            };
        self.discovery.clear_running_application();
        match (session_result, application_result) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(session), Ok(())) => Err(session),
            (Ok(()), Err(application)) => Err(application),
            (Err(session), Err(application)) => Err(format!(
                "{session}; application stop also failed: {application}"
            )),
        }
    }
}

fn has_json_content_type(headers: &[(String, String)]) -> bool {
    let values = header_values(headers, "content-type");
    values.len() == 1
        && values[0]
            .split(';')
            .next()
            .is_some_and(|value| value.trim().eq_ignore_ascii_case("application/json"))
}

fn header_values<'a>(headers: &'a [(String, String)], name: &str) -> Vec<&'a str> {
    headers
        .iter()
        .filter(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
        .collect()
}

#[cfg(test)]
pub(crate) mod tests;
