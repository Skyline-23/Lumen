use std::mem::ManuallyDrop;

use windows_api::core::{Interface, PCWSTR};
use windows_api::Win32::Foundation::HMODULE;
use windows_api::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows_api::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11Device1, ID3D11DeviceContext, ID3D11Texture2D,
    ID3D11VideoContext, ID3D11VideoContext1, ID3D11VideoDevice, D3D11_BIND_RENDER_TARGET,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_SDK_VERSION,
    D3D11_TEX2D_VPIV, D3D11_TEX2D_VPOV, D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT,
    D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE, D3D11_VIDEO_PROCESSOR_CONTENT_DESC,
    D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT, D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT,
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0,
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0,
    D3D11_VIDEO_PROCESSOR_STREAM, D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
    D3D11_VPIV_DIMENSION_TEXTURE2D, D3D11_VPOV_DIMENSION_TEXTURE2D,
};
use windows_api::Win32::Graphics::Dxgi::Common::{
    DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
    DXGI_COLOR_SPACE_TYPE, DXGI_COLOR_SPACE_YCBCR_STUDIO_G2084_LEFT_P2020,
    DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709, DXGI_FORMAT, DXGI_FORMAT_AYUV,
    DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_NV12, DXGI_FORMAT_P010, DXGI_FORMAT_R16G16B16A16_FLOAT,
    DXGI_FORMAT_Y410, DXGI_RATIONAL, DXGI_SAMPLE_DESC,
};
use windows_api::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1, IDXGIKeyedMutex, DXGI_ERROR_NOT_FOUND,
    DXGI_SHARED_RESOURCE_READ, DXGI_SHARED_RESOURCE_WRITE,
};

use crate::PlatformChromaSubsampling;

use super::native_display_driver::{shared_frame_name, DriverHandle};

pub(super) struct NativeIddCxCapture {
    driver: DriverHandle,
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    device1: ID3D11Device1,
    surface: Option<NativeSharedSurface>,
    require_hdr: bool,
}

pub(super) struct NativeCapturedFrame {
    release: IDXGIKeyedMutex,
    texture: ID3D11Texture2D,
}

struct NativeSharedSurface {
    revision: u32,
    texture: ID3D11Texture2D,
    keyed_mutex: IDXGIKeyedMutex,
}

pub(super) struct NativeEncoderSurface {
    texture: ID3D11Texture2D,
}

impl NativeIddCxCapture {
    pub(super) fn open(driver: DriverHandle, require_hdr: bool) -> Result<Self, String> {
        let factory = unsafe { CreateDXGIFactory1::<IDXGIFactory1>() }
            .map_err(|error| format!("Windows DXGI factory creation failed: {error}"))?;
        let adapter_luid = driver.render_adapter_luid()?;
        let adapter = select_adapter_by_luid(&factory, adapter_luid)?;
        let (device, context) = create_device(&adapter)?;
        let device1 = device.cast::<ID3D11Device1>().map_err(|error| {
            format!("Windows D3D11.1 shared-resource device is unavailable: {error}")
        })?;
        driver.start_frame_delivery()?;
        Ok(Self {
            driver,
            device,
            context,
            device1,
            surface: None,
            require_hdr,
        })
    }

    pub(super) fn acquire_next_frame(
        &mut self,
        timeout_milliseconds: u32,
    ) -> Result<Option<NativeCapturedFrame>, String> {
        let record = self.driver.dequeue_frame()?;
        let format_value = i32::try_from(record.format)
            .map_err(|_| "Windows IDD frame format is out of range".to_owned())?;
        let format = DXGI_FORMAT(format_value);
        if !matches!(
            format,
            DXGI_FORMAT_B8G8R8A8_UNORM | DXGI_FORMAT_R16G16B16A16_FLOAT
        ) {
            return Err(format!(
                "Windows IDD frame format {:?} is unsupported",
                format
            ));
        }
        if self.require_hdr && format != DXGI_FORMAT_R16G16B16A16_FLOAT {
            return Err("Windows HDR session requires a scRGB IDD surface".to_owned());
        }
        let needs_open = self
            .surface
            .as_ref()
            .is_none_or(|surface| surface.revision != record.surface_revision);
        if needs_open {
            let name = shared_frame_name(record.monitor_id, record.surface_revision);
            let name = name
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect::<Vec<_>>();
            let access = DXGI_SHARED_RESOURCE_READ.0 | DXGI_SHARED_RESOURCE_WRITE.0;
            let texture = unsafe {
                self.device1
                    .OpenSharedResourceByName::<_, ID3D11Texture2D>(PCWSTR(name.as_ptr()), access)
            }
            .map_err(|error| format!("Windows IDD shared frame open failed: {error}"))?;
            let keyed_mutex = texture
                .cast::<IDXGIKeyedMutex>()
                .map_err(|error| format!("Windows IDD shared frame has no keyed mutex: {error}"))?;
            self.surface = Some(NativeSharedSurface {
                revision: record.surface_revision,
                texture,
                keyed_mutex,
            });
        }
        let surface = self
            .surface
            .as_ref()
            .ok_or_else(|| "Windows IDD shared frame is unavailable".to_owned())?;
        unsafe { surface.keyed_mutex.AcquireSync(1, timeout_milliseconds) }
            .map_err(|error| format!("Windows IDD shared frame wait failed: {error}"))?;
        let frame = NativeCapturedFrame {
            release: surface.keyed_mutex.clone(),
            texture: surface.texture.clone(),
        };
        if let Err(error) = frame.validate() {
            drop(frame);
            return Err(error);
        }
        Ok(Some(frame))
    }

