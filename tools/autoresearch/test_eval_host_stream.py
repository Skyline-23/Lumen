import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("eval_host_stream.py")
SPEC = importlib.util.spec_from_file_location("eval_host_stream", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class EvalHostStreamTests(unittest.TestCase):
    def test_parse_runtime_log_detects_overlay_hdr_fix(self) -> None:
        log_contents = """
[2026-04-04 13:30:57.034]: Info: macOS virtual display color profile: gamut=display-p3 hdr_capable=true hdr_intent=true client_gamut=display-p3 client_transfer=pq current-edr-headroom=1.2 potential-edr-headroom=16 current-peak-nits=120 potential-peak-nits=1600
[2026-04-04 13:31:00.207]: Info: Publishing macOS bridge capture request displayID=182 codec=hevc streaming-profile=balanced queue=auto fps=120 size=3512x2290 requested-transport=sdr-base-hdr-overlay negotiated-transport=sdr-base-hdr-overlay hdr-stream=false sink-gamut=display-p3 sink-transfer=pq current-edr-headroom=1.2 potential-edr-headroom=16 current-peak-nits=120 potential-peak-nits=1600 effective-gamut=display-p3 effective-transfer=pq supports-frame-gated-hdr=true supports-hdr-tile-overlay=true supports-per-frame-hdr-metadata=true effective-hdr-metadata=true
[2026-04-04 13:31:01.000]: Info: Mac bridge frame callback display-id=182 codec=hevc seq=1 seq-delta=1 display-time=1 display-delta-ms=8.0 callback-latency-ms=9.2 key=true hdr=true hdr-primaries=p3 hdr-transfer=pq hdr-matrix=709 hdr-mastering=true hdr-cll=true target-fps=120 target-size=3512x2290 queue=q1 capture-emitted=1 capture-dropped=0 capture-processing-failures=0 capture-restarts=0 capture-running=true capture-last-error=n/a capture-min-callback-latency-ms=9.2 capture-max-callback-latency-ms=9.2 capture-vt=n/a core-frame-count=1 core-queued=0 core-dropped=0 core-last-seq=1
"""
        with tempfile.NamedTemporaryFile("w+", delete=False) as handle:
            handle.write(log_contents)
            handle.flush()
            path = Path(handle.name)

        metrics = MODULE.parse_runtime_log(path)
        assert metrics is not None
        self.assertEqual(metrics["fps"], 120)
        self.assertEqual(metrics["negotiated_transport"], "sdr-base-hdr-overlay")
        self.assertEqual(metrics["effective_transfer"], "pq")
        self.assertTrue(metrics["effective_hdr_metadata"])
        self.assertTrue(metrics["hdr_intent"])

    def test_parse_runtime_log_counts_saturation_and_overflow(self) -> None:
        log_contents = """
[2026-04-04 13:22:16.458]: Info: Publishing macOS bridge capture request displayID=181 codec=hevc streaming-profile=balanced queue=auto fps=60 size=3512x2290 requested-transport=sdr-base-hdr-overlay negotiated-transport=sdr-base-hdr-overlay hdr-stream=false sink-gamut=display-p3 sink-transfer=pq current-edr-headroom=1.2 potential-edr-headroom=16 current-peak-nits=120 potential-peak-nits=1600 effective-gamut=display-p3 effective-transfer=pq supports-frame-gated-hdr=true supports-hdr-tile-overlay=true supports-per-frame-hdr-metadata=true effective-hdr-metadata=true
[2026-04-04 13:22:36.766]: Warning: External macOS encoded ingress dropped a frame message=Source frame dropped before processing because the capture processing queue is saturated.
[2026-04-04 13:22:37.015]: Warning: External macOS encoded ingress dropped a frame message=core-forwarder-overflow
[2026-04-04 13:22:37.050]: Warning: External macOS encoded ingress callback latency spike seq=1 callback-latency-ms=98.0 threshold-ms=80.0 packet-ts-delta-ms=5.0
"""
        with tempfile.NamedTemporaryFile("w+", delete=False) as handle:
            handle.write(log_contents)
            handle.flush()
            path = Path(handle.name)

        metrics = MODULE.parse_runtime_log(path)
        assert metrics is not None
        self.assertEqual(metrics["saturation_count"], 1)
        self.assertEqual(metrics["overflow_count"], 1)
        self.assertEqual(metrics["callback_spike_count"], 1)


if __name__ == "__main__":
    unittest.main()
