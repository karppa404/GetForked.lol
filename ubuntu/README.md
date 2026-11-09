# Ubuntu manual evidence capture (X11)

This is an initial GTK application and manual capture tool, not feature parity with the macOS recorder. It captures the selected X11 window after each action you describe. It does not observe clicks or keyboard input, record network traffic, connect to a workspace, or upload. Descriptions are stored as interaction titles; they may contain sensitive information. Wayland is not supported.

Install Python 3, ImageMagick (`import`), and `x11-utils` (`xwininfo`). Log in to an X11 session. Run `xwininfo` and click the target window to find its ID, then:

```sh
python3 ubuntu/record.py --window 0x123456 --app 'Example' --app-id example.app --pid 1234 --output ./session
```

Perform each action in the target app, return to the terminal, and enter a description. Submit an empty description to finish. Review every screenshot and description before sharing. The generated manifest marks network as `not_captured` and review as incomplete. Window contents may include private data; obscured windows or protected content may not capture correctly.

## GTK application

Install `python3-gi`, `gir1.2-gtk-3.0`, ImageMagick and `x11-utils`, then run `/usr/bin/python3 ubuntu/app.py`. Use `xwininfo` to find the window ID and `ps` to find its PID. Start a session, perform each action, then use Capture action. Select each row to preview its screenshot; Remove selected deletes that screenshot and its action. Save session writes the manifest. Closing before saving loses the manifest. The output is an evidence collection, not an upload-ready reviewed session.

The GTK app does not yet implement automatic input observation, GNOME Wayland screencast portal integration, workspace connection, network correlation, or upload. X11 window capture and the GUI require manual verification in a graphical Ubuntu session.

## GNOME top bar

GNOME Shell requires an extension to add a button to its top bar. For GNOME Shell 45–49, run `ubuntu/install-extension.sh`, log out and back in, then run `gnome-extensions enable retrace@local` (or enable Retrace in the Extensions app). The camera icon launches the GTK recorder. Re-run the installer after updating the app. Disable with `gnome-extensions disable retrace@local`. The button is a launcher; it does not yet show recording status or provide capture controls. GNOME Shell extension loading and the top bar have not been tested in a graphical session.
