#!/usr/bin/env bash
# Fully automated: build a device, (re)launch the simulator, WAIT until the watch
# face has actually rendered, then screenshot the sim window.
#
# "Is the device booted yet?" -- the simulator emits no render-complete event
# (nothing lands in monkeydo.log). But the window itself is the signal: before the
# app draws, the sim window is static and matches a blank baseline; once the face
# renders it differs a lot from that baseline, then settles to just the second
# hand (~0.2% of pixels/sec). So: capture a blank baseline (sim up, app not loaded
# yet), then poll until a frame differs a lot from the baseline AND is stable vs
# the previous frame. Frames are normalised to a fixed size before comparing, so
# it's device-agnostic and never trips ImageMagick's same-size requirement.
#
# Usage: ./auto-shot.sh [DEVICE] [out.png]   (default marq2aviator, /tmp/moonkey-sim.png)
set -euo pipefail
export LC_ALL=C   # force '.' decimal in ImageMagick fx output

DEVICE="${1:-marq2aviator}"
OUT="${2:-/tmp/moonkey-sim.png}"
KEY="$HOME/.connectiq/developer_key.der"
SDKBIN="$("$HOME/go/bin/connect-iq-sdk-manager-cli" sdk current-path --bin)"
PRG="bin/moonkey-${DEVICE}.prg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo ">> build $DEVICE"
"$SDKBIN/monkeyc" -d "$DEVICE" -f moonkey.jungle -o "$PRG" -y "$KEY" -w >/dev/null

echo ">> restart simulator (device switch needs a fresh sim)"
pkill -f 'bin/simulato[r]' 2>/dev/null || true; sleep 2
setsid env GDK_BACKEND=x11 "$SDKBIN/simulator" >/tmp/ciqsim.log 2>&1 </dev/null &
for i in $(seq 1 80); do ss -ltn 2>/dev/null | grep -q ':1234' && break; sleep 0.3; done

# Blank baseline: the sim window with no app loaded yet (retry until it exists).
for i in $(seq 1 12); do ./screenshot.sh "$TMP/base.png" >/dev/null 2>&1 && break; sleep 0.5; done

echo ">> load app"
> /tmp/monkeydo.log
setsid "$SDKBIN/monkeydo" "$PRG" "$DEVICE" >/tmp/monkeydo.log 2>&1 </dev/null &

# Changed-pixel count between two frames, each normalised to 240x240 first so
# size never matters. Returns the full count (=100%) if compare fails.
N=57600 # 240*240
pct() {
  magick "$1" -resize 240x240\! "$TMP/a.png" 2>/dev/null
  magick "$2" -resize 240x240\! "$TMP/b.png" 2>/dev/null
  magick compare -metric AE -fuzz 8% "$TMP/a.png" "$TMP/b.png" null: 2>&1 \
    | grep -oE '^[0-9]+' | head -1 || echo "$N"
}

echo ">> wait for render (differs from blank, then settles)"
prev="$TMP/base.png"; ready=0
for t in $(seq 1 30); do
  sleep 1
  ./screenshot.sh "$TMP/cur.png" >/dev/null 2>&1 || continue
  db=$(pct "$TMP/cur.png" "$TMP/base.png")   # vs blank baseline -> "appeared"
  dp=$(pct "$TMP/cur.png" "$prev")           # vs previous frame  -> "settled"
  if awk -v db="${db:-$N}" -v dp="${dp:-$N}" -v n="$N" \
       'BEGIN{exit !(db/n*100>20 && dp/n*100<2)}'; then
    echo "   rendered + settled at ~${t}s"; ready=1; break
  fi
  cp "$TMP/cur.png" "$TMP/prev.png"; prev="$TMP/prev.png"
done
[ "$ready" = 1 ] || echo "   WARN: render not confirmed within 30s; capturing anyway"

./screenshot.sh "$OUT"
