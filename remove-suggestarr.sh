#!/usr/bin/env bash
# Remove SuggestArr from an existing installation without touching its data.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-$SCRIPT_DIR/torbox-media-server}}"
[[ -f "$INSTALL_DIR/.env" && -f "$INSTALL_DIR/docker-compose.yml" ]] || {
  echo '[ERROR] Pass an existing install directory containing .env and docker-compose.yml.' >&2; exit 1;
}
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
command -v docker >/dev/null 2>&1 || { echo '[ERROR] Docker is required.' >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo '[ERROR] Docker Compose v2 is required.' >&2; exit 1; }

backup_dir=$(mktemp -d "$INSTALL_DIR/backup-before-remove-suggestarr-XXXXXXXX")
cp -p "$ENV_FILE" "$backup_dir/.env"
[[ ! -f "$INSTALL_DIR/docker-compose.suggestarr.yml" ]] || cp -p "$INSTALL_DIR/docker-compose.suggestarr.yml" "$backup_dir/"

docker rm -f suggestarr 2>/dev/null || true
profiles=$(env_val COMPOSE_PROFILES "$ENV_FILE" || true)
profiles=",${profiles},"
profiles="${profiles//,suggestarr,/,}"
profiles="${profiles#,}"
profiles="${profiles%,}"
files=$(env_val COMPOSE_FILE "$ENV_FILE" || true)
files="${files:-docker-compose.yml}"
files=":${files}:"
files="${files//:docker-compose.suggestarr.yml:/:}"
files="${files//:${INSTALL_DIR}\/docker-compose.suggestarr.yml:/:}"
files="${files#:}"
files="${files%:}"
tmp=$(mktemp "${ENV_FILE}.remove-suggestarr.XXXXXX")
sed -E '/^(SUGGESTARR_ENABLED|SUGGESTARR_PORT|SUGGESTARR_IMAGE|SUGGESTARR_LOG_LEVEL|COMPOSE_PROFILES|COMPOSE_FILE)=/d' "$ENV_FILE" >"$tmp"
printf '\nSUGGESTARR_ENABLED="false"\nCOMPOSE_PROFILES="%s"\nCOMPOSE_FILE="%s"\n' "$profiles" "$files" >>"$tmp"
mv "$tmp" "$ENV_FILE"
rm -f "$INSTALL_DIR/docker-compose.suggestarr.yml"
chmod 600 "$ENV_FILE"
TORBOX_INSTALL_DIR="$INSTALL_DIR" bash "$SCRIPT_DIR/setup.sh" --refresh-management
echo '[INFO] SuggestArr container and Compose overlay removed.'
echo '[INFO] The configs/suggestarr directory was preserved; remove it manually later if you no longer need its history.'
echo "[INFO] Previous settings saved privately in $backup_dir"
