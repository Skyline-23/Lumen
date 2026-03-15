# macOS DMG Delivery Plan

## Goal

Ship Apollo as a macOS `.app` distributed inside a DMG, with native screen capture, native system audio capture, and hardware-accelerated low-latency video encoding.

This plan assumes the fork will treat macOS as a first-class target instead of keeping the current "experimental" status.

## Product Definition

### Primary Outcome

The first supported macOS release should allow a user to:

1. Download a DMG.
2. Drag Apollo into Applications.
3. Launch the app without terminal setup.
4. Grant the required permissions through guided UX.
5. Start a stream with:
   - screen capture
   - native system audio capture
   - optional microphone capture
   - VideoToolbox hardware encoding

### Explicit Non-Goals for v1

The first DMG release should not block on these:

- gamepad support
- virtual display support
- Windows feature parity in display device management
- AV1 as the default codec path
- complex multi-display orchestration
- legacy macOS support below the chosen minimum target

## Architectural Direction

### Keep

These parts already provide value and should remain the base of the fork:

- session lifecycle
- RTSP / streaming control flow
- web UI and configuration system
- app launching / process management
- FFmpeg integration for non-macOS paths and general media utilities
- platform abstraction in `src/platform/common.h`

### Replace

These macOS-specific parts should be considered rewrite targets:

- `src/platform/macos/av_video.m`
- `src/platform/macos/av_audio.m`
- `src/platform/macos/microphone.mm`
- portions of `src/platform/macos/display.mm`
- macOS FFmpeg `videotoolbox` encode bridge inside `src/video.cpp`
- permission handling in `src/platform/macos/misc.mm`
- macOS packaging in `cmake/packaging/macos.cmake`

### Target Capture Pipeline

The macOS pipeline for the DMG release should be:

- capture backend: `ScreenCaptureKit`
- frame processing: `Metal`
- system audio capture: `ScreenCaptureKit` audio output
- microphone capture: `ScreenCaptureKit` microphone path or AVFoundation fallback
- hardware video encode: native `VTCompressionSession`
- audio encode: existing Opus path in `src/audio.cpp`

This keeps the current session/control/audio stack while replacing the macOS video path end-to-end.

## Platform Strategy

### Minimum macOS Version

Recommended target: `macOS 15+`

Reasoning:

- reduces compatibility branching
- aligns with modern `ScreenCaptureKit` usage
- makes DMG-based app distribution simpler than carrying older capture fallbacks
- avoids spending the first release budget on legacy support

If later needed, support for older versions can be reintroduced deliberately rather than implicitly inherited.

### Delivery Format

Primary deliverable: signed `.app` inside a DMG

Secondary internal artifact: unsigned local `.app` for development smoke testing

Distribution expectations:

- drag-and-drop install flow
- stable app bundle metadata
- permission prompts working from bundled app context
- future-ready for codesign and notarization

## Workstreams

## 1. Capture Backend Rewrite

### Objective

Replace the current macOS screen capture implementation with `ScreenCaptureKit`.

### Why

The old Objective-C screen capture path and the FFmpeg `hevc_videotoolbox` wrapper have both proven too fragile for a product-quality macOS host.

### Scope

- enumerate displays with `SCShareableContent`
- select a display by stable identifier
- create `SCContentFilter`
- create `SCStreamConfiguration`
- stream video sample buffers into the existing display abstraction
- expose compatibility with current `display_t` contract

### Files

Likely new files:

- `src/platform/macos/capture_sck.h`
- `src/platform/macos/capture_sck.mm`

Likely modified files:

- `src/platform/macos/display.mm`
- `src/platform/macos/misc.mm`
- `cmake/compile_definitions/macos.cmake`

### Design Notes

- keep `display_t` as the platform-facing contract
- move Objective-C / Objective-C++ stream lifecycle into a dedicated `capture_sck` object
- keep `display.mm` thin and focused on frame handoff
- prefer latest-frame behavior over deep buffering
- start with single-display capture only
- do not rely on FFmpeg `*_videotoolbox` encoders for the macOS host path

### Acceptance Criteria

- selected display appears in config and resolves correctly
- screen capture starts without using terminal-specific launch flow
- frames reach the existing encode path
- no indefinite hangs on permission denial

## 2. Native Video Encode Path

### Objective

Replace the macOS FFmpeg `videotoolbox` wrapper path with a native `VTCompressionSession` implementation.

### Why

