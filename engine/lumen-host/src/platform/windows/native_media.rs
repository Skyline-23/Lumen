use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::Duration;

use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame, PlatformSessionPlan};

use super::media_queue::WindowsMediaPacketQueues;
use super::native_audio::{self, NativeAudioConfiguration};
use super::native_display_driver::DriverHandle;
use super::native_video::{NativeEncodedVideoSample, NativeMediaFoundation};

const MAXIMUM_VIDEO_BUFFER_BYTES: usize = 32 * 1024 * 1024;

pub(super) struct NativeWindowsMedia {
    packets: Arc<PacketQueueContext>,
    audio_configuration: NativeAudioConfiguration,
    media_foundation: NativeMediaFoundation,
    lifecycle: RwLock<MediaLifecycle>,
}

#[derive(Default)]
pub(super) struct PacketQueueContext {
    queues: Mutex<WindowsMediaPacketQueues>,
}

impl PacketQueueContext {
    pub(super) fn configure_audio_capacity(&self, capacity: usize) -> Result<(), String> {
        self.queues
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
            .configure_audio_capacity(capacity);
        Ok(())
    }

    pub(super) fn push_audio(&self, payload: Vec<u8>) -> Result<(), String> {
        self.queues
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
            .push_audio(payload);
        Ok(())
    }

    fn push_video(&self, sample: NativeEncodedVideoSample) -> Result<bool, String> {
        if sample.payload.is_empty() || sample.payload.len() > MAXIMUM_VIDEO_BUFFER_BYTES {
            return Err("Windows native encoder produced an invalid video payload".to_owned());
        }
        let request_key_frame = self
            .queues
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
            .push_video(PlatformEncodedVideoFrame {
                payload: sample.payload,
                decoder_configuration_record: None,
                presentation_time_90khz: sample.presentation_time_90khz,
                key_frame: sample.key_frame,
                // The Windows Media Foundation worker pauses capture after every key frame.
                requires_bootstrap_acknowledgement: sample.key_frame,
                repair_keyframe: sample.repair_keyframe,
            });
        Ok(request_key_frame)
    }
}

#[derive(Default)]
struct MediaLifecycle {
    running: bool,
    stop_requested: Option<Arc<AtomicBool>>,
    audio_worker: Option<thread::JoinHandle<i32>>,
}

impl NativeWindowsMedia {
    pub(super) fn new(arguments: &crate::HostArguments) -> Result<Self, String> {
        let audio_configuration = NativeAudioConfiguration::from_arguments(arguments)?;
        let packets = Arc::new(PacketQueueContext::default());
        let video_packets = Arc::clone(&packets);
        let media_foundation =
            NativeMediaFoundation::start(Arc::new(move |sample: NativeEncodedVideoSample| {
                video_packets.push_video(sample)
            }))?;
        Ok(Self {
            packets,
            audio_configuration,
            media_foundation,
            lifecycle: RwLock::new(MediaLifecycle::default()),
        })
    }

    pub(super) fn start(
        &self,
        plan: PlatformSessionPlan,
        driver: DriverHandle,
    ) -> Result<(), String> {
        let mut lifecycle = self
            .lifecycle
            .write()
            .map_err(|_| "Windows media lifecycle lock is poisoned".to_owned())?;
        if lifecycle.running {
            return Err("Windows native media session is already running".to_owned());
        }
        self.reset_packets()?;
        self.media_foundation.start_encoder(plan, driver)?;

        let stop_requested = Arc::new(AtomicBool::new(false));
        let audio_worker = if self.audio_configuration.enabled() {
            match self.start_audio(plan, Arc::clone(&stop_requested)) {
                Ok(worker) => Some(worker),
                Err(error) => {
                    stop_requested.store(true, Ordering::Release);
                    let video = self.media_foundation.stop_encoder().err();
                    return Err(video.map_or(error.clone(), |video| format!("{error}; {video}")));
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
        if !lifecycle.running {
            return Ok(());
        }
        lifecycle.running = false;
        if let Some(stop_requested) = lifecycle.stop_requested.take() {
            stop_requested.store(true, Ordering::Release);
        }
        let video = self.media_foundation.stop_encoder().err();
        let audio = join_worker(lifecycle.audio_worker.take(), "audio").err();
        let reset = self.reset_packets().err();
        combine_errors([video, audio, reset])
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
            .queues
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
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
            .queues
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())?
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
        *self
            .packets
            .queues
            .lock()
            .map_err(|_| "Windows media packet queue is poisoned".to_owned())? =
            WindowsMediaPacketQueues::default();
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
}

impl Drop for NativeWindowsMedia {
    fn drop(&mut self) {
        let _ = self.stop();
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
