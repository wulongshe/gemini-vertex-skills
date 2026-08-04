#!/usr/bin/env bash
# Install the skills for a SKILL.md-compatible coding agent.
#
# Usage:
#   ./install.sh claude  [--user | --project <dir>]   # -> .claude/skills/
#   ./install.sh codex   [--user | --project <dir>]   # -> .agents/skills/
#   ./install.sh copilot --project <dir>              # -> .github/skills/
#   ./install.sh --dir <skills-dir>                   # any other agent
#
# Default scope is --user (the agent's home-level skills directory).
# Each skill is copied with the shared common/ runtime vendored inside it, so
# installed skills are fully self-contained and can even be copied around
# individually afterwards.
#
# Claude Code users can install via the plugin instead (recommended):
#   /plugin marketplace add <owner>/gemini-vertex-skills
#   /plugin install gemini-vertex-skills
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILLS=(gemini-image gemini-video gemini-audio gcs-upload)

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

AGENT=""
SCOPE="user"
PROJECT=""
TARGET=""
while (($#)); do
  case "$1" in
    claude|codex|copilot) AGENT="$1"; shift ;;
    --user) SCOPE="user"; shift ;;
    --project) SCOPE="project"; PROJECT="${2:?--project requires a directory}"; shift 2 ;;
    --dir) TARGET="${2:?--dir requires a directory}"; shift 2 ;;
    -h|--help|*) usage ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  [[ -n "$AGENT" ]] || usage
  if [[ "$SCOPE" == "project" ]]; then
    [[ -d "$PROJECT" ]] || { echo "Error: project directory not found: $PROJECT" >&2; exit 1; }
    PROJECT="$(cd "$PROJECT" && pwd -P)"
  fi
  case "$AGENT/$SCOPE" in
    claude/user)     TARGET="$HOME/.claude/skills" ;;
    claude/project)  TARGET="$PROJECT/.claude/skills" ;;
    codex/user)      TARGET="$HOME/.agents/skills" ;;
    codex/project)   TARGET="$PROJECT/.agents/skills" ;;
    copilot/project) TARGET="$PROJECT/.github/skills" ;;
    copilot/user)    echo "Error: copilot skills are project-level; use --project <dir>" >&2; exit 1 ;;
  esac
fi

mkdir -p "$TARGET"
for s in "${SKILLS[@]}"; do
  rm -rf "${TARGET:?}/$s"
  cp -r "$REPO_DIR/skills/$s" "$TARGET/$s"
  cp -r "$REPO_DIR/common" "$TARGET/$s/common"
  echo "Installed: $TARGET/$s"
done

cat <<EOF

Done. Next steps:
  1. Create a .env at the root of the project you'll work in (see
     $REPO_DIR/.env.template) with:
       GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_LOCATION,
       GOOGLE_APPLICATION_CREDENTIALS, GOOGLE_CLOUD_STORAGE
     Skills find the nearest .env from your working directory upward;
     system environment variables are the fallback.
  2. Requirements on PATH: python3, curl, openssl (Pillow optional, for
     auto-compressing oversized reference images).
EOF
