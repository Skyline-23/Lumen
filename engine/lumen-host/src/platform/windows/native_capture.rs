use std::mem::ManuallyDrop;

use windows_api::core::{Interface, PCSTR, PCWSTR};
use windows_api::Win32::Foundation::{HMODULE, POINT, RECT};
use windows_api::Win32::Graphics::Direct3D::Fxc::{
    D3DCompile, D3DCOMPILE_ENABLE_STRICTNESS, D3DCOMPILE_OPTIMIZATION_LEVEL3,
};
use windows_api::Win32::Graphics::Direct3D::{
    ID3DBlob, ID3DInclude, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST, D3D_DRIVER_TYPE_UNKNOWN,
};
use windows_api::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Buffer, ID3D11Device, ID3D11Device1, ID3D11DeviceContext,
    ID3D11PixelShader, ID3D11RenderTargetView, ID3D11ShaderResourceView, ID3D11Texture2D,
    ID3D11VertexShader, ID3D11VideoContext, ID3D11VideoContext1, ID3D11VideoDevice,
    D3D11_BIND_CONSTANT_BUFFER, D3D11_BIND_RENDER_TARGET, D3D11_BIND_SHADER_RESOURCE,
    D3D11_BUFFER_DESC, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
    D3D11_SDK_VERSION, D3D11_SUBRESOURCE_DATA, D3D11_TEX2D_VPIV, D3D11_TEX2D_VPOV,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
    D3D11_VIDEO_PROCESSOR_CAPS, D3D11_VIDEO_PROCESSOR_CONTENT_DESC,
    D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT, D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT,
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0,
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0,
    D3D11_VIDEO_PROCESSOR_STREAM, D3D11_VIDEO_USAGE_PLAYBACK_NORMAL, D3D11_VIEWPORT,
    D3D11_VPIV_DIMENSION_TEXTURE2D, D3D11_VPOV_DIMENSION_TEXTURE2D,
};
use windows_api::Win32::Graphics::Dxgi::Common::{
    DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709, DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020,
    DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709, DXGI_COLOR_SPACE_TYPE,
    DXGI_COLOR_SPACE_YCBCR_STUDIO_G2084_LEFT_P2020, DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709,
    DXGI_FORMAT, DXGI_FORMAT_AYUV, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_NV12, DXGI_FORMAT_P010,
    DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_Y410, DXGI_RATIONAL,
    DXGI_SAMPLE_DESC,
};
use windows_api::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1, IDXGIKeyedMutex, IDXGIOutput, IDXGIOutput6,
    IDXGIOutputDuplication, DXGI_ERROR_NOT_FOUND, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
    DXGI_OUTDUPL_POINTER_SHAPE_INFO, DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR,
    DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR, DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME,
    DXGI_SHARED_RESOURCE_READ, DXGI_SHARED_RESOURCE_WRITE,
};

use crate::cursor_mask::{expand_masked_color_cursor, expand_monochrome_cursor};
use crate::PlatformChromaSubsampling;

use super::native_display_driver::{shared_frame_name, DriverHandle};

const MAXIMUM_POINTER_DIMENSION: u32 = 512;
const SDR_CAPTURE_FORMATS: [DXGI_FORMAT; 1] = [DXGI_FORMAT_B8G8R8A8_UNORM];
const HDR_CAPTURE_FORMATS: [DXGI_FORMAT; 2] =
    [DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_B8G8R8A8_UNORM];
const POINTER_SHADER_ENTRY: PCSTR = PCSTR::from_raw(c"main".as_ptr().cast());
const VERTEX_SHADER_TARGET: PCSTR = PCSTR::from_raw(c"vs_5_0".as_ptr().cast());
const PIXEL_SHADER_TARGET: PCSTR = PCSTR::from_raw(c"ps_5_0".as_ptr().cast());

const POINTER_VERTEX_SHADER: &str = r#"
float4 main(uint vertexId : SV_VertexID) : SV_Position {
    float2 position = float2((vertexId << 1) & 2, vertexId & 2);
    return float4(position.x * 2.0 - 1.0, 1.0 - position.y * 2.0, 0.0, 1.0);
}
"#;

const MONOCHROME_POINTER_PIXEL_SHADER: &str = r#"
Texture2D<float4> desktopTexture : register(t0);
Texture2D<float4> pointerTexture : register(t1);
cbuffer PointerConstants : register(b0) {
    int2 destinationOrigin;
    int2 sourceOrigin;
};

float4 main(float4 position : SV_Position) : SV_Target {
    int2 desktopCoordinate = int2(position.xy);
    int2 pointerCoordinate = sourceOrigin + desktopCoordinate - destinationOrigin;
    float4 desktop = desktopTexture.Load(int3(desktopCoordinate, 0));
    float4 pointer = pointerTexture.Load(int3(pointerCoordinate, 0));
    float3 masked = pointer.r >= 0.5 ? desktop.rgb : float3(0.0, 0.0, 0.0);
    float3 composed = pointer.g >= 0.5 ? 1.0 - masked : masked;
    return float4(composed, desktop.a);
}
"#;

