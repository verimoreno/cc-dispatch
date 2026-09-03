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


class WaitsAndHandoff(unittest.TestCase):
    def parse(self, text, errors=None):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "n.md")
            with open(path, "w") as f: f.write(text)
            return ccplan.parse_notes(path, [] if errors is None else errors)

    def test_typed_waits(self):
        errors = []
        e = self.parse("## 2026-09-03T10:00:00Z\nSTATUS: blocked\nWAITS: api-schema from=s1\nWAITS: infra from=any\n", errors)
        self.assertEqual(e[0]["waits"], [{"name": "api-schema", "from": "s1"}, {"name": "infra", "from": "any"}])
        self.assertEqual(errors, [])

    def test_untyped_waits_is_legacy_and_error(self):
        errors = []
        e = self.parse("## 2026-09-03T10:00:00Z\nSTATUS: blocked\nWAITS: someone to fix the db\n", errors)
        self.assertEqual(e[0]["waits"], [])
        self.assertEqual(e[0]["legacy_waits"], ["someone to fix the db"])
        self.assertTrue(any("untyped WAITS" in x for x in errors))

    def test_handoff_block_ends_at_blank_or_keyword(self):
        e = self.parse("## 2026-09-03T10:00:00Z\nSTATUS: done\nHANDOFF:\nline one\nline two\n\nnot handoff\n"
                       f"UNBLOCKS: x pr repo=o/r number=1 head={SHA}\n")
        self.assertEqual(e[0]["handoff"], "line one\nline two")
        self.assertEqual(e[0]["prose"], ["not handoff"])
        self.assertEqual(len(e[0]["unblocks"]), 1)

    def test_handoff_inline_first_line(self):
        e = self.parse("## 2026-09-03T10:00:00Z\nHANDOFF: first\nsecond\nSTATUS: done\n")
        self.assertEqual(e[0]["handoff"], "first\nsecond")
        self.assertEqual(e[0]["status"], "done")

    def test_handoff_truncated_with_error(self):
        errors = []
        body = "\n".join(f"l{i}" for i in range(20))
        e = self.parse(f"## 2026-09-03T10:00:00Z\nHANDOFF:\n{body}\n", errors)
        self.assertEqual(len(e[0]["handoff"].splitlines()), ccplan.HANDOFF_MAX_LINES)
        self.assertEqual(sum("HANDOFF longer" in x for x in errors), 1)

    def test_prose_captured_without_keywords(self):
        e = self.parse("## 2026-09-03T10:00:00Z\nSTATUS: working\nfound the bug\nUNBLOCKS: free text\n")
        self.assertEqual(e[0]["prose"], ["found the bug"])


def sess(name, state="working", unblocks=(), waits=(), planned=False, depends="—", container="Up 2h"):
    return {"name": name, "repo_branch": f"r/{name}", "task": "t", "depends_on": depends, "planned": planned,
            "state": state, "unblocks": list(unblocks), "waits": [dict(w) for w in waits],
            "container": container, "latest_status": state if not planned else None, "release": None}


class ResolveReleases(unittest.TestCase):
    def claim(self, name, verified=None):
        c = {"type": "pr", "name": name, "repo": "o/r", "number": 1, "sha": SHA}
        if verified is not None: c["verified"] = verified
        return c

    def test_blocked_session_released_only_when_verified(self):
        a = sess("a", "done", unblocks=[self.claim("api", verified=True)])
        b = sess("b", "blocked", waits=[{"name": "api", "from": "a"}])
        rel = ccplan.resolve_releases([a, b], verify=True, contradictions=[])
        self.assertEqual(b["release"], "ready-to-resume")
        self.assertEqual(b["waits"][0]["resolution"], "satisfied")
        self.assertEqual(rel[0]["kind"], "resume"); self.assertTrue(rel[0]["verified"]); self.assertTrue(rel[0]["resident"])

    def test_unverified_claim_matches_but_holds(self):
        a = sess("a", "done", unblocks=[self.claim("api")])
        b = sess("b", "blocked", waits=[{"name": "api", "from": "any"}])
        rel = ccplan.resolve_releases([a, b], verify=False, contradictions=[])
        self.assertEqual(b["release"], "ready-to-resume-unverified")
        self.assertFalse(rel[0]["verified"])

    def test_refuted_claim_is_contradiction_not_release(self):
        a = sess("a", "done", unblocks=[self.claim("api", verified=False)])
        b = sess("b", "blocked", waits=[{"name": "api", "from": "a"}])
        contra = []
        rel = ccplan.resolve_releases([a, b], verify=True, contradictions=contra)
        self.assertEqual(rel, []); self.assertIsNone(b["release"])
        self.assertEqual(contra[0]["kind"], "waits-refuted")

    def test_from_restricts_source_and_self_never_matches(self):
        a = sess("a", "done", unblocks=[self.claim("api", verified=True)])
        b = sess("b", "blocked", unblocks=[self.claim("api", verified=True)], waits=[{"name": "api", "from": "c"}])
        rel = ccplan.resolve_releases([a, b], verify=True, contradictions=[])
        self.assertEqual(rel, []); self.assertEqual(b["waits"][0]["resolution"], "open")

    def test_planned_row_ready_when_deps_done_and_verified(self):
        a = sess("a", "done", unblocks=[self.claim("api", verified=True)])
        p = sess("PLANNED", planned=True, depends="a")
        q = sess("PLANNED", planned=True, depends="a, zz")
        rel = ccplan.resolve_releases([a, p, q], verify=True, contradictions=[])
        self.assertEqual(p["release"], "ready-to-spawn"); self.assertIsNone(q["release"])
        self.assertEqual([r["kind"] for r in rel], ["spawn"])

    def test_planned_row_without_deps_is_trivially_ready(self):
        p = sess("PLANNED", planned=True, depends="—")
        rel = ccplan.resolve_releases([p], verify=False, contradictions=[])
        self.assertEqual(p["release"], "ready-to-spawn"); self.assertTrue(rel[0]["verified"])

    def test_split_deps(self):
        self.assertEqual(ccplan.split_deps("s1, s2 s3"), ["s1", "s2", "s3"])
        self.assertEqual(ccplan.split_deps("—"), []); self.assertEqual(ccplan.split_deps(""), [])