The current macOS host can negotiate RTSP/audio/control successfully, but the first real HEVC frame consistently crashes inside FFmpeg's `hevc_videotoolbox` `avcodec_send_frame()` path. That makes the wrapper path an unreliable foundation for the DMG release.

### Scope

- create a macOS-only encoder implementation backed by `VTCompressionSession`
- feed it frames sourced from `ScreenCaptureKit`, with optional `Metal` preprocessing
- extract VPS/SPS/PPS / sample attachments required by the current packetization logic
- preserve existing Apollo session/control/transport behavior
- keep H.264 and HEVC support; AV1 remains non-goal for v1

### Files

Likely new files:

- `src/platform/macos/vt_encode.h`
- `src/platform/macos/vt_encode.mm`
- `src/platform/macos/metal_convert.h`
- `src/platform/macos/metal_convert.mm`

Likely modified files:

- `src/video.cpp`
- `src/video.h`
- `src/platform/macos/display.mm`

### Acceptance Criteria

- first HEVC frame no longer crashes
- repeated stream start/stop works
- H.264 and HEVC both encode through native `VTCompressionSession`
- Apollo continues using the current transport/session stack

## 3. Native System Audio Capture

### Objective

Eliminate BlackHole / Soundflower as the default user path for macOS audio streaming.

### Why

The DMG release must work as a desktop product, not as a "developer setup plus virtual audio driver" tool.

### Scope

- capture system audio using `ScreenCaptureKit` audio output
- optionally capture microphone input
- convert audio sample buffers into the float sample format expected by `src/audio.cpp`
- keep Opus encoding unchanged

### Files

Likely new files:

- `src/platform/macos/audio_sck.h`
- `src/platform/macos/audio_sck.mm`

Likely modified files:

- `src/platform/macos/microphone.mm`
- `src/platform/macos/av_audio.m`
- `src/audio.cpp`
- `src/config.h`
- `src/config.cpp`

### Config Model

Recommended mac-specific additions:

- `mac_audio_backend = native`
- `mac_audio_mode = system | microphone | system_and_microphone`
- `mac_exclude_self_audio = true | false`

This is better than overloading `audio_sink` with meanings that no longer fit a native macOS implementation.

### Acceptance Criteria

- system audio streams without third-party virtual audio software
- microphone capture remains available
- user can enable or disable microphone separately
- audio starts and stops cleanly across repeated sessions

## 4. Permission and Onboarding UX

### Objective

Turn macOS permissions from a hidden failure mode into a guided setup flow.

### Required Permissions

- Screen Recording
- Microphone
- Audio Capture

### Required App Metadata

At minimum, `Info.plist` will need:

- `NSMicrophoneUsageDescription`
- `NSAudioCaptureUsageDescription`

Additional messaging should be tailored for a streaming host, not generic recording text.

### Implementation Direction

- collect permission state during platform init
- report missing permissions through logs and UI
- request at appropriate points instead of only failing deep in capture startup
- provide a clear restart / retry path after permission approval

### Files

Likely modified files:

- `src/platform/macos/misc.mm`
- `src/platform/macos/misc.h`
- `src/main.cpp`
- `src_assets/macos/assets/Info.plist`
- web UI config/status files under `src_assets/common/assets/web`

### Acceptance Criteria

- first launch clearly explains what is missing
- permission prompts use app-bundle context
- denied permissions do not deadlock capture startup
- app can recover after the user enables permissions in System Settings

## 4. VideoToolbox Latency Tuning

### Objective

Keep VideoToolbox as the default hardware encoding path and tune it for low latency.

### Existing Strength

The project already has a functional `videotoolbox` encoder path and should build on that instead of replacing it.

### Scope

- validate H.264 and HEVC stability first
- keep `realtime` behavior enabled where appropriate
- minimize queue depth and reference frame count
- validate `NV12` and `P010` input paths
- postpone AV1 default enablement until after baseline stability

### Files

Likely modified files:

- `src/video.cpp`
- `src/platform/macos/display.mm`
- new `ScreenCaptureKit` bridge files

### Acceptance Criteria

- 1080p60 H.264 runs stably on supported Macs
- HEVC path works on supported hardware
- latency remains within acceptable range for interactive streaming
- no unnecessary software conversion in the steady-state hot path

## 5. Web UI and Configuration Changes

### Objective

Make the product reflect native macOS behavior instead of showing Linux/Windows-centric guidance.

### Current Problem

