import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import installed_app as probe


class InstalledAppTests(unittest.TestCase):
    def test_process_matching_requires_the_exact_installed_executable(self):
        output = f" 12 {probe.EXECUTABLE}\n13 /tmp/JazzCapture\n14 {probe.EXECUTABLE}-other\n"
        self.assertEqual(probe.matching_pids(output), [12])

    def test_absence_or_empty_queue_never_authorizes_actions(self):
        for pids in [None, [], [12], [12, 13]]:
            for provenance in [False, True]:
                value = probe.assessment(provenance, pids, {"automaticCandidates": 0})
                self.assertFalse(value["s5Qualified"])
                self.assertEqual(value["actionsPerformed"], [])
                self.assertIn(
                    "all_delivery_queues_not_attested_safe", value["blockers"]
                )
                self.assertFalse(value["startStopPauseQualified"])

    def test_queue_inventory_is_metadata_only_and_does_not_write(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for index, state in enumerate(["ready", "queued", "retryable", "rejected"]):
                (root / f"{index}.json").write_text(
                    json.dumps({"state": state, "private": "MUST_NOT_LEAK"})
                )
            before = {p.name: p.read_bytes() for p in root.iterdir()}
            result = probe.archive_queue_snapshot(root)
            self.assertTrue(result["inventoryComplete"])
            self.assertEqual(result["automaticCandidates"], 2)
            self.assertFalse(result["allDeliveryQueuesSafe"])
            self.assertNotIn("MUST_NOT_LEAK", json.dumps(result))
            self.assertEqual({p.name: p.read_bytes() for p in root.iterdir()}, before)
            self.assertIn(
                "archive_delivery_may_resume_on_launch",
                probe.assessment(True, [], result)["blockers"],
            )

    def test_missing_malformed_unknown_symlink_and_oversize_are_unknown(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.assertFalse(
                probe.archive_queue_snapshot(root / "absent")["inventoryComplete"]
            )
            path = root / "record.json"
            for raw in [
                b"{",
                b"{}",
                b'{"state":"UNTRUSTED_TEXT"}',
                b'{"state":{}}',
                b"x" * 131073,
            ]:
                path.write_bytes(raw)
                result = probe.archive_queue_snapshot(root)
                self.assertFalse(result["inventoryComplete"])
                self.assertNotIn("UNTRUSTED_TEXT", json.dumps(result))
            path.unlink()
            target = root / "source"
            target.write_text('{"state":"queued"}')
            path.symlink_to(target)
            self.assertFalse(probe.archive_queue_snapshot(root)["inventoryComplete"])

    def test_collector_has_no_launch_signal_tcc_or_credential_command(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "App.app"
            executable = app / "Contents/MacOS/JazzCapture"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"synthetic executable, not a qualification")
            (app / "Contents/Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": "dev.jazz.capture",
                        "CFBundleShortVersionString": "0.25.0",
                        "CFBundleVersion": "166.a2a019f",
                    }
                )
            )
            calls = []

            def run(args, **kwargs):
                calls.append(args)
                self.assertIn(args[0], ["/usr/bin/codesign", "/bin/ps"])
                if args[0] == "/usr/bin/codesign":
                    self.assertIn("--verify", args)
                    self.assertNotIn("--sign", args)
                    self.assertEqual(
                        args[args.index("-R") + 1], "=" + probe.REQUIREMENT
                    )
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            with (
                patch.object(probe, "APP", app),
                patch.object(probe, "EXECUTABLE", executable),
                patch.object(
                    probe,
                    "PILOT_SHA256",
                    hashlib.sha256(executable.read_bytes()).hexdigest(),
                ),
                patch.object(probe.subprocess, "run", run),
                patch.object(
                    probe,
                    "archive_queue_snapshot",
                    return_value={"inventoryComplete": False},
                ),
            ):
                result = probe.collect()
            self.assertTrue(result["provenanceMatchesPilot"])
            self.assertFalse(result["s5Qualified"])
            self.assertEqual(len(calls), 2)

    def test_receipt_is_exclusive_and_cannot_overwrite_prior_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            receipt = Path(folder) / "receipt.json"
            receipt.write_bytes(b"retained")
            with (
                patch("sys.argv", ["probe", "--receipt", str(receipt)]),
                patch.object(
                    probe, "collect", side_effect=AssertionError("must not run")
                ),
            ):
                with self.assertRaises(FileExistsError):
                    probe.main()
            self.assertEqual(receipt.read_bytes(), b"retained")


if __name__ == "__main__":
    unittest.main()