class ContextPack(unittest.TestCase):
    def proj(self):
        a = sess("a", "done", unblocks=[{"type": "commit", "name": "schema", "repo": "o/r", "sha": SHA,
                                          "path": "db/s.sql", "verified": True, "verify_reason": "present"}])
        a.update(handoff="use the new column\nmigrations are behind", latest_time="2026-09-03T10:00:00Z",
                 latest_prose=[], legacy_unblocks=[])
        b = sess("b", "blocked", waits=[{"name": "schema", "from": "a"}])
        b.update(handoff=None, latest_time="2026-09-03T11:00:00Z", latest_prose=["need b-target's invite fix"],
                 legacy_unblocks=[])
        t = sess("b-target", "working", depends="a"); t.update(handoff=None, latest_time=None, latest_prose=[], legacy_unblocks=[])
        sessions = [a, b, t]
        ccplan.resolve_releases(sessions, True, [])
        return {"plan": "2026-09-x", "generated_at": "now", "goal": "ship", "sessions": sessions,
                "assignments": [{"area": "db", "owner": "a"}, {"area": "ui", "owner": "b-target"}]}

    def test_context_has_verified_artifact_handoff_and_blockers(self):
        proj = self.proj()
        ctx = ccplan.build_context(proj, ccplan.pick_session(proj, "b-target"))
        self.assertIn("schema: commit o/r@" + SHA, ctx); self.assertIn("VERIFIED", ctx)
        self.assertIn("  use the new column", ctx)
        self.assertIn("YOU OWN: ui", ctx); self.assertIn("DO NOT TOUCH: db → a", ctx)
        self.assertIn("#### b — blocked", ctx)   # its prose names b-target

    def test_pick_session_by_repo_branch_and_missing(self):
        proj = self.proj()
        self.assertEqual(ccplan.pick_session(proj, None, "r/a")["name"], "a")
        with self.assertRaises(KeyError): ccplan.pick_session(proj, "nope")


class InitPlan(unittest.TestCase):
    def test_init_and_adopt(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            old = ccplan.NOTES_ROOT; ccplan.NOTES_ROOT = tmp
            try:
                path, adopted = ccplan.init_plan("2026-09-fresh", goal="g", orchestrator="me")
                text = open(path).read()
                self.assertEqual(adopted, 0); self.assertIn("GOAL: g", text); self.assertIn("| PLANNED |", text)
                self.assertEqual(ccplan.parse_plan_md(text, [])["status"], "active")
                with self.assertRaises(FileExistsError): ccplan.init_plan("2026-09-fresh")
                # a dir with notes but no PLAN.md (the gcp-finish case) is adopted
                os.makedirs(os.path.join(tmp, "2026-09-old", "notes"))
                for n in ("u0", "u1"):
                    open(os.path.join(tmp, "2026-09-old", "notes", f"{n}.md"), "w").write("## 2026-09-03T00:00:00Z\nSTATUS: done\n")
                path, adopted = ccplan.init_plan("2026-09-old")
                errors = []; plan = ccplan.parse_plan_md(open(path).read(), errors)
                self.assertEqual(adopted, 2); self.assertEqual([r["session"] for r in plan["roster"]], ["u0", "u1"])
                self.assertEqual(errors, [])
                with self.assertRaises(ValueError): ccplan.init_plan("Bad_Id")
            finally:
                ccplan.NOTES_ROOT = old


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
