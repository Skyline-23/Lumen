# HDR120 HEVC Bottleneck Map

Last updated: 2026-05-14.

## Current Best

- Best score: 110.00 from experiment 2058; best objective-progress state is experiment 2061 because it keeps HEVC tile records stable and restores ProRes above 120 frames.
- Stable HEVC shape: 184 encoded tile records / 184 HDR records in the 1 s probe, with 2 independent half-height encoded lanes and zero drops.
- Stable HEVC submit shape: about 94 half-height tile `VTCompressionSessionEncodeFrame` submissions; this is enough for the current tile-record metric but is not the same as 120 complete logical frames.
- Current ProRes shape: experiment 2061 reaches 136 ProRes frames / 136 HDR records, 137 VT submissions, zero drops, and about 122.91 fps source cadence by using ProRes-only bounded replay catch-up.
- Contract: keep HEVC Main10, PQ HDR, target 3512x2290, 120 fps, low latency, and existing quality/bitrate policy. Do not trade quality or high refresh for score.

## Measured Pipeline

| Boundary | Representative measurement | Interpretation |
| --- | ---: | --- |
| HEVC source/tiling | 2058: 184 tile records, 184 HDR records, max tile count 2, encoded lane count 2 | Protocol-level tile records bypass the old single full-frame 101-102 output ceiling. |
| HEVC VT submission | 2058/2059: 94 staged/submitted half-height tile frames | The HEVC tile path reaches enough records for the score cap, but logical-frame semantics still need care. |
| HEVC callback/stability | 2058: 63.504 ms avg callback latency, 0 drops; 2059: 55.828 ms avg, 0 drops | Stability is currently fixed for the tile-record path; do not reopen naive tile emission or forwarding capacity churn. |
| ProRes source cadence | 2061: 137 source frames, 136 records, about 122.91 fps | ProRes frame count is no longer the limiting stage when catch-up replay is isolated from HEVC. |
| ProRes VT encode | 2061: 137 submissions, 1.505 ms avg VT encode call, 0 drops | ProRes encoder remains fast enough after source cadence recovery. |
| Lumen forwarding ingress | 2058/2061: 0 queued, 0 dropped | The Lumen bridge is not dropping the current kept tile/prores paths. |

## Closed Or Low-Priority Axes

- Do not chase raw source availability unless source count, pending rejected count, or forwarding drops become nonzero in the same valid metric window.
- Do not repeat simple VT knobs: temporal compression disable, unretained command buffers, per-frame or batched `VTCompressionSessionCompleteFrames`, and diagnostic property deferral did not beat best.
- Do not repeat simple `submissionQueue` removal by calling VT directly from the Metal completion callback. Prior inline submit shifted blocking into the Metal-stage bucket without increasing useful submissions or outputs.
- Do not repeat naive temporal or spatial HEVC lane splitting under the current client/probe contract. It worsened callback latency or produced incomplete/dropped logical groups.
- Do not repeat independent HEVC tile emission without protocol-aware queue semantics. Experiment 2057 hit 120 HEVC HDR tile records but collapsed with 62 drops; 2058 fixed that by scaling forwarding capacity to the negotiated tile-record multiplier.
- Do not repeat ProRes replay-timer queue isolation as a standalone fix. Experiment 2059 kept the score capped at 110.00 but ProRes regressed to 106 frames and about 95.63 fps source cadence.
- Do not repeat shared replay catch-up that changes HEVC single-replay timestamp semantics. Experiment 2060 recovered ProRes but introduced 21 HEVC drop events. Experiment 2061 shows the keepable shape is ProRes-only batch replay with the original HEVC single-replay path preserved.
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

The best current explanation has shifted again:

1. For HEVC, single full-frame VT output was the old ceiling; the kept tile-record protocol now reaches 184 HDR records with zero drops.
2. For ProRes, experiment 2061 recovers source cadence and reaches 136 HDR records with zero drops, so ProRes frame count is no longer the primary limiter.
3. The remaining uncertainty is semantic rather than raw throughput: HEVC reports 184 independent tile records, not 120 complete logical frames.

The target is now to make the HEVC tile-stream contract rigorous enough for the product: clients and probes must distinguish independent encoded tile records from complete logical frames without treating valid tile substreams as drops, and without hiding real loss.

## Next Structural Directions

- Tile semantics branch: distinguish tile records from logical frames more rigorously in client/probe semantics while preserving zero drops; do not go back to complete-group gating unless client consumption requires complete groups.
- Client contract branch: define whether Android/general clients consume independent HEVC substreams directly, reassemble them, or require a logical-frame manifest beside each tile record.
- ProRes catch-up branch is kept and should not be widened unless new evidence shows drop-free ProRes overproduction hurts battery or latency.
- HEVC admission branch is lower priority now: keep the 2058 tile path unless a new change regresses HDR, drops, or Android-required HEVC Main10 support.

## Measurement Command

```bash
python3 tools/autoresearch/eval_host_stream.py --workspace src/platform/macos/Lumen.xcworkspace --scheme LumenTuistTests --log "/Users/skyline23/Library/Application Support/Lumen/lumen.log" --target-width 3512 --target-height 2290 --target-fps 120 --codec hevc --runtime-probe-runs 5 --require-partial-hdr --require-low-latency --battery-policy adaptive-hdr
```
