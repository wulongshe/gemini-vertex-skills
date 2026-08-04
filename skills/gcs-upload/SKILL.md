---
name: gcs-upload
description: "Upload local files to the configured Google Cloud Storage bucket and print their gs:// URIs. Use whenever files (images, audio, video, any binary) need to be published to GCS — e.g. approved pipeline assets. Reads GOOGLE_CLOUD_STORAGE and GOOGLE_APPLICATION_CREDENTIALS from the nearest project .env, falling back to the system environment."
---

# GCS Upload

```bash
python3 scripts/gcs_upload.py <file> [<file> ...] [--prefix <folder>/]
```

The script lives at `scripts/gcs_upload.py` inside this skill's directory (the directory containing this SKILL.md) — invoke it with `python3` by prefixing that path with this skill's directory.

- Prints one line per file: `<gs://uri>\t<local path>` — parse stdout to map
  files to their URIs.
- Object names are CONTENT HASHES under the given prefix (without `--prefix`
  they land at the bucket root): idempotent, re-uploading identical content is
  a no-op server-side, and renamed/edited files never collide.
- Auth: mints a short-lived token from the service account in
  `GOOGLE_APPLICATION_CREDENTIALS`; bucket from `GOOGLE_CLOUD_STORAGE`. Both
  are read from the nearest `.env` (current project first, then the skill's
  install location), falling back to the system environment for keys the
  `.env` does not define.
- Batch many files in ONE invocation (single token mint); a per-file failure
  is reported on stderr and the exit code is non-zero, but other files still
  upload.
- Never print or echo credentials. The script reads them from the `.env` /
  service-account file itself; no key material is ever displayed.
