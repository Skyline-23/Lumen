#!/usr/bin/env python3
import argparse
import math
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
SYNTHETIC_SCORE_RE = re.compile(r"AUTORESEARCH_SYNTHETIC_SCORE=(?P<score>[0-9.]+)")

TARGETED_TESTS = [
    "LumenTuistTests/LumenTuistBootstrapTests/testBridgeNegotiatesOverlayFallbackAndAutoQueueProfile",
    "LumenTuistTests/LumenTuistBootstrapTests/testRecommendedCoreForwardingFrameCapacityStaysLowLatency",
    "LumenTuistTests/LumenTuistBootstrapTests/testBridgePreservesRequested120HzWithoutImplicitDownscaleFor4KOverlay",
    "LumenTuistTests/LumenTuistBootstrapTests/testBridgePrefersTenBitEncoderInputForPartialHDROverlay",
    "LumenTuistTests/LumenTuistBootstrapTests/testBridgeDoesNotForceHDRTransportForBatterySavingSDRMode",
    "LumenTuistTests/LumenTuistBootstrapTests/testAutoresearchStreamScoringSnapshot",
]


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

    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    output = completed.stdout
    match = SYNTHETIC_SCORE_RE.search(output)
    score = float(match.group("score")) if match else 0.0
    if completed.returncode != 0:
        tail = "\n".join(output.splitlines()[-60:])
        raise RuntimeError(f"xcodebuild test failed\n{tail}")
    return score, output


def bool_from_group(value: str) -> bool:
    return value.lower() == "true"


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

    callback_latencies = []
    saturation_count = 0
    overflow_count = 0
    callback_spike_count = 0
    duplicate_payload_count = 0
    restart_count = 0
    for line in lines[publish_index:]:
        callback_match = CALLBACK_RE.search(line)
        if callback_match:
            callback_latencies.append(float(callback_match.group("latency")))
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
        "saturation_count": saturation_count,
        "overflow_count": overflow_count,
        "callback_spike_count": callback_spike_count,
        "duplicate_payload_count": duplicate_payload_count,
        "restart_count": restart_count,
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
    saturation_count = int(metrics["saturation_count"])
    overflow_count = int(metrics["overflow_count"])
    callback_spike_count = int(metrics["callback_spike_count"])
    duplicate_payload_count = int(metrics["duplicate_payload_count"])
    restart_count = int(metrics["restart_count"])

    components: dict[str, float] = {}
    components["fps"] = 15.0 * min(fps / max(args.target_fps, 1), 1.0)
    dimensions_match = width == args.target_width and height == args.target_height
    components["resolution"] = 10.0 if dimensions_match else 0.0

    overlay_ok = negotiated_transport == "sdr-base-hdr-overlay"
    hdr_ok = effective_transfer == "pq" and effective_hdr_metadata and hdr_intent
    components["partial_hdr"] = 15.0 if overlay_ok and hdr_ok else 0.0

    if args.battery_policy == "adaptive-hdr":
        components["battery_policy"] = 0.0 if hdr_intent else 5.0
    else:
        components["battery_policy"] = 0.0

    if callback_latencies:
        p95 = statistics.quantiles(callback_latencies, n=20)[-1] if len(callback_latencies) >= 2 else callback_latencies[0]
        components["latency"] = max(0.0, 15.0 - max(0.0, p95 - 12.0) * 0.5)
    else:
        components["latency"] = 0.0

    components["stability_penalty"] = -(
        saturation_count * 0.5
        + overflow_count * 2.0
        + callback_spike_count * 1.5
        + duplicate_payload_count * 2.0
        + restart_count * 3.0
    )

    total = sum(components.values())
    total = max(0.0, min(total, 40.0))
    return total, components


def main() -> int:
    args = parse_args()

    synthetic_score = 0.0
    if not args.skip_tests:
        synthetic_score, test_output = run_targeted_tests(args.workspace, args.scheme)
        print(f"SYNTHETIC_TEST_SCORE={synthetic_score:.2f}")
        print(f"SYNTHETIC_TESTS={len(TARGETED_TESTS)}")
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

    total = synthetic_score + runtime_score
    total = max(0.0, min(total, 140.0))
    print(f"AUTORESEARCH_SCORE={total:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
