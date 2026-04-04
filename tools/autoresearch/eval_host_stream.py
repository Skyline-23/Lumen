#!/usr/bin/env python3
import argparse
import datetime as dt
import math
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path


PUBLISH_RE = re.compile(
    r"Publishing macOS bridge capture request .* fps=(?P<fps>\d+) size=(?P<width>\d+)x(?P<height>\d+) "
    r"requested-transport=(?P<requested_transport>[a-z0-9\-]+) "
    r"negotiated-transport=(?P<negotiated_transport>[a-z0-9\-]+) .* "
    r"effective-transfer=(?P<effective_transfer>[a-z0-9\-]+) .* "
    r"effective-hdr-metadata=(?P<effective_hdr_metadata>true|false)"
)
VIRTUAL_DISPLAY_RE = re.compile(
    r"macOS virtual display color profile: .* hdr_intent=(?P<hdr_intent>true|false)"
)
CALLBACK_RE = re.compile(r"Mac bridge frame callback .* callback-latency-ms=(?P<latency>[0-9.]+)")
CALLBACK_SPIKE_RE = re.compile(
    r"callback latency spike .* callback-latency-ms=(?P<latency>[0-9.]+)"
)
ACCEPTED_PACKET_RE = re.compile(
    r"External macOS encoded ingress first accepted packet .* "
    r"hdr=(?P<hdr>true|false) .* transfer=(?P<transfer>[A-Z0-9_\.]+) .* "
    r"seq=(?P<seq>\d+) display-time=(?P<display_time>\d+)"
)
STATS_RE = re.compile(
    r"External macOS encoded ingress(?: final)? stats: "
    r"frames=(?P<frames>\d+) queued=(?P<queued>\d+) dropped=(?P<dropped>\d+) "
    r"last-seq=(?P<last_seq>\d+).* producer-active=(?P<producer_active>true|false).* "
    r"last-callback-latency-ms=(?P<last_callback_latency>-?[0-9.]+)"
)
TIMESTAMP_RE = re.compile(
    r"^\[(?P<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]"
)
SYNTHETIC_SCORE_RE = re.compile(r"AUTORESEARCH_SYNTHETIC_SCORE=(?P<score>[0-9.]+)")
RUNTIME_PROBE_VALUE_RE = re.compile(
    r"AUTORESEARCH_RUNTIME_PROBE_(?P<key>[A-Z_]+)=(?P<value>.*)"
)

TARGETED_TESTS = [
    "LumenTuistTests/LumenTuistBootstrapTests/testBridgeNegotiatesOverlayFallbackAndAutoQueueProfile",
    "LumenTuistTests/LumenTuistBootstrapTests/testRecommendedCoreForwardingFrameCapacityStaysLowLatency",
    "LumenTuistTests/LumenTuistBootstrapTests/testBridgePreservesRequested120HzWithoutImplicitDownscaleFor4KOverlay",
    "LumenTuistTests/LumenTuistBootstrapTests/testBridgePrefersTenBitEncoderInputForPartialHDROverlay",
    "LumenTuistTests/LumenTuistBootstrapTests/testBridgeDoesNotForceHDRTransportForBatterySavingSDRMode",
    "LumenTuistTests/LumenTuistBootstrapTests/testAutoresearchStreamScoringSnapshot",
    "LumenTuistTests/LumenTuistBootstrapTests/testAutoresearchLiveEncodedCaptureProbe",
]
RUNTIME_PROBE_FLAG = Path("/tmp/lumen-autoresearch-runtime-probe.flag")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", default="src/platform/macos/Lumen.xcworkspace")
    parser.add_argument("--scheme", default="LumenTuistTests")
    parser.add_argument("--log")
    parser.add_argument("--target-width", type=int, default=3512)
    parser.add_argument("--target-height", type=int, default=2290)
    parser.add_argument("--target-fps", type=int, default=120)
    parser.add_argument("--require-hdr", action="store_true")
    parser.add_argument("--require-partial-hdr", action="store_true")
    parser.add_argument("--require-low-latency", action="store_true")
    parser.add_argument("--battery-policy", default="adaptive-hdr")
    parser.add_argument("--skip-tests", action="store_true")
    return parser.parse_args()


