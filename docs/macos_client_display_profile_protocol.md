# macOS Client Display Profile Protocol

## Goal

Allow the client to describe its display profile to the Apollo host so the macOS virtual display can be created to match the client rather than the host's physical monitor.

This is needed because the legacy GameStream fields only tell the host:

- whether HDR is enabled
- which SDR YUV colorspace to use for encode

They do not describe the client's actual panel gamut or HDR transfer mode.

## Apollo Extension Keys

Apollo now accepts these optional fields in both launch HTTP and RTSP ANNOUNCE:

- `clientDisplayGamut`
- `clientDisplayTransfer`

And in RTSP ANNOUNCE as Apollo-specific attributes:

- `x-apollo-video[0].clientDisplayGamut`
- `x-apollo-video[0].clientDisplayTransfer`

## Accepted Values

### Gamut

- `srgb`
- `display-p3`
- `rec2020`

Aliases currently accepted by the host parser:

- `display_p3`
- `p3`
- `bt2020`
- `2020`
- `rec709`
- `709`

### Transfer

- `sdr`
- `pq`
- `hlg`

Aliases currently accepted by the host parser:

- `hdr-pq`
- `st2084`
- `smpte2084`
- `hdr-hlg`
- `gamma`

If the transfer value is omitted:

- HDR sessions default to `pq`
- SDR sessions default to `sdr`

## Current Host Wiring

Apollo host currently consumes the fields here:

- [`src/nvhttp.cpp`](../src/nvhttp.cpp)
  launch HTTP parser
- [`src/rtsp.cpp`](../src/rtsp.cpp)
  RTSP ANNOUNCE parser
- [`src/process.cpp`](../src/process.cpp)
  session state propagation
- [`src/platform/macos/virtual_display.mm`](../src/platform/macos/virtual_display.mm)
  virtual display primaries selection
- [`src/platform/macos/display.mm`](../src/platform/macos/display.mm)
  generic virtual HDR metadata selection

## Current Client Gap

The current `shadow-client` code sends:

- `hdrMode`
- `x-nv-video[0].dynamicRangeMode`
- `x-nv-video[0].encoderCscMode`

But it does not yet send the client's panel gamut or transfer profile.

Relevant client files to extend:

- `ShadowClientGameStreamControlClient.swift`
- `ShadowClientRTSPAnnouncePayloadBuilder.swift`

## Recommended Client Behavior

### Launch HTTP

Add these query parameters:

- `clientDisplayGamut`
- `clientDisplayTransfer`

### RTSP ANNOUNCE

Add these attributes:

- `x-apollo-video[0].clientDisplayGamut`
- `x-apollo-video[0].clientDisplayTransfer`

## Recommended Value Source

The client should derive these from the actual target display and render path:

- gamut:
  - `srgb`
  - `display-p3`
  - `rec2020`
- transfer:
  - `sdr`
  - `pq`
  - `hlg`

This should be based on the client display the user is actually rendering to, not a fixed app default.

## Notes

- `Display P3` panel gamut and HDR `PQ` transfer are separate concepts.
- A correct profile may be `display-p3 + pq`, not just `display-p3`.
- On macOS host, this is a prerequisite for building a better virtual display profile.
- This does not by itself solve physical monitor isolation. That still requires a separate `soft-disconnect + primary reassignment` path.
