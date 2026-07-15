use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LumenVideoIngressThresholds {
    pub callback_latency_milliseconds: f64,
    pub packet_timestamp_milliseconds: f64,
}

pub fn ingress_thresholds(frame_rate: i32) -> LumenVideoIngressThresholds {
    let effective_frame_rate = if frame_rate > 0 {
        f64::from(frame_rate)
    } else {
        60.0
    };
    let threshold = 80.0f64.max((1000.0 / effective_frame_rate) * 6.0);
    LumenVideoIngressThresholds {
        callback_latency_milliseconds: threshold,
        packet_timestamp_milliseconds: threshold,
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_video_ingress_thresholds(
    frame_rate: i32,
    thresholds_out: *mut LumenVideoIngressThresholds,
) -> LumenEngineStatus {
    let Some(mut thresholds_out) = NonNull::new(thresholds_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| ingress_thresholds(frame_rate))) {
        Ok(thresholds) => {
            unsafe { *thresholds_out.as_mut() = thresholds };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thresholds_follow_frame_interval_without_high_refresh_gates() {
        assert_eq!(ingress_thresholds(0).callback_latency_milliseconds, 100.0);
        assert_eq!(ingress_thresholds(30).callback_latency_milliseconds, 200.0);
        assert_eq!(ingress_thresholds(60).callback_latency_milliseconds, 100.0);
        assert_eq!(ingress_thresholds(90).callback_latency_milliseconds, 80.0);
        assert_eq!(ingress_thresholds(120).callback_latency_milliseconds, 80.0);
        assert_eq!(
            ingress_thresholds(120).callback_latency_milliseconds,
            ingress_thresholds(120).packet_timestamp_milliseconds
        );
    }
}
