"""Explicit local-workspace integration. No capture or network activity on import."""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid


class IntegrationError(ValueError):
    pass


def base_url(value):
    value = value.strip().rstrip('/')
    try:
        p = urllib.parse.urlsplit(value)
        valid = (p.scheme in ('http', 'https') and p.hostname in ('localhost', '127.0.0.1', '::1')
                 and not p.username and not p.password and not p.query and not p.fragment
                 and p.path in ('', '/') and p.port != 0)
    except ValueError:
        valid = False
    if not valid:
        raise IntegrationError('Use a loopback API URL such as http://127.0.0.1:8000.')
    return value


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value):
        raise IntegrationError('Invalid server identifier.')
    return value


def validate_review_manifest(manifest):
    allowed = {'schema_version', 'id', 'app', 'started_at', 'duration_ms', 'interactions', 'frames', 'network', 'network_status', 'redaction', 'project_id'}
    if set(manifest) - allowed or manifest.get('network') or manifest.get('network_status') != 'not_captured':
        raise IntegrationError('Unsupported session metadata; use the original recorder to review.')
    if set(manifest.get('app', {})) - {'name', 'bundle_id', 'pid'} or set(manifest.get('redaction', {})) - {'reviewed'}:
        raise IntegrationError('Unsupported session metadata.')
    frames = manifest['frames']
    ids = [frame['id'] for frame in frames]
    names = [frame['filename'] for frame in frames]
    if len(set(ids)) != len(ids) or len(set(names)) != len(names):
        raise IntegrationError('Duplicate screenshot IDs or filenames are not reviewable.')
    if any(set(frame) - {'id', 'timestamp_ms', 'filename', 'width', 'height', 'sha256'} for frame in frames):
        raise IntegrationError('Unsupported screenshot metadata.')
    for item in manifest.get('interactions', []):
        if set(item) - {'id', 'timestamp_ms', 'kind', 'key', 'accessibility', 'after_frame_id'}:
            raise IntegrationError('Unsupported interaction metadata.')
        if set(item.get('accessibility', {})) - {'title'} or item.get('key') not in (None, 'redacted'):
            raise IntegrationError('Unsupported interaction text.')
    return manifest


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise IntegrationError('API redirects are refused. Check the API URL.')


class SecretStore:
    """Use the desktop Secret Service; never fall back to plaintext credentials."""
    def load(self, base):
        try:
            result = subprocess.run(['secret-tool', 'lookup', 'application', 'retrace', 'api', base],
                                    capture_output=True, timeout=15, check=False)
            if result.returncode != 0 or not result.stdout.strip():
                return None
            return json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            raise IntegrationError('Unlock Secret Service and install libsecret-tools.') from None

    def save(self, base, credential):
        try:
            subprocess.run(['secret-tool', 'store', '--label=Retrace workspace', 'application', 'retrace', 'api', base],
                           input=json.dumps(credential).encode(), capture_output=True, timeout=60, check=True)
        except (OSError, subprocess.SubprocessError):
            raise IntegrationError('Could not store credential in Secret Service. Unlock your keyring.') from None


