#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/plex.sh"
INSTALL_DIR="${TORBOX_INSTALL_DIR:-${SCRIPT_DIR}/torbox-media-server}"
ENV_FILE="${INSTALL_DIR}/.env"
[[ -f "$ENV_FILE" ]] || {
    echo '[FAIL] Install .env not found. Set TORBOX_INSTALL_DIR.'
    exit 1
}
for dependency in curl jq; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "[FAIL] Install ${dependency} first."
        exit 1
    }
done
CONFIG_DIR="$(env_val CONFIG_DIR || true)"
CONFIG_DIR="${CONFIG_DIR:-${INSTALL_DIR}/configs}"
[[ "$CONFIG_DIR" == /* ]] || CONFIG_DIR="${INSTALL_DIR}/${CONFIG_DIR}"
backup_dir=$(
    umask 077
    mktemp -d "${INSTALL_DIR}/connection-backup-XXXXXXXX"
)
echo "[INFO] Private notification settings backup: ${backup_dir}"
failed=0
for name in Radarr Sonarr; do
    service="${name,,}"
    port=7878
    [[ "$service" == sonarr ]] && port=8989
    url="http://localhost:${port}"
    key=$(env_val "${name^^}_API_KEY" || true)
    file_key=''
    if [[ -f "${CONFIG_DIR}/${service}/config.xml" ]]; then
        file_key=$(sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "${CONFIG_DIR}/${service}/config.xml" | tr -d '\r')
    fi
    verified=''
    for candidate in "$key" "$file_key"; do
        if [[ -n "$candidate" ]] && curl -sf --connect-timeout 3 --max-time 10 \
            -H "X-Api-Key: ${candidate}" "${url}/api/v3/system/status" -o /dev/null 2>/dev/null; then
            verified="$candidate"
            break
        fi
    done
    if [[ -z "$verified" ]]; then
        echo "[FAIL] ${name}: neither stored API key reached its live API."
        failed=1
        continue
    fi
    plex_sync_notification "$name" "$url" "$verified" "$CONFIG_DIR" "$backup_dir" || failed=1
done
echo '[INFO] Notifications affect future imports. Scan Plex manually once for items already imported.'
echo '[INFO] Downloads, TorBox settings and containers were not changed. No restart is required.'
exit "$failed"
