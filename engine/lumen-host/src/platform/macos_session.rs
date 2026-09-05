use super::*;

impl MacPlatformSessionControl {
    pub(crate) fn new(stream_audio: bool) -> Result<Self, String> {
        let api = MacBridgeApi::load()?;
        if !unsafe { (api.prepare_application_main_thread)() } {
            return Err(
                "macOS application lifecycle must be prepared on the main thread".to_owned(),
            );
        }
        let controller = unsafe { (api.create_controller)() };
        if controller.is_null() {
            return Err("could not create the macOS capture bridge".to_owned());
        }
        Ok(Self {
            api,
            stream_audio,
            state: Mutex::new(MacSessionState {
                controller,
                workspace_key: None,
                display_id: 0,
                input_display_id: 0,
                input_display_bounds: None,
                input_capture_viewport: None,
                desktop_mirror_source_display_id: 0,
                opus: None,
                audio_channels: 0,
                pcm: Vec::new(),
                audio_scratch: vec![0; MAXIMUM_PCM_BYTES],
                next_audio_timestamp: 0,
                next_audio_deadline: None,
                audio_capture_failure: None,
                plan: None,
            }),
            native_input: MacNativeInput::default(),
            application: PortableApplication::default(),
        })
    }

    pub(crate) fn run_application_event_loop(
        &self,
        readiness: SyncSender<bool>,
    ) -> Result<(), String> {
        unsafe extern "C" fn publish_readiness(context: *mut c_void, ready: bool) {
            let readiness = unsafe { Box::from_raw(context.cast::<SyncSender<bool>>()) };
            let _ = readiness.send(ready);
        }
        let context = Box::into_raw(Box::new(readiness)).cast::<c_void>();
        unsafe { (self.api.run_application_main_thread)(publish_readiness, context) }
            .then_some(())
            .ok_or_else(|| "macOS application event loop must run on the main thread".to_owned())
    }

    pub(crate) fn stop_application_event_loop(&self) {
        unsafe { (self.api.stop_application_main_thread)() };
    }

    pub(crate) fn warm_screen_capture_inventory(&self) {
        unsafe { (self.api.warm_screen_capture_inventory)() };
    }

    fn reconfigure_workspace_locked(
        &self,
        state: &MacSessionState,
        plan: PlatformSessionPlan,
    ) -> Result<u32, String> {
        let key = state
            .workspace_key
            .as_ref()
            .ok_or_else(|| "macOS dynamic display has no retained workspace".to_owned())?;
        let display_name = CString::new("Lumen Display").expect("static display name");
        let mut error = [0_i8; 1024];
        let request = MacWorkspaceSessionRequest {
            display_key: key.as_ptr(),
            display_name: display_name.as_ptr(),
            width: plan.width,
            height: plan.height,
            scale_percent: u32::try_from(plan.sink_scale_percent)
                .map_err(|_| "macOS workspace display scale is invalid".to_owned())?,
            dimensions_are_logical: plan.sink_mode_is_logical,
            high_density: plan.sink_hidpi,
            refresh_rate: f64::from(plan.frames_per_second),
            hdr_enabled: matches!(
                plan.video_format.dynamic_range,
                crate::PlatformDynamicRange::Hdr10
            ),
            sink_gamut: plan.sink_gamut,
            sink_transfer: plan.sink_transfer,
            current_edr_headroom: plan.sink_current_edr_headroom,
            potential_edr_headroom: plan.sink_potential_edr_headroom,
            current_peak_luminance_nits: plan.sink_current_peak_luminance_nits,
            potential_peak_luminance_nits: plan.sink_potential_peak_luminance_nits,
            desktop_mirror_source_display_id: state.desktop_mirror_source_display_id,
        };
        let display_id =
            unsafe { (self.api.reconfigure_workspace)(request, error.as_mut_ptr(), error.len()) };
        if display_id == 0 {
            return Err(format!(
                "platform display could not be reconfigured: {}",
                error_text(&error)
            ));
        }
        Ok(display_id)
    }

    fn restore_retained_workspace_capture_locked(
        &self,
        state: &mut MacSessionState,
        plan: PlatformSessionPlan,
    ) -> Result<u32, String> {
        let display_id = self.reconfigure_workspace_locked(state, plan)?;
        // The workspace mutation has already replaced the CoreGraphics object.
        // Keep cleanup and native input bound to that physical identity even if
        // the following capture start also fails.
        state.display_id = display_id;
        state.input_display_id = display_id;
        self.start_capture_pair_locked(state, plan, display_id)?;
        Ok(display_id)
    }

