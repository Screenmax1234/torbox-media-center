#!/usr/bin/env bash
set -euo pipefail

# Repair an installation created by an older TorBox Media Server release.
#
# The repair keeps .env, configs, and data in place, replaces only the
# deployment files, and starts Compose with --build.  This is useful for the
# historical "pull access denied for torbox-decypharr" failure: old installs
# referenced a local image tag and often did not contain Dockerfile.decypharr.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-${TORBOX_INSTALL_DIR:-${SCRIPT_DIR}/torbox-media-server}}"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
DOCKERFILE="${INSTALL_DIR}/Dockerfile.decypharr"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
reset='\033[0m'

die() {
    echo -e "${red}[ERROR]${reset} $*" >&2
    exit 1
}

if [[ ! -f "${ENV_FILE}" ]]; then
    die "No .env file found at ${ENV_FILE}. Run ./setup.sh first, or pass the install directory."
fi
if [[ ! -f "${SCRIPT_DIR}/docker-compose.yml" || ! -f "${SCRIPT_DIR}/Dockerfile.decypharr" ]]; then
    die "The repository is missing docker-compose.yml or Dockerfile.decypharr."
fi
command -v docker >/dev/null 2>&1 || die "Docker is not installed or is not on PATH."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

mkdir -p "${INSTALL_DIR}"
backup_dir="${INSTALL_DIR}/backup-before-repair-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${backup_dir}"
[[ -f "${COMPOSE_FILE}" ]] && cp -a "${COMPOSE_FILE}" "${backup_dir}/"
[[ -f "${DOCKERFILE}" ]] && cp -a "${DOCKERFILE}" "${backup_dir}/"

cp "${SCRIPT_DIR}/docker-compose.yml" "${COMPOSE_FILE}"
cp "${SCRIPT_DIR}/Dockerfile.decypharr" "${DOCKERFILE}"
chmod 600 "${COMPOSE_FILE}" "${ENV_FILE}"

echo -e "${green}[INFO]${reset} Deployment files refreshed. Backup: ${backup_dir}"
if ! (cd "${INSTALL_DIR}" && docker compose --env-file "${ENV_FILE}" config -q); then
    die "The refreshed Compose configuration is invalid. Your original files are in ${backup_dir}."
fi

echo -e "${yellow}[INFO]${reset} Rebuilding Decypharr and starting the stack..."
(cd "${INSTALL_DIR}" && docker compose --env-file "${ENV_FILE}" up -d --build --remove-orphans)
echo -e "${green}[INFO]${reset} Repair complete. Check status with: cd \"${INSTALL_DIR}\" && ./manage.sh status"
