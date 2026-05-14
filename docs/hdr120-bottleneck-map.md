# HDR120 HEVC Bottleneck Map

Last updated: 2026-05-14.

## Current Best

- Best score: 110.00 from experiment 2058; best objective-progress state is experiment 2063 because it raises HEVC complete tile groups while preserving zero drops and ProRes over 120.
- Stable HEVC tile-record shape: 194 encoded tile records / HDR records in the 1 s probe, with 2 independent half-width encoded lanes and zero drops.
- Stable HEVC logical-group shape: experiment 2063 reports 97 complete frame groups and 0 incomplete groups from 194 tile records. This is stable and better than 2062, but it is still not 120 complete logical frames.
- Current ProRes shape: experiment 2063 reaches 134 ProRes frames / 134 HDR records, 135 VT submissions, zero drops, and about 123.4 fps source cadence by using ProRes-only bounded replay catch-up.
- Contract: keep HEVC Main10, PQ HDR, target 3512x2290, 120 fps, low latency, and existing quality/bitrate policy. Do not trade quality or high refresh for score.

## Measured Pipeline

| Boundary | Representative measurement | Interpretation |
| --- | ---: | --- |
| HEVC source/tiling | 2063: 194 tile records, 194 HDR records, max tile count 2, encoded lane count 2 | Protocol-level tile records bypass the old single full-frame 101-102 output ceiling. |
| HEVC logical groups | 2063: 97 complete frame groups, 0 incomplete groups | Column partitioning improves logical-frame throughput, but it remains below 120 groups/s. |
| HEVC VT submission | 2063: 103 staged/submitted half-width tile frames | The HEVC tile path reaches enough tile records for the score cap, but each logical frame needs 2 tile submissions. |
| HEVC per-lane VT output | 2068 diagnostic: lane 0 and lane 1 each submitted 103 staged frames and completed 97 output callbacks | The 97-group ceiling is symmetric across both lanes, not a single slow-lane imbalance. |
| HEVC callback/stability | 2063: 70.483 ms avg callback latency, 0 drops | Stability is currently fixed for the tile-record path; do not reopen naive tile emission or forwarding capacity churn. |
| ProRes source cadence | 2063: 135 source frames, 134 records, about 123.4 fps | ProRes frame count is no longer the limiting stage when catch-up replay is isolated from HEVC. |
| ProRes VT encode | 2063: 135 submissions, 1.482 ms avg VT encode call, 0 drops | ProRes encoder remains fast enough after source cadence recovery. |
| Lumen forwarding ingress | 2058/2061/2062/2063: 0 queued, 0 dropped | The Lumen bridge is not dropping the current kept tile/prores paths. |

## Closed Or Low-Priority Axes

