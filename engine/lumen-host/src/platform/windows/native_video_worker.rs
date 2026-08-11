use super::*;

pub(super) fn run_media_foundation_session(worker: NativeMediaFoundationWorker) {
    let NativeMediaFoundationWorker {
        plan,
        driver,
        commands,
        ready,
        sink,
        state,
        retirement_gate,
        frame_delivery,
        adaptive_event_publisher,
        content_wake_latch,
    } = worker;
    let session_epoch = plan.session_epoch;
    if let Err(error) = unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) } {
        let _ = ready.send(Err(format!(
            "Windows Media Foundation startup failed: {error}"
        )));
        return;
    }
    let catalog = match NativeVideoEncoderCatalog::discover() {
        Ok(catalog) => catalog,
        Err(error) => {
            let _ = ready.send(Err(error));
            let _ = unsafe { MFShutdown() };
            return;
        }
    };
    let mut runtime = match start_runtime(
        &catalog,
        plan,
        driver,
        &sink,
        frame_delivery,
        NativeVideoRuntimeContext {
            retirement_gate: Arc::clone(&retirement_gate),
            adaptive_event_publisher,
            content_wake_latch,
        },
    ) {
        Ok(runtime) => Some(runtime),
        Err(error) => {
            set_worker_state(&state, false, Some(error.clone()));
            let _ = ready.send(Err(error));
            drop(catalog);
            let _ = unsafe { MFShutdown() };
            return;
        }
    };
    set_worker_state(&state, true, None);
    if ready.send(Ok(())).is_err() {
        let _ = stop_runtime(&mut runtime);
        drop(catalog);
        let _ = unsafe { MFShutdown() };
        return;
    }
    while !retirement_gate.is_retired() {
        let command = match commands.try_recv() {
            Ok(command) => Some(command),
            Err(mpsc::TryRecvError::Empty) => None,
            Err(mpsc::TryRecvError::Disconnected) => break,
        };
        if let Some(command) = command {
            match command {
                NativeMediaFoundationCommand::ResetMediaEpoch { response } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(NativeVideoRuntime::reset_media_epoch);
                    let _ = response.send(finish_control_command(&mut runtime, result));
                }
                NativeMediaFoundationCommand::RequestKeyFrame { response } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(|runtime| {
                            if runtime.awaiting_bootstrap_result {
                                Ok(())
                            } else {
                                runtime.request_repair_key_frame()
                            }
                        });
                    let _ = response.send(finish_control_command(&mut runtime, result));
                }
                NativeMediaFoundationCommand::RequestPeriodicKeyFrame { response } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(|runtime| {
                            if runtime.awaiting_bootstrap_result
                                || runtime.repair_keyframe_pending
                            {
                                Err(
                                    "Windows periodic IDR cannot arm while another bootstrap or repair is pending"
                                        .to_owned(),
                                )
                            } else {
                                runtime.request_periodic_key_frame()
                            }
                        });
                    let _ = response.send(finish_control_command(&mut runtime, result));
                }
                NativeMediaFoundationCommand::ResumeAfterBootstrap { response } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(NativeVideoRuntime::resume_after_bootstrap);
                    let _ = response.send(finish_control_command(&mut runtime, result));
                }
                NativeMediaFoundationCommand::SetBitrate {
                    session_epoch,
                    bitrate_bps,
                    admission_divisor,
                    response,
                } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(|runtime| {
                            runtime.set_video_delivery_policy(
                                session_epoch,
                                bitrate_bps,
                                admission_divisor,
                            )
                        });
                    let _ = response.send(finish_control_command(&mut runtime, result));
                }
            }
            continue;
        }
        if runtime
            .as_ref()
            .expect("active Windows worker owns a video runtime")
            .awaiting_bootstrap_result
        {
            thread::sleep(Duration::from_millis(1));
            continue;
        }
        let encoded = runtime
            .as_mut()
            .expect("active Windows worker owns a video runtime")
            .encode_next(ACTIVE_CAPTURE_POLL_MILLISECONDS);
        match encoded.and_then(|sample| {
            if let Some(sample) = sample {
                let pause_for_bootstrap = sample_requires_bootstrap_pause(&sample, false);
                if retirement_gate.is_retired() {
                    return Ok(());
                }
                let sink_result = sink(session_epoch, sample)?;
                let runtime = runtime
                    .as_mut()
                    .expect("encoded frame came from an active runtime");
                runtime.record_sink_result(sink_result);
                if pause_for_bootstrap {
                    runtime.pause_after_bootstrap()?;
                }
                if sink_result.request_key_frame {
                    runtime.request_repair_key_frame()?;
                }
            }
            Ok(())
        }) {
            Ok(()) => {}
            Err(error) => {
                let shutdown = stop_runtime(&mut runtime).err();
                let error = shutdown
                    .map(|shutdown| format!("{error}; {shutdown}"))
                    .unwrap_or(error);
                set_worker_state(&state, false, Some(error));
                break;
            }
        }
    }
    while let Ok(command) = commands.try_recv() {
        reject_retired_command(command);
    }
    let _ = stop_runtime(&mut runtime);
    set_worker_running(&state, false);
    drop(catalog);
    let _ = unsafe { MFShutdown() };
}

