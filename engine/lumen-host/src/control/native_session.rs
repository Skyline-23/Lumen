use std::net::{IpAddr, SocketAddr};

use lumen_engine::{
    client_control_envelope, host_control_envelope, negotiate_native_session,
    ClientControlEnvelope, ClientSessionHello, CodecConfiguration, CodecConfigurationAck,
    HostControlEnvelope, HostSessionCapabilities, HostSessionPlan, LumenSessionOffer,
    MediaPathChallenge, MediaPathResponse, MediaPathValidated, NativeNegotiationFailure,
    NativeProtocolError, NativeSessionError, NativeVideoCodec, SessionStarted, SessionStopped,
    StartSessionAck, StopSession, NATIVE_VIDEO_STREAM_ID,
};

use super::{AudioDeliveryState, ControlRouter, VideoDeliveryState};
use crate::{
    PlatformApplicationPlan, PlatformRuntimeEvent, PlatformRuntimeEventCode,
    PlatformRuntimeEventDisposition, PlatformRuntimeEventSeverity, PlatformSessionPlan,
    PlatformVideoCodec,
};

const ERROR_INVALID_OPERATION: u32 = 1;
const ERROR_AUTHENTICATION: u32 = 2;
const ERROR_APPLICATION: u32 = 3;
const ERROR_NEGOTIATION: u32 = 4;
const ERROR_SESSION_CONFLICT: u32 = 5;
const ERROR_MEDIA_PATH: u32 = 6;
const ERROR_PLATFORM: u32 = 7;
const ERROR_SESSION_STATE: u32 = 8;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NativeConnectionContext {
    pub(crate) peer_address: IpAddr,
    pub(crate) session_epoch: u32,
    pub(crate) media_port: u16,
    pub(crate) media_challenge: [u8; 32],
    pub(crate) media_key: [u8; 16],
    pub(crate) host_capabilities: HostSessionCapabilities,
}

#[derive(Debug, Default)]
pub(super) struct NativeSessionState {
    pending: Option<PendingNativeSession>,
}

#[derive(Debug)]
struct PendingNativeSession {
    hello: ClientSessionHello,
    plan: HostSessionPlan,
    peer_address: IpAddr,
    media_challenge: [u8; 32],
    media_key: [u8; 16],
    media_endpoint: Option<SocketAddr>,
    media_validated: bool,
    active: bool,
    application_started: bool,
    codec_configuration: Option<CodecConfiguration>,
    codec_configuration_sent: bool,
    acknowledged_configuration_id: Option<u32>,
}

impl ControlRouter {
    pub(crate) fn dispatch_native_control(
        &mut self,
        envelope: ClientControlEnvelope,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let request_id = envelope.request_id;
        match envelope.payload {
            Some(client_control_envelope::Payload::Hello(hello)) => {
                self.dispatch_native_hello(request_id, hello, context)
            }
            Some(client_control_envelope::Payload::MediaPath(response)) => {
                self.dispatch_native_media_path(request_id, response, context)
            }
            Some(client_control_envelope::Payload::StartSession(start)) => {
                self.dispatch_native_start(request_id, start, context)
            }
            Some(client_control_envelope::Payload::StopSession(stop)) => {
                self.dispatch_native_stop(request_id, stop, context)
            }
            Some(client_control_envelope::Payload::CodecConfigurationAck(ack)) => {
                self.dispatch_native_codec_configuration_ack(request_id, ack, context)
            }
            None => vec![native_error(
                request_id,
                ERROR_INVALID_OPERATION,
                "native session operation is not valid in the current state",
            )],
        }
    }

