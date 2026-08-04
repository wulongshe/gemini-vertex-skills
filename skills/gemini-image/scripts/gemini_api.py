#!/usr/bin/env python3
"""gemini-image skill helper: request building, response parsing.
(Auth tokens come from the shared skills/common/vertex_auth.py.)

Subcommands:
    build <prompt> <model> <ref> <user-json>   -> prints request body JSON (info on stderr)
    save  <resp-file> <output> <elapsed>       -> saves image, prints the Saved line
"""
import base64
import json
import os
import struct
import sys


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def _encode_reference(ref):
    """Turn a reference image (local path or gs:// URI) into a request part.
    Local files are base64-encoded (oversized ones auto-compressed); gs:// URIs
    are referenced via fileData without downloading."""
    mime = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
            '.webp': 'image/webp'}.get(os.path.splitext(ref)[1].lower())
    if ref.startswith('gs://'):
        return {'fileData': {'fileUri': ref, 'mimeType': mime or 'image/png'}}
    if not mime:
        die('Error: reference image must be png/jpg/jpeg/webp')
    data = open(ref, 'rb').read()
    if len(data) > 4 * 1024 * 1024:
        try:
            import io
            from PIL import Image
            im = Image.open(io.BytesIO(data))
            im.thumbnail((1536, 1536))
            buf = io.BytesIO()
            im.convert('RGB').save(buf, 'JPEG', quality=90)
            data, mime = buf.getvalue(), 'image/jpeg'
        except ImportError:
            if len(data) > 15 * 1024 * 1024:
                die('Error: reference image exceeds 15MB and PIL is unavailable '
                    'for auto-compression; downscale it first')
    return {'inlineData': {'mimeType': mime, 'data': base64.b64encode(data).decode()}}


def cmd_build(prompt, model, ref, user_json):
    """Build the generateContent request body.

    Fixed handling: prompt text and the optional reference image (base64).
    Everything else comes from user_json and is merged verbatim into
    generationConfig (user values override defaults).
    """
    parts = [{'text': prompt}]
    if ref:
        parts.append(_encode_reference(ref))
    gen_config = {'responseModalities': ['TEXT', 'IMAGE']}
    if user_json:
        try:
            user = json.loads(user_json)
        except json.JSONDecodeError as e:
            die(f'Error: --generation-config is not valid JSON: {e}')
        if not isinstance(user, dict):
            die('Error: --generation-config must be a JSON object')
        gen_config.update(user)
    mode = 'image edit' if ref else 'text-to-image'
    print(f'Submitting {mode}: model={model}', file=sys.stderr)
    print(json.dumps({'contents': [{'role': 'user', 'parts': parts}], 'generationConfig': gen_config}))


def cmd_save(resp_file, output, elapsed):
    d = json.load(open(resp_file))
    cands = d.get('candidates') or []
    img = None
    for part in (cands[0].get('content', {}).get('parts', []) if cands else []):
        inline = part.get('inlineData') or part.get('inline_data')
        if inline and inline.get('data'):
            img = base64.b64decode(inline['data'])
            break
    if img is None:
        fb = d.get('promptFeedback') or {}
        reason = f" (blockReason: {fb.get('blockReason')})" if fb.get('blockReason') else ''
        die('Error: no image data in response' + reason)
    with open(output, 'wb') as f:
        f.write(img)
    dims = ''
    if img[:8] == b'\x89PNG\r\n\x1a\n':
        w, h = struct.unpack('>II', img[16:24])
        dims = f'{w}x{h}, '
    print(f'Saved: {output} ({dims}{len(img)} bytes, took {elapsed}s)')


def main():
    if len(sys.argv) < 2:
        die('Usage: gemini_api.py build|save ...')
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'build' and len(args) == 4:
        cmd_build(*args)
    elif cmd == 'save' and len(args) == 3:
        cmd_save(*args)
    else:
        die(f'Error: unknown subcommand or wrong argument count: {cmd} {len(args)} args')


if __name__ == '__main__':
    main()
