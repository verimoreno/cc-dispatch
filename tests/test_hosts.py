"""Host registry → rendered command. Run: .venv/bin/python -m unittest tests.test_hosts"""
import os, unittest

os.environ.setdefault("CC_DISPATCH_SECRET", "x" * 32)
os.environ["CC_DISPATCH_HOSTS"] = "hel=local,lm-server=lm-server"
import main  # noqa: E402  (imports read the env above)


class Hosts(unittest.TestCase):
    def test_local_and_ssh_render(self):
        self.assertEqual(main.HOSTS, {"hel": "", "lm-server": "lm-server"})
        self.assertEqual(main.DEFAULT_HOST, "hel")
        self.assertEqual(main._ssh_wrap("hel", ["agent-deck", "ls", "--json"]), ["agent-deck", "ls", "--json"])
        self.assertEqual(
            main._ssh_wrap("lm-server", ["tmux", "send-keys", "-t", "s", "a b"]),
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "lm-server", "tmux send-keys -t s 'a b'"],
        )
        # one-host fallback: an old .env with only CC_DISPATCH_HOST still boots
        self.assertEqual(main._parse_hosts("", ""), {"hel": ""})
        self.assertEqual(main._parse_hosts("", "cc-host"), {"hel": "cc-host"})
        self.assertEqual(main._host(""), "hel")
        with self.assertRaises(main.HTTPException):
            main._host("nope")



class SpawnFailure(unittest.TestCase):
    def test_parked_error_is_reported(self):
        pane = "→ Repo: x\nERROR: <30G disk free on /home\ncc-spawn failed (exit 2)\n"
        orig = main._capture_pane
        try:
            main._capture_pane = lambda h, t: pane
            self.assertEqual(main._spawn_failure("hel", "@1"), "ERROR: <30G disk free on /home")
            main._capture_pane = lambda h, t: "→ Repo: x\ncloning...\n"
            self.assertIsNone(main._spawn_failure("hel", "@1"))
            self.assertIsNone(main._spawn_failure("hel", None))
        finally:
            main._capture_pane = orig

if __name__ == "__main__":
    unittest.main()
