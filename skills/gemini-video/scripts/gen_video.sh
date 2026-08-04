#!/usr/bin/env bash
# Generate/extend videos by calling the Vertex AI API directly (Veo models).
# Usage: gen_video.sh <model> "<prompt>" [output.mp4] [media option] [--parameters '<JSON>']
#   media options — mutually exclusive, at most one per command (the Veo API
#   allows only one visual anchor per request):
#     --source-video src.mp4|gs://...mp4       video extension (+~7s continuing the source)
#     --key-frames start.png[,end.png]         image-to-video / start->end frame interpolation
#     --reference-images a.png,b.png           up to 3 asset images (text-to-video only)
# Fixed positional args are the ones needing local processing (file IO, base64);
# everything else goes through --parameters verbatim (Veo API field names).
# Results are written to <GOOGLE_CLOUD_STORAGE>/videos in GCS when that variable is
# set (fast download); otherwise the video is transferred inline (slow fallback).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PY="$SCRIPT_DIR/gemini_api.py"
# common/ is vendored into the skill on per-skill installs (install.sh), and a
# sibling of skills/ in the repo / Claude-plugin layout.
COMMON_DIR="$SCRIPT_DIR/../common"
[[ -d "$COMMON_DIR" ]] || COMMON_DIR="$SCRIPT_DIR/../../../common"
COMMON_DIR="$(cd "$COMMON_DIR" && pwd -P)"

# --- Argument parsing: positionals + named media options and --parameters ---
PARAMS_JSON=""
SOURCE_VIDEO=""
KEY_FRAMES=""
REF_IMAGES=""
POS=()
while (($#)); do
  case "$1" in
    --parameters)   PARAMS_JSON="${2:?Error: --parameters requires a JSON value}"; shift 2 ;;
    --parameters=*) PARAMS_JSON="${1#*=}"; shift ;;
    --source-video)   SOURCE_VIDEO="${2:?Error: --source-video requires a value}"; shift 2 ;;
    --source-video=*) SOURCE_VIDEO="${1#*=}"; shift ;;
    --key-frames)   KEY_FRAMES="${2:?Error: --key-frames requires a value}"; shift 2 ;;
    --key-frames=*) KEY_FRAMES="${1#*=}"; shift ;;
    --reference-images)   REF_IMAGES="${2:?Error: --reference-images requires a value}"; shift 2 ;;
    --reference-images=*) REF_IMAGES="${1#*=}"; shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
