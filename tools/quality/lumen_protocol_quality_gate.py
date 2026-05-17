#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from dataclasses import dataclass
from pathlib import Path


MAX_FUNCTION_LINES = 80

SCAN_SUFFIXES = {".bat", ".cpp", ".h", ".hpp", ".m", ".mm", ".swift"}
SCAN_ROOTS = ("src", "src_assets/windows", "tests/tuist/macos", "tests/unit")
PROTOCOL_FUNCTION_FILES = {
    Path("src/lumen_protocol.h"),
    Path("src/lumen_protocol_adapter.h"),
    Path("src/lumen_protocol_platform_adapter.h"),
    Path("src/platform/macos/Projects/LumenMacBridge/Sources/LumenStreamingProtocol.swift"),
}
PROTOCOL_LITERAL_AUTHORITY_FILES = PROTOCOL_FUNCTION_FILES | {
    Path("src/lumen_protocol_control_wire_generated.h"),
    Path("src/stream.cpp"),
    Path(
        "src/platform/macos/Projects/LumenMacBridge/Sources/Generated/"
        "LumenProtocolControlWireLayout.generated.swift"
    ),
}
PROTOCOL_WIRE_LITERALS = ("0x3003", "0x3004")
FORBIDDEN_PATTERNS = (
    (
        "forbidden-pattern",
        re.compile(r"\bNS(?:Recursive)?Lock\s*\("),
        "Do not add NSLock-based coordination; use actor or existing queue isolation.",
    ),
    (
        "forbidden-pattern",
        re.compile(r"\btargetFrameRate\s*(?:[><]=?|[=!]=)\s*100\b"),
        "Do not gate Lumen high-refresh behavior on a 100 fps threshold.",
    ),
)
LEGACY_IDENTITY_PATTERN = re.compile(r"\b(?:[Ss]unshine|[Aa]pollo)\w*\b")
LEGACY_IDENTITY_ALLOWED_FILES = {
    Path("src/platform/windows/utils.cpp"),
    Path("src_assets/windows/misc/migration/migrate-config.bat"),
    Path("src_assets/windows/misc/service/install-service.bat"),
    Path("src_assets/windows/misc/service/uninstall-service.bat"),
}


@dataclass(frozen=True)
class Violation:
    rule: str
    path: Path
    line: int
    message: str

    def format(self) -> str:
        return f"{self.path}:{self.line}: {self.rule}: {self.message}"


def iter_source_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for scan_root in SCAN_ROOTS:
        directory = root / scan_root
        if not directory.exists():
            continue
        for path in directory.rglob("*"):
            if path.is_file() and path.suffix in SCAN_SUFFIXES:
                files.append(path)
    return sorted(files)


def relative_to_root(path: Path, root: Path) -> Path:
    return path.relative_to(root)


def check_protocol_literal_authority(root: Path, path: Path, text: str) -> list[Violation]:
    relative = relative_to_root(path, root)
    if relative in PROTOCOL_LITERAL_AUTHORITY_FILES:
        return []

    violations: list[Violation] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        for literal in PROTOCOL_WIRE_LITERALS:
            if literal in line:
                violations.append(
                    Violation(
                        "protocol-literal-authority",
                        relative,
                        line_number,
                        f"{literal} must be declared in Lumen protocol authority files, not duplicated here.",
                    )
                )
    return violations


def check_forbidden_patterns(root: Path, path: Path, text: str) -> list[Violation]:
    relative = relative_to_root(path, root)
    violations: list[Violation] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        for rule, pattern, message in FORBIDDEN_PATTERNS:
            if pattern.search(line):
                violations.append(Violation(rule, relative, line_number, message))
    return violations


def check_legacy_identity_boundary(root: Path, path: Path, text: str) -> list[Violation]:
    relative = relative_to_root(path, root)
    if relative in LEGACY_IDENTITY_ALLOWED_FILES:
        return []

    violations: list[Violation] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if LEGACY_IDENTITY_PATTERN.search(line):
            violations.append(
                Violation(
                    "legacy-identity-boundary",
                    relative,
                    line_number,
                    "Legacy Sunshine/Apollo identity is only allowed in migration, service removal, or upstream attribution boundaries.",
                )
            )
    return violations


def function_start_name(line: str) -> str | None:
    stripped = line.strip()
    if stripped.startswith(("if ", "if(", "for ", "for(", "while ", "while(", "switch ", "switch(", "catch ", "catch(")):
        return None
    if re.search(r"\bfunc\s+\w+", stripped) and "{" in stripped:
        return stripped
    if re.search(
        r"\b(?:inline\s+)?(?:constexpr\s+)?(?:static\s+)?"
        r"(?:auto|void|bool|int|std::\w+|[\w:<>]+)\s+\w+\s*\([^;]*\)\s*(?:const\s*)?\{",
        stripped,
    ):
        return stripped
    return None


def check_protocol_function_sizes(root: Path, path: Path, text: str) -> list[Violation]:
    relative = relative_to_root(path, root)
    if relative not in PROTOCOL_FUNCTION_FILES:
        return []

    violations: list[Violation] = []
    active_name: str | None = None
    active_start = 0
    active_lines = 0
    depth = 0
    for line_number, line in enumerate(text.splitlines(), start=1):
        if active_name is None:
            name = function_start_name(line)
            if name is None:
                continue
            active_name = name
            active_start = line_number
            active_lines = 0
            depth = 0

        active_lines += 1
        depth += line.count("{")
        depth -= line.count("}")
        if active_name is not None and depth <= 0:
            if active_lines > MAX_FUNCTION_LINES:
                violations.append(
                    Violation(
                        "protocol-function-size",
                        relative,
                        active_start,
                        f"Protocol function is {active_lines} lines; split it below {MAX_FUNCTION_LINES} lines.",
                    )
                )
            active_name = None
            active_start = 0
            active_lines = 0
            depth = 0
    return violations


def check_generated_protocol_outputs(root: Path) -> list[Violation]:
    generator_path = root / "tools" / "protocol" / "generate_lumen_protocol.py"
    if not generator_path.exists():
        return []

    spec = importlib.util.spec_from_file_location("generate_lumen_protocol_for_quality_gate", generator_path)
    if spec is None or spec.loader is None:
        return [
            Violation(
                "stale-generated-protocol",
                generator_path.relative_to(root),
                1,
                "Could not load Lumen protocol generator.",
            )
        ]

    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    stale_outputs = module.find_stale_outputs(root)
    return [
        Violation(
            "stale-generated-protocol",
            path,
            1,
            "Generated protocol file is stale; run python3 tools/protocol/generate_lumen_protocol.py.",
        )
        for path in stale_outputs
    ]


def run_checks(root: Path) -> list[Violation]:
    root = root.resolve()
    violations: list[Violation] = []
    violations.extend(check_generated_protocol_outputs(root))
    for path in iter_source_files(root):
        text = path.read_text(errors="replace")
        violations.extend(check_forbidden_patterns(root, path, text))
        violations.extend(check_legacy_identity_boundary(root, path, text))
        violations.extend(check_protocol_literal_authority(root, path, text))
        violations.extend(check_protocol_function_sizes(root, path, text))
    return violations


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Lumen protocol quality gates.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()

    violations = run_checks(args.root)
    for violation in violations:
        print(violation.format(), file=sys.stderr)
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
