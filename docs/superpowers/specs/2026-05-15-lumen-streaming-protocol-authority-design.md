# Lumen Streaming Protocol Authority Design

## Goal

Make Lumen the source of truth for Mac and Windows streaming protocol semantics, with platform adapters feeding normalized protocol state and clients following only that protocol.

## Architecture

The protocol core owns capability names, launch parameters, control message ids, payload versions, and presentation contract names. Platform adapters translate MacDisplayKit or Windows capture metadata into source-neutral protocol state. Clients mirror the Lumen protocol and never depend on MDK, DXGI, WGC, VideoToolbox, or NVENC semantics.

## Components

- `docs/protocol/lumen-streaming-protocol.md`: public contract for capabilities, control messages, payload layouts, presentation contracts, and fallback rules.
- `src/lumen_protocol.h`: C++ source of truth for protocol constants used by RTSP, launch HTTP, and control-channel code.
- `src/rtsp.cpp`: consumes RTSP capability keys from the protocol core.
- `src/shadow_http.cpp`: consumes launch capability parameter names from the protocol core.
- `src/stream.cpp`: consumes Lumen control message ids and payload version/flag constants from the protocol core.
- Swift bridge files remain adapters in this slice and will be renamed or split in later slices.

## Data Flow

Client sink capabilities enter through launch HTTP and RTSP ANNOUNCE. Lumen normalizes those capabilities into `sink_request_t`. Source adapters provide HDR frame state and encoded tile metadata. Lumen negotiates a presentation contract, then emits source-neutral control messages to the client.

## Compatibility

`supportsEncodedTileStream` remains optional and defaults to false. Existing clients that omit it stay on the single-frame path.

## Validation

The first implementation slice must be behavior-preserving: unit tests and the macOS Tuist bootstrap tests should continue to pass. Later slices should add protocol parser/builder tests around `0x3003`, `0x3004`, and negotiation fallback.

