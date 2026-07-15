## Lumen HDR120 / HEVC Autoresearch Rules

- Use the native `$auto-research-codex` loop when the user explicitly asks for automatic autoresearch or names the skill. Do not keep a stale manual-only policy active after that.
- Manual loop fallback means: make one focused experiment, commit it, run the metric manually, keep only if it beats the current best and has no HDR/drop/stability regression, otherwise revert the experiment commit.
- Every experiment, including discarded ties, regressions, crashes, and reverted commits, must append a concise record to `results.tsv` and `.codex-autoresearch/experiment_notes.md`: hypothesis, change, metric/result, why it failed or succeeded, verification evidence, and what the result means for future search.
- Failed experiment retrospectives must identify the first broken pipeline boundary before the next experiment: source ingress, pending admission, Metal stage, VT submit/admission, VT output callback, Lumen forwarding, HDR validation, drop/stability accounting, or test/build failure. Do not proceed from a failed metric using only the final score.
- Do not ask whether to continue when the user says short go-aheads like `ㅇㅇ`, `ㄱㄱ`, or `계속`; continue the active loop mode, whether native autoresearch or explicit manual fallback.
- Do not use `NSLock` for new coordination. Prefer actor-isolated state, or an existing serial queue only when the code is already queue-isolated and an actor would not fit the callback boundary.
- Do not add `targetFrameRate >= 100` or equivalent 100fps policy gates. High refresh is core to this project; do not make HEVC/HDR/low-latency behavior conditional on hitting a 100fps threshold.
- Do not lower bitrate, QP, quality, resolution, or frame rate to get a better score unless the user explicitly asks for that tradeoff. When a session negotiates HDR, do not downgrade that session merely to improve a score. Quality matters.
- The product baseline is H.264 SDR. HEVC Main, HEVC Main10, and HDR are optional capability-negotiated features, not release requirements.
- ProRes has been removed from the product and research scope. Do not reintroduce ProRes paths, proxies, probes, or fallback policy.
- Do not spend search budget on AV1 on this host/runtime. Current local evidence exposes no hardware AV1 encoder, so AV1 is closed unless a future machine/runtime actually exposes one and the user explicitly reopens that axis.
- Keep H.264 and HEVC paths structurally aligned where possible. Main10 and HDR divergence must be evidence-backed and capability-required, not an arbitrary guard.
- Treat `targetFrameRate >= 100` removals as cleanup, not optional style. If a high-refresh branch is needed, express the actual technical condition such as codec, HDR transfer, capture backend, or delivery mode.
- Current evidence: single HEVC VT session/admission remains the bottleneck around 101-102 frames in the 1s probe. Source and pending admission can get ahead of VT, Metal staging is not the dominant limiter, and the clearest pre-output bottleneck is serialized VT admission after Metal completion.
- Current bottleneck map: see `docs/hdr120-bottleneck-map.md` before proposing the next experiment.
- Avoid closed axes: simple VT knobs, per-frame/batched VT drains, source early release, host-drain cadence, naive temporal/spatial lanes, direct inline submit from Metal completion, and half-height probes did not beat the best.
- Current useful kept instrumentation: VT stage timing metrics in Lumen/MacDisplayKit expose queue wait, Metal stage, VT encode call, and output callback latency.

## Current Metric Command

Run from `/Users/skyline23/code/Lumen`:

```bash
python3 tools/autoresearch/eval_host_stream.py --workspace src/platform/macos/Lumen.xcworkspace --scheme LumenTuistTests --log "/Users/skyline23/Library/Application Support/Lumen/lumen.log" --target-width 3512 --target-height 2290 --target-fps 120 --codec-suite hevc --require-low-latency --battery-policy adaptive-hdr
```

## Swift Architecture Rules

- Use Swift Concurrency as the primary coordination model. Shared mutable state belongs in actors, and asynchronous workflows should use `async`/`await`, `Task`, or `AsyncStream` rather than new dispatch queues or callback fan-out.
- Keep Combine as a UI observation boundary only. `ObservableObject` and `@Published` may expose reduced state to SwiftUI, but service orchestration and domain event pipelines must not be built around Combine publishers.
- Use Pure DI. Construct concrete dependencies once in an explicit composition root such as `LumenAppContainer`, inject them through initializers, and do not add service locators, hidden singletons, or default arguments that construct production dependencies inside feature types.
- Preserve one-way data flow: `View -> Action -> Controller/Reducer -> Actor or Service -> State -> View`. Views must not mutate service state directly, and asynchronous service callbacks must be reduced into state on the owning actor before presentation.
- Keep platform and framework adapters behind injected protocols or narrow injected concrete boundaries. Core policy must remain testable without launching AppKit, the host worker, or a live capture session.
- New concurrency code must not use `NSLock`. Prefer actor isolation; retain an existing serial queue only at an unavoidable C/Objective-C callback boundary and document why actor isolation cannot own that boundary.
