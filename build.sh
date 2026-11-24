#!/bin/bash
# Builds Crate.app into build/. Usage: ./build.sh [run]
#   run   also launches the app afterwards (quitting a running copy first)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Crate.app"
SIDECAR="agent/build/crate-agent"

# --- Agent sidecar: the Cursor SDK compiled into one binary with Bun ---------
command -v bun >/dev/null || { echo "bun is required to build the agent sidecar: https://bun.sh" >&2; exit 1; }
if [ ! -d agent/node_modules/@cursor/sdk ]; then
    (cd agent && bun install)
fi
SDK_VERSION="$(sed -n 's/.*"version": "\(.*\)".*/\1/p' agent/node_modules/@cursor/sdk/package.json | head -1)"
(cd agent && bun build --compile src/main.ts --outfile build/crate-agent \
    --define "process.env.CRATE_SDK_VERSION=\"$SDK_VERSION\"" >/dev/null)

# --- App ---------------------------------------------------------------------
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Crate"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/agent/node_modules/@cursor"
cp "$BIN" "$APP/Contents/MacOS/Crate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # redraw with Scripts/make-icon.sh
echo -n "APPL????" > "$APP/Contents/PkgInfo"
cp "$SIDECAR" "$APP/Contents/Resources/agent/crate-agent"
# The SDK looks for its native helpers (ripgrep, sandbox) beside the executable.
ARCH_PACKAGE="agent/node_modules/@cursor/sdk-darwin-$(uname -m | sed 's/x86_64/x64/')"
[ -d "$ARCH_PACKAGE" ] && cp -R "$ARCH_PACKAGE" "$APP/Contents/Resources/agent/node_modules/@cursor/"

# Ad-hoc signature. macOS ties privacy permissions to the signature, so it may
# ask again for folder or Automation access after a rebuild.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed" >&2

touch "$APP"   # so Finder and the Dock pick up a changed icon
echo "Built $APP (Cursor SDK $SDK_VERSION)"
if [ "${1:-}" = "run" ]; then
    pkill -x Crate 2>/dev/null || true
    open "$APP"
else
    echo "Run with: open $APP"
fi
