# Lumen Streaming Protocol v3

## Status and authority

Lumen Streaming Protocol v3 is the only forward-looking transport contract
between Lumen and Shadow. It is a source-neutral, Lumen-owned protocol. It does
not preserve GameStream, Sunshine, Moonlight, RTSP, SDP, RTP, ENet, or NVIDIA
packet compatibility.

The canonical machine-readable constants live in
`lumen-native-transport-conformance.json`; control message field numbers and
enums live in `lumen-streaming-v3.proto`. Rust owns negotiation, framing,
validation, pacing policy, recovery policy, and session state. Platform
capture, encode, decode, display, audio, and input adapters expose capabilities
and frames but cannot invent wire state.

Protocol integers use network byte order unless a field explicitly says
otherwise. Unknown fields are ignored only when their enclosing message is
declared extensible. Unknown message kinds and invalid lengths terminate the
session with a typed protocol error.

## Design targets

- 4K at 120 frames per second with an 8.33 ms frame interval;
- HEVC Main as the default codec, with explicit H.264 and AV1 selections;
- SDR and HDR10 as an independent account preference validated before launch;
- Stereo, 5.1, and 7.1 independently selected from standard or high audio quality;
- no ProRes implementation, negotiation, probe, or fallback path;
- no head-of-line blocking between control, input, audio, and video;
- one protected `lumen-udp-aead` media transport on every validated path;
- live ultra-low-latency, balanced, and quality policy transitions without a
  session reconnect;
- one authenticated connection and one negotiated session plan;
- bounded memory with frame-granular admission and dropping;
- explicit HDR, color, audio, input, and presentation contracts;
- no bitrate, quality, resolution, or refresh-rate reduction merely to improve
  a synthetic score, and no HDR downgrade after HDR has been negotiated.

## Connection and media transport

Every session has a QUIC v1 control connection with TLS 1.3 and ALPN
`lumen-stream/3`. Authentication, negotiation, reliable state, clock feedback,
and recovery authority always remain on that connection. Native media key
material uses the TLS exporter label `EXPORTER-Lumen-Session-v3`.
The exact-format generation retains `2` in `ClientSessionHello` minimum and
maximum protocol versions and in `HostSessionPlan.protocolVersion`; ALPN and
the required exact-format message fields identify generation 3.

Media always uses the single `lumen-udp-aead` transport after its UDP path is
authenticated and validated. Lumen owns media pacing, deadlines, DSCP, loss
feedback, queue admission, packet protection, and recovery on that transport.
There is no QUIC DATAGRAM, RTP, or alternative media fallback.

The media transport uses the Lumen header, frame ids, policy revisions,
feedback, and recovery rules defined below. Its key is derived from the
authenticated TLS exporter and is never sent on the wire. Packets use AEAD with
the fixed header as authenticated data and reject replays outside the negotiated
sequence window.

Implementations may select their congestion controller but must pace datagrams,
honor the negotiated send budget, and apply a circuit breaker when queue delay
or sustained loss shows that the path cannot carry the current media rate.

The client pins the host identity established during device enrollment. The
first bidirectional stream is the session-control stream. Its first message is
`ClientSessionHello`; the host answers with exactly one `HostSessionPlan` or a
typed rejection. Media cannot start until the client acknowledges the plan.

Every session has a random 32-bit epoch. Reconnecting creates a new epoch and
invalidates paths, packets, stream ids, sequence numbers, policy revisions,
configuration ids, and frame ids from the previous connection.

### Direct-path validation

The host offers a direct UDP endpoint and one-use challenge over the control
stream. The client sends an authenticated request on UDP and validates the
host's authenticated UDP response. The client then echoes the challenge in a
`MediaPathResponse` on QUIC, and the host returns `MediaPathValidated` only when
the UDP source and QUIC session match. The path becomes eligible only after this
two-channel confirmation and its measured payload limit, RTT, and loss fall
within the session plan.

