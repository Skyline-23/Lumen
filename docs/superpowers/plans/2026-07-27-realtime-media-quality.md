# Realtime Media Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve continuous 5 ms audio delivery under video pressure, apply real adaptive VideoToolbox bitrate control without reducing FPS, bound bootstrap storms, and prove at least 90% same-Mac audio fidelity through the Lumen-to-Shadow media path.

**Architecture:** Lumen runs independent audio, video, and motion futures over one QUIC connection while reserving audio egress capacity. A feedback controller consumes both audio and video windows and emits typed runtime bitrate changes to the existing VideoToolbox session. A deterministic same-Mac runner joins the real Lumen encoder and packetizer to the real Shadow assembler and decoder.

**Tech Stack:** Rust/Tokio/Quinn, Swift 6, VideoToolbox, SwiftOpus/COpus, Tuist, Swift Testing, XCTest.

## Global Constraints

- Work in `/Users/skyline23/code/Lumen` and `/Users/skyline23/code/shadow-client`; do not create another worktree.
- Preserve exact-display and v4-only fail-closed behavior.
- Preserve the negotiated resolution and frame-rate target; adaptive control changes bitrate and FEC, not FPS.
- New Lumen coordination uses Swift concurrency or Tokio ownership, not `NSLock`.
- Write each behavior test first and observe RED before implementation.
- Commit English Conventional Commit subjects with detailed English bullet bodies.
- Do not install or run a physical-iPad session until both repositories pass their full automated gates.

---

### Task 1: Separate Lumen audio, video, and motion scheduling

**Files:**
- Modify: `engine/lumen-host/src/server/media.rs`
- Test: `engine/lumen-host/src/server/media.rs`

**Interfaces:**
- Consumes: `poll_and_send_audio`, `poll_and_send_video`, `handle_motion_datagram`
- Produces: `run_native_audio_sender`, `run_native_video_sender`, `run_native_motion_receiver`

- [ ] **Step 1: Write a failing audio independence test**

Add a Tokio test with a video future held by a `Notify`, a 5 ms audio cadence,
and a counter updated by the audio future:

```rust
#[tokio::test(start_paused = true)]
async fn suspended_video_barrier_does_not_delay_ready_audio_packets() {
    let audio_polls = Arc::new(AtomicUsize::new(0));
    let release_video = Arc::new(Notify::new());
    let audio = run_test_audio_cadence(audio_polls.clone(), 3);
    let video = async { release_video.notified().await };
    tokio::pin!(audio, video);

    tokio::time::advance(Duration::from_millis(15)).await;

    assert_eq!(audio_polls.load(Ordering::SeqCst), 3);
}
```

- [ ] **Step 2: Run the focused test and observe RED**

Run:

```bash
cargo test -p lumen-host suspended_video_barrier_does_not_delay_ready_audio_packets -- --exact
```

Expected: FAIL because the current single tick awaits video before polling
audio again.

- [ ] **Step 3: Split the parent loop into sibling futures**

Keep sender state local to each future and join them at the existing terminal
boundary:

```rust
pub(super) async fn run_native_media_loop(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), String> {
    tokio::try_join!(
        run_native_audio_sender(
            connection.clone(),
            router.clone(),
            platform.clone()
        ),
        run_native_video_sender(
            connection.clone(),
            router.clone(),
            platform.clone()
        ),
        run_native_motion_receiver(
            connection,
            session_epoch,
            router,
            platform
        )
    )?;
    Ok(())
}
```

Each sender uses its own
`tokio::time::interval(MEDIA_POLL_INTERVAL)` with
`MissedTickBehavior::Skip`.

- [ ] **Step 4: Reserve audio egress headroom in the video barrier**

Add:

```rust
const AUDIO_EGRESS_RESERVE_BYTES: usize = 2 * 1_200;
```

Require
`video_bytes + AUDIO_EGRESS_RESERVE_BYTES` before fresh video enqueue and
`send_buffer_capacity - AUDIO_EGRESS_RESERVE_BYTES` for the video-only
capacity ceiling. Drop the complete video object when the reserve cannot be
preserved.

- [ ] **Step 5: Add and run the reserve tests**

Test that a video object leaves exactly 2,400 bytes unused and that audio sends
while a video barrier remains pending:

```bash
cargo test -p lumen-host server::media::tests -- --nocapture
```

Expected: all media scheduler tests PASS.

- [ ] **Step 6: Commit the independent scheduler**

```bash
git add engine/lumen-host/src/server/media.rs
git commit -m "fix(streaming): Isolate realtime audio scheduling" \
  -m "- Poll and send five-millisecond Opus packets independently from video queue barriers." \
  -m "- Preserve bounded audio egress headroom before admitting complete video objects." \
  -m "- Prove suspended video delivery cannot delay ready audio packets."
```

