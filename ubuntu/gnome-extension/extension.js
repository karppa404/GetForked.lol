import Gio from 'gi://Gio';
import St from 'gi://St';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class RetraceExtension extends Extension {
    enable() {
        this.indicator = new PanelMenu.Button(0.0, 'Retrace', false);
        this.label = new St.Label({text: 'Retrace · Idle', y_align: 2});
        this.indicator.add_child(this.label);
        this.actions = Gio.DBusActionGroup.get(Gio.DBus.session,
            'org.retrace.Recorder', '/org/retrace/Recorder');
        this.indicator.menu.addAction('Open recorder / Start…', () => {
            try {
                Gio.Subprocess.new(['/usr/bin/python3', `${this.path}/app.py`], Gio.SubprocessFlags.NONE);
            } catch (error) {
                Main.notify('Retrace could not start', error.message);
            }
        });
        this.capture = this.indicator.menu.addAction('Capture action…', () => this.actions.activate_action('capture', null));
        this.pause = this.indicator.menu.addAction('Pause / Resume', () => this.actions.activate_action('pause', null));
        this.stop = this.indicator.menu.addAction('Stop & Save locally', () => this.actions.activate_action('stop', null));
        this.indicator.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const notice = new PopupMenu.PopupMenuItem('Manual capture · review before sharing', {reactive: false});
        this.indicator.menu.addMenuItem(notice);
        this.signals = ['action-state-changed', 'action-added', 'action-removed'].map(signal =>
            this.actions.connect(signal, () => this.refresh()));
        Main.panel.addToStatusArea(this.uuid, this.indicator);
        this.refresh();
    }

    refresh() {
        const state = this.actions.get_action_state('status')?.deep_unpack() ?? 'idle';
        const labels = {idle: 'Idle', recording: 'Ready', paused: 'Paused', capturing: 'Capturing…'};
        this.label.set_text(`Retrace · ${labels[state] ?? 'Idle'}`);
        this.capture.setSensitive(state === 'recording');
        this.pause.setSensitive(state === 'recording' || state === 'paused');
        this.stop.setSensitive(state === 'recording' || state === 'paused');
    }

    disable() {
        for (const id of this.signals ?? [])
            this.actions.disconnect(id);
        this.signals = [];
        this.actions = null;
        this.indicator?.destroy();
        this.indicator = null;
    }
}
