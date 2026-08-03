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
negotiated depth for callback slack, but permits only one frame inside
VideoToolbox. While that frame is encoding, admission retains only the newest
pending source. This does not raise the hardware throughput ceiling; it prevents
that ceiling from becoming a queue of stale desktop frames.

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