---

### Task 2: Replace diagnostic-only feedback with an adaptive controller

**Files:**
- Create: `engine/lumen-host/src/control/adaptive_video.rs`
- Modify: `engine/lumen-host/src/control.rs`
- Modify: `engine/lumen-host/src/control/native_session.rs`
- Modify: `engine/lumen-host/src/control/tests.rs`
- Modify: `engine/lumen-host/src/server/quic.rs`

**Interfaces:**
- Produces:
  `AdaptiveVideoDeliveryController::observe(MediaFeedbackSample) -> AdaptiveVideoDecision`
- Produces:
  `AdaptiveVideoDecision { wire_budget_kbps, encoder_bitrate_kbps, fec_percentage, changed }`
- Consumes: 250 ms audio and video `MediaFeedback`

- [ ] **Step 1: Write failing controller tests**

Cover exact literal outcomes:

```rust
assert_eq!(severe.encoder_bitrate_kbps, 64_000);
assert_eq!(transport.encoder_bitrate_kbps, 72_000);
assert_eq!(stable_after_eight.encoder_bitrate_kbps, 84_000);
assert_eq!(audio_drop.congestion_source, CongestionSource::Audio);
assert_eq!(no_loss.fec_percentage, 5);
```

Use an 80,000 kbps ceiling so the 20%, 10%, and 5% steps are independently
hand-checkable.

- [ ] **Step 2: Run focused tests and observe RED**

```bash
cargo test -p lumen-host adaptive_video -- --nocapture
```

Expected: FAIL because `AdaptiveVideoDeliveryController` does not exist.

- [ ] **Step 3: Implement typed feedback samples**

Define:

```rust
pub(crate) enum FeedbackStream {
    Audio,
    Video,
}

pub(crate) struct MediaFeedbackSample {
    pub(crate) stream: FeedbackStream,
    pub(crate) expected_datagrams: u32,
    pub(crate) received_datagrams: u32,
    pub(crate) unrecoverable_objects: u32,
    pub(crate) late_objects: u32,
    pub(crate) decoder_queue_depth: u32,
    pub(crate) presentation_drops: u32,
}
```

Calculate `expected_datagrams` from the inclusive sequence span. Never add
object counts to `received_datagrams`.

- [ ] **Step 4: Implement controller hysteresis**

Use exact transitions from the design:

```rust
let factor = match severity {
    CongestionSeverity::Severe => 80,
    CongestionSeverity::Transport => 90,
    CongestionSeverity::Clean if self.clean_windows >= 8 => 105,
    _ => 100,
};
```

Clamp the wire budget to `ceiling / 4 ... ceiling`, clamp FEC to `5 ... 30`,
and derive encoder bitrate with:

```rust
wire_budget_kbps.saturating_mul(100) / u32::from(100 + fec_percentage)
```

- [ ] **Step 5: Return decisions from the control router**

Change the disposition to:

```rust
pub(crate) enum NativeMediaFeedbackDisposition {
    Applied(AdaptiveVideoDecision),
    Unchanged,
}
```

Audio feedback must enter the same controller instead of returning neutrally.

- [ ] **Step 6: Run controller and control-router tests**

```bash
cargo test -p lumen-host control:: -- --nocapture
```

Expected: controller and router tests PASS with audio-triggered video yielding.

- [ ] **Step 7: Commit the controller**

```bash
git add engine/lumen-host/src/control.rs \
  engine/lumen-host/src/control/adaptive_video.rs \
  engine/lumen-host/src/control/native_session.rs \
  engine/lumen-host/src/control/tests.rs \
  engine/lumen-host/src/server/quic.rs
git commit -m "feat(streaming): Adapt video delivery from media feedback" \
  -m "- Derive datagram loss from sequence spans without mixing object and datagram units." \
  -m "- Let audio continuity and video presentation pressure drive one hysteretic wire budget." \
  -m "- Preserve the negotiated frame cadence while adapting encoder bitrate and FEC."
```

---

### Task 3: Apply adaptive bitrate to the live macOS VideoToolbox session

**Files:**
- Modify: `engine/lumen-host/src/platform.rs`
- Modify: `engine/lumen-host/src/platform/macos.rs`
- Modify: `src/platform/macos/Projects/LumenMacBridge/Sources/LumenBridgeRuntime+VideoControl.swift`
- Modify: `src/platform/macos/Projects/LumenMacBridge/Sources/LumenBridgeObjCFacade.swift`
- Modify: `src/platform/macos/Projects/LumenMacBridge/Sources/LumenEncodedCaptureSession.swift`
- Modify: `src/platform/macos/Projects/LumenMacBridge/Sources/LumenScreenCaptureVideoEncoding.swift`
- Test: `tests/tuist/macos/LumenCaptureSessionLifecycleTests.swift`
- Test: `engine/lumen-host/src/platform.rs`

