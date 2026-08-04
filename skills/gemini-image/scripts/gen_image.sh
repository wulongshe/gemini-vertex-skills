#!/usr/bin/env bash
# Generate/edit images by calling the Vertex AI API directly.
# Text-to-image: gen_image.sh <model> "<prompt>" [output.png] [--generation-config '<JSON>'] [--gcs]
# Image-to-image: gen_image.sh <model> "<edit instruction>" [output.png] <reference-image> [--generation-config '<JSON>'] [--gcs]
# Fixed positional args are the ones needing local processing (file IO, base64);
# everything else goes through --generation-config verbatim (Gemini API field names).
# --gcs additionally uploads the result to <GOOGLE_CLOUD_STORAGE>/images/ and
# prints its gs:// URI (reusable as a reference image without re-uploading).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PY="$SCRIPT_DIR/gemini_api.py"
# common/ is vendored into the skill on per-skill installs (install.sh), and a
# sibling of skills/ in the repo / Claude-plugin layout.
COMMON_DIR="$SCRIPT_DIR/../common"
[[ -d "$COMMON_DIR" ]] || COMMON_DIR="$SCRIPT_DIR/../../../common"
COMMON_DIR="$(cd "$COMMON_DIR" && pwd -P)"

# --- Argument parsing: positionals + named --generation-config / --gcs ---
GEN_CONFIG=""
GCS_UPLOAD=""
POS=()
while (($#)); do
  case "$1" in
    --generation-config)   GEN_CONFIG="${2:?Error: --generation-config requires a JSON value}"; shift 2 ;;
    --generation-config=*) GEN_CONFIG="${1#*=}"; shift ;;
    --gcs) GCS_UPLOAD=1; shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
USAGE="Usage: gen_image.sh <model> \"<prompt>\" [output.png] [reference-image] [--generation-config '<JSON>'] [--gcs]"
MODEL="${POS[0]:?$USAGE}"
PROMPT="${POS[1]:?$USAGE}"
OUTPUT="${POS[2]:-image.png}"
REF="${POS[3]:-}"
if [[ -n "$REF" && "$REF" != gs://* && ! -f "$REF" ]]; then
  echo "Error: reference image not found: $REF" >&2
  exit 1
fi

# --- Config: project-root .env first, then the process environment (shared loader).
source "$COMMON_DIR/load_env.sh"
source "$COMMON_DIR/utils.sh"
require_env GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_APPLICATION_CREDENTIALS
SA_FILE="$GOOGLE_APPLICATION_CREDENTIALS"
[[ -f "$SA_FILE" ]] || { echo "Error: credentials file not found: $SA_FILE" >&2; exit 1; }
if [[ -n "$GCS_UPLOAD" && -z "${GOOGLE_CLOUD_STORAGE:-}" ]]; then
  echo "Error: --gcs requires GOOGLE_CLOUD_STORAGE (define it in ${ENV_FILE:-a .env at your project root} or the environment)" >&2
  exit 1
fi

# --- Output path: relative/absolute both work; create missing directories;
# never overwrite (append a number instead).
OUTPUT="$(unique_output_path "$OUTPUT")"

BODYFILE=$(mktemp)
RESP=$(mktemp)
trap 'rm -f "$RESP" "$BODYFILE"' EXIT

python3 "$PY" build "$PROMPT" "$MODEL" "$REF" "$GEN_CONFIG" > "$BODYFILE"
TOKEN=$(python3 "$COMMON_DIR/vertex_auth.py" "$SA_FILE")
ENDPOINT="https://${VERTEX_API_HOST}/v1/projects/${GOOGLE_CLOUD_PROJECT}/locations/${GOOGLE_CLOUD_LOCATION}/publishers/google/models/${MODEL}:generateContent"

# Heartbeat so a polling agent can see progress and doesn't assume the process
# hung (shared helper; piped output backs off from 5s to one line per 30s).
source "$COMMON_DIR/heartbeat.sh"
hb_start generating
GEN_START=$SECONDS
trap 'hb_stop; rm -f "$RESP" "$BODYFILE"' EXIT

# || true: on a transport failure (DNS, timeout) curl exits non-zero with
# HTTP_CODE "000" — fall through to the error path instead of dying silently.
HTTP_CODE=$(curl -s -m 300 -o "$RESP" -w "%{http_code}" \
  "$ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$BODYFILE") || true

hb_stop
GEN_ELAPSED=$((SECONDS - GEN_START))

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: HTTP $HTTP_CODE" >&2
  print_api_error "$RESP"
  exit 1
fi

python3 "$PY" save "$RESP" "$OUTPUT" "$GEN_ELAPSED"

# Optional GCS upload of the saved image to <bucket>/images/ (shared helper;
# a failure is a warning, not an error — the local file is the deliverable).
if [[ -n "$GCS_UPLOAD" ]]; then
  gcs_upload_file "$OUTPUT" "images/" "$TOKEN"
fi
