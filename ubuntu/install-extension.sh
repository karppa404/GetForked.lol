#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/retrace@local"
mkdir -p "$target_dir"
install -m 644 "$source_dir/gnome-extension/metadata.json" "$target_dir/metadata.json"
install -m 644 "$source_dir/gnome-extension/extension.js" "$target_dir/extension.js"
install -m 644 "$source_dir/app.py" "$target_dir/app.py"
printf '%s\n' 'Installed Retrace extension. Log out and back in, then run: gnome-extensions enable retrace@local'
