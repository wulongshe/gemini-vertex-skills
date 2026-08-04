#!/usr/bin/env python3
"""gemini-video skill helper: request building, response parsing, GCS download.
(Auth tokens come from the shared skills/common/vertex_auth.py.)

Subcommands:
    build   <prompt> <model> <source-video> <key-frames> <ref-images> <storage-uri> <params>
            -> prints request body (info on stderr)
            The three media args are mutually exclusive (at most one non-empty):
            source-video (extension), key-frames "start[,end]" (image-to-video /
            frame interpolation), ref-images "a,b,c" (up to 3, text-to-video only).
    status  <resp-file>                                                 -> prints running|done|failed
    extract <resp-file> <output>                                        -> prints gcs:<uri>|inline|none
    download <gs-uri> <output>  (token in GCS_TOKEN env)                -> chunked parallel resumable fetch
    report  <output> <elapsed> <gcs-uri>                                -> validates mp4, prints the Saved line
"""
import base64
import json
import os
import struct
import sys
import time
import urllib.parse
import urllib.request

PRICES_PER_SECOND = {
    'veo-3.1-lite-generate-001': 0.05,
    'veo-3.1-fast-generate-001': 0.15,
    'veo-3.1-generate-001': 0.40,
}

IMAGE_MIMES = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp'}


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def _encode_image_media(value, field):
    """Turn a user-supplied image reference (local path, gs:// URI, or API-format
    dict) into the Veo media object. Local files are base64-encoded and oversized
    ones auto-compressed."""
    if isinstance(value, dict):
        return value
    if not isinstance(value, str):
        die(f'Error: {field} must be a file path, gs:// URI, or API-format object')
    ext = os.path.splitext(value)[1].lower()
    if value.startswith('gs://'):
        return {'gcsUri': value, 'mimeType': IMAGE_MIMES.get(ext, 'image/png')}
    if not os.path.isfile(value):
        die(f'Error: {field} image not found: {value}')
    mime = IMAGE_MIMES.get(ext)
    if not mime:
        die(f'Error: {field} image must be png/jpg/jpeg/webp')
    data = open(value, 'rb').read()
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
                die(f'Error: {field} image exceeds 15MB and PIL is unavailable for auto-compression; downscale it first')
    return {'bytesBase64Encoded': base64.b64encode(data).decode(), 'mimeType': mime}


def _split_csv(value):
    return [p.strip() for p in value.split(',') if p.strip()]


def _encode_video_media(value):
    if value.startswith('gs://'):
        return {'gcsUri': value, 'mimeType': 'video/mp4'}
    if not os.path.isfile(value):
        die(f'Error: source video not found: {value}')
    size = os.path.getsize(value)
    if size > 100 * 1024 * 1024:
        die(f'Error: source video is {size >> 20}MB; inline upload is capped at 100MB — '
            'upload it to GCS first (gcs-upload skill) and pass the gs:// URI instead')
    return {'bytesBase64Encoded': base64.b64encode(open(value, 'rb').read()).decode(), 'mimeType': 'video/mp4'}


def cmd_build(prompt, model, source_video, key_frames, ref_images, storage_uri, user_json):
    """Build the predictLongRunning request body.

    Fixed handling: prompt; the three mutually exclusive media args (the Veo API
    allows only one visual anchor per request — verified): source-video for
    extension, key-frames "start[,end]" for image-to-video / frame interpolation,
    ref-images "a,b,c" for text-to-video guidance; and the auto-assembled
    storageUri. Local files are base64-encoded, gs:// URIs pass through.
    Everything else is merged verbatim into the Veo `parameters` block (user
    values override defaults).
    """
    instance = {'prompt': prompt}
    params = {'sampleCount': 1}
    mode = 'text-to-video'
    if sum(1 for x in (source_video, key_frames, ref_images) if x) > 1:
        die('Error: --source-video / --key-frames / --reference-images are mutually '
            'exclusive — the Veo API allows only one visual anchor per request')
    if source_video:
        if not source_video.lower().endswith('.mp4'):
            die('Error: --source-video must be an .mp4 file or gs://...mp4 URI')
        instance['video'] = _encode_video_media(source_video)
        mode = 'extension'
    if key_frames:
        segs = [s.strip() for s in key_frames.split(',')]
        if len(segs) > 2:
            die('Error: --key-frames accepts at most 2 comma-separated frames (start-frame,end-frame)')
        start = segs[0]
        end = segs[1] if len(segs) > 1 else ''
        if not start:
            die('Error: --key-frames requires a start frame (an end frame alone is not supported)')
        if start.lower().endswith('.mp4') or end.lower().endswith('.mp4'):
            die('Error: --key-frames must be images (use --source-video to extend a video)')
        instance['image'] = _encode_image_media(start, 'start-frame')
        mode = 'image-to-video'
        if end:
            instance['lastFrame'] = _encode_image_media(end, 'end-frame')
    if ref_images:
        ref_parts = _split_csv(ref_images)
        if len(ref_parts) > 3:
            die('Error: at most 3 reference images are supported')
        instance['referenceImages'] = [
            {'image': _encode_image_media(r, 'reference'), 'referenceType': 'asset'} for r in ref_parts]
    if mode != 'extension':
        params['durationSeconds'] = 4
        params['aspectRatio'] = '16:9'
    if storage_uri:
        params['storageUri'] = storage_uri
    if user_json:
        try:
            user = json.loads(user_json)
        except json.JSONDecodeError as e:
            die(f'Error: --parameters is not valid JSON: {e}')
        if not isinstance(user, dict):
            die('Error: --parameters must be a JSON object')
        params.update(user)

    price = PRICES_PER_SECOND.get(model)
    count = params.get('sampleCount', 1)
    if mode == 'extension':
        est = f' (~${7 * price * count:.2f})' if price else ''
        print(f'Submitting video extension: model={model}, +~7s{est}', file=sys.stderr)
    else:
        secs = params.get('durationSeconds', 4)
        est = f' (~${price * secs * count:.2f})' if price and isinstance(secs, int) else ''
        print(f'Submitting {mode}: model={model}, {secs}s{est}', file=sys.stderr)
    print(json.dumps({'instances': [instance], 'parameters': params}))


