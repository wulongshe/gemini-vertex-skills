#!/usr/bin/env python3
"""gemini-audio skill helper: request building, response parsing.
(Auth tokens come from the shared skills/common/vertex_auth.py.)

Subcommands:
    build <prompt> <model> <voices> <gen-json> <params-json> -> prints request body (info on stderr)
            TTS models (gemini-*-tts): generateContent body; voices is "Kore" or
            "Alice=Kore,Bob=Puck" (multi-speaker); gen-json merges into generationConfig.
            Music models (lyria-*): predict body; params-json merges into parameters,
            with negativePrompt/seed lifted into the instance (API keeps them there).
    save  <resp-file> <output> <elapsed>                   -> saves WAV, prints the Saved line
"""
import base64
import json
import os
import re
import struct
import sys
import wave

DEFAULT_VOICE = 'Kore'


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def _speech_config(voices):
    """Turn the voices slot into a speechConfig: "Kore" for a single voice,
    "Alice=Kore,Bob=Puck" for multi-speaker dialogue."""
    if '=' not in voices:
        return {'voiceConfig': {'prebuiltVoiceConfig': {'voiceName': voices}}}
    configs = []
    for pair in voices.split(','):
        pair = pair.strip()
        if not pair:
            continue
        if '=' not in pair:
            die(f'Error: multi-speaker voices must all be speaker=voice pairs, got: {pair}')
        speaker, voice = (s.strip() for s in pair.split('=', 1))
        if not speaker or not voice:
            die(f'Error: empty speaker or voice in pair: {pair}')
        configs.append({'speaker': speaker,
                        'voiceConfig': {'prebuiltVoiceConfig': {'voiceName': voice}}})
    return {'multiSpeakerVoiceConfig': {'speakerVoiceConfigs': configs}}


def _parse_user_json(raw, flag):
    try:
        user = json.loads(raw)
    except json.JSONDecodeError as e:
        die(f'Error: {flag} is not valid JSON: {e}')
    if not isinstance(user, dict):
        die(f'Error: {flag} must be a JSON object')
    return user


def cmd_build(prompt, model, voices, gen_json, params_json):
    """Build the request body: generateContent for TTS models, predict for Lyria.

    Fixed handling: the text/prompt and the voices slot (shorthand expanded into
    speechConfig). Everything else is merged verbatim from --generation-config
    (TTS) or --parameters (Lyria); user values override defaults.
    """
    if model.startswith('lyria'):
        if gen_json:
            die('Error: --generation-config is for TTS models; use --parameters with music models')
        if voices:
            print('Warning: the voices slot is TTS-only and is ignored for music models', file=sys.stderr)
        instance = {'prompt': prompt}
        params = {'sampleCount': 1}
        if params_json:
            user = _parse_user_json(params_json, '--parameters')
            # The Lyria API keeps these on the instance, not in parameters.
            if 'negativePrompt' in user:
                instance['negative_prompt'] = user.pop('negativePrompt')
            if 'seed' in user:
                instance['seed'] = user.pop('seed')
            params.update(user)
        count = params.get('sampleCount', 1)
        print(f'Submitting music generation: model={model}, ~30s clip (~${0.06 * count:.2f})', file=sys.stderr)
        print(json.dumps({'instances': [instance], 'parameters': params}))
        return

    speech = _speech_config(voices or DEFAULT_VOICE)
    gen_config = {'responseModalities': ['AUDIO'], 'speechConfig': speech}
    if params_json:
        die('Error: --parameters is for music models; use --generation-config with TTS models')
    if gen_json:
        gen_config.update(_parse_user_json(gen_json, '--generation-config'))
    mode = 'multi-speaker' if 'multiSpeakerVoiceConfig' in speech else 'single-voice'
    print(f'Submitting speech synthesis ({mode}): model={model}', file=sys.stderr)
    print(json.dumps({'contents': [{'role': 'user', 'parts': [{'text': prompt}]}],
                      'generationConfig': gen_config}))


def _save_tts(d, output, elapsed):
    cands = d.get('candidates') or []
    inline = None
    for part in (cands[0].get('content', {}).get('parts', []) if cands else []):
        data = part.get('inlineData') or part.get('inline_data')
        if data and data.get('data'):
            inline = data
            break
    if inline is None:
        fb = d.get('promptFeedback') or {}
        reason = f" (blockReason: {fb.get('blockReason')})" if fb.get('blockReason') else ''
        die('Error: no audio data in response' + reason)
    pcm = base64.b64decode(inline['data'])
    m = re.search(r'rate=(\d+)', inline.get('mimeType', ''))
    rate = int(m.group(1)) if m else 24000
    with wave.open(output, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    dur = len(pcm) / 2 / rate
    size = os.path.getsize(output)
    print(f'Saved: {output} ({dur:.1f}s, {rate // 1000}kHz mono, {size} bytes, took {elapsed}s)')


def _save_music(d, output, elapsed):
    preds = d.get('predictions') or []
    raw = base64.b64decode(preds[0]['bytesBase64Encoded']) if preds and preds[0].get('bytesBase64Encoded') else None
    if not raw:
        die('Error: no audio data in response')
    if raw[:4] != b'RIFF':
        die('Error: response audio is not a WAV file')
    with open(output, 'wb') as f:
        f.write(raw)
    ch, rate = struct.unpack('<HI', raw[22:28])
    dur = (len(raw) - 44) / (rate * ch * 2)
    stereo = 'stereo' if ch == 2 else 'mono'
    extra = f' (only the first of {len(preds)} samples saved)' if len(preds) > 1 else ''
    print(f'Saved: {output} ({dur:.1f}s, {rate // 1000}kHz {stereo}, {len(raw)} bytes, took {elapsed}s){extra}')


def cmd_save(resp_file, output, elapsed):
    d = json.load(open(resp_file))
    if 'predictions' in d:
        _save_music(d, output, elapsed)
    else:
        _save_tts(d, output, elapsed)


def main():
    if len(sys.argv) < 2:
        die('Usage: gemini_api.py build|save ...')
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'build' and len(args) == 5:
        cmd_build(*args)
    elif cmd == 'save' and len(args) == 3:
        cmd_save(*args)
    else:
        die(f'Error: unknown subcommand or wrong argument count: {cmd} {len(args)} args')


if __name__ == '__main__':
    main()
