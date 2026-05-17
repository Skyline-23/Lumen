import importlib.util
import json
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("run_lumen_quality_gate.py")
SPEC = importlib.util.spec_from_file_location("run_lumen_quality_gate", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
ROOT = Path(__file__).resolve().parents[2]


class RunLumenQualityGateTests(unittest.TestCase):
    def test_full_gate_contains_protocol_generation_and_no_open_tuist_generation(self) -> None:
        commands = [" ".join(step.command) for step in MODULE.build_steps(fast=False)]

        self.assertIn("python3 tools/protocol/generate_lumen_protocol.py --check", commands)
        self.assertIn("python3 tools/quality/lumen_protocol_quality_gate.py", commands)
        self.assertIn("python3 tools/quality/test_windows_protocol_adapter.py", commands)
        self.assertIn("tuist generate --no-open", commands)

    def test_fast_gate_skips_build_heavy_checks(self) -> None:
        commands = [" ".join(step.command) for step in MODULE.build_steps(fast=True)]

        self.assertIn("git diff --check", commands)
        self.assertNotIn("npm run build", commands)
        self.assertNotIn("xcodebuild test -workspace Lumen.xcworkspace -scheme LumenTuistTests", commands)

    def test_package_scripts_expose_standard_quality_gate_commands(self) -> None:
        package = json.loads((ROOT / "package.json").read_text())

        self.assertEqual(package["scripts"]["quality"], "python3 tools/quality/run_lumen_quality_gate.py")
        self.assertEqual(package["scripts"]["quality-fast"], "python3 tools/quality/run_lumen_quality_gate.py --fast")


if __name__ == "__main__":
    unittest.main()
