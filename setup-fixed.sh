#!/usr/bin/env bash
set -euo pipefail

# Reliable entry point for the TorBox Media Server installer.
# Normal arguments are passed to the maintained installer.  --repair refreshes
# deployment files in an existing install without touching its credentials or
# media data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    --add-silo)
        shift
        exec bash "${SCRIPT_DIR}/add-silo.sh" "${1:-${TORBOX_INSTALL_DIR:-$SCRIPT_DIR/torbox-media-server}}"
        ;;
    --repair)
        shift
        # Invoke through Bash so repairs also work when a checkout was created
        # on a filesystem that stripped executable permission bits.
        exec bash "${SCRIPT_DIR}/repair-install.sh" "${1:-}"
        ;;
    --help|-h)
        echo "Usage: ./setup-fixed.sh [setup.sh options]"
        echo "       ./setup-fixed.sh --repair [INSTALL_DIR]"
        echo "       bash setup-fixed.sh --add-silo [INSTALL_DIR]"
        echo "       ./setup-fixed.sh --refresh-management"
        echo ""
        echo "The normal path runs setup.sh with the local Decypharr build fix."
        echo "--repair updates an existing install and rebuilds Decypharr."
        ;;
    *)
        exec bash "${SCRIPT_DIR}/setup.sh" "$@"
        ;;
esac
