#include <d3d12.h>
#include <d3d12video.h>
#include <dxgi1_6.h>
#include <windows.h>
#include <wrl/client.h>

#include <array>
#include <cstdio>

namespace {
using Microsoft::WRL::ComPtr;

struct FormatProbe {
  DXGI_FORMAT format;
  const char *name;
};

bool probe_profile(
  ID3D12VideoDevice3 *video_device,
  D3D12_VIDEO_ENCODER_PROFILE_HEVC profile,
  const char *profile_name
) {
  D3D12_VIDEO_ENCODER_PROFILE_DESC profile_desc {};
  profile_desc.DataSize = sizeof(profile);
  profile_desc.pHEVCProfile = &profile;

  const std::array<FormatProbe, 6> formats {{
    {DXGI_FORMAT_AYUV, "AYUV"},
    {DXGI_FORMAT_Y410, "Y410"},
    {DXGI_FORMAT_Y416, "Y416"},
    {DXGI_FORMAT_NV12, "NV12"},
    {DXGI_FORMAT_P010, "P010"},
    {DXGI_FORMAT_R8G8B8A8_UNORM, "RGBA8"},
  }};

  bool any_supported = false;
  for (const auto &format : formats) {
    D3D12_FEATURE_DATA_VIDEO_ENCODER_INPUT_FORMAT support {};
    support.Codec = D3D12_VIDEO_ENCODER_CODEC_HEVC;
    support.Profile = profile_desc;
    support.Format = format.format;
    const HRESULT result = video_device->CheckFeatureSupport(
      D3D12_FEATURE_VIDEO_ENCODER_INPUT_FORMAT,
      &support,
      sizeof(support)
    );
    std::printf(
      "profile=%s format=%s query=0x%08lx supported=%s\n",
      profile_name,
      format.name,
      static_cast<unsigned long>(result),
      SUCCEEDED(result) && support.IsSupported ? "yes" : "no"
    );
    any_supported = any_supported || (SUCCEEDED(result) && support.IsSupported);
  }
  return any_supported;
}

void probe_conversion(
  ID3D12VideoDevice3 *video_device,
  DXGI_FORMAT input_format,
  DXGI_COLOR_SPACE_TYPE input_color_space,
  const char *input_name,
  DXGI_FORMAT output_format,
  DXGI_COLOR_SPACE_TYPE output_color_space,
  const char *output_name
) {
  D3D12_FEATURE_DATA_VIDEO_PROCESS_SUPPORT support {};
  support.InputSample.Width = 3840;
  support.InputSample.Height = 2160;
  support.InputSample.Format.Format = input_format;
  support.InputSample.Format.ColorSpace = input_color_space;
  support.InputFieldType = D3D12_VIDEO_FIELD_TYPE_NONE;
  support.InputStereoFormat = D3D12_VIDEO_FRAME_STEREO_FORMAT_NONE;
  support.InputFrameRate = {120, 1};
  support.OutputFormat.Format = output_format;
  support.OutputFormat.ColorSpace = output_color_space;
  support.OutputStereoFormat = D3D12_VIDEO_FRAME_STEREO_FORMAT_NONE;
  support.OutputFrameRate = {120, 1};
  const HRESULT result = video_device->CheckFeatureSupport(
    D3D12_FEATURE_VIDEO_PROCESS_SUPPORT,
    &support,
    sizeof(support)
  );
  std::printf(
    "conversion=%s-to-%s query=0x%08lx supported=%s\n",
    input_name,
    output_name,
    static_cast<unsigned long>(result),
    SUCCEEDED(result) &&
        (support.SupportFlags & D3D12_VIDEO_PROCESS_SUPPORT_FLAG_SUPPORTED) != 0
      ? "yes"
      : "no"
  );
}
}

int main() {
  ComPtr<IDXGIFactory7> factory;
  HRESULT result = CreateDXGIFactory2(0, IID_PPV_ARGS(factory.GetAddressOf()));
  if (FAILED(result)) {
    std::fprintf(stderr, "CreateDXGIFactory2 failed: 0x%08lx\n", static_cast<unsigned long>(result));
    return 10;
  }

  for (UINT index = 0;; ++index) {
    ComPtr<IDXGIAdapter4> adapter;
    result = factory->EnumAdapterByGpuPreference(
      index,
      DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
      IID_PPV_ARGS(adapter.GetAddressOf())
    );
    if (result == DXGI_ERROR_NOT_FOUND) {
      break;
    }
    if (FAILED(result)) {
      return 11;
    }

    DXGI_ADAPTER_DESC3 description {};
    if (FAILED(adapter->GetDesc3(&description)) ||
        (description.Flags & DXGI_ADAPTER_FLAG3_SOFTWARE) != 0) {
      continue;
    }

    ComPtr<ID3D12Device> device;
    result = D3D12CreateDevice(
      adapter.Get(),
      D3D_FEATURE_LEVEL_11_0,
      IID_PPV_ARGS(device.GetAddressOf())
    );
    if (FAILED(result)) {
      continue;
    }

    ComPtr<ID3D12VideoDevice3> video_device;
    result = device.As(&video_device);
    if (FAILED(result)) {
      continue;
    }

    std::wprintf(L"adapter=%ls\n", description.Description);
    const bool main_444 = probe_profile(
      video_device.Get(),
      D3D12_VIDEO_ENCODER_PROFILE_HEVC_MAIN_444,
      "main444"
    );
    const bool main10_444 = probe_profile(
      video_device.Get(),
      D3D12_VIDEO_ENCODER_PROFILE_HEVC_MAIN10_444,
      "main10-444"
    );
    probe_conversion(
      video_device.Get(),
      DXGI_FORMAT_B8G8R8A8_UNORM,
      DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
      "BGRA8",
      DXGI_FORMAT_AYUV,
      DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709,
      "AYUV"
    );
    probe_conversion(
      video_device.Get(),
      DXGI_FORMAT_R16G16B16A16_FLOAT,
      DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020,
      "RGBA16F-PQ",
      DXGI_FORMAT_Y410,
      DXGI_COLOR_SPACE_YCBCR_STUDIO_G2084_LEFT_P2020,
      "Y410-PQ"
    );
    return main_444 || main10_444 ? 0 : 12;
  }

  std::fprintf(stderr, "No hardware D3D12 video device found\n");
  return 13;
}
