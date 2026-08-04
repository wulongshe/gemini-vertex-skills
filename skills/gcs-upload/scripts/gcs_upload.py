#!/usr/bin/env python3
"""Upload local files to Google Cloud Storage.

Usage:
  gcs_upload.py <file> [<file> ...] [--prefix <folder>/]

Without --prefix, objects are uploaded to the bucket root.

Prints one line per file:  <gs://uri>\t<local path>
Object names are content hashes (idempotent — re-uploading identical content
maps to the same object). Config (GOOGLE_CLOUD_STORAGE bucket,
GOOGLE_APPLICATION_CREDENTIALS service-account json) comes from the nearest
.env — $CLAUDE_PROJECT_DIR, then the current directory upward, then the
install location upward — falling back to the process environment for keys
the .env does not define.
"""
import hashlib
import mimetypes
import sys
import urllib.parse
import urllib.request
from pathlib import Path

# common/ is vendored into the skill on per-skill installs (install.sh), and a
# sibling of skills/ in the repo / Claude-plugin layout.
_HERE = Path(__file__).resolve()
_COMMON = _HERE.parents[1] / "common"
if not _COMMON.is_dir():
    _COMMON = _HERE.parents[3] / "common"
sys.path.insert(0, str(_COMMON))
from project_env import load_env  # noqa: E402
from vertex_auth import mint_token  # noqa: E402


def parse_args(args):
    """Split argv into (files, prefix). No --prefix means the bucket root."""
    prefix = ""
    if "--prefix" in args:
        i = args.index("--prefix")
        raw = args[i + 1].strip("/")
        del args[i:i + 2]
        prefix = raw + "/" if raw else ""
    else:
        for i, a in enumerate(args):
            if a.startswith("--prefix="):
                raw = a.split("=", 1)[1].strip("/")
                del args[i]
                prefix = raw + "/" if raw else ""
                break
    return args, prefix


def main():
    args, prefix = parse_args(sys.argv[1:])
    if not args:
        sys.exit(__doc__.strip())

    env, env_file, project_root = load_env(__file__)
    bucket = env.get("GOOGLE_CLOUD_STORAGE", "").removeprefix("gs://").rstrip("/")
    sa = env.get("GOOGLE_APPLICATION_CREDENTIALS", "")
    if not bucket or not sa:
        where = env_file or "a .env at your project root"
        sys.exit("Error: GOOGLE_CLOUD_STORAGE / GOOGLE_APPLICATION_CREDENTIALS "
                 f"not set (define them in {where} or the environment)")
    sa_path = Path(sa).expanduser()
    if not sa_path.is_absolute():
        sa_path = project_root / sa_path
    token = mint_token(str(sa_path),
                       scope="https://www.googleapis.com/auth/devstorage.read_write")

    failed = 0
    for name in args:
        f = Path(name)
        if not f.is_file():
            print(f"Error: not a file: {f}", file=sys.stderr)
            failed += 1
            continue
        body = f.read_bytes()
        digest = hashlib.sha256(body).hexdigest()[:12]
        obj = f"{prefix}{digest}{f.suffix.lower() or '.bin'}"
        mime = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
        url = ("https://storage.googleapis.com/upload/storage/v1/b/"
               f"{bucket}/o?uploadType=media&name="
               + urllib.parse.quote(obj, safe=""))
        try:
            urllib.request.urlopen(urllib.request.Request(
                url, data=body, method="POST",
                headers={"Authorization": f"Bearer {token}",
                         "Content-Type": mime}), timeout=600).read()
            print(f"gs://{bucket}/{obj}\t{f}")
        except Exception as e:
            print(f"Error uploading {f}: {e}", file=sys.stderr)
            failed += 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
