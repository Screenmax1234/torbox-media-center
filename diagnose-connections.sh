#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/seerr.sh"

repair=false
case "${1:-}" in
    --repair) repair=true ;;
    '') ;;
    *)
        echo 'Usage: bash diagnose-connections.sh [--repair]'
        exit 1
        ;;
esac
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
# Resolve relative Compose bind paths against the installation directory.
[[ "$CONFIG_DIR" == /* ]] || CONFIG_DIR="${INSTALL_DIR}/${CONFIG_DIR}"
failed=0
declare -A keys

echo 'Connection checks (credentials and raw API responses are hidden)'
echo 'Run on the Docker host. Default mode reads settings and tests connections.'
for service in radarr sonarr prowlarr; do
    port=7878 version=v3
    [[ "$service" == sonarr ]] && port=8989
    [[ "$service" == prowlarr ]] && port=9696 && version=v1
    key=$(env_val "${service^^}_API_KEY" || true)
    file_key=''
    if [[ -f "${CONFIG_DIR}/${service}/config.xml" ]]; then
        file_key=$(sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "${CONFIG_DIR}/${service}/config.xml" | tr -d '\r')
    fi
    if [[ -n "$file_key" && "$file_key" != "$key" ]]; then
        echo "[WARN] ${service}: .env and config.xml API keys differ."
    fi
    if [[ -n "$key" ]] && curl -sf --connect-timeout 3 --max-time 10 -H "X-Api-Key: ${key}" \
        "http://localhost:${port}/api/${version}/system/status" -o /dev/null 2>/dev/null; then
        keys[$service]="$key"
        echo "[OK] ${service}: live API accepts the .env key."
    elif [[ -n "$file_key" ]] && curl -sf --connect-timeout 3 --max-time 10 -H "X-Api-Key: ${file_key}" \
        "http://localhost:${port}/api/${version}/system/status" -o /dev/null 2>/dev/null; then
        keys[$service]="$file_key"
        echo "[WARN] ${service}: only the config.xml key works; using it for this run."
    else
        echo "[FAIL] ${service}: no stored key could reach its live API. Check status/logs and API key."
        failed=1
    fi
done

if [[ -n "${keys[prowlarr]:-}" ]]; then
    proxy=$(curl -sf --connect-timeout 3 --max-time 10 -H "X-Api-Key: ${keys[prowlarr]}" \
        http://localhost:9696/api/v1/config/host 2>/dev/null) || proxy=''
    if [[ -z "$proxy" ]]; then
        echo '[FAIL] Could not inspect Prowlarr global proxy settings.'
        failed=1
    elif jq -e '.proxyEnabled == true' <<<"$proxy" >/dev/null; then
        echo '[WARN] Prowlarr has a global HTTP/SOCKS proxy enabled.'
        if jq -e '(.proxyPort | tostring) == "8191"' <<<"$proxy" >/dev/null; then
            echo '[FAIL] Port 8191 is Byparr, which cannot act as a global HTTP/SOCKS proxy.'
            echo '       Disable Settings -> General -> Proxy. Use Indexers -> Indexer Proxies -> FlareSolverr, http://byparr:8191.'
            failed=1
        fi
    else
        echo '[OK] Prowlarr global HTTP/SOCKS proxy is disabled.'
    fi
fi

if seerr_connect http://localhost:5055 "$CONFIG_DIR"; then
    for service in radarr sonarr; do
        if [[ -z "${keys[$service]:-}" ]]; then
            echo "[FAIL] Skipping Seerr -> ${service}: no verified API key."
            failed=1
            continue
        fi
        # Back up the existing API object privately before an authenticated PUT.
        if [[ "$repair" == true ]]; then
            if [[ -z "${backup_dir:-}" ]]; then
                backup_dir=$(
                    umask 077
                    mktemp -d "${INSTALL_DIR}/connection-backup-XXXXXXXX"
                )
                echo "[INFO] Private Seerr settings backup: ${backup_dir}"
            fi
            if ! (
                umask 077
                seerr_request GET "/api/v1/settings/${service}" >"${backup_dir}/${service}.json"
            ); then
                echo "[FAIL] Cannot back up Seerr ${service} settings; skipping repair."
                failed=1
                continue
            fi
        fi
        seerr_sync_arr "$service" "${keys[$service]}" "$repair" || failed=1
    done
else
    failed=1
fi

if curl -sf --connect-timeout 3 --max-time 10 http://localhost:8282/ -o /dev/null 2>/dev/null; then
    echo '[OK] Decypharr web endpoint responds. This does not test TorBox download submission.'
else
    echo '[FAIL] Decypharr web endpoint failed or requires authentication; check its status/logs.'
    failed=1
fi
if [[ -f "${CONFIG_DIR}/decypharr/config.json" ]] &&
    jq -e 'any(.debrids[]?; .name == "torbox" and .rate_limit == "55/hour")' \
        "${CONFIG_DIR}/decypharr/config.json" >/dev/null 2>&1; then
    echo '[WARN] Legacy TorBox rate limit is 55/hour: requests may wait about 65 seconds each.'
    if [[ "$repair" == true ]]; then
        config="${CONFIG_DIR}/decypharr/config.json"
        backup=$(mktemp "${config}.before-rate-fix-XXXXXXXX")
        cp -p "$config" "$backup"
        chmod 600 "$backup"
        temp=$(mktemp "${config}.tmp.XXXXXXXX")
        if jq '(.debrids[] | select(.name == "torbox" and .rate_limit == "55/hour")).rate_limit = "250/minute"' \
            "$config" >"$temp" && chmod --reference="$config" "$temp" && chown --reference="$config" "$temp"; then
            mv "$temp" "$config"
            echo "[OK] Updated legacy rate limit to 250/minute. Backup: ${backup}"
            echo '[ACTION] Restart Decypharr to apply: docker compose restart decypharr (from the install directory).'
        else
            rm -f "$temp"
            echo '[FAIL] Could not update Decypharr rate limit; original retained.'
            failed=1
        fi
    else
        echo '       --repair migrates this legacy value to 250/minute; custom limits are preserved.'
    fi
fi
echo '[INFO] No torrents were submitted, keys rotated, or containers restarted.'
exit "$failed"
