use super::*;

pub(super) fn poll_video_capture_events(
    pop_event: PopVideoEvent,
    controller: *mut BridgeController,
) -> Result<(), String> {
    loop {
        let mut message = [0_i8; 1024];
        let event = unsafe { pop_event(controller, message.as_mut_ptr(), message.len()) };
        if !event.has_value {
            return Ok(());
        }
        // Restart notifications and individual frame drops are recoverable.
        // Failed is emitted after capture recovery has exhausted its options.
        if event.kind == 3 {
            let message = error_text(&message);
            return Err(if message.is_empty() {
                "macOS video capture failed".to_owned()
            } else {
                message
            });
        }
    }
}

pub(super) struct NativeOpusEncoder {
    encoder: *mut MacOpusEncoder,
    encode: EncodeOpusFloat32,
    destroy: DestroyOpusEncoder,
}

unsafe impl Send for NativeOpusEncoder {}

impl NativeOpusEncoder {
    pub(super) fn new(
        api: &MacBridgeApi,
        stream: &lumen_engine::LumenAudioStreamPlan,
        enhanced: bool,
    ) -> Result<Self, String> {
        let mut error = [0_i8; 1024];
        let encoder = unsafe {
            (api.create_opus_encoder)(
                stream.sample_rate,
                stream.channel_count,
                stream.streams,
                stream.coupled_streams,
                stream.mapping.as_ptr(),
                stream.bitrate,
                enhanced,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if encoder.is_null() {
            return Err(error_text(&error));
        }
        Ok(Self {
            encoder,
            encode: api.encode_opus_float32,
            destroy: api.destroy_opus_encoder,
        })
    }

    pub(super) fn encode(&mut self, samples: &[f32], frame_count: i32) -> Result<Vec<u8>, String> {
        let mut packet = vec![0_u8; 1_275];
        let mut packet_size = 0;
        let mut error = [0_i8; 1024];
        let encoded = unsafe {
            (self.encode)(
                self.encoder,
                samples.as_ptr(),
                frame_count,
                packet.as_mut_ptr(),
                packet.len(),
                &mut packet_size,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if !encoded {
            return Err(error_text(&error));
        }
        packet.truncate(packet_size);
        Ok(packet)
    }
}

impl Drop for NativeOpusEncoder {
    fn drop(&mut self) {
        unsafe { (self.destroy)(self.encoder) };
    }
}

pub(super) fn copy_annex_b_sample(
    sample: SampleBuffer,
    codec: i32,
    key_frame: bool,
) -> Result<(Vec<u8>, u64), String> {
    let format = unsafe { CMSampleBufferGetFormatDescription(sample) };
    let block = unsafe { CMSampleBufferGetDataBuffer(sample) };
    if format.is_null() || block.is_null() {
        return Err("encoded sample omitted its format or block buffer".to_owned());
    }
    if codec == 3 {
        let length = unsafe { CMBlockBufferGetDataLength(block) };
        if !(24..=MAXIMUM_VIDEO_BYTES).contains(&length) {
            return Err("ShadowVC sample size is invalid".to_owned());
        }
        let mut payload = vec![0_u8; length];
        if unsafe { CMBlockBufferCopyDataBytes(block, 0, length, payload.as_mut_ptr().cast()) } != 0 {
            return Err("could not copy ShadowVC sample".to_owned());
        }
        let time = unsafe { CMSampleBufferGetPresentationTimeStamp(sample) };
        if time.timescale <= 0 || time.value < 0 { return Err("invalid ShadowVC timestamp".into()); }
        return Ok((payload, ((i128::from(time.value)*90_000)/i128::from(time.timescale)) as u64));
    }
    let mut count = 0;
    let mut bytes = ptr::null();
    let mut length = 0;
    let mut nal_length_size = 0;
    let status = unsafe {
        parameter_set(
            codec,
            format,
            0,
            &mut bytes,
            &mut length,
            &mut count,
            &mut nal_length_size,
        )
    };
    if status != 0 || count == 0 || !(1..=4).contains(&nal_length_size) {
        return Err("encoded sample parameter sets are unavailable".to_owned());
    }
    let nal_length_size = usize::try_from(nal_length_size)
        .map_err(|_| "encoded sample NAL length field is invalid".to_owned())?;
    let mut output = Vec::new();
    if key_frame {
        for index in 0..count {
            let status = unsafe {
                parameter_set(
                    codec,
                    format,
                    index,
                    &mut bytes,
                    &mut length,
                    ptr::null_mut(),
                    ptr::null_mut(),
                )
            };
            if status != 0 || bytes.is_null() || length == 0 {
                return Err("encoded sample parameter set is invalid".to_owned());
            }
            output.extend_from_slice(&[0, 0, 0, 1]);
            output.extend_from_slice(unsafe { std::slice::from_raw_parts(bytes, length) });
        }
    }
    let input_length = unsafe { CMBlockBufferGetDataLength(block) };
    if input_length == 0 || input_length > MAXIMUM_VIDEO_BYTES {
        return Err("encoded sample size is invalid".to_owned());
    }
    let mut input = vec![0_u8; input_length];
    if unsafe { CMBlockBufferCopyDataBytes(block, 0, input_length, input.as_mut_ptr().cast()) } != 0
    {
        return Err("could not copy the encoded sample".to_owned());
    }
    let mut offset = 0;
    while offset + nal_length_size <= input.len() {
        let mut nal_length = 0_usize;
        for byte in &input[offset..offset + nal_length_size] {
            nal_length = (nal_length << 8) | usize::from(*byte);
        }
        offset += nal_length_size;
        if nal_length == 0 || offset + nal_length > input.len() {
            return Err("encoded sample NAL length is invalid".to_owned());
        }
        output.extend_from_slice(&[0, 0, 0, 1]);
        output.extend_from_slice(&input[offset..offset + nal_length]);
        offset += nal_length;
    }
    if offset != input.len() || output.len() > MAXIMUM_VIDEO_BYTES {
        return Err("encoded sample framing is invalid".to_owned());
    }
    let time = unsafe { CMSampleBufferGetPresentationTimeStamp(sample) };
    let timestamp = if time.timescale > 0 {
        ((i128::from(time.value) * 90_000) / i128::from(time.timescale)) as u64
    } else {
        0
    };
    Ok((output, timestamp))
}
