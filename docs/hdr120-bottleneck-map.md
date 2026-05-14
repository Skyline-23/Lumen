# HDR120 HEVC Bottleneck Map

Last updated: 2026-05-14.

## Current Best

- Best score: 106.25.
- Stable HEVC shape: about 101-102 output frames in the 1 s probe.
- Stable submit shape: about 107-108 staged `VTCompressionSessionEncodeFrame` submissions when the source side is healthy.
- Contract: keep HEVC Main10, PQ HDR, target 3512x2290, 120 fps, low latency, and existing quality/bitrate policy. Do not trade quality or high refresh for score.

## Measured Pipeline

| Boundary | Representative measurement | Interpretation |
| --- | ---: | --- |
| Source ingress | 120 source frames in the earlier full diagnostic probe | Source can reach the target window; raw source availability is not the primary limiter. |
| Pending-frame admission | 102 acquire attempts, 102 acquired, 0 rejected in the lightweight submitQueue probe | Pending limit is not rejecting frames in the measured window. |
| Metal stage | 102 samples, avg 1.995 ms, max 5.755 ms in the lightweight submitQueue probe | Metal conversion is not the dominant wall-clock limiter in the current kept path. |
| Metal completion to VT submit queue | 102 samples, avg 16.616 ms, max 50.369 ms in the lightweight submitQueue probe | The largest newly isolated pre-VT-output bottleneck. Frames that finished Metal wait behind the serialized VT submit lane. |
| VT encode call | 102 samples, avg 6.247 ms, max 37.381 ms in the lightweight submitQueue probe | `VTCompressionSessionEncodeFrame` itself can occupy the submit lane long enough to accumulate queue wait. |
| VT submit to output callback | 100 output frames from 102 submissions, avg callback latency 55.112 ms, max 71.656 ms in the lightweight submitQueue probe | VT output latency still costs frames at the probe boundary. In healthy best-like runs this is usually about 101 from 107 submissions with about 67 ms callback latency. |
| Lumen forwarding ingress | 0 queued, 0 dropped in current probes | The Lumen bridge/forwarding queue is not the limiting stage. |

## Closed Or Low-Priority Axes

- Do not chase raw source availability unless source count, pending rejected count, or forwarding drops become nonzero in the same valid metric window.
- Do not repeat simple VT knobs: temporal compression disable, unretained command buffers, per-frame or batched `VTCompressionSessionCompleteFrames`, and diagnostic property deferral did not beat best.
- Do not repeat simple `submissionQueue` removal by calling VT directly from the Metal completion callback. Prior inline submit shifted blocking into the Metal-stage bucket without increasing useful submissions or outputs.
- Do not repeat naive temporal or spatial HEVC lane splitting under the current client/probe contract. It worsened callback latency or produced incomplete/dropped logical groups.
- Do not optimize host probe drain cadence. Faster drain destabilized measurement and did not reveal hidden encoder headroom.
- Be careful with detailed source diagnostics: forcing cadence/timing trackers on the hot path reduced source counts during measurement, so use them as diagnostic-only evidence, not a performance baseline.

## Failure Retrospective Protocol

Every discarded experiment has to answer "why did it fail?" before the next commit. The minimum review is:

| Question | Required evidence |
| --- | --- |
| Which boundary broke first? | Classify the first regression as source ingress, pending admission, Metal stage, VT submit/admission, VT output callback, Lumen forwarding, HDR validation, drop/stability accounting, or build/test failure. |
| Did it improve the intended stage? | Compare the targeted counters against the current baseline: HEVC frames, staged VT submissions, source count if available, Metal stage, VT encode call, VT callback latency, startup, queued/dropped frames, and drop events. |
| Did it preserve the contract? | Confirm HEVC Main10/PQ HDR, partial HDR requirement, target resolution, target fps, low latency, quality/bitrate policy, and ProRes suite health when applicable. |
| Why is it closed or still open? | State whether the axis is closed, invalid/inconclusive, or worth retrying only with a changed topology. |
| What should the next experiment avoid? | Record the concrete anti-repeat lesson in `.codex-autoresearch/experiment_notes.md`, not just in chat. |

Stability failures are usually not crashes in this campaign. If `DROP_EVENTS` is nonzero, trace the event source before interpreting the score. Current evidence points to MacDisplayKit source-frame drops when upstream admission gets ahead of VT submit/output and the pending window saturates; those drops enter the evaluator as stability penalties even when HDR and forwarding remain valid.

## Highest Priority Bottleneck

The best current explanation is serialized VT admission pressure:

1. Metal can stage frames fast enough.
2. Pending admission is not rejecting frames.
3. The VT submit lane waits because prior `VTCompressionSessionEncodeFrame` calls and output/session bookkeeping occupy the serialized path.
4. Even after submission, VT callback latency leaves several submitted frames outside the 1 s probe window.

The target is not just "remove the queue"; that has already failed. The target is to reduce or hide the time that full-resolution HDR HEVC frames spend waiting for the single VT submit/admission lane while preserving ordered output and the existing codec contract.

## Next Structural Directions

- Split state mutation from VT admission: keep staging-slot ownership, force-keyframe state, counters, and output bookkeeping actor/queue-isolated, but minimize what must sit on the same serial lane as `VTCompressionSessionEncodeFrame`.
- Prebuild an ordered submission packet before Metal completion: all per-frame state needed by VT should be resolved on the encode path before the Metal handler fires, so the post-Metal lane only performs the irreducible VT call and source-release transition.
- Investigate whether VT accepts safe bounded concurrent admission for independent staged pixel buffers without violating ordering or increasing callback latency. This needs a small bounded design, not naive multi-lane or direct callback submission.
- Investigate private/SkyLight capture sizing only as a source-health branch: the display mode is 5120x2880 @ 240 Hz while the requested stream is 3512x2290, but current healthy runs already show source can get ahead of VT, so this is secondary to VT admission.
- If no single-session admission design beats the plateau, the next creative path is a protocol-level change that lets clients consume independently encoded substreams without requiring complete logical-frame grouping in the 1 s probe. Under the current logical-frame contract, naive tiling is closed.

## Measurement Command

```bash
python3 tools/autoresearch/eval_host_stream.py --workspace src/platform/macos/Lumen.xcworkspace --scheme LumenTuistTests --log "/Users/skyline23/Library/Application Support/Lumen/lumen.log" --target-width 3512 --target-height 2290 --target-fps 120 --codec hevc --runtime-probe-runs 5 --require-partial-hdr --require-low-latency --battery-policy adaptive-hdr
```
