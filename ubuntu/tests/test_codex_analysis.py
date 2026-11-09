import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import codex_analysis


class AnalysisTests(unittest.TestCase):
    def test_no_consent_never_starts_codex(self):
        with patch('codex_analysis.subprocess.run') as run:
            with self.assertRaises(ValueError):
                codex_analysis.analyze('/does-not-exist')
            run.assert_not_called()

    def test_api_key_login_is_not_subscription(self):
        with patch('codex_analysis.shutil.which', return_value='/usr/bin/codex'), patch('codex_analysis.subprocess.run', return_value=SimpleNamespace(returncode=0, stdout='', stderr='Logged in using an API key')):
            with self.assertRaises(ValueError):
                codex_analysis.require_subscription()

    def test_only_reviewed_frames_staged_and_report_saved(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'frames').mkdir()
            data = b'fixture'
            (root / 'frames/one.png').write_bytes(data)
            (root / 'frames/private-unlisted.png').write_bytes(b'secret')
            manifest = {'network_status': 'not_captured', 'app': {'name': 'Synthetic'}, 'interactions': [], 'frames': [{'id': 'one', 'filename': 'one.png', 'sha256': hashlib.sha256(data).hexdigest()}]}
            (root / 'manifest.json').write_text(json.dumps(manifest))
            def execute(command, **kwargs):
                stage = Path(command[command.index('-C') + 1])
                self.assertEqual(list(stage.iterdir()), [stage / 'frame-1.png'])
                self.assertIn('read-only', command)
                self.assertIn('--ignore-user-config', command)
                self.assertIn('features.shell_tool=false', command)
                self.assertNotIn('secret', kwargs['input'])
                Path(command[command.index('-o') + 1]).write_text('# User stories\nSynthetic test report')
                return SimpleNamespace(returncode=0)
            with patch('codex_analysis.require_subscription'), patch('codex_analysis.subprocess.run', side_effect=execute):
                output = codex_analysis.analyze(root, reviewed=True)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertIn('Synthetic', output.read_text())
            with patch('codex_analysis.subprocess.run') as run:
                with self.assertRaises(ValueError):
                    codex_analysis.analyze(root, reviewed=True)
                run.assert_not_called()
            output.unlink()
            manifest['frames'][0]['filename'] = '../escape.png'
            (root / 'manifest.json').write_text(json.dumps(manifest))
            with patch('codex_analysis.require_subscription'), patch('codex_analysis.subprocess.run') as run:
                with self.assertRaises(ValueError):
                    codex_analysis.analyze(root, reviewed=True)
                run.assert_not_called()