Path probes use one fixed 60-byte `LP` record: magic `0x4C50`, version, request
or response kind, session epoch, path id, two reserved zero bytes, the 32-byte
one-use challenge, and a 16-byte AES-GCM tag. The first 44 bytes are
authenticated data and the empty protected payload prevents the probe from
becoming a second control channel. Request and response kinds use distinct
nonces derived from epoch, path id, and kind.

Path failure pauses new media admission and starts a new Lumen UDP challenge.
The same transport resumes only after a stable observation window. If
revalidation misses the negotiated deadline, the host terminates the session
with a typed path failure instead of silently changing protocols. The host
never trusts a source address learned only from an unauthenticated UDP packet.

## Stream classes

QUIC streams have one responsibility so backpressure in one class cannot stall
another class.

| Class | QUIC primitive | Purpose |
| --- | --- | --- |
| Session control | bidirectional stream | offer, plan, lifecycle, errors |
| Input state | bidirectional stream | keys, buttons, text, attach/detach, acknowledgements |
| Codec configuration | unidirectional stream | immutable decoder configurations and HDR session metadata |
| Telemetry | bidirectional stream | loss, decode, render, clock, pacing feedback |
| File transfer | independent bidirectional stream per transfer | metadata and bounded chunks |
| Video | negotiated datagram plane | independently presentable encoded frames |
| Audio | negotiated datagram plane | 5 ms Opus access units |
| Motion input | negotiated datagram plane | coalescible pointer, scroll, touch, pen, and motion samples |

Control messages use length-delimited Protocol Buffers. A message larger than
the negotiated control limit is rejected before allocation. File payload bytes
do not travel inside control messages.

The client opens bidirectional streams in this fixed order: session control,
input state, then telemetry. The host opens one unidirectional codec-
configuration stream. No stream role is inferred from a legacy port or packet
type. Reliable input envelopes and codec configurations use the same 32 KiB
length-delimited protobuf allocation limit as session control.

## Account streaming profile

The authenticated account service owns one revisioned streaming profile per
account. It is fetched and replaced before selecting a host; it is not stored
by the Lumen host and does not travel over the session QUIC connection as a
mutable account document.

`GET /v1/account/streaming-profile` returns the complete profile.
`PUT /v1/account/streaming-profile` requires an `If-Match` header containing
the current revision and returns the complete profile with a strictly greater
nonzero revision. The bearer token is the sole account identity; clients never
submit an account id in the path or body.

The version 1 JSON document contains `schemaVersion`, `revision`,
`videoCodec`, `dynamicRange`, `audioChannelMode`, and `audioQuality`. Defaults
are `hevc`, `sdr`, `stereo`, and `standard`. Valid explicit alternatives are
`h264` or `av1`, `hdr10`, `5.1` or `7.1`, and `high` respectively. The four
selection axes are independent.

Account errors use `authentication-required`, `profile-revision-conflict`,
`invalid-streaming-profile`, and `profile-service-unavailable`. A revision
conflict and service outage are retryable; an invalid profile is not.

Shadow copies the exact account intent and revision into the session hello.
Lumen intersects that intent with current client decode and host encode/output
capabilities. An unsupported combination is a typed pre-session negotiation
failure. Neither side rewrites the stored preference, silently downgrades, nor
switches codec during an active session.

## Session negotiation

`ClientSessionHello` contains:

- protocol version range;
- display size, scale, refresh rate, gamut, transfer function, luminance, and
  HDR metadata support;
- exact hardware video rows combining codec, profile, chroma subsampling, bit
  depth, dynamic range, color range, maximum geometry, and maximum refresh;
- supported Opus channel layouts and audio output capabilities;
- input device and feedback capabilities;
- maximum receive datagram payload and receive-memory budget;
- the exact account-selected video format, audio channel mode, audio quality,
  and nonzero streaming-profile revision;
- requested presentation mode and runtime policy.

`HostSessionPlan` contains the single selected contract:

- session epoch;
- encoded size, frame rate, presentation mode, dynamic range, gamut, transfer
  function, and luminance contract;
