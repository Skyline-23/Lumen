import importlib.util
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("lumen_protocol_quality_gate.py")
SPEC = importlib.util.spec_from_file_location("lumen_protocol_quality_gate", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class LumenProtocolQualityGateTests(unittest.TestCase):
    def test_allows_protocol_literals_in_authority_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            authority = root / "src" / "lumen_protocol.h"
            authority.parent.mkdir(parents=True)
            authority.write_text("inline constexpr std::uint16_t hdr_frame_state_type = 0x3003;\n")

            self.assertEqual(MODULE.run_checks(root), [])

    def test_allows_protocol_literals_in_generated_authority_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            authority = root / "src" / "lumen_protocol_control_wire_generated.h"
            authority.parent.mkdir(parents=True)
            authority.write_text("inline constexpr std::uint16_t hdr_frame_state_type = 0x3003;\n")

            self.assertEqual(MODULE.run_checks(root), [])

    def test_rejects_protocol_literals_outside_authority_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "src" / "shadow_http.cpp"
            source.parent.mkdir(parents=True)
            source.write_text("auto packet = 0x3004;\n")

            violations = MODULE.run_checks(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "protocol-literal-authority")
        self.assertIn("0x3004", violations[0].message)

    def test_rejects_stale_generated_protocol_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            generator = root / "tools" / "protocol" / "generate_lumen_protocol.py"
            generator.parent.mkdir(parents=True)
            generator.write_text(
                textwrap.dedent(
                    """
                    from pathlib import Path

                    def find_stale_outputs(root):
                        return [Path("src/lumen_protocol_control_wire_generated.h")]
                    """
                )
            )

            violations = MODULE.run_checks(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "stale-generated-protocol")

    def test_rejects_forbidden_coordination_and_refresh_gates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            swift = root / "src" / "platform" / "macos" / "Projects" / "LumenMacBridge" / "Sources" / "Bad.swift"
            swift.parent.mkdir(parents=True)
            swift.write_text(
                textwrap.dedent(
                    """
                    let lock = NSLock()
                    if targetFrameRate >= 100 {
                        enableFastPath()
                    }
                    """
                )
            )

            violations = MODULE.run_checks(root)

        self.assertEqual(
            [violation.rule for violation in violations],
            ["forbidden-pattern", "forbidden-pattern"],
        )

    def test_rejects_equivalent_refresh_threshold_gates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            swift = root / "src" / "platform" / "macos" / "Projects" / "LumenMacBridge" / "Sources" / "Bad.swift"
            swift.parent.mkdir(parents=True)
            swift.write_text(
                textwrap.dedent(
                    """
                    if targetFrameRate > 100 {
                        enableFastPath()
                    }
                    if targetFrameRate == 100 {
                        enableOtherFastPath()
                    }
                    """
                )
            )

            violations = MODULE.run_checks(root)

        self.assertEqual(
            [violation.rule for violation in violations],
            ["forbidden-pattern", "forbidden-pattern"],
        )

    def test_rejects_oversized_protocol_functions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "src" / "lumen_protocol_adapter.h"
            source.parent.mkdir(parents=True)
            body = "\n".join(f"  do_step_{index}();" for index in range(MODULE.MAX_FUNCTION_LINES + 1))
            source.write_text(f"inline void build_contract() {{\n{body}\n}}\n")

            violations = MODULE.run_checks(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "protocol-function-size")

    def test_rejects_first_legacy_identity_outside_attribution_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "src" / "runtime_identity.cpp"
            source.parent.mkdir(parents=True)
            source.write_text(f'auto name = "{"Sun" + "shine"}";\n')

            violations = MODULE.run_checks(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "legacy-identity-boundary")

    def test_rejects_second_legacy_identity_outside_attribution_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "src" / "runtime_identity.cpp"
            source.parent.mkdir(parents=True)
            source.write_text(f'auto name = "{"Apo" + "llo"}";\n')

            violations = MODULE.run_checks(root)

        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "legacy-identity-boundary")

    def test_allows_legacy_identity_in_upstream_attribution_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            attribution = root / "src" / "platform" / "windows" / "utils.cpp"
            attribution.parent.mkdir(parents=True)
            attribution.write_text(f"// Modified from https://github.com/FrogTheFrog/{'Sun' + 'shine'}\n")

            self.assertEqual(MODULE.run_checks(root), [])


if __name__ == "__main__":
    unittest.main()
