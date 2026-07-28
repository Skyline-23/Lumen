# Native Session Quality Boundaries

## Scope

This design addresses three independent producer-side defects observed in a
generation-four native session:

1. ScreenCaptureKit source delivery is back-pressured by synchronous
   VideoToolbox admission and produces roughly 34 source samples per second
   despite a real 120 Hz virtual display and a negotiated 120 FPS target.
2. Desktop-mirror sessions leave the physical display online even when the
   requested workspace policy is isolated.
3. Captured system audio is forwarded to the client but continues playing on
   the host.

The changes do not alter the v4 wire contract, reduce resolution, quality,
bitrate, HDR, or frame rate, synthesize duplicate frames, or add compatibility
fallbacks.

## Capture and encoder admission

ScreenCaptureKit sample receipt must not synchronously wait for
`VTCompressionSessionEncodeFrame`. Source samples enter a bounded,
latest-frame admission boundary. VideoToolbox submission remains serialized
and owns a single compression session. When admission is saturated, the
existing typed drop and recovery-keyframe accounting applies; the queue must
not grow without bound.

All bootstrap generation, acknowledgement, codec-configuration, and
VideoToolbox callback ordering remains fail-closed. A blocked encoder
submission must be testable through an injected submission boundary while
source receipt continues.

## Physical-display isolation

Desktop mirroring must honor the requested workspace policy. With
`isolatedWorkspace`, Lumen first creates, mirrors, publishes, and captures the
retained virtual display. Only after the first encoded frame proves the
capture source is usable may the existing exact-display isolation operation
disable the session-owned physical targets.

Stop, failure, cancellation, watchdog recovery, and durable recovery restore
only the exact physical display IDs changed by this session and restore the
captured topology. `coexist` retains the existing behavior.

## Host-audio suppression

The session captures system audio through a Core Audio process tap whose mute
behavior is active only while Lumen consumes the tap. The tap forwards the
same audio contract to the client while preventing the tapped mix from
reaching the physical output. Lumen must not change global volume, mute state,
or the default output device.

Tap, aggregate-device, and AudioUnit ownership is session-scoped and
actor-owned. Every terminal path destroys these resources in reverse order.
If exclusive tapped capture cannot be established, session startup fails with
a typed platform error rather than silently playing host audio.

## Acceptance

- A blocked VideoToolbox submission does not block ScreenCaptureKit sample
  receipt; pending admission remains bounded and preserves the newest valid
  sample.
- A live 120 Hz session reports materially improved source and encoder
  cadence without quality or stability regression.
- An isolated desktop-mirror session disables only its physical target after
  the first encoded frame and restores it exactly on teardown.
- System audio reaches the client while the host output is suppressed only
  for the active session.
- Existing v4 control, bootstrap, input, telemetry, typed stop, and recovery
  behavior remains green.
