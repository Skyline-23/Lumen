#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


FIELD = re.compile(r"(?:(optional|repeated) )?([A-Za-z0-9_.]+) ([A-Za-z0-9_]+) = ([0-9]+);")
INLINE_CODE = re.compile(r"`([^`]+)`")


def parse_proto(source: str) -> dict[str, dict[str, Any]]:
    declarations: dict[str, dict[str, Any]] = {}
    active: dict[str, Any] | None = None
    active_oneof: str | None = None
    for raw_line in source.splitlines():
        line = raw_line.split("//", 1)[0].strip()
        if match := re.fullmatch(r"(enum|message) ([A-Za-z0-9_]+) \{", line):
            active = {"kind": match.group(1), "numbers": {}, "reserved": set()}
            declarations[match.group(2)] = active
            continue
        if active is None:
            continue
        if match := re.fullmatch(r"oneof ([A-Za-z0-9_]+) \{", line):
            active_oneof = match.group(1)
            continue
        if line == "}":
            if active_oneof is not None:
                active_oneof = None
            else:
                active = None
            continue
        if match := re.fullmatch(r"reserved ([0-9, ]+);", line):
            active["reserved"].update(int(value.strip()) for value in match.group(1).split(","))
            continue
        if active["kind"] == "enum":
            if match := re.fullmatch(r"([A-Z0-9_]+) = ([0-9]+);", line):
                active["numbers"][int(match.group(2))] = (match.group(1),)
            continue
        if match := FIELD.fullmatch(line):
            active["numbers"][int(match.group(4))] = (
                match.group(3),
                match.group(2),
                match.group(1) or "singular",
                active_oneof,
            )
    return declarations


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def compare_proto(baseline: dict[str, Any], current: dict[str, Any]) -> None:
    old = parse_proto(baseline["protobuf"]["source"])
    new = parse_proto(current["protobuf"]["source"])
    for declaration_name, old_declaration in old.items():
        require(declaration_name in new, f"removed protobuf declaration: {declaration_name}")
        new_declaration = new[declaration_name]
        require(old_declaration["kind"] == new_declaration["kind"], f"changed protobuf declaration kind: {declaration_name}")
        require(old_declaration["reserved"].issubset(new_declaration["reserved"]), f"removed reserved protobuf number: {declaration_name}")
        for number, old_value in old_declaration["numbers"].items():
            require(
                new_declaration["numbers"].get(number) == old_value,
                f"removed, reused, or changed protobuf number {declaration_name}.{number}",
            )


def nested_routes(value: Any) -> dict[tuple[str, str], str]:
    routes: dict[tuple[str, str], str] = {}
    if isinstance(value, dict):
        if isinstance(value.get("method"), str) and isinstance(value.get("path"), str):
            routes[(value["method"], value["path"])] = json.dumps(value, sort_keys=True)
        for child in value.values():
            routes.update(nested_routes(child))
    elif isinstance(value, list):
        for child in value:
            routes.update(nested_routes(child))
    return routes


def require_preserved_list(baseline: Any, current: Any, label: str) -> None:
    require(isinstance(baseline, list) and isinstance(current, list), f"{label} must be a list")
    require(set(baseline).issubset(current), f"removed {label}")


def require_preserved_value(baseline: Any, current: Any, label: str) -> None:
    require(type(baseline) is type(current), f"changed {label} type")
    if isinstance(baseline, dict):
        for key, value in baseline.items():
            require(key in current, f"removed {label}.{key}")
            require_preserved_value(value, current[key], f"{label}.{key}")
        return
    require(baseline == current, f"changed {label}")


def compare_documentation(baseline: str, current: str, label: str) -> None:
    old_headings = {line.strip() for line in baseline.splitlines() if line.startswith("#")}
    new_headings = {line.strip() for line in current.splitlines() if line.startswith("#")}
    require(old_headings.issubset(new_headings), f"removed {label} heading")
    require(
        set(INLINE_CODE.findall(baseline)).issubset(INLINE_CODE.findall(current)),
        f"removed {label} protocol token",
    )
    old_lines = sum(bool(line.strip()) for line in baseline.splitlines())
    new_lines = sum(bool(line.strip()) for line in current.splitlines())
    require(new_lines * 10 >= old_lines * 9, f"collapsed {label} authority")