    pub(super) fn device(&self) -> &ID3D11Device {
        &self.device
    }

    pub(super) fn pause_frame_delivery(&self) -> Result<(), String> {
        self.driver.stop_frame_delivery()
    }

    pub(super) fn resume_frame_delivery(&self) -> Result<(), String> {
        self.driver.start_frame_delivery()
    }

    pub(super) fn convert_frame(
        &self,
        frame: &NativeCapturedFrame,
        output_width: u32,
        output_height: u32,
        frames_per_second: u32,
        ten_bit: bool,
        chroma_subsampling: PlatformChromaSubsampling,
    ) -> Result<NativeEncoderSurface, String> {
        convert_iddcx_frame(
            &self.device,
            &self.context,
            frame,
            output_width,
            output_height,
            frames_per_second,
            ten_bit,
            chroma_subsampling,
        )
    }
}

impl Drop for NativeIddCxCapture {
    fn drop(&mut self) {
        let _ = self.driver.stop_frame_delivery();
    }
}

impl NativeEncoderSurface {
    pub(super) fn texture(&self) -> &ID3D11Texture2D {
        &self.texture
    }
}

fn convert_iddcx_frame(
    device: &ID3D11Device,
    context: &ID3D11DeviceContext,
    frame: &NativeCapturedFrame,
    output_width: u32,
    output_height: u32,
    frames_per_second: u32,
    ten_bit: bool,
    chroma_subsampling: PlatformChromaSubsampling,
) -> Result<NativeEncoderSurface, String> {
    let mut input_description = D3D11_TEXTURE2D_DESC::default();
    unsafe { frame.texture.GetDesc(&mut input_description) };
    let output_format = encoder_surface_format(chroma_subsampling, ten_bit);
    let video_device = device
        .cast::<ID3D11VideoDevice>()
        .map_err(|error| format!("Windows D3D11 video device is unavailable: {error}"))?;
    let video_context = context
        .cast::<ID3D11VideoContext>()
        .map_err(|error| format!("Windows D3D11 video context is unavailable: {error}"))?;
    let video_context1 = context.cast::<ID3D11VideoContext1>().map_err(|error| {
        format!("Windows D3D11.1 color-managed video context is unavailable: {error}")
    })?;
    let (input_color_space, output_color_space) =
        encoder_color_spaces(input_description.Format, ten_bit)?;
    let content = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
        InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
        InputFrameRate: DXGI_RATIONAL {
            Numerator: frames_per_second,
            Denominator: 1,
        },
        InputWidth: input_description.Width,
        InputHeight: input_description.Height,
        OutputFrameRate: DXGI_RATIONAL {
            Numerator: frames_per_second,
            Denominator: 1,
        },
        OutputWidth: output_width,
        OutputHeight: output_height,
        Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
    };
    let enumerator = unsafe { video_device.CreateVideoProcessorEnumerator(&content) }
        .map_err(|error| format!("Windows video processor enumeration failed: {error}"))?;
    require_format_support(&enumerator, input_description.Format, true)?;
    require_format_support(&enumerator, output_format, false)?;
    let processor = unsafe { video_device.CreateVideoProcessor(&enumerator, 0) }
        .map_err(|error| format!("Windows video processor creation failed: {error}"))?;
    let output_texture =
        create_encoder_texture(device, output_width, output_height, output_format)?;
    let input_view = create_input_view(&video_device, &enumerator, &frame.texture)?;
    let output_view = create_output_view(&video_device, &enumerator, &output_texture)?;
    unsafe {
        video_context.VideoProcessorSetStreamFrameFormat(
            &processor,
            0,
            D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
        );
        video_context1.VideoProcessorSetStreamColorSpace1(&processor, 0, input_color_space);
        video_context1.VideoProcessorSetOutputColorSpace1(&processor, output_color_space);
    }
    let mut stream = D3D11_VIDEO_PROCESSOR_STREAM {
        Enable: true.into(),
        pInputSurface: ManuallyDrop::new(Some(input_view)),
        ..Default::default()
    };
    let converted = unsafe {
        video_context.VideoProcessorBlt(&processor, &output_view, 0, std::slice::from_ref(&stream))
    }
    .map_err(|error| format!("Windows IDD GPU video conversion failed: {error}"));
    unsafe { ManuallyDrop::drop(&mut stream.pInputSurface) };
    converted?;
    unsafe { context.Flush() };
    Ok(NativeEncoderSurface {
        texture: output_texture,
    })
}

