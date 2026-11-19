#!/usr/bin/env bash
# Show the persistent paths that can grow in a TorBox Media Server install.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-${SCRIPT_DIR}/torbox-media-server}}"
ENV_FILE="${INSTALL_DIR}/.env"
source "${SCRIPT_DIR}/lib/env.sh"

[[ -f "${ENV_FILE}" ]] || { echo "[ERROR] No .env found at ${ENV_FILE}." >&2; exit 1; }
INSTALL_DIR="$(cd "${INSTALL_DIR}" && pwd)"
ENV_FILE="${INSTALL_DIR}/.env"
CONFIG_DIR="$(env_val CONFIG_DIR "${ENV_FILE}" || true)"
DATA_DIR="$(env_val DATA_DIR "${ENV_FILE}" || true)"
MOUNT_DIR="$(env_val MOUNT_DIR "${ENV_FILE}" || true)"
SILO_WORK_DIR="$(env_val SILO_WORK_DIR "${ENV_FILE}" || true)"
CONFIG_DIR="${CONFIG_DIR:-${INSTALL_DIR}/configs}"
DATA_DIR="${DATA_DIR:-${INSTALL_DIR}/data}"
SILO_WORK_DIR="${SILO_WORK_DIR:-${INSTALL_DIR}/silo-work}"

echo "TorBox storage report"
echo "Install: ${INSTALL_DIR}"
echo ""
printf '[Root filesystem usage]\n'
df -hT / 2>/dev/null || true
du -xhd1 / 2>/dev/null | sort -h | tail -n 20 || true
if [[ -d /var/lib/docker ]]; then
    printf '\n[/var/lib/docker breakdown]\n'
    du -xhd2 /var/lib/docker 2>/dev/null | sort -h | tail -n 30 || true
fi
if command -v lsof >/dev/null 2>&1; then
    printf '\n[Deleted files still held open]\n'
    lsof +L1 2>/dev/null | tail -n +2 | head -n 30 || true
fi

for path in "${INSTALL_DIR}" "${CONFIG_DIR}" "${CONFIG_DIR}/silo" "${CONFIG_DIR}/silo/artwork" "${CONFIG_DIR}/silo/postgres" "${SILO_WORK_DIR}" "${DATA_DIR}" "${MOUNT_DIR:-/mnt/remote}"; do
    [[ -e "${path}" ]] || continue
    printf '\n[%s]\n' "${path}"
    df -hT "${path}" 2>/dev/null || true
    du -xhd2 "${path}" 2>/dev/null | sort -h | tail -n 20 || true
done

if command -v docker >/dev/null 2>&1; then
    printf '\n[Container writable-layer sizes]\n'
    docker ps -as --format 'table {{.Names}}\t{{.Size}}\t{{.Image}}' 2>/dev/null || true
    printf '\n[Docker usage]\n'
    docker system df 2>/dev/null || true
    printf '\n[Container logs]\n'
    docker ps --format '{{.Names}}' 2>/dev/null | while read -r container; do
        size=$(docker inspect --format '{{.LogPath}}' "${container}" 2>/dev/null | xargs -r du -h 2>/dev/null | awk '{print $1}')
        printf '%-28s %s\n' "${container}" "${size:-0}"
    done
fi

echo ""
echo "The usual per-movie growth is Silo artwork/PostgreSQL metadata or an active"
echo "transcode cache. Media growth belongs under DATA_DIR and should be checked"
echo "against the HDD mount separately."
