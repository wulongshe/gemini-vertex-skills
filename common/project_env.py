"""Shared environment loading for Python skill scripts.

Mirrors common/load_env.sh: the .env file is located by searching
$CLAUDE_PROJECT_DIR, then the current working directory and its parents, then
the anchor script's directory and its parents. Values from the found .env take
precedence over the process environment; empty values do not mask environment
variables.
"""
import os
from pathlib import Path


def find_env_file(anchor):
    cpd = os.environ.get("CLAUDE_PROJECT_DIR")
    if cpd and (Path(cpd) / ".env").is_file():
        return Path(cpd) / ".env"
    for base in (Path.cwd(), Path(anchor).resolve().parent):
        for d in (base, *base.parents):
            if (d / ".env").is_file():
                return d / ".env"
    return None


def load_env(anchor):
    """Return (env, env_file, project_root) for the script at `anchor`."""
    env_file = find_env_file(anchor)
    env = dict(os.environ)
    if env_file:
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                v = v.strip().strip('"')
                if v:
                    env[k.strip()] = v
    project_root = env_file.parent if env_file else Path.cwd()
    return env, env_file, project_root