fn encoder_surface_format(
    chroma_subsampling: PlatformChromaSubsampling,
    ten_bit: bool,
) -> DXGI_FORMAT {
    match (chroma_subsampling, ten_bit) {
        (PlatformChromaSubsampling::Yuv420, false) => DXGI_FORMAT_NV12,
        (PlatformChromaSubsampling::Yuv420, true) => DXGI_FORMAT_P010,
        (PlatformChromaSubsampling::Yuv444, false) => DXGI_FORMAT_AYUV,
        (PlatformChromaSubsampling::Yuv444, true) => DXGI_FORMAT_Y410,
    }
}

#[cfg(test)]
mod iddcx_tests {
    use super::*;

    #[test]
    fn selects_packed_444_encoder_surfaces() {
        assert_eq!(
            encoder_surface_format(PlatformChromaSubsampling::Yuv444, false),
            DXGI_FORMAT_AYUV
        );
        assert_eq!(
            encoder_surface_format(PlatformChromaSubsampling::Yuv444, true),
            DXGI_FORMAT_Y410
        );
    }
}

fn encoder_color_spaces(
    input_format: DXGI_FORMAT,
    ten_bit: bool,
) -> Result<(DXGI_COLOR_SPACE_TYPE, DXGI_COLOR_SPACE_TYPE), String> {
    let input = match input_format {
        DXGI_FORMAT_B8G8R8A8_UNORM => {
            if ten_bit {
                return Err(
                    "Windows HDR session requires an scRGB desktop duplication surface".to_owned(),
                );
            }
            DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709
        }
        DXGI_FORMAT_R16G16B16A16_FLOAT => DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709,
        _ => {
            return Err(format!(
                "Windows desktop color space is unknown for format {:?}",
                input_format
            ));
        }
    };
    let output = if ten_bit {
        DXGI_COLOR_SPACE_YCBCR_STUDIO_G2084_LEFT_P2020
    } else {
        DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709
    };
    Ok((input, output))
}

fn require_format_support(
    enumerator: &windows_api::Win32::Graphics::Direct3D11::ID3D11VideoProcessorEnumerator,
    format: DXGI_FORMAT,
    input: bool,
) -> Result<(), String> {
    let support = unsafe { enumerator.CheckVideoProcessorFormat(format) }
        .map_err(|error| format!("Windows video format query failed: {error}"))?;
    let required = if input {
        u32::try_from(D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT.0)
    } else {
        u32::try_from(D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT.0)
    }
    .map_err(|_| "Windows video format-support flag is invalid".to_owned())?;
    (support & required != 0).then_some(()).ok_or_else(|| {
        format!(
            "Windows video processor does not support {:?} as {}",
            format,
            if input { "input" } else { "output" }
        )
    })
}

fn create_encoder_texture(
    device: &ID3D11Device,
    width: u32,
    height: u32,
    format: DXGI_FORMAT,
) -> Result<ID3D11Texture2D, String> {
    let bind_flags = u32::try_from(D3D11_BIND_RENDER_TARGET.0)
        .map_err(|_| "Windows render-target bind flag is invalid".to_owned())?;
    let description = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 1,
        Format: format,
        SampleDesc: DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: bind_flags,
        CPUAccessFlags: 0,
        MiscFlags: 0,
    };
    let mut texture = None;
    unsafe { device.CreateTexture2D(&description, None, Some(&mut texture)) }
        .map_err(|error| format!("Windows encoder surface creation failed: {error}"))?;
    texture.ok_or_else(|| "Windows encoder surface is unavailable".to_owned())
}