def cmd_status(resp_file):
    d = json.load(open(resp_file))
    if d.get('error'):
        print(json.dumps(d['error'])[:400], file=sys.stderr)
        print('failed')
    elif d.get('done'):
        print('done')
    else:
        print('running')


def cmd_extract(resp_file, output):
    """Detect where the result lives; write inline bytes directly if present."""
    d = json.load(open(resp_file))
    vids = (d.get('response') or {}).get('videos') or []
    if not vids:
        print('none')
        return
    v = vids[0]
    if v.get('gcsUri'):
        print('gcs:' + v['gcsUri'])
    elif v.get('bytesBase64Encoded'):
        with open(output, 'wb') as f:
            f.write(base64.b64decode(v['bytesBase64Encoded']))
        print('inline')
    else:
        print('none')


def cmd_download(gs_uri, output):
    """Chunked, parallel, resumable download of a GCS object.

    2MiB ranges are fetched by 4 workers into .partN files; each part resumes
    from its existing bytes, so retries, reruns, and dropped connections only
    cost the missing data. Parallel ranges also multiply throughput on
    per-connection-throttled links. Parts are concatenated into the output and
    removed on success, and kept for resume on failure. The token comes from
    the GCS_TOKEN env var (never argv). Reads stall out after 60s of silence.
    """
    import concurrent.futures
    token = os.environ.get('GCS_TOKEN')
    if not token:
        die('Error: GCS_TOKEN not set')
    url = 'https://storage.googleapis.com/' + urllib.parse.quote(gs_uri[len('gs://'):], safe='/')
    auth = {'Authorization': f'Bearer {token}'}
    head = urllib.request.urlopen(
        urllib.request.Request(url, method='HEAD', headers=auth), timeout=60)
    size = int(head.headers['Content-Length'])
    chunk = 2 * 1024 * 1024
    ranges = [(lo, min(lo + chunk, size) - 1) for lo in range(0, size, chunk)]

    def fetch(job):
        idx, (lo, hi) = job
        part = f'{output}.part{idx}'
        want = hi - lo + 1
        for attempt in range(3):
            have = os.path.getsize(part) if os.path.exists(part) else 0
            if have > want:
                os.truncate(part, want)
                have = want
            if have == want:
                return
            try:
                req = urllib.request.Request(url, headers={
                    **auth, 'Range': f'bytes={lo + have}-{hi}'})
                with urllib.request.urlopen(req, timeout=60) as resp, open(part, 'ab') as f:
                    while True:
                        block = resp.read(256 * 1024)
                        if not block:
                            break
                        f.write(block)
                if os.path.getsize(part) == want:
                    return
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(5)
        raise IOError(f'chunk {idx} still incomplete after retries')

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
            list(ex.map(fetch, enumerate(ranges)))
    except Exception as e:
        die(f'Error: download failed: {e}')
    with open(output, 'wb') as out:
        for i in range(len(ranges)):
            with open(f'{output}.part{i}', 'rb') as f:
                while True:
                    block = f.read(1 << 20)
                    if not block:
                        break
                    out.write(block)
    for i in range(len(ranges)):
        os.unlink(f'{output}.part{i}')


def cmd_report(output, elapsed, gcs):
    data = open(output, 'rb').read()
    if data[4:8] not in (b'ftyp', b'moov'):
        die('Error: downloaded file is not a valid mp4')
    i = data.find(b'mvhd')
    dur = ''
    if i > 0:
        ts, d = struct.unpack('>II', data[i + 16:i + 24])
        dur = f'{d / ts:.1f}s, '
    suffix = f' [{gcs}]' if gcs else ''
    print(f'Saved: {output} ({dur}{len(data)} bytes, took {elapsed}s){suffix}')


def main():
    if len(sys.argv) < 2:
        die('Usage: gemini_api.py build|status|extract|download|report ...')
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'build' and len(args) == 7:
        cmd_build(*args)
    elif cmd == 'status' and len(args) == 1:
        cmd_status(*args)
    elif cmd == 'extract' and len(args) == 2:
        cmd_extract(*args)
    elif cmd == 'download' and len(args) == 2:
        cmd_download(*args)
    elif cmd == 'report' and len(args) == 3:
        cmd_report(*args)
    else:
        die(f'Error: unknown subcommand or wrong argument count: {cmd} {len(args)} args')


if __name__ == '__main__':
    main()
