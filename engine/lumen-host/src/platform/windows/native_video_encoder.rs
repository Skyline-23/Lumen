use super::*;

#[derive(Default)]
pub(super) struct NativeVideoEncoderCatalog {
    h264: Option<IMFActivate>,
    hevc: Option<IMFActivate>,
    av1: Option<IMFActivate>,
}

pub(super) struct NativeVideoEncoderSession {
    activation: IMFActivate,
    transform: IMFTransform,
    codec_api: ICodecAPI,
    events: IMFMediaEventGenerator,
    _device_manager: IMFDXGIDeviceManager,
    output_stream: MFT_OUTPUT_STREAM_INFO,
    frame_duration_hns: i64,
    pending_input_requests: usize,
    pending_output_samples: usize,
    is_shutdown: bool,
}

impl NativeVideoEncoderCatalog {
    pub(super) fn discover() -> Result<Self, String> {
        Ok(Self {
            h264: hardware_encoder_activation(MFVideoFormat_H264)?,
            hevc: hardware_encoder_activation(MFVideoFormat_HEVC)?,
            av1: hardware_encoder_activation(MFVideoFormat_AV1)?,
        })
    }

    pub(super) fn activate(
        &self,
        plan: NativeVideoEncoderPlan,
        device: &ID3D11Device,
    ) -> Result<NativeVideoEncoderSession, String> {
        let activation = match plan.codec {
            PlatformVideoCodec::H264 => self.h264.as_ref(),
            PlatformVideoCodec::Hevc => self.hevc.as_ref(),
            PlatformVideoCodec::Av1 => self.av1.as_ref(),
            PlatformVideoCodec::ShadowVc => None,
        }
        .ok_or_else(|| {
            format!(
                "Windows has no hardware Media Foundation encoder for {}",
                codec_name(plan.codec)
            )
        })?;
        let transform =
            unsafe { activation.ActivateObject::<IMFTransform>() }.map_err(|error| {
                format!(
                    "Windows Media Foundation could not activate the {} hardware encoder: {error}",
                    codec_name(plan.codec)
                )
            })?;
        let configured = configure_transform(&transform, plan, device).and_then(|manager| {
            unsafe {
                transform
                    .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
                    .map_err(|error| format!("encoder begin-streaming failed: {error}"))?;
                transform
                    .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
                    .map_err(|error| format!("encoder start-of-stream failed: {error}"))?;
            }
            Ok(manager)
        });
        let manager = match configured {
            Ok(manager) => manager,
            Err(error) => {
                let _ = unsafe { activation.ShutdownObject() };
                return Err(format!(
                    "Windows Media Foundation could not start the {} hardware encoder: {error}",
                    codec_name(plan.codec)
                ));
            }
        };
        let events = match transform.cast::<IMFMediaEventGenerator>() {
            Ok(events) => events,
            Err(error) => {
                let _ = unsafe { activation.ShutdownObject() };
                return Err(format!(
                    "Windows {} hardware encoder has no asynchronous event surface: {error}",
                    codec_name(plan.codec)
                ));
            }
        };
        let codec_api = match transform.cast::<ICodecAPI>() {
            Ok(codec_api) => codec_api,
            Err(error) => {
                let _ = unsafe { activation.ShutdownObject() };
                return Err(format!(
                    "Windows {} hardware encoder has no codec control surface: {error}",
                    codec_name(plan.codec)
                ));
            }
        };
        let output_stream = match unsafe { transform.GetOutputStreamInfo(0) } {
            Ok(output_stream) => output_stream,
            Err(error) => {
                let _ = unsafe { activation.ShutdownObject() };
                return Err(format!(
                    "Windows {} hardware encoder output description failed: {error}",
                    codec_name(plan.codec)
                ));
            }
        };
        Ok(NativeVideoEncoderSession {
            activation: activation.clone(),
            transform,
            codec_api,
            events,
            _device_manager: manager,
            output_stream,
            frame_duration_hns: 10_000_000_i64 / i64::from(plan.frames_per_second),
            pending_input_requests: 0,
            pending_output_samples: 0,
            is_shutdown: false,
        })
    }
}

impl NativeVideoEncoderSession {
    pub(super) fn frame_duration_hns(&self) -> i64 {
        self.frame_duration_hns
    }

