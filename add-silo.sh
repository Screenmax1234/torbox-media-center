#!/usr/bin/env bash
# Add Silo to a working Linux install without recreating its current services.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/silo.sh"

case "${1:-}" in
    --help | -h)
        echo 'Usage: bash add-silo.sh [INSTALL_DIR]'
        echo 'Adds Silo alongside the active Plex/Jellyfin stack. Defaults to /dev/dri.'
        echo 'TORBOX_SILO_GPU=none opts into a CPU-only trial.'
        exit 0
        ;;
esac
INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-$SCRIPT_DIR/torbox-media-server}}"
[[ -f "$INSTALL_DIR/.env" && -f "$INSTALL_DIR/docker-compose.yml" ]] || {
    echo '[ERROR] Pass an existing install directory containing .env and docker-compose.yml.' >&2
    exit 1
}
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
gpu=$(env_val SILO_GPU "$ENV_FILE" || true)
export TORBOX_SILO_GPU="${TORBOX_SILO_GPU:-${gpu:-dri}}"
silo_check_host
docker info >/dev/null
# --no-deps below deliberately requires an already healthy Decypharr mount.
cid=$(cd "$INSTALL_DIR" && docker compose --env-file "$ENV_FILE" ps -q decypharr)
[[ -n "$cid" && $(docker inspect -f '{{.State.Health.Status}}' "$cid") == healthy ]] || {
    echo '[ERROR] Start the current stack and wait for Decypharr to be healthy before adding Silo.' >&2
    exit 1
}
backup_dir=$(mktemp -d "$INSTALL_DIR/backup-before-silo-XXXXXXXX")
cp -p "$ENV_FILE" "$backup_dir/.env"
for file in manage.sh backup-silo.sh docker-compose.silo.yml docker-compose.silo-gpu.yml; do
    [[ ! -f "$INSTALL_DIR/$file" ]] || cp -p "$INSTALL_DIR/$file" "$backup_dir/"
done
rollback_files() {
    cp -p "$backup_dir/.env" "$ENV_FILE"
    for file in manage.sh backup-silo.sh docker-compose.silo.yml docker-compose.silo-gpu.yml; do
        if [[ -f "$backup_dir/$file" ]]; then
            cp -p "$backup_dir/$file" "$INSTALL_DIR/$file"
        else
            rm -f "$INSTALL_DIR/$file"
        fi
    done
}
# Restore deployment files on validation/pull failures; no old service was touched.
trap 'rollback_files' ERR
silo_prepare "$INSTALL_DIR" "$SCRIPT_DIR"
cp "$SCRIPT_DIR/backup-silo.sh" "$INSTALL_DIR/backup-silo.sh"
(cd "$INSTALL_DIR" && docker compose --env-file "$ENV_FILE" config -q)
(cd "$INSTALL_DIR" && docker compose --env-file "$ENV_FILE" pull silo)
TORBOX_INSTALL_DIR="$INSTALL_DIR" bash "$SCRIPT_DIR/setup.sh" --refresh-management
# No whole-stack up, no --remove-orphans, no image update to existing services.
# Once startup is attempted, retain the key even on failure: the container may
# already have initialized its encrypted database. Retrying must reuse that key.
trap - ERR
if ! (cd "$INSTALL_DIR" && docker compose --env-file "$ENV_FILE" up -d --no-deps silo); then
    echo '[ERROR] Silo startup failed. Its settings and encryption key were retained for a safe retry.' >&2
    echo "[INFO] Check: cd \"$INSTALL_DIR\" && ./manage.sh logs silo" >&2
    echo '[INFO] Fix the reported problem, then run add-silo.sh again.' >&2
    exit 1
fi
port=$(env_val SILO_HTTP_PORT "$ENV_FILE" || true)
echo "[INFO] Silo started at http://SERVER-IP:${port:-8090}. Initial database setup can take several minutes."
echo "[INFO] Previous deployment settings saved privately in $backup_dir"
echo '[INFO] Finish onboarding, requests, autoscan and GPU selection using docs/SILO.md.'
