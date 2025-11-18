#!/bin/bash
# Hudson App Bundle Builder
# Manually assembles Hudson.app since cargo tauri build skips bundling
# Usage: ./scripts/make_app_bundle.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

echo "🔨 Building Hudson.app bundle..."

# Configuration
APP_NAME="Hudson"
BUNDLE_ID="com.hudson.app"
VERSION="0.1.0"
MIN_MACOS="11.0"

# Paths
TAURI_DIR="$REPO_ROOT/src-tauri"
BUNDLE_DIR="$TAURI_DIR/target/release/bundle/macos"
APP_BUNDLE="$BUNDLE_DIR/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BINARIES="$RESOURCES/binaries"

# Source binaries
RUST_BINARY_1="$TAURI_DIR/target/release/hudson_desktop"
RUST_BINARY_2="$TAURI_DIR/target/release/Hudson"
BURRITO_BINARY="$REPO_ROOT/burrito_out/hudson_macos_arm"
ICON="$TAURI_DIR/icons/icon.png"

# Find the Rust binary (could be hudson_desktop or Hudson)
RUST_BINARY=""
if [ -f "$RUST_BINARY_1" ]; then
  RUST_BINARY="$RUST_BINARY_1"
elif [ -f "$RUST_BINARY_2" ]; then
  RUST_BINARY="$RUST_BINARY_2"
fi

# Validate prerequisites
if [ -z "$RUST_BINARY" ]; then
  echo "❌ Error: Rust binary not found at $RUST_BINARY_1 or $RUST_BINARY_2"
  echo "   Run: cd src-tauri && cargo build --release"
  exit 1
fi
echo "✓ Found Rust binary: $RUST_BINARY"

if [ ! -f "$BURRITO_BINARY" ]; then
  echo "❌ Error: Burrito binary not found at $BURRITO_BINARY"
  echo "   Run: MIX_ENV=prod mix release"
  exit 1
fi

if [ ! -f "$ICON" ]; then
  echo "⚠️  Warning: Icon not found at $ICON (will skip)"
fi

# Clean and create bundle structure
echo "📁 Creating bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES" "$BINARIES"

# Copy executables
echo "📦 Copying executables..."
cp "$RUST_BINARY" "$MACOS/hudson_desktop"
chmod +x "$MACOS/hudson_desktop"

# Copy sidecar with Tauri's expected naming convention
SIDECAR_NAME="hudson_macos_arm-aarch64-apple-darwin"
cp "$BURRITO_BINARY" "$BINARIES/$SIDECAR_NAME"
chmod +x "$BINARIES/$SIDECAR_NAME"

# Copy icon if present
if [ -f "$ICON" ]; then
  cp "$ICON" "$RESOURCES/icon.png"
fi

# Generate Info.plist
echo "📝 Writing Info.plist..."
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>hudson_desktop</string>
  <key>CFBundleIconFile</key><string>icon.png</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.business</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Summary
echo ""
echo "✅ Bundle created successfully!"
echo "   Location: $APP_BUNDLE"
echo ""
echo "📊 Bundle Contents:"
ls -lh "$MACOS/"
echo ""
ls -lh "$BINARIES/"
echo ""

# Verify bundle is valid
if [ -x "$MACOS/hudson_desktop" ] && [ -x "$BINARIES/$SIDECAR_NAME" ]; then
  echo "✅ All executables are present and executable"
else
  echo "❌ Warning: Some executables may not be executable"
  exit 1
fi

# Test launch (optional)
if [ "$1" == "--test" ]; then
  echo ""
  echo "🧪 Testing launch..."
  rm -f /tmp/hudson_port.json
  "$APP_BUNDLE/Contents/MacOS/hudson_desktop" &
  PID=$!
  sleep 3
  if kill -0 "$PID" 2>/dev/null; then
    echo "✅ App launched successfully (PID: $PID)"
    kill "$PID"
    wait "$PID" 2>/dev/null || true
  else
    echo "❌ App failed to launch"
    exit 1
  fi
fi

echo ""
echo "🚀 Ready to launch with: ./run_native.sh"
