use crate::{PlatformEncodedVideoFrame, PlatformVideoCodec, PlatformVideoFormat};

mod bit_reader;
mod configuration_record;
#[cfg(test)]
mod configuration_tests;
mod h26x;
mod hevc_sps;
mod sps;
#[cfg(test)]
pub(crate) mod test_fixtures;
#[cfg(test)]
mod tests;

const AV1_CONFIGURATION_MARKER_AND_VERSION: u8 = 0x81;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NativeVideoConfiguration {
    pub(crate) configuration_id: u32,
    pub(crate) codec: PlatformVideoCodec,
    pub(crate) decoder_configuration_record: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NormalizedNativeVideoFrame {
    pub(crate) frame: PlatformEncodedVideoFrame,
    pub(crate) configuration_id: u32,
    pub(crate) new_configuration: Option<NativeVideoConfiguration>,
}

pub(crate) struct NativeVideoBitstreamNormalizer {
    format: PlatformVideoFormat,
    active_configuration: Option<Vec<u8>>,
    active_configuration_id: u32,
}

impl NativeVideoBitstreamNormalizer {
    pub(crate) const fn new(format: PlatformVideoFormat) -> Self {
        Self {
            format,
            active_configuration: None,
            active_configuration_id: 0,
        }
    }

    pub(crate) fn normalize(
        &mut self,
        frame: PlatformEncodedVideoFrame,
    ) -> Result<NormalizedNativeVideoFrame, String> {
        let (payload, discovered_configuration) = match self.format.codec {
            PlatformVideoCodec::H264 => h26x::normalize_avc(&frame.payload, self.format)?,
            PlatformVideoCodec::Hevc => h26x::normalize_hevc(&frame.payload, self.format)?,
            PlatformVideoCodec::Av1 => {
                validate_av1_obu_stream(&frame.payload)?;
                (frame.payload.clone(), None)
            }
        };
        let candidate_configuration = reconcile_configuration(
            discovered_configuration,
            frame.decoder_configuration_record.as_deref(),
        )?;
        if let Some(configuration) = candidate_configuration.as_deref() {
            configuration_record::validate_decoder_configuration(self.format, configuration)?;
        }
        if self.format.codec == PlatformVideoCodec::Av1 {
            if let Some(configuration) = candidate_configuration.as_ref() {
                if configuration.len() < 4
                    || configuration[0] != AV1_CONFIGURATION_MARKER_AND_VERSION
                {
                    return Err("AV1 decoder configuration record is invalid".to_owned());
                }
            }
        }
        let changed = candidate_configuration
            .as_ref()
            .is_some_and(|candidate| self.active_configuration.as_ref() != Some(candidate));
        if self.active_configuration.is_none() && candidate_configuration.is_none() {
            return Err("native video frame arrived before decoder configuration".to_owned());
        }
        if changed && !frame.key_frame {
            return Err("native video configuration changed without a key frame".to_owned());
        }
        let new_configuration = if changed {
            let configuration_id = self
                .active_configuration_id
                .checked_add(1)
                .ok_or_else(|| "native video configuration id exhausted".to_owned())?;
            let Some(decoder_configuration_record) = candidate_configuration else {
                return Err("native video configuration transition is invalid".to_owned());
            };
            self.active_configuration = Some(decoder_configuration_record.clone());
            self.active_configuration_id = configuration_id;
            Some(NativeVideoConfiguration {
                configuration_id,
                codec: self.format.codec,
                decoder_configuration_record,
            })
        } else {
            None
        };
        Ok(NormalizedNativeVideoFrame {
            frame: PlatformEncodedVideoFrame {
                payload,
                decoder_configuration_record: None,
                ..frame
            },
            configuration_id: self.active_configuration_id,
            new_configuration,
        })
    }
}

fn reconcile_configuration(
    discovered: Option<Vec<u8>>,
    supplied: Option<&[u8]>,
) -> Result<Option<Vec<u8>>, String> {
    match (discovered, supplied) {
        (Some(discovered), Some(supplied)) if discovered != supplied => {
            Err("native encoder configuration disagrees with its parameter sets".to_owned())
        }
        (Some(discovered), _) => Ok(Some(discovered)),
        (None, Some([])) => Err("native encoder configuration is empty".to_owned()),
        (None, Some(supplied)) => Ok(Some(supplied.to_vec())),
        (None, None) => Ok(None),
    }
}

fn validate_av1_obu_stream(payload: &[u8]) -> Result<(), String> {
    let mut offset = 0;
    while offset < payload.len() {
        let header = payload[offset];
        if header & 0x80 != 0 || header & 0x01 != 0 || header & 0x02 == 0 {
            return Err("AV1 access unit is not a low-overhead sized OBU stream".to_owned());
        }
        offset += 1;
        if header & 0x04 != 0 {
            offset = offset
                .checked_add(1)
                .filter(|offset| *offset <= payload.len())
                .ok_or_else(|| "AV1 OBU extension is truncated".to_owned())?;
        }
        let (size, size_bytes) = read_leb128(&payload[offset..])?;
        offset = offset
            .checked_add(size_bytes)
            .and_then(|offset| offset.checked_add(size))
            .filter(|offset| *offset <= payload.len())
            .ok_or_else(|| "AV1 OBU payload is truncated".to_owned())?;
    }
    (offset != 0)
        .then_some(())
        .ok_or_else(|| "AV1 access unit is empty".to_owned())
}

fn read_leb128(bytes: &[u8]) -> Result<(usize, usize), String> {
    let mut value = 0_usize;
    for (index, byte) in bytes.iter().copied().enumerate().take(8) {
        value |= usize::from(byte & 0x7f)
            .checked_shl((index * 7) as u32)
            .ok_or_else(|| "AV1 OBU size overflows".to_owned())?;
        if byte & 0x80 == 0 {
            return Ok((value, index + 1));
        }
    }
    Err("AV1 OBU size is truncated or oversized".to_owned())
}
