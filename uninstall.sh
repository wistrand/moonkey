#!/usr/bin/env bash
#
# Remove sideloaded Moonkey .prg(s) from a Garmin device over USB/MTP.
# The inverse of install.sh. Handy before installing a store/beta build: a
# sideloaded copy carries the same app id and conflicts with the beta install.
#
# Usage:
#   ./uninstall.sh           # remove ALL moonkey-*.prg on the watch (default)
#   ./uninstall.sh marq2     # remove only moonkey-marq2.prg
#
# Prereqs: watch plugged in via USB, unlocked, "allow file transfer" accepted.
# Needs gio (gvfs MTP backend).

set -euo pipefail

DEVICE="${1:-}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Locate the MTP mount, mounting the watch if needed (same as install.sh).
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
# 2. Find the storage root that holds GARMIN/Apps.
# ---------------------------------------------------------------------------
APPS=""
for store in "$DEV"/*; do
    for d in "GARMIN/Apps" "GARMIN/APPS" "Garmin/Apps"; do
        if [ -d "$store/$d" ]; then APPS="$store/$d"; break 2; fi
    done
done
[ -n "$APPS" ] || die "Could not locate GARMIN/Apps on the device."
log "App folder: $APPS"

# ---------------------------------------------------------------------------
# 3. Collect the Moonkey .prg(s) to remove.
# ---------------------------------------------------------------------------
matches=()
if [ -z "$DEVICE" ] || [ "$DEVICE" = "all" ]; then
    for f in "$APPS"/moonkey-*.prg; do [ -e "$f" ] && matches+=("$f"); done
    label="all Moonkey builds"
else
    f="$APPS/moonkey-$DEVICE.prg"
    [ -e "$f" ] && matches+=("$f")
    label="moonkey-$DEVICE.prg"
fi

if [ ${#matches[@]} -eq 0 ]; then
    log "No $label found on the device (already uninstalled?)."
    present=""
    for f in "$APPS"/moonkey-*.prg; do [ -e "$f" ] && present+="  $(basename "$f")\n"; done
    [ -n "$present" ] && printf "Moonkey files present:\n%b" "$present"
else
    for f in "${matches[@]}"; do
        if gio rm "$f" 2>/dev/null || rm -f "$f"; then
            log "Removed $(basename "$f")"
        else
            die "Failed to remove $f (is the watch unlocked / not busy?)."
        fi
    done
fi

# ---------------------------------------------------------------------------
# 4. Flush and unmount so it's safe to unplug.
# ---------------------------------------------------------------------------
sync 2>/dev/null || true
gio mount -u "$DEV" >/dev/null 2>&1 || true

log "Done. Unplug the watch."