- one exact selected hardware video row, bitrate envelope, keyframe policy,
  configuration id, and maximum in-flight frame count;
- Opus channel count, stream count, coupled-stream count, mapping, and fixed
  5 ms packet duration;
- maximum datagram payload, data-shard limit, parity-shard limit, and initial
  parity ratio;
- media endpoint, initial path id, policy mode, latency budget, and
  policy revision;
- input lanes and feedback capabilities;
- client deadlines for ingest, decode, and presentation.

Logical datagram stream ids are allocated once per session epoch: video is `1`,
audio is `2`, and input motion is `3`. They are never reused for another class
inside the epoch. The initial video configuration id is `1`; subsequent ids are
strictly increasing and never wrap or reset during a connection.

Capabilities and the four account selections are immutable after
`StartSessionAck`. Runtime policy changes use `PolicyProposal`, `PolicyAck`, an
incrementing policy revision, and an exact `effectiveFrameId`. A codec or
dynamic-range change requires a new preflight and session.

## Runtime policy modes

The user selects a preference and the host adapts only inside that envelope.

| Policy | Frame admission | Repair | Quality behavior |
| --- | --- | --- | --- |
| `ultraLatency` | one presentable frame | no normal-frame retransmission; observed-loss parity only | prioritize newest frame and minimum queue age |
| `balanced` | up to two presentable frames | deadline-aware keyframe repair plus adaptive parity | raise quality after sustained headroom |
| `quality` | bounded three-frame window | repair when RTT fits the deadline; otherwise adaptive parity | maximize bitrate and encoder quality inside the latency ceiling |

Policy changes never silently change resolution, frame rate, dynamic range, or
the user's selected codec family. Those changes require an explicit client
request and a new plan revision. Network adaptation first changes pacing,
parity, repair, bitrate inside the negotiated floor and ceiling, and keyframe
strategy.

Promotion toward quality requires at least two seconds of stable delivery-rate
headroom and healthy decode/render queues. Demotion reacts within three missed
presentation deadlines or one declared decoder stall. Recovery hysteresis
prevents oscillation between policies.

## Media datagrams

Video, audio, and input motion use the same fixed 40-byte header on the Lumen
datagram transport.
Payload length is the datagram length minus `headerBytes` and the AEAD tag; it
is never repeated in the header.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 2 | magic `0x4C33` (`L3`) |
| 2 | 1 | protocol version `3` |
| 3 | 1 | datagram kind: video `1`, audio `2`, input motion `3` |
| 4 | 2 | flags |
| 6 | 2 | header bytes, initially `40` |
| 8 | 4 | session epoch |
| 12 | 2 | active media path id |
| 14 | 2 | policy revision |
| 16 | 2 | logical stream id |
| 18 | 2 | shard index |
| 20 | 2 | data-shard count |
| 22 | 2 | parity-shard count |
| 24 | 4 | packet sequence |
| 28 | 4 | frame or audio-unit id |
| 32 | 4 | unsharded frame bytes |
| 36 | 4 | capture timestamp in microseconds modulo `2^32` |

Defined flags are keyframe, codec configuration boundary, discontinuity,
end-of-stream, parity shard, and FEC block extension. Reserved flag bits must
be zero when sent and ignored when received.

Frames that exceed one Reed-Solomon field set the FEC block flag and extend the
header to 48 bytes. The extension carries a 16-bit block index, 16-bit block
count, and 32-bit byte offset of that block in the unsharded frame. Base shard
index and shard counts are local to the block. Each block is independently
recoverable and contains no more than 256 total data and parity shards. All
shards in one block carry the same extension values.

FEC is systematic Reed-Solomon over GF(2^8), using the primitive polynomial
`0x11d`, generator `0x02`, and the systematic Vandermonde matrix. Data shards
occupy indices `0..<dataShards`; parity follows immediately. Every data shard is
zero-padded to the block shard size before parity is generated. Reconstruction
is per block: reconstruct missing shards, concatenate data shards in index
order, then truncate to the block byte range derived from consecutive
`framePayloadOffset` values or the final `frameBytes` value. Parity count is
`ceil(dataShards * parityPercentage / 100)` and total shards never exceed 256.

