use std::collections::VecDeque;
use std::ffi::c_void;
use std::mem::size_of;
use std::ptr;
use std::slice;

use windows_api::core::{Error, Owned, PCWSTR};
use windows_api::Win32::Foundation::{HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows_api::Win32::Media::Audio::{
    eConsole, eRender, IAudioCaptureClient, IAudioClient, IMMDevice, IMMDeviceEnumerator,
    MMDeviceEnumerator, AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_E_DEVICE_INVALIDATED,
    AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
    AUDCLNT_STREAMFLAGS_EVENTCALLBACK, AUDCLNT_STREAMFLAGS_LOOPBACK,
    AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, DEVICE_STATE_ACTIVE, WAVEFORMATEX,
    WAVEFORMATEXTENSIBLE, WAVEFORMATEXTENSIBLE_0,
};
use windows_api::Win32::Media::KernelStreaming::{
    SPEAKER_BACK_LEFT, SPEAKER_BACK_RIGHT, SPEAKER_FRONT_CENTER, SPEAKER_FRONT_LEFT,
    SPEAKER_FRONT_RIGHT, SPEAKER_LOW_FREQUENCY, SPEAKER_SIDE_LEFT, SPEAKER_SIDE_RIGHT,
    WAVE_FORMAT_EXTENSIBLE,
};
use windows_api::Win32::Media::Multimedia::KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
use windows_api::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL,
    COINIT_MULTITHREADED, COINIT_SPEED_OVER_MEMORY,
};
use windows_api::Win32::System::Threading::{
    AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, CreateEventW,
    WaitForSingleObjectEx,
};

const SAMPLE_RATE: u32 = 48_000;
const BYTES_PER_SAMPLE: u16 = size_of::<f32>() as u16;
const PRO_AUDIO_TASK: [u16; 10] = [80, 114, 111, 32, 65, 117, 100, 105, 111, 0];

pub(super) enum WasapiSampleResult {
    Ready,
    Timeout,
    Reinitialize,
}

struct ComApartment;

impl ComApartment {
    fn initialize() -> Result<Self, String> {
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED | COINIT_SPEED_OVER_MEMORY)
                .ok()
                .map_err(|error| windows_error("initialize COM", error))?;
        }
        Ok(Self)
    }
}

impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

pub(super) struct WasapiEndpointCatalog {
    enumerator: IMMDeviceEnumerator,
    apartment: ComApartment,
}

impl WasapiEndpointCatalog {
    pub(super) fn open() -> Result<Self, String> {
        let apartment = ComApartment::initialize()?;
        let enumerator = unsafe {
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
                .map_err(|error| windows_error("create audio endpoint enumerator", error))?
        };
        Ok(Self {
            enumerator,
            apartment,
        })
    }

    pub(super) fn host_sink(&self) -> Result<Option<String>, String> {
        let device = match unsafe { self.enumerator.GetDefaultAudioEndpoint(eRender, eConsole) } {
            Ok(device) => device,
            Err(_) => return Ok(None),
        };
        device_id(&device).map(Some)
    }

    pub(super) fn endpoint_available(&self, endpoint_id: &str) -> Result<bool, String> {
        let endpoint_id = wide_string(endpoint_id)?;
        let device = match unsafe {
            self.enumerator
                .GetDevice(PCWSTR::from_raw(endpoint_id.as_ptr()))
        } {
            Ok(device) => device,
            Err(_) => return Ok(false),
        };
        let state = unsafe { device.GetState() }
            .map_err(|error| windows_error("read audio endpoint state", error))?;
        Ok(state == DEVICE_STATE_ACTIVE)
    }

