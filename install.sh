#!/usr/bin/env bash
#
# Sideload the watchface onto a physical Garmin device over USB/MTP.
#
# Copies the device-specific .prg into GARMIN/Apps on the watch. Builds the
# .prg first if it isn't already present in ./bin.
#
# Usage:
#   ./install.sh [DEVICE]
# Examples:
#   ./install.sh                 # marq2aviator (default)
#   ./install.sh fenix847mm
#
# Prereqs: watch plugged in via USB, unlocked, "allow file transfer" accepted.
# Needs gio (gvfs MTP backend) — already present on this system.

set -euo pipefail

DEVICE="${1:-marq2aviator}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRG="$PROJECT_DIR/bin/moonkey-$DEVICE.prg"
KEY="${CONNECTIQ_KEY:-$HOME/.connectiq/developer_key.der}"
CLI="$HOME/go/bin/connect-iq-sdk-manager-cli"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Make sure the .prg exists (build it if missing).
# ---------------------------------------------------------------------------
if [ ! -f "$PRG" ]; then
    log "No prebuilt .prg for '$DEVICE' — building it"
    [ -f "$KEY" ] || die "developer key not found at $KEY"
    if ! command -v monkeyc >/dev/null 2>&1; then
        export PATH="$("$CLI" sdk current-path --bin):$PATH"
    fi
    ( cd "$PROJECT_DIR" && monkeyc -d "$DEVICE" -f moonkey.jungle -o "$PRG" -y "$KEY" -w )
fi
log "Sideloading $(basename "$PRG") ($(stat -c%s "$PRG") bytes) -> $DEVICE"

# ---------------------------------------------------------------------------
# 2. Locate the MTP mount, mounting the watch if needed.
# ---------------------------------------------------------------------------
GVFS_DIR="/run/user/$(id -u)/gvfs"
find_mount() { ls -d "$GVFS_DIR"/mtp* 2>/dev/null | head -1 || true; }

DEV="$(find_mount)"
if [ -z "$DEV" ]; then
    log "No MTP mount yet — trying to mount the watch"
    uri="$(gio mount -li 2>/dev/null | grep -oE 'mtp://[^ ]+' | head -1 || true)"
    [ -n "$uri" ] && gio mount "$uri" >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        DEV="$(find_mount)"
        [ -n "$DEV" ] && break
        sleep 1
    done
fi
[ -n "$DEV" ] || die "Watch not found. Plug in via USB, unlock it, accept 'allow file transfer', then retry."
log "MTP mount: $DEV"

# ---------------------------------------------------------------------------
# 3. Find the storage root that holds GARMIN/Apps.
# ---------------------------------------------------------------------------
APPS=""
for store in "$DEV"/*; do
    for d in "GARMIN/Apps" "GARMIN/APPS" "Garmin/Apps"; do
        if [ -d "$store/$d" ]; then APPS="$store/$d"; break 2; fi
    done
done
if [ -z "$APPS" ]; then
    die "Could not locate GARMIN/Apps on the device. Storage roots seen:
$(ls -d "$DEV"/* 2>/dev/null || true)
Open one and check the path, then copy manually."
fi
log "Target folder: $APPS"

# ---------------------------------------------------------------------------
# 4. Copy the .prg (gio handles MTP better than plain cp).
# ---------------------------------------------------------------------------
DEST="$APPS/$(basename "$PRG")"
if gio copy "$PRG" "$DEST" 2>/dev/null || cp "$PRG" "$DEST"; then
    log "Copied to device."
else
    die "Copy failed. Try the file-manager method, or check free space on the watch."
fi

# ---------------------------------------------------------------------------
# 5. Flush and unmount so it's safe to unplug.
# ---------------------------------------------------------------------------
sync 2>/dev/null || true
gio mount -u "$DEV" >/dev/null 2>&1 || true

cat <<EOF

$(log "Done")
Unplug the watch. On the device, open the watch-face list
(long-press UP -> Watch Face, or Connect IQ) and select "Moonkey".
EOF