    fn stop_capture_pair_locked(&self, state: &mut MacSessionState) {
        unsafe {
            // Stop the ScreenCaptureKit owner first so a following display-mode
            // mutation is observed as an intentional teardown, not as an
            // unexpected termination that races the replacement capture.
            (self.api.stop_video_capture)(state.controller);
            (self.api.stop_audio_capture)(state.controller);
        }
        state.audio_capture_failure = None;
        state.pcm.clear();
        state.next_audio_deadline = None;
    }

    fn start_capture_pair_locked(
        &self,
        state: &mut MacSessionState,
        plan: PlatformSessionPlan,
        display_id: u32,
    ) -> Result<(), String> {
        unsafe {
            (self.api.configure_video_forwarding)(state.controller, 3, 16);
            (self.api.configure_audio_forwarding)(state.controller, 8, 16);
        }
        let mut video = unsafe { (self.api.make_video_configuration)(display_id) };
        video.session_epoch = plan.session_epoch;
        video.policy_revision = plan.policy_revision;
        video.codec = match plan.video_format.codec {
            crate::PlatformVideoCodec::H264 => 0,
            crate::PlatformVideoCodec::Hevc => 1,
            crate::PlatformVideoCodec::Av1 => return Err("AV1 is unavailable on macOS".to_owned()),
        };
        video.video_profile = plan.video_format.profile as i32;
        video.chroma_subsampling = plan.video_format.chroma_subsampling as i32;
        video.bit_depth = plan.video_format.bit_depth;
        video.dynamic_range = plan.video_format.dynamic_range as i32;
        video.color_range = plan.video_format.color_range as i32;
        video.target_frame_rate = i32::try_from(plan.frames_per_second).unwrap_or(i32::MAX);
        video.target_video_bitrate_kbps = i32::try_from(plan.bitrate_kbps).unwrap_or(i32::MAX);
        video.requested_width = i32::try_from(plan.width).unwrap_or(i32::MAX);
        video.requested_height = i32::try_from(plan.height).unwrap_or(i32::MAX);
        video.sink_request.mode = MacSinkMode {
            hidpi: plan.sink_hidpi,
            scale_explicit: plan.sink_scale_explicit,
            mode_is_logical: plan.sink_mode_is_logical,
            scale_percent: plan.sink_scale_percent,
        };
        video.sink_request.capability = MacSinkCapability {
            gamut: plan.sink_gamut,
            transfer: plan.sink_transfer,
            current_edr_headroom: plan.sink_current_edr_headroom,
            potential_edr_headroom: plan.sink_potential_edr_headroom,
            current_peak_luminance_nits: plan.sink_current_peak_luminance_nits,
            potential_peak_luminance_nits: plan.sink_potential_peak_luminance_nits,
            supports_frame_gated_hdr: plan.sink_supports_frame_gated_hdr,
            supports_hdr_tile_overlay: plan.sink_supports_hdr_tile_overlay,
            supports_per_frame_hdr_metadata: plan.sink_supports_per_frame_hdr_metadata,
        };
        video.sink_request.dynamic_range_transport =
            i32::try_from(plan.negotiated_dynamic_range_transport).unwrap_or_default();
        video.effective_display_state.gamut = plan.sink_gamut;
        video.effective_display_state.transfer = plan.sink_transfer;
        let mut audio = unsafe { (self.api.make_audio_configuration)(display_id) };
        audio.sample_rate = 48_000;
        audio.channel_count = i32::from(plan.audio_channels);
        audio.frame_size = AUDIO_FRAME_COUNT as i32;
        let mut error = [0_i8; 1024];
        state.audio_capture_failure = self.start_configured_capture(state.controller, video, audio, &mut error)?;
        state.pcm.clear();
        state.next_audio_timestamp = audio_timestamp(monotonic_nanoseconds());
        state.next_audio_deadline = self.stream_audio.then(Instant::now);
        Ok(())
    }