    pub(super) fn start_capture(
        self,
        endpoint_id: &str,
        channel_count: u16,
        frame_count: usize,
    ) -> Result<WasapiCapture, String> {
        let endpoint_id = wide_string(endpoint_id)?;
        let device = unsafe {
            self.enumerator
                .GetDevice(PCWSTR::from_raw(endpoint_id.as_ptr()))
                .map_err(|error| windows_error("open selected audio endpoint", error))?
        };
        let audio_client: IAudioClient = unsafe {
            device
                .Activate(CLSCTX_ALL, None)
                .map_err(|error| windows_error("activate WASAPI client", error))?
        };
        let format = float_wave_format(channel_count)?;
        unsafe {
            audio_client
                .Initialize(
                    AUDCLNT_SHAREMODE_SHARED,
                    AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                        | AUDCLNT_STREAMFLAGS_LOOPBACK
                        | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                        | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                    0,
                    0,
                    ptr::from_ref(&format).cast::<WAVEFORMATEX>(),
                    None,
                )
                .map_err(|error| windows_error("initialize WASAPI loopback capture", error))?;
        }

        let mut default_period = 0_i64;
        unsafe {
            audio_client
                .GetDevicePeriod(Some(&mut default_period), None)
                .map_err(|error| windows_error("read WASAPI device period", error))?;
        }
        let buffer_frames = unsafe {
            audio_client
                .GetBufferSize()
                .map_err(|error| windows_error("read WASAPI buffer size", error))?
        } as usize;
        let capture_client: IAudioCaptureClient = unsafe {
            audio_client
                .GetService()
                .map_err(|error| windows_error("open WASAPI capture service", error))?
        };
        let event = unsafe {
            CreateEventW(None, false, false, None)
                .map_err(|error| windows_error("create WASAPI event", error))?
        };
        let event = unsafe { Owned::new(event) };
        unsafe {
            audio_client
                .SetEventHandle(*event)
                .map_err(|error| windows_error("set WASAPI event", error))?;
        }

        let mut task_index = 0_u32;
        let multimedia_task = unsafe {
            AvSetMmThreadCharacteristicsW(
                PCWSTR::from_raw(PRO_AUDIO_TASK.as_ptr()),
                &mut task_index,
            )
            .ok()
            .filter(|handle| !handle.is_invalid())
        };
        unsafe {
            audio_client
                .Start()
                .map_err(|error| windows_error("start WASAPI capture", error))?;
        }

        let sample_capacity = buffer_frames
            .max(frame_count)
            .checked_mul(usize::from(channel_count))
            .and_then(|samples| samples.checked_mul(2))
            .ok_or_else(|| "WASAPI sample capacity overflowed".to_owned())?;
        let wait_timeout_milliseconds =
            u32::try_from(((default_period.max(10_000) + 9_999) / 10_000).max(1))
                .map_err(|_| "WASAPI device period is out of range".to_owned())?;

        Ok(WasapiCapture {
            audio_client,
            capture_client,
            event,
            multimedia_task,
            pending_samples: VecDeque::with_capacity(sample_capacity),
            sample_capacity,
            channel_count: usize::from(channel_count),
            wait_timeout_milliseconds,
            _device: device,
            _enumerator: self.enumerator,
            _apartment: self.apartment,
        })
    }
}

pub(super) struct WasapiCapture {
    audio_client: IAudioClient,
    capture_client: IAudioCaptureClient,
    event: Owned<HANDLE>,
    multimedia_task: Option<HANDLE>,
    pending_samples: VecDeque<f32>,
    sample_capacity: usize,
    channel_count: usize,
    wait_timeout_milliseconds: u32,
    _device: IMMDevice,
    _enumerator: IMMDeviceEnumerator,
    _apartment: ComApartment,
}

impl WasapiCapture {
    pub(super) fn sample(&mut self, output: &mut [f32]) -> Result<WasapiSampleResult, String> {
        while self.pending_samples.len() < output.len() {
            match self.fill_buffer()? {
                WasapiSampleResult::Ready => {}
                result => return Ok(result),
            }
        }
        let output_length = output.len();
        for (destination, sample) in output
            .iter_mut()
            .zip(self.pending_samples.drain(..output_length))
        {
            *destination = sample;
        }
        Ok(WasapiSampleResult::Ready)
    }