- Do not chase raw source availability unless source count, pending rejected count, or forwarding drops become nonzero in the same valid metric window.
- Do not repeat simple VT knobs: temporal compression disable, unretained command buffers, per-frame or batched `VTCompressionSessionCompleteFrames`, and diagnostic property deferral did not beat best.
- Do not repeat simple `submissionQueue` removal by calling VT directly from the Metal completion callback. Prior inline submit shifted blocking into the Metal-stage bucket without increasing useful submissions or outputs.
- Do not repeat naive temporal or spatial HEVC lane splitting under the current client/probe contract. It worsened callback latency or produced incomplete/dropped logical groups.
- Do not repeat independent HEVC tile emission without protocol-aware queue semantics. Experiment 2057 hit 120 HEVC HDR tile records but collapsed with 62 drops; 2058 fixed that by scaling forwarding capacity to the negotiated tile-record multiplier.
- Do not repeat ProRes replay-timer queue isolation as a standalone fix. Experiment 2059 kept the score capped at 110.00 but ProRes regressed to 106 frames and about 95.63 fps source cadence.
- Do not repeat shared replay catch-up that changes HEVC single-replay timestamp semantics. Experiment 2060 recovered ProRes but introduced 21 HEVC drop events. Experiment 2061 shows the keepable shape is ProRes-only batch replay with the original HEVC single-replay path preserved.
- Do not treat encoded tile-record count alone as proof of logical-frame completion. Experiment 2062 shows 178 stable tile records but only 89 complete logical tile groups.
- Do not revert to full-width half-height tile bands unless a later experiment proves columns break client decoding. Experiment 2063 raised complete logical groups from 89 to 97 with zero drops.
- Do not add a third HEVC tile lane as a direct throughput fix. Experiment 2064 raised tile records to 272 but regressed complete logical groups to 90 and introduced 1 incomplete group.
- Do not rotate 2-column tile lane processing order. Experiment 2065 regressed complete groups to 94, introduced 3 incomplete groups, and increased Metal/VT jitter.
- Do not round the 2-column split to a 64-pixel CTU boundary as a standalone fix. Experiment 2066 regressed complete groups to 94 and introduced 4 HEVC drop events.
- Do not move the existing 2-column lane work onto per-lane serial queues as a standalone fix. Experiment 2067 removed almost all encode queue wait but still produced 194 tile records, 97 complete groups, 0 drops, and 103 VT submissions, so source-callback lane enqueue serialization is not the first remaining bottleneck.
- Do not assume one tile lane is uniquely lagging. Experiment 2068 showed lane 0 and lane 1 both processed/submitted 103 tile frames and completed 97 callbacks. The detailed diagnostic path itself caused 1 HEVC drop event, so keep it as discard-only evidence rather than baseline instrumentation.
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

1. For HEVC, single full-frame VT output was the old ceiling; the kept tile-record protocol now reaches 194 HDR tile records with zero drops.
2. For ProRes, experiment 2061-2063 recovers source cadence and reaches 134-141 HDR records with zero drops, so ProRes frame count is no longer the primary limiter.
3. The remaining HEVC gap is now 97 complete logical tile groups versus the 120 target. Tile geometry matters: column partitioning improved the previous 89-group audit.

The target is now to make the HEVC tile-stream contract rigorous enough for the product: either clients and probes must explicitly consume independent encoded tile records as tile substreams, or the encoder topology must deliver 120 complete logical tile groups without treating valid substreams as drops.

## Next Structural Directions

- Tile semantics branch: add a first-class tile-stream manifest/reassembly contract so the receiver can map each encoded tile record to frame group, tile index, region, and lane without requiring the encoder to hold back records for group completion.
- Logical-group throughput branch: if the product requires complete frames before delivery, redesign HEVC lane scheduling so both tile lanes produce at least 120 complete groups/s; do not reintroduce complete-group gating on the current queue because prior gating collapsed throughput.
- Client contract branch: define whether Android/general clients consume independent HEVC substreams directly, reassemble them, or require a logical-frame manifest beside each tile record.
- Lane-count branch is mostly closed for direct scaling: 3 lanes increased record count but made logical groups worse. Prefer 2-lane scheduling/region work before any higher lane count.
- Lane-order branch is closed for simple rotation: reordering existing lane work caused incomplete groups. Per-lane queue isolation also tied the current 97-group best without moving VT submission/output, so prefer reducing per-lane work or changing the encoded tile contract rather than rescheduling the same work.
- Tile-width alignment branch is closed for simple asymmetric CTU rounding: equal half-width columns remain the best measured geometry.
- ProRes catch-up branch is kept and should not be widened unless new evidence shows drop-free ProRes overproduction hurts battery or latency.
- HEVC admission branch is lower priority now: keep the 2058 tile path unless a new change regresses HDR, drops, or Android-required HEVC Main10 support.

## Measurement Command

```bash
python3 tools/autoresearch/eval_host_stream.py --workspace src/platform/macos/Lumen.xcworkspace --scheme LumenTuistTests --log "/Users/skyline23/Library/Application Support/Lumen/lumen.log" --target-width 3512 --target-height 2290 --target-fps 120 --codec-suite hevc,prores-proxy --require-partial-hdr --require-low-latency --battery-policy adaptive-hdr
```
