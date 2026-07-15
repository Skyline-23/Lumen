use serde::Serialize;

use super::wake_on_lan::{WakeOnLanCapability, WakeOnLanDescriptor};
use super::{ControlResponse, ControlRouter};
use crate::network_ports::HostPorts;
use crate::HostArguments;
use lumen_engine::{
    AUDIO_CHANNEL_MODE_WIRE_VALUES, AUDIO_OPUS_APPLICATION, AUDIO_PACKET_DURATION_MILLISECONDS,
    AUDIO_SAMPLE_RATE, AUDIO_VARIABLE_BITRATE, ENHANCED_AUDIO_QUALITY_SUPPORTED,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostDiscoveryState {
    session_quic_port: u16,
    direct_media_udp_port: u16,
    control_https_port: u16,
    current_application_id: u32,
    current_application_uuid: String,
    wake_on_lan: WakeOnLanCapability,
}

impl HostDiscoveryState {
    pub fn from_arguments(arguments: &HostArguments) -> Result<Self, String> {
        let ports = HostPorts::from_arguments(arguments)?;
        Ok(Self {
            session_quic_port: ports.native_session_quic,
            direct_media_udp_port: ports.native_media_udp,
            control_https_port: ports.control_https,
            current_application_id: 0,
            current_application_uuid: String::new(),
            wake_on_lan: WakeOnLanCapability::detect(),
        })
    }

    #[cfg(test)]
    pub(crate) fn test_default() -> Self {
        Self {
            session_quic_port: 48_010,
            direct_media_udp_port: 47_998,
            control_https_port: 47_990,
            current_application_id: 0,
            current_application_uuid: String::new(),
            wake_on_lan: WakeOnLanCapability::Unsupported,
        }
    }

    #[cfg(test)]
    pub(crate) fn test_with_wake_on_lan(mac_address: [u8; 6]) -> Self {
        Self {
            wake_on_lan: WakeOnLanCapability::test_supported(mac_address),
            ..Self::test_default()
        }
    }

    pub(super) fn current_application_id(&self) -> u32 {
        self.current_application_id
    }

    pub(super) fn set_running_application(&mut self, id: u32, uuid: String) {
        self.current_application_id = id;
        self.current_application_uuid = uuid;
    }

    pub(super) fn clear_running_application(&mut self) {
        self.current_application_id = 0;
        self.current_application_uuid.clear();
    }
}

impl ControlRouter {
    pub(super) fn dispatch_discovery_apps(&self) -> ControlResponse {
        let settings = self.authorities().settings().snapshot();
        match self.authorities().applications().applications() {
            Ok(apps) => ControlResponse::json(
                200,
                &ApplicationCatalogResponse {
                    status: true,
                    apps,
                    current_app: &self.discovery.current_application_uuid,
                    host_uuid: self.authorities().host_identity().unique_id(),
                    name: &settings.settings.general.name,
                },
            ),
            Err(_) => ControlResponse::json(
                500,
                &DiscoveryErrorResponse {
                    error: DiscoveryError {
                        code: "storage-error",
                        message: "application catalog could not be loaded",
                        retryable: true,
                    },
                },
            ),
        }
    }

    pub(super) fn dispatch_discovery_host(&self) -> ControlResponse {
        let identity = self.authorities().host_identity();
        let settings = self.authorities().settings().snapshot();
        let name = &settings.settings.general.name;
        let busy = self.discovery.current_application_id > 0;
        ControlResponse::json(
            200,
            &HostDiscoveryResponse {
                status: true,
                host: HostDescriptor {
                    name,
                    device_authentication: "ready",
                    current_game_id: self.discovery.current_application_id,
                    server_state: if busy {
                        "LUMEN_SERVER_BUSY"
                    } else {
                        "LUMEN_SERVER_FREE"
                    },
                    session_quic_port: self.discovery.session_quic_port,
                    direct_media_udp_port: self.discovery.direct_media_udp_port,
                    control_https_port: self.discovery.control_https_port,
                    server_unique_id: identity.unique_id(),
                    authority_host: identity.authority_host(),
                    service_type: "_lumen._udp",
                    server_codec_mode_support: 0,
                    client_certificate_required: false,
                    wake_on_lan: self.discovery.wake_on_lan.descriptor(),
                    audio_capabilities: AudioCapabilities {
                        schema_version: 1,
                        channel_modes: &AUDIO_CHANNEL_MODE_WIRE_VALUES,
                        enhanced_audio_quality: ENHANCED_AUDIO_QUALITY_SUPPORTED,
                        sample_rate: AUDIO_SAMPLE_RATE,
                        packet_duration_milliseconds: AUDIO_PACKET_DURATION_MILLISECONDS,
                        opus_application: AUDIO_OPUS_APPLICATION,
                        variable_bitrate: AUDIO_VARIABLE_BITRATE,
                    },
                },
            },
        )
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApplicationCatalogResponse<'a> {
    status: bool,
    apps: Vec<lumen_engine::ApplicationDescriptor>,
    current_app: &'a str,
    #[serde(rename = "hostUUID")]
    host_uuid: &'a str,
    name: &'a str,
}

#[derive(Serialize)]
struct HostDiscoveryResponse<'a> {
    status: bool,
    host: HostDescriptor<'a>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostDescriptor<'a> {
    name: &'a str,
    device_authentication: &'static str,
    #[serde(rename = "currentGameID")]
    current_game_id: u32,
    server_state: &'static str,
    session_quic_port: u16,
    direct_media_udp_port: u16,
    control_https_port: u16,
    server_unique_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    authority_host: Option<&'a str>,
    service_type: &'static str,
    server_codec_mode_support: u32,
    client_certificate_required: bool,
    wake_on_lan: WakeOnLanDescriptor<'a>,
    audio_capabilities: AudioCapabilities,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AudioCapabilities {
    schema_version: u32,
    channel_modes: &'static [&'static str],
    enhanced_audio_quality: bool,
    sample_rate: i32,
    packet_duration_milliseconds: i32,
    opus_application: &'static str,
    variable_bitrate: bool,
}

#[derive(Serialize)]
struct DiscoveryErrorResponse {
    error: DiscoveryError,
}

#[derive(Serialize)]
struct DiscoveryError {
    code: &'static str,
    message: &'static str,
    retryable: bool,
}