**Interfaces:**
- Consumes:
  `PlatformControlEvent::SetVideoBitrateKbps { bitrate_kbps: u32 }`
- Produces:
  `LumenMacBridgeSetVideoBitrateKbps(_ bitrateKbps: UInt32) -> Bool`
- Produces:
  `LumenEncodedCaptureSession.updateVideoBitrateKbps(_:) async -> Bool`

- [ ] **Step 1: Write failing Rust and Swift bridge tests**

The Rust callback test must observe the exact `bitrate_kbps`. The Swift test
must inject a property setter and assert:

```swift
XCTAssertEqual(recordedAverageBitrates, [64_000_000])
XCTAssertEqual(recordedDataRateLimits, [[8_000_000, 1]])
XCTAssertEqual(factory.makeCount, 1)
```

- [ ] **Step 2: Run the focused tests and observe RED**

```bash
cargo test -p lumen-host platform::tests -- --nocapture
cd src/platform/macos
tuist generate --no-open
tuist xcodebuild test \
  -workspace Lumen.xcworkspace \
  -scheme LumenTuistTests \
  -destination 'platform=macOS' \
  -only-testing:LumenTuistTests/LumenCaptureSessionLifecycleTests
```

Expected: FAIL because the event and bridge operation do not exist.

- [ ] **Step 3: Add the typed platform event and C bridge**

Add:

```rust
PlatformControlEvent::SetVideoBitrateKbps { bitrate_kbps: u32 }
```

Load and call a new `SetVideoBitrate` C symbol from `MacBridgeApi`.

- [ ] **Step 4: Apply properties on the existing encoder queue**

In the active encoder runtime:

```swift
try setProperty(
    kVTCompressionPropertyKey_AverageBitRate,
    value: (bitrateKbps * 1_000) as CFNumber
)
try setProperty(
    kVTCompressionPropertyKey_DataRateLimits,
    value: [
        Int(bitrateKbps * 1_000 / 8),
        1,
    ] as CFArray
)
```

Do not create or invalidate a compression session and do not change
`ExpectedFrameRate`.

- [ ] **Step 5: Dispatch changed decisions after releasing the router lock**

In the telemetry stream, copy the decision out of the router and then call:

```rust
platform.handle_control_event(
    session_epoch,
    PlatformControlEvent::SetVideoBitrateKbps {
        bitrate_kbps: decision.encoder_bitrate_kbps,
    },
)?;
```

Never invoke the platform bridge while holding the control-router mutex.

- [ ] **Step 6: Run focused Rust and Swift tests**

Run the commands from Step 2. Expected: PASS and one encoder creation.

- [ ] **Step 7: Commit the live bitrate bridge**

```bash
git add engine/lumen-host/src/platform.rs \
  engine/lumen-host/src/platform/macos.rs \
  src/platform/macos/Projects/LumenMacBridge/Sources \
  tests/tuist/macos/LumenCaptureSessionLifecycleTests.swift
git commit -m "feat(macos): Apply adaptive VideoToolbox bitrate" \
  -m "- Forward changed congestion decisions through the typed platform control boundary." \
  -m "- Update average bitrate and burst limits on the existing compression session." \
  -m "- Preserve negotiated resolution and frame cadence without encoder recreation."
```

---

### Task 4: Feed Shadow audio playback pressure back to Lumen

**Files:**
- Modify: `/Users/skyline23/code/shadow-client/Projects/App/Features/LumenRealtimeSession/Sources/ShadowClientLumenRealtimeSessionModule.swift`
- Modify: `/Users/skyline23/code/shadow-client/Projects/App/Features/StreamingTransport/Sources/ShadowClientLumenV4SessionRuntime.swift`
- Modify: `/Users/skyline23/code/shadow-client/Projects/App/Features/StreamingTransport/Sources/ShadowClientLumenV4MediaReceiver.swift`
- Test: `/Users/skyline23/code/shadow-client/Projects/App/Features/LumenRealtimeSession/Tests/Sources/ShadowClientLumenRealtimeSessionModuleTests.swift`
- Test: `/Users/skyline23/code/shadow-client/Projects/App/Features/StreamingTransport/Tests/Sources/ShadowClientLumenV4SessionRuntimeTests.swift`

