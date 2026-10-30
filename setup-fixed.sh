#!/usr/bin/env bash
set -euo pipefail

# Reliable entry point for the TorBox Media Server installer.
# Normal arguments are passed to the maintained installer.  --repair refreshes
# deployment files in an existing install without touching its credentials or
# media data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    --repair)
        shift
        exec "${SCRIPT_DIR}/repair-install.sh" "${1:-}"
        ;;
    --help|-h)
        echo "Usage: ./setup-fixed.sh [setup.sh options]"
        echo "       ./setup-fixed.sh --repair [INSTALL_DIR]"
        echo "       ./setup-fixed.sh --refresh-management"
        echo ""
        echo "The normal path runs setup.sh with the local Decypharr build fix."
        echo "--repair updates an existing install and rebuilds Decypharr."
        ;;
    *)
        exec "${SCRIPT_DIR}/setup.sh" "$@"
        ;;
esac
