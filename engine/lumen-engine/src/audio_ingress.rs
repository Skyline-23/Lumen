use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::sync::Mutex;

use crate::LumenEngineStatus;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAudioIngressRequest {
    pub sample_rate: i32,
    pub channel_count: i32,
    pub frame_count: i32,
    pub sample_count: usize,
    pub pcm_byte_count: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAudioIngressFrame {
    pub sample_rate: i32,
    pub channel_count: i32,
    pub frame_count: i32,
    pub copied_pcm_byte_count: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAudioIngressDecision {
    pub accepted: bool,
    pub should_log_mismatch: bool,
}

#[derive(Debug)]
struct AudioIngressState {
    format: LumenAudioIngressRequest,
    mismatch_reported: bool,
}

impl AudioIngressState {
    fn new(request: LumenAudioIngressRequest) -> Result<Self, LumenEngineStatus> {
        if request.sample_rate <= 0 || request.channel_count <= 0 || request.frame_count <= 0 {
            return Err(LumenEngineStatus::InvalidArgument);
        }
        let expected_sample_count = usize::try_from(request.frame_count)
            .ok()
            .and_then(|frames| {
                usize::try_from(request.channel_count)
                    .ok()
                    .and_then(|channels| frames.checked_mul(channels))
            })
            .ok_or(LumenEngineStatus::InvalidArgument)?;
        let expected_pcm_byte_count = expected_sample_count
            .checked_mul(std::mem::size_of::<f32>())
            .ok_or(LumenEngineStatus::InvalidArgument)?;
        if request.sample_count != expected_sample_count
            || request.pcm_byte_count != expected_pcm_byte_count
        {
            return Err(LumenEngineStatus::InvalidArgument);
        }

        Ok(Self {
            format: request,
            mismatch_reported: false,
        })
    }

    fn evaluate(&mut self, frame: LumenAudioIngressFrame) -> LumenAudioIngressDecision {
        let accepted = frame.sample_rate == self.format.sample_rate
            && frame.channel_count == self.format.channel_count
            && frame.frame_count == self.format.frame_count
            && frame.copied_pcm_byte_count == self.format.pcm_byte_count;
        let decision = LumenAudioIngressDecision {
            accepted,
            should_log_mismatch: !accepted && !self.mismatch_reported,
        };
        self.mismatch_reported |= !accepted;
        decision
    }
}

pub struct LumenAudioIngressPolicy {
    inner: Mutex<AudioIngressState>,
}

#[no_mangle]
pub extern "C" fn lumen_audio_ingress_policy_create(
    request: LumenAudioIngressRequest,
    policy_out: *mut *mut LumenAudioIngressPolicy,
) -> LumenEngineStatus {
    let Some(mut policy_out) = NonNull::new(policy_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| AudioIngressState::new(request))) {
        Ok(Ok(state)) => {
            let policy = Box::into_raw(Box::new(LumenAudioIngressPolicy {
                inner: Mutex::new(state),
            }));
            unsafe { *policy_out.as_mut() = policy };
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_audio_ingress_policy_destroy(policy: *mut LumenAudioIngressPolicy) {
    if !policy.is_null() {
        unsafe { drop(Box::from_raw(policy)) };
    }
}

#[no_mangle]
pub extern "C" fn lumen_audio_ingress_policy_evaluate(
    policy: *const LumenAudioIngressPolicy,
    frame: LumenAudioIngressFrame,
    decision_out: *mut LumenAudioIngressDecision,
) -> LumenEngineStatus {
    let Some(policy) = NonNull::new(policy.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut decision_out) = NonNull::new(decision_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let mut state = unsafe { policy.as_ref() }
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        unsafe { *decision_out.as_mut() = state.evaluate(frame) };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_accepts_only_an_internally_consistent_runtime_shape() {
        let state = AudioIngressState::new(LumenAudioIngressRequest {
            sample_rate: 48_000,
            channel_count: 6,
            frame_count: 240,
            sample_count: 1_440,
            pcm_byte_count: 5_760,
        })
        .unwrap();
        assert_eq!(state.format.sample_count, 1_440);
        assert!(AudioIngressState::new(LumenAudioIngressRequest::default()).is_err());
        assert!(AudioIngressState::new(LumenAudioIngressRequest {
            pcm_byte_count: 5_759,
            ..state.format
        })
        .is_err());
    }

    #[test]
    fn mismatch_is_rejected_and_reported_only_once() {
        let mut state = AudioIngressState::new(LumenAudioIngressRequest {
            sample_rate: 48_000,
            channel_count: 2,
            frame_count: 240,
            sample_count: 480,
            pcm_byte_count: 1_920,
        })
        .unwrap();
        let mismatch = LumenAudioIngressFrame {
            sample_rate: 44_100,
            channel_count: 2,
            frame_count: 240,
            copied_pcm_byte_count: 1_920,
        };
        assert_eq!(
            state.evaluate(mismatch),
            LumenAudioIngressDecision {
                accepted: false,
                should_log_mismatch: true,
            }
        );
        assert!(!state.evaluate(mismatch).should_log_mismatch);
        assert!(
            state
                .evaluate(LumenAudioIngressFrame {
                    sample_rate: 48_000,
                    ..mismatch
                })
                .accepted
        );
    }
}