def private_json(path, data):
    """Atomic owner-only state, with no following of an existing destination symlink."""
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.retrace-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Workspace:
    def __init__(self, url, secrets=None, opener=None):
        self.base = base_url(url)
        self.secrets = secrets or SecretStore()
        # Bypass environment proxies and refuse redirects, including bearer redirects.
        self.opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path, body, content_type='application/json', credential=None):
        headers = {'Content-Type': content_type, 'Accept': 'application/json'}
        if credential:
            if credential.get('api_base_url') != self.base:
                raise IntegrationError('Credential belongs to another API URL. Connect again.')
            token = credential.get('device_token', '')
            if not re.fullmatch(r'[A-Za-z0-9_-]{1,512}', token):
                raise IntegrationError('Invalid device credential. Connect again.')
            headers['Authorization'] = 'Bearer ' + token
        try:
            with self.opener.open(urllib.request.Request(self.base + path, data=body, headers=headers, method='POST'), timeout=60) as response:
                data = response.read(1024 * 1024 + 1)
                if len(data) > 1024 * 1024:
                    raise IntegrationError('API response too large.')
                result = json.loads(data)
                if not isinstance(result, dict):
                    raise ValueError()
                return result
        except urllib.error.HTTPError as exc:
            raise IntegrationError(f'API HTTP {exc.code}. Check connection, authorization, and session validation.') from None
        except (urllib.error.URLError, TimeoutError, ValueError):
            raise IntegrationError('API unavailable or returned an invalid response.') from None

    def connect(self, device_name):
        name = device_name.strip()
        if not 1 <= len(name) <= 64:
            raise IntegrationError('Device name must be 1–64 characters.')
        result = self.request('/v1/local/connect', json.dumps({'device_name': name}).encode())
        identifier(result.get('project_id'))
        token = result.get('device_token', '')
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,512}', token):
            raise IntegrationError('Invalid device credential response.')
        credential = {k: result[k] for k in ('device_token', 'project_id')}
        credential.update(api_base_url=self.base, device_name=name)
        self.secrets.save(self.base, credential)
        return credential

    def upload_and_analyze(self, root, manifest, confirmed=False):
        if not confirmed:
            raise IntegrationError('Review screenshots and descriptions, then explicitly confirm sharing.')
        credential = self.secrets.load(self.base)
        if not credential:
            raise IntegrationError('Connect to the Local workspace first.')
        if manifest.get('network') or manifest.get('network_status') != 'not_captured':
            raise IntegrationError('Ubuntu uploads support manual evidence without network traffic only.')
        validate_review_manifest(manifest)
        m = copy.deepcopy(manifest)
        if m.get('project_id') not in (None, credential['project_id']):
            raise IntegrationError('Session belongs to another workspace.')
        m['project_id'] = identifier(credential['project_id'])
        sid = str(uuid.UUID(m['id']))
        m['redaction'] = {'reviewed': True}
        files = []
        names = set()
        total = 0
        for frame in m['frames']:
            name = frame['filename']
            if not re.fullmatch(r'[A-Za-z0-9_-]+\.png', name) or name in names:
                raise IntegrationError('Unsafe or duplicate frame filename.')
            names.add(name)
            path = Path(root) / 'frames' / name
            if path.is_symlink() or path.parent.is_symlink():
                raise IntegrationError('Frame symlinks are refused.')
            directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
                with os.fdopen(fd, 'rb') as stream:
                    import stat
                    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                        raise IntegrationError('Frame must be a regular file.')
                    data = stream.read(20 * 1024 * 1024 + 1)
            finally:
                os.close(directory_fd)
            if len(data) > 20 * 1024 * 1024 or not data.startswith(b'\x89PNG\r\n\x1a\n') or hashlib.sha256(data).hexdigest() != frame['sha256']:
                raise IntegrationError('Frame is too large, modified, or not PNG.')
            total += len(data)
            if total > 100 * 1024 * 1024:
                raise IntegrationError('Upload exceeds the Ubuntu 100 MiB limit.')
            files.append((name, data))
        encoded = json.dumps(m, sort_keys=True, separators=(',', ':')).encode()
        digest = hashlib.sha256(encoded).hexdigest()
        receipt_path = Path(root) / 'upload.json'
        receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
        if receipt and (receipt.get('api_base_url') != self.base or receipt.get('digest') != digest):
            raise IntegrationError('Uploaded evidence is locked to its original content and API URL.')
        if not receipt:
            boundary = 'Retrace-' + uuid.uuid4().hex
            body = bytearray(f'--{boundary}\r\nContent-Disposition: form-data; name="manifest"\r\n\r\n'.encode())
            body.extend(encoded + b'\r\n')
            for name, data in files:
                body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="files"; filename="{name}"\r\nContent-Type: image/png\r\n\r\n'.encode())
                body.extend(data + b'\r\n')
            body.extend(f'--{boundary}--\r\n'.encode())
            if len(body) > 100 * 1024 * 1024:
                raise IntegrationError('Upload exceeds the Ubuntu 100 MiB limit.')
            result = self.request('/v1/sessions', bytes(body), 'multipart/form-data; boundary=' + boundary, credential)
            if result.get('id') != sid or result.get('status') != 'uploaded':
                raise IntegrationError('Unexpected upload response.')
            receipt = {'id': sid, 'digest': digest, 'api_base_url': self.base}
            private_json(receipt_path, receipt)
        job = self.request(f'/v1/sessions/{sid}/analyze', b'{}', credential=credential)
        identifier(job.get('job_id'))
        receipt.update(job_id=job['job_id'], job_status=job.get('status'))
        private_json(receipt_path, receipt)
        return receipt
