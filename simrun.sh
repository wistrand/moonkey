#!/usr/bin/env bash
# Build + load a device into the simulator, or (with --install) sideload it to a
# connected watch -- optionally overriding app-settings defaults. Pass overrides as
# environment variables named exactly after the <property id> entries in
# resources/settings/properties.xml, e.g.:
#
#     moonImage=1 ./simrun.sh marq2aviator           # cat, in the sim
#     moonImage=2 tz=2 ./simrun.sh fenix843mm         # fox + Stockholm, in the sim
#     moonImage=1 ./simrun.sh --install fenix843mm    # cat, sideloaded to the watch
#
# Mechanism: Application.Properties is seeded from the .prg's properties.xml
# defaults, so for each override we patch that default into properties.xml for the
# build, then restore the file. In the sim we also restart it with the .SET cleared
# so the new defaults take. --install builds the dev variant (moonkey-dev.jungle,
# "Moonkey Dev") and sideloads via install.sh -- the dev sideload reads its settings
# only from the .prg (not Connect-editable), so the baked defaults ARE the effective
# settings. (If a prior dev install persisted settings, `make uninstall` first.)
set -euo pipefail

INSTALL=0
if [ "${1:-}" = "--install" ]; then INSTALL=1; shift; fi

DEVICE="${1:-marq2aviator}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROPS="$ROOT/resources/settings/properties.xml"
KEY="$HOME/.connectiq/developer_key.der"
SDKBIN="$("$HOME/go/bin/connect-iq-sdk-manager-cli" sdk current-path --bin)"

if [ "$INSTALL" = 1 ]; then
    JUNGLE="$ROOT/moonkey-dev.jungle"; PRG="$ROOT/bin/moonkey-dev-${DEVICE}.prg"
else
    JUNGLE="$ROOT/moonkey.jungle";     PRG="$ROOT/bin/moonkey-${DEVICE}.prg"
fi
mkdir -p "$ROOT/bin"

# Collect overrides: env vars whose name matches a property id in properties.xml.
ov=()
while read -r id; do
    v="${!id-__UNSET__}"
    [ "$v" = "__UNSET__" ] || ov+=("$id=$v")
done < <(grep -oE 'id="[a-zA-Z]+"' "$PROPS" | sed -E 's/id="(.*)"/\1/')

restore() { [ -f "$PROPS.bak" ] && mv -f "$PROPS.bak" "$PROPS"; return 0; }  # return 0 so set -e doesn't abort when there's no .bak (no overrides)

if [ ${#ov[@]} -gt 0 ]; then
    echo ">> settings overrides: ${ov[*]}"
    cp "$PROPS" "$PROPS.bak"; trap restore EXIT
    for kv in "${ov[@]}"; do
        k="${kv%%=*}"; val="${kv#*=}"
        sed -i -E "s#(<property id=\"$k\" type=\"[a-z]+\">)[^<]*(</property>)#\1${val}\2#" "$PROPS"
    done
fi

echo ">> build $DEVICE"
"$SDKBIN/monkeyc" -d "$DEVICE" -f "$JUNGLE" -o "$PRG" -y "$KEY" -w >/dev/null
restore; trap - EXIT   # the .prg has baked the defaults; restore properties.xml now

if [ "$INSTALL" = 1 ]; then
    echo ">> sideload to watch"
    "$ROOT/install.sh" "$DEVICE" "$PRG"
    echo "installed $DEVICE (overrides: ${ov[*]:-none})"
    exit 0
fi

if [ ${#ov[@]} -gt 0 ]; then
    echo ">> restart sim + clear persisted store (so the overridden defaults apply)"
    pkill -f 'bin/simulato[r]' 2>/dev/null || true; sleep 2
    find /tmp/com.garmin.connectiq -iname "MOONKEY*.SET" -delete 2>/dev/null || true
fi

pgrep -f 'bin/simulato[r]' >/dev/null \
    || { setsid env GDK_BACKEND=x11 "$SDKBIN/simulator" >/tmp/ciqsim.log 2>&1 </dev/null & sleep 5; }
for i in $(seq 1 60); do ss -ltn 2>/dev/null | grep -q ':1234' && break; sleep 0.3; done

> /tmp/monkeydo.log
setsid "$SDKBIN/monkeydo" "$PRG" "$DEVICE" >/tmp/monkeydo.log 2>&1 </dev/null &
echo "loaded $DEVICE (overrides: ${ov[*]:-none}); logs /tmp/monkeydo.log"