The UI still tells macOS users to install Soundflower or BlackHole, which conflicts with the native capture goal.

### Scope

- add mac-native audio mode options
- surface permission status
- remove or demote raw sink text fields for standard mac usage
- expose chosen display and audio mode clearly
- keep advanced options separate from the common path

### Files

Likely modified files:

- `src_assets/common/assets/web/configs/tabs/AudioVideo.vue`
- `src_assets/common/assets/web/configs/tabs/audiovideo/DisplayOutputSelector.vue`
- `src_assets/common/assets/web/configs/tabs/audiovideo/DisplayDeviceOptions.vue`
- locale files under `src_assets/common/assets/web/public/assets/locale/`
- `src/config.h`
- `src/config.cpp`

### Acceptance Criteria

- a mac user can configure capture without knowing audio device internals
- native audio capture is the obvious default path
- permissions are visible and actionable

## 6. App Bundle and DMG Packaging

### Objective

Produce a reliable macOS application bundle and DMG suitable for distribution.

### Scope

- build a valid `.app`
- ensure bundle resources are copied correctly
- ensure Info.plist is correct for runtime permissions
- generate a drag-and-drop DMG
- prepare for codesign and notarization

### Packaging Phases

#### Phase A: Local Developer Packaging

- unsigned `.app`
- local DMG generation
- manual launch and permission verification

#### Phase B: Release Packaging

- app icon / branding cleanup
- codesign
- notarization
- stapled DMG

### Files

Likely modified files:

- `cmake/packaging/macos.cmake`
- `cmake/targets/macos.cmake`
- `cmake/compile_definitions/macos.cmake`
- `src_assets/macos/assets/Info.plist`
- any new asset or helper script files under `src_assets/macos/`

### Acceptance Criteria

- `cpack -G DragNDrop` produces a usable DMG
- the installed app launches from `/Applications`
- runtime resources resolve correctly from the app bundle
- permission prompts appear as expected from the bundled app

## Delivery Phases

## Phase 0: Foundation

- choose minimum macOS target
- finalize v1 scope
- define config additions
- define permission model
- make local `.app` buildable

## Phase 1: Video-Only Native Capture

- `ScreenCaptureKit` display enumeration
- single-display capture
- VideoToolbox encode path validation
- no native system audio yet

Milestone:

- bundled app can stream video only

## Phase 2: Native Audio

- system audio capture
- microphone capture option
- audio mode configuration
- permission UX for audio capture

Milestone:

- bundled app can stream video + system audio

## Phase 3: DMG-Ready UX

- UI cleanup
- mac-specific onboarding copy
- error handling and retry flows
- local DMG artifact

Milestone:

- test user can install via DMG and complete setup

## Phase 4: Release Hardening

- codesign
- notarization
- QA pass on Intel and Apple Silicon if available
- release notes and support docs

Milestone:

- public DMG release candidate

## Risk Register

### Technical Risks

- sample format mismatch between `ScreenCaptureKit` output and the current ingest path
- synchronization issues between system audio and microphone paths
- permission changes not being picked up without app restart
- app bundle runtime resource lookup issues
- hardware-specific encode behavior differences across Macs

### Product Risks

- trying to carry gamepad or virtual display into v1
- trying to support too many macOS versions at once
- exposing too many low-level options in the first DMG release

### Mitigations

- ship video-only first internally
- keep native system audio as a distinct milestone
- keep the first DMG narrow and reliable
- test the app only from bundle context, not just from terminal

## Definition of Done for the First DMG

The first DMG release is done when all of the following are true:

1. A user can install Apollo from a DMG by dragging the app into Applications.
2. The app launches without terminal setup.
3. The app clearly guides the user through required macOS permissions.
4. Screen capture works through `ScreenCaptureKit`.
5. System audio capture works natively, without BlackHole or Soundflower.
6. Optional microphone capture works.
7. VideoToolbox H.264 is stable for interactive streaming.
8. The app survives repeated start/stop cycles without capture deadlocks.
9. Logs and UI provide enough information to diagnose permission failures.

## Recommended First Implementation Slice

The best first code slice for this fork is:

1. Add missing macOS permission metadata to the app bundle.
2. Introduce a `ScreenCaptureKit` video-only backend.
3. Connect that backend to the existing `display_t` and VideoToolbox path.
4. Verify a bundled `.app` can launch and capture video.

This gives a hard proof that the macOS fork direction works before system audio and DMG polish consume more time.
