import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture

PNG = b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', 12, 9) + b'\x08\x02\x00\x00\x00' + b'\x00' * 4


class CaptureTests(unittest.TestCase):
    def test_png_validation(self):
        self.assertEqual(capture.png_size(PNG), (12, 9))
        for data in (b'', PNG[:24], PNG.replace(b'IHDR', b'NOPE'), PNG[:16] + b'\x00' * 8 + PNG[24:]):
            with self.assertRaises(ValueError):
                capture.png_size(data)

    def test_portal_rejects_remote_or_invalid_paths(self):
        for uri in ('https://example.com/a.png', 'file://remote/a.png', 'file:relative', 'file:///tmp/a?secret', ''):
            with self.assertRaises(ValueError):
                capture.local_portal_file(uri)
        self.assertEqual(capture.local_portal_file('file:///tmp/a%20b.png'), Path('/tmp/a b.png'))

    @patch('capture.subprocess.run')
    def test_x11_rejects_unscoped_targets(self, run):
        for window in ('root', '0x0', '', '-window', '0x', '0xBAD;echo'):
            with self.assertRaises(ValueError):
                capture.capture_x11(window, Path('/tmp/unused'))
        run.assert_not_called()

    @patch.dict(os.environ, {'XDG_SESSION_TYPE': 'wayland'})
    @patch('capture.subprocess.run')
    def test_wayland_never_uses_x11(self, run):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                capture.capture('x11', '0x123', Path(folder) / 'frame.png')
        run.assert_not_called()

    def test_failed_capture_leaves_no_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'frame.png'
            def invalid(destination):
                destination.write_bytes(b'not a PNG')
            with patch('capture.capture_portal', side_effect=invalid):
                with self.assertRaises(ValueError):
                    capture.capture('portal', '', path)
            self.assertFalse(path.exists())

    def test_success_is_private(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'frame.png'
            with patch('capture.capture_portal', side_effect=lambda p: p.write_bytes(PNG)):
                self.assertEqual(capture.capture('portal', '', path), (12, 9))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