def run_targeted_tests(workspace: str, scheme: str) -> tuple[float, str]:
    command = [
        "xcodebuild",
        "test",
        "-workspace",
        workspace,
        "-scheme",
        scheme,
        "-destination",
        "platform=macOS",
    ]
    for test_name in TARGETED_TESTS:
        command.extend(["-only-testing:" + test_name])

    env = dict(os.environ)
    RUNTIME_PROBE_FLAG.write_text("1\n", encoding="utf-8")
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            env=env,
        )
        output = completed.stdout
    finally:
        RUNTIME_PROBE_FLAG.unlink(missing_ok=True)
    match = SYNTHETIC_SCORE_RE.search(output)
    score = float(match.group("score")) if match else 0.0
    if completed.returncode != 0:
        tail = "\n".join(output.splitlines()[-60:])
        raise RuntimeError(f"xcodebuild test failed\n{tail}")
    return score, output


def parse_runtime_probe_output(output: str) -> dict[str, str] | None:
    matches = RUNTIME_PROBE_VALUE_RE.findall(output)
    if not matches:
        return None
    return {key: value.strip() for key, value in matches}


def score_runtime_probe(
    probe: dict[str, str],
    args: argparse.Namespace,
) -> tuple[float, dict[str, float]]:
    fps = float(probe.get("FPS", "0") or 0)
    frames = int(probe.get("FRAMES", "0") or 0)
    hdr_frames = int(probe.get("HDR_FRAMES", "0") or 0)
    first_frame_hdr = probe.get("FIRST_FRAME_HDR", "false").lower() == "true"
    average_latency = float(probe.get("AVG_LATENCY_MS", "-1") or -1)
    max_latency = float(probe.get("MAX_LATENCY_MS", "-1") or -1)
    dropped = int(probe.get("DROPPED", "0") or 0)
    failures = int(probe.get("FAILURES", "0") or 0)
    restarts = int(probe.get("RESTARTS", "0") or 0)
    error = probe.get("ERROR", "")

    components: dict[str, float] = {}
    components["fps"] = 40.0 * min(fps / max(args.target_fps, 1), 1.0)
    components["progression"] = 20.0 if frames > 0 else 0.0
    if frames > 60:
        components["progression"] += 10.0
    if args.require_partial_hdr:
        components["partial_hdr"] = 15.0 if hdr_frames > 0 or first_frame_hdr else 0.0
    elif args.require_hdr:
        components["partial_hdr"] = 15.0 if hdr_frames > 0 or first_frame_hdr else 0.0
    else:
        components["partial_hdr"] = 0.0

    if max_latency >= 0 or average_latency >= 0:
        reference_latency = max(max_latency, average_latency, 0.0)
        components["latency"] = max(0.0, 15.0 - max(0.0, reference_latency - 8.0) * 0.75)
    else:
        components["latency"] = 0.0

    penalty = (
        dropped * 1.5
        + failures * 8.0
        + restarts * 10.0
    )
    if error:
        penalty += 20.0
    if frames == 0:
        penalty += 40.0
    components["stability_penalty"] = -penalty

    total = sum(components.values())
    total = max(0.0, min(total, 100.0))
    return total, components


def bool_from_group(value: str) -> bool:
    return value.lower() == "true"


def parse_timestamp(line: str) -> dt.datetime | None:
    match = TIMESTAMP_RE.search(line)
    if not match:
        return None
    return dt.datetime.strptime(match.group("stamp"), "%Y-%m-%d %H:%M:%S.%f")


