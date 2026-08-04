#!/usr/bin/env python3
"""Shared auth helper: mint a short-lived OAuth access token from a
service-account key file. The key material is never printed or stored.

CLI:    vertex_auth.py <sa-json-path> [scope]   -> prints the access token
Module: from vertex_auth import mint_token
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

CLOUD_PLATFORM_SCOPE = 'https://www.googleapis.com/auth/cloud-platform'


def mint_token(sa_path, scope=CLOUD_PLATFORM_SCOPE):
    sa = json.load(open(sa_path))
    b64u = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=')
    now = int(time.time())
    header = b64u(json.dumps({'alg': 'RS256', 'typ': 'JWT'}).encode())
    claims = b64u(json.dumps({
        'iss': sa['client_email'], 'scope': scope,
        'aud': sa['token_uri'], 'iat': now, 'exp': now + 3600,
    }).encode())
    signing_input = header + b'.' + claims
    fd, keyfile = tempfile.mkstemp()
    try:
        os.write(fd, sa['private_key'].encode())
        os.close(fd)
        sig = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', keyfile],
                             input=signing_input, capture_output=True, check=True).stdout
    finally:
        os.unlink(keyfile)
    jwt = (signing_input + b'.' + b64u(sig)).decode()
    data = urllib.parse.urlencode({
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': jwt,
    }).encode()
    resp = json.load(urllib.request.urlopen(
        urllib.request.Request(sa['token_uri'], data=data), timeout=30))
    return resp['access_token']


def main():
    if len(sys.argv) < 2:
        print('Usage: vertex_auth.py <sa-json-path> [scope]', file=sys.stderr)
        sys.exit(1)
    print(mint_token(*sys.argv[1:3]))


if __name__ == '__main__':
    main()