const MASKED_COLOR_POINTER_PIXEL_SHADER: &str = r#"
Texture2D<float4> desktopTexture : register(t0);
Texture2D<float4> pointerTexture : register(t1);
cbuffer PointerConstants : register(b0) {
    int2 destinationOrigin;
    int2 sourceOrigin;
};

float4 main(float4 position : SV_Position) : SV_Target {
    int2 desktopCoordinate = int2(position.xy);
    int2 pointerCoordinate = sourceOrigin + desktopCoordinate - destinationOrigin;
    float4 desktop = desktopTexture.Load(int3(desktopCoordinate, 0));
    float4 pointer = pointerTexture.Load(int3(pointerCoordinate, 0));
    if (pointer.a < 0.5) {
        return float4(pointer.rgb, desktop.a);
    }
    uint3 desktopBytes = uint3(round(saturate(desktop.rgb) * 255.0));
    uint3 pointerBytes = uint3(round(saturate(pointer.rgb) * 255.0));
    return float4(float3(desktopBytes ^ pointerBytes) / 255.0, desktop.a);
}
"#;

pub(super) struct NativeDesktopDuplication {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    duplication: IDXGIOutputDuplication,
    capture_format: DXGI_FORMAT,
    pointer: NativePointerState,
    pointer_compositor: Option<NativePointerCompositor>,
}

pub(super) struct NativeIddCxCapture {
    driver: DriverHandle,
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    device1: ID3D11Device1,
    surface: Option<NativeSharedSurface>,
    require_hdr: bool,
}

pub(super) struct NativeCapturedFrame {
    release: NativeFrameRelease,
    texture: ID3D11Texture2D,
    pointer: Option<NativePointerOverlay>,
}

enum NativeFrameRelease {
    Duplication(IDXGIOutputDuplication),
    Shared(IDXGIKeyedMutex),
}

struct NativeSharedSurface {
    revision: u32,
    texture: ID3D11Texture2D,
    keyed_mutex: IDXGIKeyedMutex,
}

pub(super) struct NativeEncoderSurface {
    texture: ID3D11Texture2D,
}

#[derive(Default)]
struct NativePointerState {
    visible: bool,
    position: POINT,
    shape: Option<NativePointerShape>,
}

struct NativePointerShape {
    texture: ID3D11Texture2D,
    shader_view: ID3D11ShaderResourceView,
    width: u32,
    height: u32,
    composition: NativePointerComposition,
}

struct NativePointerOverlay {
    texture: ID3D11Texture2D,
    shader_view: ID3D11ShaderResourceView,
    source: RECT,
    destination: RECT,
    composition: NativePointerComposition,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum NativePointerComposition {
    AlphaColor,
    Monochrome,
    MaskedColor,
}

struct NativePointerCompositor {
    vertex_shader: ID3D11VertexShader,
    monochrome_shader: ID3D11PixelShader,
    masked_color_shader: ID3D11PixelShader,
    constants: ID3D11Buffer,
    surfaces: Option<NativePointerCompositionSurfaces>,
}

struct NativePointerCompositionSurfaces {
    width: u32,
    height: u32,
    format: DXGI_FORMAT,
    source: ID3D11Texture2D,
    source_view: ID3D11ShaderResourceView,
    output: ID3D11Texture2D,
    output_view: ID3D11RenderTargetView,
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
            release: NativeFrameRelease::Shared(surface.keyed_mutex.clone()),
            texture: surface.texture.clone(),
            pointer: None,
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

#[repr(C)]
struct NativePointerShaderConstants {
    destination_left: i32,
    destination_top: i32,
    source_left: i32,
    source_top: i32,
}

impl NativeDesktopDuplication {
    pub(super) fn open(
        adapter_name: &str,
        output_name: &str,
        require_hdr: bool,
    ) -> Result<Self, String> {
        let factory = unsafe { CreateDXGIFactory1::<IDXGIFactory1>() }
            .map_err(|error| format!("Windows DXGI factory creation failed: {error}"))?;
        let (adapter, output) = select_output(&factory, adapter_name, output_name)?;
        let (device, context) = create_device(&adapter)?;
        let output = output.cast::<IDXGIOutput6>().map_err(|error| {
            format!("Windows DXGI output does not support high-color desktop duplication: {error}")
        })?;
        let output_description = unsafe { output.GetDesc1() }
            .map_err(|error| format!("Windows output color description failed: {error}"))?;
        let output_is_hdr = output_description.BitsPerColor >= 10
            && matches!(
                output_description.ColorSpace,
                DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020
                    | DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709
            );
        if require_hdr && !output_is_hdr {
            return Err(
                "Windows HDR session requires Advanced Color on the selected display".to_owned(),
            );
        }
        let (capture_format, supported_formats) = if output_is_hdr {
            (
                DXGI_FORMAT_R16G16B16A16_FLOAT,
                HDR_CAPTURE_FORMATS.as_slice(),
            )
        } else {
            (DXGI_FORMAT_B8G8R8A8_UNORM, SDR_CAPTURE_FORMATS.as_slice())
        };
        let duplication = unsafe { output.DuplicateOutput1(&device, 0, supported_formats) }
            .map_err(|error| {
                format!("Windows high-color desktop duplication startup failed: {error}")
            })?;
        let description = unsafe { duplication.GetDesc() };
        if description.ModeDesc.Width == 0 || description.ModeDesc.Height == 0 {
            return Err("Windows desktop duplication reported empty geometry".to_owned());
        }
        if description.ModeDesc.Format != capture_format {
            return Err(format!(
                "Windows desktop duplication returned {:?} instead of required {:?}",
                description.ModeDesc.Format, capture_format
            ));
        }
        Ok(Self {
            device,
            context,
            duplication,
            capture_format,
            pointer: NativePointerState::default(),
            pointer_compositor: None,
        })
    }