def quantile95(values: list[float]) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    return statistics.quantiles(values, n=20)[-1]


def parse_runtime_log(path: Path) -> dict[str, float | bool | int] | None:
    if not path.exists():
        return None

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    publish_indices: list[tuple[int, re.Match[str]]] = []
    for index, line in enumerate(lines):
        match = PUBLISH_RE.search(line)
        if match:
            publish_indices.append((index, match))

    if not publish_indices:
        return None

    publish_index, publish_match = publish_indices[-1]
    hdr_intent = False
    for back_index in range(publish_index, -1, -1):
        display_match = VIRTUAL_DISPLAY_RE.search(lines[back_index])
        if display_match:
            hdr_intent = bool_from_group(display_match.group("hdr_intent"))
            break

    publish_time = parse_timestamp(lines[publish_index])
    end_time = publish_time
    callback_latencies = []
    callback_spike_latencies = []
    saturation_count = 0
    overflow_count = 0
    callback_spike_count = 0
    duplicate_payload_count = 0
    restart_count = 0
    no_advance_count = 0
    initial_idr_wait_count = 0
    callback_count = 0
    accepted_packet_count = 0
    accepted_hdr_count = 0
    accepted_non709_transfer_count = 0
    accepted_sequences: list[int] = []
    max_stats_frames = 0
    max_stats_queued = 0
    max_stats_dropped = 0
    producer_active_count = 0
    stats_last_callback_latencies = []
    for line in lines[publish_index:]:
        parsed_time = parse_timestamp(line)
        if parsed_time is not None:
            end_time = parsed_time
        callback_match = CALLBACK_RE.search(line)
        if callback_match:
            callback_latencies.append(float(callback_match.group("latency")))
            callback_count += 1
        spike_match = CALLBACK_SPIKE_RE.search(line)
        if spike_match:
            callback_spike_latencies.append(float(spike_match.group("latency")))
        if "capture processing queue is saturated" in line:
            saturation_count += 1
        if "core-forwarder-overflow" in line:
            overflow_count += 1
        if "callback latency spike" in line:
            callback_spike_count += 1
        if "duplicate-payload" in line:
            duplicate_payload_count += 1
        if "restarting the capture session" in line:
            restart_count += 1
        if "has not advanced frame delivery" in line:
            no_advance_count += 1
        if "waiting for an initial IDR packet" in line:
            initial_idr_wait_count += 1

        accepted_match = ACCEPTED_PACKET_RE.search(line)
        if accepted_match:
            accepted_packet_count += 1
            if bool_from_group(accepted_match.group("hdr")):
                accepted_hdr_count += 1
            if accepted_match.group("transfer") != "ITU_R_709_2":
                accepted_non709_transfer_count += 1
            accepted_sequences.append(int(accepted_match.group("seq")))

        stats_match = STATS_RE.search(line)
        if stats_match:
            max_stats_frames = max(max_stats_frames, int(stats_match.group("frames")))
            max_stats_queued = max(max_stats_queued, int(stats_match.group("queued")))
            max_stats_dropped = max(max_stats_dropped, int(stats_match.group("dropped")))
            if bool_from_group(stats_match.group("producer_active")):
                producer_active_count += 1
            last_callback_latency = float(stats_match.group("last_callback_latency"))
            if last_callback_latency >= 0:
                stats_last_callback_latencies.append(last_callback_latency)

    return {
        "fps": int(publish_match.group("fps")),
        "width": int(publish_match.group("width")),
        "height": int(publish_match.group("height")),
        "requested_transport": publish_match.group("requested_transport"),
        "negotiated_transport": publish_match.group("negotiated_transport"),
        "effective_transfer": publish_match.group("effective_transfer"),
        "effective_hdr_metadata": bool_from_group(publish_match.group("effective_hdr_metadata")),
        "hdr_intent": hdr_intent,
        "callback_latencies": callback_latencies,
        "callback_spike_latencies": callback_spike_latencies,
        "saturation_count": saturation_count,
        "overflow_count": overflow_count,
        "callback_spike_count": callback_spike_count,
        "duplicate_payload_count": duplicate_payload_count,
        "restart_count": restart_count,
        "no_advance_count": no_advance_count,
        "initial_idr_wait_count": initial_idr_wait_count,
        "callback_count": callback_count,
        "accepted_packet_count": accepted_packet_count,
        "accepted_hdr_count": accepted_hdr_count,
        "accepted_non709_transfer_count": accepted_non709_transfer_count,
        "accepted_sequence_span": (
            max(accepted_sequences) - min(accepted_sequences)
            if len(accepted_sequences) >= 2
            else 0
        ),
        "max_stats_frames": max_stats_frames,
        "max_stats_queued": max_stats_queued,
        "max_stats_dropped": max_stats_dropped,
        "producer_active_count": producer_active_count,
        "stats_last_callback_latencies": stats_last_callback_latencies,
        "session_duration_seconds": max(
            (end_time - publish_time).total_seconds(),
            0.0,
        ) if publish_time and end_time else 0.0,
    }


