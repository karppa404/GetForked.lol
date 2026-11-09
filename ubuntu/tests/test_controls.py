"""Exercise UI state guards without opening a window or recording anything."""
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    from app import Recorder
except (ImportError, ValueError):
    Recorder = None


@unittest.skipIf(Recorder is None, 'Requires system Python with GTK 3')
class ControlTests(unittest.TestCase):
    def recorder(self, **overrides):
        values = dict(session={}, paused=False, busy=False, publish_state=Mock(), status=Mock(), hide=Mock(), capture_action=Mock())
        values.update(overrides)
        return SimpleNamespace(**values)

    def test_paused_and_busy_block_capture(self):
        for values in (dict(paused=True), dict(busy=True)):
            recorder = self.recorder(**values)
            Recorder.capture(recorder, None)
            recorder.capture_action.assert_not_called()

    def test_capture_failure_restores_controls(self):
        recorder = self.recorder(capture_action=Mock(side_effect=RuntimeError('cancelled')))
        with self.assertRaises(RuntimeError):
            Recorder.capture(recorder, None)
        self.assertFalse(recorder.busy)
        self.assertEqual(recorder.publish_state.call_count, 2)

    def test_pause_only_during_session_and_outside_capture(self):
        recorder = self.recorder()
        Recorder.pause(recorder, None)
        self.assertTrue(recorder.paused)
        Recorder.pause(recorder, None)
        self.assertFalse(recorder.paused)
        recorder.busy = True
        Recorder.pause(recorder, None)
        self.assertFalse(recorder.paused)

    def test_active_close_preserves_session(self):
        recorder = self.recorder()
        self.assertTrue(Recorder.close_requested(recorder))
        recorder.hide.assert_called_once()
        self.assertIsNotNone(recorder.session)
        recorder.session = None
        self.assertFalse(Recorder.close_requested(recorder))