    pub(super) fn acquire_next_frame(
        &mut self,
        timeout_milliseconds: u32,
    ) -> Result<Option<NativeCapturedFrame>, String> {
        let mut information = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource = None;
        match unsafe {
            self.duplication
                .AcquireNextFrame(timeout_milliseconds, &mut information, &mut resource)
        } {
            Ok(()) => {}
            Err(error) if error.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(None),
            Err(error) => return Err(format!("Windows desktop frame acquisition failed: {error}")),
        }
        let Some(resource) = resource else {
            let _ = unsafe { self.duplication.ReleaseFrame() };
            return Err("Windows desktop duplication returned no frame resource".to_owned());
        };
        let texture = match resource.cast::<ID3D11Texture2D>() {
            Ok(texture) => texture,
            Err(error) => {
                let _ = unsafe { self.duplication.ReleaseFrame() };
                return Err(format!(
                    "Windows desktop frame is not a D3D11 texture: {error}"
                ));
            }
        };
        let mut texture_description = D3D11_TEXTURE2D_DESC::default();
        unsafe { texture.GetDesc(&mut texture_description) };
        if texture_description.Format != self.capture_format {
            let _ = unsafe { self.duplication.ReleaseFrame() };
            return Err(format!(
                "Windows desktop frame changed from {:?} to unsupported {:?}",
                self.capture_format, texture_description.Format
            ));
        }
        let pointer = match self.update_pointer(&information, &texture) {
            Ok(pointer) => pointer,
            Err(error) => {
                let _ = unsafe { self.duplication.ReleaseFrame() };
                return Err(error);
            }
        };
        Ok(Some(NativeCapturedFrame {
            release: NativeFrameRelease::Duplication(self.duplication.clone()),
            texture,
            pointer,
        }))
    }

    pub(super) fn device(&self) -> &ID3D11Device {
        &self.device
    }

    fn update_pointer(
        &mut self,
        information: &DXGI_OUTDUPL_FRAME_INFO,
        desktop: &ID3D11Texture2D,
    ) -> Result<Option<NativePointerOverlay>, String> {
        if information.LastMouseUpdateTime != 0 {
            self.pointer.visible = information.PointerPosition.Visible.as_bool();
            self.pointer.position = information.PointerPosition.Position;
        }
        if information.PointerShapeBufferSize != 0 {
            self.pointer.shape = Some(self.read_pointer_shape(information.PointerShapeBufferSize)?);
        }
        if !self.pointer.visible {
            return Ok(None);
        }
        let shape = match self.pointer.shape.as_ref() {
            Some(shape) => shape,
            None => {
                return Err(
                    "Windows desktop duplication exposed a cursor without a cached shape"
                        .to_owned(),
                );
            }
        };
        let mut desktop_description = D3D11_TEXTURE2D_DESC::default();
        unsafe { desktop.GetDesc(&mut desktop_description) };
        let desktop_width = i64::from(desktop_description.Width);
        let desktop_height = i64::from(desktop_description.Height);
        let pointer_x = i64::from(self.pointer.position.x);
        let pointer_y = i64::from(self.pointer.position.y);
        let pointer_right = pointer_x + i64::from(shape.width);
        let pointer_bottom = pointer_y + i64::from(shape.height);
        let destination_left = pointer_x.max(0);
        let destination_top = pointer_y.max(0);
        let destination_right = pointer_right.min(desktop_width);
        let destination_bottom = pointer_bottom.min(desktop_height);
        if destination_left >= destination_right || destination_top >= destination_bottom {
            return Ok(None);
        }
        let source_left = destination_left - pointer_x;
        let source_top = destination_top - pointer_y;
        let source_right = source_left + (destination_right - destination_left);
        let source_bottom = source_top + (destination_bottom - destination_top);
        Ok(Some(NativePointerOverlay {
            texture: shape.texture.clone(),
            shader_view: shape.shader_view.clone(),
            source: checked_rect(source_left, source_top, source_right, source_bottom)?,
            destination: checked_rect(
                destination_left,
                destination_top,
                destination_right,
                destination_bottom,
            )?,
            composition: shape.composition,
        }))
    }

