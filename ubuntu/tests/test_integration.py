import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, MagicMock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from integration import Workspace, IntegrationError, NoRedirect, base_url


class IntegrationTests(unittest.TestCase):
    def test_rejects_hidden_metadata_and_duplicate_frames(self):
        from integration import validate_review_manifest, IntegrationError
        manifest = {'network_status': 'not_captured', 'frames': [{'id': 'a', 'filename': 'a.png'}], 'task': 'hidden'}
        with self.assertRaises(IntegrationError):
            validate_review_manifest(manifest)
        del manifest['task']
        manifest['interactions'] = [{'accessibility': {'value': 'hidden'}}]
        with self.assertRaises(IntegrationError):
            validate_review_manifest(manifest)
        manifest['interactions'] = []
        manifest['frames'].append({'id': 'a', 'filename': 'b.png'})
        with self.assertRaises(IntegrationError):
            validate_review_manifest(manifest)

    def test_loopback_only(self):
        for url in ('http://evil.com', 'http://localhost@evil.com', 'http://localhost/?x=1',
                    'file:///tmp/a', 'http://localhost/#x', 'http://localhost:bad', 'http://localhost/api'):
            with self.subTest(url=url), self.assertRaises(IntegrationError):
                base_url(url)
        self.assertEqual(base_url('http://[::1]:8000/'), 'http://[::1]:8000')

    def test_redirects_refused(self):
        with self.assertRaises(IntegrationError):
            NoRedirect().redirect_request(None, None, None, None, None, None)

    def test_transport_uses_backend_contract_and_hides_error_body(self):
        import urllib.error
        opener = MagicMock()
        response = opener.open.return_value.__enter__.return_value
        response.read.return_value = b'{"job_id":"job","status":"queued"}'
        workspace = Workspace('http://127.0.0.1:8000', opener=opener)
        credential = {'api_base_url': workspace.base, 'device_token': 'rtd_secret'}
        workspace.request('/v1/sessions/session/analyze', b'{}', credential=credential)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.method, 'POST')
        self.assertEqual(request.get_header('Authorization'), 'Bearer rtd_secret')
        self.assertEqual(request.get_header('Content-type'), 'application/json')
        self.assertEqual(request.data, b'{}')
        opener.open.side_effect = urllib.error.HTTPError(request.full_url, 401, 'secret', {}, None)
        with self.assertRaises(IntegrationError) as caught:
            workspace.request('/v1/sessions', b'{}', credential=credential)
        self.assertNotIn('secret', str(caught.exception))

    def test_connect_binds_requested_url(self):
        secrets = Mock()
        workspace = Workspace('http://127.0.0.1:8000', secrets=secrets)
        workspace.request = Mock(return_value={'project_id': 'project', 'device_token': 'rtd_secret', 'api_base_url': 'https://evil.com'})
        credential = workspace.connect('Ubuntu')
        self.assertEqual(credential['api_base_url'], workspace.base)
        secrets.save.assert_called_once_with(workspace.base, credential)
        self.assertEqual(workspace.request.call_count, 1)

    def fixture(self, root):
        data = b'\x89PNG\r\n\x1a\nexample'
        (root / 'frames').mkdir()
        (root / 'frames' / 'frame.png').write_bytes(data)
        return {'id': str(uuid.uuid4()), 'frames': [{'id': 'frame', 'filename': 'frame.png', 'sha256': hashlib.sha256(data).hexdigest()}],
                'interactions': [], 'network': [], 'network_status': 'not_captured', 'redaction': {'reviewed': False}}

    def workspace(self):
        secrets = Mock()
        secrets.load.return_value = {'project_id': 'project', 'device_token': 'rtd_secret', 'api_base_url': 'http://127.0.0.1:8000'}
        return Workspace('http://127.0.0.1:8000', secrets=secrets)

    def test_confirmation_required_before_network(self):
        workspace = self.workspace()
        workspace.request = Mock()
        with self.assertRaises(IntegrationError):
            workspace.upload_and_analyze('.', {})
        workspace.request.assert_not_called()
        workspace.secrets.load.assert_not_called()

    def test_upload_then_analysis_retry_and_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self.fixture(root)
            workspace = self.workspace()
            workspace.request = Mock(side_effect=[{'id': manifest['id'], 'status': 'uploaded'}, IntegrationError('offline')])
            with self.assertRaises(IntegrationError):
                workspace.upload_and_analyze(root, manifest, True)
            self.assertTrue((root / 'upload.json').exists())
            self.assertEqual((root / 'upload.json').stat().st_mode & 0o777, 0o600)
            upload = workspace.request.call_args_list[0]
            self.assertIn(b'name="manifest"', upload.args[1])
            self.assertIn(b'name="files"; filename="frame.png"', upload.args[1])
            self.assertFalse(manifest['redaction']['reviewed'])
            workspace.request = Mock(return_value={'job_id': 'job', 'status': 'queued'})
            workspace.upload_and_analyze(root, manifest, True)
            workspace.request.assert_called_once()
            self.assertTrue(workspace.request.call_args.args[0].endswith('/analyze'))
            manifest['duration_ms'] = 123
            with self.assertRaises(IntegrationError):
                workspace.upload_and_analyze(root, manifest, True)

    def test_unsafe_or_modified_frames_never_sent(self):
        for variant in ('path', 'hash', 'symlink'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                manifest = self.fixture(root)
                if variant == 'path':
                    manifest['frames'][0]['filename'] = '../frame.png'
                elif variant == 'hash':
                    manifest['frames'][0]['sha256'] = '0' * 64
                else:
                    (root / 'frames' / 'frame.png').rename(root / 'outside.png')
                    (root / 'frames' / 'frame.png').symlink_to(root / 'outside.png')
                workspace = self.workspace()
                workspace.request = Mock()
                with self.assertRaises(IntegrationError):
                    workspace.upload_and_analyze(root, manifest, True)
                workspace.request.assert_not_called()

    def test_mismatched_credential_never_sent(self):
        workspace = self.workspace()
        workspace.opener = Mock()
        with self.assertRaises(IntegrationError):
            workspace.request('/v1/sessions', b'{}', credential={'api_base_url': 'http://localhost:9000'})
        workspace.opener.open.assert_not_called()


if __name__ == '__main__':
    unittest.main()