fn create_input_view(
    device: &ID3D11VideoDevice,
    enumerator: &windows_api::Win32::Graphics::Direct3D11::ID3D11VideoProcessorEnumerator,
    texture: &ID3D11Texture2D,
) -> Result<windows_api::Win32::Graphics::Direct3D11::ID3D11VideoProcessorInputView, String> {
    let description = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
        FourCC: 0,
        ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
        Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 {
            Texture2D: D3D11_TEX2D_VPIV {
                MipSlice: 0,
                ArraySlice: 0,
            },
        },
    };
    let mut view = None;
    unsafe {
        device.CreateVideoProcessorInputView(texture, enumerator, &description, Some(&mut view))
    }
    .map_err(|error| format!("Windows video input view creation failed: {error}"))?;
    view.ok_or_else(|| "Windows video input view is unavailable".to_owned())
}

fn create_output_view(
    device: &ID3D11VideoDevice,
    enumerator: &windows_api::Win32::Graphics::Direct3D11::ID3D11VideoProcessorEnumerator,
    texture: &ID3D11Texture2D,
) -> Result<windows_api::Win32::Graphics::Direct3D11::ID3D11VideoProcessorOutputView, String> {
    let description = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
        ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
        Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 {
            Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 },
        },
    };
    let mut view = None;
    unsafe {
        device.CreateVideoProcessorOutputView(texture, enumerator, &description, Some(&mut view))
    }
    .map_err(|error| format!("Windows video output view creation failed: {error}"))?;
    view.ok_or_else(|| "Windows video output view is unavailable".to_owned())
}

impl NativeCapturedFrame {
    pub(super) fn validate(&self) -> Result<(), String> {
        let mut description = Default::default();
        unsafe { self.texture.GetDesc(&mut description) };
        if description.Width == 0 || description.Height == 0 {
            return Err("Windows desktop frame has empty geometry".to_owned());
        }
        if !matches!(
            description.Format,
            DXGI_FORMAT_B8G8R8A8_UNORM | DXGI_FORMAT_R16G16B16A16_FLOAT
        ) {
            return Err(format!(
                "Windows desktop frame format {:?} is unsupported",
                description.Format
            ));
        }
        Ok(())
    }
}

impl Drop for NativeCapturedFrame {
    fn drop(&mut self) {
        let _ = unsafe { self.release.ReleaseSync(0) };
    }
}

fn select_adapter_by_luid(
    factory: &IDXGIFactory1,
    adapter_luid: u64,
) -> Result<IDXGIAdapter1, String> {
    let mut adapter_index = 0_u32;
    loop {
        let adapter = match unsafe { factory.EnumAdapters1(adapter_index) } {
            Ok(adapter) => adapter,
            Err(error) if error.code() == DXGI_ERROR_NOT_FOUND => break,
            Err(error) => return Err(format!("Windows DXGI adapter enumeration failed: {error}")),
        };
        adapter_index = adapter_index.saturating_add(1);
        let description = unsafe { adapter.GetDesc1() }
            .map_err(|error| format!("Windows DXGI adapter description failed: {error}"))?;
        let packed_luid = u64::from(description.AdapterLuid.LowPart)
            | (u64::from(description.AdapterLuid.HighPart as u32) << 32);
        if packed_luid == adapter_luid {
            return Ok(adapter);
        }
    }
    Err(format!(
        "Windows DXGI found no render adapter matching LUID {adapter_luid:016X}"
    ))
}

fn create_device(adapter: &IDXGIAdapter1) -> Result<(ID3D11Device, ID3D11DeviceContext), String> {
    let mut device = None;
    let mut context = None;
    let flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    unsafe {
        D3D11CreateDevice(
            adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            HMODULE::default(),
            flags,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )
    }
    .map_err(|error| format!("Windows D3D11 device creation failed: {error}"))?;
    let device = device.ok_or_else(|| "Windows D3D11 device is unavailable".to_owned())?;
    let context = context.ok_or_else(|| "Windows D3D11 context is unavailable".to_owned())?;
    Ok((device, context))
}
