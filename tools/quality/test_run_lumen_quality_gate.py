import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("run_lumen_quality_gate.py")
SPEC = importlib.util.spec_from_file_location("run_lumen_quality_gate", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class RunLumenQualityGateTests(unittest.TestCase):
    def test_full_gate_contains_native_protocol_checks_and_no_open_tuist_generation(self) -> None:
        commands = [" ".join(step.command) for step in MODULE.build_steps(fast=False)]
        test_command = (
            "tuist xcodebuild test -workspace Lumen.xcworkspace "
            "-scheme LumenTuistTests -destination platform=macOS"
        )

        self.assertIn("python3 tools/quality/lumen_protocol_quality_gate.py", commands)
        self.assertIn("tuist generate --no-open", commands)
        self.assertIn(test_command, commands)
        self.assertLess(commands.index("tuist generate --no-open"), commands.index(test_command))
        self.assertFalse(any(command.startswith("xcodebuild ") for command in commands))
        self.assertNotIn("npm run build", commands)

    def test_fast_gate_skips_build_heavy_checks(self) -> None:
        commands = [" ".join(step.command) for step in MODULE.build_steps(fast=True)]

        self.assertIn("git diff --check", commands)
        self.assertNotIn("npm run build", commands)
        self.assertFalse(any(command.startswith("tuist xcodebuild ") for command in commands))

    def test_quality_gate_is_a_direct_python_entrypoint(self) -> None:
        self.assertEqual(MODULE.main.__module__, "run_lumen_quality_gate")
        self.assertTrue(MODULE_PATH.is_file())


if __name__ == "__main__":
    unittest.main()
