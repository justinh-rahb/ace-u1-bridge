#!/usr/bin/env bash
# install.sh — Set up ace-u1-bridge on the Klipper host
#
# This script:
#   1. Validates that Klipper and klippy-env exist
#   2. Symlinks the ACEPRO ace extra into Klipper's extras directory
#   3. Symlinks the virtual_pins extra (required by ACE driver)
#   4. Optionally installs systemd services for the ACE instance and router
#
# Usage:
#   ./scripts/install.sh [--services]
#
# Options:
#   --services    Also install and enable systemd services

set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults — override with environment variables if your layout differs
KLIPPER_DIR="${KLIPPER_DIR:-$HOME/klipper}"
KLIPPY_ENV="${KLIPPY_ENV:-$HOME/klippy-env}"
KLIPPER_EXTRAS="${KLIPPER_DIR}/klippy/extras"

ACEPRO_DIR="${BRIDGE_DIR}/upstream/ACEPRO"
ROUTER_DIR="${BRIDGE_DIR}/upstream/klipper-router"

INSTALL_SERVICES=false

# ─── Parse args ───────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --services) INSTALL_SERVICES=true ;;
        --help|-h)
            echo "Usage: $0 [--services]"
            echo ""
            echo "Sets up ace-u1-bridge by symlinking ACE extras into Klipper."
            echo ""
            echo "Options:"
            echo "  --services    Install and enable systemd services"
            echo ""
            echo "Environment variables:"
            echo "  KLIPPER_DIR   Path to klipper checkout (default: ~/klipper)"
            echo "  KLIPPY_ENV    Path to klippy virtualenv (default: ~/klippy-env)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            exit 1
            ;;
    esac
done

# ─── Preflight checks ────────────────────────────────────────────────────────
echo "=== ace-u1-bridge installer ==="
echo ""

errors=0

if [ ! -d "$KLIPPER_DIR" ]; then
    echo "ERROR: Klipper not found at $KLIPPER_DIR"
    echo "       Set KLIPPER_DIR to your klipper checkout path"
    errors=$((errors + 1))
fi

if [ ! -d "$KLIPPY_ENV" ]; then
    echo "ERROR: klippy-env not found at $KLIPPY_ENV"
    echo "       Set KLIPPY_ENV to your klippy virtualenv path"
    errors=$((errors + 1))
fi

if [ ! -d "$KLIPPER_EXTRAS" ]; then
    echo "ERROR: Klipper extras directory not found at $KLIPPER_EXTRAS"
    errors=$((errors + 1))
fi

if [ ! -d "$ACEPRO_DIR/extras/ace" ]; then
    echo "ERROR: ACEPRO submodule not initialized"
    echo "       Run: git submodule update --init --recursive"
    errors=$((errors + 1))
fi

if [ ! -f "$ROUTER_DIR/src/klipper_router.py" ]; then
    echo "ERROR: klipper-router submodule not initialized"
    echo "       Run: git submodule update --init --recursive"
    errors=$((errors + 1))
fi

if [ $errors -gt 0 ]; then
    echo ""
    echo "Fix the above errors and re-run."
    exit 1
fi

echo "Klipper:        $KLIPPER_DIR"
echo "klippy-env:     $KLIPPY_ENV"
echo "ACEPRO:         $ACEPRO_DIR"
echo "klipper-router: $ROUTER_DIR"
echo "Bridge:         $BRIDGE_DIR"
echo ""

# ─── Symlink ACE extras ──────────────────────────────────────────────────────
echo "--- Symlinking ACE extras into Klipper ---"

# ace package (directory)
if [ -L "$KLIPPER_EXTRAS/ace" ]; then
    echo "  ace/ symlink already exists, updating..."
    rm "$KLIPPER_EXTRAS/ace"
elif [ -d "$KLIPPER_EXTRAS/ace" ]; then
    echo "  WARNING: $KLIPPER_EXTRAS/ace is a directory, not a symlink."
    echo "  Skipping — remove it manually if you want this script to manage it."
    echo ""
else
    echo "  Creating ace/ symlink..."
fi

if [ ! -e "$KLIPPER_EXTRAS/ace" ]; then
    ln -sf "$ACEPRO_DIR/extras/ace" "$KLIPPER_EXTRAS/ace"
    echo "  -> $KLIPPER_EXTRAS/ace -> $ACEPRO_DIR/extras/ace"
fi

# virtual_pins module
if [ -L "$KLIPPER_EXTRAS/virtual_pins.py" ] || [ ! -e "$KLIPPER_EXTRAS/virtual_pins.py" ]; then
    ln -sf "$ACEPRO_DIR/extras/virtual_pins.py" "$KLIPPER_EXTRAS/virtual_pins.py"
    echo "  -> $KLIPPER_EXTRAS/virtual_pins.py -> $ACEPRO_DIR/extras/virtual_pins.py"
else
    echo "  virtual_pins.py already exists (not a symlink), skipping"
fi

echo ""

# ─── Install systemd services ────────────────────────────────────────────────
if [ "$INSTALL_SERVICES" = true ]; then
    echo "--- Installing systemd services ---"

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo &>/dev/null; then
        echo "ERROR: Need root or sudo to install systemd services"
        exit 1
    fi

    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        SUDO="sudo"
    fi

    # Generate service files with correct paths
    for svc in klipper-ace klipper-router; do
        SVC_SRC="$BRIDGE_DIR/systemd/${svc}.service"
        SVC_DST="/etc/systemd/system/${svc}.service"

        if [ ! -f "$SVC_SRC" ]; then
            echo "  WARNING: $SVC_SRC not found, skipping"
            continue
        fi

        echo "  Installing $svc.service..."

        # Substitute paths in the service file
        $SUDO sed \
            -e "s|%KLIPPER_DIR%|$KLIPPER_DIR|g" \
            -e "s|%KLIPPY_ENV%|$KLIPPY_ENV|g" \
            -e "s|%BRIDGE_DIR%|$BRIDGE_DIR|g" \
            -e "s|%ROUTER_DIR%|$ROUTER_DIR|g" \
            -e "s|%USER%|$(whoami)|g" \
            "$SVC_SRC" > /tmp/${svc}.service.tmp

        $SUDO mv /tmp/${svc}.service.tmp "$SVC_DST"
        $SUDO chmod 644 "$SVC_DST"
        echo "  -> $SVC_DST"
    done

    $SUDO systemctl daemon-reload
    echo ""
    echo "  Services installed. Enable with:"
    echo "    sudo systemctl enable --now klipper-ace"
    echo "    sudo systemctl enable --now klipper-router"
else
    echo "Skipping systemd services (use --services to install)"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Find your ACE Pro USB serial path:  ls /dev/serial/by-id/"
echo "  2. Edit config/klipper-ace/ace_instance.cfg — set serial_0"
echo "  3. Follow docs/COMMISSIONING.md from Phase 2"