    pub(super) fn set_bitrate(&self, bitrate_bps: u32) -> Result<u32, String> {
        if bitrate_bps == 0 {
            return Err("Windows adaptive video bitrate must be nonzero".to_owned());
        }
        let api = &CODECAPI_AVEncCommonMeanBitRate;
        let raw = Interface::as_raw(&self.codec_api);
        let vtable = Interface::vtable(&self.codec_api);
        let supported = unsafe { (vtable.IsSupported)(raw, api) };
        if supported.0 != 0 {
            return Err(format!(
                "Windows encoder does not support runtime mean bitrate control: {supported:?}"
            ));
        }
        let modifiable = unsafe { (vtable.IsModifiable)(raw, api) };
        if modifiable.0 != 0 {
            return Err(format!(
                "Windows encoder mean bitrate is not runtime-modifiable: {modifiable:?}"
            ));
        }
        self.validate_bitrate_parameter(bitrate_bps)?;

        let requested = variant_from_ui4(bitrate_bps);
        let set = unsafe { (vtable.SetValue)(raw, api, &requested) };
        if set.0 != 0 {
            return Err(format!(
                "Windows encoder rejected runtime mean bitrate {bitrate_bps} bps: {set:?}"
            ));
        }
        let mut applied = VARIANT::default();
        let read = unsafe { (vtable.GetValue)(raw, api, &mut applied) };
        if read.0 != 0 {
            return Err(format!(
                "Windows encoder did not expose runtime mean bitrate readback: {read:?}"
            ));
        }
        let applied = variant_ui4(&applied)
            .ok_or_else(|| "Windows encoder mean bitrate readback was not VT_UI4".to_owned())?;
        if applied != bitrate_bps {
            return Err(format!(
                "Windows encoder mean bitrate readback mismatch requested={bitrate_bps} applied={applied}"
            ));
        }
        Ok(applied)
    }

    fn validate_bitrate_parameter(&self, bitrate_bps: u32) -> Result<(), String> {
        let api = &CODECAPI_AVEncCommonMeanBitRate;
        let raw = Interface::as_raw(&self.codec_api);
        let vtable = Interface::vtable(&self.codec_api);
        let mut values = ptr::null_mut::<VARIANT>();
        let mut values_count = 0_u32;
        let discrete =
            unsafe { (vtable.GetParameterValues)(raw, api, &mut values, &mut values_count) };
        if discrete.0 == 0 {
            let values = CoTaskVariantArray::new(values, values_count);
            let admitted = values
                .as_slice()
                .iter()
                .filter_map(variant_ui4)
                .any(|value| value == bitrate_bps);
            return admitted.then_some(()).ok_or_else(|| {
                format!("Windows encoder does not admit mean bitrate {bitrate_bps} bps")
            });
        }

        let mut minimum = VARIANT::default();
        let mut maximum = VARIANT::default();
        let mut step = VARIANT::default();
        let range =
            unsafe { (vtable.GetParameterRange)(raw, api, &mut minimum, &mut maximum, &mut step) };
        if range.0 != 0 {
            return Ok(());
        }
        let minimum = variant_ui4(&minimum)
            .ok_or_else(|| "Windows encoder mean bitrate minimum was not VT_UI4".to_owned())?;
        let maximum = variant_ui4(&maximum)
            .ok_or_else(|| "Windows encoder mean bitrate maximum was not VT_UI4".to_owned())?;
        let step = variant_ui4(&step)
            .ok_or_else(|| "Windows encoder mean bitrate step was not VT_UI4".to_owned())?;
        let in_range = (minimum..=maximum).contains(&bitrate_bps);
        let on_step = step == 0 || bitrate_bps.saturating_sub(minimum).is_multiple_of(step);
        (in_range && on_step).then_some(()).ok_or_else(|| {
            format!(
                "Windows encoder mean bitrate {bitrate_bps} bps is outside range {minimum}...{maximum} step={step}"
            )
        })
    }

