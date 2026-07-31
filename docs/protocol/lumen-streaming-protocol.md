# Lumen Streaming Protocol v4

## Authority

Protocol v4 defines the independent Lumen Object Transport (LOT) over
standards-compliant QUIC and is the only native Lumen streaming contract for
hosts and third-party clients. It deliberately
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
selected video capability. The client advertises `media_capabilities` on
`ClientSessionHello` field 38 and the host echoes the required subset on
`HostSessionPlan` field 46. Native v4 requires same-generation datagram
keyframes (bit 0), fixed-cadence coalesced feedback (bit 1), continuous scroll
metadata (bit 2), and paired video/audio feedback windows with explicit IDs
(bit 3). Negotiation fails before capture if any required bit is absent, so a
client using the older single-report contract cannot enter a paired-window
session. Packet-arrival feedback (bit 4) is optional. When negotiated, the
client may attach observation-only receive timing to `MediaFeedback`; it does
not participate in bitrate, FEC, pacing, resolution, or lifecycle decisions.

`MediaFeedback.packet_arrival_reference_time_us` is field 18 and
`packet_arrival_runs` is field 19. Each run is `first_sequence` as a big-endian
`uint32`, followed by a big-endian 64-bit received bitmap (bit zero names the
first sequence), then one unsigned protobuf varint arrival delta in ascending
sequence order for every set bit. Deltas are microseconds relative to field 18.
Payloads are limited to 16 KiB and 4,096 covered sequences. A partial,
malformed, unsupported, oversized, or untracked report closes the telemetry
path; peers that do not negotiate bit 4 omit both fields.

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
and explicit-repair keyframes create a new reliable bootstrap generation. A
decoded bootstrap issues a platform resume only when its encoded frame carries
that platform's pause ownership.

Encoder-originated periodic keyframes retain the acknowledged generation and
travel on the DATAGRAM plane with flag `0x01`. They refresh decoder reference
state without recreating the decoder. An incomplete keyframe object follows the
same deduplicated explicit-repair path as an incomplete delta.

## QUIC DATAGRAM object plane

Video deltas, audio objects, and coalescible input motion use QUIC DATAGRAM.
The QUIC connection authenticates and binds every datagram to the session.
There is no extra media encryption layer.

The normal header is 28 bytes, all multi-byte values big-endian:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | flow kind: video delta 1, audio 2, input motion 3 |
| 1 | 1 | flags: keyframe 0x01, parity 0x10, FEC block 0x20 |
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

Periodic same-configuration video keyframes use DATAGRAM in the current
generation. Startup, configuration, and explicit-repair keyframes remain
reliable `VideoBootstrap` records. Audio is one raw 5 ms Opus multistream packet
per object. A single-data-shard audio object with no parity or FEC block uses
the exact Opus payload length and is not padded to the negotiated datagram
payload size. Input motion carries one `ClientMotionEnvelope`, latest unsent
sample wins, and it has no FEC.

`ScrollInput` preserves point deltas in 1/1024-point units and adds phase on
field 4, X/Y velocity in 1/1024 point-per-second units on fields 5 and 6, and a
continuous-precision marker on field 7. Coalescing preserves total distance
and the newest phase and velocity. End and cancel boundaries are never
discarded behind changed samples. On macOS the host emits continuous pixel
scroll events with fixed-point deltas and maps gesture and momentum phases to
CoreGraphics without intermediate integer-point quantization.

## FEC and feedback

FEC is systematic Reed-Solomon over GF(2^8), primitive polynomial `0x11d`,
generator `0x02`, and the systematic Vandermonde matrix. FEC data shards are
zero-padded before parity. Non-FEC video and multi-shard objects retain the
negotiated full shard size. Reconstruction is block-local and the final object
is trimmed to `objectBytes`.

Telemetry uses client bidi raw stream 8. `ClientTelemetryEnvelope.sequence`
starts at 1 and is contiguous. `MediaFeedback` is tag 10 and reports the exact
datagram sequence window, receive/recovery/loss/reorder counts, jitter, decoder
queue depth, presentation drops, and window duration.

