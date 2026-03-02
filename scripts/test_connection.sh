#!/usr/bin/env bash
# test_connection.sh — Validate ace-u1-bridge connectivity
#
# Checks that the ACE Klipper instance, U1 Klipper instance, and
# klipper-router are all running and communicating.
#
# Usage:
#   ./scripts/test_connection.sh

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
U1_SOCK="${U1_SOCK:-/tmp/klippy_uds}"
ACE_SOCK="${ACE_SOCK:-/tmp/klippy_ace_uds}"
ACE_LOG="${ACE_LOG:-/tmp/klippy_ace.log}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass=0
fail=0
warn=0

check_pass() { echo -e "  ${GREEN}✓${NC} $1"; pass=$((pass + 1)); }
check_fail() { echo -e "  ${RED}✗${NC} $1"; fail=$((fail + 1)); }
check_warn() { echo -e "  ${YELLOW}!${NC} $1"; warn=$((warn + 1)); }

# ─── Socket checks ───────────────────────────────────────────────────────────
echo "=== Socket Checks ==="

if [ -S "$U1_SOCK" ]; then
    check_pass "U1 Klipper socket exists: $U1_SOCK"
else
    check_fail "U1 Klipper socket missing: $U1_SOCK"
fi

if [ -S "$ACE_SOCK" ]; then
    check_pass "ACE Klipper socket exists: $ACE_SOCK"
else
    check_fail "ACE Klipper socket missing: $ACE_SOCK"
fi

echo ""

# ─── Process checks ──────────────────────────────────────────────────────────
echo "=== Process Checks ==="

if pgrep -f "klippy.py.*printer.cfg" > /dev/null 2>&1; then
    check_pass "ACE Klipper process running"
else
    # Check with the ace-specific config path
    if pgrep -f "klippy.py.*klipper-ace" > /dev/null 2>&1; then
        check_pass "ACE Klipper process running"
    else
        check_fail "ACE Klipper process not found"
    fi
fi

if pgrep -f "klipper_router.py" > /dev/null 2>&1; then
    check_pass "Klipper Router process running"
else
    check_fail "Klipper Router process not found"
fi

echo ""

# ─── ACE log checks ──────────────────────────────────────────────────────────
echo "=== ACE Instance Log Checks ==="

if [ -f "$ACE_LOG" ]; then
    check_pass "ACE log file exists: $ACE_LOG"

    # Check for successful ACE connection
    if grep -q "ACE\[0\]" "$ACE_LOG" 2>/dev/null; then
        check_pass "ACE hardware connection logged"
    else
        check_warn "No ACE hardware connection in log (may not be plugged in)"
    fi

    # Check for router ready
    if grep -q "ace_events: registering event handlers" "$ACE_LOG" 2>/dev/null; then
        check_pass "Router event handlers registered on ACE side"
    else
        check_warn "Router event handlers not yet registered (router may not be running)"
    fi

    # Check for errors
    error_count=$(grep -c "^!!" "$ACE_LOG" 2>/dev/null || echo "0")
    if [ "$error_count" -gt 0 ]; then
        check_warn "Found $error_count error(s) in ACE log — check $ACE_LOG"
    else
        check_pass "No errors in ACE log"
    fi
else
    check_fail "ACE log file not found: $ACE_LOG"
fi

echo ""

# ─── USB device check ────────────────────────────────────────────────────────
echo "=== USB Device Check ==="

if [ -d "/dev/serial/by-id" ]; then
    ace_devs=$(ls /dev/serial/by-id/ 2>/dev/null | grep -i -E "anycubic|ace" || true)
    if [ -n "$ace_devs" ]; then
        check_pass "ACE Pro USB device found:"
        echo "         $ace_devs"
    else
        all_devs=$(ls /dev/serial/by-id/ 2>/dev/null || true)
        if [ -n "$all_devs" ]; then
            check_warn "No ACE-named USB device. Available serial devices:"
            echo "$all_devs" | while read -r dev; do echo "         $dev"; done
        else
            check_warn "No USB serial devices found in /dev/serial/by-id/"
        fi
    fi
else
    check_warn "/dev/serial/by-id/ does not exist (may not be Linux)"
fi

echo ""

# ─── Systemd service check ───────────────────────────────────────────────────
echo "=== Systemd Services ==="

for svc in klipper-ace klipper-router; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        case "$status" in
            active)  check_pass "$svc.service is active" ;;
            failed)  check_fail "$svc.service has failed" ;;
            *)       check_warn "$svc.service status: $status" ;;
        esac
    else
        check_warn "$svc.service not installed (optional — see scripts/install.sh --services)"
    fi
done

echo ""

# ─── Summary ──────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo -e "  ${GREEN}Passed:${NC}  $pass"
echo -e "  ${RED}Failed:${NC}  $fail"
echo -e "  ${YELLOW}Warnings:${NC} $warn"
echo ""

if [ $fail -gt 0 ]; then
    echo "Some checks failed. See docs/COMMISSIONING.md for setup instructions."
    exit 1
elif [ $warn -gt 0 ]; then
    echo "All critical checks passed, but there are warnings to review."
    exit 0
else
    echo "All checks passed."
    exit 0
fi