    pub(super) fn force_key_frame(&self) -> Result<(), String> {
        let enabled = VARIANT::from(true);
        unsafe {
            self.codec_api
                .SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &enabled)
        }
        .map_err(|error| format!("Windows hardware encoder rejected a key-frame request: {error}"))
    }

    pub(super) fn encode(
        &mut self,
        surface: &NativeEncoderSurface,
        presentation_time_hns: i64,
        duration_hns: i64,
    ) -> Result<NativeEncodedVideoSample, String> {
        self.wait_for_input_request()?;
        let sample = create_input_sample(surface, presentation_time_hns, duration_hns)?;
        unsafe { self.transform.ProcessInput(0, &sample, 0) }
            .map_err(|error| format!("Windows hardware encoder rejected a GPU frame: {error}"))?;
        self.wait_for_output_sample()?;
        let sample = self.process_output()?;
        encoded_video_sample(&sample)
    }

    fn wait_for_input_request(&mut self) -> Result<(), String> {
        if self.pending_input_requests != 0 {
            self.pending_input_requests -= 1;
            return Ok(());
        }
        self.wait_for_transform_credit(true)
    }

    fn wait_for_output_sample(&mut self) -> Result<(), String> {
        if self.pending_output_samples != 0 {
            self.pending_output_samples -= 1;
            return Ok(());
        }
        self.wait_for_transform_credit(false)
    }

    fn wait_for_transform_credit(&mut self, needs_input: bool) -> Result<(), String> {
        let input_event = u32::try_from(METransformNeedInput.0)
            .map_err(|_| "Windows input event identifier is invalid".to_owned())?;
        let output_event = u32::try_from(METransformHaveOutput.0)
            .map_err(|_| "Windows output event identifier is invalid".to_owned())?;
        let deadline = Instant::now() + TRANSFORM_EVENT_TIMEOUT;
        loop {
            if Instant::now() >= deadline {
                return Err(format!(
                    "Windows hardware encoder timed out waiting for {}",
                    if needs_input { "input" } else { "output" }
                ));
            }
            match unsafe { self.events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                Ok(event) => {
                    let status = unsafe { event.GetStatus() }.map_err(|error| {
                        format!("Windows hardware encoder event status failed: {error}")
                    })?;
                    status.ok().map_err(|error| {
                        format!("Windows hardware encoder reported an event failure: {error}")
                    })?;
                    let event_type = unsafe { event.GetType() }.map_err(|error| {
                        format!("Windows hardware encoder event type failed: {error}")
                    })?;
                    if event_type == input_event {
                        if needs_input {
                            return Ok(());
                        }
                        self.pending_input_requests = self
                            .pending_input_requests
                            .checked_add(1)
                            .ok_or_else(|| "Windows encoder input credit overflowed".to_owned())?;
                        continue;
                    }
                    if event_type == output_event {
                        if !needs_input {
                            return Ok(());
                        }
                        self.pending_output_samples = self
                            .pending_output_samples
                            .checked_add(1)
                            .ok_or_else(|| "Windows encoder output credit overflowed".to_owned())?;
                        continue;
                    }
                    return Err(format!(
                        "Windows hardware encoder produced unsupported event {event_type}"
                    ));
                }
                Err(error) if error.code() == MF_E_NO_EVENTS_AVAILABLE => {
                    thread::sleep(Duration::from_millis(1));
                }
                Err(error) => {
                    return Err(format!(
                        "Windows hardware encoder event retrieval failed: {error}"
                    ));
                }
            }
        }
    }

    fn process_output(&self) -> Result<IMFSample, String> {
        let supplied_sample = if output_stream_provides_samples(self.output_stream.dwFlags)? {
            None
        } else {
            Some(create_output_sample(
                self.output_stream.cbSize,
                self.output_stream.cbAlignment,
            )?)
        };
        let mut output = MFT_OUTPUT_DATA_BUFFER {
            dwStreamID: 0,
            pSample: ManuallyDrop::new(supplied_sample),
            dwStatus: 0,
            pEvents: ManuallyDrop::new(None),
        };
        let mut status = 0_u32;
        let result = unsafe {
            self.transform
                .ProcessOutput(0, slice::from_mut(&mut output), &mut status)
        };
        let sample = unsafe { ManuallyDrop::take(&mut output.pSample) };
        let events = unsafe { ManuallyDrop::take(&mut output.pEvents) };
        drop(events);
        result.map_err(|error| {
            format!("Windows hardware encoder output processing failed: {error}")
        })?;
        sample.ok_or_else(|| "Windows hardware encoder produced no output sample".to_owned())
    }

    pub(super) fn shutdown(&mut self) -> Result<(), String> {
        if self.is_shutdown {
            return Ok(());
        }
        self.is_shutdown = true;
        let end_of_stream = unsafe {
            self.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0)
        }
        .map_err(|error| format!("Windows encoder end-of-stream failed: {error}"));
        let end_streaming = unsafe {
            self.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0)
        }
        .map_err(|error| format!("Windows encoder end-streaming failed: {error}"));
        let flush = unsafe { self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0) }
            .map_err(|error| format!("Windows encoder flush failed: {error}"));
        let shutdown = unsafe { self.activation.ShutdownObject() }
            .map_err(|error| format!("Windows hardware encoder shutdown failed: {error}"));
        combine_results([end_of_stream, end_streaming, flush, shutdown])
    }
}

