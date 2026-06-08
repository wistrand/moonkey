#!/usr/bin/env bash
# Capture the running Connect IQ simulator window directly, by its X11 window id
# (located via window title), instead of screenshotting the whole display and
# guessing where the window sits.
#
# Why this works on GNOME/Wayland: the simulator is launched with GDK_BACKEND=x11,
# so it is an XWayland (X11) client. Native Wayland hides window geometry, but the
# X11 window is visible to `xprop` (find it by WM_NAME) and `import` (ImageMagick)
# can grab that exact window by id -- both already part of the toolchain, no extra
# packages. Capturing by id is immune to the window moving, and `import` reads the
# window's backing pixmap (so the crop offsets are relative to the window's fixed
# layout, not the screen).
#
# Usage: ./screenshot.sh [output.png]      # default: /tmp/moonkey-sim.png
set -euo pipefail

OUT="${1:-/tmp/moonkey-sim.png}"
TITLE="CIQ Simulator"

command -v xprop  >/dev/null || { echo "error: xprop not found" >&2; exit 1; }
command -v import >/dev/null || { echo "error: ImageMagick 'import' not found" >&2; exit 1; }

# Find the simulator's X11 window id by WM_NAME among the managed XWayland clients.
simid=""
for id in $(xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -oE '0x[0-9a-f]+'); do
    if xprop -id "$id" WM_NAME 2>/dev/null | grep -qi "$TITLE"; then
        simid="$id"
        break
    fi
done

if [ -z "$simid" ]; then
    echo "error: no window titled '$TITLE' found -- is the simulator running? (make run / make sim)" >&2
    exit 1
fi

import -window "$simid" "$OUT"
echo "$OUT ($(magick identify -format '%wx%h' "$OUT"); sim window $simid)"
