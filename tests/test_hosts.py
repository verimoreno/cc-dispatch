"""Host registry → rendered command. Run: .venv/bin/python -m unittest tests.test_hosts"""
import os, unittest

os.environ.setdefault("CC_DISPATCH_SECRET", "x" * 32)
os.environ["CC_DISPATCH_HOSTS"] = "hel=local,home=lm-server"
import main  # noqa: E402  (imports read the env above)


class Hosts(unittest.TestCase):
    def test_local_and_ssh_render(self):
        self.assertEqual(main.HOSTS, {"hel": "", "home": "lm-server"})
        self.assertEqual(main.DEFAULT_HOST, "hel")
        self.assertEqual(main._ssh_wrap("hel", ["agent-deck", "ls", "--json"]), ["agent-deck", "ls", "--json"])
        self.assertEqual(
            main._ssh_wrap("home", ["tmux", "send-keys", "-t", "s", "a b"]),
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "lm-server", "tmux send-keys -t s 'a b'"],
        )
        # one-host fallback: an old .env with only CC_DISPATCH_HOST still boots
        self.assertEqual(main._parse_hosts("", ""), {"hel": ""})
        self.assertEqual(main._parse_hosts("", "cc-host"), {"hel": "cc-host"})
        self.assertEqual(main._host(""), "hel")
        with self.assertRaises(main.HTTPException):
            main._host("nope")


if __name__ == "__main__":
    unittest.main()