**Interfaces:**
- Produces:
  `updateAudioFeedbackMetrics(decoderQueueDepth:presentationDrops:)`
- Consumes: lane pending count, trims, timeline resets, and
  `droppedForBackpressure`

- [ ] **Step 1: Write a failing feedback test**

Submit one backpressure drop and one lane trim, advance one 250 ms window, and
assert the audio feedback contains:

```swift
#expect(audioSnapshot.decoderQueueDepth == 3)
#expect(audioSnapshot.presentationDrops == 2)
#expect(videoSnapshot.presentationDrops == 0)
```

- [ ] **Step 2: Run and observe RED**

```bash
cd /Users/skyline23/code/shadow-client
tuist generate --no-open
tuist xcodebuild test \
  -workspace shadow-client.xcworkspace \
  -scheme ShadowClientStreamingTransportTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ShadowClientStreamingTransportTests/ShadowClientLumenV4SessionRuntimeTests
```

- [ ] **Step 3: Count consumer-visible audio drops**

Increment one monotonic playback-drop counter for
`.droppedForBackpressure`, decoder submission failure, lane trim, and timeline
reset. Publish only the per-window delta to transport.

- [ ] **Step 4: Attach metrics to the audio stream snapshot**

Use audio metrics for `plan.audioStreamID` and video metrics only for
`plan.videoStreamID`; reset each drop delta only after successful telemetry
send.

- [ ] **Step 5: Run both focused suites**

```bash
cd /Users/skyline23/code/shadow-client
tuist generate --no-open
tuist xcodebuild test \
  -workspace shadow-client.xcworkspace \
  -scheme ShadowClientStreamingTransportTests \
  -destination 'platform=macOS,arch=arm64'
tuist xcodebuild test \
  -workspace shadow-client.xcworkspace \
  -scheme ShadowClientLumenRealtimeSessionTests \
  -destination 'platform=macOS,arch=arm64'
```

Expected: PASS with stream-specific feedback.

- [ ] **Step 6: Commit Shadow feedback**

```bash
git add Projects/App/Features/LumenRealtimeSession \
  Projects/App/Features/StreamingTransport
git commit -m "feat(streaming): Report realtime audio pressure" \
  -m "- Count playback backpressure, lane trims, and timeline resets as consumer-visible drops." \
  -m "- Attach audio queue depth and drop deltas to the audio feedback stream." \
  -m "- Keep video and audio feedback windows independently owned."
```

---

### Task 5: Bound consecutive repair bootstraps

**Files:**
- Modify: `engine/lumen-host/src/control/native_session.rs`
- Test: `engine/lumen-host/src/control/tests.rs`
- Modify: `/Users/skyline23/code/shadow-client/Projects/App/Features/StreamingTransport/Sources/ShadowClientLumenV4SessionRuntime.swift`
- Test: `/Users/skyline23/code/shadow-client/Projects/App/Features/StreamingTransport/Tests/Sources/ShadowClientLumenV4SessionRuntimeTests.swift`

**Interfaces:**
- Produces:
  `VideoRepairCadence::admit(now: ContinuousClock.Instant, reason:)`
- Initial/configuration bootstrap bypasses the cadence.
- Consecutive repair generations require 500 ms separation.

- [ ] **Step 1: Write failing literal cadence tests**

Prove repair requests at 0 ms and 499 ms produce one host request, a request at
500 ms produces the second, and two seconds of clean feedback resets the
cadence.

- [ ] **Step 2: Run focused tests and observe RED**

```bash
cargo test -p lumen-host repair_cadence -- --nocapture
cd /Users/skyline23/code/shadow-client
tuist generate --no-open
tuist xcodebuild test \
  -workspace shadow-client.xcworkspace \
  -scheme ShadowClientStreamingTransportTests \
  -destination 'platform=macOS,arch=arm64'
```

- [ ] **Step 3: Implement repair-only cooldown**

Keep the most recent `afterFrameID` while the cooldown is closed. Send it when
the cooldown opens. Never delay `.initial` or `.configurationChange`.

- [ ] **Step 4: Run focused tests and commit each repository**

Expected: repair traffic is bounded, while a terminal decoder error still
terminates the session.

---

### Task 6: Add the same-Mac 90% fidelity runner

**Files:**
- Create: `engine/lumen-host/examples/audio_fidelity_loopback.rs`
- Modify: `engine/lumen-host/Cargo.toml`
- Create: `tests/fixtures/audio-fidelity/README.md`
- Create: `/Users/skyline23/code/shadow-client/Projects/App/Features/NativeAudio/Tests/Sources/ShadowClientLumenAudioFidelityTests.swift`
- Create: `/Users/skyline23/code/shadow-client/Scripts/verify-lumen-audio-fidelity.sh`
- Modify: `/Users/skyline23/code/shadow-client/Projects/App/Features/NativeAudio/Tests/Sources/ShadowClientLumenAudioTransportIntegrationTests.swift`

