#!/bin/bash
# Hudson Pilot Automated Test Suite
# Tests all aspects that don't require GUI interaction

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

log_test() {
    echo -e "\n${YELLOW}▶ TEST: $1${NC}"
}

log_pass() {
    echo -e "${GREEN}✓ PASS: $1${NC}"
    ((TESTS_PASSED++))
}

log_fail() {
    echo -e "${RED}✗ FAIL: $1${NC}"
    ((TESTS_FAILED++))
}

cleanup() {
    echo -e "\n${YELLOW}Cleaning up test processes...${NC}"
    pkill -f hudson 2>/dev/null || true
    rm -f /tmp/hudson_port.json
    sleep 1
}

trap cleanup EXIT

echo "============================================"
echo "Hudson Pilot - Automated Test Suite"
echo "============================================"

# Test 1: Bundle structure validation
log_test "Bundle structure validation"
APP_BUNDLE="$REPO_ROOT/src-tauri/target/release/bundle/macos/Hudson.app"
if [ -d "$APP_BUNDLE" ]; then
    if [ -x "$APP_BUNDLE/Contents/MacOS/hudson_desktop" ] && \
       [ -f "$APP_BUNDLE/Contents/Info.plist" ] && \
       [ -x "$APP_BUNDLE/Contents/Resources/binaries/hudson_macos_arm-aarch64-apple-darwin" ]; then
        log_pass "Bundle structure complete"
    else
        log_fail "Bundle missing required files"
    fi
else
    log_fail "Bundle directory not found"
fi

# Test 2: Binary validation
log_test "Binary validation"
RUST_BIN="$APP_BUNDLE/Contents/MacOS/hudson_desktop"
BEAM_BIN="$APP_BUNDLE/Contents/Resources/binaries/hudson_macos_arm-aarch64-apple-darwin"

if file "$RUST_BIN" | grep -q "Mach-O.*arm64"; then
    log_pass "Rust binary is valid ARM64 executable"
else
    log_fail "Rust binary is not valid"
fi

if file "$BEAM_BIN" | grep -q "Mach-O.*arm64"; then
    log_pass "BEAM binary is valid ARM64 executable"
else
    log_fail "BEAM binary is not valid"
fi

# Test 3: Basic launch and health check
log_test "Basic launch and health check"
cleanup
rm -f /tmp/hudson_test_basic.log

"$RUST_BIN" > /tmp/hudson_test_basic.log 2>&1 &
APP_PID=$!
sleep 3

if [ -f /tmp/hudson_port.json ]; then
    log_pass "Port handshake file created"
    PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)

    if [ -n "$PORT" ]; then
        log_pass "Port extracted from handshake: $PORT"

        # Test health endpoint
        sleep 2
        HEALTH_RESPONSE=$(curl -s http://127.0.0.1:$PORT/healthz || echo "")
        if echo "$HEALTH_RESPONSE" | grep -q "status"; then
            log_pass "Health endpoint responding"
        else
            log_fail "Health endpoint not responding"
        fi
    else
        log_fail "Could not extract port from handshake"
    fi
else
    log_fail "Port handshake file not created"
fi

kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
cleanup

# Test 4: Offline mode (HUDSON_ENABLE_NEON=false)
log_test "Offline mode launch"
cleanup
rm -f /tmp/hudson_test_offline.log

HUDSON_ENABLE_NEON=false "$RUST_BIN" > /tmp/hudson_test_offline.log 2>&1 &
APP_PID=$!
sleep 3

if [ -f /tmp/hudson_port.json ]; then
    log_pass "Offline mode launched successfully"
    PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)

    sleep 2
    HEALTH_RESPONSE=$(curl -s http://127.0.0.1:$PORT/healthz || echo "")
    if echo "$HEALTH_RESPONSE" | grep -q "status"; then
        log_pass "Offline mode health check passed"
    else
        log_fail "Offline mode health check failed"
    fi

    # Check logs for expected warnings
    if grep -q "HUDSON_ENABLE_NEON=false" /tmp/hudson_test_offline.log; then
        log_pass "Offline mode logs show Neon disabled"
    else
        log_fail "Offline mode logs missing expected warnings"
    fi
else
    log_fail "Offline mode failed to launch"
fi

kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
cleanup

# Test 5: Process cleanup verification
log_test "Process cleanup after shutdown"
cleanup
"$RUST_BIN" > /dev/null 2>&1 &
APP_PID=$!
sleep 3

BEAM_PIDS=$(pgrep -f hudson_macos_arm || echo "")
if [ -n "$BEAM_PIDS" ]; then
    log_pass "BEAM processes running during app lifecycle"

    # Kill main process
    kill $APP_PID 2>/dev/null || true
    sleep 2

    # Check if BEAM processes cleaned up
    REMAINING=$(pgrep -f hudson_macos_arm || echo "")
    if [ -z "$REMAINING" ]; then
        log_pass "BEAM processes cleaned up after shutdown"
    else
        log_fail "BEAM processes still running after shutdown"
        pkill -f hudson 2>/dev/null || true
    fi
else
    log_fail "No BEAM processes found during launch"
fi

cleanup

# Test 6: Handshake file recreation
log_test "Handshake file recreation"
cleanup
"$RUST_BIN" > /dev/null 2>&1 &
APP_PID=$!
sleep 3

if [ -f /tmp/hudson_port.json ]; then
    ORIGINAL_PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)
    log_pass "Initial handshake created with port $ORIGINAL_PORT"

    # Delete handshake and restart
    kill $APP_PID 2>/dev/null || true
    wait $APP_PID 2>/dev/null || true
    pkill -f hudson 2>/dev/null || true
    sleep 1

    rm -f /tmp/hudson_port.json
    "$RUST_BIN" > /dev/null 2>&1 &
    APP_PID=$!
    sleep 3

    if [ -f /tmp/hudson_port.json ]; then
        NEW_PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)
        log_pass "Handshake recreated with port $NEW_PORT"

        if [ "$ORIGINAL_PORT" != "$NEW_PORT" ]; then
            log_pass "Port changed on restart (ephemeral ports working)"
        fi
    else
        log_fail "Handshake not recreated"
    fi

    kill $APP_PID 2>/dev/null || true
    wait $APP_PID 2>/dev/null || true
