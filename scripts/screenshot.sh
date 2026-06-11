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
# Usage: ./screenshot.sh [--crop] [--transparent] [output.png]  # default: /tmp/moonkey-sim.png
#   --crop / -c : clip the sim's menu header + status footer, keeping the watch
#       device area (detected as the strongly-white-background row band). Applied
#       before --transparent.
#   --transparent / -t : make the white sim-window background transparent. Uses a
#       SEEDED floodfill (from background-white points), so only white CONNECTED to
#       the background is removed -- the watch's own white pixels (second hand, etc.)
#       are enclosed by the black face, disconnected, and so preserved. A global
#       "white -> transparent" would wrongly erase those, hence floodfill.
set -euo pipefail
export LC_ALL=C   # force '.' decimal in ImageMagick fx output

TRANSPARENT=0
CROP=0
OUT=""
for a in "$@"; do
    case "$a" in
        -t|--transparent) TRANSPARENT=1 ;;
        -c|--crop) CROP=1 ;;
        -*) echo "error: unknown option '$a'" >&2; exit 2 ;;
        *)  OUT="$a" ;;
    esac
done
OUT="${OUT:-/tmp/moonkey-sim.png}"
TITLE="CIQ Simulator"
FUZZ="15%"

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

if [ "$CROP" = 1 ]; then
    # Clip the sim's menu header and status footer: the watch device area sits on a
    # white background, while the grey chrome bars have only sparse (text) white. So
    # threshold near-white -> white, average each row to 1px (= its white fraction),
    # and keep the band of rows that are strongly white (>~78%) -- that span brackets
    # the device area (its top/bottom white margins enclose the watch). Done BEFORE
    # the transparent floodfill, which would otherwise erase the white we detect on.
    ch=$(magick "$OUT" -format "%[fx:h]" info:)
    cw=$(magick "$OUT" -format "%[fx:w]" info:)
    bounds=$(magick "$OUT" -fuzz 5% -fill black +opaque white -colorspace gray -resize 1x${ch}\! txt:- \
        | awk -F'[,:()]' '/^[0-9]/ { y=$2; v=$4+0; if (v>200){ if(t==""){t=y}; b=y } } END{ if(t!="") print t" "b }')
    if [ -n "$bounds" ]; then
        t="${bounds% *}"; b="${bounds#* }"
        magick "$OUT" -crop "${cw}x$((b-t+1))+0+${t}" +repage "$OUT"
        echo "(cropped chrome: kept rows ${t}-${b} of ${ch})"
    else
        echo "warning: no white device area found; left '$OUT' uncropped" >&2
    fi
fi

if [ "$TRANSPARENT" = 1 ]; then
    w=$(magick "$OUT" -format "%[fx:w]" info:)
    h=$(magick "$OUT" -format "%[fx:h]" info:)
    # Candidate background-white seed points near the edges (a few px in, to clear
    # the dark Mutter window frame): left/right margins at several heights, plus the
    # menu bar (top) and status bar (bottom). Multiple seeds cover white regions that
    # the watch body might split apart.
    floods=()
    for pt in "4,$((h/2))" "$((w-5)),$((h/2))" \
              "4,$((h/4))" "$((w-5)),$((h/4))" \
              "4,$((h*3/4))" "$((w-5)),$((h*3/4))" \
              "$((w/2)),6" "$((w-30)),6" "30,6" "$((w/2)),$((h-6))"; do
        x="${pt%,*}"; y="${pt#*,}"
        # white iff the darkest RGB channel at the seed is high (excludes the dark
        # frame and any coloured/AMOLED pixel, e.g. amber -> low blue).
        minc=$(magick "${OUT}[1x1+${x}+${y}]" -format "%[fx:255*minima]" info: 2>/dev/null || echo 0)
        if awk -v m="$minc" 'BEGIN{exit !(m>230)}'; then
            floods+=(-floodfill "+${x}+${y}" white)
        fi
    done
    if [ ${#floods[@]} -eq 0 ]; then
        echo "warning: no white background seed found; leaving '$OUT' opaque" >&2
    else
        magick "$OUT" -alpha set -fuzz "$FUZZ" -fill none "${floods[@]}" "$OUT"
        echo "(background made transparent via $(( ${#floods[@]} / 3 )) floodfill seed(s))"
    fi
fi

echo "$OUT ($(magick identify -format '%wx%h' "$OUT"); sim window $simid)"
