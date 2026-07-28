use crate::{
    PlatformChromaSubsampling, PlatformColorRange, PlatformDynamicRange, PlatformEncodedVideoFrame,
    PlatformVideoCodec, PlatformVideoFormat, PlatformVideoProfile,
};

pub(crate) const H264_420: PlatformVideoFormat = PlatformVideoFormat {
    codec: PlatformVideoCodec::H264,
    profile: PlatformVideoProfile::H264High,
    chroma_subsampling: PlatformChromaSubsampling::Yuv420,
    bit_depth: 8,
    dynamic_range: PlatformDynamicRange::Sdr,
    color_range: PlatformColorRange::Limited,
};

pub(crate) const H264_444: PlatformVideoFormat = PlatformVideoFormat {
    codec: PlatformVideoCodec::H264,
    profile: PlatformVideoProfile::H264High444Predictive,
    chroma_subsampling: PlatformChromaSubsampling::Yuv444,
    bit_depth: 8,
    dynamic_range: PlatformDynamicRange::Sdr,
    color_range: PlatformColorRange::Full,
};

pub(crate) const HEVC_420: PlatformVideoFormat = PlatformVideoFormat {
    codec: PlatformVideoCodec::Hevc,
    profile: PlatformVideoProfile::HevcMain,
    chroma_subsampling: PlatformChromaSubsampling::Yuv420,
    bit_depth: 8,
    dynamic_range: PlatformDynamicRange::Sdr,
    color_range: PlatformColorRange::Limited,
};

pub(crate) const HEVC_420_10: PlatformVideoFormat = PlatformVideoFormat {
    codec: PlatformVideoCodec::Hevc,
    profile: PlatformVideoProfile::HevcMain10,
    chroma_subsampling: PlatformChromaSubsampling::Yuv420,
    bit_depth: 10,
    dynamic_range: PlatformDynamicRange::Hdr10,
    color_range: PlatformColorRange::Limited,
};

pub(crate) const HEVC_444: PlatformVideoFormat = PlatformVideoFormat {
    codec: PlatformVideoCodec::Hevc,
    profile: PlatformVideoProfile::HevcMain444,
    chroma_subsampling: PlatformChromaSubsampling::Yuv444,
    bit_depth: 8,
    dynamic_range: PlatformDynamicRange::Sdr,
    color_range: PlatformColorRange::Full,
};

pub(crate) const HEVC_444_10: PlatformVideoFormat = PlatformVideoFormat {
    codec: PlatformVideoCodec::Hevc,
    profile: PlatformVideoProfile::HevcMain44410,
    chroma_subsampling: PlatformChromaSubsampling::Yuv444,
    bit_depth: 10,
    dynamic_range: PlatformDynamicRange::Hdr10,
    color_range: PlatformColorRange::Limited,
};

pub(crate) fn encoded_frame(format: PlatformVideoFormat) -> PlatformEncodedVideoFrame {
    let parameter_sets = match format.codec {
        PlatformVideoCodec::H264 => vec![
            avc_sps(format),
            vec![0x68, 0xce, 0x3c, 0x80],
            vec![0x65, 0x88],
        ],
        PlatformVideoCodec::Hevc => vec![
            vec![0x40, 0x01, 0x0c, 0x01],
            hevc_sps(format),
            vec![0x44, 0x01, 0xc0],
            vec![0x26, 0x01, 0x80],
        ],
        PlatformVideoCodec::Av1 => Vec::new(),
    };
    let mut payload = Vec::new();
    for parameter_set in parameter_sets {
        payload.extend_from_slice(&[0, 0, 0, 1]);
        payload.extend_from_slice(&parameter_set);
    }
    PlatformEncodedVideoFrame {
        payload,
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: true,
        requires_bootstrap_acknowledgement: false,
        repair_keyframe: false,
    }
}

fn avc_sps(format: PlatformVideoFormat) -> Vec<u8> {
    let profile_idc = match format.profile {
        PlatformVideoProfile::H264Main => 77,
        PlatformVideoProfile::H264High => 100,
        PlatformVideoProfile::H264High444Predictive => 244,
        PlatformVideoProfile::HevcMain
        | PlatformVideoProfile::HevcMain10
        | PlatformVideoProfile::HevcMain444
        | PlatformVideoProfile::HevcMain44410
        | PlatformVideoProfile::Av1Main => 0,
    };
    let chroma_format_idc = match format.chroma_subsampling {
        PlatformChromaSubsampling::Yuv420 => 1,
        PlatformChromaSubsampling::Yuv444 => 3,
    };
    let mut bits = BitWriter::default();
    bits.write(8, profile_idc);
    bits.write(8, 0);
    bits.write(8, 40);
    bits.unsigned_exp_golomb(0);
    if profile_idc != 77 {
        bits.unsigned_exp_golomb(chroma_format_idc);
        if chroma_format_idc == 3 {
            bits.write(1, 0);
        }
        bits.unsigned_exp_golomb(u64::from(format.bit_depth - 8));
        bits.unsigned_exp_golomb(u64::from(format.bit_depth - 8));
        bits.write(1, 0);
        bits.write(1, 0);
    }
    bits.unsigned_exp_golomb(0);
    bits.unsigned_exp_golomb(0);
    bits.unsigned_exp_golomb(0);
    bits.unsigned_exp_golomb(0);
    bits.write(1, 0);
    bits.unsigned_exp_golomb(119);
    bits.unsigned_exp_golomb(67);
    bits.write(1, 1);
    bits.write(1, 1);
    bits.write(1, 0);
    write_vui(&mut bits, format);
    finish_nal(0x67, bits)
}

