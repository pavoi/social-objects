#!/bin/bash
# Quick validation tests

set -e
cd "$(dirname "$0")/.."

echo "🧪 Running quick validation tests..."
echo ""

# Test 1: Offline mode
echo "TEST 1: Offline Mode Launch"
rm -f /tmp/hudson_port.json
export HUDSON_ENABLE_NEON=false

./src-tauri/target/release/bundle/macos/Hudson.app/Contents/MacOS/hudson_desktop > /tmp/test_offline.log 2>&1 &
PID=$!
sleep 5

if [ -f /tmp/hudson_port.json ]; then
    PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)
    echo "✓ Offline mode launched on port $PORT"

    # Test health endpoint
    if curl -s http://127.0.0.1:$PORT/healthz | grep -q "status"; then
        echo "✓ Health endpoint responding"
    fi

    # Check for offline warnings in logs
    if grep -q "HUDSON_ENABLE_NEON=false" /tmp/test_offline.log; then
        echo "✓ Neon disabled in logs"
    fi
else
    echo "✗ Offline mode failed"
    cat /tmp/test_offline.log
fi

kill $PID 2>/dev/null || true
pkill -f hudson || true
sleep 1

echo ""
echo "TEST 2: Normal Mode Launch"
rm -f /tmp/hudson_port.json
unset HUDSON_ENABLE_NEON

./src-tauri/target/release/bundle/macos/Hudson.app/Contents/MacOS/hudson_desktop > /tmp/test_normal.log 2>&1 &
PID=$!
sleep 5

if [ -f /tmp/hudson_port.json ]; then
    PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)
    echo "✓ Normal mode launched on port $PORT"

    # Test health endpoint
    HEALTH=$(curl -s http://127.0.0.1:$PORT/healthz)
    if echo "$HEALTH" | grep -q '"status".*"timestamp"'; then
        echo "✓ Health endpoint returns valid JSON"
    fi
else
    echo "✗ Normal mode failed"
    cat /tmp/test_normal.log | head -20
fi

kill $PID 2>/dev/null || true
pkill -f hudson || true
sleep 1

echo ""
echo "TEST 3: Process Cleanup"
if pgrep -f hudson > /dev/null; then
    echo "✗ Processes still running"
    pgrep -f hudson
else
    echo "✓ All processes cleaned up"
fi

echo ""
echo "TEST 4: Bundle Rebuild"
if ./scripts/make_app_bundle.sh > /tmp/rebuild.log 2>&1; then
    echo "✓ Bundle rebuilt successfully"
else
    echo "✗ Bundle rebuild failed"
    cat /tmp/rebuild.log
fi

echo ""
echo "✅ All quick tests complete"
