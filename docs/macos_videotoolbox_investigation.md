# macOS VideoToolbox Investigation

## Why this path was investigated

Lumen on macOS is currently able to:

- boot as an `.app`
- initialize the tray and Web UI
- negotiate RTSP, audio, and control successfully
- negotiate `hevc_videotoolbox` as a valid encoder

The remaining failure is in the first real video frame submission on macOS.

This investigation initially focused on the FFmpeg-backed macOS hardware path instead of falling back to software encoding because:

- the goal is low-latency desktop streaming on macOS
- CPU/software encode is not an acceptable long-term answer for this target
- the failure appears to be in the FFmpeg `hevc_videotoolbox` submission path, not in RTSP, audio, permissions, or discovery

## Current confirmed behavior

The macOS host currently succeeds through these stages:

1. display enumeration
2. VideoToolbox encoder probing
3. RTSP session setup
4. audio/control startup
5. first captured frame preparation

Recent host logs show the following sequence:

- `Video thread established UDP peer [...]`
- `Starting video capture`
- `Preparing initial video frame for synced session`
- `Initial video frame prepared for synced session`
- `push_captured_image_callback ...`
- `Converted captured image for synced session`
- `About to encode synced video packet frame_nr=1`
- `encode_avcodec send_frame start frame_nr=1 codec=hevc_videotoolbox`

The process crashes immediately after entering `avcodec_send_frame(...)`.

## What this means

This rules out several earlier theories:

- not a login issue
- not a discovery issue
- not an RTSP negotiation issue
- not an audio startup issue
- not a "no captured frame at all" issue

The active problem is now narrowed to:

`ScreenCaptureKit frame -> FFmpeg frame -> hevc_videotoolbox send_frame()`

## Current technical suspicion

The strongest current suspicion is that Lumen's direct VideoToolbox frame setup does not match the contract expected by FFmpeg's `hevc_videotoolbox` wrapper.

Observed state before the crash has included:

- `frame->format = AV_PIX_FMT_VIDEOTOOLBOX`
- `ctx->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX`
- `frame->data[3]` populated from a `CVPixelBufferRef`
- inconsistent `hw_frames_ctx` state between frame/context during some attempts

Even after reducing callback/lifetime risks, the crash still occurs at the first `avcodec_send_frame()`.

## Conclusion

This investigation narrowed the failure enough to justify moving away from FFmpeg's macOS `videotoolbox` wrapper path.

The current conclusion is:

- Lumen reaches the first real HEVC frame
- the crash still occurs inside the first `avcodec_send_frame()`
- the unstable point is specifically the FFmpeg `hevc_videotoolbox` submission path on macOS

For that reason, the macOS direction is being changed to:

- `ScreenCaptureKit` for capture
- `Metal` for frame processing
- native `VTCompressionSession` for encode

The notes below remain useful as historical evidence for why the FFmpeg wrapper path is being replaced.

## Why not stay on the FFmpeg wrapper path

A macOS-native `VTCompressionSession` path is a larger implementation change, but the FFmpeg wrapper path has now failed at the exact point where the first real frame is submitted.

That makes the wrapper path a poor foundation for the DMG-quality macOS host.

Before switching, it was still useful to document whether the failure was:

- a bad frame layout
- a bad FFmpeg VideoToolbox expectation mismatch
- a lifecycle / ownership issue
- a limitation of the current wrapper path

That information will be useful even if Lumen later moves to a direct `VTCompressionSession` implementation.

## Investigation strategy

The investigation should continue in this order:

1. log the exact frame/context state immediately before `avcodec_send_frame()`
2. log the direct VideoToolbox frame setup in `nv12_zero_device::set_frame()` and `convert()`
3. verify whether `frame->hw_frames_ctx`, `buf[0]`, and `data[3]` match FFmpeg's expected VideoToolbox input contract
4. determine whether the crash is caused by:
   - FFmpeg wrapper assumptions
   - incorrect frame ownership/state
   - unsupported direct-frame submission pattern
5. use the findings to replace macOS encode with direct `VTCompressionSession`

## Current status

At the time of this note:

- Lumen no longer fails in startup probing
- Lumen no longer fails before the first real frame
- the remaining crash happens on the first HEVC `avcodec_send_frame()`
- the project is moving to native macOS `VTCompressionSession` encode instead of continuing to debug the FFmpeg wrapper path

This document exists so later changes are grounded in what has already been proven, instead of re-litigating earlier hypotheses.