    fn start_configured_capture(
        &self,
        controller: *mut BridgeController,
        video: MacCaptureConfiguration,
        audio: MacAudioCaptureConfiguration,
        error: &mut [c_char],
    ) -> Result<Option<String>, String> {
        if self.stream_audio {
            let status = unsafe {
                (self.api.start_capture_pair)(controller, video, audio, error.as_mut_ptr(), error.len())
            };
            capture_pair_audio_failure(status, error_text(error))
        } else {
            let started = unsafe {
                (self.api.start_video_capture)(controller, video, error.as_mut_ptr(), error.len())
            };
            if !started {
                return Err(format!("macOS video-only capture start failed: {}", error_text(error)));
            }
            eprintln!("Lumen native media stage=audio-disabled-by-host-policy");
            Ok(None)
        }
    }

    fn stop_locked(&self, state: &mut MacSessionState) -> Result<(), String> {
        unsafe {
            (self.api.stop_audio_capture)(state.controller);
            (self.api.stop_video_capture)(state.controller);
        }
        let workspace_result = stop_workspace(&mut state.workspace_key, self.api.stop_workspace);
        state.display_id = 0;
        state.input_display_id = 0;
        state.input_display_bounds = None;
        state.input_capture_viewport = None;
        state.opus = None;
        state.audio_channels = 0;
        state.pcm.clear();
        state.next_audio_deadline = None;
        state.audio_capture_failure = None;
        state.plan = None;
        workspace_result
    }
}

pub(super) fn stop_workspace(
    workspace_key: &mut Option<CString>,
    stop_workspace: StopWorkspace,
) -> Result<(), String> {
    let Some(key) = workspace_key.take() else {
        return Ok(());
    };
    let mut error = [0_i8; 1024];
    if unsafe { stop_workspace(key.as_ptr(), error.as_mut_ptr(), error.len()) } {
        return Ok(());
    }
    *workspace_key = Some(key);
    Err(format!("workspace stop failed: {}", error_text(&error)))
}

impl PlatformSessionControl for MacPlatformSessionControl {
    fn supports_media_park_resume(&self) -> bool {
        true
    }

    fn start_application(&self, plan: PlatformApplicationPlan) -> Result<(), String> {
        let source_display_id = desktop_mirror_source_candidate_display_id(
            plan.application.captures_desktop(),
            plan.virtual_display,
            unsafe { CGMainDisplayID() },
        )?;
        self.application.start(plan)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
        state.desktop_mirror_source_display_id = source_display_id;
        Ok(())
    }

    fn stop_application(&self) -> Result<(), String> {
        self.application.stop()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
        state.desktop_mirror_source_display_id = 0;
        Ok(())
    }

