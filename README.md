# gemini-vertex-skills

Agent skills for generating media with the Vertex AI API, in the open
[Agent Skills](https://agentskills.io) format (SKILL.md) — works with Claude
Code, Codex CLI, GitHub Copilot, and any other SKILL.md-compatible agent.

| Skill | What it does | Models |
|-------|--------------|--------|
| `gemini-image` | Generate / edit images | gemini-2.5-flash-image |
| `gemini-video` | Generate / extend videos | veo-3.1 (lite / fast / standard) |
| `gemini-audio` | Speech (TTS) and instrumental music | gemini-2.5-flash/pro-tts, lyria-002 |
| `gcs-upload` | Upload files to a GCS bucket | — |

## Install

**Claude Code (plugin, recommended):**

```
/plugin marketplace add wulongshe/gemini-vertex-skills
/plugin install gemini-vertex-skills
```

**Codex CLI / Claude Code / Copilot (copy install):**

```bash
git clone https://github.com/wulongshe/gemini-vertex-skills.git
cd gemini-vertex-skills
./install.sh codex                      # -> ~/.agents/skills/
./install.sh claude                     # -> ~/.claude/skills/
./install.sh claude --project ~/my-app  # -> ~/my-app/.claude/skills/
./install.sh copilot --project ~/my-app # -> ~/my-app/.github/skills/
./install.sh --dir <path>               # any other SKILL.md-compatible agent
```

The installer vendors the shared `common/` runtime into each skill, so
installed skills are self-contained. Requirements: `python3`, `curl`,
`openssl` (Pillow optional, for auto-compressing oversized reference images).

## Configure

1. Create a GCP project, enable the **Vertex AI API**, and (for video/GCS
   features) create a **Cloud Storage bucket**.
2. Create a **service account**, grant it `Vertex AI User` and
   `Storage Object Admin` (for the bucket), and download a JSON key.
3. In the project where you'll use the skills, copy `.env.template` to `.env`
   and fill in:

```
GOOGLE_CLOUD_PROJECT=my-project
GOOGLE_CLOUD_LOCATION=us-central1
GOOGLE_APPLICATION_CREDENTIALS=~/keys/sa.json
GOOGLE_CLOUD_STORAGE=my-bucket
```

Skills locate the `.env` by searching `$CLAUDE_PROJECT_DIR`, then your
working directory upward, then their own install location upward. Values in
the `.env` take precedence; anything missing falls back to system environment
variables — so exporting the four variables works too, with no `.env` at all.

## Use

Just ask your agent ("generate an image of ...", "make a 8s video of ...",
"read this text aloud") — skills auto-activate from their descriptions. Each
skill's SKILL.md documents models, options, and cost notes; video and music
generation cost real money per call (see `skills/gemini-video/SKILL.md`).

## Repo layout

See [skills/README.md](skills/README.md) for the internal architecture.
