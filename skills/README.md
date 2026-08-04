# Skills — internal architecture

```
gemini-vertex-skills/
├── .claude-plugin/         Claude Code plugin + marketplace manifests
├── skills/                 canonical skills (agent-neutral SKILL.md, core
│   ├── gemini-image/       spec only: name + description + body)
│   ├── gemini-video/
│   ├── gemini-audio/
│   └── gcs-upload/
├── common/                 shared runtime used by every skill
│   ├── load_env.sh         env loader (bash; sourced by the gen_*.sh scripts)
│   ├── project_env.py      env loader (python mirror of load_env.sh)
│   ├── vertex_auth.py      OAuth token minting from a service-account key
│   ├── heartbeat.sh        progress heartbeat (TTY refresh / piped backoff)
│   └── utils.sh            API error printer, output-path dedup, GCS upload
├── install.sh              copy installer for Codex / Claude / Copilot / --dir
└── .env.template
```

## How scripts find common/

Each script checks two locations relative to itself:

1. `<skill>/common/` — vendored copy, created by `install.sh` so that each
   installed skill is fully self-contained;
2. `../../../common/` — the sibling-of-`skills/` location used when running
   from this repo directly or from the installed Claude plugin (plugins are
   copied whole, so the relative layout survives).

## How scripts find the .env

Search order (first hit wins):

1. `$CLAUDE_PROJECT_DIR/.env` (injected by Claude Code, when present);
2. the current working directory, then each parent — the project the user is
   working in, which is the primary source once skills are installed globally;
3. the script's own location, then each parent — covers running from this
   repo (repo-root `.env`) and any install location.

Values in the found `.env` override the process environment; keys it does not
define (or leaves empty) fall back to the process environment. With no `.env`
anywhere, everything comes from the environment. A relative
`GOOGLE_APPLICATION_CREDENTIALS` resolves against the `.env`'s directory; `~`
is expanded.

## Cross-agent compatibility rules

- SKILL.md files use only the core Agent Skills spec (`name`, `description`,
  Markdown body) — no agent-specific frontmatter.
- Scripts never rely on agent-specific variables; `CLAUDE_PROJECT_DIR` is
  used opportunistically but never required.
- Agent-specific packaging lives outside the skills (`.claude-plugin/`);
  other agents simply ignore it.