pub(super) fn variant_from_ui4(value: u32) -> VARIANT {
    VARIANT::from(value)
}

pub(super) fn variant_ui4(value: &VARIANT) -> Option<u32> {
    (value.vt() == VT_UI4)
        .then(|| u32::try_from(value).ok())
        .flatten()
}

struct CoTaskVariantArray {
    values: *mut VARIANT,
    count: usize,
}

impl CoTaskVariantArray {
    fn new(values: *mut VARIANT, count: u32) -> Self {
        Self {
            values,
            count: count as usize,
        }
    }

    fn as_slice(&self) -> &[VARIANT] {
        if self.values.is_null() || self.count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(self.values, self.count) }
        }
    }
}

impl Drop for CoTaskVariantArray {
    fn drop(&mut self) {
        if self.values.is_null() {
            return;
        }
        unsafe {
            visit_variant_elements(self.values, self.count, |value| {
                let _ = VariantClear(value);
            });
            CoTaskMemFree(Some(self.values.cast()));
        }
    }
}

pub(super) unsafe fn visit_variant_elements(
    values: *mut VARIANT,
    count: usize,
    mut visit: impl FnMut(*mut VARIANT),
) {
    for index in 0..count {
        visit(unsafe { values.add(index) });
    }
}

impl Drop for NativeVideoEncoderSession {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

pub(super) fn create_input_sample(
    surface: &NativeEncoderSurface,
    presentation_time_hns: i64,
    duration_hns: i64,
) -> Result<IMFSample, String> {
    let buffer =
        unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, surface.texture(), 0, false) }
            .map_err(|error| format!("Windows DXGI media buffer creation failed: {error}"))?;
    let sample = unsafe { MFCreateSample() }
        .map_err(|error| format!("Windows input media sample creation failed: {error}"))?;
    unsafe { sample.AddBuffer(&buffer) }
        .map_err(|error| format!("Windows input sample rejected its DXGI buffer: {error}"))?;
    unsafe { sample.SetSampleTime(presentation_time_hns) }
        .map_err(|error| format!("Windows input sample rejected its timestamp: {error}"))?;
    unsafe { sample.SetSampleDuration(duration_hns) }
        .map_err(|error| format!("Windows input sample rejected its duration: {error}"))?;
    Ok(sample)
}

pub(super) fn create_output_sample(capacity: u32, alignment: u32) -> Result<IMFSample, String> {
    if capacity == 0 {
        return Err("Windows hardware encoder reported zero output capacity".to_owned());
    }
    if alignment != 0 && !alignment.is_power_of_two() {
        return Err(format!(
            "Windows hardware encoder requested invalid output alignment {alignment}"
        ));
    }
    let alignment_mask = alignment.saturating_sub(1);
    let buffer = unsafe { MFCreateAlignedMemoryBuffer(capacity, alignment_mask) }
        .map_err(|error| format!("Windows output media buffer creation failed: {error}"))?;
    let sample = unsafe { MFCreateSample() }
        .map_err(|error| format!("Windows output media sample creation failed: {error}"))?;
    unsafe { sample.AddBuffer(&buffer) }
        .map_err(|error| format!("Windows output sample rejected its buffer: {error}"))?;
    Ok(sample)
}

pub(super) fn output_stream_provides_samples(flags: u32) -> Result<bool, String> {
    let provides = u32::try_from(MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0)
        .map_err(|_| "Windows output sample-provider flag is invalid".to_owned())?;
    let can_provide = u32::try_from(MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0)
        .map_err(|_| "Windows optional sample-provider flag is invalid".to_owned())?;
    Ok(flags & (provides | can_provide) != 0)
}