    fn fill_buffer(&mut self) -> Result<WasapiSampleResult, String> {
        let wait =
            unsafe { WaitForSingleObjectEx(*self.event, self.wait_timeout_milliseconds, false) };
        if wait == WAIT_TIMEOUT {
            return Ok(WasapiSampleResult::Timeout);
        }
        if wait != WAIT_OBJECT_0 {
            return Err(format!("WASAPI event wait failed with status {}", wait.0));
        }

        loop {
            let packet_frames = match unsafe { self.capture_client.GetNextPacketSize() } {
                Ok(frames) => frames,
                Err(error) if error.code() == AUDCLNT_E_DEVICE_INVALIDATED => {
                    return Ok(WasapiSampleResult::Reinitialize)
                }
                Err(error) => return Err(windows_error("read WASAPI packet size", error)),
            };
            if packet_frames == 0 {
                return Ok(WasapiSampleResult::Ready);
            }

            let mut data = ptr::null_mut();
            let mut frames = 0_u32;
            let mut flags = 0_u32;
            let get_buffer = unsafe {
                self.capture_client
                    .GetBuffer(&mut data, &mut frames, &mut flags, None, None)
            };
            if let Err(error) = get_buffer {
                if error.code() == AUDCLNT_E_DEVICE_INVALIDATED {
                    return Ok(WasapiSampleResult::Reinitialize);
                }
                return Err(windows_error("read WASAPI packet", error));
            }

            let copy_result = (|| -> Result<(), String> {
                let sample_count = usize::try_from(frames)
                    .ok()
                    .and_then(|frames| frames.checked_mul(self.channel_count))
                    .ok_or_else(|| "WASAPI packet sample count overflowed".to_owned())?;
                let next_length = self
                    .pending_samples
                    .len()
                    .checked_add(sample_count)
                    .ok_or_else(|| "WASAPI pending sample count overflowed".to_owned())?;
                if next_length > self.sample_capacity {
                    return Err("WASAPI capture buffer exceeded its bounded capacity".to_owned());
                }
                if flags & (AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) != 0 {
                    self.pending_samples
                        .extend(std::iter::repeat_n(0.0, sample_count));
                } else if data.is_null() {
                    return Err("WASAPI returned a null non-silent sample buffer".to_owned());
                } else {
                    let samples =
                        unsafe { slice::from_raw_parts(data.cast::<f32>(), sample_count) };
                    self.pending_samples.extend(samples.iter().copied());
                }
                Ok(())
            })();
            let release_result = unsafe { self.capture_client.ReleaseBuffer(frames) }
                .map_err(|error| windows_error("release WASAPI packet", error));
            release_result?;
            copy_result?;
        }
    }
}

impl Drop for WasapiCapture {
    fn drop(&mut self) {
        let _ = unsafe { self.audio_client.Stop() };
        if let Some(handle) = self.multimedia_task.take() {
            let _ = unsafe { AvRevertMmThreadCharacteristics(handle) };
        }
    }
}

fn float_wave_format(channel_count: u16) -> Result<WAVEFORMATEXTENSIBLE, String> {
    let channel_mask = match channel_count {
        2 => SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT,
        6 => {
            SPEAKER_FRONT_LEFT
                | SPEAKER_FRONT_RIGHT
                | SPEAKER_FRONT_CENTER
                | SPEAKER_LOW_FREQUENCY
                | SPEAKER_BACK_LEFT
                | SPEAKER_BACK_RIGHT
        }
        8 => {
            SPEAKER_FRONT_LEFT
                | SPEAKER_FRONT_RIGHT
                | SPEAKER_FRONT_CENTER
                | SPEAKER_LOW_FREQUENCY
                | SPEAKER_BACK_LEFT
                | SPEAKER_BACK_RIGHT
                | SPEAKER_SIDE_LEFT
                | SPEAKER_SIDE_RIGHT
        }
        _ => return Err(format!("unsupported WASAPI channel count {channel_count}")),
    };
    let block_alignment = channel_count
        .checked_mul(BYTES_PER_SAMPLE)
        .ok_or_else(|| "WASAPI block alignment overflowed".to_owned())?;
    Ok(WAVEFORMATEXTENSIBLE {
        Format: WAVEFORMATEX {
            wFormatTag: WAVE_FORMAT_EXTENSIBLE as u16,
            nChannels: channel_count,
            nSamplesPerSec: SAMPLE_RATE,
            nAvgBytesPerSec: SAMPLE_RATE * u32::from(block_alignment),
            nBlockAlign: block_alignment,
            wBitsPerSample: BYTES_PER_SAMPLE * 8,
            cbSize: (size_of::<WAVEFORMATEXTENSIBLE>() - size_of::<WAVEFORMATEX>()) as u16,
        },
        Samples: WAVEFORMATEXTENSIBLE_0 {
            wValidBitsPerSample: BYTES_PER_SAMPLE * 8,
        },
        dwChannelMask: channel_mask,
        SubFormat: KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
    })
}

fn device_id(device: &IMMDevice) -> Result<String, String> {
    let value = unsafe { device.GetId() }
        .map_err(|error| windows_error("read audio endpoint identity", error))?;
    let result = unsafe { value.to_string() }
        .map_err(|error| format!("decode audio endpoint identity: {error}"));
    unsafe { CoTaskMemFree(Some(value.0.cast::<c_void>())) };
    result
}

fn wide_string(value: &str) -> Result<Vec<u16>, String> {
    if value.contains('\0') {
        return Err("audio endpoint identity contains NUL".to_owned());
    }
    Ok(value.encode_utf16().chain([0]).collect())
}

fn windows_error(operation: &str, error: Error) -> String {
    format!("{operation}: {error}")
}