USAGE="Usage: gen_video.sh <model> \"<prompt>\" [output.mp4] [--source-video <mp4> | --key-frames <start[,end]> | --reference-images <a,b,c>] [--parameters '<JSON>']"
MODEL="${POS[0]:?$USAGE}"
PROMPT="${POS[1]:?$USAGE}"
OUTPUT="${POS[2]:-video.mp4}"
if (( ${#POS[@]} > 3 )); then
  echo "Error: unexpected positional argument: ${POS[3]} — media is passed via --source-video / --key-frames / --reference-images" >&2
  exit 1
fi

# --- Config: project-root .env first, then the process environment (shared loader).
source "$COMMON_DIR/load_env.sh"
source "$COMMON_DIR/utils.sh"
require_env GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_APPLICATION_CREDENTIALS
SA_FILE="$GOOGLE_APPLICATION_CREDENTIALS"
[[ -f "$SA_FILE" ]] || { echo "Error: credentials file not found: $SA_FILE" >&2; exit 1; }

# GCS output prefix from GOOGLE_CLOUD_STORAGE (bucket only, no folder)
STORAGE_URI=""
if [[ -n "${GOOGLE_CLOUD_STORAGE:-}" ]]; then
  _bucket="${GOOGLE_CLOUD_STORAGE%/}"
  [[ "$_bucket" == gs://* ]] || _bucket="gs://$_bucket"
  STORAGE_URI="$_bucket/videos"
fi

# --- Output path: relative/absolute both work; create missing directories;
# never overwrite (append a number instead).
OUTPUT="$(unique_output_path "$OUTPUT")"

BODYFILE=$(mktemp)
RESP=$(mktemp)
trap 'rm -f "$RESP" "$BODYFILE"' EXIT

python3 "$PY" build "$PROMPT" "$MODEL" "$SOURCE_VIDEO" "$KEY_FRAMES" "$REF_IMAGES" "$STORAGE_URI" "$PARAMS_JSON" > "$BODYFILE"
TOKEN=$(python3 "$COMMON_DIR/vertex_auth.py" "$SA_FILE")
MODEL_URL="https://${VERTEX_API_HOST}/v1/projects/${GOOGLE_CLOUD_PROJECT}/locations/${GOOGLE_CLOUD_LOCATION}/publishers/google/models/${MODEL}"
GEN_START=$SECONDS

# || true: on a transport failure (DNS, timeout) curl exits non-zero with
# HTTP_CODE "000" — fall through to the error path instead of dying silently.
HTTP_CODE=$(curl -s -m 300 -o "$RESP" -w "%{http_code}" \
  "${MODEL_URL}:predictLongRunning" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$BODYFILE") || true
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: submit failed, HTTP $HTTP_CODE" >&2
  print_api_error "$RESP"
  exit 1
fi
OPNAME=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$RESP")
echo "Task submitted (operation: ...${OPNAME: -30})."

# Heartbeat so a polling agent can see progress and doesn't assume the process
# hung (shared helper; piped output backs off from 5s to one line per 30s).
# The label tells the phase apart: "generating" while polling, "downloading" while fetching.
source "$COMMON_DIR/heartbeat.sh"
hb_start generating
trap 'hb_stop; rm -f "$RESP" "$BODYFILE"' EXIT

finish_hb() {
  hb_stop
  GEN_ELAPSED=$((SECONDS - GEN_START))
}

# Poll the operation until done. With storageUri the completed response is tiny;
# in the inline fallback it carries the whole video at a slow upstream rate, so
# the long per-request timeout is intentional and required.
STATUS=""
for _ in $(seq 1 90); do
  HTTP_CODE=$(curl -s -m 1800 -o "$RESP" -w "%{http_code}" \
    "${MODEL_URL}:fetchPredictOperation" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"operationName\": \"$OPNAME\"}") || true
  if [[ "$HTTP_CODE" == "200" ]]; then
    STATUS=$(python3 "$PY" status "$RESP" 2>/dev/null || echo "")
    if [[ "$STATUS" == "done" ]]; then break; fi
    if [[ "$STATUS" == "failed" ]]; then
      finish_hb
      echo "Error: video generation failed" >&2
      python3 "$PY" status "$RESP" > /dev/null || true   # re-run to surface the error detail on stderr
      exit 1
    fi
  fi
  sleep 10
done

if [[ "$STATUS" != "done" ]]; then
  finish_hb
  echo "Error: timed out waiting for video generation" >&2
  exit 1
fi

# Auto-detect the result location: gcsUri (GCS — fast download) or inline bytes.
RESULT=$(python3 "$PY" extract "$RESP" "$OUTPUT")
GCS_SRC=""
case "$RESULT" in
  gcs:*)
    GCS_OBJ="${RESULT#gcs:}"
    GCS_SRC="$GCS_OBJ"
    hb_stop
    hb_start downloading
    # Chunked parallel resumable download (cmd_download): 2MiB ranges fetched
    # concurrently, each part resumes from its existing bytes — dropped
    # connections and reruns only cost the missing data, and parallel ranges
    # multiply throughput on per-connection-throttled links. Part files are
    # kept on failure; the object stays in GCS regardless.
    DL_ERR=""
    GCS_TOKEN="$TOKEN" python3 "$PY" download "$GCS_OBJ" "$OUTPUT" || DL_ERR=1
    finish_hb
    if [[ -n "$DL_ERR" ]]; then
      echo "Error: GCS download failed ($GCS_OBJ)" >&2
      echo "Partial chunks kept next to $OUTPUT — rerun to resume, or fetch the gs:// object manually" >&2
      exit 1
    fi
    ;;
  inline)
    finish_hb
    ;;
  *)
    finish_hb
    echo "Error: no video data in completed operation" >&2
    head -c 300 "$RESP" >&2 || true
    exit 1
    ;;
esac

python3 "$PY" report "$OUTPUT" "$GEN_ELAPSED" "$GCS_SRC"