pub(super) fn encoded_video_sample(sample: &IMFSample) -> Result<NativeEncodedVideoSample, String> {
    let buffer = unsafe { sample.ConvertToContiguousBuffer() }
        .map_err(|error| format!("Windows encoded sample could not be made contiguous: {error}"))?;
    let mut bytes = ptr::null_mut();
    let mut length = 0_u32;
    unsafe { buffer.Lock(&mut bytes, None, Some(&mut length)) }
        .map_err(|error| format!("Windows encoded sample lock failed: {error}"))?;
    let payload_result = if bytes.is_null() || length == 0 {
        Err("Windows hardware encoder returned an empty media buffer".to_owned())
    } else {
        Ok(unsafe { slice::from_raw_parts(bytes, length as usize) }.to_vec())
    };
    unsafe { buffer.Unlock() }
        .map_err(|error| format!("Windows encoded sample unlock failed: {error}"))?;
    let payload = payload_result?;
    let presentation_time_hns = unsafe { sample.GetSampleTime() }
        .map_err(|error| format!("Windows encoded sample has no presentation time: {error}"))?;
    let presentation_time_90khz = timestamp_90khz(presentation_time_hns)?;
    let key_frame = unsafe { sample.GetUINT32(&MFSampleExtension_CleanPoint) }.unwrap_or(0) != 0;
    Ok(NativeEncodedVideoSample {
        payload,
        presentation_time_90khz,
        key_frame,
        repair_keyframe: false,
        periodic_keyframe: false,
    })
}

pub(super) fn timestamp_90khz(timestamp_hns: i64) -> Result<u32, String> {
    let timestamp = u64::try_from(timestamp_hns)
        .map_err(|_| "Windows encoded sample timestamp is negative".to_owned())?;
    let timestamp = u128::from(timestamp)
        .checked_mul(9)
        .and_then(|value| value.checked_div(1_000))
        .ok_or_else(|| "Windows encoded sample timestamp overflowed".to_owned())?;
    let modulus = u128::from(u32::MAX) + 1;
    u32::try_from(timestamp % modulus)
        .map_err(|_| "Windows encoded sample timestamp modulo conversion failed".to_owned())
}

pub(super) fn capture_timestamp_hns(unwrapped_timestamp_90khz: u64) -> Result<i64, String> {
    let timestamp_hns = u128::from(unwrapped_timestamp_90khz)
        .checked_mul(10_000_000)
        .and_then(|value| value.checked_div(90_000))
        .ok_or_else(|| "Windows capture timestamp conversion overflowed".to_owned())?;
    i64::try_from(timestamp_hns)
        .map_err(|_| "Windows capture timestamp exceeds Media Foundation range".to_owned())
}

pub(super) fn capture_timestamp_step_is_forward(previous_90khz: u32, current_90khz: u32) -> bool {
    let step = current_90khz.wrapping_sub(previous_90khz);
    step > 0 && step <= MAX_CAPTURE_TIMESTAMP_STEP_90KHZ
}

#[cfg(test)]
pub(super) fn take_admitted_video_timestamp(
    next: &mut i64,
    frame_duration_hns: i64,
    admissions_until_next: &mut u8,
    admission_divisor: u8,
    repair_keyframe_pending: bool,
) -> Result<Option<i64>, String> {
    let timestamp = take_video_timestamp(next, frame_duration_hns)?;
    if !repair_keyframe_pending && *admissions_until_next > 0 {
        *admissions_until_next -= 1;
        return Ok(None);
    }
    *admissions_until_next = admission_divisor.saturating_sub(1);
    Ok(Some(timestamp))
}

#[cfg(test)]
pub(super) fn take_video_timestamp(next: &mut i64, frame_duration_hns: i64) -> Result<i64, String> {
    let timestamp = *next;
    *next = next
        .checked_add(frame_duration_hns)
        .ok_or_else(|| "Windows video timestamp overflowed".to_owned())?;
    Ok(timestamp)
}

