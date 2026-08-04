#!/usr/bin/env bash
# Shared environment loader — source this from a skill script.
#
# The .env file is located by searching, in order:
#   1. $CLAUDE_PROJECT_DIR/.env            (injected by Claude Code, if set)
#   2. the current working directory, then each parent up to /   (the project
#      the user is working in — the primary source for installed skills)
#   3. this loader's directory, then each parent up to /         (the install
#      location: repo root, plugin root, or a vendored skill copy)
#
# Values from the found .env take precedence over the process environment;
# keys the .env does not define (or leaves empty) fall back to the process
# environment. No .env anywhere is fine — everything then comes from the
# environment.
#
# Exposes to the sourcing script:
#   ENV_FILE            path of the .env in effect (empty if none was found)
#   PROJECT_ROOT        directory containing ENV_FILE, else the current dir
#   require_env VAR...  exit with an error if any listed variable is empty
#
# GOOGLE_APPLICATION_CREDENTIALS is normalized after loading: ~ is expanded and
# a relative path is resolved against PROJECT_ROOT, so it works from any cwd.

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

_find_env_file() {
  local d
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -f "$CLAUDE_PROJECT_DIR/.env" ]]; then
    echo "$CLAUDE_PROJECT_DIR/.env"
    return 0
  fi
  for d in "$PWD" "$_COMMON_DIR"; do
    while :; do
      if [[ -f "$d/.env" ]]; then
        echo "$d/.env"
        return 0
      fi
      [[ "$d" == "/" ]] && break
      d="$(dirname "$d")"
    done
  done
  true
}

ENV_FILE="$(_find_env_file)"
if [[ -n "$ENV_FILE" ]]; then
  PROJECT_ROOT="$(cd "$(dirname "$ENV_FILE")" && pwd -P)"
else
  PROJECT_ROOT="$PWD"
fi

if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    v="${v%$'\r'}"
    if [[ "$v" == \"*\" && "$v" == *\" && ${#v} -ge 2 ]]; then v="${v#\"}"; v="${v%\"}"; fi
    # Empty values in the .env do not mask variables set in the environment.
    if [[ -n "$v" ]]; then export "$k=$v"; fi
  done < "$ENV_FILE"
fi

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS/#\~/$HOME}"
  [[ "$GOOGLE_APPLICATION_CREDENTIALS" == /* ]] ||
    GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_ROOT/$GOOGLE_APPLICATION_CREDENTIALS"
  export GOOGLE_APPLICATION_CREDENTIALS
fi

# Vertex AI endpoint host: regional endpoints are prefixed with the region
# (us-central1-aiplatform.googleapis.com); the global endpoint is not.
if [[ -n "${GOOGLE_CLOUD_LOCATION:-}" ]]; then
  if [[ "$GOOGLE_CLOUD_LOCATION" == "global" ]]; then
    VERTEX_API_HOST="aiplatform.googleapis.com"
  else
    VERTEX_API_HOST="${GOOGLE_CLOUD_LOCATION}-aiplatform.googleapis.com"
  fi
fi

require_env() {
  local k
  for k in "$@"; do
    if [[ -z "${!k:-}" ]]; then
      echo "Error: $k not set (define it in ${ENV_FILE:-a .env at your project root} or export it in the environment)" >&2
      exit 1
    fi
  done
}
