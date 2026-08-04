#!/usr/bin/env bash
# Generate speech (Gemini TTS) or music (Lyria) by calling the Vertex AI API directly.
# Usage: gen_audio.sh <model> "<text|prompt>" [output.wav] [voices] [--generation-config '<JSON>'] [--parameters '<JSON>'] [--gcs]
#   model: gemini-2.5-flash-tts | gemini-2.5-pro-tts -> speech (generateContent)
#          lyria-002                                 -> instrumental music (predict, ~30s clip)
#   voices (TTS only, 4th slot): single voice "Kore", or multi-speaker "Alice=Kore,Bob=Puck"
# Fixed positional args are the ones needing local processing (voices expansion, WAV
# wrapping); everything else goes through --generation-config (TTS) or --parameters
# (Lyria) verbatim (native API field names).
# --gcs additionally uploads the result to <GOOGLE_CLOUD_STORAGE>/audios/ and
# prints its gs:// URI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PY="$SCRIPT_DIR/gemini_api.py"
# common/ is vendored into the skill on per-skill installs (install.sh), and a
# sibling of skills/ in the repo / Claude-plugin layout.
COMMON_DIR="$SCRIPT_DIR/../common"
[[ -d "$COMMON_DIR" ]] || COMMON_DIR="$SCRIPT_DIR/../../../common"
COMMON_DIR="$(cd "$COMMON_DIR" && pwd -P)"

# --- Argument parsing: positionals + named --generation-config / --parameters / --gcs ---
GEN_CONFIG=""
PARAMS_JSON=""
GCS_UPLOAD=""
POS=()
while (($#)); do
  case "$1" in
    --generation-config)   GEN_CONFIG="${2:?Error: --generation-config requires a JSON value}"; shift 2 ;;
    --generation-config=*) GEN_CONFIG="${1#*=}"; shift ;;
    --parameters)   PARAMS_JSON="${2:?Error: --parameters requires a JSON value}"; shift 2 ;;
    --parameters=*) PARAMS_JSON="${1#*=}"; shift ;;
    --gcs) GCS_UPLOAD=1; shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
USAGE="Usage: gen_audio.sh <model> \"<text|prompt>\" [output.wav] [voices] [--generation-config '<JSON>'] [--parameters '<JSON>'] [--gcs]"
MODEL="${POS[0]:?$USAGE}"
PROMPT="${POS[1]:?$USAGE}"
OUTPUT="${POS[2]:-audio.wav}"
VOICES="${POS[3]:-}"

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

python3 "$PY" build "$PROMPT" "$MODEL" "$VOICES" "$GEN_CONFIG" "$PARAMS_JSON" > "$BODYFILE"
TOKEN=$(python3 "$COMMON_DIR/vertex_auth.py" "$SA_FILE")
if [[ "$MODEL" == lyria* ]]; then METHOD=predict; else METHOD=generateContent; fi
ENDPOINT="https://${VERTEX_API_HOST}/v1/projects/${GOOGLE_CLOUD_PROJECT}/locations/${GOOGLE_CLOUD_LOCATION}/publishers/google/models/${MODEL}:${METHOD}"

# Heartbeat so a polling agent can see progress and doesn't assume the process
# hung (shared helper; piped output backs off from 5s to one line per 30s).
source "$COMMON_DIR/heartbeat.sh"
hb_start generating
GEN_START=$SECONDS
trap 'hb_stop; rm -f "$RESP" "$BODYFILE"' EXIT

# The response carries the audio inline as base64 (no GCS option on these APIs), and
# the link can degrade to tens of KB/s — a Lyria response is ~8MB. Bound the request
# by stall rather than total time — but the non-streaming API sends NOTHING until
# synthesis finishes, and a multi-minute TTS segment can take >60s to generate, so
# the stall window must cover generation time, not just link health.
HTTP_CODE=$(curl -s -m 3600 --speed-limit 1024 --speed-time 300 -o "$RESP" -w "%{http_code}" \
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

# Optional GCS upload of the saved audio to <bucket>/audios/ (shared helper;
# a failure is a warning, not an error — the local file is the deliverable).
if [[ -n "$GCS_UPLOAD" ]]; then
  gcs_upload_file "$OUTPUT" "audios/" "$TOKEN"
fi
