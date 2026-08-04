---
name: gemini-image
description: Generate images from text prompts or edit existing images using the Vertex AI API (Gemini image models). Use this skill whenever the user asks to generate, create, draw, edit, or render an image/picture/illustration/photo.
---

# Gemini Image Generation & Editing

Generate or edit images via the Vertex AI API using the bundled script. Do NOT hand-craft curl commands — the script handles credentials, request format, and PNG decoding.

## Usage

```bash
scripts/gen_image.sh <model> "<prompt>" [output.png] [reference-image] [--generation-config '<JSON>'] [--gcs]
```

The script lives at `scripts/gen_image.sh` inside this skill's directory (the directory containing this SKILL.md) — invoke it by prefixing that path with this skill's directory. Output paths are resolved from your working directory as usual.

Examples:

```bash
# Text-to-image, ultra-wide
scripts/gen_image.sh gemini-2.5-flash-image "a mountain panorama at dawn" pano.png --generation-config '{"imageConfig":{"aspectRatio":"21:9"}}'
# Edit an existing image
scripts/gen_image.sh gemini-2.5-flash-image "turn this into a night scene" night.png photo.jpg
```

- **model** (required, 1st argument): currently only `gemini-2.5-flash-image` is supported. More models may be added later.
- **prompt** (required): image description, or for editing, the change to apply. English prompts generally produce better results — translate the user's request into a detailed English prompt, but keep any text that must appear inside the image in its original language.
- **output.png** (optional, default `image.png`): relative or absolute paths both work; missing intermediate directories are created automatically. If the file exists, the script auto-appends a number instead of overwriting.
- **reference-image** (optional): a local png/jpg/jpeg/webp path or a `gs://` URI (must keep its file extension) switches to edit mode; oversized local files are compressed automatically, gs:// objects are referenced without downloading. The output follows the reference image's aspect ratio.
- **--generation-config** (optional): a JSON object merged verbatim into the API's `generationConfig` — see the field reference below.
- **--gcs** (optional flag): after saving locally, also upload the image to `images/` in the `GOOGLE_CLOUD_STORAGE` bucket (the object is named by its content hash, e.g. `a1b2c3d4e5f6.png`) and print `Uploaded: gs://...` — reuse that URI as a reference-image here or as media input in the gemini-video skill without re-uploading. An upload failure only prints a warning; the local file is still the result.

## `--generation-config` field reference

| Field | Values / notes |
|-------|----------------|
| `imageConfig.aspectRatio` | `"1:1"` (default), `"3:2"`, `"2:3"`, `"3:4"`, `"4:3"`, `"4:5"`, `"5:4"`, `"9:16"`, `"16:9"`, `"21:9"`. Text-to-image only; exact pixel dimensions cannot be requested (long edge ~1024–1344px). |
| `imageConfig.imageSize` | `"1K"`/`"2K"`/`"4K"` — documented for newer Gemini image models; `gemini-2.5-flash-image` is fixed at ~1024px and likely ignores it. |
| `personGeneration` | `"allow_all"`, `"allow_adult"` (default), `"dont_allow"` — safety policy for generating people. |
| `imageOutputOptions.mimeType` | `"image/png"` (default) or `"image/jpeg"`. |
| `temperature` | 0–2, sampling creativity; model default is usually fine. |
| `seed` | integer, for reproducible output with identical inputs. |
| `candidateCount` | leave unset — the script saves only the first image. |

`responseModalities` is set by the script (`["TEXT","IMAGE"]`) — do not override it.

## Behavior rules

- The script takes 20–120 seconds and prints heartbeat lines (`generating...(Ns)`) while working. If your shell tool backgrounds the process, you MUST keep polling the session (10+ polls if needed) until you see the final line: `Saved: <path>` on success, or an error message. Seeing only heartbeat lines means it is still working — keep waiting. NEVER end your turn or tell the user "please wait" while the process is still running; the process dies when you stop.
- The API generates exactly one image per call. For multiple images, run the script once per image.
- On success the script prints the saved path and dimensions — report these to the user.
- On failure it prints the API error message to stderr — relay it to the user; do not retry more than once.
- **NEVER view, open, or inspect the generated image** (no image-viewing tool, no reading the file). Media in tool responses breaks the session. Trust the script's success output — the printed path and dimensions are the verification.
- Never print or echo credentials. The script reads its configuration from the nearest `.env` (current project first, then its install location), falling back to system environment variables; no key material is ever displayed.
