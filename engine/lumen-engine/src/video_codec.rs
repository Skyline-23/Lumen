pub const VIDEO_FORMAT_H264: i32 = 0;
pub const VIDEO_FORMAT_HEVC: i32 = 1;
pub const VIDEO_FORMAT_AV1: i32 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenVideoCodecPlan {
    pub video_format: i32,
    pub supports_hdr_transport: bool,
}

pub fn resolve_video_codec(video_format: i32) -> Option<LumenVideoCodecPlan> {
    match video_format {
        VIDEO_FORMAT_H264 => Some(LumenVideoCodecPlan {
            video_format,
            supports_hdr_transport: false,
        }),
        VIDEO_FORMAT_HEVC | VIDEO_FORMAT_AV1 => Some(LumenVideoCodecPlan {
            video_format,
            supports_hdr_transport: true,
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_codecs_preserve_format_and_hdr_transport_capability() {
        assert_eq!(
            resolve_video_codec(VIDEO_FORMAT_H264).unwrap().video_format,
            0
        );
        assert!(
            !resolve_video_codec(VIDEO_FORMAT_H264)
                .unwrap()
                .supports_hdr_transport
        );
        assert!(
            resolve_video_codec(VIDEO_FORMAT_HEVC)
                .unwrap()
                .supports_hdr_transport
        );
        assert!(
            resolve_video_codec(VIDEO_FORMAT_AV1)
                .unwrap()
                .supports_hdr_transport
        );
    }

    #[test]
    fn unknown_codec_is_rejected() {
        assert_eq!(resolve_video_codec(99), None);
    }
}