The generator matrix is byte-exact. For `d` data shards and `p` parity shards,
construct a `(d + p) x d` Vandermonde matrix `V` whose element `V[r,c]` is
`r^c` in GF(2^8), with `r` interpreted as the byte-valued field element and
`x^0 = 1`. Let `T` be rows `0..<d` of `V`, then compute `G = V * T^-1`.
Rows `0..<d` of `G` are the identity matrix. Parity shard `j` uses row
`G[d + j]`: each parity byte is the XOR sum of the corresponding data bytes
multiplied by that row's GF coefficients. Reconstruction selects any `d`
available rows of `G`, inverts that submatrix, and applies it at every shard
byte position.

All shards for one frame use the same epoch, path id, policy revision, stream
id, frame id, frame byte count, and timestamp. Within each FEC block they use
the same block metadata and shard counts. Shard indices cover data shards first
and parity shards second. A receiver admits or drops a whole frame; it never
forwards a partial access unit to a decoder.

The negotiated maximum datagram payload must remain below the validated path
MTU. Implementations start at 1200 bytes and may raise the payload only after
path validation. Packetization never relies on IP fragmentation. A path switch
uses a keyframe boundary and sends configuration state on the reliable stream
before packets with the new path id.

## Video policy

Each video frame is independently tracked by `frameId`. Decoder configuration
travels on the reliable codec-configuration stream before any datagram that
references its `configurationId`. The first frame under a new configuration is
a keyframe.

The host sends one length-delimited `CodecConfiguration` protobuf on the first
host-initiated unidirectional QUIC stream. `decoder_configuration_record` is an
`AVCDecoderConfigurationRecord` for H.264, an
`HEVCDecoderConfigurationRecord` for HEVC, or an
`AV1CodecConfigurationRecord` for AV1. H.264 and HEVC access units contain
four-byte network-order length-prefixed NAL units. AV1 access units use the
low-overhead OBU form and every OBU sets `obu_has_size_field`. Annex B start
codes, SDP parameter strings, and configuration bytes prepended to keyframes
are forbidden.

The client advertises credit for at least one host-initiated unidirectional
stream before sending `ClientSessionHello`. After receiving that first control
request, the host opens stream id 3 before returning the session plan. If the
client does not admit that stream, the host returns `NativeProtocolError` code
9 on the session-control stream for the hello request and terminates the
connection. The host does not leave the client waiting indefinitely for codec
configuration.

Native protocol error codes are stable:

| Code | Meaning |
| ---: | --- |
| 1 | invalid operation |
| 2 | authentication |
| 3 | application |
| 4 | negotiation |
| 5 | session conflict |
| 6 | media path |
| 7 | platform start or cleanup |
| 8 | session state |
| 9 | QUIC transport or fixed-stream admission |

Every reconstructed video frame begins with this network-order descriptor,
followed immediately by exactly `accessUnitBytes` codec bytes:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | acknowledged configuration id |
| 4 | 4 | encoded access-unit byte count |

The media header `frameBytes` includes this eight-byte descriptor. The
configuration-boundary flag is set only on the first keyframe using a newly
acknowledged configuration. It does not announce inline configuration data.
The client acknowledges the exact epoch, video stream id, and configuration id
with `CodecConfigurationAck` before that keyframe is admitted.

The host keeps at most the negotiated number of frames in admission, encode,
and send stages. Under pressure it drops complete non-key frames before encode
or before packetization. It does not drain stale fragments after their
presentation deadline.

Normal video datagrams are not retransmitted. A missing keyframe shard may be
repaired only when measured RTT is shorter than its remaining presentation
deadline. Otherwise the client requests a fresh keyframe. Decoder
configurations remain reliable. FEC is raised only for observed non-congestion
loss; adding parity during congestion is forbidden because it worsens the
bottleneck.