Each negotiated feedback window consists of exactly one video report followed
by exactly one audio report carrying the same nonzero `feedback_window_id`.
The base window is 250 ms; when reliable telemetry is delayed, the client may
coalesce consecutive samples into one positive 250 ms multiple. Both reports
must cover the same duration. After the first report, the second must arrive
within that reported duration; timeout or telemetry EOF with an incomplete pair
is a protocol failure. Video transport
evidence controls clean recovery, while severe audio pressure may still reduce
the shared video delivery budget. Each report requires an active session and an
ordered inclusive sequence range; datagram sequence windows remain independent
per logical media stream while the telemetry-envelope sequence remains global.
Missing, duplicate, unknown-stream, or mismatched-window reports are rejected.

The negotiated video bitrate is the hard video wire ceiling. The host raises a
request that cannot contain the exact format quality floor at the maximum 30%
parity allowance. The wire floor uses the negotiated datagram size and the
actual packetizer plan: per-datagram headers, padded final shards, rounded Reed-
Solomon parity shards, and FEC block boundaries are all counted. The payload
floor starts at 35 millibits per pixel for SDR or
60 millibits per pixel for HDR, multiplied by the exact encoded dimensions and
refresh rate. H.264, HEVC, and AV1 scale that floor by 125%, 100%, and 90%; 4:4:4
scales it by 200% relative to 4:2:0, and bit depth scales relative to 8-bit SDR
or 10-bit HDR. Network evidence owns the wire budget and parity state. The
maximum encoder payload is solved against that same packetization model;
payload and FEC overhead are not interchangeable counters.

The host adapts parity in five-point steps inside 5...30. Sustained packet loss
may reduce the wire budget only as far as the format payload floor plus current
parity, and never above the negotiated ceiling. Video decoder pressure instead
changes a host-side latest-frame encoder-admission divisor; it does not reduce
the wire budget, encoder payload target, or FEC. Video presentation pressure
blocks clean recovery but does not directly reduce admission. Audio playback
pressure does not control video admission. A clean video-pipeline window
sequence restores full admission. Repair and bootstrap frames bypass this
cadence. None of these controls changes the negotiated codec, resolution,
refresh, dynamic range, or hardware decode policy. At most one unsent video
delta may be retained.

The sender additionally meters the actual encoded datagram byte lengths. A
token envelope permits at most two negotiated-datagram-sized chunks of burst,
then schedules every delta, same-generation keyframe, and reliable lifecycle
bootstrap byte at the active wire budget. A datagram batch that cannot fit its
object deadline is dropped before its first local enqueue and enters the
single-flight repair path. Once the first datagram is locally committed, the
host drains the entire reserved object schedule without another local deadline
or capacity abort; only a connection-fatal transport failure can cut that
local enqueue sequence. Such a failure terminates the native media task without
requesting an IDR; ordinary post-enqueue network loss remains feedback-driven
and recoverable through the repair path. Reliable initial, configuration, and
repair bootstraps use
the same token state, read the current committed wire budget before reserving
each chunk, and share one absolute 15-second lifecycle deadline across paced
transfer and the decoded result wait. This runtime byte gate remains
authoritative when real keyframe and delta sizes differ from the negotiated
one-second floor model.

Adaptive platform policy application runs on a dedicated revision-fenced lane,
outside the global control-router mutex. Stop and teardown therefore remain
available while a platform call is stalled. There is no timeout that can report
rejection while a late platform mutation is still possible; completion either
commits the matching revision, records a typed rejection, or is discarded after
session teardown.

Windows retires each Media Foundation worker by epoch. Capture-stop ownership
is retained until cleanup succeeds, so a failed stop remains retryable. Finished
workers are reaped, while a fixed retired-worker bound rejects new sessions
fail-closed instead of accumulating stalled MFT, thread, and D3D resources. A
verified stop permanently retires that epoch's shared frame-delivery ownership;
late capture pause, resume, or drop work therefore cannot send driver START or
STOP operations after a replacement epoch begins.

A decoder-recovery keyframe is generation-fenced and single-flight across
client requests and host-detected stale, incomplete, or post-bootstrap repair
sources. Repeated requests coalesce from the first accepted request through the
matching decoded `VideoBootstrapResult`; only that result resumes paused
encoder admission and reopens a subsequent repair request.

## Security and compatibility

TLS 1.3 protects all streams and QUIC DATAGRAM. A client pins the enrolled
Lumen host identity. Removed v3 exporter/AES-GCM protection must not be
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
