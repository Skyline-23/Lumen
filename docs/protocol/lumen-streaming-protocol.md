# Lumen Streaming Protocol

## Purpose

Lumen Streaming Protocol is the platform-neutral contract between a Lumen host and a Lumen-capable client. Platform capture backends provide source metadata through adapters; clients consume only the normalized Lumen wire contract.

## Ownership

- Lumen owns RTSP capability keys, launch capability parameters, control message ids, payload versions, fallback policy, and presentation contract names.
- Platform adapters translate source-specific signals into Lumen protocol state.
- Clients mirror this protocol and must not depend on MacDisplayKit, DXGI, WGC, VideoToolbox, NVENC, or other source-specific semantics.

## Source Adapters

Every platform adapter emits a normalized presentation signal:

- requested dynamic-range transport from the client or launch path
- negotiated dynamic-range transport after platform and codec constraints
- sink capability
- source encoded-tile layout

Presentation contracts are resolved from this source-neutral signal. MacDisplayKit,
DXGI, WGC, VideoToolbox, NVENC, and future capture backends must stay behind this
adapter boundary.

### Mac

The Mac adapter maps MacDisplayKit capture state into Lumen protocol state:

- `MDKEncodedFrameTileMetadata` to `LumenEncodedTileFrameState`
- HDR static metadata and overlay regions to `LumenHDRFrameState`
- VideoToolbox and Metal timing to diagnostics only

The pure adapter boundary is `src/platform/macos/lumen_protocol_adapter.h`; it
maps CoreDisplay/ScreenCaptureKit/VideoToolbox/HDR facts into the same
source-neutral `presentation_signal` used by other platforms.

### Windows

The Windows adapter maps Windows capture state into the same Lumen protocol state:

- DXGI or WGC dirty regions to protocol tile or region state when available
- NVENC surface/frame metadata to encoded frame diagnostics
- Windows HDR display state to `LumenHDRFrameState`

Windows adapters must not create client-visible message ids or capability keys outside the Lumen protocol namespace.
The pure adapter boundary is `src/platform/windows/lumen_protocol_adapter.h`; it
maps DXGI/WGC/NVENC/HDR facts into a source-neutral `presentation_signal` before
contract resolution.
Both platform adapters share `src/lumen_protocol_platform_adapter.h` for fallback
and presentation-contract negotiation.
The existing `video::make_lumen_protocol_adapter` runtime paths build the same
platform adapter input/output before exposing the legacy `video` adapter shape.

## Sink Capability

RTSP ANNOUNCE uses these Lumen capability keys:

- `x-shadow-sink.scalePercent`
- `x-shadow-sink.hidpi`
- `x-shadow-sink.modeIsLogical`
- `x-shadow-sink.gamut`
- `x-shadow-sink.transfer`
- `x-shadow-sink.currentEDRHeadroom`
- `x-shadow-sink.potentialEDRHeadroom`
- `x-shadow-sink.currentPeakLuminanceNits`
- `x-shadow-sink.potentialPeakLuminanceNits`
- `x-shadow-sink.requestedDynamicRangeTransport`
- `x-shadow-sink.supportsFrameGatedHDR`
- `x-shadow-sink.supportsHDRTileOverlay`
- `x-shadow-sink.supportsPerFrameHDRMetadata`
- `x-shadow-sink.supportsEncodedTileStream`

Launch HTTP uses the equivalent parameter names:

- `clientSinkScalePercent`
- `clientSinkHiDPI`
- `clientSinkModeIsLogical`
- `clientSinkGamut`
- `clientSinkTransfer`
- `clientSinkCurrentEDRHeadroom`
- `clientSinkPotentialEDRHeadroom`
- `clientSinkCurrentPeakLuminanceNits`
- `clientSinkPotentialPeakLuminanceNits`
- `requestedDynamicRangeTransport`
- `clientSinkSupportsFrameGatedHDR`
- `clientSinkSupportsHDRTileOverlay`
- `clientSinkSupportsPerFrameHDRMetadata`
- `clientSinkSupportsEncodedTileStream`

`supportsEncodedTileStream` is optional for compatibility and defaults to false.

## Control Messages

Lumen reserves these control message ids:

- `0x3000` execute server command
- `0x3001` set clipboard
- `0x3002` file transfer nonce request
- `0x3003` HDR frame state v2
- `0x3004` encoded tile frame state v1

### HDR Frame State v2

Payload body after the control header:

- `version UInt8`, value `1`
- `frameDynamicRange UInt8`
- `flags UInt8`
- `reserved UInt8`
- `effectiveFromFrameNumber UInt32 LE`
- `overlayRegionCount UInt16 LE`
- `reserved UInt16`
- static HDR metadata payload
- zero or more overlay region payloads

Flags:

- `1 << 0`: static metadata present
- `1 << 1`: overlay regions present

### Encoded Tile Frame State v1

Payload body after the control header:

- `version UInt8`, value `1`
- `flags UInt8`
- `reserved UInt16`
- `effectiveFromFrameNumber UInt32 LE`
- `frameGroupId UInt64 LE`
- `tileIndex UInt32 LE`
- `tileCount UInt32 LE`, minimum effective value `1`
- `encodedLaneIndex UInt32 LE`
- `encodedLaneCount UInt32 LE`, minimum effective value `1`
- `tileOriginX UInt32 LE`
- `tileOriginY UInt32 LE`
- `tileWidth UInt32 LE`
- `tileHeight UInt32 LE`

Flags:

- `1 << 0`: tile region present

## Presentation Contracts

`single-frame` means every decoded frame is independently presentable.

`primed-per-tile-update` means the client maintains a persistent presentation surface. The host may send independently encoded tile updates. The client must wait until every encoded lane is primed once, then present the persistent surface after each valid tile update.

The host negotiates `primed-per-tile-update` only when all of these are true:

- the transport is `sdr-base-hdr-overlay`
- the client supports HDR tile overlay
- the client supports per-frame HDR metadata
- the client supports encoded tile stream
- the source adapter provides a multi-tile encoded stream

## Fallback Policy

- If the client does not support encoded tile stream, Lumen must use `single-frame`.
- If HDR overlay requirements are missing, Lumen must fall back through frame-gated HDR or SDR according to sink capability.
- Source adapters provide facts; protocol negotiation owns fallback decisions.
- Clients must reject invalid payload versions and invalid tile regions, then fall back to the last valid presentable state.

## Quality Gate

Run `python3 tools/protocol/generate_lumen_protocol.py` after changing `docs/protocol/lumen-protocol-conformance.json`.

Run `npm run quality` before committing protocol or adapter changes.
Use `npm run quality-fast` for the non-build subset while iterating.

The gate enforces these protocol-maintenance rules:

- generated protocol authority files must be current with `docs/protocol/lumen-protocol-conformance.json`
- control message ids `0x3003` and `0x3004` stay in Lumen protocol authority files instead of being duplicated in adapters
- new legacy upstream identity references must stay in explicit upstream attribution boundaries
- new Mac protocol coordination must not use `NSLock`
- high-refresh behavior must not be gated on `targetFrameRate >= 100` or an equivalent 100 fps threshold
- protocol authority functions must stay below the configured function-size budget and be split when they grow too large
