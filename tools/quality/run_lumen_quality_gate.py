#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class QualityStep:
    name: str
    command: tuple[str, ...]
    cwd: Path | None = None


def build_steps(fast: bool) -> list[QualityStep]:
    steps = [
        QualityStep("git whitespace check", ("git", "diff", "--check")),
        QualityStep("protocol generator tests", ("python3", "tools/protocol/test_generate_lumen_protocol.py")),
        QualityStep("protocol output freshness", ("python3", "tools/protocol/generate_lumen_protocol.py", "--check")),
        QualityStep("protocol quality gate tests", ("python3", "tools/quality/test_lumen_protocol_quality_gate.py")),
        QualityStep("quality runner tests", ("python3", "tools/quality/test_run_lumen_quality_gate.py")),
        QualityStep("protocol quality gate", ("python3", "tools/quality/lumen_protocol_quality_gate.py")),
    ]
    if fast:
        return steps

    steps.extend(
        [
            QualityStep("web asset build", ("npm", "run", "build")),
            QualityStep("cmake configure", ("cmake", "-S", ".", "-B", "/tmp/lumen-quality-cmake", "-DBUILD_TESTS=OFF")),
            QualityStep("tuist project generation", ("tuist", "generate", "--no-open"), Path("src/platform/macos")),
            QualityStep(
                "macOS Tuist tests",
                ("xcodebuild", "test", "-workspace", "Lumen.xcworkspace", "-scheme", "LumenTuistTests"),
                Path("src/platform/macos"),
            ),
        ]
    )
    return steps


def run_step(root: Path, step: QualityStep) -> int:
    cwd = root / step.cwd if step.cwd is not None else root
    print(f"==> {step.name}", flush=True)
    completed = subprocess.run(step.command, cwd=cwd)
    return completed.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Lumen protocol and build quality gates.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--fast", action="store_true", help="Skip build-heavy web, CMake, Tuist, and Xcode checks.")
    args = parser.parse_args()

    root = args.root.resolve()
    for step in build_steps(fast=args.fast):
        result = run_step(root, step)
        if result != 0:
            return result
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
