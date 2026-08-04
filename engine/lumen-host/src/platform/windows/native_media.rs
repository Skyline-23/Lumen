use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::Duration;

use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame, PlatformSessionPlan};

use super::media_queue::WindowsMediaPacketQueues;
use super::native_audio::{self, NativeAudioConfiguration};
use super::native_display_driver::DriverHandle;
use super::native_video::{NativeEncodedVideoSample, NativeMediaFoundation, NativeVideoSinkResult};
use crate::windows_service_log::WindowsServiceEventLane;

const MAXIMUM_VIDEO_BUFFER_BYTES: usize = 32 * 1024 * 1024;

pub(super) struct NativeWindowsMedia {
    packets: Arc<PacketQueueContext>,
    audio_configuration: NativeAudioConfiguration,
    media_foundation: NativeMediaFoundation,
    adaptive_event_lane: WindowsServiceEventLane,
    lifecycle: RwLock<MediaLifecycle>,
}

#[derive(Default)]
pub(super) struct PacketQueueContext {
    state: Mutex<PacketQueueState>,
}

#[derive(Default)]
struct PacketQueueState {
    queues: WindowsMediaPacketQueues,
    video_session_epoch: Option<u32>,
}

impl PacketQueueContext {
    pub(super) fn configure_audio_capacity(&self, capacity: usize) -> Result<(), String> {
        self.state
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
            .queues
            .configure_audio_capacity(capacity);
        Ok(())
    }

    pub(super) fn push_audio(&self, payload: Vec<u8>) -> Result<(), String> {
        self.state
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
            .queues
            .push_audio(payload);
        Ok(())
    }

    fn activate_video_session(&self, session_epoch: u32) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?;
        if state.video_session_epoch.is_some() {
            return Err("Windows video packet queue already has an active session".to_owned());
        }
        state.video_session_epoch = Some(session_epoch);
        Ok(())
    }

    fn retire_video_session(&self, session_epoch: u32) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?;
        if state.video_session_epoch == Some(session_epoch) {
            state.video_session_epoch = None;
            state.queues = WindowsMediaPacketQueues::default();
        }
        Ok(())
    }

    fn push_video(
        &self,
        session_epoch: u32,
        sample: NativeEncodedVideoSample,
    ) -> Result<NativeVideoSinkResult, String> {
        if sample.payload.is_empty() || sample.payload.len() > MAXIMUM_VIDEO_BUFFER_BYTES {
            return Err("Windows native encoder produced an invalid video payload".to_owned());
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?;
        if state.video_session_epoch != Some(session_epoch) {
            return Ok(NativeVideoSinkResult::default());
        }
        let result = state
            .queues
            .push_video_with_result(PlatformEncodedVideoFrame {
                payload: sample.payload,
                decoder_configuration_record: None,
                presentation_time_90khz: u64::from(sample.presentation_time_90khz),
                key_frame: sample.key_frame,
                // Initial admission pauses explicitly. During steady state only an explicit
                // repair key frame owns a pause; natural periodic key frames remain in the
                // acknowledged DATAGRAM generation.
                requires_bootstrap_acknowledgement: sample.key_frame && sample.repair_keyframe,
                repair_keyframe: sample.repair_keyframe,
            });
        Ok(NativeVideoSinkResult {
            request_key_frame: result.request_key_frame,
            pending_drop_count: result.dropped_frames,
        })
    }
}

#[derive(Default)]
struct MediaLifecycle {
    running: bool,
    session_epoch: Option<u32>,
    stop_requested: Option<Arc<AtomicBool>>,
    audio_worker: Option<thread::JoinHandle<i32>>,
}

impl NativeWindowsMedia {
    pub(super) fn new(arguments: &crate::HostArguments) -> Result<Self, String> {
        let audio_configuration = NativeAudioConfiguration::from_arguments(arguments)?;
        let packets = Arc::new(PacketQueueContext::default());
        let video_packets = Arc::clone(&packets);
        let adaptive_event_lane = WindowsServiceEventLane::from_program_data()?;
        let media_foundation = NativeMediaFoundation::start(
            Arc::new(move |session_epoch, sample: NativeEncodedVideoSample| {
                video_packets.push_video(session_epoch, sample)
            }),
            adaptive_event_lane.publisher(),
        );
        Ok(Self {
            packets,
            audio_configuration,
            media_foundation,
            adaptive_event_lane,
            lifecycle: RwLock::new(MediaLifecycle::default()),
        })
    }

