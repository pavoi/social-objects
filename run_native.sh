#!/bin/bash
# Hudson Native App Launcher
# Starts the Tauri-wrapped Hudson desktop app

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🚀 Launching Hudson native app..."

# Prefer the packaged app bundle if present
APP_BUNDLE="$SCRIPT_DIR/src-tauri/target/release/bundle/macos/Hudson.app/Contents/MacOS/Hudson"
APP_FALLBACK="$SCRIPT_DIR/src-tauri/target/release/Hudson"

# Set the backend binary path (Tauri also looks in app resources via externalBin)
export HUDSON_BACKEND_BIN="${HUDSON_BACKEND_BIN:-$SCRIPT_DIR/burrito_out/hudson_macos_arm}"

# Disable Neon for offline-first desktop mode (uses SQLite LocalRepo only)
export HUDSON_ENABLE_NEON="${HUDSON_ENABLE_NEON:-false}"

# Prepare the expected external bin name for Tauri bundling
if [ -f "$SCRIPT_DIR/burrito_out/hudson_macos_arm" ] && [ ! -e "$SCRIPT_DIR/burrito_out/hudson_macos_arm-aarch64-apple-darwin" ]; then
  ln -sf hudson_macos_arm "$SCRIPT_DIR/burrito_out/hudson_macos_arm-aarch64-apple-darwin"
fi

# Clean up old handshake file
rm -f /tmp/hudson_port.json

if [ -x "$APP_BUNDLE" ]; then
  echo "Using bundled app at $APP_BUNDLE"
  exec "$APP_BUNDLE"
fi

echo "Using fallback binary at $APP_FALLBACK"
exec "$APP_FALLBACK"