def compare_contract(baseline: dict[str, Any], current: dict[str, Any]) -> None:
    require(baseline["identity"] == current["identity"], "v4 identity cannot change")
    compare_proto(baseline, current)

    old_native = baseline["nativeTransport"]
    new_native = current["nativeTransport"]
    for key in (
        "clientBidirectionalStreams",
        "hostUnidirectionalStreams",
        "mediaDatagramHeader",
        "mediaKinds",
        "flags",
        "fecBlockExtension",
        "mediaCapabilities",
        "dynamicRangeTransport",
        "videoBootstrap",
        "telemetry",
        "validation",
    ):
        if key in old_native:
            require_preserved_value(old_native[key], new_native.get(key), f"v4 native authority {key}")
    for key in ("transportErrors", "packetArrivalFeedbackErrors"):
        require_preserved_list(old_native.get(key, []), new_native.get(key, []), key)

    if "lifecycle" in baseline:
        require_preserved_value(baseline["lifecycle"], current.get("lifecycle"), "v4 lifecycle")
    for authority in ("authentication", "settings"):
        old_routes = nested_routes(baseline["https"][authority])
        new_routes = nested_routes(current["https"][authority])
        for route, definition in old_routes.items():
            require(new_routes.get(route) == definition, f"removed or changed {authority} route: {route[0]} {route[1]}")

    old_auth = baseline["https"]["authentication"]
    new_auth = current["https"]["authentication"]
    for key, value in old_auth.items():
        if key != "errorCodes":
            require_preserved_value(value, new_auth.get(key), f"authentication {key}")
    require_preserved_list(
        old_auth.get("errorCodes", []),
        new_auth.get("errorCodes", []),
        "authentication error code",
    )

    old_settings = baseline["https"]["settings"]
    new_settings = current["https"]["settings"]
    for key, value in old_settings.items():
        if key not in {"errorCodes", "fields"}:
            require_preserved_value(value, new_settings.get(key), f"settings {key}")
    old_fields = {field["key"]: field for field in old_settings.get("fields", [])}
    new_fields = {field["key"]: field for field in new_settings.get("fields", [])}
    for key, field in old_fields.items():
        require(key in new_fields, f"removed settings field: {key}")
        require_preserved_value(field, new_fields[key], f"settings field {key}")
    require_preserved_list(
        old_settings.get("errorCodes", []),
        new_settings.get("errorCodes", []),
        "settings error code",
    )


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def legacy_baseline(args: argparse.Namespace, current: dict[str, Any]) -> dict[str, Any]:
    paths = {
        "protobuf": args.baseline_proto,
        "native transport": args.baseline_native,
        "authentication": args.baseline_auth,
        "settings": args.baseline_settings,
    }
    missing = [label for label, path in paths.items() if path is None]
    require(not missing, f"missing legacy baseline: {', '.join(missing)}")
    return {
        "identity": current["identity"],
        "protobuf": {"source": args.baseline_proto.read_text()},
        "nativeTransport": read_json(args.baseline_native),
        "https": {
            "authentication": read_json(args.baseline_auth),
            "settings": read_json(args.baseline_settings),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Reject breaking changes inside Lumen protocol v4.")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--baseline-proto", type=Path)
    parser.add_argument("--baseline-native", type=Path)
    parser.add_argument("--baseline-auth", type=Path)
    parser.add_argument("--baseline-settings", type=Path)
    parser.add_argument("--baseline-streaming-doc", type=Path)
    parser.add_argument("--baseline-settings-doc", type=Path)
    parser.add_argument("--current", type=Path, default=Path("docs/protocol/lumen-contract-v4.json"))
    parser.add_argument("--current-streaming-doc", type=Path, default=Path("docs/protocol/lumen-streaming-protocol.md"))
    parser.add_argument("--current-settings-doc", type=Path, default=Path("docs/protocol/lumen-settings-protocol.md"))
    args = parser.parse_args()
    try:
        current = read_json(args.current)
        baseline = read_json(args.baseline) if args.baseline is not None else legacy_baseline(args, current)
        compare_contract(baseline, current)
        if args.baseline_streaming_doc is not None:
            compare_documentation(
                args.baseline_streaming_doc.read_text(),
                args.current_streaming_doc.read_text(),
                "streaming documentation",
            )
        if args.baseline_settings_doc is not None:
            compare_documentation(
                args.baseline_settings_doc.read_text(),
                args.current_settings_doc.read_text(),
                "settings documentation",
            )
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"breaking Lumen v4 contract change: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
