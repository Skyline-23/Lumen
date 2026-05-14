import importlib.util
import types
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("eval_host_stream.py")
SPEC = importlib.util.spec_from_file_location("eval_host_stream", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class EvalHostStreamTests(unittest.TestCase):
    def test_requested_codecs_prefers_codec_suite(self) -> None:
        args = types.SimpleNamespace(codec="hevc", codec_suite="hevc,prores-proxy")
        self.assertEqual(MODULE.requested_codecs(args), ["hevc", "prores-proxy"])

    def test_parse_runtime_probe_output_parses_successful_probe(self) -> None:
        output = """
AUTORESEARCH_RUNTIME_PROBE_STATUS=ok
AUTORESEARCH_RUNTIME_PROBE_WIDTH=3512
AUTORESEARCH_RUNTIME_PROBE_HEIGHT=2290
AUTORESEARCH_RUNTIME_PROBE_FPS=120
AUTORESEARCH_RUNTIME_PROBE_CODEC=hevc
AUTORESEARCH_RUNTIME_PROBE_FRAMES=16
AUTORESEARCH_RUNTIME_PROBE_FRAME_RECORDS=20
AUTORESEARCH_RUNTIME_PROBE_TILED_FRAME_RECORDS=4
AUTORESEARCH_RUNTIME_PROBE_TILE_CONTRACT_READY_UPDATES=3
AUTORESEARCH_RUNTIME_PROBE_TILE_CONTRACT_INVALID_RECORDS=0
AUTORESEARCH_RUNTIME_PROBE_COMPLETE_FRAME_GROUPS=2
AUTORESEARCH_RUNTIME_PROBE_INCOMPLETE_FRAME_GROUPS=1
AUTORESEARCH_RUNTIME_PROBE_MAX_TILE_COUNT=2
AUTORESEARCH_RUNTIME_PROBE_MAX_ENCODED_LANE_COUNT=2
AUTORESEARCH_RUNTIME_PROBE_HDR_FRAMES=16
AUTORESEARCH_RUNTIME_PROBE_FIRST_FRAME_HDR=1
AUTORESEARCH_RUNTIME_PROBE_STARTUP_MS=742.500
AUTORESEARCH_RUNTIME_PROBE_AVG_CALLBACK_LATENCY_MS=8.700
AUTORESEARCH_RUNTIME_PROBE_MAX_CALLBACK_LATENCY_MS=10.300
AUTORESEARCH_RUNTIME_PROBE_RESTART_EVENTS=0
AUTORESEARCH_RUNTIME_PROBE_FAILURE_EVENTS=0
AUTORESEARCH_RUNTIME_PROBE_DROP_EVENTS=0
AUTORESEARCH_RUNTIME_PROBE_QUEUED_FRAMES=2
AUTORESEARCH_RUNTIME_PROBE_DROPPED_FRAMES=14
AUTORESEARCH_RUNTIME_PROBE_LAST_SEQ=20862881947186
AUTORESEARCH_RUNTIME_PROBE_LAST_HDR_SIGNALLED=1
AUTORESEARCH_RUNTIME_PROBE_SOURCE_BACKEND=skylight-display-stream
AUTORESEARCH_RUNTIME_PROBE_RAW_PRIVATE_DISPLAY_STREAM=true
AUTORESEARCH_RUNTIME_PROBE_RAW_PRIVATE_DISPLAY_STREAM_REQUESTED_PIXEL_FORMAT=0x78343230
AUTORESEARCH_RUNTIME_PROBE_RAW_PRIVATE_DISPLAY_STREAM_REQUESTED_MATRIX=unset
AUTORESEARCH_RUNTIME_PROBE_SKYLIGHT_SYNTHETIC_IDLE_REPLAY=true
AUTORESEARCH_RUNTIME_PROBE_SKYLIGHT_SYNTHETIC_IDLE_REPLAY_INTERVAL_MS=8.333
AUTORESEARCH_RUNTIME_PROBE_SKYLIGHT_PENDING_POLICY=callback-low-latency
AUTORESEARCH_RUNTIME_PROBE_SKYLIGHT_RECOMMENDED_PENDING_FRAME_COUNT=1
AUTORESEARCH_RUNTIME_PROBE_SOURCE_FRAME_COUNT=121
AUTORESEARCH_RUNTIME_PROBE_SOURCE_DISPLAY_DELTA_COUNT=120
AUTORESEARCH_RUNTIME_PROBE_SOURCE_LAST_DISPLAY_DELTA_MS=8.333
AUTORESEARCH_RUNTIME_PROBE_SOURCE_MIN_DISPLAY_DELTA_MS=8.100
AUTORESEARCH_RUNTIME_PROBE_SOURCE_MAX_DISPLAY_DELTA_MS=11.200
AUTORESEARCH_RUNTIME_PROBE_SOURCE_AVG_DISPLAY_DELTA_MS=8.368
AUTORESEARCH_RUNTIME_PROBE_SOURCE_REDUCED_DIRTY_SAMPLE_COUNT=120
AUTORESEARCH_RUNTIME_PROBE_SOURCE_AVG_REDUCED_DIRTY_COVERAGE_RATIO=0.391
AUTORESEARCH_RUNTIME_PROBE_SOURCE_MAX_REDUCED_DIRTY_COVERAGE_RATIO=0.744
AUTORESEARCH_RUNTIME_PROBE_SOURCE_AVG_REDUCED_DIRTY_RECT_COUNT=1.400
AUTORESEARCH_RUNTIME_PROBE_SOURCE_MAX_REDUCED_DIRTY_RECT_COUNT=4.000
AUTORESEARCH_RUNTIME_PROBE_SOURCE_UPDATE_DROP_SAMPLE_COUNT=120
AUTORESEARCH_RUNTIME_PROBE_SOURCE_AVG_UPDATE_DROP_COUNT=0.200
AUTORESEARCH_RUNTIME_PROBE_SOURCE_MAX_UPDATE_DROP_COUNT=2
AUTORESEARCH_RUNTIME_PROBE_SOURCE_APPROX_FRAME_RATE=119.500
AUTORESEARCH_RUNTIME_PROBE_SOURCE_CADENCE=near-target
AUTORESEARCH_RUNTIME_PROBE_SOURCE_HOT_PATH_DIAGNOSTICS=disabled
AUTORESEARCH_RUNTIME_PROBE_PRIVATE_CAPTURE_SOURCE_PIXEL_FORMAT=0x42475241
AUTORESEARCH_RUNTIME_PROBE_PRIVATE_CAPTURE_REQUESTED_PIXEL_FORMAT=0x78343230
AUTORESEARCH_RUNTIME_PROBE_PRIVATE_CAPTURE_EXTENDED_RANGE=true
AUTORESEARCH_RUNTIME_PROBE_PRIVATE_CAPTURE_CURSOR_COMPOSITION=metal-overlay-on-encode
AUTORESEARCH_RUNTIME_PROBE_PRIVATE_CAPTURE_SOURCE_COLOR_TRANSFORM=negotiated-source-primaries-to-hdr-signal
AUTORESEARCH_RUNTIME_PROBE_VT_USING_HARDWARE_ENCODER=true
AUTORESEARCH_RUNTIME_PROBE_VT_RECOMMENDED_PARALLELIZATION_LIMIT=6
AUTORESEARCH_RUNTIME_PROBE_VT_PIXEL_BUFFER_POOL_IS_SHARED=false
AUTORESEARCH_RUNTIME_PROBE_VT_STAGING_MODE=direct-iosurface
AUTORESEARCH_RUNTIME_PROBE_VT_STAGED_SOURCE_RELEASE_MODE=post-submit
AUTORESEARCH_RUNTIME_PROBE_VT_DIRECT_SUBMISSION_FRAME_COUNT=16
AUTORESEARCH_RUNTIME_PROBE_VT_STAGED_SUBMISSION_FRAME_COUNT=0
AUTORESEARCH_RUNTIME_PROBE_VT_SUBMITTED_FRAME_COUNT=16
AUTORESEARCH_RUNTIME_PROBE_VT_IMMEDIATE_REPLAY_SUBMISSION_COUNT=0
AUTORESEARCH_RUNTIME_PROBE_VT_SUPPRESSED_IMMEDIATE_REPLAY_COUNT=0
AUTORESEARCH_RUNTIME_PROBE_VT_MAX_INFLIGHT_STAGING_SLOTS=3
AUTORESEARCH_RUNTIME_PROBE_VT_PIXEL_BUFFER_CACHE_SIZE=2
"""
        metrics = MODULE.parse_runtime_probe_output(output)
        assert metrics is not None
        self.assertEqual(metrics["frames"], 16)
        self.assertEqual(metrics["frame_records"], 20)
        self.assertEqual(metrics["tiled_frame_records"], 4)
        self.assertEqual(metrics["tile_contract_ready_updates"], 3)
        self.assertEqual(metrics["tile_contract_invalid_records"], 0)
        self.assertEqual(metrics["complete_frame_groups"], 2)
        self.assertEqual(metrics["incomplete_frame_groups"], 1)
        self.assertEqual(metrics["max_tile_count"], 2)
        self.assertEqual(metrics["max_encoded_lane_count"], 2)
        self.assertEqual(metrics["codec"], "hevc")
        self.assertEqual(metrics["hdr_frames"], 16)
        self.assertTrue(metrics["first_frame_hdr"])
        self.assertEqual(metrics["startup_ms"], 742.5)
        self.assertEqual(metrics["last_seq"], 20862881947186)
        self.assertEqual(metrics["source_backend"], "skylight-display-stream")
        self.assertEqual(metrics["raw_private_display_stream"], "true")
        self.assertEqual(metrics["raw_private_display_stream_requested_pixel_format"], "0x78343230")
        self.assertEqual(metrics["raw_private_display_stream_requested_matrix"], "unset")
        self.assertEqual(metrics["skylight_synthetic_idle_replay"], "true")
        self.assertEqual(metrics["skylight_synthetic_idle_replay_interval_ms"], 8.333)
        self.assertEqual(metrics["skylight_pending_policy"], "callback-low-latency")
        self.assertEqual(metrics["skylight_recommended_pending_frame_count"], 1)
        self.assertEqual(metrics["source_frame_count"], 121)
        self.assertEqual(metrics["source_display_delta_count"], 120)
        self.assertEqual(metrics["source_last_display_delta_ms"], 8.333)
        self.assertEqual(metrics["source_min_display_delta_ms"], 8.1)
        self.assertEqual(metrics["source_max_display_delta_ms"], 11.2)
        self.assertEqual(metrics["source_avg_display_delta_ms"], 8.368)
        self.assertEqual(metrics["source_reduced_dirty_sample_count"], 120)
        self.assertEqual(metrics["source_update_drop_sample_count"], 120)
        self.assertEqual(metrics["source_max_update_drop_count"], 2)
        self.assertEqual(metrics["source_avg_reduced_dirty_coverage_ratio"], 0.391)
        self.assertEqual(metrics["source_max_reduced_dirty_coverage_ratio"], 0.744)
        self.assertEqual(metrics["source_avg_reduced_dirty_rect_count"], 1.4)
        self.assertEqual(metrics["source_max_reduced_dirty_rect_count"], 4.0)
        self.assertEqual(metrics["source_avg_update_drop_count"], 0.2)
        self.assertEqual(metrics["source_approx_frame_rate"], 119.5)
        self.assertEqual(metrics["source_cadence"], "near-target")
        self.assertEqual(metrics["source_hot_path_diagnostics"], "disabled")
        self.assertEqual(metrics["private_capture_source_pixel_format"], "0x42475241")
        self.assertEqual(metrics["private_capture_requested_pixel_format"], "0x78343230")
        self.assertEqual(metrics["private_capture_extended_range"], "true")
        self.assertEqual(metrics["private_capture_cursor_composition"], "metal-overlay-on-encode")
        self.assertEqual(
            metrics["private_capture_source_color_transform"],
            "negotiated-source-primaries-to-hdr-signal",
        )
        self.assertEqual(metrics["vt_using_hardware_encoder"], "true")
        self.assertEqual(metrics["vt_recommended_parallelization_limit"], "6")
        self.assertEqual(metrics["vt_pixel_buffer_pool_is_shared"], "false")
        self.assertEqual(metrics["vt_staging_mode"], "direct-iosurface")
        self.assertEqual(metrics["vt_staged_source_release_mode"], "post-submit")
        self.assertEqual(metrics["vt_direct_submission_frame_count"], 16)
        self.assertEqual(metrics["vt_staged_submission_frame_count"], 0)
        self.assertEqual(metrics["vt_submitted_frame_count"], 16)
        self.assertEqual(metrics["vt_immediate_replay_submission_count"], 0)
        self.assertEqual(metrics["vt_suppressed_immediate_replay_count"], 0)
        self.assertEqual(metrics["vt_max_inflight_staging_slots"], 3)
        self.assertEqual(metrics["vt_pixel_buffer_cache_size"], 2)

    def test_score_runtime_probe_rewards_live_progression(self) -> None:
        metrics = {
            "status": "ok",
            "width": 3512,
            "height": 2290,
            "fps": 120,
            "codec": "hevc",
            "frames": 24,
            "hdr_frames": 24,
            "first_frame_hdr": True,
            "startup_ms": 640.0,
            "avg_callback_latency_ms": 8.5,
            "max_callback_latency_ms": 10.0,
            "restart_events": 0,
            "failure_events": 0,
            "drop_events": 0,
            "queued_frames": 0,
            "dropped_frames": 0,
            "last_seq": 200,
            "last_hdr_signalled": True,
        }
        args = types.SimpleNamespace(
            target_fps=120,
            target_width=3512,
            target_height=2290,
            codec="hevc",
            battery_policy="adaptive-hdr",
        )
        score, components = MODULE.score_runtime_probe(metrics, args)
        self.assertGreater(score, 50.0)
        self.assertGreater(components["progression"], 0.0)
        self.assertGreater(components["partial_hdr"], 0.0)

    def test_score_runtime_probe_rejects_failed_probe(self) -> None:
        metrics = {
            "status": "error",
            "frames": 0,
            "codec": "hevc",
            "hdr_frames": 0,
            "first_frame_hdr": False,
            "startup_ms": 0.0,
            "avg_callback_latency_ms": 0.0,
            "max_callback_latency_ms": 0.0,
            "restart_events": 0,
            "failure_events": 1,
            "drop_events": 0,
            "queued_frames": 0,
            "dropped_frames": 0,
            "last_seq": 0,
            "last_hdr_signalled": False,
        }
        args = types.SimpleNamespace(
            target_fps=120,
            target_width=3512,
            target_height=2290,
            codec="hevc",
            battery_policy="adaptive-hdr",
        )
        score, components = MODULE.score_runtime_probe(metrics, args)
        self.assertEqual(score, 0.0)
        self.assertLess(components["probe_penalty"], 0.0)

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
        self.assertEqual(metrics["callback_count"], 1)
        self.assertEqual(metrics["accepted_packet_count"], 0)

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

    def test_score_runtime_rewards_progressing_session(self) -> None:
        log_contents = """
[2026-04-04 13:31:00.207]: Info: Publishing macOS bridge capture request displayID=182 codec=hevc streaming-profile=balanced queue=auto fps=120 size=3512x2290 requested-transport=sdr-base-hdr-overlay negotiated-transport=sdr-base-hdr-overlay hdr-stream=false sink-gamut=display-p3 sink-transfer=pq current-edr-headroom=1.2 potential-edr-headroom=16 current-peak-nits=120 potential-peak-nits=1600 effective-gamut=display-p3 effective-transfer=pq supports-frame-gated-hdr=true supports-hdr-tile-overlay=true supports-per-frame-hdr-metadata=true effective-hdr-metadata=true
[2026-04-04 13:31:00.300]: Info: External macOS encoded ingress stats: frames=12 queued=0 dropped=0 last-seq=12 producer-active=true last-seq-delta=1 last-display-delta-ms=8.3 last-packet-ts-delta-ms=8.3 last-callback-latency-ms=8.2
[2026-04-04 13:31:00.308]: Info: Mac bridge frame callback display-id=182 codec=hevc seq=10 seq-delta=1 display-time=1 display-delta-ms=8.0 callback-latency-ms=8.9 key=false hdr=true hdr-primaries=p3 hdr-transfer=pq hdr-matrix=709 hdr-mastering=true hdr-cll=true target-fps=120 target-size=3512x2290 queue=q1 capture-emitted=10 capture-dropped=0 capture-processing-failures=0 capture-restarts=0 capture-running=true capture-last-error=n/a capture-min-callback-latency-ms=8.1 capture-max-callback-latency-ms=9.0 capture-vt=n/a core-frame-count=10 core-queued=0 core-dropped=0 core-last-seq=10
[2026-04-04 13:31:00.316]: Info: Mac bridge frame callback display-id=182 codec=hevc seq=11 seq-delta=1 display-time=2 display-delta-ms=8.1 callback-latency-ms=9.1 key=false hdr=true hdr-primaries=p3 hdr-transfer=pq hdr-matrix=709 hdr-mastering=true hdr-cll=true target-fps=120 target-size=3512x2290 queue=q1 capture-emitted=11 capture-dropped=0 capture-processing-failures=0 capture-restarts=0 capture-running=true capture-last-error=n/a capture-min-callback-latency-ms=8.1 capture-max-callback-latency-ms=9.1 capture-vt=n/a core-frame-count=11 core-queued=0 core-dropped=0 core-last-seq=11
[2026-04-04 13:31:00.324]: Info: Mac bridge frame callback display-id=182 codec=hevc seq=12 seq-delta=1 display-time=3 display-delta-ms=8.3 callback-latency-ms=9.3 key=false hdr=true hdr-primaries=p3 hdr-transfer=pq hdr-matrix=709 hdr-mastering=true hdr-cll=true target-fps=120 target-size=3512x2290 queue=q1 capture-emitted=12 capture-dropped=0 capture-processing-failures=0 capture-restarts=0 capture-running=true capture-last-error=n/a capture-min-callback-latency-ms=8.1 capture-max-callback-latency-ms=9.3 capture-vt=n/a core-frame-count=12 core-queued=0 core-dropped=0 core-last-seq=12
"""
        with tempfile.NamedTemporaryFile("w+", delete=False) as handle:
            handle.write(log_contents)
            handle.flush()
            path = Path(handle.name)

        metrics = MODULE.parse_runtime_log(path)
        assert metrics is not None
        args = types.SimpleNamespace(
            target_fps=120,
            target_width=3512,
            target_height=2290,
            battery_policy="adaptive-hdr",
        )
        score, components = MODULE.score_runtime(metrics, args)
        self.assertGreater(score, 50.0)
        self.assertGreater(components["progression"], 0.0)
        self.assertGreater(components["latency"], 0.0)

    def test_score_runtime_rejects_thrashing_session_without_callbacks(self) -> None:
        log_contents = """
[2026-04-04 13:58:11.205]: Info: Publishing macOS bridge capture request displayID=183 codec=hevc streaming-profile=balanced queue=auto fps=120 size=3512x2290 requested-transport=sdr-base-hdr-overlay negotiated-transport=sdr-base-hdr-overlay hdr-stream=false sink-gamut=display-p3 sink-transfer=pq current-edr-headroom=3.2 potential-edr-headroom=16 current-peak-nits=320 potential-peak-nits=1600 effective-gamut=display-p3 effective-transfer=pq supports-frame-gated-hdr=true supports-hdr-tile-overlay=true supports-per-frame-hdr-metadata=true effective-hdr-metadata=true
[2026-04-04 13:58:19.148]: Info: External macOS encoded ingress stats: frames=0 queued=0 dropped=0 last-seq=0 producer-active=true last-seq-delta=0 last-display-delta-ms=-1 last-packet-ts-delta-ms=-1 last-callback-latency-ms=-1
[2026-04-04 13:58:19.148]: Warning: External macOS encoded ingress has not advanced frame delivery in the last 3s
[2026-04-04 13:58:20.143]: Info: External macOS encoded ingress first accepted packet codec=hevc idr=true bridge-key=true samplebuffer-idr=true hdr=false encoded=3512x2290 primaries=P3_D65 transfer=ITU_R_709_2 matrix=ITU_R_709_2 mastering=false cll=false sample-payload-mastering=false sample-payload-cll=false packet-mastering=false packet-cll=false seq=20818008916218 display-time=20818009139607
[2026-04-04 13:58:20.470]: Warning: External macOS encoded ingress callback latency spike seq=20818008916219 callback-latency-ms=91.3985 threshold-ms=80 packet-ts-delta-ms=1.46
[2026-04-04 13:58:20.471]: Warning: External macOS encoded ingress dropped a frame message=Source frame dropped before processing because the capture processing queue is saturated.
[2026-04-04 13:58:20.472]: Warning: External macOS encoded ingress dropped a frame message=core-forwarder-overflow
[2026-04-04 13:58:20.473]: Warning: External macOS encoded ingress is restarting the capture session after repeated queue saturation events run=3
[2026-04-04 13:58:20.474]: Warning: External macOS encoded ingress is waiting for an initial IDR packet before forwarding to the client
[2026-04-04 13:58:20.700]: Info: External macOS encoded ingress final stats: frames=1 queued=0 dropped=0 last-seq=20818008916218 producer-active=true last-seq-delta=0 last-display-delta-ms=-1 last-packet-ts-delta-ms=-1 last-callback-latency-ms=91.4
"""
        with tempfile.NamedTemporaryFile("w+", delete=False) as handle:
            handle.write(log_contents)
            handle.flush()
            path = Path(handle.name)

        metrics = MODULE.parse_runtime_log(path)
        assert metrics is not None
        args = types.SimpleNamespace(
            target_fps=120,
            target_width=3512,
            target_height=2290,
            battery_policy="adaptive-hdr",
        )
        score, components = MODULE.score_runtime(metrics, args)
        self.assertLess(score, 15.0)
        self.assertEqual(metrics["callback_count"], 0)
        self.assertGreater(metrics["accepted_packet_count"], 0)
        self.assertLessEqual(components["progression"], 0.0)


if __name__ == "__main__":
    unittest.main()
