Must read @/Users/skyline23/.codex/RTK.md

## Lumen HDR120 / HEVC Autoresearch Rules

- Do not enable or restart the native autoresearch hook unless the user explicitly asks for it. Current default is manual loop only.
- Manual loop means: make one focused experiment, commit it, run the metric manually, keep only if it beats the current manual best and has no HDR/drop/stability regression, otherwise revert the experiment commit.
- Do not ask whether to continue when the user says short go-aheads like `ㅇㅇ`, `ㄱㄱ`, or `계속`; continue the manual loop.
- Do not use `NSLock` for new coordination. Prefer actor-isolated state, or an existing serial queue only when the code is already queue-isolated and an actor would not fit the callback boundary.
- Do not add `targetFrameRate >= 100` or equivalent 100fps policy gates. High refresh is core to this project; do not make HEVC/HDR/low-latency behavior conditional on hitting a 100fps threshold.
- Do not lower bitrate, QP, quality, HDR, resolution, or frame rate to get a better score unless the user explicitly asks for that tradeoff. Quality matters.
- Do not route the solution through ProRes-only if Android/general client support is in scope. ProRes can be an Apple-client fast path, but HEVC Main10 remains required for broad hardware decode.
- Keep HEVC and ProRes paths structurally aligned where possible. If they diverge, the divergence must be evidence-backed and codec-required, not an arbitrary guard.
- Treat `targetFrameRate >= 100` removals as cleanup, not optional style. If a high-refresh branch is needed, express the actual technical condition such as codec, HDR transfer, capture backend, or delivery mode.
- Current evidence: single HEVC VT session is the bottleneck around 101-102 frames in the 1s probe; simple VT knobs, concurrent VT submit, source early release, naive two-lane, and half-height probes did not beat the best.
- Current useful kept instrumentation: VT stage timing metrics in Lumen/MacDisplayKit expose queue wait, Metal stage, VT encode call, and output callback latency.

## Current Metric Command

Run from `/Users/skyline23/Downloads/Lumen`:

```bash
rtk python3 tools/autoresearch/eval_host_stream.py --workspace src/platform/macos/Lumen.xcworkspace --scheme LumenTuistTests --log "/Users/skyline23/Library/Application Support/Lumen/lumen.log" --target-width 3512 --target-height 2290 --target-fps 120 --codec-suite hevc,prores-proxy --require-partial-hdr --require-low-latency --battery-policy adaptive-hdr
```

