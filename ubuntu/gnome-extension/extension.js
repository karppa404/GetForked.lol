import Gio from 'gi://Gio';
import St from 'gi://St';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class RetraceExtension extends Extension {
    enable() {
        this.indicator = new PanelMenu.Button(0.0, 'Retrace', false);
        this.indicator.add_child(new St.Icon({icon_name: 'camera-photo-symbolic', style_class: 'system-status-icon'}));
        this.indicator.connect('button-press-event', () => {
            try {
                Gio.Subprocess.new(['/usr/bin/python3', `${this.path}/app.py`], Gio.SubprocessFlags.NONE);
            } catch (error) {
                Main.notify('Retrace could not start', error.message);
            }
        });
        Main.panel.addToStatusArea(this.uuid, this.indicator);
    }

    disable() {
        this.indicator?.destroy();
        this.indicator = null;
    }
}