fn combine_results<const N: usize>(results: [Result<(), String>; N]) -> Result<(), String> {
    let errors = results
        .into_iter()
        .filter_map(Result::err)
        .collect::<Vec<_>>();
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

impl TryFrom<PlatformSessionPlan> for NativeVideoEncoderPlan {
    type Error = String;

    fn try_from(plan: PlatformSessionPlan) -> Result<Self, Self::Error> {
        if plan.width == 0 || plan.height == 0 || plan.frames_per_second == 0 {
            return Err("Windows Media Foundation encoder geometry is invalid".to_owned());
        }
        if plan.video_format.codec != PlatformVideoCodec::Hevc
            && plan.video_format.chroma_subsampling == PlatformChromaSubsampling::Yuv444
        {
            return Err("Windows native 4:4:4 encoding requires HEVC".to_owned());
        }
        if !matches!(plan.video_format.bit_depth, 8 | 10) {
            return Err("Windows native encoder requires 8-bit or 10-bit video".to_owned());
        }
        let ten_bit = plan.video_format.bit_depth == 10;
        if plan.video_format.dynamic_range == PlatformDynamicRange::Hdr10
            && plan.video_format.codec == PlatformVideoCodec::H264
        {
            return Err("H.264 cannot carry the negotiated HDR stream".to_owned());
        }
        let bitrate_bps = plan
            .bitrate_kbps
            .checked_mul(1_000)
            .filter(|bitrate| *bitrate != 0)
            .ok_or_else(|| "Windows Media Foundation encoder bitrate is invalid".to_owned())?;
        Ok(Self {
            session_epoch: plan.session_epoch,
            encoder_epoch: 0,
            codec: plan.video_format.codec,
            width: plan.width,
            height: plan.height,
            frames_per_second: plan.frames_per_second,
            bitrate_bps,
            ten_bit,
            chroma_subsampling: plan.video_format.chroma_subsampling,
        })
    }
}

pub(super) fn configure_transform(
    transform: &IMFTransform,
    plan: NativeVideoEncoderPlan,
    device: &ID3D11Device,
) -> Result<IMFDXGIDeviceManager, String> {
    let mut reset_token = 0_u32;
    let mut manager = None;
    unsafe { MFCreateDXGIDeviceManager(&mut reset_token, &mut manager) }
        .map_err(|error| format!("Windows DXGI device manager creation failed: {error}"))?;
    let manager = manager.ok_or_else(|| "Windows DXGI device manager is unavailable".to_owned())?;
    unsafe { manager.ResetDevice(device, reset_token) }.map_err(|error| {
        format!("Windows DXGI device manager rejected the encoder device: {error}")
    })?;
    unsafe {
        transform.ProcessMessage(
            MFT_MESSAGE_SET_D3D_MANAGER,
            Interface::as_raw(&manager) as usize,
        )
    }
    .map_err(|error| {
        format!(
            "Windows {} encoder rejected the D3D11 device manager: {error}",
            codec_name(plan.codec)
        )
    })?;
    let attributes = unsafe { transform.GetAttributes() }.map_err(|error| {
        format!(
            "Windows Media Foundation could not expose {} encoder attributes: {error}",
            codec_name(plan.codec)
        )
    })?;
    let low_latency = (|| -> windows_api::core::Result<()> {
        unsafe {
            attributes.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1)?;
            attributes.SetUINT32(&MF_LOW_LATENCY, 1)?;
        }
        Ok(())
    })();
    low_latency.map_err(|error| {
        format!(
            "Windows Media Foundation rejected the {} low-latency contract: {error}",
            codec_name(plan.codec)
        )
    })?;
    let output = video_media_type(plan, output_subtype(plan.codec), true)?;
    let input = video_media_type(plan, input_subtype(plan), false)?;
    unsafe { transform.SetOutputType(0, &output, 0) }.map_err(|error| {
        format!(
            "Windows Media Foundation rejected the {} output contract: {error}",
            codec_name(plan.codec)
        )
    })?;
    unsafe { transform.SetInputType(0, &input, 0) }.map_err(|error| {
        format!(
            "Windows Media Foundation rejected the {} input contract: {error}",
            codec_name(plan.codec)
        )
    })?;
    Ok(manager)
}

pub(super) fn video_media_type(
    plan: NativeVideoEncoderPlan,
    subtype: windows_api::core::GUID,
    encoded: bool,
) -> Result<IMFMediaType, String> {
    let media_type = unsafe { MFCreateMediaType() }
        .map_err(|error| format!("Windows Media Foundation media type creation failed: {error}"))?;
    let progressive = u32::try_from(MFVideoInterlace_Progressive.0)
        .map_err(|_| "Windows Media Foundation progressive mode is invalid".to_owned())?;
    let configured = (|| -> windows_api::core::Result<()> {
        unsafe {
            media_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            media_type.SetGUID(&MF_MT_SUBTYPE, &subtype)?;
            media_type.SetUINT64(&MF_MT_FRAME_SIZE, pack_ratio(plan.width, plan.height))?;
            media_type.SetUINT64(&MF_MT_FRAME_RATE, pack_ratio(plan.frames_per_second, 1))?;
            media_type.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack_ratio(1, 1))?;
            media_type.SetUINT32(&MF_MT_INTERLACE_MODE, progressive)?;
            if encoded {
                media_type.SetUINT32(&MF_MT_AVG_BITRATE, plan.bitrate_bps)?;
                media_type.SetUINT32(&MF_MT_MPEG2_PROFILE, output_profile(plan))?;
            }
        }
        Ok(())
    })();
    configured.map_err(|error| {
        format!("Windows Media Foundation media type configuration failed: {error}")
    })?;
    Ok(media_type)
}

