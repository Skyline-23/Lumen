# Lumen Streaming Protocol v4

## Authority

Protocol v4 defines the independent Lumen Object Transport (LOT) over
standards-compliant QUIC and is the only native Lumen/Shadow streaming
contract. It deliberately
has no compatibility path for GameStream, RTSP, SDP, RTP, ENet, direct media
UDP, application-level media AEAD, legacy media headers, or protocol v3.

The protobuf authority is `lumen-streaming-v4.proto`. The fixed compact
QUIC-DATAGRAM header authority is
`lumen-native-transport-conformance.json`. Rust owns negotiation, stream-role
assignment, object delivery, FEC, feedback adaptation, and session lifecycle.

## Connection

- QUIC v1 over TLS 1.3.
- ALPN is exactly `lumen-stream/4`.
- `ClientSessionHello.minimum_protocol_version`,
  `maximum_protocol_version`, and `HostSessionPlan.protocol_version` are all
  numeric protocol `4`.
- Authentication uses the enrolled device access token in the hello.
- One QUIC connection carries control, input, telemetry, reliable video
  bootstrap, video deltas, audio, and input motion.
- No direct media UDP socket, path challenge, path id, TLS exporter media key,
  application AES-GCM tag, or media endpoint negotiation exists.

Client-opened bidirectional streams have fixed raw QUIC ids:

| Raw id | Role |
| ---: | --- |
| 0 | session control |
| 4 | reliable input |
| 8 | telemetry |

The host keeps raw unidirectional stream `3` open for codec configuration.
Each video bootstrap generation uses one fresh host unidirectional stream,
beginning with raw id `7` and continuing `11`, `15`, and so on. A bootstrap
stream carries exactly one length-delimited `VideoBootstrap` record and then
FIN. Clients grant at least eight host unidirectional streams.

Control, reliable input, telemetry, and codec configuration bodies are limited
to 32 KiB. A VideoBootstrap body is limited to 16 MiB.

## Negotiation and lifecycle

The client advertises exact hardware video capability rows. A row is the exact
combination of codec, profile, chroma subsampling, bit depth, dynamic range,
color range, and decoder-proven mode throughput. Independent maximum width,
height, and refresh values must not be interpreted as an unproven cross
product.

The host either returns one exact `HostSessionPlan` or a typed
`ProtocolError`. Unsupported versions are reported only when numeric protocol
4 is outside the offered range. Malformed capability rows and unsupported exact
selections keep their distinct typed failures.

`HostSessionPlan.maximum_object_delay_us` is field 45. Field 44 remains the
selected video capability.

Codec configuration is reliable and must be acknowledged before the first
bootstrap. A session's first video generation follows this gate:

1. host sends `CodecConfiguration` on raw stream 3;
2. client returns `CodecConfigurationAck` on control;
3. host opens raw stream 7 and sends one `VideoBootstrap`;
4. client creates the required hardware decoder and decodes that access unit;
5. client returns `VideoBootstrapResult` tag 16 with result `decoded`;
6. only then may the host send dependent video deltas for that generation.

`decoded` means a successful hardware decoder callback, not merely successful
configuration parsing or decoder-session creation. `decoderRejected`,
`stale`, malformed identity, and timeout are typed failures. A rejected or
unacknowledged bootstrap never opens delta delivery.

A `VideoKeyframeRequest` carries the currently acknowledged generation id.
Stale-generation repair requests are ignored. Initial, configuration-change,
explicit repair, and encoder-originated periodic keyframes create a new
generation. A decoded bootstrap issues a platform resume only when its encoded
frame carries that platform's pause ownership. A natural macOS periodic
keyframe therefore advances delivery without a resume; the Windows adapter,
which pauses after every keyframe, resumes its owned periodic boundary. Initial
and repair bootstraps still resume only the exact pending encoder admission
boundary.