    pub(super) fn start(
        &self,
        plan: PlatformSessionPlan,
        driver: DriverHandle,
    ) -> Result<(), String> {
        let session_epoch = plan.session_epoch;
        let mut lifecycle = self
            .lifecycle
            .write()
            .map_err(|_| "Windows media lifecycle lock is poisoned".to_owned())?;
        if lifecycle.running || lifecycle.session_epoch.is_some() {
            return Err(
                "Windows native media session is running or awaiting cleanup retry".to_owned(),
            );
        }
        self.reset_packets()?;
        self.packets.activate_video_session(session_epoch)?;
        lifecycle.session_epoch = Some(session_epoch);
        if let Err(error) = self.media_foundation.start_encoder(plan, driver) {
            let video = self.media_foundation.stop_encoder().err();
            let queue = self.packets.retire_video_session(session_epoch).err();
            let reset = self.reset_packets().err();
            if video.is_none() && queue.is_none() && reset.is_none() {
                lifecycle.session_epoch = None;
            }
            return combine_errors([Some(error), video, queue, reset]);
        }

        let stop_requested = Arc::new(AtomicBool::new(false));
        let audio_worker = if self.audio_configuration.enabled() {
            match self.start_audio(plan, Arc::clone(&stop_requested)) {
                Ok(worker) => Some(worker),
                Err(error) => {
                    stop_requested.store(true, Ordering::Release);
                    let video = self.media_foundation.stop_encoder().err();
                    let queue = self.packets.retire_video_session(session_epoch).err();
                    let reset = self.reset_packets().err();
                    if video.is_none() && queue.is_none() && reset.is_none() {
                        lifecycle.session_epoch = None;
                    }
                    return combine_errors([Some(error), video, queue, reset]);
                }
            }
        } else {
            None
        };

        lifecycle.running = true;
        lifecycle.stop_requested = Some(stop_requested);
        lifecycle.audio_worker = audio_worker;
        Ok(())
    }

    pub(super) fn stop(&self) -> Result<(), String> {
        let mut lifecycle = self
            .lifecycle
            .write()
            .map_err(|_| "Windows media lifecycle lock is poisoned".to_owned())?;
        if !lifecycle.running && lifecycle.session_epoch.is_none() {
            return Ok(());
        }
        lifecycle.running = false;
        let session_epoch = lifecycle.session_epoch;
        if let Some(stop_requested) = lifecycle.stop_requested.as_ref() {
            stop_requested.store(true, Ordering::Release);
        }
        let queue = session_epoch
            .and_then(|session_epoch| self.packets.retire_video_session(session_epoch).err());
        let video = self.media_foundation.stop_encoder().err();
        let audio = join_worker(lifecycle.audio_worker.take(), "audio").err();
        if lifecycle.audio_worker.is_none() {
            lifecycle.stop_requested = None;
        }
        let reset = self.reset_packets().err();
        if queue.is_none() && video.is_none() && reset.is_none() {
            lifecycle.session_epoch = None;
        }
        combine_errors([queue, video, audio, reset])
    }

    pub(super) fn request_key_frame(&self) -> Result<(), String> {
        let lifecycle = self.running_session()?;
        let result = self.media_foundation.request_key_frame();
        drop(lifecycle);
        result
    }

    pub(super) fn resume_after_bootstrap(&self) -> Result<(), String> {
        let lifecycle = self.running_session()?;
        let result = self.media_foundation.resume_after_bootstrap();
        drop(lifecycle);
        result
    }

    pub(super) fn set_video_delivery_policy(
        &self,
        session_epoch: u32,
        bitrate_kbps: u32,
        admission_divisor: u8,
    ) -> Result<(), String> {
        self.require_running_session_epoch(session_epoch)?;
        self.media_foundation.set_video_delivery_policy(
            session_epoch,
            bitrate_kbps,
            admission_divisor,
        )
    }

    pub(super) fn invalidate_reference_frames(
        &self,
        first_frame: i64,
        last_frame: i64,
    ) -> Result<(), String> {
        if first_frame < 0 || last_frame < first_frame {
            return Err("Windows reference invalidation range is invalid".to_owned());
        }
        let lifecycle = self.running_session()?;
        let result = self.media_foundation.request_key_frame();
        drop(lifecycle);
        result
    }

    pub(super) fn poll_video(&self) -> Result<Option<PlatformEncodedVideoFrame>, String> {
        let lifecycle = self
            .lifecycle
            .read()
            .map_err(|_| "Windows media lifecycle lock is poisoned".to_owned())?;
        if !lifecycle.running {
            return Ok(None);
        }
        if let Some(error) = self.media_foundation.take_error()? {
            return Err(error);
        }
        let frame = self
            .packets
            .state
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
            .queues
            .pop_video();
        drop(lifecycle);
        Ok(frame)
    }