    fn read_pointer_shape(&self, buffer_size: u32) -> Result<NativePointerShape, String> {
        let buffer_length = usize::try_from(buffer_size)
            .map_err(|_| "Windows cursor shape buffer is too large".to_owned())?;
        let mut bytes = vec![0_u8; buffer_length];
        let mut required = 0_u32;
        let mut information = DXGI_OUTDUPL_POINTER_SHAPE_INFO::default();
        unsafe {
            self.duplication.GetFramePointerShape(
                buffer_size,
                bytes.as_mut_ptr().cast(),
                &mut required,
                &mut information,
            )
        }
        .map_err(|error| format!("Windows cursor shape acquisition failed: {error}"))?;
        if required == 0 || required > buffer_size {
            return Err("Windows cursor shape reported an invalid buffer length".to_owned());
        }
        if information.Width == 0
            || information.Height == 0
            || information.Width > MAXIMUM_POINTER_DIMENSION
            || information.Height > MAXIMUM_POINTER_DIMENSION
        {
            return Err("Windows cursor shape has invalid geometry".to_owned());
        }
        let color = pointer_shape_type(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR.0)?;
        let monochrome = pointer_shape_type(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME.0)?;
        let masked_color = pointer_shape_type(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR.0)?;
        let (pixels, pitch, format, composition) = match information.Type {
            shape_type if shape_type == color => (
                validate_color_pointer_storage(&information, required, &bytes)?,
                information.Pitch,
                DXGI_FORMAT_B8G8R8A8_UNORM,
                NativePointerComposition::AlphaColor,
            ),
            shape_type if shape_type == masked_color => (
                expand_masked_color_cursor(
                    information.Width,
                    information.Height,
                    information.Pitch,
                    required,
                    &bytes,
                )?,
                information
                    .Width
                    .checked_mul(4)
                    .ok_or_else(|| "Windows cursor row pitch overflowed".to_owned())?,
                DXGI_FORMAT_R8G8B8A8_UNORM,
                NativePointerComposition::MaskedColor,
            ),
            shape_type if shape_type == monochrome => (
                expand_monochrome_cursor(
                    information.Width,
                    information.Height,
                    information.Pitch,
                    required,
                    &bytes,
                )?,
                information
                    .Width
                    .checked_mul(4)
                    .ok_or_else(|| "Windows cursor row pitch overflowed".to_owned())?,
                DXGI_FORMAT_R8G8B8A8_UNORM,
                NativePointerComposition::Monochrome,
            ),
            shape_type => {
                return Err(format!(
                    "Windows desktop cursor shape type {shape_type} is unsupported"
                ));
            }
        };
        let (texture, shader_view) = create_pointer_texture(
            &self.device,
            information.Width,
            information.Height,
            pitch,
            format,
            &pixels,
        )?;
        Ok(NativePointerShape {
            texture,
            shader_view,
            width: information.Width,
            height: information.Height,
            composition,
        })
    }

