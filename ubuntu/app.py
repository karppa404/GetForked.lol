#!/usr/bin/python3
"""GTK front end for manually collecting X11 window evidence."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time
import uuid
from datetime import datetime, timezone

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GdkPixbuf


class Recorder(Gtk.Window):
    def __init__(self):
        super().__init__(title='Retrace — Ubuntu')
        self.set_default_size(760, 580)
        self.connect('destroy', Gtk.main_quit)
        self.session = None
        self.started = None
        self.root = None
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        self.add(box)
        box.pack_start(Gtk.Label(label='Capture a selected X11 window after each action. Review all evidence before sharing.', xalign=0), False, False, 0)
        grid = Gtk.Grid(column_spacing=8, row_spacing=6)
        box.pack_start(grid, False, False, 0)
        self.fields = {}
        for row, (key, label, default) in enumerate((('app', 'Application name', ''), ('app_id', 'Application ID', ''), ('pid', 'Process ID', ''), ('window', 'X11 window ID', ''), ('folder', 'New session folder', str(Path.home() / 'retrace-session')))):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, row, 1, 1)
            entry = Gtk.Entry(text=default, hexpand=True)
            grid.attach(entry, 1, row, 1, 1)
            self.fields[key] = entry
        controls = Gtk.Box(spacing=6)
        box.pack_start(controls, False, False, 0)
        for title, handler in [('Start', self.start), ('Capture action', self.capture), ('Remove selected', self.remove), ('Save session', self.save)]:
            button = Gtk.Button(label=title)
            button.connect('clicked', handler)
            controls.pack_start(button, False, False, 0)
        self.store = Gtk.ListStore(str, str, str)
        self.list = Gtk.TreeView(model=self.store)
        for i, title in enumerate(('Action', 'Kind', 'Screenshot')):
            self.list.append_column(Gtk.TreeViewColumn(title, Gtk.CellRendererText(), text=i))
        self.list.get_selection().connect('changed', self.preview)
        scroll = Gtk.ScrolledWindow(vexpand=True)
        scroll.add(self.list)
        box.pack_start(scroll, True, True, 0)
        self.image = Gtk.Image()
        box.pack_start(self.image, False, False, 0)
        self.status = Gtk.Label(label='Network traffic is not captured. No evidence is uploaded automatically.', xalign=0)
        box.pack_start(self.status, False, False, 0)

    def alert(self, message):
        dialog = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.CLOSE, text=str(message))
        dialog.run()
        dialog.destroy()

    def start(self, _):
        try:
            if self.session is not None:
                raise ValueError('Save the current session before starting another.')
            if os.environ.get('XDG_SESSION_TYPE') == 'wayland':
                raise ValueError('X11 is required. Wayland capture is not yet supported.')
            values = {k: v.get_text().strip() for k, v in self.fields.items()}
            if not all(values.values()):
                raise ValueError('Complete all fields first.')
            pid = int(values['pid'])
            if pid < 0 or pid > 2**31:
                raise ValueError('Invalid process ID.')
            self.root = Path(values['folder']).expanduser()
            self.root.mkdir(mode=0o700, parents=True, exist_ok=False)
            (self.root / 'frames').mkdir(mode=0o700)
            self.started = time.monotonic()
            self.session = {'schema_version': 1, 'id': str(uuid.uuid4()), 'app': {'name': values['app'], 'bundle_id': values['app_id'], 'pid': pid}, 'started_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'), 'duration_ms': 0, 'interactions': [], 'frames': [], 'network': [], 'network_status': 'not_captured', 'redaction': {'reviewed': False}}
            self.window_id = values['window']
            self.status.set_text('Recording started. Perform an action, then capture it.')
        except (OSError, ValueError) as exc:
            self.alert(exc)

    def capture(self, _):
        if self.session is None:
            self.alert('Start a session first.')
            return
        dialog = Gtk.Dialog(title='Describe the action', transient_for=self, flags=0)
        dialog.add_buttons('Cancel', Gtk.ResponseType.CANCEL, 'Capture', Gtk.ResponseType.OK)
        content = dialog.get_content_area()
        entry = Gtk.Entry(placeholder_text='Action description (do not enter sensitive values)', max_length=256)
        kinds = Gtk.ComboBoxText()
        for kind in ('click', 'scroll', 'text_input', 'key'):
            kinds.append_text(kind)
        kinds.set_active(0)
        content.pack_start(entry, False, False, 6)
        content.pack_start(kinds, False, False, 6)
        dialog.show_all()
        response = dialog.run()
        description, kind = entry.get_text().strip(), kinds.get_active_text()
        dialog.destroy()
        if response != Gtk.ResponseType.OK:
            return
        if not description:
            self.alert('Enter an action description.')
            return
        frame_id = str(uuid.uuid4())
        path = self.root / 'frames' / (frame_id + '.png')
        try:
            subprocess.run(['import', '-window', self.window_id, str(path)], check=True, capture_output=True)
            path.chmod(0o600)
            data = path.read_bytes()
            if data[:8] != b'\x89PNG\r\n\x1a\n':
                raise ValueError('Capture did not produce a PNG.')
            width, height = struct.unpack('>II', data[16:24])
            timestamp = int((time.monotonic() - self.started) * 1000)
            self.session['frames'].append({'id': frame_id, 'timestamp_ms': timestamp, 'filename': path.name, 'width': width, 'height': height, 'sha256': hashlib.sha256(data).hexdigest()})
            self.session['interactions'].append({'id': str(uuid.uuid4()), 'timestamp_ms': timestamp, 'kind': kind, **({'key': 'redacted'} if kind == 'text_input' else {}), 'accessibility': {'title': description}, 'after_frame_id': frame_id})
            self.store.append([description, kind, path.name])
            self.status.set_text('Captured. Select a row to review its screenshot.')
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            self.alert(f'Capture failed: {exc}')

    def preview(self, selection):
        model, row = selection.get_selected()
        if row and self.root:
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(self.root / 'frames' / model[row][2]), 500, 200, True)
                self.image.set_from_pixbuf(pixbuf)
            except Exception as exc:
                self.alert(exc)

    def remove(self, _):
        model, row = self.list.get_selection().get_selected()
        if row is None or self.session is None:
            return
        filename = model[row][2]
        frame = next(f for f in self.session['frames'] if f['filename'] == filename)
        self.session['frames'].remove(frame)
        self.session['interactions'] = [i for i in self.session['interactions'] if i.get('after_frame_id') != frame['id']]
        (self.root / 'frames' / filename).unlink(missing_ok=True)
        model.remove(row)
        self.image.clear()

    def save(self, _):
        if self.session is None:
            self.alert('Start a session first.')
            return
        try:
            self.session['duration_ms'] = int((time.monotonic() - self.started) * 1000)
            path = self.root / 'manifest.json'
            path.write_text(json.dumps(self.session, indent=2) + '\n')
            path.chmod(0o600)
            self.status.set_text(f'Saved {path}. Review remains incomplete; nothing was uploaded.')
            self.session = None
            self.store.clear()
            self.image.clear()
        except OSError as exc:
            self.alert(exc)


if __name__ == '__main__':
    os.umask(0o077)
    Recorder().show_all()
    Gtk.main()
