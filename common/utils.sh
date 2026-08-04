#!/usr/bin/env bash
# Shared helpers for the gen_*.sh scripts — source after load_env.sh.

# Print the API error message from a JSON error-response file to stderr.
print_api_error() {
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('error', {}).get('message', json.dumps(d)[:500]), file=sys.stderr)
except Exception:
    print(open(sys.argv[1]).read()[:500], file=sys.stderr)
" "$1"
}

# Normalize an output path: create missing directories and, if the file already
# exists, append a counter instead of overwriting. Prints the path to use.
unique_output_path() {
  local out="$1" dir base ext i
  dir=$(dirname "$out")
  [[ -d "$dir" ]] || mkdir -p "$dir"
  [[ -e "$out" ]] || { echo "$out"; return; }
  if [[ "${out##*/}" == *.* ]]; then
    base="${out%.*}"; ext=".${out##*.}"
  else
    base="$out"; ext=""
  fi
  i=1
  while [[ -e "${base}-${i}${ext}" ]]; do i=$((i+1)); done
  echo "${base}-${i}${ext}"
}

# Upload a file to the GOOGLE_CLOUD_STORAGE bucket under the given prefix,
# named by its content hash (unique across sessions; identical content maps to
# the same object, so re-uploads are idempotent). A failure is a warning, not
# an error: the local file is the primary deliverable.
gcs_upload_file() {  # <file> <prefix> <token>
  local file="$1" prefix="$2" token="$3" bucket hash ext obj obj_enc mime code
  bucket="${GOOGLE_CLOUD_STORAGE%/}"
  bucket="${bucket#gs://}"
  hash=$(sha256sum "$file" | cut -c1-12)
  ext="${file##*.}"
  [[ "${file##*/}" == *.* ]] || ext=bin
  obj="${prefix}${hash}.${ext}"
  obj_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$obj")
  case "$ext" in
    png)      mime="image/png" ;;
    jpg|jpeg) mime="image/jpeg" ;;
    webp)     mime="image/webp" ;;
    wav)      mime="audio/wav" ;;
    mp4)      mime="video/mp4" ;;
    *)        mime="application/octet-stream" ;;
  esac
  code=$(curl -sf -m 600 -X POST -o /dev/null -w "%{http_code}" \
    "https://storage.googleapis.com/upload/storage/v1/b/${bucket}/o?uploadType=media&name=${obj_enc}" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: $mime" \
    --data-binary @"$file") || true
  if [[ "$code" == "200" ]]; then
    echo "Uploaded: gs://${bucket}/${obj}"
  else
    echo "Warning: GCS upload failed, HTTP $code (file saved locally at $file)" >&2
  fi
}
