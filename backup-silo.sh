#!/usr/bin/env bash
# Cold-copy Silo's PostgreSQL data; keep the existing stack's deployment/configs.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-$SCRIPT_DIR/torbox-media-server}}"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
env_val() {
    grep "^${1}=" "$ENV_FILE" | head -1 | cut -d= -f2- |
        sed 's/[[:space:]]#.*$//' | tr -d '\r"' | tr -d "'"
}
compose() { (cd "$INSTALL_DIR" && docker compose --env-file "$ENV_FILE" "$@"); }
[[ -f "$ENV_FILE" ]] || {
    echo '[ERROR] Existing installation required.' >&2
    exit 1
}
profiles=$(env_val COMPOSE_PROFILES)
case ",$profiles," in
    *,silo,*) ;;
    *)
        echo '[ERROR] Silo is not enabled in this installation.' >&2
        exit 1
        ;;
esac
config_dir=$(env_val CONFIG_DIR)
[[ "$config_dir" == /* ]] || config_dir="$INSTALL_DIR/$config_dir"
[[ -d "$config_dir/silo" ]] || {
    echo '[ERROR] Silo config directory is missing.' >&2
    exit 1
}
cid=$(compose ps -a -q silo)
running=false
if [[ -n "$cid" ]]; then
    state=$(docker inspect -f '{{.State.Running}}' "$cid")
    case "$state" in
        true) running=true ;;
        false) ;;
        *)
            echo '[ERROR] Could not establish whether Silo is stopped; backup cancelled.' >&2
            exit 1
            ;;
    esac
fi
backup_dir=$(mktemp -d "$(dirname "$INSTALL_DIR")/silo-backup-$(date +%Y%m%d_%H%M%S)-XXXXXXXX")
resume=false
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$resume" == true ]]; then
        if ! compose start silo; then
            echo '[ERROR] Backup finished but Silo could not restart. Run docker compose start silo in the installation directory.' >&2
            result=1
        fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$running" == true ]]; then
    # Register recovery before stopping, including an interrupted stop.
    resume=true
    compose stop silo
fi
mkdir "$backup_dir/deployment"
for file in .env docker-compose.yml Dockerfile.decypharr manage.sh backup-silo.sh \
    docker-compose.override.yml docker-compose.override.yaml \
    docker-compose.silo.yml docker-compose.silo-gpu.yml; do
    [[ ! -f "$INSTALL_DIR/$file" ]] || cp -p "$INSTALL_DIR/$file" "$backup_dir/deployment/"
done
# tar retains numeric ownership and never follows media symlinks. Transcode and
# download-artifact caches live outside CONFIG_DIR and are intentionally omitted.
tar -cpf "$backup_dir/configs.tar" -C "$config_dir" .
printf '%s\n' "$config_dir" >"$backup_dir/config-source.txt"
touch "$backup_dir/COMPLETE"
echo "[INFO] Backup saved to: $backup_dir (Silo database copied while stopped)."
echo '[INFO] Other services retain their current state. For a fully cold stack backup, stop the stack first.'
echo '[INFO] Store SILO_SECRET_KEY separately too. Restore instructions: docs/SILO.md.'
