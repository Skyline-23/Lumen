# HDR 120 Hz Bottleneck Map

This document records the measured 3512 x 2290 HEVC Main10 PQ path on the
current Apple silicon host. It is evidence for future optimization work, not a
reason to lower negotiated quality, resolution, or refresh rate.

## Current boundary

The limiting stage is the single VideoToolbox compression session.

- A hardware-only probe with no ScreenCaptureKit or production queue handoff
  admitted 100 frames and emitted 97 valid frames in the first second.
- Producing all 120 ordered outputs took 1224.6 to 1228.6 milliseconds across
  three runs.
- Increasing the bounded in-flight depth from 3 to 8 raised first-second
  admission only from 100 to 103 frames and did not improve output throughput.
- At depth 8, `VTCompressionSessionEncodeFrame` averaged about 9.7 milliseconds
  as VideoToolbox applied backpressure.

This reproduces the production 101 to 102 frame admission ceiling without the
production dispatch handoff. Queue depth and dispatch serialization are not the
dominant limit for this exact format on this host.

The low-latency runtime therefore keeps the ScreenCaptureKit source queue at its
negotiated depth for callback slack, but permits only two pipelined frames inside
VideoToolbox. While both slots are occupied, admission retains only the newest
pending source. This does not raise the hardware throughput ceiling; it gives the
asynchronous hardware encoder one slot of pipeline overlap while preventing that
ceiling from becoming a queue of stale desktop frames.

A later 3600 x 2260 live run showed why the earlier depth-3-versus-depth-8 probe
does not justify a one-frame gate: VideoToolbox callbacks took roughly 18 to 64
milliseconds, so waiting for every callback before admitting the next source
reduced admission to about 17 percent. Two slots retain the freshness bound
without serializing source admission to callback cadence.

## Closed changes

Do not present any of these as a fix for this boundary:

- buffering more frames;
- duplicating frames;
- submitting one session concurrently;
- splitting one predictive stream across multiple compression sessions; or
- lowering bitrate, quality, dimensions, dynamic range, or refresh rate.

Those changes either preserve the hardware ceiling, violate VideoToolbox
ordering and ownership requirements, break the predictive chain, or hide the
problem by reducing the negotiated result.

## Contract-preserving work

The current protocol permits internal scheduling, capture, Metal staging,
encoder configuration, transport pacing, decoder, and presentation changes as
long as bootstrap, keyframe, ordering, and negotiated-format behavior remain
unchanged. A candidate must produce more ordered valid outputs at the same
format and quality before it is kept.

## Contract-changing work

Host-initiated format ladders, layered video, multi-link delivery, and
authoritative delay-control semantics require a new atomic protocol generation.
Their required negotiation boundaries are recorded in
`docs/protocol/post-v4-performance-evolution.md`.

## macOS 27 private display-stream cross-check

The private SkyLight backend materially improves source cadence over the prior
ScreenCaptureKit route, but it does not yet sustain 120 fps through the complete
capture-to-VideoToolbox path. On display 3 (`3008 x 1692 @ 240 Hz`), an internal
Core Animation stimulus and requested `3024 x 1964` output produced:

| Path | SDR HEVC | HDR Main10 | Stream drops |
| --- | ---: | ---: | ---: |
| Raw SkyLight IOSurface | 107.58 fps | 102.56 fps | 0 / 0 |
| Production SkyLight to VT | 92.37 fps | 90.75 fps | 303 / 301 |

The production runs had zero inferred admission-sequence gaps and zero
forwarding drops. VT output callback latency was `18.75 / 21.94 ms` p50/p95 in
SDR and `18.79 / 22.05 ms` in HDR. This places the remaining loss at the
IOSurface-to-VideoToolbox ownership boundary: the compositor can deliver above
100 fps raw, but two leased surfaces remain held long enough for the private
producer to accumulate drops.

Increasing the private queue from two to four is closed. It reduced output to
72.49 fps, raised VT callback p95 to 57.50 ms, and raised cumulative stream
drops to 440. More buffering makes frames stale without raising encoder
throughput.
