#!/usr/bin/env python3
"""Parser fixtures for cc-plan (protocol v1). Pure — no docker/host state needed."""
import importlib.machinery, importlib.util, os, sys, unittest
sys.dont_write_bytecode = True  # keep host/bin free of __pycache__

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("ccplan", os.path.join(HERE, "..", "bin", "cc-plan"))
spec = importlib.util.spec_from_loader("ccplan", loader)
ccplan = importlib.util.module_from_spec(spec)
loader.exec_module(ccplan)

SHA = "a" * 40


class ParsePlanMd(unittest.TestCase):
    def test_full_plan(self):
        errors = []
        plan = ccplan.parse_plan_md(
            "# T\n\nGOAL: ship it\nORCHESTRATOR: me\nSTATUS: active\n\n"
            "## Roster\n| session | repo/branch | task | depends on |\n|---|---|---|---|\n"
            "| s1 | r/b | do x | — |\n| s2 | r/c | do y | s1 |\n\n"
            "## Assignments\n| area | owner |\n|---|---|\n| db | s1 |\n", errors)
        self.assertEqual(plan["status"], "active")
        self.assertEqual(len(plan["roster"]), 2)
        self.assertEqual(plan["roster"][1]["depends_on"], "s1")
        self.assertEqual(plan["assignments"], [{"area": "db", "owner": "s1"}])
        self.assertEqual(errors, [])

    def test_malformed_roster_row_is_error_not_silence(self):
        errors = []
        plan = ccplan.parse_plan_md(
            "STATUS: active\n## Roster\n| a | b | c | d |\n|---|---|---|---|\n| broken | row |\n", errors)
        self.assertEqual(plan["roster"], [])
        self.assertTrue(any("malformed" in e for e in errors))

    def test_missing_status_is_error(self):
        errors = []
        ccplan.parse_plan_md("just prose\n", errors)
        self.assertTrue(any("no STATUS" in e for e in errors))


class ParseNotes(unittest.TestCase):
    def write(self, tmp, text):
        p = os.path.join(tmp, "n.md")
        with open(p, "w") as f: f.write(text)
        return p

    def test_typed_pr_and_commit(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            errors = []
            entries = ccplan.parse_notes(self.write(tmp,
                "## 2026-08-27T10:00:00Z\nSTATUS: done\n"
                f"UNBLOCKS: api pr repo=own/rep number=7 head={SHA}\n"
                f"UNBLOCKS: schema commit repo=own/rep sha={SHA} path=db/schema.sql\n"), errors)
            self.assertEqual(errors, [])
            u = entries[0]["unblocks"]
            self.assertEqual([x["type"] for x in u], ["pr", "commit"])
            self.assertEqual(u[0]["number"], 7)
            self.assertEqual(u[1]["path"], "db/schema.sql")

    def test_freetext_is_legacy_never_typed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            entries = ccplan.parse_notes(self.write(tmp,
                "## 2026-08-27T10:00:00Z\nSTATUS: done\nUNBLOCKS: trust me it is done\n"), [])
            self.assertEqual(entries[0]["unblocks"], [])
            self.assertEqual(entries[0]["legacy_unblocks"], ["trust me it is done"])

    def test_short_sha_is_not_evidence(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            entries = ccplan.parse_notes(self.write(tmp,
                f"## 2026-08-27T10:00:00Z\nUNBLOCKS: x commit repo=o/r sha={'a'*8} path=f\n"), [])
            self.assertEqual(entries[0]["unblocks"], [])
            self.assertEqual(len(entries[0]["legacy_unblocks"]), 1)

    def test_unsafe_path_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            errors = []
            entries = ccplan.parse_notes(self.write(tmp,
                f"## 2026-08-27T10:00:00Z\nUNBLOCKS: x commit repo=o/r sha={SHA} path=../../etc/passwd\n"),
                errors)
            self.assertEqual(entries[0]["unblocks"], [])
            self.assertTrue(any("unsafe path" in e for e in errors))

    def test_malformed_status_is_error_not_silence(self):
        # QA finding: "STATUS: done (all tests green)" silently parsed as no status
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            errors = []
            entries = ccplan.parse_notes(self.write(tmp,
                "## 2026-08-27T10:00:00Z\nSTATUS: done (all tests green)\n"), errors)
            self.assertIsNone(entries[0]["status"])
            self.assertTrue(any("malformed STATUS" in e for e in errors))

    def test_content_before_heading_is_flagged(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            errors = []
            ccplan.parse_notes(self.write(tmp, "stray text\n## 2026-08-27T10:00:00Z\nSTATUS: working\n"), errors)
            self.assertTrue(any("before first entry" in e for e in errors))


class RegisterRow(unittest.TestCase):
    PLAN = ("STATUS: active\n## Roster\n"
            "| session | repo/branch | task | depends on |\n|---|---|---|---|\n"
            "| s1 | r/b1 | build | — |\n"
            "| PLANNED | r/b2 | api work | s1 |\n\n## Log\n- created\n")

    def test_replaces_planned_row(self):
        new, action = ccplan.register_row(self.PLAN, "real-sess", "r/b2")
        self.assertIn("replaced", action)
        self.assertIn("| real-sess | r/b2 | api work | s1 |", new)
        self.assertNotIn("PLANNED", new)

    def test_appends_when_no_planned_match(self):
        new, action = ccplan.register_row(self.PLAN, "extra", "r/b3", task="t3", depends="s1")
        self.assertIn("appended", action)
        self.assertIn("| extra | r/b3 | t3 | s1 |", new)
        self.assertIn("| PLANNED | r/b2 |", new)  # untouched

    def test_append_without_trailing_newline(self):
        # QA finding: appending after a final roster row with no trailing \n merged rows
        new, action = ccplan.register_row(self.PLAN.rstrip("\n"), "tail-sess", "r/b9")
        self.assertIn("appended", action)
        self.assertIn("\n| tail-sess | r/b9 |", new)

    def test_no_roster_raises(self):
        with self.assertRaises(ValueError):
            ccplan.register_row("STATUS: active\nno tables here\n", "s", "r/b")


class EpochUTC(unittest.TestCase):
    def test_epoch_is_utc_regression(self):
        # 2026-08-27 bug: mktime applied the local DST offset -> ages 60min high under CEST
        self.assertEqual(ccplan.epoch("1970-01-01T00:00:00Z"), 0)
        self.assertEqual(ccplan.epoch("2026-08-27T12:00:00Z") - ccplan.epoch("2026-08-27T11:00:00Z"), 3600)

    def test_bad_timestamp_is_none(self):
        self.assertIsNone(ccplan.epoch("not-a-time"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
