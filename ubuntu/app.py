#!/usr/bin/python3
"""Single-instance GTK recorder for explicit X11 or GNOME portal evidence."""
import hashlib
import json
import os
import shutil
import subprocess
import threading
from pathlib import Path
import time
import uuid
import threading
from integration import Workspace, private_json
from datetime import datetime, timezone

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GdkPixbuf, Gio, GLib
from capture import capture as capture_frame
from codex_analysis import analyze


class Recorder(Gtk.ApplicationWindow):
    def __init__(self, application):
        super().__init__(application=application, title='Retrace — Ubuntu')
        self.set_default_size(760, 580)
        self.connect('delete-event', self.close_requested)
        self.application = application
        self.paused = False
        self.busy = False
        self.session = None
        self.started = None
        self.root = None
        self.review_manifest = None
        self.saved_root = None
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        self.add(box)
        box.pack_start(Gtk.Label(label='Manual evidence capture. Portal screenshots may include other apps; select carefully and review before sharing.', xalign=0), False, False, 0)
        grid = Gtk.Grid(column_spacing=8, row_spacing=6)
        box.pack_start(grid, False, False, 0)
        self.backend = Gtk.ComboBoxText()
        self.backend.append('portal', 'GNOME desktop portal (confirm each screenshot)')
        self.backend.append('x11', 'X11 selected window')
        self.backend.set_active_id('portal' if os.environ.get('XDG_SESSION_TYPE') == 'wayland' else 'x11')
        box.pack_start(self.backend, False, False, 0)
        connection = Gtk.Box(spacing=6)
        self.api_url = Gtk.Entry(text='http://127.0.0.1:8000', hexpand=True)
        connection.pack_start(self.api_url, True, True, 0)
        for title, handler in [('Connect workspace', self.connect_workspace), ('Open saved session', self.open_session), ('Upload & Analyze', self.upload)]:
            button = Gtk.Button(label=title)
            button.connect('clicked', handler)
            connection.pack_start(button, False, False, 0)
        box.pack_start(connection, False, False, 0)
        self.fields = {}
        for row, (key, label, default) in enumerate((('app', 'Application name', ''), ('app_id', 'Application ID', ''), ('pid', 'Process ID', ''), ('window', 'X11 window ID', ''), ('folder', 'New session folder', str(Path.home() / 'retrace-session')))):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, row, 1, 1)
            entry = Gtk.Entry(text=default, hexpand=True)
            grid.attach(entry, 1, row, 1, 1)
            self.fields[key] = entry
        controls = Gtk.Box(spacing=6)
        box.pack_start(controls, False, False, 0)
        for title, handler in [('Sign in with ChatGPT', self.sign_in), ('Start', self.start), ('Capture action', self.capture), ('Pause / Resume', self.pause), ('Remove selected', self.remove), ('Save session', self.save)]:
            button = Gtk.Button(label=title)
            button.connect('clicked', handler)
            controls.pack_start(button, False, False, 0)
        self.review_consent = Gtk.CheckButton(label='I reviewed all screenshots and descriptions and consent to send this saved session to OpenAI through Codex.')
        box.pack_start(self.review_consent, False, False, 0)
        analyze_button = Gtk.Button(label='Generate user stories & spec with Codex')
        analyze_button.connect('clicked', self.analyze_saved)
        box.pack_start(analyze_button, False, False, 0)
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
        if self.busy:
            return
        try:
            if self.session is not None:
                raise ValueError('Save the current session before starting another.')
            values = {k: v.get_text().strip() for k, v in self.fields.items()}
            if not all(values[k] for k in ('app', 'app_id', 'pid', 'folder')) or (self.backend.get_active_id() == 'x11' and not values['window']):
                raise ValueError('Complete all fields first.')
            pid = int(values['pid'])
            if pid <= 0 or pid >= 2**31:
                raise ValueError('Invalid process ID.')
            self.root = Path(values['folder']).expanduser()
            self.root.mkdir(mode=0o700, parents=True, exist_ok=False)
            (self.root / 'frames').mkdir(mode=0o700)
            self.review_manifest = None
            self.store.clear()
            self.image.clear()
            self.started = time.monotonic()
            self.session = {'schema_version': 1, 'id': str(uuid.uuid4()), 'app': {'name': values['app'], 'bundle_id': values['app_id'], 'pid': pid}, 'started_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'), 'duration_ms': 0, 'interactions': [], 'frames': [], 'network': [], 'network_status': 'not_captured', 'redaction': {'reviewed': False}}
            self.window_id = values['window']
            self.capture_backend = self.backend.get_active_id()
            self.paused = False
            self.publish_state()
            self.status.set_text('Recording started. Perform an action, then capture it.')
        except (OSError, ValueError) as exc:
            self.alert(exc)

    def capture(self, _):
        if self.busy or self.paused:
            return
        self.busy = True
        self.publish_state()
        try:
            self.capture_action()
        finally:
            self.busy = False
            self.publish_state()

    def capture_action(self):
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
            width, height = capture_frame(self.capture_backend, self.window_id, path)
            data = path.read_bytes()
            timestamp = int((time.monotonic() - self.started) * 1000)
            self.session['frames'].append({'id': frame_id, 'timestamp_ms': timestamp, 'filename': path.name, 'width': width, 'height': height, 'sha256': hashlib.sha256(data).hexdigest()})
            self.session['interactions'].append({'id': str(uuid.uuid4()), 'timestamp_ms': timestamp, 'kind': kind, **({'key': 'redacted'} if kind == 'text_input' else {}), 'accessibility': {'title': description}, 'after_frame_id': frame_id})
            self.store.append([description, kind, path.name])
            self.status.set_text('Captured. Select a row to review its screenshot.')
        except Exception as exc:
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
        if self.busy:
            return
        model, row = self.list.get_selection().get_selected()
        evidence = self.session if self.session is not None else self.review_manifest
        if row is None or evidence is None:
            return
        if (self.root / 'upload.json').exists():
            self.alert('Uploaded evidence is locked. Create a new session for changed evidence.')
            return
        filename = model[row][2]
        frame = next(f for f in evidence['frames'] if f['filename'] == filename)
        evidence['frames'].remove(frame)
        evidence['interactions'] = [i for i in evidence['interactions'] if i.get('after_frame_id') != frame['id']]
        (self.root / 'frames' / filename).unlink(missing_ok=True)
        model.remove(row)
        self.image.clear()
        if self.session is None:
            self.review_consent.set_active(False)
            private_json(self.root / 'manifest.json', evidence)

    def save(self, _):
        if self.busy:
            return
        if self.session is None:
            self.alert('Start a session first.')
            return
        try:
            self.session['duration_ms'] = int((time.monotonic() - self.started) * 1000)
            path = self.root / 'manifest.json'
            private_json(path, self.session)
            self.review_manifest = self.session
            self.status.set_text(f'Saved {path}. Review remains incomplete; nothing was uploaded.')
            self.saved_root = self.root
            self.review_consent.set_active(False)
            self.session = None
            self.paused = False
            self.publish_state()
        except OSError as exc:
            self.alert(exc)

    def sign_in(self, _):
        try:
            if not shutil.which('codex'):
                raise ValueError('Install the official Codex CLI first, then try again.')
            subprocess.Popen(['x-terminal-emulator', '-e', 'codex', 'login'])
            self.status.set_text('Complete ChatGPT sign-in in the Codex browser flow. Credentials stay in Codex.')
        except (OSError, ValueError) as exc:
            self.alert(exc)

    def analyze_saved(self, _):
        if self.busy:
            return
        if self.session is not None or self.saved_root is None:
            self.alert('Save a session first. Review its files before generating a report.')
            return
        if not self.review_consent.get_active():
            self.alert('Review every saved screenshot and description, then confirm consent.')
            return
        root = self.saved_root
        self.busy = True
        self.publish_state()
        self.status.set_text('Generating with Codex. Reviewed evidence is sent to OpenAI; subscription limits apply.')
        def work():
            try:
                message = f'Generated {analyze(root, reviewed=True)}'
            except Exception as exc:
                message = str(exc)
            GLib.idle_add(done, message)
        def done(message):
            self.busy = False
            self.publish_state()
            self.status.set_text(message)
            return False
        threading.Thread(target=work, daemon=True).start()

    def background(self, operation, success):
        if self.busy:
            return
        self.busy = True
        self.publish_state()
        self.status.set_text('Working…')
        def run():
            try:
                result, error = operation(), None
            except Exception as exc:
                result, error = None, str(exc)
            def finish():
                self.busy = False
                self.publish_state()
                if error:
                    self.status.set_text(error)
                    self.alert(error)
                else:
                    success(result)
                return False
            GLib.idle_add(finish)
        threading.Thread(target=run, daemon=True).start()

    def connect_workspace(self, _):
        if self.busy:
            return
        try:
            workspace = Workspace(self.api_url.get_text())
            self.background(lambda: workspace.connect('Ubuntu recorder'),
                            lambda _: self.status.set_text('Connected to Local workspace. Credential stored in Secret Service; no evidence uploaded.'))
        except ValueError as exc:
            self.alert(exc)

    def open_session(self, _):
        if self.busy or self.session is not None:
            return
        dialog = Gtk.FileChooserDialog(title='Open saved session folder', transient_for=self,
                                       action=Gtk.FileChooserAction.SELECT_FOLDER)
        dialog.add_buttons('Cancel', Gtk.ResponseType.CANCEL, 'Open', Gtk.ResponseType.OK)
        response = dialog.run()
        folder = dialog.get_filename()
        dialog.destroy()
        if response != Gtk.ResponseType.OK:
            return
        try:
            root = Path(folder)
            manifest_path = root / 'manifest.json'
            if manifest_path.stat().st_size > 4 * 1024 * 1024:
                raise ValueError('Manifest too large.')
            manifest = json.loads(manifest_path.read_text())
            from integration import validate_review_manifest
            validate_review_manifest(manifest)
            # Ubuntu review UI must display every item being shared.
            if manifest.get('network') or manifest.get('network_status') != 'not_captured':
                raise ValueError('Only Ubuntu manual evidence sessions can be reviewed here.')
            frames = {frame['id']: frame for frame in manifest['frames']}
            rows = []
            for item in manifest['interactions']:
                if set(item) - {'id', 'timestamp_ms', 'kind', 'key', 'accessibility', 'after_frame_id'}:
                    raise ValueError('Unsupported interaction metadata; use the original recorder to review.')
                if set(item.get('accessibility', {})) - {'title'} or item.get('key') not in (None, 'redacted'):
                    raise ValueError('Unsupported interaction text; use the original recorder to review.')
                frame = frames.pop(item.get('after_frame_id'), None)
                if frame is None or item.get('before_frame_id') or item.get('delayed_frame_id'):
                    raise ValueError('Unsupported session structure; use the original recorder to review.')
                name = frame['filename']
                if Path(name).name != name or '/' in name or '\\' in name or not name.endswith('.png'):
                    raise ValueError('Unsafe frame filename.')
                rows.append([item.get('accessibility', {}).get('title', ''), item['kind'], name])
            if frames:
                raise ValueError('Session contains screenshots without reviewable actions.')
            self.root, self.review_manifest = root, manifest
            self.saved_root = root
            self.review_consent.set_active(False)
            self.store.clear()
            self.image.clear()
            for row in rows:
                self.store.append(row)
            self.status.set_text('Review every screenshot and description; remove private evidence before Upload & Analyze.')
        except (OSError, ValueError, KeyError, TypeError) as exc:
            self.alert(exc)

    def upload(self, _):
        if self.busy:
            return
        if self.session is not None or self.review_manifest is None:
            self.alert('Save or open a session, then review every screenshot and description first.')
            return
        dialog = Gtk.MessageDialog(transient_for=self, flags=Gtk.DialogFlags.MODAL,
                                   message_type=Gtk.MessageType.WARNING, buttons=Gtk.ButtonsType.OK_CANCEL,
                                   text='Confirm reviewed upload and analysis')
        dialog.format_secondary_text('I reviewed all remaining screenshots and descriptions and am allowed to share them. Sensitive content is not detected automatically. Upload sends all remaining evidence to the selected local API and starts analysis, which may use its configured external model provider.')
        response = dialog.run()
        dialog.destroy()
        if response != Gtk.ResponseType.OK:
            return
        try:
            workspace = Workspace(self.api_url.get_text())
            manifest = json.loads(json.dumps(self.review_manifest))
            root = self.root
            self.background(lambda: workspace.upload_and_analyze(root, manifest, confirmed=True),
                            lambda receipt: self.status.set_text('Uploaded. Analysis job ' + receipt['job_id'] + ' (' + str(receipt['job_status']) + ').'))
        except ValueError as exc:
            self.alert(exc)

    def publish_state(self):
        state = 'capturing' if self.busy else 'idle' if self.session is None else 'paused' if self.paused else 'recording'
        self.application.lookup_action('status').set_state(GLib.Variant('s', state))

    def pause(self, _):
        if self.session is not None and not self.busy:
            self.paused = not self.paused
            self.publish_state()
            self.status.set_text('Paused. No capture is possible.' if self.paused else 'Ready for manual capture.')

    def close_requested(self, *_):
        if self.session is not None or getattr(self, 'busy', False):
            self.hide()
            return True
        return False


class Application(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='org.retrace.Recorder', flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.recorder = None
        status = Gio.SimpleAction.new_stateful('status', None, GLib.Variant('s', 'idle'))
        status.connect('change-state', lambda *_: None)
        self.add_action(status)
        for name in ('show', 'capture', 'pause', 'stop'):
            action = Gio.SimpleAction.new(name, None)
            action.connect('activate', self.control, name)
            self.add_action(action)

    def do_activate(self):
        if self.recorder is None:
            self.recorder = Recorder(self)
            self.recorder.connect('destroy', self.window_destroyed)
        self.recorder.show_all()
        self.recorder.present()

    def window_destroyed(self, *_):
        self.recorder = None

    def control(self, _action, _parameter, name):
        if name == 'show':
            self.activate()
        elif self.recorder:
            if name == 'capture':
                self.recorder.present()
                self.recorder.capture(None)
            elif name == 'pause':
                self.recorder.pause(None)
            elif name == 'stop':
                self.recorder.save(None)
                self.recorder.present()


if __name__ == '__main__':
    os.umask(0o077)
    Application().run(None)