fn hevc_sps(format: PlatformVideoFormat) -> Vec<u8> {
    let profile_idc = match format.profile {
        PlatformVideoProfile::HevcMain => 1,
        PlatformVideoProfile::HevcMain10 => 2,
        PlatformVideoProfile::HevcMain444 | PlatformVideoProfile::HevcMain44410 => 4,
        PlatformVideoProfile::H264Main
        | PlatformVideoProfile::H264High
        | PlatformVideoProfile::H264High444Predictive
        | PlatformVideoProfile::Av1Main => 0,
    };
    let chroma_format_idc = match format.chroma_subsampling {
        PlatformChromaSubsampling::Yuv420 => 1,
        PlatformChromaSubsampling::Yuv444 => 3,
    };
    let mut bits = BitWriter::default();
    bits.write(4, 0);
    bits.write(3, 0);
    bits.write(1, 1);
    bits.write(2, 0);
    bits.write(1, 0);
    bits.write(5, profile_idc);
    bits.write(32, 0);
    bits.write(48, 0);
    bits.write(8, 120);
    bits.unsigned_exp_golomb(0);
    bits.unsigned_exp_golomb(chroma_format_idc);
    if chroma_format_idc == 3 {
        bits.write(1, 0);
    }
    bits.unsigned_exp_golomb(1_920);
    bits.unsigned_exp_golomb(1_080);
    bits.write(1, 0);
    bits.unsigned_exp_golomb(u64::from(format.bit_depth - 8));
    bits.unsigned_exp_golomb(u64::from(format.bit_depth - 8));
    bits.unsigned_exp_golomb(0);
    bits.write(1, 0);
    for _ in 0..3 {
        bits.unsigned_exp_golomb(0);
    }
    for _ in 0..6 {
        bits.unsigned_exp_golomb(0);
    }
    bits.write(1, 0);
    bits.write(1, 0);
    bits.write(1, 0);
    bits.write(1, 0);
    bits.unsigned_exp_golomb(0);
    bits.write(1, 0);
    bits.write(1, 0);
    bits.write(1, 0);
    write_vui(&mut bits, format);
    finish_hevc_nal(bits)
}

fn write_vui(bits: &mut BitWriter, format: PlatformVideoFormat) {
    bits.write(1, 1);
    bits.write(1, 0);
    bits.write(1, 0);
    bits.write(1, 1);
    bits.write(3, 5);
    bits.write(1, u64::from(format.color_range == PlatformColorRange::Full));
    bits.write(1, 1);
    bits.write(8, 1);
    bits.write(
        8,
        if format.dynamic_range == PlatformDynamicRange::Hdr10 {
            16
        } else {
            1
        },
    );
    bits.write(8, 1);
}

fn finish_nal(header: u8, bits: BitWriter) -> Vec<u8> {
    let mut output = vec![header];
    output.extend_from_slice(&escape_rbsp(bits.finish()));
    output
}

fn finish_hevc_nal(bits: BitWriter) -> Vec<u8> {
    let mut output = vec![0x42, 0x01];
    output.extend_from_slice(&escape_rbsp(bits.finish()));
    output
}

fn escape_rbsp(bytes: Vec<u8>) -> Vec<u8> {
    let mut output = Vec::with_capacity(bytes.len());
    let mut zeroes = 0;
    for byte in bytes {
        if zeroes >= 2 && byte <= 3 {
            output.push(3);
            zeroes = 0;
        }
        output.push(byte);
        zeroes = if byte == 0 { zeroes + 1 } else { 0 };
    }
    output
}

#[derive(Default)]
struct BitWriter {
    bytes: Vec<u8>,
    bit: usize,
}

impl BitWriter {
    fn write(&mut self, count: usize, value: u64) {
        for offset in (0..count).rev() {
            if self.bit % 8 == 0 {
                self.bytes.push(0);
            }
            if value & (1 << offset) != 0 {
                let index = self.bytes.len() - 1;
                self.bytes[index] |= 1 << (7 - self.bit % 8);
            }
            self.bit += 1;
        }
    }

    fn unsigned_exp_golomb(&mut self, value: u64) {
        let code = value + 1;
        let bits = 64 - usize::try_from(code.leading_zeros()).unwrap_or_default();
        self.write(bits - 1, 0);
        self.write(bits, code);
    }

    fn finish(mut self) -> Vec<u8> {
        self.write(1, 1);
        while self.bit % 8 != 0 {
            self.write(1, 0);
        }
        self.bytes
    }
}
