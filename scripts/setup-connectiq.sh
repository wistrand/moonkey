#!/usr/bin/env bash
#
# Set up the Garmin Connect IQ command-line toolchain without the GUI SDK Manager
# (the prebuilt sdkmanager binary needs libwebkit2gtk-4.0, which Arch/Manjaro dropped).
#
# It does three things:
#   1. Generates a developer key with openssl (no Garmin login needed).
#   2. Installs lindell/connect-iq-sdk-manager-cli, an open-source replacement
#      for the GUI manager.
#   3. Uses that CLI to log in, accept the EULA, download an SDK, and download
#      the devices referenced by a manifest.xml.
#
# The SDK download is gated behind a Garmin account + license agreement, so the
# login step is interactive (or set GARMIN_USERNAME / GARMIN_PASSWORD first).
#
# Usage:
#   ./setup-connectiq.sh [SDK_VERSION] [path/to/manifest.xml]
# Examples:
#   ./setup-connectiq.sh                       # latest SDK, ./manifest.xml if present
#   ./setup-connectiq.sh '^7.0.0' app/manifest.xml

set -euo pipefail

SDK_VERSION="${1:-}"                 # empty -> latest stable
MANIFEST="${2:-manifest.xml}"
KEY_DIR="${CONNECTIQ_KEY_DIR:-$HOME/.connectiq}"
KEY_PEM="$KEY_DIR/developer_key.pem"
KEY_DER="$KEY_DIR/developer_key.der"

CLI="connect-iq-sdk-manager-cli"
GOBIN="$(go env GOBIN)"; [ -n "$GOBIN" ] || GOBIN="$(go env GOPATH)/bin"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Developer key (RSA 4096, PKCS#8 DER) — fully offline.
# ---------------------------------------------------------------------------
log "Developer key"
if [ -f "$KEY_DER" ]; then
  echo "Already present: $KEY_DER"
else
  mkdir -p "$KEY_DIR"; chmod 700 "$KEY_DIR"
  openssl genrsa -out "$KEY_PEM" 4096
  openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt \
    -in "$KEY_PEM" -out "$KEY_DER"
  chmod 600 "$KEY_PEM" "$KEY_DER"
  echo "Created $KEY_DER  (pass to monkeyc with -y)"
fi

# ---------------------------------------------------------------------------
# 2. Install the open-source SDK manager CLI.
# ---------------------------------------------------------------------------
log "SDK manager CLI"
if command -v "$CLI" >/dev/null 2>&1; then
  echo "Already on PATH: $(command -v "$CLI")"
else
  echo "Installing via 'go install'..."
  go install github.com/lindell/connect-iq-sdk-manager-cli@latest
  CLI="$GOBIN/$CLI"
  echo "Installed: $CLI"
  case ":$PATH:" in
    *":$GOBIN:"*) ;;
    *) echo "NOTE: add $GOBIN to PATH to call '$(basename "$CLI")' directly." ;;
  esac
fi

# ---------------------------------------------------------------------------
# 3. Login, accept EULA, fetch SDK + devices.
# ---------------------------------------------------------------------------
log "Garmin login (interactive unless GARMIN_USERNAME/PASSWORD are set)"
"$CLI" login

log "Accepting SDK license agreement"
"$CLI" agreement accept

log "Downloading + activating SDK ${SDK_VERSION:-(latest)}"
if [ -n "$SDK_VERSION" ]; then
  "$CLI" sdk set "$SDK_VERSION"
else
  "$CLI" sdk set ">=0.0.0"   # newest available
fi

log "Downloading devices"
if [ -f "$MANIFEST" ]; then
  "$CLI" device download --manifest "$MANIFEST" --include-fonts
else
  echo "No manifest at '$MANIFEST' — skipping device download."
  echo "Re-run with: $0 \"$SDK_VERSION\" path/to/manifest.xml"
fi

# ---------------------------------------------------------------------------
# Done — print how to use it.
# ---------------------------------------------------------------------------
SDK_BIN="$("$CLI" sdk current-path --bin)"
cat <<EOF

$(log "Setup complete")
Add the SDK tools to your PATH (e.g. in ~/.bashrc):

    export PATH="$SDK_BIN:$GOBIN:\$PATH"

Then build / simulate:

    monkeyc -d <device> -f moonkey.jungle -o app.prg -y "$KEY_DER"
    monkeydo app.prg <device>

Developer key: $KEY_DER
SDK bin:       $SDK_BIN
EOF