When HDR is selected, HDR static session metadata is part of the session plan.
Per-frame dynamic range and overlay state are carried in the protected frame
descriptor before the encoded access unit and therefore participate in frame
FEC. SDR sessions omit HDR metadata entirely. H.264, HEVC, and AV1 use the same
logical descriptor; 10-bit fields are valid only when that exact codec and HDR
capability combination was negotiated.

## Audio policy

Audio is Opus with a fixed 5 ms duration. Channel mapping is selected in the
session plan; there is no SDP or positional compatibility string. Every audio
unit has an id and capture timestamp. A receiver may use short packet-loss
concealment but must not build an unbounded jitter queue.

Audio and video timestamps share the same session clock. Clock synchronization
uses periodic four-timestamp probes on the telemetry stream. Implementations
correct drift gradually and never reorder video to hide audio drift.

The audio payload is exactly one raw Opus multistream packet. It has no RTP,
SDP, topology prefix, or compatibility header. `frameId` is the monotonically
increasing audio-unit id within the session epoch. `captureTimestampUs` is the
first PCM sample time on the shared session clock in microseconds modulo
`2^32`. The selected channel count, stream count, coupled-stream count, and
mapping live only in `HostSessionPlan`; every unit represents exactly 240
samples per channel at 48 kHz.

## Input policy

State-changing input uses the second client-initiated bidirectional QUIC stream.
Each length-delimited `ClientInputEnvelope` carries a nonzero session epoch and
a strictly increasing 64-bit event sequence. Keyboard keys use USB HID keyboard
usage ids. Committed and marked text is UTF-8; composition selections are UTF-8
byte offsets and must land on scalar boundaries. This keeps multilingual input
independent of Windows virtual-key values or Apple key codes.

The reliable stream uses varint-length-delimited protobuf messages with a
32 KiB body limit. `ClientInputEnvelope` uses fields `session_epoch = 1`,
`event_sequence = 2`, and payload oneof fields `keyboard = 10`, `text = 11`,
`pointer_button = 12`, `gamepad_connection = 13`, `gamepad_button = 14`,
`touch_contact = 15`, `pen_contact = 16`, and `rumble_ack = 17`.
`HostInputEnvelope` uses `session_epoch = 1`, `command_sequence = 2`, and
payload oneof fields `ack = 10`, `reset = 11`, and `rumble = 12`. Protobuf
serialization order does not carry meaning; sequence fields and the QUIC byte
stream provide ordering.

Keyboard `modifiers` is the USB HID boot modifier byte. Bits `0...7` mean left
control, left shift, left alt, left GUI, right control, right shift, right alt,
and right GUI. Pointer button values are primary/left `1`, middle `2`,
secondary/right `3`, back `4`, and forward `5`. Gamepad ids are `0...15`.
Button analog values, triggers, and rumble motor amplitudes use unsigned values
in `0...65535`, even though protobuf carries them in `uint32` fields.

Keyboard, text, pointer buttons, gamepad attach/detach, gamepad buttons,
touch/pen begin/end/cancel, and rumble acknowledgements are reliable and
ordered. The host acknowledges the highest contiguous event sequence.
Host-to-client `RumbleCommand` is reliable and ordered; all four motor values
are unsigned 16-bit normalized amplitudes encoded in `uint32` fields, and the
client returns `RumbleAck` for the exact command sequence.

Pointer motion, scrolling, touch movement, pen movement, and gamepad axes or
motion use `ClientMotionEnvelope` as one protected `lumen-udp-aead` payload with
kind `3`, logical stream id `3`, one data shard, no parity, and no
retransmission. `motion_sequence` is monotonic modulo `2^32`; the media header
timestamp is the sample time. Newer unsent motion supersedes older motion for
the same device and contact. Relative pointer values are signed counts;
absolute coordinates and contact pressure are finite normalized floats in
`0...1`; scroll values are signed 1/1024-point units; gamepad sticks are
`-32768...32767`, and triggers are `0...65535`.

