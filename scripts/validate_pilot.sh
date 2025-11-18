#!/bin/bash
# Hudson Pilot - Final Validation Script
# Runs all automated tests and generates a report

set -e
cd "$(dirname "$0")/.."

echo "╔════════════════════════════════════════════════════════╗"
echo "║     Hudson Desktop Pilot - Final Validation           ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0

test_result() {
    if [ $? -eq 0 ]; then
        echo "   ✓ $1"
        ((PASS++))
    else
        echo "   ✗ $1"
        ((FAIL++))
    fi
}

# Cleanup
pkill -f hudson 2>/dev/null || true
sleep 1

echo "📦 1. BUNDLE VALIDATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

APP_BUNDLE="./src-tauri/target/release/bundle/macos/Hudson.app"
[ -x "$APP_BUNDLE/Contents/MacOS/hudson_desktop" ]
test_result "Rust executable present"

[ -x "$APP_BUNDLE/Contents/Resources/binaries/hudson_macos_arm-aarch64-apple-darwin" ]
test_result "BEAM sidecar present"

[ -f "$APP_BUNDLE/Contents/Info.plist" ]
test_result "Info.plist present"

file "$APP_BUNDLE/Contents/MacOS/hudson_desktop" | grep -q "Mach-O.*arm64"
test_result "Rust binary is ARM64"

file "$APP_BUNDLE/Contents/Resources/binaries/hudson_macos_arm-aarch64-apple-darwin" | grep -q "Mach-O.*arm64"
test_result "BEAM binary is ARM64"

echo ""
echo "🚀 2. BASIC LAUNCH TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -f /tmp/hudson_port.json /tmp/test_launch.log
"$APP_BUNDLE/Contents/MacOS/hudson_desktop" > /tmp/test_launch.log 2>&1 &
TEST_PID=$!
sleep 5

[ -f /tmp/hudson_port.json ]
test_result "Port handshake file created"

if [ -f /tmp/hudson_port.json ]; then
    PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)
    [ -n "$PORT" ]
    test_result "Port number extracted: $PORT"

    HEALTH=$(curl -s http://127.0.0.1:$PORT/healthz 2>/dev/null || echo "")
    echo "$HEALTH" | grep -q '"status"'
    test_result "Health endpoint responding"

    echo "$HEALTH" | grep -q '"timestamp"'
    test_result "Health JSON format valid"
fi

kill $TEST_PID 2>/dev/null || true
pkill -f hudson 2>/dev/null || true
sleep 1

[ -z "$(pgrep -f hudson)" ]
test_result "Processes cleaned up after shutdown"

echo ""
echo "🔌 3. OFFLINE MODE TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -f /tmp/hudson_port.json /tmp/test_offline.log
export HUDSON_ENABLE_NEON=false
"$APP_BUNDLE/Contents/MacOS/hudson_desktop" > /tmp/test_offline.log 2>&1 &
TEST_PID=$!
sleep 6

grep -q "🔌.*skipping Hudson.Repo" /tmp/test_offline.log
test_result "Neon Repo skipped in offline mode"

grep -q "🔌.*skipping Oban" /tmp/test_offline.log
test_result "Oban skipped in offline mode"

! grep -q "Postgrex.*disconnect\|FATAL.*admin_shutdown" /tmp/test_offline.log
test_result "No Postgres connection attempts"

grep -q "Running local SQLite migrations" /tmp/test_offline.log
test_result "SQLite migrations ran"

kill $TEST_PID 2>/dev/null || true
pkill -f hudson 2>/dev/null || true
unset HUDSON_ENABLE_NEON
sleep 1

echo ""
echo "🔧 4. REBUILD WORKFLOW TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

./scripts/make_app_bundle.sh > /tmp/rebuild_test.log 2>&1
test_result "Bundle rebuild script runs successfully"

[ -x "$APP_BUNDLE/Contents/MacOS/hudson_desktop" ]
test_result "Executable still valid after rebuild"

echo ""
echo "🧪 5. NIF VALIDATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -f /tmp/nif_test.log
./burrito_out/hudson_macos_arm > /tmp/nif_test.log 2>&1 &
TEST_PID=$!
sleep 5

grep -q "Pilot NIF smoke checks passed.*bcrypt_elixir.*lazy_html" /tmp/nif_test.log
test_result "bcrypt_elixir and lazy_html NIFs load"

kill $TEST_PID 2>/dev/null || true
pkill -f hudson 2>/dev/null || true
sleep 1

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║                    RESULTS SUMMARY                     ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "   ✓ Tests Passed: $PASS"
echo "   ✗ Tests Failed: $FAIL"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "   🎉 All tests PASSED! Pilot is ready for manual testing."
    echo ""
    echo "   Next step: Launch the app and test the UI"
    echo "   → ./run_native.sh"
    exit 0
else
    echo "   ⚠️  Some tests failed. Review logs in /tmp/test_*.log"
    exit 1
fi