else
    log_fail "Initial handshake not created"
fi

cleanup

# Test 7: SQLite migrations
log_test "SQLite auto-migrations"
cleanup

# Launch and check for migration logs
"$RUST_BIN" > /tmp/hudson_test_sqlite.log 2>&1 &
APP_PID=$!
sleep 3

if grep -qi "migration" /tmp/hudson_test_sqlite.log || \
   grep -qi "local.*repo" /tmp/hudson_test_sqlite.log; then
    log_pass "SQLite migrations executed"
else
    # Migrations might have run before, check database exists
    if [ -f "$HOME/Library/Application Support/Hudson/local.db" ] || \
       [ -f "$REPO_ROOT/_build/prod/rel/hudson/tmp/local.db" ]; then
        log_pass "SQLite database exists"
    else
        log_fail "No evidence of SQLite migrations"
    fi
fi

kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
cleanup

# Test 8: Bundle rebuild workflow
log_test "Bundle rebuild workflow"
if [ -x ./scripts/make_app_bundle.sh ]; then
    if ./scripts/make_app_bundle.sh > /tmp/bundle_rebuild.log 2>&1; then
        log_pass "Bundle rebuild script executed successfully"

        if [ -x "$APP_BUNDLE/Contents/MacOS/hudson_desktop" ]; then
            log_pass "Bundle executable still valid after rebuild"
        else
            log_fail "Bundle executable invalid after rebuild"
        fi
    else
        log_fail "Bundle rebuild script failed"
        cat /tmp/bundle_rebuild.log
    fi
else
    log_fail "Bundle rebuild script not executable"
fi

# Test 9: Port uniqueness across launches
log_test "Ephemeral port allocation"
PORTS=()
for i in {1..3}; do
    cleanup
    "$RUST_BIN" > /dev/null 2>&1 &
    APP_PID=$!
    sleep 3

    if [ -f /tmp/hudson_port.json ]; then
        PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)
        PORTS+=($PORT)
    fi

    kill $APP_PID 2>/dev/null || true
    wait $APP_PID 2>/dev/null || true
done

UNIQUE_PORTS=$(printf '%s\n' "${PORTS[@]}" | sort -u | wc -l | tr -d ' ')
if [ "$UNIQUE_PORTS" -ge 2 ]; then
    log_pass "Multiple unique ephemeral ports allocated: ${PORTS[*]}"
else
    log_fail "Ports not properly randomized"
fi

cleanup

# Test 10: Health endpoint JSON format
log_test "Health endpoint JSON validation"
cleanup
"$RUST_BIN" > /dev/null 2>&1 &
APP_PID=$!
sleep 3

if [ -f /tmp/hudson_port.json ]; then
    PORT=$(cat /tmp/hudson_port.json | grep -o '"port":[0-9]*' | cut -d: -f2)
    sleep 2

    HEALTH_JSON=$(curl -s http://127.0.0.1:$PORT/healthz)

    # Check JSON is parseable and has expected fields
    if echo "$HEALTH_JSON" | grep -q '"status"' && \
       echo "$HEALTH_JSON" | grep -q '"timestamp"'; then
        log_pass "Health endpoint returns valid JSON"
    else
        log_fail "Health endpoint JSON malformed: $HEALTH_JSON"
    fi
fi

kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
cleanup

# Summary
echo ""
echo "============================================"
echo "Test Suite Complete"
echo "============================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
