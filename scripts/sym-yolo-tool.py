#!/usr/bin/env python3
"""Call one bound Symphony MCP request. Descriptor carries no Linear credentials."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys


def checkout_proof(binding):
    # Do not chdir silently: the agent must actually invoke exec in the checkout.
    cwd = str(Path.cwd().resolve())
    expected = binding["checkout"]
    if cwd != str(Path(expected["workspace"]).resolve()):
        raise ValueError("wrong checkout")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

    def git(*args):
        return subprocess.check_output(["git", *args], env=env, stderr=subprocess.DEVNULL, timeout=10).decode().strip()

    root, sha = git("rev-parse", "--show-toplevel"), git("rev-parse", "HEAD")
    if str(Path(root).resolve()) != cwd or sha != expected["sha"] or git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("changed checkout")
    return dict(expected, cwd=cwd, git_root=cwd, clean=True)


def call(descriptor, request):
    with open(descriptor, encoding="utf-8") as stream:
        binding = json.load(stream)
    proof = checkout_proof(binding)
    with socket.create_connection(("127.0.0.1", binding["port"]), timeout=60) as client:
        client.sendall((json.dumps({"token": binding["token"], "checkout": proof, "request": request}) + "\n").encode())
        with client.makefile("rb") as response:
            return json.loads(response.readline(1_048_577))


if __name__ == "__main__":
    try:
        print(json.dumps(call(sys.argv[1], json.load(sys.stdin)), ensure_ascii=False))
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
        print(json.dumps({"error": "Symphony tool binding unavailable or checkout unverified; use the bound clean checkout and SHA"}))
        sys.exit(1)
