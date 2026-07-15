# MIT migration contract

## Goal

Lumen will replace the inherited GPL implementation with a Lumen-owned Rust
host and Lumen Streaming Protocol v2. After the exit gate passes, the current
tree may be released under MIT. Published MIT versions remain available under
MIT; the copyright owner may distribute later versions under a private or
commercial license.

Changing `LICENSE` is the last migration action, not the first.

## Provenance classes

Every retained implementation file must fit one class:

1. **Lumen original**: authored from Lumen requirements or source-neutral
   standards without copying or translating inherited implementation code.
2. **Permissive dependency**: dependency whose license permits inclusion in an
   MIT product and whose notices are preserved.
3. **Weak-copyleft runtime dependency**: an independently replaceable shared
   library whose license, corresponding source, build recipe, and notices are
   shipped without applying that license to Lumen itself.
4. **GPL legacy**: inherited, copied, translated, or structurally derived code
   that must be removed or replaced before the MIT exit gate.

Git authorship alone does not prove Lumen-original status. A Rust translation of
GPL C++ remains legacy for this migration.

## Mandatory removals

The MIT release graph cannot compile, link, generate from, or package:

- inherited common C++ streaming, audio, video, input, display, or utility
  sources under `src`;
- Sunshine or Moonlight runtime sources, headers, fixtures, or generated data;
- `third-party/moonlight-common-c` or its ENet transport;
- RTSP, SDP, RTP, ENet, GameStream, or NVIDIA media-header implementations;
- ProRes implementations, probes, proxies, fixtures, and fallback paths;
- tests that use inherited source files as the protocol oracle.

The Windows media boundary uses operating-system DXGI, D3D, Media Foundation,
WASAPI, and Win32 APIs directly from Rust. The release graph does not compile,
link, or package FFmpeg, x264, x265, SVT-AV1, or a vendor codec SDK. Opus is a
separately attributed BSD-licensed native audio dependency. The Windows UI uses
Slint under its Royalty-free Desktop, Mobile, and Web Applications License 2.0
and exposes the required `AboutSlint` widget from a top-level About screen.

Reference repositories may not be used as implementation input for the new
transport. Standards, Lumen-owned specifications, black-box captures from
authorized systems, and independently authored conformance fixtures are valid
inputs.

## Rust classification work

The following areas require provenance review before retention:

- control-frame parsing and output;
- input wire parsing;
- launch parsing and compatibility aliases;
- RTP, FEC, audio, and video packetization;
- RTSP, SDP, ENet, and legacy discovery behavior;
- codec and fallback policy copied or translated from inherited paths.

Owner, device, authentication, settings, application catalog, process
supervision, file storage, and workspace state are candidates for retention only
after their implementations and tests pass the same review.

## Exit gate

The root license may change to MIT only when all conditions pass:

- Windows and macOS release artifacts are built without GPL legacy paths;
- Lumen Streaming Protocol v2 is the only network session protocol;
- dependency licenses are MIT-compatible and notices are complete;
- the retained Rust and native platform boundary has a recorded provenance
  classification;
- Shadow passes v2 cross-platform conformance without upstream source fixtures;
- repository scans find no compiled or generated dependency on forbidden
  compatibility code;
- CI, packaging, signing, installation, and runtime smoke tests pass.

## Future closed-source option

MIT grants for published versions are permanent. A later private version may
reuse the MIT code subject to its notice requirements. To preserve clean
relicensing authority, implementation contributions to the new core must not be
accepted from external contributors until a contributor agreement or equivalent
copyright policy is in place.
