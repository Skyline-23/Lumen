# ShadowVC product integration

The optional ShadowVC codec uses the shared `ShadowVCRuntime` package at an
immutable Git revision in `src/platform/macos/Project.swift`. The model is stored
separately in the private Hugging Face repository
`Skyline23/shadowvc-fc3-spatial-base16-v1` at
`0669d0b6c387fa48f07baab85cfe7584fce57369`.
Its manifest SHA256 is
`8bd6f8475e8a7c041e76c255219940654a9402bb1f00a5ddaf150563d81176c8`.

Authenticate the build machine using `hf auth login`, then run the shared
repository's `tools/fetch_runtime_model.py --output <Lumen>/artifacts/ShadowVCModels`.
The existing native-assets build stage includes that verified directory in the
signed app. Credentials are never included. The runtime validates every file
and all three model-tree hashes before capture starts.

Codec 4/profile 9 must be selected explicitly: macOS 27 on Apple Silicon, even
native pixels up to 3840x2160, SDR BT.709 limited-range YUV420 10-bit. Capture
rejects mismatched native display dimensions. The independent SCV1 bitstream is
carried through the existing sample-buffer bridge and native QUIC normalizer;
it is never interpreted as H.264, HEVC or AV1. Bootstrap ACK and media-epoch
fencing still apply. Fixed q52 does not implement bitrate adaptation.

Validation artifacts are in `artifacts/fc3-*`. The standalone 100.89 FPS sender
result excludes capture/network/display and is not a product performance claim.
The opt-in `LumenShadowVCCaptureTests` uses an independent 4K virtual display and
writes actual capture-to-encoded-frame counts and bytes. It does not validate
remote-client presentation. Enable it with `TEST_RUNNER_LUMEN_SHADOWVC_LIVE_TEST=1`
and the normal `tuist xcodebuild test` wrapper. It skips if screen-recording
access is absent, rather than opening a permission dialog.

On 2026-09-06 the signed LumenApp build passed, as did 220 engine and 326 host
Rust tests and the contract generator check. Focused bridge/backend tests
passed. The opt-in capture test reached its permission preflight but was skipped
because the XCTest runner lacks screen-recording access. Therefore there is no
measured product capture FPS or remote presentation acceptance for this revision.
The remaining performance gate is average displayed FPS above 100 with native
4K stimulus, frame identity, drops, bytes and presentation timing recorded.