    fn start_session(&self, plan: PlatformSessionPlan) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
        self.stop_locked(&mut state)?;
        let startup = (|| -> Result<(), String> {
            let workspace_key = CString::new(MACOS_WORKSPACE_DISPLAY_KEY)
                .map_err(|_| "workspace key is invalid".to_owned())?;
            let display_name = CString::new("Lumen Display").expect("static display name");
            let capture_topology = mac_capture_topology(
                plan.virtual_display,
                state.desktop_mirror_source_display_id,
                unsafe { CGMainDisplayID() },
            )?;
            let display_id = match capture_topology {
                MacCaptureTopology::VirtualWorkspace {
                    desktop_mirror_source_display_id,
                } => {
                    let mut error = [0_i8; 1024];
                    let request = MacWorkspaceSessionRequest {
                        display_key: workspace_key.as_ptr(),
                        display_name: display_name.as_ptr(),
                        width: plan.width,
                        height: plan.height,
                        scale_percent: u32::try_from(plan.sink_scale_percent)
                            .map_err(|_| "macOS workspace display scale is invalid".to_owned())?,
                        dimensions_are_logical: plan.sink_mode_is_logical,
                        high_density: plan.sink_hidpi,
                        refresh_rate: f64::from(plan.frames_per_second),
                        hdr_enabled: matches!(
                            plan.video_format.dynamic_range,
                            crate::PlatformDynamicRange::Hdr10
                        ),
                        sink_gamut: plan.sink_gamut,
                        sink_transfer: plan.sink_transfer,
                        current_edr_headroom: plan.sink_current_edr_headroom,
                        potential_edr_headroom: plan.sink_potential_edr_headroom,
                        current_peak_luminance_nits: plan.sink_current_peak_luminance_nits,
                        potential_peak_luminance_nits: plan.sink_potential_peak_luminance_nits,
                        desktop_mirror_source_display_id,
                    };
                    let display_id = unsafe {
                        (self.api.prepare_workspace)(request, error.as_mut_ptr(), error.len())
                    };
                    if display_id == 0 {
                        return Err(format!(
                            "platform display could not be created: {}",
                            error_text(&error)
                        ));
                    }
                    state.workspace_key = Some(workspace_key);
                    display_id
                }
                MacCaptureTopology::PhysicalDisplay(display_id) => display_id,
            };
            state.display_id = display_id;
            // The owned capture display is only safe for input after the Swift workspace
            // admission has returned successfully. Until then, keep the input target unset.
            let workspace_prepared = !plan.virtual_display || state.workspace_key.is_some();
            state.input_display_id =
                input_display_id_after_workspace_prepare(display_id, workspace_prepared);
            state.input_display_bounds = if plan.virtual_display {
                let geometry = resolve_display_geometry(LumenDisplayModeRequest {
                    width: plan.width,
                    height: plan.height,
                    scale_percent: u32::try_from(plan.sink_scale_percent)
                        .map_err(|_| "macOS native input display scale is invalid".to_owned())?,
                    dimensions_are_logical: plan.sink_mode_is_logical,
                    high_density: plan.sink_hidpi,
                })
                .map_err(|status| {
                    format!("macOS native input display geometry is invalid: {status:?}")
                })?;
                Some(MacInputDisplayBounds {
                    width: f64::from(geometry.logical_width),
                    height: f64::from(geometry.logical_height),
                })
            } else {
                None
            };
            state.input_capture_viewport =
                (!plan.virtual_display).then_some(MacInputCaptureViewport {
                    width: f64::from(plan.width),
                    height: f64::from(plan.height),
                });
            let stream = resolve_audio_stream(LumenAudioStreamRequest {
                channels: i32::from(plan.audio_channels),
                packet_duration_milliseconds: 5,
                enhanced_audio_quality: plan.enhanced_audio_quality,
            })
            .map_err(|status| format!("audio stream policy rejected the session: {status:?}"))?;
            state.opus = if self.stream_audio { Some(NativeOpusEncoder::new(
                &self.api,
                &stream,
                plan.enhanced_audio_quality,
            )?) } else { None };
            state.audio_channels = usize::from(plan.audio_channels);
            unsafe {
                (self.api.configure_video_forwarding)(state.controller, 3, 16);
                (self.api.configure_audio_forwarding)(state.controller, 8, 16);
            }
            let mut video = unsafe { (self.api.make_video_configuration)(display_id) };
            video.session_epoch = plan.session_epoch;
            video.policy_revision = plan.policy_revision;
            video.codec = match plan.video_format.codec {
                crate::PlatformVideoCodec::H264 => 0,
                crate::PlatformVideoCodec::Hevc => 1,
                crate::PlatformVideoCodec::Av1 => {
                    return Err("AV1 is unavailable on macOS".to_owned())
                }
            };
            video.video_profile = plan.video_format.profile as i32;
            video.chroma_subsampling = plan.video_format.chroma_subsampling as i32;
            video.bit_depth = plan.video_format.bit_depth;
            video.dynamic_range = plan.video_format.dynamic_range as i32;
            video.color_range = plan.video_format.color_range as i32;
            video.target_frame_rate = i32::try_from(plan.frames_per_second).unwrap_or(i32::MAX);
            video.target_video_bitrate_kbps = i32::try_from(plan.bitrate_kbps).unwrap_or(i32::MAX);
            video.requested_width = i32::try_from(plan.width).unwrap_or(i32::MAX);
            video.requested_height = i32::try_from(plan.height).unwrap_or(i32::MAX);
            video.sink_request.mode = MacSinkMode {
                hidpi: plan.sink_hidpi,
                scale_explicit: plan.sink_scale_explicit,
                mode_is_logical: plan.sink_mode_is_logical,
                scale_percent: plan.sink_scale_percent,
            };
            video.sink_request.capability = MacSinkCapability {
                gamut: plan.sink_gamut,
                transfer: plan.sink_transfer,
                current_edr_headroom: plan.sink_current_edr_headroom,
                potential_edr_headroom: plan.sink_potential_edr_headroom,
                current_peak_luminance_nits: plan.sink_current_peak_luminance_nits,
                potential_peak_luminance_nits: plan.sink_potential_peak_luminance_nits,
                supports_frame_gated_hdr: plan.sink_supports_frame_gated_hdr,
                supports_hdr_tile_overlay: plan.sink_supports_hdr_tile_overlay,
                supports_per_frame_hdr_metadata: plan.sink_supports_per_frame_hdr_metadata,
            };
            video.sink_request.dynamic_range_transport =
                i32::try_from(plan.negotiated_dynamic_range_transport).unwrap_or_default();
            video.effective_display_state.gamut = plan.sink_gamut;
            video.effective_display_state.transfer = plan.sink_transfer;
            let mut audio = unsafe { (self.api.make_audio_configuration)(display_id) };
            audio.sample_rate = 48_000;
            audio.channel_count = i32::from(plan.audio_channels);
            audio.frame_size = AUDIO_FRAME_COUNT as i32;
            let mut error = [0_i8; 1024];
            state.audio_capture_failure = self.start_configured_capture(state.controller, video, audio, &mut error)?;
            error.fill(0);
            if plan.virtual_display {
                let key = state.workspace_key.as_ref().expect("workspace key");
                let outcome = unsafe {
                    (self.api.activate_workspace)(key.as_ptr(), error.as_mut_ptr(), error.len())
                };
                if !outcome.activated {
                    return Err(format!(
                        "workspace activation failed: {}",
                        error_text(&error)
                    ));
                }
                let event = workspace_isolation_event(outcome, error_text(&error))?;
                self.publish_runtime_event(event)?;
            }
            state.next_audio_timestamp = audio_timestamp(monotonic_nanoseconds());
            state.next_audio_deadline = self.stream_audio.then(Instant::now);
            state.plan = Some(plan);
            Ok(())
        })();
        if let Err(startup_error) = startup {
            return match self.stop_locked(&mut state) {
                Ok(()) => Err(startup_error),
                Err(cleanup_error) => Err(format!(
                    "{startup_error}; platform session rollback failed: {cleanup_error}"
                )),
            };
        }
        Ok(())
    }

    fn stop_session(&self) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
        // Keep platform lifecycle ownership while draining input. An event that
        // already passed the control-router admission check must complete before
        // this reset; later events observe the cleared platform plan below.
        let input_result = self.native_input.reset_all();
        let session_result = self.stop_locked(&mut state);
        match (input_result, session_result) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(input), Ok(())) => Err(format!("native input reset failed: {input}")),
            (Ok(()), Err(session)) => Err(session),
            (Err(input), Err(session)) => Err(format!(
                "native input reset failed: {input}; platform session stop also failed: {session}"
            )),
        }
    }

    fn reconfigure_session(&self, plan: PlatformSessionPlan) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
        let previous = state
            .plan
            .ok_or_else(|| "macOS dynamic display has no active session plan".to_owned())?;
        let reconfiguration =
            dynamic_display_reconfiguration_mode(previous.virtual_display, plan.virtual_display)?;
        if plan.video_format != previous.video_format
            || plan.audio_channels != previous.audio_channels
            || plan.enhanced_audio_quality != previous.enhanced_audio_quality
            || plan.play_audio_on_host != previous.play_audio_on_host
        {
            return Err(
                "dynamic display reconfiguration cannot change media format or audio layout"
                    .to_owned(),
            );
        }

        let previous_display_id = state.display_id;
        if matches!(
            reconfiguration,
            MacDynamicDisplayReconfigurationMode::PhysicalCapture
        ) && previous_display_id == 0
        {
            return Err(
                "macOS physical capture reconfiguration has no retained display".to_owned(),
            );
        }

        let mut display_id = previous_display_id;
        for step in mac_capture_reconfiguration_steps(reconfiguration) {
            match step {
                MacCaptureReconfigurationStep::StopCapturePair => {
                    self.stop_capture_pair_locked(&mut state);
                }
                MacCaptureReconfigurationStep::ReconfigureWorkspace => {
                    display_id = match self.reconfigure_workspace_locked(&state, plan) {
                        Ok(display_id) => {
                            // Swift has committed a replacement display before
                            // returning its ID. Publish it immediately so any
                            // subsequent rollback or teardown sees real state.
                            state.display_id = display_id;
                            state.input_display_id = display_id;
                            display_id
                        }
                        Err(error) => {
                            let rollback = self
                                .restore_retained_workspace_capture_locked(&mut state, previous);
                            return Err(match rollback {
                                Ok(rollback_display_id) => format!(
                                    "dynamic display reconfiguration failed and previous capture resumed on display {rollback_display_id}: {error}"
                                ),
                                Err(rollback) => format!(
                                    "dynamic display reconfiguration failed: {error}; rollback={rollback}"
                                ),
                            });
                        }
                    };
                }
                MacCaptureReconfigurationStep::StartCapturePair => {
                    if let Err(error) = self.start_capture_pair_locked(&mut state, plan, display_id)
                    {
                        return Err(match reconfiguration {
                            MacDynamicDisplayReconfigurationMode::RetainedWorkspace => {
                                match self.restore_retained_workspace_capture_locked(
                                    &mut state,
                                    previous,
                                ) {
                                    Ok(rollback_display_id) => format!(
                                        "dynamic capture reconfiguration failed and was rolled back to display {rollback_display_id}: {error}"
                                    ),
                                    Err(rollback) => format!(
                                        "dynamic capture reconfiguration failed: {error}; rollback={rollback}"
                                    ),
                                }
                            }
                            MacDynamicDisplayReconfigurationMode::PhysicalCapture => {
                                match self.start_capture_pair_locked(
                                    &mut state,
                                    previous,
                                    previous_display_id,
                                ) {
                                    Ok(()) => format!(
                                        "physical capture reconfiguration failed and was rolled back: {error}"
                                    ),
                                    Err(rollback) => format!(
                                        "physical capture reconfiguration failed: {error}; rollback capture={rollback}"
                                    ),
                                }
                            }
                        });
                    }
                }
            }
        }
        let (active_display_id, input_display_id) =
            mac_reconfigured_display_ids(reconfiguration, previous_display_id, display_id);
        state.display_id = active_display_id;
        state.input_display_id = input_display_id;
        state.input_display_bounds = match reconfiguration {
            MacDynamicDisplayReconfigurationMode::RetainedWorkspace => Some(
                resolve_display_geometry(LumenDisplayModeRequest {
                    width: plan.width,
                    height: plan.height,
                    scale_percent: u32::try_from(plan.sink_scale_percent)
                        .map_err(|_| "macOS native input display scale is invalid".to_owned())?,
                    dimensions_are_logical: plan.sink_mode_is_logical,
                    high_density: plan.sink_hidpi,
                })
                .map(|geometry| MacInputDisplayBounds {
                    width: f64::from(geometry.logical_width),
                    height: f64::from(geometry.logical_height),
                })
                .map_err(|status| {
                    format!("macOS native input display geometry is invalid: {status:?}")
                })?,
            ),
            MacDynamicDisplayReconfigurationMode::PhysicalCapture => None,
        };
        state.input_capture_viewport = match reconfiguration {
            MacDynamicDisplayReconfigurationMode::RetainedWorkspace => None,
            MacDynamicDisplayReconfigurationMode::PhysicalCapture => {
                Some(MacInputCaptureViewport {
                    width: f64::from(plan.width),
                    height: f64::from(plan.height),
                })
            }
        };
        state.plan = Some(plan);
        Ok(())
    }

    fn poll_encoded_video(&self) -> Result<Option<PlatformEncodedVideoFrame>, String> {
        let state = self
            .state
            .lock()
            .map_err(|_| "macOS video state is unavailable".to_owned())?;
        let mut sample = ptr::null();
        let record = unsafe { (self.api.pop_video)(state.controller, &mut sample) };
        if !record.has_value {
            return Ok(None);
        }
        if sample.is_null() {
            return Err("macOS video frame omitted its sample buffer".to_owned());
        }
        let result = copy_annex_b_sample(sample, record.codec, record.is_key_frame);
        unsafe { CFRelease(sample) };
        let (payload, timestamp) = result?;
        Ok(Some(PlatformEncodedVideoFrame {
            payload,
            decoder_configuration_record: None,
            presentation_time_90khz: timestamp,
            key_frame: record.is_key_frame,
            requires_bootstrap_acknowledgement: record.requires_bootstrap_acknowledgement,
            repair_keyframe: record.repair_key_frame,
        }))
    }

    fn poll_encoded_audio(&self) -> Result<Option<PlatformEncodedAudioPacket>, String> {
        if !self.stream_audio {
            return Ok(None);
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS audio state is unavailable".to_owned())?;
        let mut event_message = [0_i8; 1024];
        loop {
            event_message.fill(0);
            let event = unsafe {
                (self.api.pop_audio_event)(
                    state.controller,
                    event_message.as_mut_ptr(),
                    event_message.len(),
                )
            };
            if !event.has_value {
                break;
            }
            match event.kind {
                0 => state.audio_capture_failure = None,
                3 => {
                    let message = error_text(&event_message);
                    state.audio_capture_failure = Some(if message.is_empty() {
                        "macOS audio capture failed".to_owned()
                    } else {
                        message
                    });
                }
                _ => {}
            }
        }
        if let Some(failure) = &state.audio_capture_failure {
            return Err(failure.clone());
        }
        let packet_bytes = AUDIO_FRAME_COUNT * state.audio_channels * std::mem::size_of::<f32>();
        for _ in 0..8 {
            if state.pcm.len() >= packet_bytes {
                break;
            }
            let mut copied = 0;
            let record = unsafe {
                (self.api.pop_audio)(
                    state.controller,
                    state.audio_scratch.as_mut_ptr().cast(),
                    state.audio_scratch.len(),
                    &mut copied,
                )
            };
            if !record.has_value {
                break;
            }
            if record.sample_rate != 48_000
                || usize::try_from(record.channel_count).ok() != Some(state.audio_channels)
                || copied != record.pcm_byte_count
                || copied > state.audio_scratch.len()
            {
                state.pcm.clear();
                return Err("macOS audio capture returned inconsistent PCM metadata".to_owned());
            }
            let bytes = state.audio_scratch[..copied].to_vec();
            state.pcm.extend_from_slice(&bytes);
        }
        let now = Instant::now();
        let Some(deadline) = ready_audio_packet_deadline(&mut state, now, packet_bytes) else {
            return Ok(None);
        };
        let samples = state.pcm[..packet_bytes]
            .chunks_exact(4)
            .map(|bytes| f32::from_le_bytes(bytes.try_into().expect("four PCM bytes")))
            .collect::<Vec<_>>();
        let packet = state
            .opus
            .as_mut()
            .ok_or_else(|| "macOS Opus encoder is unavailable".to_owned())?
            .encode(&samples, AUDIO_FRAME_COUNT as i32)?;
        state.pcm.drain(..packet_bytes);
        let timestamp = state.next_audio_timestamp;
        state.next_audio_timestamp = state
            .next_audio_timestamp
            .wrapping_add(AUDIO_FRAME_COUNT as u32);
        state.next_audio_deadline = Some(deadline + AUDIO_PACKET_DURATION);
        Ok(Some(PlatformEncodedAudioPacket {
            payload: packet,
            presentation_time_48khz: timestamp,
            duration_frames: AUDIO_FRAME_COUNT as u32,
        }))
    }

    fn reset_media_queue(&self, session_epoch: u32) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS media state is unavailable".to_owned())?;
        if state.plan.as_ref().map(|plan| plan.session_epoch) != Some(session_epoch) {
            return Err(format!(
                "macOS media queue reset does not belong to session epoch {session_epoch}"
            ));
        }
        unsafe { (self.api.reset_media_queues)(state.controller) };
        // The bridge queues contain source PCM, not Opus packets. Drop the
        // partially accumulated packet too so a resume cannot encode samples
        // that crossed the park boundary.
        state.pcm.clear();
        state.next_audio_deadline = self.stream_audio.then(Instant::now);
        Ok(())
    }

    fn handle_control_event(
        &self,
        session_epoch: u32,
        event: PlatformControlEvent,
    ) -> Result<(), String> {
        match event {
            PlatformControlEvent::RequestIdrFrame
            | PlatformControlEvent::InvalidateReferenceFrames { .. } => {
                unsafe { (self.api.request_key_frame)() };
                Ok(())
            }
            PlatformControlEvent::RequestPeriodicIdrFrame => unsafe {
                (self.api.request_periodic_key_frame)()
                    .then_some(())
                    .ok_or_else(|| {
                        "macOS video periodic IDR gate could not be armed".to_owned()
                    })
            },
            PlatformControlEvent::ResumeVideoEncodingAfterCodecAck => {
                unsafe { (self.api.resume_video_encoding_after_codec_ack)() }
                    .then_some(())
                    .ok_or_else(|| {
                        "macOS video encoding could not resume after codec acknowledgement"
                            .to_owned()
                    })
            }
            PlatformControlEvent::SetVideoDeliveryPolicy {
                policy_revision,
                bitrate_kbps,
                admission_divisor,
            } => {
                unsafe {
                    (self.api.set_video_delivery_policy)(
                        session_epoch,
                        policy_revision,
                        bitrate_kbps,
                        admission_divisor,
                    )
                }
                    .then_some(())
                    .ok_or_else(|| {
                        format!(
                            "macOS VideoToolbox rejected adaptive delivery bitrate={bitrate_kbps} kbps admission-divisor={admission_divisor}"
                        )
                    })
            }
            PlatformControlEvent::ResetInput => Ok(()),
            PlatformControlEvent::ExecuteServerCommand { index } => {
                self.application.execute_server_command(index)
            }
        }
    }

    fn handle_native_input(
        &self,
        session_epoch: u32,
        event: PlatformNativeInputEvent,
    ) -> Result<(), String> {
        let result: Result<bool, String> = {
            let state = self
                .state
                .lock()
                .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
            if state.plan.is_none() {
                Err("macOS native input has no active platform session".to_owned())
            } else if !session_epoch_matches(
                state.plan.as_ref().map(|plan| plan.session_epoch),
                session_epoch,
            ) {
                Err(format!(
                    "macOS native input does not belong to session epoch {session_epoch}"
                ))
            } else if let PlatformNativeInputEvent::PointerButton {
                pointer_id,
                button,
                pressed,
                absolute_position: Some((normalized_x, normalized_y)),
            } = &event
            {
                let display_id = state.input_display_id;
                if display_id == 0 {
                    Err("macOS positioned pointer input has no active display".to_owned())
                } else {
                    self.native_input.handle_positioned_button_activity(
                        session_epoch,
                        display_id,
                        state.input_display_bounds,
                        state.input_capture_viewport,
                        MacPositionedButtonInput {
                            pointer_id: *pointer_id,
                            button: *button,
                            pressed: *pressed,
                            normalized_x: *normalized_x,
                            normalized_y: *normalized_y,
                        },
                    )
                }
            } else {
                self.native_input.handle_activity(session_epoch, event)
            }
        };
        if matches!(result, Ok(true)) {
            // Only a native event that changed host input state is trusted as activity. The
            // bridge reopens the source pacer and rebases idle confirmation;
            // it does not request a key frame or reset media generation.
            unsafe { (self.api.wake_unchanged_content_cadence)(session_epoch) };
        }
        result.map(|_| ())
    }

    fn handle_native_motion(
        &self,
        session_epoch: u32,
        event: crate::PlatformNativeMotionEvent,
    ) -> Result<(), String> {
        let result: Result<bool, String> = {
            let state = self
                .state
                .lock()
                .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
            if state.plan.is_none() {
                Err("macOS native motion has no active platform session".to_owned())
            } else if !session_epoch_matches(
                state.plan.as_ref().map(|plan| plan.session_epoch),
                session_epoch,
            ) {
                Err(format!(
                    "macOS native motion does not belong to session epoch {session_epoch}"
                ))
            } else {
                let display_id = state.input_display_id;
                if display_id == 0 {
                    Err("macOS native motion has no active display".to_owned())
                } else {
                    self.native_input.handle_motion(
                        session_epoch,
                        display_id,
                        state.input_display_bounds,
                        state.input_capture_viewport,
                        event,
                    )
                }
            }
        };
        if matches!(result, Ok(true)) {
            unsafe { (self.api.wake_unchanged_content_cadence)(session_epoch) };
        }
        result.map(|_| ())
    }

    fn reset_native_input(&self, session_epoch: u32) -> Result<(), String> {
        self.native_input.reset(session_epoch)
    }

    fn publish_runtime_event(&self, event: PlatformRuntimeEvent) -> Result<(), String> {
        let message = event
            .message
            .map(CString::new)
            .transpose()
            .map_err(|_| "runtime event contains a null byte".to_owned())?;
        unsafe {
            (self.api.publish_runtime_event)(
                match event.disposition {
                    PlatformRuntimeEventDisposition::Raised => 0,
                    PlatformRuntimeEventDisposition::Cleared => 1,
                },
                match event.severity {
                    PlatformRuntimeEventSeverity::Warning => 0,
                    PlatformRuntimeEventSeverity::Error => 1,
                },
                event.code as u32,
                message.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
            )
        };
        Ok(())
    }
}

impl Drop for MacPlatformSessionControl {
    fn drop(&mut self) {
        if let Ok(mut state) = self.state.lock() {
            let _ = self.stop_locked(&mut state);
            unsafe { (self.api.destroy_controller)(state.controller) };
            state.controller = ptr::null_mut();
        }
    }
}
