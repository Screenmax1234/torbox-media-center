#!/usr/bin/env bash
# Move persistent configuration, optional DATA_DIR, and Silo temporary work to
# a mounted data disk while preserving the container's /data paths.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-${SCRIPT_DIR}/torbox-media-server}}"
TARGET_ROOT="${2:-${TORBOX_STORAGE_ROOT:-/data/torbox-system}}"
ENV_FILE="${INSTALL_DIR}/.env"
source "${SCRIPT_DIR}/lib/env.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

[[ -f "${ENV_FILE}" && -f "${INSTALL_DIR}/docker-compose.yml" ]] || die "Pass an existing install directory containing .env and docker-compose.yml."
INSTALL_DIR="$(cd "${INSTALL_DIR}" && pwd)"
ENV_FILE="${INSTALL_DIR}/.env"
CONFIG_DIR="$(env_val CONFIG_DIR "${ENV_FILE}" || true)"
SILO_WORK_DIR="$(env_val SILO_WORK_DIR "${ENV_FILE}" || true)"
CONFIG_DIR="${CONFIG_DIR:-${INSTALL_DIR}/configs}"
SILO_WORK_DIR="${SILO_WORK_DIR:-${INSTALL_DIR}/silo-work}"
TARGET_ROOT="${TARGET_ROOT%/}"
TARGET_CONFIG="${TARGET_ROOT}/configs"
TARGET_SILO_WORK="${TARGET_ROOT}/silo-work"
TARGET_DATA="${TARGET_ROOT}/data"

[[ "${TARGET_ROOT}" == /* ]] || die "The target must be an absolute path."
[[ -d "${TARGET_ROOT}" || -d "$(dirname "${TARGET_ROOT}")" ]] || die "Target parent does not exist: ${TARGET_ROOT}"
mkdir -p "${TARGET_CONFIG}" "${TARGET_SILO_WORK}/transcode" "${TARGET_SILO_WORK}/download-artifacts" "${TARGET_DATA}"
chmod 755 "${TARGET_ROOT}" "${TARGET_CONFIG}" "${TARGET_SILO_WORK}" "${TARGET_SILO_WORK}/transcode" "${TARGET_SILO_WORK}/download-artifacts" "${TARGET_DATA}"

source_device=$(df -P "${INSTALL_DIR}" | awk 'NR==2 {print $1}')
target_device=$(df -P "${TARGET_ROOT}" | awk 'NR==2 {print $1}')
[[ -n "${target_device}" && "${target_device}" != "${source_device}" ]] || die "${TARGET_ROOT} is on the same filesystem as the install. Mount the HDD there first."

command -v docker >/dev/null 2>&1 || die "Docker is required."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
copy_tree() {
    local source="$1" target="$2"
    mkdir -p "${target}"
    if command -v rsync >/dev/null 2>&1; then
        rsync -aHAX "${source}/" "${target}/"
    else
        cp -a "${source}/." "${target}/"
    fi
}

backup_dir="${INSTALL_DIR}/backup-before-storage-move-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${backup_dir}"
cp -a "${ENV_FILE}" "${backup_dir}/.env"

info "Stopping the stack before copying persistent files."
(cd "${INSTALL_DIR}" && docker compose --env-file "${ENV_FILE}" down)

info "Copying configuration data to ${TARGET_CONFIG}."
[[ -d "${CONFIG_DIR}" ]] && copy_tree "${CONFIG_DIR}" "${TARGET_CONFIG}"
info "Copying Silo temporary work data to ${TARGET_SILO_WORK}."
[[ -d "${SILO_WORK_DIR}" ]] && copy_tree "${SILO_WORK_DIR}" "${TARGET_SILO_WORK}"
DATA_MOVED=false
if [[ -d "${DATA_DIR}" ]]; then
    data_device=$(df -P "${DATA_DIR}" | awk 'NR==2 {print $1}')
    if [[ "${data_device}" != "${target_device}" ]]; then
        info "Copying DATA_DIR to ${TARGET_DATA}."
        copy_tree "${DATA_DIR}" "${TARGET_DATA}"
        DATA_MOVED=true
    else
        info "DATA_DIR is already on the target filesystem; leaving it in place."
    fi
fi

tmp=$(mktemp "${ENV_FILE}.storage.XXXXXX")
chmod 600 "${tmp}"
sed -E '/^(CONFIG_DIR|DATA_DIR|SILO_WORK_DIR)=/d' "${ENV_FILE}" >"${tmp}"
printf 'CONFIG_DIR="%s"\n' "${TARGET_CONFIG}" >>"${tmp}"
if [[ "${DATA_MOVED}" == true ]]; then
    printf 'DATA_DIR="%s"\n' "${TARGET_DATA}" >>"${tmp}"
else
    printf 'DATA_DIR="%s"\n' "${DATA_DIR}" >>"${tmp}"
fi
printf 'SILO_WORK_DIR="%s"\n' "${TARGET_SILO_WORK}" >>"${tmp}"
mv "${tmp}" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

info "Validating the updated Compose paths."
(cd "${INSTALL_DIR}" && docker compose --env-file "${ENV_FILE}" config -q)
info "Starting the stack."
(cd "${INSTALL_DIR}" && docker compose --env-file "${ENV_FILE}" up -d)

echo ""
echo "Storage move complete. Backup: ${backup_dir}"
echo "New CONFIG_DIR: ${TARGET_CONFIG}"
echo "New DATA_DIR: $([[ "${DATA_MOVED}" == true ]] && echo "${TARGET_DATA}" || echo "${DATA_DIR}")"
echo "New SILO_WORK_DIR: ${TARGET_SILO_WORK}"
echo "The old directories were retained as a rollback copy. Delete them only after verifying all services and Silo artwork work."
