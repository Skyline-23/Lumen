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

## 2026-09-05: Native 4K HDR pixel-semantics gate precedes throughput acceptance

The older VT timing measurements above remain specific to their fixtures. They
do not prove that the live private source contains unclipped HDR pixels. The
new `--inspect-native-color` mode in the existing screen harness compares eight
static PQ/BT.2020 patches on an owned virtual display. Only bounded scalar
samples leave the C callbacks; a Swift actor checks sample accounting, spatial
uniformity, temporal stability, matrix agreement, and highlight separation.

- On a CG virtual display, 219/219 settled samples were spatially uniform and
  temporally identical. Requested BT.2020 native P010 instead matched the
  BT.601 matrix of simultaneous RGB10 samples within 0.487 code values; BT.2020
  differed by up to 40.899 codes. A separate 210/210 stable BT.709 request gave
  the same pixels. Exported CG and CoreVideo 709 constants have identical values;
  a string mapping change is not a fix.
- That CG display reported current/potential EDR headroom 1 despite HDR creation
  settings. The existing SL virtual-display implementation reported headroom 5
  with actual 1920x1080 logical / 3840x2160 backing at 120 Hz. It can be examined
  without calling unsupported CG mode setters. Legacy `CGDisplayPixelsWide`
  returns the logical 1920 on this SL display; use the selected mode's pixel
  dimensions for backing-size validation. Product backend selection is unchanged.
- On the same SL display, raw RGB10's latest three high-gray samples all had
  channel code 520 (about 100 nits if interpreted as PQ), whereas SCK canonical
  HDR P010 preserved distinct Y values 567, 653, and 785 with PQ/BT.2020 metadata.
  Both streams stopped successfully and all 93 observations were collected.
  However, the full-run temporal stability gate failed (363-code maximum
  transient), so this is boundary-localization evidence, not final native HDR
  color equivalence or a performance acceptance result.

Artifacts are in the sibling Shadow checkout under
`artifacts/screen-metrics/macos-e2e-20260905/`:
`native-rgb10-p010-color-settled-2020.jsonlog`,
`native-rgb10-p010-color-settled-709.jsonlog`,
`native-rgb10-p010-color-sl-backing.jsonlog`, and
`native-rgb10-sck-p010-color-sl-reference.jsonlog`.

Next boundary: establish a stable HDR-preserving native source (and correct
matrix), then validate its GPU conversion and actual end-to-end throughput.
The synthetic RGB10-to-P010 converter remains unused by production: retagging
raw RGB10 as PQ cannot recover highlights already clipped upstream. No new
native 4K HDR 120-FPS or stutter fix has been accepted from these color probes.