def score_runtime(metrics: dict[str, float | bool | int], args: argparse.Namespace) -> tuple[float, dict[str, float]]:
    fps = int(metrics["fps"])
    width = int(metrics["width"])
    height = int(metrics["height"])
    negotiated_transport = str(metrics["negotiated_transport"])
    effective_transfer = str(metrics["effective_transfer"])
    effective_hdr_metadata = bool(metrics["effective_hdr_metadata"])
    hdr_intent = bool(metrics["hdr_intent"])
    callback_latencies = list(metrics["callback_latencies"])
    callback_spike_latencies = list(metrics["callback_spike_latencies"])
    saturation_count = int(metrics["saturation_count"])
    overflow_count = int(metrics["overflow_count"])
    callback_spike_count = int(metrics["callback_spike_count"])
    duplicate_payload_count = int(metrics["duplicate_payload_count"])
    restart_count = int(metrics["restart_count"])
    no_advance_count = int(metrics["no_advance_count"])
    initial_idr_wait_count = int(metrics["initial_idr_wait_count"])
    callback_count = int(metrics["callback_count"])
    accepted_packet_count = int(metrics["accepted_packet_count"])
    accepted_hdr_count = int(metrics["accepted_hdr_count"])
    accepted_non709_transfer_count = int(metrics["accepted_non709_transfer_count"])
    accepted_sequence_span = int(metrics["accepted_sequence_span"])
    max_stats_frames = int(metrics["max_stats_frames"])
    max_stats_queued = int(metrics["max_stats_queued"])
    max_stats_dropped = int(metrics["max_stats_dropped"])
    producer_active_count = int(metrics["producer_active_count"])
    stats_last_callback_latencies = list(metrics["stats_last_callback_latencies"])
    session_duration_seconds = float(metrics["session_duration_seconds"])

    components: dict[str, float] = {}
    components["fps"] = 10.0 * min(fps / max(args.target_fps, 1), 1.0)
    dimensions_match = width == args.target_width and height == args.target_height
    components["resolution"] = 10.0 if dimensions_match else 0.0

    overlay_ok = negotiated_transport == "sdr-base-hdr-overlay"
    hdr_ok = effective_transfer == "pq" and effective_hdr_metadata and hdr_intent
    components["partial_hdr"] = 15.0 if overlay_ok and hdr_ok else 0.0

    if args.battery_policy == "adaptive-hdr":
        components["battery_policy"] = 0.0 if hdr_intent else 5.0
    else:
        components["battery_policy"] = 0.0

    runtime_latency_samples = callback_latencies + callback_spike_latencies + stats_last_callback_latencies
    if runtime_latency_samples:
        p95 = quantile95(runtime_latency_samples)
        components["latency"] = max(0.0, 20.0 - max(0.0, p95 - 12.0) * 0.6)
    else:
        components["latency"] = 0.0

    progress_frames = max(callback_count, max_stats_frames)
    if session_duration_seconds > 0:
        expected_frames = max(session_duration_seconds * max(args.target_fps, 1), 1.0)
        progress_ratio = min(progress_frames / expected_frames, 1.0)
    else:
        progress_ratio = 0.0

    progression_bonus = 0.0
    if callback_count > 0:
        progression_bonus += 20.0 * min(progress_ratio * 4.0, 1.0)
    elif progress_frames > 1:
        progression_bonus += 8.0 * min(progress_ratio * 2.0, 1.0)

    if accepted_packet_count > 0 and callback_count == 0:
        progression_bonus = 0.0

    if accepted_packet_count > 0 and accepted_sequence_span > 0:
        progression_bonus += 5.0

    components["progression"] = min(progression_bonus, 25.0)

    thrash_penalty = (
        saturation_count * 0.8
        + overflow_count * 2.5
        + callback_spike_count * 1.0
        + duplicate_payload_count * 2.0
        + restart_count * 5.0
        + no_advance_count * 8.0
        + initial_idr_wait_count * 4.0
    )
    if accepted_packet_count > 1:
        thrash_penalty += (accepted_packet_count - 1) * 1.25
    if callback_count == 0 and accepted_packet_count > 0:
        thrash_penalty += 20.0
    if max_stats_frames <= 1 and session_duration_seconds >= 1.0:
        thrash_penalty += 15.0
    if max_stats_queued > 0:
        thrash_penalty += max_stats_queued * 1.5
    if max_stats_dropped > 0:
        thrash_penalty += max_stats_dropped * 1.5
    if producer_active_count > 0 and progress_frames == 0:
        thrash_penalty += 10.0

    components["stability_penalty"] = -thrash_penalty

    total = sum(components.values())
    total = max(0.0, min(total, 100.0))
    return total, components