    fn dispatch_native_codec_configuration_ack(
        &mut self,
        request_id: u64,
        ack: CodecConfigurationAck,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_mut() else {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )];
        };
        let accepted = pending
            .codec_configuration
            .as_ref()
            .is_some_and(|configuration| {
                pending.codec_configuration_sent
                    && context.session_epoch == configuration.session_epoch
                    && ack.session_epoch == configuration.session_epoch
                    && ack.stream_id == configuration.stream_id
                    && ack.configuration_id == configuration.configuration_id
            });
        if !accepted {
            return vec![native_error(
                request_id,
                ERROR_INVALID_OPERATION,
                "codec configuration acknowledgement was rejected",
            )];
        }
        pending.acknowledged_configuration_id = Some(ack.configuration_id);
        Vec::new()
    }

    fn dispatch_native_media_path(
        &mut self,
        request_id: u64,
        response: MediaPathResponse,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_mut() else {
            return vec![native_error(
                request_id,
                ERROR_MEDIA_PATH,
                "native media path has not been offered",
            )];
        };
        if response.session_epoch != pending.plan.session_epoch
            || context.session_epoch != pending.plan.session_epoch
            || response.path_id != pending.plan.path_id
            || response.token != pending.media_challenge
            || pending.media_endpoint.is_none()
            || pending.media_validated
        {
            return vec![native_error(
                request_id,
                ERROR_MEDIA_PATH,
                "native media path confirmation was rejected",
            )];
        }
        pending.media_validated = true;
        vec![HostControlEnvelope {
            request_id,
            payload: Some(host_control_envelope::Payload::MediaPathValidated(
                MediaPathValidated {
                    session_epoch: pending.plan.session_epoch,
                    path_id: pending.plan.path_id,
                },
            )),
        }]
    }

    fn dispatch_native_start(
        &mut self,
        request_id: u64,
        start: StartSessionAck,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_ref() else {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )];
        };
        if start.session_epoch != pending.plan.session_epoch
            || context.session_epoch != pending.plan.session_epoch
            || !pending.media_validated
            || pending.active
        {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session cannot start in the current state",
            )];
        }
        let hello = pending.hello.clone();
        let plan = pending.plan.clone();
        let current_application_id = self.discovery.current_application_id();
        if (hello.resume && current_application_id != hello.application_id)
            || (!hello.resume && current_application_id != 0)
        {
            return vec![native_error(
                request_id,
                ERROR_SESSION_CONFLICT,
                "application state conflicts with the native session request",
            )];
        }
        let application = match self
            .authorities
            .applications()
            .launch_plan(hello.application_id)
        {
            Ok(application) => application,
            Err(_) => {
                return vec![native_error(
                    request_id,
                    ERROR_APPLICATION,
                    "application launch plan is unavailable",
                )]
            }
        };
        if self
            .authorities
            .settings_mut()
            .mark_next_session_started()
            .is_err()
        {
            return vec![native_error(
                request_id,
                ERROR_APPLICATION,
                "next-session settings could not be applied",
            )];
        }
        let application_plan =
            match self.native_application_plan(&hello, &plan, application.clone()) {
                Ok(plan) => plan,
                Err(_) => {
                    return vec![native_error(
                        request_id,
                        ERROR_NEGOTIATION,
                        "native application plan is invalid",
                    )]
                }
            };
        let session_plan = match native_platform_session_plan(&hello, &plan) {
            Ok(plan) => plan,
            Err(_) => {
                return vec![native_error(
                    request_id,
                    ERROR_NEGOTIATION,
                    "native platform session plan is invalid",
                )]
            }
        };
        let application_started = !hello.resume;
        if application_started {
            if let Err(error) = self.platform.start_application(application_plan) {
                let message = format!("platform application could not be started: {error}");
                self.publish_native_platform_error(message.clone());
                return vec![native_error(request_id, ERROR_PLATFORM, message)];
            }
        }
        if let Err(error) = self.platform.start_session(session_plan) {
            let message = format!("platform stream session could not be started: {error}");
            return vec![native_error(
                request_id,
                ERROR_PLATFORM,
                self.rollback_native_start(application_started, message),
            )];
        }
        let _ = self.platform.publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Cleared,
            severity: PlatformRuntimeEventSeverity::Error,
            code: PlatformRuntimeEventCode::NativeSessionPlatform,
            message: None,
        });
        self.discovery
            .set_running_application(application.id, application.uuid);
        if let Some(pending) = self.native.pending.as_mut() {
            pending.active = true;
            pending.application_started = application_started;
        }
        vec![HostControlEnvelope {
            request_id,
            payload: Some(host_control_envelope::Payload::SessionStarted(
                SessionStarted {
                    session_epoch: plan.session_epoch,
                },
            )),
        }]
    }

    fn rollback_native_start(&self, application_started: bool, message: String) -> String {
        if application_started {
            let _ = self.platform.stop_application();
        }
        self.publish_native_platform_error(message.clone());
        message
    }

    fn publish_native_platform_error(&self, message: String) {
        eprintln!("Lumen native session platform error: {message}");
        let _ = self.platform.publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Error,
            code: PlatformRuntimeEventCode::NativeSessionPlatform,
            message: Some(message),
        });
    }

    fn dispatch_native_stop(
        &mut self,
        request_id: u64,
        stop: StopSession,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_ref() else {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session is not running",
            )];
        };
        if stop.session_epoch != pending.plan.session_epoch
            || context.session_epoch != pending.plan.session_epoch
        {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session stop does not match the active session",
            )];
        }
        let session_epoch = pending.plan.session_epoch;
        let active = pending.active;
        let application_started = pending.application_started;
        let session_error = active
            .then(|| self.platform.stop_session())
            .and_then(Result::err);
        let application_error = application_started
            .then(|| self.platform.stop_application())
            .and_then(Result::err);
        if application_started {
            self.discovery.clear_running_application();
        }
        self.native.pending = None;
        if session_error.is_some() || application_error.is_some() {
            return vec![native_error(
                request_id,
                ERROR_PLATFORM,
                "platform session cleanup failed",
            )];
        }
        vec![HostControlEnvelope {
            request_id,
            payload: Some(host_control_envelope::Payload::SessionStopped(
                SessionStopped { session_epoch },
            )),
        }]
    }

    pub(crate) fn observe_native_media_path(
        &mut self,
        peer: SocketAddr,
        session_epoch: u32,
        path_id: u16,
        challenge: &[u8],
    ) -> bool {
        let Some(pending) = self.native.pending.as_mut() else {
            return false;
        };
        if pending.plan.session_epoch != session_epoch
            || pending.plan.path_id != u32::from(path_id)
            || pending.peer_address != peer.ip()
            || challenge != pending.media_challenge
            || pending.media_endpoint.is_some()
        {
            return false;
        }
        pending.media_endpoint = Some(peer);
        true
    }

    fn dispatch_native_hello(
        &mut self,
        request_id: u64,
        hello: ClientSessionHello,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        if self.native.pending.is_some() {
            return vec![native_error(
                request_id,
                ERROR_SESSION_CONFLICT,
                "a native session is already pending",
            )];
        }
        if self
            .authorities
            .authentication()
            .verify_access_token(&hello.device_id, &hello.access_token)
            .is_err()
        {
            return vec![native_error(
                request_id,
                ERROR_AUTHENTICATION,
                "device credential was rejected",
            )];
        }
        let application_exists =
            self.authorities
                .applications()
                .applications()
                .is_ok_and(|applications| {
                    applications
                        .iter()
                        .any(|application| application.id == hello.application_id)
                });
        if !application_exists {
            return vec![native_error(
                request_id,
                ERROR_APPLICATION,
                "application is unavailable",
            )];
        }
        let plan = match negotiate_native_session(
            &hello,
            &context.host_capabilities,
            context.session_epoch,
        ) {
            Ok(plan) => plan,
            Err(error) => return vec![native_negotiation_error(request_id, error)],
        };
        self.native.pending = Some(PendingNativeSession {
            hello,
            plan: plan.clone(),
            peer_address: context.peer_address,
            media_challenge: context.media_challenge,
            media_key: context.media_key,
            media_endpoint: None,
            media_validated: false,
            active: false,
            application_started: false,
            codec_configuration: None,
            codec_configuration_sent: false,
            acknowledged_configuration_id: None,
        });
        vec![
            HostControlEnvelope {
                request_id,
                payload: Some(host_control_envelope::Payload::SessionPlan(plan.clone())),
            },
            HostControlEnvelope {
                request_id,
                payload: Some(host_control_envelope::Payload::MediaPath(
                    MediaPathChallenge {
                        session_epoch: plan.session_epoch,
                        path_id: plan.path_id,
                        media_port: u32::from(context.media_port),
                        token: context.media_challenge.to_vec(),
                    },
                )),
            },
        ]
    }

    #[cfg(test)]
    pub(crate) fn pending_native_media_endpoint(&self) -> Option<SocketAddr> {
        self.native
            .pending
            .as_ref()
            .and_then(|pending| pending.media_endpoint)
    }

    #[cfg(test)]
    pub(crate) fn pending_native_media_is_validated(&self) -> bool {
        self.native
            .pending
            .as_ref()
            .is_some_and(|pending| pending.media_validated)
    }

    pub(crate) fn pending_native_media_key(&self, session_epoch: u32) -> Option<[u8; 16]> {
        self.native.pending.as_ref().and_then(|pending| {
            (pending.plan.session_epoch == session_epoch).then_some(pending.media_key)
        })
    }

    pub(crate) fn native_input_is_active(&self, session_epoch: u32) -> bool {
        self.native
            .pending
            .as_ref()
            .is_some_and(|pending| pending.active && pending.plan.session_epoch == session_epoch)
    }

    pub(crate) fn publish_native_codec_configuration(
        &mut self,
        configuration: CodecConfiguration,
    ) -> bool {
        {
            let Some(pending) = self.native.pending.as_mut() else {
                return false;
            };
            if !pending.active
                || configuration.session_epoch != pending.plan.session_epoch
                || configuration.stream_id != u32::from(NATIVE_VIDEO_STREAM_ID)
                || configuration.stream_id != pending.plan.video_stream_id
                || configuration.configuration_id == 0
                || configuration.decoder_configuration_record.is_empty()
                || configuration.codec != pending.plan.video_codec
                || pending.codec_configuration.as_ref().is_some_and(|current| {
                    current.configuration_id >= configuration.configuration_id
                })
            {
                return false;
            }
            pending.codec_configuration = Some(configuration);
            pending.codec_configuration_sent = false;
            pending.acknowledged_configuration_id = None;
        }
        self.codec_configuration_notify.notify_one();
        true
    }

    pub(crate) fn take_native_codec_configuration(
        &mut self,
        session_epoch: u32,
    ) -> Option<CodecConfiguration> {
        let pending = self.native.pending.as_mut()?;
        if pending.plan.session_epoch != session_epoch || pending.codec_configuration_sent {
            return None;
        }
        let configuration = pending.codec_configuration.clone()?;
        pending.codec_configuration_sent = true;
        Some(configuration)
    }

    pub(crate) fn video_delivery_state(&self) -> Option<VideoDeliveryState> {
        self.native_video_delivery_state()
    }

    pub(crate) fn audio_delivery_state(&self) -> Option<AudioDeliveryState> {
        self.native_audio_delivery_state()
    }

    fn native_video_delivery_state(&self) -> Option<VideoDeliveryState> {
        let pending = self.native.pending.as_ref()?;
        if !pending.active || !pending.media_validated {
            return None;
        }
        Some(VideoDeliveryState {
            codec: platform_video_codec(&pending.plan)?,
            acknowledged_configuration_id: pending.acknowledged_configuration_id,
            session_epoch: pending.plan.session_epoch,
            path_id: u16::try_from(pending.plan.path_id).ok()?,
            policy_revision: u16::try_from(pending.plan.policy_revision).ok()?,
            maximum_datagram_payload: usize::try_from(pending.plan.maximum_datagram_payload)
                .ok()?,
            endpoint: pending.media_endpoint?,
            encryption_key: pending.media_key,
            fec_percentage: self
                .authorities
                .settings()
                .snapshot()
                .effective
                .network
                .fec_percentage,
        })
    }

    fn native_audio_delivery_state(&self) -> Option<AudioDeliveryState> {
        let pending = self.native.pending.as_ref()?;
        if !pending.active || !pending.media_validated {
            return None;
        }
        Some(AudioDeliveryState {
            session_epoch: pending.plan.session_epoch,
            path_id: u16::try_from(pending.plan.path_id).ok()?,
            policy_revision: u16::try_from(pending.plan.policy_revision).ok()?,
            maximum_datagram_payload: usize::try_from(pending.plan.maximum_datagram_payload)
                .ok()?,
            endpoint: pending.media_endpoint?,
            encryption_key: pending.media_key,
        })
    }

    pub(super) fn take_native_cleanup_state(&mut self) -> (bool, bool) {
        self.native
            .pending
            .take()
            .map(|pending| (pending.active, pending.application_started))
            .unwrap_or_default()
    }

    fn native_application_plan(
        &self,
        hello: &ClientSessionHello,
        plan: &HostSessionPlan,
        application: lumen_engine::ApplicationLaunchPlan,
    ) -> Result<PlatformApplicationPlan, String> {
        let settings = self.authorities.settings().snapshot().effective;
        let global_prep_commands = if application.exclude_global_prep_commands {
            Vec::new()
        } else {
            settings.commands.prep
        };
        let global_state_commands = if application.exclude_global_state_commands {
            Vec::new()
        } else {
            settings.commands.state
        };
        Ok(PlatformApplicationPlan {
            application,
            global_prep_commands,
            global_state_commands,
            server_commands: settings.commands.server,
            width: plan.encoded_width,
            height: plan.encoded_height,
            frames_per_second: refresh_millihz_to_frames_per_second(plan.refresh_millihz)?,
            virtual_display: hello.virtual_display,
            session_offer: native_session_offer(plan)?,
        })
    }

    #[cfg(test)]
    pub(crate) fn pending_native_media_key_from_test(&self) -> Option<[u8; 16]> {
        self.native
            .pending
            .as_ref()
            .map(|pending| pending.media_key)
    }
}

