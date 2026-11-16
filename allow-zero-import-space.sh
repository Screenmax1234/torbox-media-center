#!/usr/bin/env bash
# Disable the Radarr/Sonarr import free-space floor without changing media paths.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-$SCRIPT_DIR/torbox-media-server}}"
ENV_FILE="$INSTALL_DIR/.env"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo 'Usage: bash allow-zero-import-space.sh [INSTALL_DIR]'
    echo 'Sets Radarr and Sonarr minimumFreeSpaceWhenImporting to 0 MB.'
    echo 'This does not move media or change the zero-local-media-storage paths.'
    exit 0
fi

[[ -f "$ENV_FILE" ]] || { echo "[ERROR] No .env found at $ENV_FILE" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo '[ERROR] curl is required.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo '[ERROR] jq is required.' >&2; exit 1; }

env_val() {
    local key="$1"
    grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- |
        sed 's/[[:space:]]#.*$//' | tr -d '"' | tr -d "'" | tr -d '\r' |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

updated=0
for service in radarr sonarr; do
    if [[ "$service" == radarr ]]; then
        port=7878; key_name=RADARR_API_KEY; label=Radarr
    else
        port=8989; key_name=SONARR_API_KEY; label=Sonarr
    fi
    api_key="$(env_val "$key_name")"
    if [[ -z "$api_key" ]]; then
        echo "[WARN] Skipping ${label}: API key is missing from .env."
        continue
    fi
    config="$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" \
        "http://localhost:${port}/api/v3/config/mediamanagement" 2>/dev/null)" || true
    if [[ -z "$config" ]]; then
        echo "[WARN] Skipping ${label}: service is not reachable on port ${port}."
        continue
    fi
    config_id="$(jq -r '.id // empty' <<<"$config")"
    updated_config="$(jq '.minimumFreeSpaceWhenImporting = 0' <<<"$config")"
    if [[ -z "$config_id" || -z "$updated_config" ]]; then
        echo "[WARN] Skipping ${label}: media-management settings could not be read."
        continue
    fi
    if curl -sf --connect-timeout 5 --max-time 15 -X PUT \
        -H 'Content-Type: application/json' -H "X-Api-Key: ${api_key}" \
        "http://localhost:${port}/api/v3/config/mediamanagement/${config_id}" \
        -d "$updated_config" -o /dev/null; then
        echo "[OK] ${label}: import free-space floor set to 0 MB."
        updated=$((updated + 1))
    else
        echo "[WARN] ${label}: update failed." >&2
    fi
done

if ((updated == 0)); then
    echo '[ERROR] No service was updated. Start Radarr/Sonarr and retry.' >&2
    exit 1
fi
echo '[OK] No media paths or local-storage settings were changed.'