pub(super) fn pack_ratio(numerator: u32, denominator: u32) -> u64 {
    (u64::from(numerator) << 32) | u64::from(denominator)
}

pub(super) fn output_subtype(codec: PlatformVideoCodec) -> windows_api::core::GUID {
    match codec {
        PlatformVideoCodec::H264 => MFVideoFormat_H264,
        PlatformVideoCodec::Hevc => MFVideoFormat_HEVC,
        PlatformVideoCodec::Av1 => MFVideoFormat_AV1,
        PlatformVideoCodec::ShadowVc => windows_api::core::GUID::zeroed(),
    }
}

pub(super) fn input_subtype(plan: NativeVideoEncoderPlan) -> windows_api::core::GUID {
    match (plan.chroma_subsampling, plan.ten_bit) {
        (PlatformChromaSubsampling::Yuv420, false) => MFVideoFormat_NV12,
        (PlatformChromaSubsampling::Yuv420, true) => MFVideoFormat_P010,
        (PlatformChromaSubsampling::Yuv444, false) => MFVideoFormat_AYUV,
        (PlatformChromaSubsampling::Yuv444, true) => MFVideoFormat_Y410,
    }
}

pub(super) fn output_profile(plan: NativeVideoEncoderPlan) -> u32 {
    let profile = match (plan.codec, plan.chroma_subsampling, plan.ten_bit) {
        (PlatformVideoCodec::H264, _, _) => eAVEncH264VProfile_High.0,
        (PlatformVideoCodec::Hevc, PlatformChromaSubsampling::Yuv420, false) => {
            eAVEncH265VProfile_Main_420_8.0
        }
        (PlatformVideoCodec::Hevc, PlatformChromaSubsampling::Yuv420, true) => {
            eAVEncH265VProfile_Main_420_10.0
        }
        (PlatformVideoCodec::Hevc, PlatformChromaSubsampling::Yuv444, false) => {
            eAVEncH265VProfile_Main_444_8.0
        }
        (PlatformVideoCodec::Hevc, PlatformChromaSubsampling::Yuv444, true) => {
            eAVEncH265VProfile_Main_444_10.0
        }
        (PlatformVideoCodec::Av1, _, false) => eAVEncAV1VProfile_Main_420_8.0,
        (PlatformVideoCodec::Av1, _, true) => eAVEncAV1VProfile_Main_420_10.0,
        (PlatformVideoCodec::ShadowVc, _, _) => 0,
    };
    u32::try_from(profile).unwrap_or_default()
}

pub(super) fn hardware_encoder_activation(
    subtype: windows_api::core::GUID,
) -> Result<Option<IMFActivate>, String> {
    let output = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: subtype,
    };
    let mut activations: *mut Option<IMFActivate> = ptr::null_mut();
    let mut activation_count = 0_u32;
    let result = unsafe {
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
            None,
            Some(&output),
            &mut activations,
            &mut activation_count,
        )
    };
    if let Err(error) = result {
        drop(take_first_activation(activations, activation_count));
        return Err(format!(
            "Media Foundation hardware encoder discovery failed: {error}"
        ));
    }
    Ok(take_first_activation(activations, activation_count))
}

pub(super) fn take_first_activation(
    activations: *mut Option<IMFActivate>,
    count: u32,
) -> Option<IMFActivate> {
    if activations.is_null() {
        return None;
    }
    let mut first = None;
    for index in 0..count as usize {
        let activation = unsafe { ptr::read(activations.add(index)) };
        if first.is_none() {
            first = activation;
        }
    }
    unsafe { CoTaskMemFree(Some(activations.cast::<c_void>())) };
    first
}

pub(super) fn codec_name(codec: PlatformVideoCodec) -> &'static str {
    match codec {
        PlatformVideoCodec::H264 => "H.264",
        PlatformVideoCodec::Hevc => "HEVC",
        PlatformVideoCodec::Av1 => "AV1",
        PlatformVideoCodec::ShadowVc => "ShadowVC (unavailable on Windows)",
    }
}
