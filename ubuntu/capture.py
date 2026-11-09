"""Screenshot backends. No input observation, network access, or silent desktop capture."""
from pathlib import Path
import os
import struct
import subprocess
from urllib.parse import unquote, urlsplit
import uuid


def png_size(data):
    if len(data) < 33 or data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        raise ValueError('Capture did not produce a PNG.')
    width, height = struct.unpack('>II', data[16:24])
    if not width or not height:
        raise ValueError('Capture has invalid dimensions.')
    return width, height


def local_portal_file(uri):
    parsed = urlsplit(uri)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost') or parsed.query or parsed.fragment:
        raise ValueError('Portal returned a non-local screenshot.')
    path = Path(unquote(parsed.path))
    if not path.is_absolute():
        raise ValueError('Portal returned an invalid screenshot path.')
    return path


def capture_x11(window, destination):
    if not window or not window.startswith('0x') or any(c not in '0123456789abcdefABCDEF' for c in window[2:]) or len(window) <= 2 or int(window, 16) == 0:
        raise ValueError('Choose an explicit hexadecimal X11 window ID.')
    subprocess.run(['import', '-window', window, str(destination)], check=True, capture_output=True, timeout=30)


def capture_portal(destination):
    # Subscribe before the request: a fast portal can respond before the method returns.
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    token = 'retrace_' + uuid.uuid4().hex
    sender = bus.get_unique_name()[1:].replace('.', '_')
    request = f'/org/freedesktop/portal/desktop/request/{sender}/{token}'
    loop = GLib.MainLoop()
    result = {}

    def response(_bus, _sender, _path, _iface, _signal, params):
        result['response'] = params.unpack()
        loop.quit()

    subscription = bus.signal_subscribe('org.freedesktop.portal.Desktop', 'org.freedesktop.portal.Request', 'Response', request, None, Gio.DBusSignalFlags.NONE, response)
    def timeout():
        result['error'] = 'Screenshot request timed out.'
        loop.quit()
        return False
    timer = GLib.timeout_add_seconds(120, timeout)
    try:
        returned = bus.call_sync('org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop', 'org.freedesktop.portal.Screenshot', 'Screenshot', GLib.Variant('(sa{sv})', ('', {'handle_token': GLib.Variant('s', token), 'interactive': GLib.Variant('b', True)})), GLib.VariantType.new('(o)'), Gio.DBusCallFlags.NONE, 10000, None).unpack()[0]
        if returned != request:
            raise ValueError('Portal returned an unexpected request handle.')
        if 'response' not in result:
            loop.run()
        if 'error' in result:
            raise ValueError(result['error'])
        code, values = result['response']
        if code != 0:
            raise ValueError('Screenshot cancelled or denied; no evidence added.')
        source = local_portal_file(values.get('uri', ''))
        data = source.read_bytes()
        png_size(data)
        # Copy only: portal-owned files must not be deleted by this application.
        with destination.open('xb') as output:
            os.chmod(destination, 0o600)
            output.write(data)
    finally:
        if 'error' not in result:
            GLib.source_remove(timer)
        bus.signal_unsubscribe(subscription)
        if 'response' not in result:
            bus.call('org.freedesktop.portal.Desktop', request, 'org.freedesktop.portal.Request', 'Close', None, None, Gio.DBusCallFlags.NONE, 1000, None, None)


def capture(backend, window, destination):
    try:
        if backend == 'portal':
            capture_portal(destination)
        elif backend == 'x11':
            if os.environ.get('XDG_SESSION_TYPE') == 'wayland':
                raise ValueError('X11 capture is unavailable on Wayland. Select the desktop portal.')
            capture_x11(window, destination)
        else:
            raise ValueError('Unknown capture backend.')
        destination.chmod(0o600)
        return png_size(destination.read_bytes())
    except Exception:
        destination.unlink(missing_ok=True)
        raise
