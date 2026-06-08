#!/usr/bin/env bash
# Build + load a device into the simulator, optionally overriding app-settings
# defaults for this run. Pass overrides as environment variables named exactly
# after the <property id> entries in resources/settings/properties.xml, e.g.:
#
#     moonImage=1 ./simrun.sh marq2aviator      # cat
#     moonImage=2 tz=2 ./simrun.sh fenix843mm   # fox + Stockholm
#     accentColor=16724016 ./simrun.sh          # red accent (default device)
#
# Mechanism: the simulator seeds Application.Properties from the .prg's
# properties.xml defaults, but only when its persisted store (.SET) is absent and
# the sim is fresh. So when overrides are given we patch those defaults into
# properties.xml for the build, restore the file immediately after, then restart
# the sim with the .SET cleared so the new defaults take effect. No overrides =>
# a plain build + load into the running sim (the old `make run` behaviour).
set -euo pipefail

DEVICE="${1:-marq2aviator}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROPS="$ROOT/resources/settings/properties.xml"
KEY="$HOME/.connectiq/developer_key.der"
SDKBIN="$("$HOME/go/bin/connect-iq-sdk-manager-cli" sdk current-path --bin)"
PRG="$ROOT/bin/moonkey-${DEVICE}.prg"

# Collect overrides: env vars whose name matches a property id in properties.xml.
ov=()
while read -r id; do
    v="${!id-__UNSET__}"
    [ "$v" = "__UNSET__" ] || ov+=("$id=$v")
done < <(grep -oE 'id="[a-zA-Z]+"' "$PROPS" | sed -E 's/id="(.*)"/\1/')

restore() { [ -f "$PROPS.bak" ] && mv -f "$PROPS.bak" "$PROPS"; }

if [ ${#ov[@]} -gt 0 ]; then
    echo ">> settings overrides: ${ov[*]}"
    cp "$PROPS" "$PROPS.bak"; trap restore EXIT
    for kv in "${ov[@]}"; do
        k="${kv%%=*}"; val="${kv#*=}"
        sed -i -E "s#(<property id=\"$k\" type=\"number\">)[^<]*(</property>)#\1${val}\2#" "$PROPS"
    done
fi

echo ">> build $DEVICE"
"$SDKBIN/monkeyc" -d "$DEVICE" -f "$ROOT/moonkey.jungle" -o "$PRG" -y "$KEY" -w >/dev/null
restore; trap - EXIT   # the .prg has baked the defaults; restore properties.xml now

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
