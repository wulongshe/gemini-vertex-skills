---
name: gemini-video
description: Generate videos from text prompts or extend existing videos using the Vertex AI API (Veo models). Use this skill whenever the user asks to generate, create, or render a video/animation clip, or to continue/extend an existing video.
---

# Veo Video Generation & Extension

Generate or extend videos via the Vertex AI API using the bundled script. Do NOT hand-craft curl commands — the script handles credentials, the async submit/poll/download flow, and slow-transfer timeouts that naive curl calls get wrong.

## Usage

```bash
scripts/gen_video.sh <model> "<prompt>" [output.mp4] [--source-video <mp4>|--key-frames <start[,end]>|--reference-images <a,b,c>] [--parameters '<JSON>']
```

The script lives at `scripts/gen_video.sh` inside this skill's directory (the directory containing this SKILL.md) — invoke it by prefixing that path with this skill's directory. Output paths are resolved from your working directory as usual.

Examples:

```bash
# Text-to-video, 8s portrait with audio and a negative prompt
scripts/gen_video.sh veo-3.1-lite-generate-001 "waves crashing on rocks" waves.mp4 --parameters '{"durationSeconds":8,"aspectRatio":"9:16","generateAudio":true,"negativePrompt":"text, watermark"}'
# Extend an existing video (source can be a local mp4 or a gs:// URI from a previous run)
scripts/gen_video.sh veo-3.1-lite-generate-001 "the camera pans up to reveal a rainbow" longer.mp4 --source-video gs://bucket/videos/123/sample_0.mp4
# Image-to-video: animate a still image as the first frame
scripts/gen_video.sh veo-3.1-lite-generate-001 "the camera slowly zooms in as leaves drift by" animated.mp4 --key-frames photo.png
# Start->end frame transition
scripts/gen_video.sh veo-3.1-lite-generate-001 "smooth transition between the scenes" morph.mp4 --key-frames start.png,end.png
# Text-to-video guided by reference images (fast/standard models only)
scripts/gen_video.sh veo-3.1-fast-generate-001 "the character walks through a market" walk.mp4 --reference-images character.png,prop.png
```

- **model** (required, 1st argument): supported models and prices —
  - `veo-3.1-lite-generate-001` — $0.05/s (default choice, use unless the user asks for higher quality)
  - `veo-3.1-fast-generate-001` — $0.15/s
  - `veo-3.1-generate-001` — $0.40/s
- **prompt** (required): scene description, or for extension, what happens next. English prompts generally produce better results — translate the user's request into a detailed English prompt (subject, motion, camera, lighting). Limit ~1024 tokens.
- **output.mp4** (optional, default `video.mp4`): relative or absolute paths both work; missing intermediate directories are created automatically. If the file exists, the script auto-appends a number instead of overwriting.
- **media options** (optional, named): at most ONE of the three per command — verified: the Veo API allows only one visual anchor per request and rejects every pairwise combination ("Video/Image and reference images cannot be both set", "Image and video cannot both be set"). All media is processed locally (files base64-encoded, oversized images auto-compressed; `gs://` URIs pass through — they must keep their file extension; file names containing `,` are not supported).
  - **--source-video**: a `source.mp4` path or `gs://...mp4` URI → **video extension** (Veo adds ~7 seconds continuing the source; the output contains the full video and follows the source's orientation; prefer the `gs://` URI printed by a previous run to avoid re-uploading). The prompt is the only content guide in this mode.
  - **--key-frames**: `start.png` → **image-to-video** (the image becomes the first frame), or `start.png,end.png` → **start→end frame transition** (verified working on all three models). An end frame alone is not supported.
  - **--reference-images**: up to 3 comma-separated asset reference images guiding subject/character consistency (`referenceType` is fixed to `asset` — the only type veo-3.1 supports). Verified: NOT supported by the lite model (use fast/standard); **text-to-video only**.
- **--parameters** (optional): a JSON object merged verbatim into the Veo `parameters` block — see the field reference below.

## `--parameters` field reference

| Field | Values / notes |
|-------|----------------|
| `durationSeconds` | `4` (default), `6`, or `8`. Text-to-video only (extension always adds ~7s). |
| `aspectRatio` | `"16:9"` (default) or `"9:16"`. Exact pixel dimensions cannot be requested (720p ≈ 1280x720 / 720x1280). |
| `negativePrompt` | free text describing what must NOT appear (e.g. `"text, watermark, low quality"`). |
| `seed` | uint32 — same prompt + same seed reproduces the same video. |
| `generateAudio` | `true`/`false` — synchronized audio (dialogue/sfx) is a Veo 3.1 flagship feature. |
| `resolution` | `"720p"` (default) or `"1080p"`. Note: 1080p costs more on lite ($0.08/s vs $0.05/s). |
| `sampleCount` | 1 (script default) to 4. Each sample bills separately — total cost ×N; the script only saves the first, so leave at 1. |
| `personGeneration` | `"allow_adult"` (default), `"allow_all"`, `"dont_allow"`. |
| `enhancePrompt` | `true` (default) — Gemini rewrites/enriches the prompt automatically. |
| `compressionQuality` | `"optimized"` (default) or `"lossless"`. |
| `storageUri` | set automatically by the script (`GOOGLE_CLOUD_STORAGE` bucket + `/videos`); only override if you know what you are doing — unsetting it forces a very slow inline transfer. |

## Cost rules (real money — follow strictly)

- Every call is billed per second of generated video (see model prices above): lite 4s ≈ $0.20, standard 8s ≈ $3.20; extension bills the ~7 new seconds.
- Default to the lite model. Only use fast/standard when the user explicitly asks for higher quality, and state the estimated cost to the user before running (the script prints an estimate at submit time).
- On failure relay the error message; do not retry more than once (each retry costs money).

## Behavior rules

- **Generation typically takes 2–5 minutes end to end** (longer for extensions, and the result download can add several minutes on a slow link — it runs as parallel resumable chunks, and a failed/killed run resumes from its `.part` files on rerun). The script prints a heartbeat line while working — `generating...(Ns)` during generation, `downloading...(Ns)` while fetching the result. If your shell tool backgrounds the process, you MUST keep polling the session until you see the final line: `Saved: <path>` on success, or an error message. Seeing only heartbeat lines means it is still working — keep waiting. NEVER end your turn or tell the user "please wait" while the process is still running; the process dies when you stop.
- One generation at a time; for multiple clips run the script sequentially.
- On success report the saved path, duration, and elapsed time to the user. When the result was stored in GCS, the `Saved:` line also shows its `gs://` URI in brackets — reuse that URI as the extension source to avoid re-uploading. Note: these generated objects are cleaned up by the service after a retention period (observed: gone within days), so an older URI may have expired. If `--source-video` fails because the `gs://` object no longer exists, STOP and tell the user the link expired — do NOT silently re-upload the local file as a workaround.
- **NEVER view, open, or inspect the generated video or its frames** (no image-viewing tool, no reading the file). Media in tool responses breaks the session. Trust the script's `Saved:` line — it validates the mp4 and prints its duration.
- Never print or echo credentials. The script reads its configuration from the nearest `.env` (current project first, then its install location), falling back to system environment variables; no key material is ever displayed.