While a periodic bootstrap is pending, the host retains at most one dependent
frame for one negotiated object deadline. If the result is slower, it drains
and drops later dependent frames without requesting another generation. After
the periodic generation is acknowledged, it requests exactly one owned repair
only when a dependent frame was dropped; otherwise the held frame resumes
delivery directly.

## QUIC DATAGRAM object plane

Video deltas, audio objects, and coalescible input motion use QUIC DATAGRAM.
The QUIC connection authenticates and binds every datagram to the session.
There is no extra media encryption layer.

The normal header is 28 bytes, all multi-byte values big-endian:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | flow kind: video delta 1, audio 2, input motion 3 |
| 1 | 1 | flags: parity 0x10, FEC block 0x20 |
| 2 | 2 | header bytes: 28 or 36 |
| 4 | 4 | generation id; nonzero for video, zero otherwise |
| 8 | 4 | datagram sequence |
| 12 | 4 | object id |
| 16 | 4 | complete unsharded object bytes |
| 20 | 4 | capture timestamp microseconds modulo 2^32 |
| 24 | 1 | shard index |
| 25 | 1 | data shards, 1...255 |
| 26 | 1 | parity shards |
| 27 | 1 | reserved, zero |

The 36-byte FEC-block form appends:

| Offset | Size | Field |
| ---: | ---: | --- |
| 28 | 1 | block index |
| 29 | 1 | block count, at least 2 |
| 30 | 2 | reserved, zero |
| 32 | 4 | object payload offset |

A block contains at most 256 total shards. Data and parity counts are block
local. Object kind, generation, object id, object bytes, timestamp, and block
count are object global. Datagram sequence is monotonic for a flow.

Video keyframes never use DATAGRAM. Audio is one raw 5 ms Opus multistream
packet per object. Input motion carries one `ClientMotionEnvelope`, latest
unsent sample wins, and it has no FEC.

## FEC and feedback

FEC is systematic Reed-Solomon over GF(2^8), primitive polynomial `0x11d`,
generator `0x02`, and the systematic Vandermonde matrix. Data shards are
zero-padded before parity. Reconstruction is block-local and the final object is
trimmed to `objectBytes`.

Telemetry uses client bidi raw stream 8. `ClientTelemetryEnvelope.sequence`
starts at 1 and is contiguous. `MediaFeedback` is tag 10 and reports the exact
datagram sequence window, receive/recovery/loss/reorder counts, jitter, decoder
queue depth, presentation drops, and window duration.

Feedback may identify the negotiated video or audio stream. Video feedback
drives the adaptive delivery state. Structurally valid audio feedback is
consumed without changing video loss EWMA, FEC, bitrate, or admission state.
Every report still requires an active session, an exact 250 ms window, and an
ordered inclusive sequence range; datagram sequence windows are independent
per logical media stream while the telemetry-envelope sequence remains global.
Unknown stream IDs are rejected.

The host adapts parity in five-point steps inside 5...50 using loss EWMA. It
must also reduce admission or bitrate under sustained high loss without
changing the negotiated codec, resolution, refresh, dynamic range, or hardware
decode policy. At most one unsent video delta may be retained.

## Security and compatibility

TLS 1.3 protects all streams and QUIC DATAGRAM. The enrolled host identity is
pinned by Shadow. Removed v3 exporter/AES-GCM protection must not be
reintroduced as a second cryptographic state machine.

Forbidden production contracts include protocol v3, direct media UDP,
MediaPath challenge/validation, RTSP, RTP, SDP, ENet, Annex-B compatibility,
inline codec configuration, software decode fallback, and silent format
downgrade.

LOT is not MoQ, a reduced MoQ profile, WebRTC, or SRT. Those systems may inform
design review but do not define this wire contract. Multipath scheduling is
also outside the v4 core. A future v4.x multi-link design may register multiple
QUIC connections under one session and use session-global generation/object
ids with receiver deduplication; current implementations must not expose a
per-path id or assume an unavailable Apple per-path scheduler API.