def main() -> int:
    args = parse_args()

    synthetic_score = 0.0
    runtime_probe_score = 0.0
    runtime_probe_components: dict[str, float] = {}
    if not args.skip_tests:
        synthetic_score, test_output = run_targeted_tests(args.workspace, args.scheme)
        print(f"SYNTHETIC_TEST_SCORE={synthetic_score:.2f}")
        print(f"SYNTHETIC_TESTS={len(TARGETED_TESTS)}")
        runtime_probe = parse_runtime_probe_output(test_output)
        if runtime_probe is not None:
            runtime_probe_score, runtime_probe_components = score_runtime_probe(runtime_probe, args)
            print(f"BENCHMARK_RUNTIME_SCORE={runtime_probe_score:.2f}")
            for key, value in sorted(runtime_probe_components.items()):
                print(f"BENCHMARK_RUNTIME_COMPONENT_{key.upper()}={value:.2f}")
    else:
        test_output = ""

    runtime_score = 0.0
    runtime_components: dict[str, float] = {}
    if args.log:
        runtime_metrics = parse_runtime_log(Path(args.log))
        if runtime_metrics is not None:
            runtime_score, runtime_components = score_runtime(runtime_metrics, args)
            print(f"RUNTIME_SCORE={runtime_score:.2f}")
            for key, value in sorted(runtime_components.items()):
                print(f"RUNTIME_COMPONENT_{key.upper()}={value:.2f}")
        else:
            print("RUNTIME_SCORE=0.00")
            print("RUNTIME_COMPONENT_NOTE=missing-or-no-session")

    if runtime_probe_components:
        total = runtime_probe_score + (synthetic_score * 0.25)
    elif args.log and runtime_components:
        total = runtime_score + (synthetic_score * 0.25)
    else:
        total = synthetic_score
    total = max(0.0, min(total, 110.0))
    print(f"AUTORESEARCH_SCORE={total:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
