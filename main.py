import json
import os
import shlex
import subprocess
import tempfile
import uuid
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.staticfiles import StaticFiles

app = FastAPI()

# Set CC_DISPATCH_HOST to an SSH alias to manage a remote cc-host.
# Leave unset (or empty) for local mode.
REMOTE_HOST = os.environ.get("CC_DISPATCH_HOST", "").strip()


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    if REMOTE_HOST:
        # SSH joins all trailing args into one shell string — quote each token.
        remote_cmd = " ".join(shlex.quote(a) for a in cmd)
        cmd = ["ssh", "-o", "BatchMode=yes", REMOTE_HOST, remote_cmd]
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def _run_tmux(tmux_session: str, args: list[str]):
    cmd = ["tmux"] + args
    if REMOTE_HOST:
        remote_cmd = " ".join(shlex.quote(a) for a in cmd)
        subprocess.run(["ssh", "-o", "BatchMode=yes", REMOTE_HOST, remote_cmd], check=True)
    else:
        subprocess.run(cmd, check=True)


def get_sessions() -> list[dict]:
    result = _run(["agent-deck", "ls", "--json"])
    if result.returncode != 0 or not result.stdout.strip():
        return []
    return json.loads(result.stdout)


def find_session(session_id: str) -> dict:
    session = next((s for s in get_sessions() if s["id"] == session_id), None)
    if not session:
        raise HTTPException(404, "Session not found")
    return session


def tmux_inject(tmux_session: str, text: str, send_enter: bool = True):
    _run_tmux(tmux_session, ["send-keys", "-t", tmux_session, "-l", text])
    if send_enter:
        _run_tmux(tmux_session, ["send-keys", "-t", tmux_session, "Enter"])


@app.get("/api/sessions")
def list_sessions():
    return get_sessions()


@app.get("/api/host")
def get_host():
    return {"host": REMOTE_HOST or "local"}


@app.post("/api/sessions/{session_id}/prompt")
async def send_prompt(session_id: str, body: dict):
    session = find_session(session_id)
    prompt = body.get("prompt", "").strip()
    if not prompt:
        raise HTTPException(400, "Empty prompt")
    tmux_inject(session["tmux_session"], prompt)
    return {"ok": True}


@app.post("/api/sessions/{session_id}/image")
async def send_image(
    session_id: str,
    file: UploadFile = File(...),
    prompt: Optional[str] = Form(None),
):
    session = find_session(session_id)
    ext = Path(file.filename).suffix if file.filename else ".png"
    fname = f"upload-{uuid.uuid4().hex[:8]}{ext}"
    remote_path = f"{session['path']}/{fname}"

    # Write upload to a temp file, then copy it to wherever the worktree lives.
    with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name

    try:
        if REMOTE_HOST:
            subprocess.run(
                ["scp", "-q", tmp_path, f"{REMOTE_HOST}:{remote_path}"],
                check=True,
            )
        else:
            import shutil
            shutil.copy(tmp_path, remote_path)
    finally:
        os.unlink(tmp_path)

    inject = f"~/work/{fname}"
    if prompt and prompt.strip():
        inject = f"{prompt.strip()} ~/work/{fname}"

    tmux_inject(session["tmux_session"], inject)
    return {"ok": True, "path": f"~/work/{fname}"}


@app.get("/api/github/repos")
def github_repos():
    result = subprocess.run(
        ["gh", "repo", "list", "--limit", "200", "--json", "name,owner,defaultBranchRef"],
        capture_output=True, text=True,
    )
    repos = json.loads(result.stdout) if result.returncode == 0 else []

    # Also pull org repos
    for org in ["wearefractional", "caua-veiga"]:
        r2 = subprocess.run(
            ["gh", "repo", "list", org, "--limit", "200", "--json", "name,owner,defaultBranchRef"],
            capture_output=True, text=True,
        )
        if r2.returncode == 0:
            repos += json.loads(r2.stdout)

    # Deduplicate by owner/name
    seen = set()
    out = []
    for r in repos:
        key = f"{r['owner']['login']}/{r['name']}"
        if key not in seen:
            seen.add(key)
            out.append({
                "full_name": key,
                "name": r["name"],
                "owner": r["owner"]["login"],
                "default_branch": r.get("defaultBranchRef", {}).get("name", "main"),
            })
    return sorted(out, key=lambda x: x["full_name"].lower())


@app.get("/api/github/repos/{owner}/{repo}/branches")
def github_branches(owner: str, repo: str):
    result = subprocess.run(
        ["gh", "api", f"repos/{owner}/{repo}/branches", "--paginate", "--jq", ".[].name"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise HTTPException(500, result.stderr)
    branches = [b for b in result.stdout.strip().splitlines() if b]
    return branches


@app.post("/api/sessions")
def create_session(body: dict):
    repo = body.get("repo", "").strip()
    branch = body.get("branch", "").strip()
    if not repo or not branch:
        raise HTTPException(400, "repo and branch required")
    # If repo contains an owner (owner/name), pass as a full git URL so cc-spawn
    # doesn't prepend its default org (wearefractional).
    repo_arg = repo
    if "/" in repo:
        repo_arg = f"git@github.com:{repo}.git"
    # Spawn in a detached tmux window on the target host.
    cmd = ["tmux", "new-window", f"cc-spawn {repo_arg} {branch}"]
    if REMOTE_HOST:
        cmd = ["ssh", "-o", "BatchMode=yes", REMOTE_HOST] + cmd
    subprocess.Popen(cmd)
    return {"ok": True}


app.mount("/", StaticFiles(directory="static", html=True), name="static")
