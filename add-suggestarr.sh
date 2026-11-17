#!/usr/bin/env bash
# Add SuggestArr to a working installation without recreating current services.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/suggestarr.sh"

case "${1:-}" in
  --help|-h)
    echo 'Usage: bash add-suggestarr.sh [INSTALL_DIR]'
    echo 'Adds SuggestArr recommendation automation alongside the active stack.'
    echo 'Set TORBOX_SUGGESTARR_PORT (or SUGGESTARR_PORT) to change the host port (default: 5000).'
    exit 0
    ;;
esac
INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-$SCRIPT_DIR/torbox-media-server}}"
[[ -f "$INSTALL_DIR/.env" && -f "$INSTALL_DIR/docker-compose.yml" ]] || {
  echo '[ERROR] Pass an existing install directory containing .env and docker-compose.yml.' >&2; exit 1;
}
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
command -v docker >/dev/null 2>&1 || { echo '[ERROR] Docker is required.' >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo '[ERROR] Docker Compose v2 is required.' >&2; exit 1; }

backup_dir=$(mktemp -d "$INSTALL_DIR/backup-before-suggestarr-XXXXXXXX")
cp -p "$ENV_FILE" "$backup_dir/.env"
for file in manage.sh docker-compose.suggestarr.yml; do
  [[ ! -f "$INSTALL_DIR/$file" ]] || cp -p "$INSTALL_DIR/$file" "$backup_dir/"
done
rollback_files() {
  cp -p "$backup_dir/.env" "$ENV_FILE"
  for file in manage.sh docker-compose.suggestarr.yml; do
    if [[ -f "$backup_dir/$file" ]]; then cp -p "$backup_dir/$file" "$INSTALL_DIR/$file"; else rm -f "$INSTALL_DIR/$file"; fi
  done
}
trap 'rollback_files' ERR

suggestarr_prepare "$INSTALL_DIR" "$SCRIPT_DIR"
(cd "$INSTALL_DIR" && docker compose --env-file "$ENV_FILE" config -q)
(cd "$INSTALL_DIR" && docker compose --env-file "$ENV_FILE" pull suggestarr)
TORBOX_INSTALL_DIR="$INSTALL_DIR" bash "$SCRIPT_DIR/setup.sh" --refresh-management
if ! (cd "$INSTALL_DIR" && docker compose --env-file "$ENV_FILE" up -d --no-deps suggestarr); then
  echo '[ERROR] SuggestArr startup failed. Existing services were not restarted.' >&2
  echo "[INFO] Check: cd \"$INSTALL_DIR\" && ./manage.sh logs suggestarr" >&2
  exit 1
fi
trap - ERR
port=$(env_val SUGGESTARR_PORT "$ENV_FILE" || true)
echo "[INFO] SuggestArr started at http://SERVER-IP:${port:-5000}."
echo '[INFO] Open the web UI and complete its wizard: TMDb, Silo/Jellyfin, and Seerr credentials are configured there.'
echo "[INFO] Previous deployment settings saved privately in $backup_dir"