fn native_platform_session_plan(
    hello: &ClientSessionHello,
    plan: &HostSessionPlan,
) -> Result<PlatformSessionPlan, String> {
    let video_codec =
        platform_video_codec(plan).ok_or_else(|| "native video codec is invalid".to_owned())?;
    Ok(PlatformSessionPlan {
        width: plan.encoded_width,
        height: plan.encoded_height,
        frames_per_second: refresh_millihz_to_frames_per_second(plan.refresh_millihz)?,
        bitrate_kbps: plan.bitrate_kbps,
        video_codec,
        yuv444: false,
        audio_channels: u8::try_from(plan.opus_channel_count)
            .map_err(|_| "native audio channel count is invalid".to_owned())?,
        enhanced_audio_quality: plan.enhanced_audio_quality,
        play_audio_on_host: hello.play_audio_on_host,
        virtual_display: hello.virtual_display,
        encoder_csc_mode: 2,
        sink_hidpi: plan.sink_hidpi,
        sink_scale_explicit: plan.sink_scale_explicit,
        sink_mode_is_logical: plan.sink_mode_is_logical,
        sink_scale_percent: i32::try_from(plan.sink_scale_percent)
            .map_err(|_| "native display scale is invalid".to_owned())?,
        sink_gamut: plan.sink_gamut,
        sink_transfer: plan.sink_transfer,
        sink_current_edr_headroom: plan.sink_current_edr_headroom,
        sink_potential_edr_headroom: plan.sink_potential_edr_headroom,
        sink_current_peak_luminance_nits: i32::try_from(plan.sink_current_peak_luminance_nits)
            .map_err(|_| "native current display luminance is invalid".to_owned())?,
        sink_potential_peak_luminance_nits: i32::try_from(plan.sink_potential_peak_luminance_nits)
            .map_err(|_| "native potential display luminance is invalid".to_owned())?,
        sink_supports_frame_gated_hdr: plan.sink_supports_frame_gated_hdr,
        sink_supports_hdr_tile_overlay: plan.sink_supports_hdr_tile_overlay,
        sink_supports_per_frame_hdr_metadata: plan.sink_supports_per_frame_hdr_metadata,
        negotiated_dynamic_range_transport: plan.dynamic_range_transport,
    })
}

