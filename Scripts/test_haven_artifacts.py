#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("haven_artifacts", Path(__file__).with_name("haven_artifacts.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="haven-artifact-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "workspace"
        self.root.mkdir()
        self.spool = self.base / "spool"
        self.spool.mkdir(mode=0o700)
        self.config = self.base / "config.json"
        self.settings = {"schema": MODULE.SCHEMA, "ownerRef": "owner-test", "hostID": "host-test",
                         "roots": [{"path": str(self.root), "volumeID": "volume-test", "device": self.root.stat().st_dev}],
                         "spool": str(self.spool)}
        self.save_config()

    def save_config(self):
        self.config.write_text(json.dumps(self.settings))
        self.config.chmod(0o600)

    def collector(self):
        collector = MODULE.Collector(self.config)
        self.addCleanup(collector.close)
        return collector

    def start(self, collector, path=None):
        return collector.record("start", job="test-job", project="test-project", path=str(path or self.root))

    def test_writer_and_inventory_are_distinct_and_never_copy_contents(self):
        collector = self.collector()
        attempt = self.start(collector)
        artifact = self.root / "report.txt"
        artifact.write_text("SECRET-CONTENT-NOT-METADATA")
        collector.record("created", attempt=attempt, path=str(artifact))
        incidental = self.root / "concurrent.txt"
        incidental.write_text("another process")
        collector.record("finish", attempt=attempt, result="succeeded")
        data = collector.snapshot()
        by_path = {item["path"]: item for item in data["artifacts"]}
        self.assertEqual(by_path[str(artifact)]["createdBy"], attempt)
        self.assertEqual(by_path[str(artifact)]["originEvidence"], "registered_writer")
        self.assertIsNone(by_path[str(incidental)]["createdBy"])
        self.assertEqual(by_path[str(incidental)]["usedBy"], [])
        self.assertEqual(by_path[str(incidental)]["observedDuring"], [attempt])
        self.assertNotIn("SECRET-CONTENT-NOT-METADATA", MODULE.canonical(data))
        self.assertEqual(data["runs"][0]["coverage"], "partial")
        self.assertEqual(by_path[str(artifact)]["retentionStatus"], "unknown")

    def test_transient_files_are_not_claimed_as_complete_capture(self):
        collector = self.collector()
        attempt = self.start(collector)
        artifact = self.root / "transient"
        artifact.touch()
        artifact.unlink()
        collector.record("finish", attempt=attempt, result="succeeded")
        self.assertEqual(collector.snapshot()["runs"][0]["coverageReason"], "boundary_inventory_misses_transient_files")

    def test_shared_root_has_two_consumers_and_stays_active(self):
        collector = self.collector()
        first, second = self.start(collector), self.start(collector)
        collector.record("finish", attempt=first, result="succeeded")
        snapshot = collector.snapshot()
        root = next(item for item in snapshot["artifacts"] if item["path"] == str(self.root))
        self.assertEqual(set(root["usedBy"]), {first, second})
        self.assertEqual(root["retentionStatus"], "active")

    def test_restart_and_replay_are_byte_stable(self):
        collector = self.collector()
        self.start(collector)
        before = collector.snapshot()
        after = self.collector().snapshot()
        self.assertEqual(MODULE.canonical(before), MODULE.canonical(after))

    def test_snapshot_frame_is_complete_at_exact_byte_boundary(self):
        collector = self.collector()
        self.start(collector)
        expected = MODULE.canonical(collector.snapshot()).encode("utf-8") + b"\n"
        self.assertEqual(collector.encoded_snapshot(len(expected)), expected)
        with self.assertRaises(MODULE.SnapshotTooLarge):
            collector.encoded_snapshot(len(expected) - 1)
        self.assertEqual(collector.encoded_snapshot(len(expected)), expected)

    def test_oversized_snapshot_cli_emits_no_payload_and_preserves_replay(self):
        for index in range(20):
            (self.root / ("registrert-\u00e6\u00f8\u00e5-" + str(index))).touch()
        collector = self.collector()
        self.start(collector)
        before = collector.snapshot()
        command = [os.sys.executable, str(Path(__file__).with_name("haven_artifacts.py")),
                   "--config", str(self.config), "snapshot", "--max-bytes", "1024"]
        result = subprocess.run(command, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"snapshot_too_large", result.stderr)
        self.assertNotIn(str(self.root).encode(), result.stderr)
        self.assertEqual(before, self.collector().snapshot())
        # A later delivery with sufficient room gets every retained row.
        command[-1] = str(MODULE.MAX_SNAPSHOT_BYTES)
        result = subprocess.run(command, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), before)

    def test_invalid_snapshot_limits_fail_closed(self):
        collector = self.collector()
        self.start(collector)
        for maximum in (0, -1, 1023, MODULE.MAX_SNAPSHOT_BYTES + 1, True, "1024"):
            with self.assertRaises(MODULE.Rejected):
                collector.encoded_snapshot(maximum)

    def test_terminal_retry_is_idempotent_but_conflict_is_rejected(self):
        collector = self.collector()
        attempt = self.start(collector)
        collector.record("finish", attempt=attempt, result="failed")
        before = collector.snapshot()
        collector.record("finish", attempt=attempt, result="failed")
        self.assertEqual(before, collector.snapshot())
        with self.assertRaises(MODULE.Rejected):
            collector.record("finish", attempt=attempt, result="succeeded")

    def test_recovery_marks_interrupted_and_does_not_infer_deletion(self):
        collector = self.collector()
        artifact = self.root / "file"
        artifact.touch()
        attempt = self.start(collector)
        artifact.unlink()
        collector.record("recover", attempt=attempt, result="interrupted")
        snapshot = collector.snapshot()
        self.assertEqual(snapshot["runs"][0]["status"], "interrupted")
        self.assertEqual(next(item for item in snapshot["artifacts"] if item["path"] == str(artifact))["presence"], "not_observed")

    def test_path_replacement_does_not_inherit_creator(self):
        collector = self.collector()
        attempt = self.start(collector)
        artifact = self.root / "file"
        artifact.touch()
        collector.record("created", attempt=attempt, path=str(artifact))
        old_id = next(item["id"] for item in collector.snapshot()["artifacts"] if item["path"] == str(artifact))
        artifact.rename(self.root / "old")
        artifact.write_text("replacement")
        collector.record("finish", attempt=attempt, result="succeeded")
        items = [item for item in collector.snapshot()["artifacts"] if item["path"] == str(artifact)]
        self.assertEqual(len(items), 2)
        current = next(item for item in items if item["presence"] == "observed")
        self.assertNotEqual(current["id"], old_id)
        self.assertIsNone(current["createdBy"])

    def test_wrong_owner_or_host_cannot_rebind_journal(self):
        collector = self.collector()
        self.start(collector)
        for field in ("ownerRef", "hostID"):
            original = self.settings[field]
            self.settings[field] = "other"
            self.save_config()
            with self.assertRaises(MODULE.Rejected):
                MODULE.Collector(self.config)
            self.settings[field] = original

    def test_symlink_and_out_of_scope_and_excluded_writer_rejected(self):
        collector = self.collector()
        outside = self.base / "outside"
        outside.mkdir()
        (self.root / "escape").symlink_to(outside, target_is_directory=True)
        for path in (outside, self.root / "escape" / "child", self.root / ".env.secret"):
            with self.assertRaises(MODULE.Rejected):
                self.start(collector, path)

    def test_inventory_does_not_follow_symlinks_or_cross_mounts(self):
        (self.root / "link").symlink_to(self.base)
        collector = self.collector()
        inventory = collector.scan(self.root)
        self.assertEqual(len(inventory["entries"]), 1)
        self.assertIn("symlink_excluded", inventory["gaps"])
        collector.roots[0]["device"] += 1
        inventory = collector.scan(self.root)
        self.assertEqual(inventory["entries"], [])
        self.assertIn("volume_changed_or_mount_excluded", inventory["gaps"])

    def test_scan_limit_is_visible_and_does_not_infer_missing(self):
        (self.root / "a").touch()
        (self.root / "b").touch()
        collector = self.collector()
        attempt = self.start(collector)
        collector.maximum = 1
        collector.record("finish", attempt=attempt, result="succeeded")
        data = collector.snapshot()
        self.assertIn("scan_limit", data["runs"][0]["gaps"])
        self.assertTrue(all(item["presence"] == "observed" for item in data["artifacts"]))

    def test_private_config_and_spool_required(self):
        self.config.chmod(0o644)
        with self.assertRaises(MODULE.Rejected):
            MODULE.Collector(self.config)
        self.config.chmod(0o600)
        self.spool.chmod(0o755)
        with self.assertRaises(MODULE.Rejected):
            MODULE.Collector(self.config)

    def test_transaction_failure_leaves_no_partial_event(self):
        collector = self.collector()
        attempt = self.start(collector)
        before = collector.snapshot()
        collector.db.execute("CREATE TRIGGER refuse_insert BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'test'); END")
        with self.assertRaises(sqlite3.Error):
            collector.record("finish", attempt=attempt, result="succeeded")
        self.assertEqual(before, collector.snapshot())

    def test_fake_build_failure_is_preserved_and_recorded(self):
        fake = self.base / "fake-swift"
        fake.write_text("#!/bin/sh\nexit 17\n")
        fake.chmod(0o700)
        runner = Path(__file__).with_name("haven-swiftpm.sh")
        cache = self.root / "cache"
        result = subprocess.run(["bash", str(runner), "--cache-root", str(cache), "--cache-key", "unit-test",
                                 "--max-age-seconds", "0", "--max-cache-kib", "0", "--dry-run", "--", "build"],
                                env=dict(os.environ, SWIFT_BIN=str(fake), HAVEN_ARTIFACT_CONFIG=str(self.config)),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 17, result.stderr)
        data = self.collector().snapshot()
        self.assertEqual(data["runs"][0]["status"], "failed")
        cache_records = [item for item in data["artifacts"] if item["createdBy"]]
        self.assertTrue(cache_records)
        self.assertNotIn("fake-swift", MODULE.canonical(data))

    def test_unavailable_collection_does_not_change_wrapper_exit(self):
        fake = self.base / "fake-swift"
        fake.write_text("#!/bin/sh\nexit 0\n")
        fake.chmod(0o700)
        result = subprocess.run(["bash", str(Path(__file__).with_name("haven-swiftpm.sh")),
                                 "--cache-root", str(self.root / "cache"), "--cache-key", "unit-test",
                                 "--max-age-seconds", "0", "--max-cache-kib", "0", "--dry-run", "--", "build"],
                                env=dict(os.environ, SWIFT_BIN=str(fake), HAVEN_ARTIFACT_CONFIG="/missing-config"),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("degraded", result.stderr)


if __name__ == "__main__":
    unittest.main()
