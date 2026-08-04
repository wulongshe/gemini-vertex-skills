---
name: gemini-audio
description: Generate speech from text (Gemini TTS, single or multi-speaker) or instrumental music (Lyria) using the Vertex AI API. Use this skill whenever the user asks to synthesize speech, read text aloud, create a voiceover/narration/dialogue audio, or generate music/background audio.
---

# Gemini Speech & Music Generation

Generate speech or music via the Vertex AI API using the bundled script. Do NOT hand-craft curl commands — the script handles credentials, request format, and WAV encoding (TTS models return raw PCM that is unplayable without the header the script adds).

## Usage

```bash
scripts/gen_audio.sh <model> "<text|prompt>" [output.wav] [voices] [--generation-config '<JSON>'] [--parameters '<JSON>'] [--gcs]
```

The script lives at `scripts/gen_audio.sh` inside this skill's directory (the directory containing this SKILL.md) — invoke it by prefixing that path with this skill's directory. Output paths are resolved from your working directory as usual.

Examples:

```bash
# Text-to-speech, default voice (Kore)
scripts/gen_audio.sh gemini-2.5-flash-tts "Welcome to the show! Let's get started." intro.wav
# Specific voice, with a style instruction prefixed to the text
scripts/gen_audio.sh gemini-2.5-flash-tts "Say in a calm, reassuring tone: Everything is going to be fine." calm.wav Enceladus
# Multi-speaker dialogue (speaker names in the text must match the voices slot)
scripts/gen_audio.sh gemini-2.5-flash-tts "TTS the following conversation:
Alice: Did you see the launch?
Bob: I did — absolutely incredible!" dialog.wav Alice=Kore,Bob=Puck
# Instrumental music (~30 second clip)
scripts/gen_audio.sh lyria-002 "upbeat acoustic folk with hand claps, sunny morning feel" music.wav --parameters '{"negativePrompt":"drums, electric guitar"}'
```

- **model** (required, 1st argument): supported models —
  - `gemini-2.5-flash-tts` — speech, default choice (~$0.015/min of audio)
  - `gemini-2.5-pro-tts` — speech, more natural delivery (~$0.03/min)
  - `lyria-002` — instrumental music only (no vocals), fixed ~30s clip, ~$0.06 per clip
- **text | prompt** (required): for TTS, the text to speak — it is spoken VERBATIM in its own language, so do NOT translate the user's text; steer style/emotion/pace with a natural-language instruction prefixed to the text (e.g. "Say cheerfully: ..."), and format multi-speaker dialogue as `Name: line` per line. For Lyria, a music description — English prompts work best (genre, instruments, mood, tempo).
- **output.wav** (optional, default `audio.wav`): relative or absolute paths both work; missing intermediate directories are created automatically. If the file exists, the script auto-appends a number instead of overwriting.
- **voices** (optional 4th slot, TTS only): a single voice name (`Kore`), or comma-separated `Speaker=Voice` pairs for multi-speaker dialogue (`Alice=Kore,Bob=Puck`; speaker names must match those used in the text). Defaults to `Kore`. Ignored by music models.
- **--generation-config** (optional, TTS only): a JSON object merged verbatim into `generationConfig` — e.g. `{"temperature":1.2}`. `responseModalities` and `speechConfig` are set by the script; overriding `speechConfig` here replaces the voices slot entirely.
- **--parameters** (optional, music only): a JSON object for the Lyria request — `sampleCount` (1–4, each bills separately; the script saves only the first, so leave at 1), `negativePrompt` (what to avoid, e.g. `"vocals, drums"`), `seed` (reproducibility; cannot be combined with `sampleCount` > 1). The script places each field where the API expects it.
- **--gcs** (optional flag): after saving locally, also upload the audio to `audios/` in the `GOOGLE_CLOUD_STORAGE` bucket (the object is named by its content hash, e.g. `a1b2c3d4e5f6.wav`) and print `Uploaded: gs://...`. An upload failure only prints a warning; the local file is still the result.

## TTS voices

30 prebuilt voices, all supporting multiple languages (the language is auto-detected from the text):

| Voice | Character | Voice | Character | Voice | Character |
|-------|-----------|-------|-----------|-------|-----------|
| Zephyr | Bright | Puck | Upbeat | Charon | Informative |
| Kore | Firm | Fenrir | Excitable | Leda | Youthful |
| Orus | Firm | Aoede | Breezy | Callirrhoe | Easy-going |
| Autonoe | Bright | Enceladus | Breathy | Iapetus | Clear |
| Umbriel | Easy-going | Algieba | Smooth | Despina | Smooth |
| Erinome | Clear | Algenib | Gravelly | Rasalgethi | Informative |
| Laomedeia | Upbeat | Achernar | Soft | Alnilam | Firm |
| Schedar | Even | Gacrux | Mature | Pulcherrima | Forward |
| Achird | Friendly | Zubenelgenubi | Casual | Vindemiatrix | Gentle |
| Sadachbia | Lively | Sadaltager | Knowledgeable | Sulafat | Warm |

## Output format

- TTS models: WAV, 24kHz 16-bit mono (the API returns raw PCM; the script wraps it).
- Lyria: WAV, 48kHz 16-bit stereo, ~30–33 seconds (clip length is not configurable).

## Cost rules (real money — follow strictly)

- TTS is cheap (fractions of a cent for short text); Lyria bills ~$0.06 per 30s clip per sample.
- On failure relay the error message; do not retry more than once (each retry costs money).

## Behavior rules

- TTS finishes in seconds; Lyria takes 10–60 seconds to generate, but the ~8MB inline response can take **several minutes to transfer on a slow link**. The script prints heartbeat lines (`generating...(Ns)`) while working. If your shell tool backgrounds the process, you MUST keep polling the session until you see the final line: `Saved: <path>` on success, or an error message. Seeing only heartbeat lines means it is still working — keep waiting. NEVER end your turn or tell the user "please wait" while the process is still running; the process dies when you stop.
- One generation at a time; for multiple clips run the script sequentially.
- On success the script prints the saved path, duration, and format — report these to the user.
- **NEVER play, open, or inspect the generated audio** (no media tool, no reading the file). Media in tool responses breaks the session. Trust the script's `Saved:` line — it validates the audio and prints its duration.
- Never print or echo credentials. The script reads its configuration from the nearest `.env` (current project first, then its install location), falling back to system environment variables; no key material is ever displayed.