Key, button, controller attach/detach, text, clipboard, and file-transfer state
are never sent on the lossy lane. Session stop synthesizes releases for every
pressed key and button before destroying platform input state.

## Feedback and recovery

The client reports feedback every 16 ms while media is active and immediately
on a decoder stall, reference invalidation, path change, or deadline miss.
Feedback contains:

- highest received packet sequence and compact loss ranges;
- admitted, recovered, dropped, decoded, and presented frame ids;
- receive, decode, and presentation queue depths;
- decoder output age and presentation delay;
- measured path RTT, clock offset, and datagram payload limit.
- delivery-rate estimate, one-way delay trend, ECN state, active path id, and
  policy revision.

The host adapts pacing, repair, and parity from sustained evidence. A single
loss sample cannot force a codec, HDR, resolution, or frame-rate downgrade.
When RTT fits the presentation deadline, targeted repair is preferred over
proactive parity. When it does not, bounded parity protects only the frames
whose loss would invalidate future decoding. Codec fallback is allowed only
after declared decoder failure or repeated missed recovery deadlines.

## Discovery and ports

Lumen advertises `_lumen._udp` over mDNS with protocol major version, QUIC port,
optional direct-media UDP port, host identity fingerprint, and enrollment
requirement. When the owner enables UPnP, Lumen maps the HTTPS control, native
QUIC, and direct-media ports. HTTPS carries device
enrollment, access-token rotation, authenticated discovery, and settings for
both LAN and WAN clients. Launch negotiation, input, telemetry, and reliable
session state travel on the authenticated QUIC connection.

No RTSP, RTP, ENet, or legacy GameStream port is advertised or opened by a
v3-only host.

The authoritative discovery field is mDNS TXT `quic-port`; authenticated HTTPS
host discovery exposes the same value as `sessionQuicPort`. The default base
port is `47989`, the QUIC offset is `21`, and therefore the default QUIC control
port is `48010`. Native media uses base offset `9` (`47998` by default), while
HTTPS control uses offset `1` (`47990` by default). Clients use the
discovered value when present and use `48010`
only when discovery is unavailable and the user supplied no explicit port.

## Alternatives considered

- **QUIC DATAGRAM** would reuse QUIC security and congestion state, but it adds
  another media behavior and transition state while coupling high-rate media to
  the reliable control connection. Lumen v3 intentionally has no such fallback.
- **Raw UDP only** has the smallest media overhead but would duplicate
  authentication, NAT traversal, reliable control, and path recovery. Lumen
  uses it only after the QUIC-authenticated direct-path handshake.
- **WebRTC** has mature adaptation but requires RTP, SDP, ICE, DTLS-SRTP, and
  browser-oriented interoperability that Lumen intentionally removed.
- **Media over QUIC** remains a draft optimized for publish/subscribe and relay
  distribution. Lumen is a single-host interactive desktop session and does not
  need its object and subscription model.
- **SRT and RIST** optimize contribution streaming through retransmission
  windows. Their buffering model is not the authority for interactive input and
  8.33 ms frame deadlines.

## Removal gate

The v3-only release must satisfy all of these conditions:

- Shadow completes a session without RTSP, SDP, RTP, ENet, or legacy launch
  fields;
- a failed media path revalidates the same Lumen transport or terminates with a
  typed path failure without resetting input state;
- ultra-low-latency, balanced, and quality policies transition on the declared
  effective frame without oscillation;
- Windows and macOS hosts use the same Rust negotiation and framing code;
- protocol tests are generated only from Lumen-owned fixtures;
- the release build contains no Sunshine or Moonlight runtime source;
- media admission stays bounded during 4K120 SDR and optional HDR stress runs;
- HEVC Main SDR, optional H.264/AV1, independent HDR10, Opus, input reset,
  keyframe recovery, and clock synchronization pass their applicable
  cross-platform conformance tests;
- no build or test contains a ProRes implementation or compatibility fixture.

## Validation

After changing the transport fixture or this contract, run:

```bash
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
python3 tools/quality/run_lumen_quality_gate.py --fast
```
