#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Enable the optional Silo watch-history discovery scheduler on an existing
# installation.  This only writes its private settings/state and a scheduler;
# it does not recreate or restart the Docker Compose stack.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/env.sh"

dotenv_quote() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '"%s"' "$value"
}

usage() {
    cat <<'EOF'
Usage: bash add-silo-discovery.sh [INSTALL_DIR]

Adds an optional hourly Silo-watch-history -> Radarr discovery scheduler.
Defaults: up to 8 movies per hour and 192 per day.  Set environment variables
for unattended use; otherwise the script asks for the Silo-compatible account.
EOF
}

case "${1:-}" in --help|-h) usage; exit 0 ;; esac

INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-${SCRIPT_DIR}/torbox-media-server}}"
[[ -f "$INSTALL_DIR/.env" && -f "$INSTALL_DIR/docker-compose.yml" ]] || {
    echo "[ERROR] Pass an existing install directory containing .env and docker-compose.yml." >&2
    exit 1
}
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
[[ -f "$SCRIPT_DIR/silo-discovery.sh" ]] || { echo '[ERROR] silo-discovery.sh is missing from the repository.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo '[ERROR] jq is required.' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo '[ERROR] curl is required.' >&2; exit 1; }

profiles="$(env_val COMPOSE_PROFILES "$ENV_FILE" || true)"
if [[ ",$profiles," != *,silo,* && "$(env_val MEDIA_SERVER "$ENV_FILE" || true)" != silo ]]; then
    echo '[ERROR] Silo is not enabled in this installation. Enable Silo first, then rerun this command.' >&2
    exit 1
fi

if [[ "$INSTALL_DIR" == *[[:space:]]* ]]; then
    echo '[ERROR] The install path contains spaces; systemd/cron installation is intentionally refused.' >&2
    exit 1
fi

get_or_prompt() {
    local key="$1" prompt="$2" default="${3:-}" value
    value="${!key:-$(env_val "$key" "$ENV_FILE" || true)}"
    if [[ -z "$value" && -n "$default" ]]; then value="$default"; fi
    if [[ -z "$value" ]]; then
        read -r -p "$prompt" value
    fi
    printf '%s' "$value"
}

SILO_JF_PORT="$(env_val SILO_JF_PORT "$ENV_FILE" || true)"
SILO_JF_PORT="${SILO_JF_PORT:-8097}"
SILO_DISCOVERY_USER="$(get_or_prompt SILO_DISCOVERY_USER "Silo/Jellyfin-compatible username [$(env_val SILO_ADMIN_USER "$ENV_FILE" || echo admin)]: " "$(env_val SILO_ADMIN_USER "$ENV_FILE" || echo admin)")"
SILO_DISCOVERY_PASS="${SILO_DISCOVERY_PASS:-$(env_val SILO_DISCOVERY_PASS "$ENV_FILE" || true)}"
# Reusing the generated Silo administrator credentials is convenient for an
# unattended install; an explicitly supplied discovery password always wins.
SILO_DISCOVERY_PASS="${SILO_DISCOVERY_PASS:-$(env_val SILO_ADMIN_PASS "$ENV_FILE" || true)}"
if [[ -z "$SILO_DISCOVERY_PASS" ]]; then
    read -r -s -p 'Silo/Jellyfin-compatible password: ' SILO_DISCOVERY_PASS
    echo
fi
[[ -n "$SILO_DISCOVERY_USER" && -n "$SILO_DISCOVERY_PASS" ]] || { echo '[ERROR] A username and password are required.' >&2; exit 1; }

SILO_DISCOVERY_JF_URL="${SILO_DISCOVERY_JF_URL:-$(env_val SILO_DISCOVERY_JF_URL "$ENV_FILE" || true)}"
SILO_DISCOVERY_JF_URL="${SILO_DISCOVERY_JF_URL:-http://127.0.0.1:${SILO_JF_PORT}}"
SILO_DISCOVERY_RADARR_URL="${SILO_DISCOVERY_RADARR_URL:-$(env_val SILO_DISCOVERY_RADARR_URL "$ENV_FILE" || true)}"
SILO_DISCOVERY_RADARR_URL="${SILO_DISCOVERY_RADARR_URL:-http://127.0.0.1:7878}"
SILO_DISCOVERY_BATCH_SIZE="${SILO_DISCOVERY_BATCH_SIZE:-$(env_val SILO_DISCOVERY_BATCH_SIZE "$ENV_FILE" || true)}"
SILO_DISCOVERY_BATCH_SIZE="${SILO_DISCOVERY_BATCH_SIZE:-8}"
SILO_DISCOVERY_DAILY_LIMIT="${SILO_DISCOVERY_DAILY_LIMIT:-$(env_val SILO_DISCOVERY_DAILY_LIMIT "$ENV_FILE" || true)}"
SILO_DISCOVERY_DAILY_LIMIT="${SILO_DISCOVERY_DAILY_LIMIT:-192}"
SILO_DISCOVERY_LOOKBACK="${SILO_DISCOVERY_LOOKBACK:-$(env_val SILO_DISCOVERY_LOOKBACK "$ENV_FILE" || true)}"
SILO_DISCOVERY_LOOKBACK="${SILO_DISCOVERY_LOOKBACK:-20}"
SILO_DISCOVERY_QUALITY_PROFILE="${SILO_DISCOVERY_QUALITY_PROFILE:-$(env_val SILO_DISCOVERY_QUALITY_PROFILE "$ENV_FILE" || true)}"
SILO_DISCOVERY_QUALITY_PROFILE="${SILO_DISCOVERY_QUALITY_PROFILE:-Any}"
SILO_DISCOVERY_ROOT_FOLDER="${SILO_DISCOVERY_ROOT_FOLDER:-$(env_val SILO_DISCOVERY_ROOT_FOLDER "$ENV_FILE" || true)}"
SILO_DISCOVERY_ROOT_FOLDER="${SILO_DISCOVERY_ROOT_FOLDER:-/data/media/movies}"

[[ "$SILO_DISCOVERY_BATCH_SIZE" =~ ^[1-9][0-9]*$ && "$SILO_DISCOVERY_DAILY_LIMIT" =~ ^[1-9][0-9]*$ ]] || {
    echo '[ERROR] Batch and daily limits must be positive integers.' >&2; exit 1;
}
(( SILO_DISCOVERY_BATCH_SIZE <= SILO_DISCOVERY_DAILY_LIMIT )) || {
    echo '[ERROR] Batch size cannot exceed the daily limit.' >&2; exit 1;
}
[[ "$SILO_DISCOVERY_JF_URL" =~ ^https?://[^[:space:]]+$ && "$SILO_DISCOVERY_RADARR_URL" =~ ^https?://[^[:space:]]+$ ]] || {
    echo '[ERROR] Silo and Radarr URLs must start with http:// or https://.' >&2; exit 1;
}
[[ "$SILO_DISCOVERY_ROOT_FOLDER" == /* && "$SILO_DISCOVERY_ROOT_FOLDER" != *[[:space:]]* ]] || {
    echo '[ERROR] The Radarr root folder must be an absolute path without spaces.' >&2; exit 1;
}

tmp=$(mktemp "$ENV_FILE.discovery.XXXXXXXX")
sed -E '/^(SILO_DISCOVERY_ENABLED|SILO_DISCOVERY_USER|SILO_DISCOVERY_PASS|SILO_DISCOVERY_JF_URL|SILO_DISCOVERY_RADARR_URL|SILO_DISCOVERY_BATCH_SIZE|SILO_DISCOVERY_DAILY_LIMIT|SILO_DISCOVERY_LOOKBACK|SILO_DISCOVERY_QUALITY_PROFILE|SILO_DISCOVERY_ROOT_FOLDER)=/d' "$ENV_FILE" >"$tmp"
cat >>"$tmp" <<EOF

# Optional Silo watch-history discovery (credentials remain in this mode-600 file)
SILO_DISCOVERY_ENABLED="true"
EOF
printf 'SILO_DISCOVERY_USER=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_USER")" >>"$tmp"
printf 'SILO_DISCOVERY_PASS=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_PASS")" >>"$tmp"
printf 'SILO_DISCOVERY_JF_URL=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_JF_URL")" >>"$tmp"
printf 'SILO_DISCOVERY_RADARR_URL=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_RADARR_URL")" >>"$tmp"
printf 'SILO_DISCOVERY_BATCH_SIZE=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_BATCH_SIZE")" >>"$tmp"
printf 'SILO_DISCOVERY_DAILY_LIMIT=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_DAILY_LIMIT")" >>"$tmp"
printf 'SILO_DISCOVERY_LOOKBACK=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_LOOKBACK")" >>"$tmp"
printf 'SILO_DISCOVERY_QUALITY_PROFILE=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_QUALITY_PROFILE")" >>"$tmp"
printf 'SILO_DISCOVERY_ROOT_FOLDER=%s\n' "$(dotenv_quote "$SILO_DISCOVERY_ROOT_FOLDER")" >>"$tmp"
mv "$tmp" "$ENV_FILE"
chmod 600 "$ENV_FILE"
cp "$SCRIPT_DIR/silo-discovery.sh" "$INSTALL_DIR/silo-discovery.sh"
chmod 700 "$INSTALL_DIR/silo-discovery.sh"
mkdir -p "$INSTALL_DIR/configs/silo-discovery"
chmod 700 "$INSTALL_DIR/configs/silo-discovery"

# Install a persistent hourly scheduler when this is a normal systemd LXC.
if [[ -d /run/systemd/system && "${EUID}" -eq 0 && -x "$(command -v systemctl)" ]]; then
    service_file=/etc/systemd/system/torbox-silo-discovery.service
    timer_file=/etc/systemd/system/torbox-silo-discovery.timer
    cat >"$service_file" <<EOF
[Unit]
Description=TorBox Silo watch-history discovery
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
ExecStart=/bin/bash $INSTALL_DIR/silo-discovery.sh once
EOF
    cat >"$timer_file" <<EOF
[Unit]
Description=Run TorBox Silo discovery hourly

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    if systemctl enable --now torbox-silo-discovery.timer; then
        echo '[INFO] Hourly systemd timer enabled (up to 8 movies/hour, 192/day).'
    else
        echo '[WARN] Could not enable the systemd timer. The settings were saved.' >&2
        echo '[INFO] Run: systemctl enable --now torbox-silo-discovery.timer' >&2
    fi
else
    echo '[WARN] systemd is unavailable or this is not a root shell.'
    echo "[INFO] Run hourly: cd '$INSTALL_DIR' && ./silo-discovery.sh once"
    echo "[INFO] A systemd unit can be installed later with this same command as root."
fi

TORBOX_INSTALL_DIR="$INSTALL_DIR" bash "$SCRIPT_DIR/setup.sh" --refresh-management
echo "[INFO] Silo discovery is configured. Test safely with: cd '$INSTALL_DIR' && ./manage.sh discovery-once --dry-run"
echo "[INFO] Check scheduler: cd '$INSTALL_DIR' && ./manage.sh discovery-status"
