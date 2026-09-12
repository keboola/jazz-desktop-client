import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from spool_inventory import inventory, tcc_snapshot


class InventoryTests(unittest.TestCase):
    def test_all_files_hashed_zero_families_explicit_and_no_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            journal = root / "spool/archives/.capture-journal/ar-test"
            journal.mkdir(parents=True)
            (journal / "state.json").write_text(
                json.dumps({"lifecycle": "committed", "private": "DO_NOT_REPORT"})
            )
            (root / "spool/blob").write_bytes(b"private bytes")
            before = {
                str(p.relative_to(root)): p.read_bytes()
                for p in root.rglob("*")
                if p.is_file()
            }
            result = inventory(root)
            self.assertTrue(result["complete"])
            self.assertEqual(result["checkpointLifecycles"], {"committed": 1})
            self.assertEqual(result["families"]["narration"]["files"], 0)
            self.assertFalse(result["controlledLaunchAllowed"])
            self.assertNotIn("DO_NOT_REPORT", json.dumps(result))
            self.assertEqual(
                before,
                {
                    str(p.relative_to(root)): p.read_bytes()
                    for p in root.rglob("*")
                    if p.is_file()
                },
            )
            (root / "spool/blob").write_bytes(b"changed bytes")
            self.assertNotEqual(inventory(root)["treeSHA256"], result["treeSHA256"])

    def test_symlinks_and_special_files_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "link").symlink_to("/tmp")
            self.assertFalse(inventory(root)["complete"])

    def test_confirmation_without_queue_and_forked_chain_are_not_safety(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            assertions = root / "spool/archives/.review/ar-test/assertions"
            assertions.mkdir(parents=True)
            first = {
                "assertionId": "assert-1",
                "scope": "archive",
                "target": {"kind": "archive", "id": "ar-test"},
                "decision": "confirm",
            }
            (assertions / "one.json").write_text(json.dumps(first))
            result = inventory(root)
            self.assertTrue(result["complete"])
            self.assertEqual(result["archiveReview"]["confirmedWithoutQueue"], 1)
            self.assertFalse(result["controlledLaunchAllowed"])
            (assertions / "two.json").write_text(
                json.dumps({**first, "assertionId": "assert-2"})
            )
            blocked = inventory(root)
            self.assertTrue(blocked["complete"])
            self.assertFalse(blocked["semanticChecksComplete"])
            self.assertFalse(blocked["archiveReview"]["valid"])

    def test_tcc_is_exact_client_readonly_and_live_wal_remains_unknown(self):
        with tempfile.TemporaryDirectory() as folder:
            db = Path(folder) / "TCC.db"
            with sqlite3.connect(db) as conn:
                conn.execute(
                    "CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER)"
                )
                conn.execute(
                    "INSERT INTO access VALUES ('kTCCServiceMicrophone','dev.jazz.capture',2)"
                )
                conn.execute(
                    "INSERT INTO access VALUES ('kTCCServiceAccessibility','other-client',2)"
                )
            before = db.read_bytes()
            result = tcc_snapshot(db)
            self.assertEqual(result["storedValues"], {"kTCCServiceMicrophone": 2})
            self.assertFalse(result["effectivePermissionsKnown"])
            self.assertEqual(db.read_bytes(), before)
            self.assertEqual(len(list(Path(folder).iterdir())), 1)
            db.with_name("TCC.db-wal").write_bytes(b"pending")
            self.assertEqual(tcc_snapshot(db)["status"], "not_read_live_wal")


if __name__ == "__main__":
    unittest.main()
