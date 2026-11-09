#!/usr/bin/env python3
"""Explicit, manual X11 window snapshots in Retrace manifest format."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time
import uuid
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--window', required=True, help='X11 window ID (see xwininfo)')
    parser.add_argument('--app', required=True, help='Name of the application being recorded')
    parser.add_argument('--app-id', required=True, help='Application identifier')
    parser.add_argument('--pid', type=int, required=True, help='Target application process ID')
    parser.add_argument('--output', type=Path, required=True, help='New session directory')
    args = parser.parse_args()
    if os.environ.get('XDG_SESSION_TYPE') == 'wayland':
        parser.error('This recorder requires an X11 session; Wayland capture is not implemented.')
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    frames_dir = args.output / 'frames'
    frames_dir.mkdir(mode=0o700)
    start = time.monotonic()
    manifest = {'schema_version': 1, 'id': str(uuid.uuid4()),
                'app': {'name': args.app, 'bundle_id': args.app_id, 'pid': args.pid}, 'started_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
                'duration_ms': 0, 'interactions': [], 'frames': [], 'network': [],
                'network_status': 'not_captured', 'redaction': {'reviewed': False}}
    print('Perform an action in the selected window, then describe it here. Blank description ends recording.')
    while description := input('Action: ').strip():
        if len(description) > 256:
            print('Description must be at most 256 characters.')
            continue
        kind = input('Action kind (click, scroll, text_input, key): ').strip()
        if kind not in ('click', 'scroll', 'text_input', 'key'):
            print('Unknown action kind; try again.')
            continue
        frame_id = str(uuid.uuid4())
        path = frames_dir / (frame_id + '.png')
        subprocess.run(['import', '-window', args.window, str(path)], check=True)
        path.chmod(0o600)
        data = path.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            raise ValueError('Screenshot is not a PNG')
        width, height = struct.unpack('>II', data[16:24])
        timestamp = int((time.monotonic() - start) * 1000)
        manifest['frames'].append({'id': frame_id, 'timestamp_ms': timestamp, 'filename': path.name,
                                   'width': width, 'height': height, 'sha256': hashlib.sha256(data).hexdigest()})
        manifest['interactions'].append({'id': str(uuid.uuid4()), 'timestamp_ms': timestamp, 'kind': kind, **({'key': 'redacted'} if kind == 'text_input' else {}),
                                         'accessibility': {'title': description}, 'after_frame_id': frame_id})
    manifest['duration_ms'] = int((time.monotonic() - start) * 1000)
    path = args.output / 'manifest.json'
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    path.chmod(0o600)
    print(f'Saved {path}. Review images and text before sharing; no upload was performed.')


if __name__ == '__main__':
    os.umask(0o077)
    main()