fn platform_video_codec(plan: &HostSessionPlan) -> Option<PlatformVideoCodec> {
    match NativeVideoCodec::try_from(plan.video_codec) {
        Ok(NativeVideoCodec::H264) => Some(PlatformVideoCodec::H264),
        Ok(NativeVideoCodec::Hevc) => Some(PlatformVideoCodec::Hevc),
        Ok(NativeVideoCodec::Av1) => Some(PlatformVideoCodec::Av1),
        _ => None,
    }
}

fn native_session_offer(plan: &HostSessionPlan) -> Result<LumenSessionOffer, String> {
    Ok(LumenSessionOffer {
        version: 2,
        hidpi: plan.sink_hidpi,
        scale_explicit: plan.sink_scale_explicit,
        mode_is_logical: plan.sink_mode_is_logical,
        scale_percent: i32::try_from(plan.sink_scale_percent)
            .map_err(|_| "native display scale is invalid".to_owned())?,
        gamut: plan.sink_gamut,
        transfer: plan.sink_transfer,
        current_edr_headroom: plan.sink_current_edr_headroom,
        potential_edr_headroom: plan.sink_potential_edr_headroom,
        current_peak_luminance_nits: i32::try_from(plan.sink_current_peak_luminance_nits)
            .map_err(|_| "native current display luminance is invalid".to_owned())?,
        potential_peak_luminance_nits: i32::try_from(plan.sink_potential_peak_luminance_nits)
            .map_err(|_| "native potential display luminance is invalid".to_owned())?,
        supports_frame_gated_hdr: plan.sink_supports_frame_gated_hdr,
        supports_hdr_tile_overlay: plan.sink_supports_hdr_tile_overlay,
        supports_per_frame_hdr_metadata: plan.sink_supports_per_frame_hdr_metadata,
        requested_transport: plan.dynamic_range_transport,
    })
}

fn refresh_millihz_to_frames_per_second(refresh_millihz: u32) -> Result<u32, String> {
    let frames_per_second = refresh_millihz.saturating_add(500) / 1_000;
    (frames_per_second > 0)
        .then_some(frames_per_second)
        .ok_or_else(|| "native refresh rate is invalid".to_owned())
}

fn native_error(request_id: u64, code: u32, message: impl Into<String>) -> HostControlEnvelope {
    HostControlEnvelope {
        request_id,
        payload: Some(host_control_envelope::Payload::Error(NativeProtocolError {
            code,
            message: message.into(),
            negotiation_failure: NativeNegotiationFailure::Unspecified as i32,
        })),
    }
}

fn native_negotiation_error(request_id: u64, error: NativeSessionError) -> HostControlEnvelope {
    HostControlEnvelope {
        request_id,
        payload: Some(host_control_envelope::Payload::Error(NativeProtocolError {
            code: ERROR_NEGOTIATION,
            message: "session capabilities could not be negotiated".to_owned(),
            negotiation_failure: NativeNegotiationFailure::from(error) as i32,
        })),
    }
}
