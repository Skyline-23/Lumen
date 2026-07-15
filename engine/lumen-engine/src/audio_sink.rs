use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

pub const AUDIO_SINK_HOST: u32 = 0;
pub const AUDIO_SINK_CONFIGURED: u32 = 1;
pub const AUDIO_SINK_UNAVAILABLE: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAudioSinkRequest {
    pub host_audio_enabled: bool,
    pub host_sink_available: bool,
    pub configured_sink_available: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAudioSinkPlan {
    pub kind: u32,
}

pub fn resolve_audio_sink(request: LumenAudioSinkRequest) -> LumenAudioSinkPlan {
    let kind = if request.configured_sink_available {
        AUDIO_SINK_CONFIGURED
    } else if request.host_audio_enabled && request.host_sink_available {
        AUDIO_SINK_HOST
    } else {
        AUDIO_SINK_UNAVAILABLE
    };
    LumenAudioSinkPlan { kind }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_audio_sink(
    request: LumenAudioSinkRequest,
    plan_out: *mut LumenAudioSinkPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_audio_sink(request))) {
        Ok(plan) => {
            unsafe { *plan_out.as_mut() = plan };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configured_sink_precedes_host_when_playback_remains_enabled() {
        assert_eq!(
            resolve_audio_sink(LumenAudioSinkRequest {
                host_audio_enabled: true,
                host_sink_available: true,
                configured_sink_available: true,
            })
            .kind,
            AUDIO_SINK_CONFIGURED
        );
    }

    #[test]
    fn host_sink_requires_host_playback_permission() {
        assert_eq!(
            resolve_audio_sink(LumenAudioSinkRequest {
                host_audio_enabled: true,
                host_sink_available: true,
                configured_sink_available: false,
            })
            .kind,
            AUDIO_SINK_HOST
        );
    }

    #[test]
    fn missing_explicit_sink_does_not_enable_host_playback() {
        assert_eq!(
            resolve_audio_sink(LumenAudioSinkRequest {
                host_audio_enabled: false,
                host_sink_available: true,
                configured_sink_available: false,
            })
            .kind,
            AUDIO_SINK_UNAVAILABLE
        );
    }
}