    pub(super) fn poll_audio(&self) -> Result<Option<PlatformEncodedAudioPacket>, String> {
        let lifecycle = self
            .lifecycle
            .read()
            .map_err(|_| "Windows media lifecycle lock is poisoned".to_owned())?;
        if !lifecycle.running {
            return Ok(None);
        }
        let packet = self
            .packets
            .state
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
            .queues
            .pop_audio();
        drop(lifecycle);
        Ok(packet)
    }

    fn start_audio(
        &self,
        plan: PlatformSessionPlan,
        stop_requested: Arc<AtomicBool>,
    ) -> Result<thread::JoinHandle<i32>, String> {
        let packets = Arc::clone(&self.packets);
        let configuration = self.audio_configuration.clone();
        let worker_stop_requested = Arc::clone(&stop_requested);
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let worker = thread::Builder::new()
            .name("lumen-windows-audio-capture".to_owned())
            .spawn(move || {
                native_audio::run(
                    worker_stop_requested,
                    packets,
                    configuration,
                    plan,
                    ready_sender,
                )
            })
            .map_err(|error| format!("Windows audio capture thread failed to start: {error}"))?;
        match ready_receiver
            .recv_timeout(Duration::from_secs(15))
            .map_err(|error| format!("Windows audio readiness failed: {error}"))
            .and_then(|result| result)
        {
            Ok(()) => Ok(worker),
            Err(error) => {
                stop_requested.store(true, Ordering::Release);
                let worker_error = join_worker(Some(worker), "audio").err();
                Err(worker_error.map_or(error.clone(), |worker| format!("{error}; {worker}")))
            }
        }
    }

    fn reset_packets(&self) -> Result<(), String> {
        self.packets
            .state
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
            .queues = WindowsMediaPacketQueues::default();
        Ok(())
    }

    fn running_session(&self) -> Result<std::sync::RwLockReadGuard<'_, MediaLifecycle>, String> {
        let lifecycle = self
            .lifecycle
            .read()
            .map_err(|_| "Windows media lifecycle lock is poisoned".to_owned())?;
        lifecycle
            .running
            .then_some(lifecycle)
            .ok_or_else(|| "Windows native media session is not running".to_owned())
    }

    fn require_running_session_epoch(&self, session_epoch: u32) -> Result<(), String> {
        require_running_session_epoch(&self.lifecycle, session_epoch)
    }
}

fn require_running_session_epoch(
    lifecycle: &RwLock<MediaLifecycle>,
    session_epoch: u32,
) -> Result<(), String> {
    let lifecycle = lifecycle
        .read()
        .map_err(|_| "Windows media lifecycle lock is poisoned".to_owned())?;
    (lifecycle.running && lifecycle.session_epoch == Some(session_epoch))
        .then_some(())
        .ok_or_else(|| {
            "Windows adaptive video policy does not belong to the running session".to_owned()
        })
}

impl Drop for NativeWindowsMedia {
    fn drop(&mut self) {
        let _ = self.stop();
        self.adaptive_event_lane.shutdown();
    }
}

fn join_worker(worker: Option<thread::JoinHandle<i32>>, lane: &str) -> Result<(), String> {
    let Some(worker) = worker else {
        return Ok(());
    };
    match worker.join() {
        Ok(0) => Ok(()),
        Ok(status) => Err(format!(
            "Windows {lane} capture stopped with status {status}"
        )),
        Err(_) => Err(format!("Windows {lane} capture thread panicked")),
    }
}

fn combine_errors<const N: usize>(errors: [Option<String>; N]) -> Result<(), String> {
    let errors = errors.into_iter().flatten().collect::<Vec<_>>();
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

#[cfg(test)]
mod tests {
    use super::{require_running_session_epoch, MediaLifecycle};
    use std::sync::{mpsc, Arc, RwLock};

    #[test]
    fn adaptive_policy_snapshot_releases_lifecycle_lock_before_worker_wait() {
        let lifecycle = Arc::new(RwLock::new(MediaLifecycle {
            running: true,
            session_epoch: Some(7),
            ..MediaLifecycle::default()
        }));
        let (entered_send, entered_receive) = mpsc::sync_channel(1);
        let (release_send, release_receive) = mpsc::sync_channel(1);
        let policy_lifecycle = Arc::clone(&lifecycle);
        let policy = std::thread::spawn(move || {
            require_running_session_epoch(&policy_lifecycle, 7).unwrap();
            entered_send.send(()).unwrap();
            release_receive.recv().unwrap();
        });

        entered_receive.recv().unwrap();
        let mut stopping = lifecycle
            .try_write()
            .expect("stalled policy worker must not retain the lifecycle read lock");
        stopping.running = false;
        stopping.session_epoch = None;
        drop(stopping);
        assert!(require_running_session_epoch(&lifecycle, 7).is_err());
        release_send.send(()).unwrap();
        policy.join().unwrap();
    }
}
