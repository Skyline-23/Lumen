# Realtime Media Quality Design

## Problem

Lumen currently polls and sends audio, then polls and sends video, from one
1 ms task. A video queue-capacity wait may consume the complete video object
deadline (normally 16.668 ms), so a 5 ms Opus packet is not polled while the
video sender is suspended. Shadow can conceal at most six missing packets and
then trims or resets its low-latency queue. Increasing that queue would add
latency without removing the host-side head-of-line blocking.

The latest captured live session also produced 315 reliable video bootstraps
and 315 acknowledgements. The repeated 400-580 KB keyframes occupied the QUIC
datagram queue, caused video queue-barrier drops, and reduced both presented
frame cadence and audio continuity.

The host already calculates `target_bitrate_kbps`, adaptive FEC, and an
`admission_divisor` from 250 ms feedback. The bitrate is diagnostic state only:
it is never applied to VideoToolbox. Audio feedback is accepted but ignored,
even though an audio loss or playback drop is the strongest evidence that
video traffic must yield.

The existing Shadow integration test decodes one hard-coded Opus packet. It
proves codec compatibility for 240 frames, not sustained transport fidelity.

## Goals

- A video capacity wait must never delay capture polling or submission of a
  ready 5 ms audio packet.
- Video may use the shared QUIC datagram connection only while preserving
  bounded audio egress headroom.
- Video bitrate must adapt at runtime without recreating the encoder, changing
  resolution, or reducing the negotiated frame-rate target.
- Both audio and video feedback must drive one congestion controller.
- Repeated recovery bootstraps must be bounded while congestion adaptation
  takes effect.
- A same-Mac deterministic test must exercise the real Lumen Opus encoder and
  media packetizer and the real Shadow assembler and Opus decoder.
- The same-Mac test must require at least 90% source-frame coverage and at
  least 0.90 normalized waveform correlation after deterministic alignment.

## Non-goals

- Do not increase client playback latency to hide transport gaps.
- Do not fall back to a physical iPad for the automated fidelity gate.
- Do not reduce resolution or the negotiated 120 Hz capture target.
- Do not make ScreenCaptureKit or VideoToolbox failures non-terminal.
- Do not weaken generation, bootstrap, or exact-display fail-closed behavior.

## Architecture

### Independent media tasks

`run_native_media_loop` owns three sibling futures over cloned Quinn
connections:

1. `run_native_audio_sender` polls the platform every 1 ms and sends each ready
   Opus object with its existing 5 ms deadline.
2. `run_native_video_sender` owns normalization, bootstrap, FEC, and video
   queue barriers.
3. `run_native_motion_receiver` reads client motion datagrams.

Failure of any terminal future cancels the other two at the parent boundary.
Audio warnings remain non-terminal, as they are today.

The video barrier reserves two maximum-sized datagrams (2,400 bytes) for the
next 10 ms of stereo audio. A video object that cannot fit while preserving
that reserve is dropped as one object and requests one repair chain. Audio
never uses an evicting send.

### Congestion controller

`AdaptiveVideoDeliveryController` receives one `MediaFeedback` window at a
time. It derives datagram loss from the sequence span and received datagram
count; object loss and late-object counts are separate event signals and are
never added to a datagram denominator.

An audio window is congested when it reports an unrecoverable object, a late
object, a playback drop, a timeline reset, or a decoder queue above the
low-latency window. A video window is congested when it reports the same
transport failures, a presentation drop, or a decoder queue above the
negotiated presentation budget.

- Severe congestion applies a 20% multiplicative decrease.
- Transport congestion applies a 10% multiplicative decrease.
- The controller waits eight clean 250 ms windows before a 5% additive
  increase.
- The target remains between one quarter of the negotiated ceiling and the
  negotiated ceiling.
- FEC remains between 5% and 30% and follows measured datagram loss.
- The encoder target accounts for FEC overhead so parity does not push the
  wire rate above the selected budget.
- The negotiated frame rate and capture admission cadence are unchanged.

Each changed target produces
`PlatformControlEvent::SetVideoBitrateKbps { bitrate_kbps }`. The macOS bridge
applies `kVTCompressionPropertyKey_AverageBitRate` and a one-second
`kVTCompressionPropertyKey_DataRateLimits` value on the existing encoder
queue. A failed dynamic update raises a typed runtime warning and keeps the
last successfully applied target.

### Repair storm bound

The host keeps one recovery bootstrap pending per generation. Consecutive
repair generations are rate-limited to one every 500 ms until two seconds of
clean feedback have elapsed. Initial and codec-configuration bootstraps are
never delayed. This caps recovery traffic without converting a repair failure
into silent continuation.

### Same-Mac fidelity gate

The test runner uses a temporary directory and a loopback socket:

1. A Lumen fixture generates ten seconds of deterministic 48 kHz stereo PCM.
2. The real macOS Lumen Opus bridge encodes 5 ms packets.
3. The real Lumen media packetizer emits production v4 audio datagrams.
4. A loopback sender applies the production audio scheduler while a synthetic
   video producer continuously pressures the video barrier.
5. Shadow receives the datagrams, runs the production assembler and real Opus
   decoder, and records decoded PCM and packet admission.
6. The verifier aligns the decoded signal by cross-correlation and reports:
   source frames, decoded source frames, concealed frames, dropped frames,
   maximum consecutive missing duration, correlation, and timeline resets.

The gate passes only when:

- `decodedSourceFrames / sourceFrames >= 0.90`
- normalized cross-correlation is at least `0.90`
- maximum consecutive missing duration is no more than `20 ms`
- a clean loopback run has zero timeline resets
- the simultaneous video-pressure run meets the same coverage and correlation
  thresholds

The test is deterministic and requires no installed app, iPad, microphone, or
speaker.

## Verification

- Rust scheduler tests prove a suspended video barrier does not delay audio
  polling and that video preserves audio headroom.
- Rust controller tests cover severe decrease, transport decrease, stable
  increase, FEC overhead, floors, ceilings, and audio-triggered video yielding.
- Swift tests prove dynamic bitrate updates run on the encoder queue and do
  not recreate the compression session.
- Shadow tests prove audio playback metrics enter audio feedback and repair
  requests are bounded.
- The same-Mac runner emits a machine-readable JSON report and fails below any
  required threshold.
- Full Lumen and Shadow test suites, Release builds, signing checks, and a
  final physical-iPad live run remain required before completion.