fn finish_control_command(
    runtime: &mut Option<NativeVideoRuntime>,
    result: Result<(), String>,
) -> Result<(), String> {
    let Some(runtime) = runtime.as_mut() else {
        return result;
    };
    let resume = runtime.resume_after_control_interrupt();
    match (result, resume) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Err(error), Err(resume_error)) => Err(format!(
            "{error}; Windows frame delivery resume failed: {resume_error}"
        )),
    }
}

fn reject_retired_command(command: NativeMediaFoundationCommand) {
    let response = match command {
        NativeMediaFoundationCommand::ResetMediaEpoch { response }
        | NativeMediaFoundationCommand::RequestKeyFrame { response }
        | NativeMediaFoundationCommand::RequestPeriodicKeyFrame { response }
        | NativeMediaFoundationCommand::ResumeAfterBootstrap { response }
        | NativeMediaFoundationCommand::SetBitrate { response, .. } => response,
    };
    let _ = response.send(Err(
        "Windows Media Foundation session was retired before command execution".to_owned(),
    ));
}

fn start_runtime(
    catalog: &NativeVideoEncoderCatalog,
    plan: NativeVideoEncoderPlan,
    driver: DriverHandle,
    sink: &NativeVideoSink,
    frame_delivery: Arc<FrameDeliveryOwnership>,
    context: NativeVideoRuntimeContext,
) -> Result<NativeVideoRuntime, String> {
    let NativeVideoRuntimeContext {
        retirement_gate,
        adaptive_event_publisher,
        content_wake_latch,
    } = context;
    let capture = NativeIddCxCapture::open(driver, plan.ten_bit, frame_delivery)?;
    let encoder = catalog.activate(plan, capture.device())?;
    let cadence_controller = WindowsAdaptiveFrameCadence::new(plan.frames_per_second)?;
    let unchanged_content_cadence = WindowsUnchangedContentCadence::new(plan.frames_per_second)?;
    let effective_target_frame_rate = plan.frames_per_second;
    let mut runtime = NativeVideoRuntime {
        capture,
        encoder,
        plan,
        last_source_timestamp_90khz: None,
        unwrapped_source_timestamp_90khz: 0,
        last_admitted_timestamp_hns: None,
        cadence_controller,
        unchanged_content_cadence,
        cadence_admission: WindowsCadenceAdmission::new(),
        adaptive_target_frame_rate: effective_target_frame_rate,
        content_target_frame_rate: effective_target_frame_rate,
        effective_target_frame_rate,
        source_frame_count: 0,
        output_frame_count: 0,
        pending_drop_count: 0,
        last_callback_latency_milliseconds: 0.0,
        last_callback_time_seconds: None,
        observation_clock: Instant::now(),
        content_wake_latch,
        awaiting_bootstrap_result: false,
        repair_keyframe_pending: false,
        periodic_keyframe_pending: false,
        admission_divisor: 1,
        retirement_gate,
        adaptive_event_publisher,
    };
    runtime.encoder.force_key_frame()?;
    let deadline = Instant::now() + INITIAL_FRAME_TIMEOUT;
    loop {
        if Instant::now() >= deadline {
            return Err("Windows native video readiness timed out".to_owned());
        }
        let Some(encoded) = runtime.encode_next(200)? else {
            continue;
        };
        if encoded.presentation_time_90khz != 0 || !encoded.key_frame {
            return Err(
                "Windows hardware encoder did not start on the required timestamp-zero key frame"
                    .to_owned(),
            );
        }
        let pause_for_bootstrap = sample_requires_bootstrap_pause(&encoded, true);
        let sink_result = sink(plan.session_epoch, encoded)?;
        runtime.record_sink_result(sink_result);
        if pause_for_bootstrap {
            runtime.pause_after_bootstrap()?;
        }
        if sink_result.request_key_frame {
            runtime.request_repair_key_frame()?;
        }
        return Ok(runtime);
    }
}

pub(super) fn sample_requires_bootstrap_pause(
    sample: &NativeEncodedVideoSample,
    initial: bool,
) -> bool {
    sample.key_frame && (initial || sample.repair_keyframe || sample.periodic_keyframe)
}

fn stop_runtime(runtime: &mut Option<NativeVideoRuntime>) -> Result<(), String> {
    match runtime.take() {
        Some(mut runtime) => runtime.encoder.shutdown(),
        None => Ok(()),
    }
}

fn set_worker_state(state: &Mutex<NativeVideoWorkerState>, running: bool, error: Option<String>) {
    if let Ok(mut state) = state.lock() {
        state.running = running;
        state.error = error;
    }
}

fn set_worker_running(state: &Mutex<NativeVideoWorkerState>, running: bool) {
    if let Ok(mut state) = state.lock() {
        state.running = running;
    }
}