    pub(super) fn convert_frame(
        &mut self,
        frame: &NativeCapturedFrame,
        output_width: u32,
        output_height: u32,
        frames_per_second: u32,
        ten_bit: bool,
    ) -> Result<NativeEncoderSurface, String> {
        let input_texture = match frame.pointer.as_ref() {
            Some(pointer) if pointer.composition != NativePointerComposition::AlphaColor => {
                let compositor = match self.pointer_compositor.as_mut() {
                    Some(compositor) => compositor,
                    None => {
                        self.pointer_compositor = Some(NativePointerCompositor::new(&self.device)?);
                        self.pointer_compositor
                            .as_mut()
                            .expect("pointer compositor was initialized")
                    }
                };
                compositor.compose(&self.device, &self.context, &frame.texture, pointer)?
            }
            _ => frame.texture.clone(),
        };
        let mut input_description = D3D11_TEXTURE2D_DESC::default();
        unsafe { input_texture.GetDesc(&mut input_description) };
        let output_format = if ten_bit {
            DXGI_FORMAT_P010
        } else {
            DXGI_FORMAT_NV12
        };
        let video_device = self
            .device
            .cast::<ID3D11VideoDevice>()
            .map_err(|error| format!("Windows D3D11 video device is unavailable: {error}"))?;
        let video_context = self
            .context
            .cast::<ID3D11VideoContext>()
            .map_err(|error| format!("Windows D3D11 video context is unavailable: {error}"))?;
        let video_context1 = self
            .context
            .cast::<ID3D11VideoContext1>()
            .map_err(|error| {
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
            create_encoder_texture(&self.device, output_width, output_height, output_format)?;
        let input_view = create_input_view(&video_device, &enumerator, &input_texture)?;
        let output_view = create_output_view(&video_device, &enumerator, &output_texture)?;
        unsafe {
            video_context.VideoProcessorSetStreamFrameFormat(
                &processor,
                0,
                D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
            );
            video_context1.VideoProcessorSetStreamColorSpace1(&processor, 0, input_color_space);
            video_context1.VideoProcessorSetOutputColorSpace1(&processor, output_color_space);
        };
        let pointer_stream = if let Some(pointer) = frame
            .pointer
            .as_ref()
            .filter(|pointer| pointer.composition == NativePointerComposition::AlphaColor)
        {
            let mut capabilities = D3D11_VIDEO_PROCESSOR_CAPS::default();
            unsafe { enumerator.GetVideoProcessorCaps(&mut capabilities) }.map_err(|error| {
                format!("Windows video processor capability query failed: {error}")
            })?;
            if capabilities.MaxInputStreams < 2 {
                return Err(
                    "Windows video processor cannot composite a separate desktop cursor".to_owned(),
                );
            }
            let pointer_view = create_input_view(&video_device, &enumerator, &pointer.texture)?;
            let destination = scale_destination_rect(
                pointer.destination,
                input_description.Width,
                input_description.Height,
                output_width,
                output_height,
            )?;
            unsafe {
                video_context.VideoProcessorSetStreamFrameFormat(
                    &processor,
                    1,
                    D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                );
                video_context.VideoProcessorSetStreamSourceRect(
                    &processor,
                    1,
                    true,
                    Some(&pointer.source),
                );
                video_context.VideoProcessorSetStreamDestRect(
                    &processor,
                    1,
                    true,
                    Some(&destination),
                );
                video_context.VideoProcessorSetStreamAlpha(&processor, 1, true, 1.0);
                video_context1.VideoProcessorSetStreamColorSpace1(
                    &processor,
                    1,
                    DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
                );
            }
            Some(D3D11_VIDEO_PROCESSOR_STREAM {
                Enable: true.into(),
                pInputSurface: ManuallyDrop::new(Some(pointer_view)),
                ..Default::default()
            })
        } else {
            None
        };
        let desktop_stream = D3D11_VIDEO_PROCESSOR_STREAM {
            Enable: true.into(),
            pInputSurface: ManuallyDrop::new(Some(input_view)),
            ..Default::default()
        };
        let mut streams = Vec::with_capacity(1 + usize::from(pointer_stream.is_some()));
        streams.push(desktop_stream);
        if let Some(pointer_stream) = pointer_stream {
            streams.push(pointer_stream);
        }
        let converted =
            unsafe { video_context.VideoProcessorBlt(&processor, &output_view, 0, &streams) }
                .map_err(|error| format!("Windows GPU video conversion failed: {error}"));
        for stream in &mut streams {
            unsafe { ManuallyDrop::drop(&mut stream.pInputSurface) };
        }
        converted?;
        Ok(NativeEncoderSurface {
            texture: output_texture,
        })
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

fn checked_rect(left: i64, top: i64, right: i64, bottom: i64) -> Result<RECT, String> {
    Ok(RECT {
        left: i32::try_from(left)
            .map_err(|_| "Windows cursor left coordinate is out of range".to_owned())?,
        top: i32::try_from(top)
            .map_err(|_| "Windows cursor top coordinate is out of range".to_owned())?,
        right: i32::try_from(right)
            .map_err(|_| "Windows cursor right coordinate is out of range".to_owned())?,
        bottom: i32::try_from(bottom)
            .map_err(|_| "Windows cursor bottom coordinate is out of range".to_owned())?,
    })
}

fn scale_destination_rect(
    rectangle: RECT,
    input_width: u32,
    input_height: u32,
    output_width: u32,
    output_height: u32,
) -> Result<RECT, String> {
    if input_width == 0 || input_height == 0 || output_width == 0 || output_height == 0 {
        return Err("Windows cursor scaling geometry is empty".to_owned());
    }
    let scale_floor = |value: i32, input: u32, output: u32| -> Result<i64, String> {
        let value = u64::try_from(value)
            .map_err(|_| "Windows cursor destination is negative after clipping".to_owned())?;
        let scaled = value
            .checked_mul(u64::from(output))
            .and_then(|value| value.checked_div(u64::from(input)))
            .ok_or_else(|| "Windows cursor destination scaling overflowed".to_owned())?;
        i64::try_from(scaled)
            .map_err(|_| "Windows cursor destination exceeds coordinate range".to_owned())
    };
    let scale_ceil = |value: i32, input: u32, output: u32| -> Result<i64, String> {
        let value = u64::try_from(value)
            .map_err(|_| "Windows cursor destination is negative after clipping".to_owned())?;
        let input = u64::from(input);
        let scaled = value
            .checked_mul(u64::from(output))
            .and_then(|value| value.checked_add(input - 1))
            .and_then(|value| value.checked_div(input))
            .ok_or_else(|| "Windows cursor destination scaling overflowed".to_owned())?;
        i64::try_from(scaled)
            .map_err(|_| "Windows cursor destination exceeds coordinate range".to_owned())
    };
    checked_rect(
        scale_floor(rectangle.left, input_width, output_width)?,
        scale_floor(rectangle.top, input_height, output_height)?,
        scale_ceil(rectangle.right, input_width, output_width)?,
        scale_ceil(rectangle.bottom, input_height, output_height)?,
    )
}

fn pointer_shape_type(value: i32) -> Result<u32, String> {
    u32::try_from(value).map_err(|_| "Windows cursor shape identifier is invalid".to_owned())
}

fn validate_color_pointer_storage(
    information: &DXGI_OUTDUPL_POINTER_SHAPE_INFO,
    required: u32,
    bytes: &[u8],
) -> Result<Vec<u8>, String> {
    let minimum_pitch = information
        .Width
        .checked_mul(4)
        .ok_or_else(|| "Windows cursor row pitch overflowed".to_owned())?;
    let required_bytes = information
        .Pitch
        .checked_mul(information.Height)
        .ok_or_else(|| "Windows cursor shape size overflowed".to_owned())?;
    if information.Pitch < minimum_pitch || required_bytes > required {
        return Err("Windows color cursor shape has invalid row storage".to_owned());
    }
    let required_bytes = usize::try_from(required_bytes)
        .map_err(|_| "Windows cursor shape storage is too large".to_owned())?;
    bytes
        .get(..required_bytes)
        .map(|storage| storage.to_vec())
        .ok_or_else(|| "Windows cursor shape buffer is truncated".to_owned())
}

fn create_pointer_texture(
    device: &ID3D11Device,
    width: u32,
    height: u32,
    pitch: u32,
    format: DXGI_FORMAT,
    bytes: &[u8],
) -> Result<(ID3D11Texture2D, ID3D11ShaderResourceView), String> {
    let bind_flags = u32::try_from(D3D11_BIND_SHADER_RESOURCE.0)
        .map_err(|_| "Windows cursor shader-resource flag is invalid".to_owned())?;
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
    let initial = D3D11_SUBRESOURCE_DATA {
        pSysMem: bytes.as_ptr().cast(),
        SysMemPitch: pitch,
        SysMemSlicePitch: 0,
    };
    let mut texture = None;
    unsafe { device.CreateTexture2D(&description, Some(&initial), Some(&mut texture)) }
        .map_err(|error| format!("Windows cursor texture creation failed: {error}"))?;
    let texture = texture.ok_or_else(|| "Windows cursor texture is unavailable".to_owned())?;
    let shader_view = create_shader_resource_view(device, &texture, "cursor")?;
    Ok((texture, shader_view))
}

impl NativePointerCompositor {
    fn new(device: &ID3D11Device) -> Result<Self, String> {
        let vertex_bytecode = compile_pointer_shader(POINTER_VERTEX_SHADER, VERTEX_SHADER_TARGET)?;
        let monochrome_bytecode =
            compile_pointer_shader(MONOCHROME_POINTER_PIXEL_SHADER, PIXEL_SHADER_TARGET)?;
        let masked_color_bytecode =
            compile_pointer_shader(MASKED_COLOR_POINTER_PIXEL_SHADER, PIXEL_SHADER_TARGET)?;
        let mut vertex_shader = None;
        let mut monochrome_shader = None;
        let mut masked_color_shader = None;
        unsafe {
            device.CreateVertexShader(
                &vertex_bytecode,
                None::<&windows_api::Win32::Graphics::Direct3D11::ID3D11ClassLinkage>,
                Some(&mut vertex_shader),
            )
        }
        .map_err(|error| format!("Windows cursor vertex shader creation failed: {error}"))?;
        unsafe {
            device.CreatePixelShader(
                &monochrome_bytecode,
                None::<&windows_api::Win32::Graphics::Direct3D11::ID3D11ClassLinkage>,
                Some(&mut monochrome_shader),
            )
        }
        .map_err(|error| format!("Windows monochrome cursor shader creation failed: {error}"))?;
        unsafe {
            device.CreatePixelShader(
                &masked_color_bytecode,
                None::<&windows_api::Win32::Graphics::Direct3D11::ID3D11ClassLinkage>,
                Some(&mut masked_color_shader),
            )
        }
        .map_err(|error| format!("Windows masked cursor shader creation failed: {error}"))?;
        let constants_description = D3D11_BUFFER_DESC {
            ByteWidth: u32::try_from(std::mem::size_of::<NativePointerShaderConstants>())
                .map_err(|_| "Windows cursor constants are too large".to_owned())?,
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: u32::try_from(D3D11_BIND_CONSTANT_BUFFER.0)
                .map_err(|_| "Windows constant-buffer bind flag is invalid".to_owned())?,
            CPUAccessFlags: 0,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let mut constants = None;
        unsafe { device.CreateBuffer(&constants_description, None, Some(&mut constants)) }
            .map_err(|error| format!("Windows cursor constant buffer creation failed: {error}"))?;
        Ok(Self {
            vertex_shader: vertex_shader
                .ok_or_else(|| "Windows cursor vertex shader is unavailable".to_owned())?,
            monochrome_shader: monochrome_shader
                .ok_or_else(|| "Windows monochrome cursor shader is unavailable".to_owned())?,
            masked_color_shader: masked_color_shader
                .ok_or_else(|| "Windows masked cursor shader is unavailable".to_owned())?,
            constants: constants
                .ok_or_else(|| "Windows cursor constant buffer is unavailable".to_owned())?,
            surfaces: None,
        })
    }

    fn compose(
        &mut self,
        device: &ID3D11Device,
        context: &ID3D11DeviceContext,
        desktop: &ID3D11Texture2D,
        pointer: &NativePointerOverlay,
    ) -> Result<ID3D11Texture2D, String> {
        let mut description = D3D11_TEXTURE2D_DESC::default();
        unsafe { desktop.GetDesc(&mut description) };
        self.ensure_surfaces(device, &description)?;
        let surfaces = self
            .surfaces
            .as_ref()
            .expect("pointer composition surfaces were initialized");
        unsafe {
            context.CopyResource(&surfaces.source, desktop);
            context.CopyResource(&surfaces.output, desktop);
        }
        let constants = NativePointerShaderConstants {
            destination_left: pointer.destination.left,
            destination_top: pointer.destination.top,
            source_left: pointer.source.left,
            source_top: pointer.source.top,
        };
        unsafe {
            context.UpdateSubresource(
                &self.constants,
                0,
                None,
                (&raw const constants).cast(),
                0,
                0,
            );
        }
        let pixel_shader = match pointer.composition {
            NativePointerComposition::Monochrome => &self.monochrome_shader,
            NativePointerComposition::MaskedColor => &self.masked_color_shader,
            NativePointerComposition::AlphaColor => {
                return Err("alpha cursor entered the XOR compositor".to_owned());
            }
        };
        let viewport = D3D11_VIEWPORT {
            TopLeftX: pointer.destination.left as f32,
            TopLeftY: pointer.destination.top as f32,
            Width: (pointer.destination.right - pointer.destination.left) as f32,
            Height: (pointer.destination.bottom - pointer.destination.top) as f32,
            MinDepth: 0.0,
            MaxDepth: 1.0,
        };
        unsafe {
            context.IASetInputLayout(
                None::<&windows_api::Win32::Graphics::Direct3D11::ID3D11InputLayout>,
            );
            context.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context.VSSetShader(&self.vertex_shader, None);
            context.PSSetShader(pixel_shader, None);
            context.PSSetShaderResources(
                0,
                Some(&[
                    Some(surfaces.source_view.clone()),
                    Some(pointer.shader_view.clone()),
                ]),
            );
            context.PSSetConstantBuffers(0, Some(&[Some(self.constants.clone())]));
            context.OMSetRenderTargets(
                Some(&[Some(surfaces.output_view.clone())]),
                None::<&windows_api::Win32::Graphics::Direct3D11::ID3D11DepthStencilView>,
            );
            context.RSSetViewports(Some(&[viewport]));
            context.Draw(3, 0);
            context.PSSetShaderResources(0, Some(&[None, None]));
            context.PSSetConstantBuffers(0, Some(&[None]));
            context.OMSetRenderTargets(
                None,
                None::<&windows_api::Win32::Graphics::Direct3D11::ID3D11DepthStencilView>,
            );
            context.VSSetShader(
                None::<&windows_api::Win32::Graphics::Direct3D11::ID3D11VertexShader>,
                None,
            );
            context.PSSetShader(
                None::<&windows_api::Win32::Graphics::Direct3D11::ID3D11PixelShader>,
                None,
            );
        }
        Ok(surfaces.output.clone())
    }

    fn ensure_surfaces(
        &mut self,
        device: &ID3D11Device,
        desktop: &D3D11_TEXTURE2D_DESC,
    ) -> Result<(), String> {
        if self.surfaces.as_ref().is_some_and(|surfaces| {
            surfaces.width == desktop.Width
                && surfaces.height == desktop.Height
                && surfaces.format == desktop.Format
        }) {
            return Ok(());
        }
        let shader_resource = u32::try_from(D3D11_BIND_SHADER_RESOURCE.0)
            .map_err(|_| "Windows shader-resource bind flag is invalid".to_owned())?;
        let render_target = u32::try_from(D3D11_BIND_RENDER_TARGET.0)
            .map_err(|_| "Windows render-target bind flag is invalid".to_owned())?;
        let base = D3D11_TEXTURE2D_DESC {
            Width: desktop.Width,
            Height: desktop.Height,
            MipLevels: 1,
            ArraySize: 1,
            Format: desktop.Format,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: shader_resource,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let source = create_texture(device, &base, "cursor source")?;
        let output_description = D3D11_TEXTURE2D_DESC {
            BindFlags: shader_resource | render_target,
            ..base
        };
        let output = create_texture(device, &output_description, "cursor output")?;
        let source_view = create_shader_resource_view(device, &source, "cursor source")?;
        let output_view = create_render_target_view(device, &output)?;
        self.surfaces = Some(NativePointerCompositionSurfaces {
            width: desktop.Width,
            height: desktop.Height,
            format: desktop.Format,
            source,
            source_view,
            output,
            output_view,
        });
        Ok(())
    }
}

fn compile_pointer_shader(source: &str, target: PCSTR) -> Result<Vec<u8>, String> {
    let mut bytecode = None;
    let mut errors = None;
    unsafe {
        D3DCompile(
            source.as_ptr().cast(),
            source.len(),
            PCSTR::null(),
            None,
            None::<&ID3DInclude>,
            POINTER_SHADER_ENTRY,
            target,
            D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            &mut bytecode,
            Some(&mut errors),
        )
    }
    .map_err(|error| {
        let details = errors
            .as_ref()
            .and_then(|blob: &ID3DBlob| shader_blob_bytes(blob).ok())
            .and_then(|bytes| {
                std::str::from_utf8(&bytes)
                    .ok()
                    .map(str::trim)
                    .map(str::to_owned)
            })
            .filter(|details| !details.is_empty());
        details.map_or_else(
            || format!("Windows cursor shader compilation failed: {error}"),
            |details| format!("Windows cursor shader compilation failed: {details}"),
        )
    })?;
    let bytecode =
        bytecode.ok_or_else(|| "Windows cursor shader bytecode is unavailable".to_owned())?;
    shader_blob_bytes(&bytecode)
}

fn shader_blob_bytes(blob: &ID3DBlob) -> Result<Vec<u8>, String> {
    let pointer = unsafe { blob.GetBufferPointer() };
    let length = unsafe { blob.GetBufferSize() };
    if pointer.is_null() || length == 0 {
        return Err("Windows shader compiler returned an empty blob".to_owned());
    }
    Ok(unsafe { std::slice::from_raw_parts(pointer.cast::<u8>(), length) }.to_vec())
}

fn create_texture(
    device: &ID3D11Device,
    description: &D3D11_TEXTURE2D_DESC,
    name: &str,
) -> Result<ID3D11Texture2D, String> {
    let mut texture = None;
    unsafe { device.CreateTexture2D(description, None, Some(&mut texture)) }
        .map_err(|error| format!("Windows {name} texture creation failed: {error}"))?;
    texture.ok_or_else(|| format!("Windows {name} texture is unavailable"))
}

fn create_shader_resource_view(
    device: &ID3D11Device,
    texture: &ID3D11Texture2D,
    name: &str,
) -> Result<ID3D11ShaderResourceView, String> {
    let mut view = None;
    unsafe { device.CreateShaderResourceView(texture, None, Some(&mut view)) }
        .map_err(|error| format!("Windows {name} shader view creation failed: {error}"))?;
    view.ok_or_else(|| format!("Windows {name} shader view is unavailable"))
}

fn create_render_target_view(
    device: &ID3D11Device,
    texture: &ID3D11Texture2D,
) -> Result<ID3D11RenderTargetView, String> {
    let mut view = None;
    unsafe { device.CreateRenderTargetView(texture, None, Some(&mut view)) }
        .map_err(|error| format!("Windows cursor render-target view creation failed: {error}"))?;
    view.ok_or_else(|| "Windows cursor render-target view is unavailable".to_owned())
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
        match &self.release {
            NativeFrameRelease::Duplication(duplication) => {
                let _ = unsafe { duplication.ReleaseFrame() };
            }
            NativeFrameRelease::Shared(keyed_mutex) => {
                let _ = unsafe { keyed_mutex.ReleaseSync(0) };
            }
        }
    }
}

fn select_output(
    factory: &IDXGIFactory1,
    adapter_name: &str,
    output_name: &str,
) -> Result<(IDXGIAdapter1, IDXGIOutput), String> {
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
        if !adapter_name.is_empty() && wide_text(&description.Description)? != adapter_name {
            continue;
        }
        if let Some(output) = select_adapter_output(&adapter, output_name)? {
            return Ok((adapter, output));
        }
    }
    Err(format!(
        "Windows DXGI found no attached output matching adapter {adapter_name:?} and display {output_name:?}"
    ))
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

fn select_adapter_output(
    adapter: &IDXGIAdapter1,
    output_name: &str,
) -> Result<Option<IDXGIOutput>, String> {
    let mut output_index = 0_u32;
    loop {
        let output = match unsafe { adapter.EnumOutputs(output_index) } {
            Ok(output) => output,
            Err(error) if error.code() == DXGI_ERROR_NOT_FOUND => return Ok(None),
            Err(error) => return Err(format!("Windows DXGI output enumeration failed: {error}")),
        };
        output_index = output_index.saturating_add(1);
        let description = unsafe { output.GetDesc() }
            .map_err(|error| format!("Windows DXGI output description failed: {error}"))?;
        if !description.AttachedToDesktop.as_bool() {
            continue;
        }
        if output_name.is_empty() || wide_text(&description.DeviceName)? == output_name {
            return Ok(Some(output));
        }
    }
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

fn wide_text(value: &[u16]) -> Result<String, String> {
    let length = value
        .iter()
        .position(|unit| *unit == 0)
        .unwrap_or(value.len());
    String::from_utf16(&value[..length])
        .map_err(|_| "Windows DXGI identity is not valid UTF-16".to_owned())
}
