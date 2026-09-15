#!/usr/bin/env python3
"""Dummy-only checks; no host credentials or real Claude calls."""
import builtins
import contextlib
import importlib.machinery
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

HOST = Path(__file__).resolve().parents[1]
a = importlib.machinery.SourceFileLoader('account', str(HOST / 'bin/cc-account')).load_module()
w = importlib.machinery.SourceFileLoader('wrapper', str(HOST / 'sessions/claude-account')).load_module()
TOKEN = 'dummy-owner-token-do-not-print'
OTHER = 'dummy-other-token-do-not-print'


def refuses(fn, *args):
    try:
        fn(*args)
    except (a.AccountError, OSError, SystemExit):
        return
    raise AssertionError('expected refusal')


out = io.StringIO()
with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
    a.ROOT = Path(tmp) / 'accounts'
    a.BINDINGS = Path(tmp) / 'bindings'
    for name in ('../diogo', 'Diogo', 'x/y', 'x;id', '', '-x', 'a'*33):
        refuses(a.account_path, name)
    refuses(a.check, 'unknown')
    real_open = builtins.open
    def tty_open(path, *args, **kwargs):
        return contextlib.nullcontext(io.StringIO()) if path == '/dev/tty' else real_open(path, *args, **kwargs)
    with patch.object(a.getpass, 'getpass', return_value=TOKEN), patch('builtins.open', side_effect=tty_open):
        # Only /dev/tty uses builtins.open; pathlib handles credential files.
        a.provision('diogo')
    p = a.check('diogo')
    (p / 'config/owner-note').write_text('keep')
    with patch.object(a.getpass, 'getpass', return_value=OTHER), patch('builtins.open', side_effect=tty_open):
        a.provision('diogo')
    assert (p / 'credentials/token').read_text().strip() == OTHER
    assert (p / 'config/owner-note').read_text() == 'keep'
    with patch.object(a.getpass, 'getpass', return_value=TOKEN), patch('builtins.open', side_effect=tty_open):
        a.provision('diogo')
    assert (p / 'credentials/token').read_text().strip() == TOKEN
    assert not (p / 'config/.credentials.json').exists()
    assert 'oauthAccount' not in json.loads((p / 'claude.json').read_text())
    assert (p / 'config/skills/cc-spawn-session/SKILL.md').exists()
    for bad in ('', '\n  ', 'two words'):
        (p / 'credentials/token').write_text(bad)
        refuses(a.check, 'diogo')
    (p / 'credentials/token').write_text(TOKEN)
    (p / 'credentials/token').chmod(0o644)
    refuses(a.check, 'diogo')
    (p / 'credentials/token').chmod(0o600)
    (p / 'credentials/token').unlink()
    refuses(a.check, 'diogo')
    (p / 'credentials/token').symlink_to(p / 'claude.json')
    refuses(a.check, 'diogo')
    (p / 'credentials/token').unlink()
    os.mkfifo(p / 'credentials/token', mode=0o600)
    refuses(a.check, 'diogo')
    (p / 'credentials/token').unlink()
    with patch.object(a.subprocess, 'check_output', return_value=''):
        a.match('default-session', '', pin=True)
        refuses(a.match, 'default-session', 'diogo')
        a.match('owner-session', 'diogo', pin=True)
        a.match('owner-session', 'diogo')
        refuses(a.match, 'owner-session', '')
        refuses(a.match, 'owner-session', 'other')
    # Running/stopped legacy container metadata and explicit account label.
    with patch.object(a.subprocess, 'check_output', side_effect=['legacy\n', '<no value>\n']):
        a.match('legacy', '')
    with patch.object(a.subprocess, 'check_output', side_effect=['selected\n', 'diogo\n']):
        refuses(a.match, 'selected', 'other')
    env = {'ANTHROPIC_API_KEY':OTHER, 'ANTHROPIC_AUTH_TOKEN':OTHER,
           'ANTHROPIC_BASE_URL':'https://wrong.invalid', 'CLAUDE_CODE_USE_BEDROCK':'1',
           'CLAUDE_CODE_OAUTH_TOKEN':OTHER, 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN':OTHER,
           'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR':'3', 'CLAUDE_CONFIG_DIR':'/wrong', 'PATH':'/bin'}
    with patch.dict(os.environ, env, clear=True), patch.object(Path, 'read_text', return_value=TOKEN), patch.object(os, 'execve') as execute:
        w.launch()
        binary, argv, actual = execute.call_args.args
        assert actual['CLAUDE_CODE_OAUTH_TOKEN'] == TOKEN
        assert OTHER not in json.dumps(actual)
        assert 'CLAUDE_CONFIG_DIR' not in actual
        assert not any(k.startswith('ANTHROPIC_') for k in actual)
        assert argv[-2:] == ['--setting-sources', 'user']
        assert TOKEN not in str(argv)
    with patch.object(Path, 'read_text', return_value=''), patch.object(os, 'execve') as execute:
        refuses(w.launch)
        execute.assert_not_called()
    # Real spawn entrypoint refuses bad accounts before touching repo or admission.
    for name in ('../bad', 'unknown'):
        env = dict(os.environ, PATH=str(HOST/'bin')+':'+os.environ['PATH'], CC_ACCOUNT=name, CC_BASE_DIR=tmp+'/repos')
        r = subprocess.run([str(HOST/'bin/cc-spawn'), '--detach', 'Internal-App', 'test/account'], env=env, capture_output=True, text=True)
        assert r.returncode != 0 and not Path(tmp+'/repos').exists()
        assert TOKEN not in r.stdout+r.stderr and OTHER not in r.stdout+r.stderr
assert TOKEN not in out.getvalue() and OTHER not in out.getvalue()
print('PASS: account validation, provisioning, permissions, isolation, precedence, fixed selection, secret-free output')