**Interfaces:**
- Lumen sender arguments:
  `--port-file`, `--report-dir`, `--duration-seconds 10`,
  `--video-pressure`
- Shadow test environment:
  `LUMEN_AUDIO_LOOPBACK_PORT`, `LUMEN_AUDIO_REPORT_DIR`
- Report:
  `audio-fidelity-result.json`

- [ ] **Step 1: Replace the one-packet test with a failing ten-second gate**

Generate deterministic stereo samples:

```swift
left[n] = 0.35 * sin(2 * .pi * 440 * Double(n) / 48_000)
right[n] = 0.30 * sin(2 * .pi * 997 * Double(n) / 48_000)
```

Require:

```swift
#expect(result.sourceFrameCoverage >= 0.90)
#expect(result.normalizedCorrelation >= 0.90)
#expect(result.maximumConsecutiveMissingMilliseconds <= 20)
#expect(result.timelineResets == 0)
```

- [ ] **Step 2: Run the Shadow test and observe RED**

Expected: FAIL because no loopback source or fidelity result exists.

- [ ] **Step 3: Implement the Lumen loopback fixture**

Use the real `LumenMacOpusEncoderCreate`/encode/destroy bridge and
`NativeMediaPacketizer`. Send production v4 datagrams to `127.0.0.1` at the
real 5 ms cadence. In `--video-pressure` mode, run the production video
capacity barrier with repeated 512 KB synthetic frames on a sibling task.

- [ ] **Step 4: Implement Shadow PCM alignment and metrics**

Cross-correlate within a 100 ms alignment window, normalize each channel by
RMS, count decoded source frames by object ID, and exclude PLC frames from
source-frame coverage while retaining them in the maximum-gap report.

- [ ] **Step 5: Implement the one-pass runner**

The script must use `mktemp -d`, start the Lumen fixture, wait for the port
file, run the Shadow test, wait for the sender, and print the JSON report. It
must preserve artifacts on failure and exit nonzero below any threshold.

Run:

```bash
Scripts/verify-lumen-audio-fidelity.sh \
  --lumen-repo /Users/skyline23/code/Lumen
```

Expected report fields:

```json
{
  "source_frame_coverage": 0.9,
  "normalized_correlation": 0.9,
  "maximum_consecutive_missing_ms": 20,
  "timeline_resets": 0,
  "video_pressure": true
}
```

The actual values must meet or exceed the thresholds; the literals above are
the gates, not fabricated results.

- [ ] **Step 6: Commit the fixture and verifier in their owning repositories**

Use `test(streaming): Add same-Mac audio fidelity gate` in both repositories
with repository-specific bullet bodies.

---

### Task 7: Full verification, builds, and one live session

**Files:**
- No new production files.
- Update generated validation artifacts only when the project already tracks
  them.

**Interfaces:**
- Consumes all preceding tasks.
- Produces final automated and live evidence.

- [ ] **Step 1: Run complete Lumen verification**

```bash
cargo test --workspace
cd src/platform/macos
tuist generate --no-open
tuist xcodebuild test \
  -workspace Lumen.xcworkspace \
  -scheme LumenTuistTests \
  -destination 'platform=macOS'
```

- [ ] **Step 2: Run complete Shadow verification**

Use the repository's complete `tuist xcodebuild test` command, then run:

```bash
Scripts/verify-lumen-audio-fidelity.sh \
  --lumen-repo /Users/skyline23/code/Lumen
```

- [ ] **Step 3: Build signed Release applications**

Generate with Tuist and build Lumen using Apple Development team
`Q23JLSJCCV`. Build Shadow for the connected iPad using the hardware UDID.

- [ ] **Step 4: Install Lumen and deploy Shadow**

Back up the previous installed Lumen app, install only the verified Release,
and launch it. Deploy the verified Shadow build to the iPad.

- [ ] **Step 5: Run one live connection**

Run exactly one connect/play-video/end-session cycle. Record:

- audio playback continuity
- capture, decode, and presented FPS
- adaptive bitrate and FEC transitions
- bootstrap count
- audio drop and timeline-reset counts
- terminal physical-display restoration

- [ ] **Step 6: Audit every acceptance criterion**

Do not claim completion unless the same-Mac report passes both 90% gates, no
performance regression is observed, adaptive bitrate reaches VideoToolbox,
and the single live session restores the physical display.
