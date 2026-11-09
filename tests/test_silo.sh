#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/env.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"
export DOCKER_TEST_LOG="$test_dir/docker.log"
export TORBOX_SILO_GPU=none
export PATH="$test_dir/bin:$PATH"
cat >"$test_dir/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_TEST_LOG"
case "$*" in
    'compose version --short') echo "${DOCKER_TEST_VERSION:-v2.39.4}" ;;
    info) ;;
    'inspect -f {{.State.Health.Status}} mount-cid') echo healthy ;;
    'inspect -f {{.State.Running}} silo-cid') echo true ;;
    *'ps -q decypharr') echo mount-cid ;;
    *'ps -a -q silo') echo silo-cid ;;
    *'pull silo') [[ "${FAIL_PULL:-false}" != true ]] ;;
    *'up -d --no-deps silo') [[ "${FAIL_START:-false}" != true ]] ;;
    *'config -q'|*'start silo'|*'stop silo'|*'pull prowlarr byparr radarr sonarr bazarr seerr plex silo'|*'pull prowlarr byparr radarr sonarr bazarr seerr jellyfin silo') ;;
    *) echo "Unexpected Docker call: $*" >&2; exit 2 ;;
esac
MOCK
chmod +x "$test_dir/bin/docker"
fixture() {
    install_dir="$test_dir/$1 with spaces"
    mkdir -p "$install_dir/custom-configs/decypharr" "$install_dir/data"
    printf 'keep exact config\n' >"$install_dir/custom-configs/decypharr/config.json"
    printf 'keep exact base\n' >"$install_dir/docker-compose.yml"
    printf 'keep exact override\n' >"$install_dir/docker-compose.override.yml"
    printf 'original management\n' >"$install_dir/manage.sh"
    cat >"$install_dir/.env" <<ENV
PUID=0
PGID=0
CONFIG_DIR="$install_dir/custom-configs"
DATA_DIR="$install_dir/data"
MOUNT_DIR=/mnt/torbox-media
COMPOSE_PROFILES=${2:-plex}
DECYPHARR_PASS=unchanged-password
RADARR_API_KEY=unchanged-api-key
SILO_HTTP_PORT=18090
ENV
    cp "$install_dir/.env" "$test_dir/original-env"
}
fixture success
bash "$PROJECT_ROOT/add-silo.sh" "$install_dir" >"$test_dir/output"
key=$(env_val SILO_SECRET_KEY "$install_dir/.env")
[[ ${#key} -ge 32 && $(env_val SILO_PUID "$install_dir/.env") == 911 ]]
[[ $(env_val COMPOSE_PROFILES "$install_dir/.env") == plex,silo ]]
[[ $(env_val COMPOSE_FILE "$install_dir/.env") == docker-compose.yml:docker-compose.override.yml:docker-compose.silo.yml ]]
grep -q '^DECYPHARR_PASS=unchanged-password$' "$install_dir/.env"
grep -q '^RADARR_API_KEY=unchanged-api-key$' "$install_dir/.env"
grep -q '^keep exact base$' "$install_dir/docker-compose.yml"
grep -q '^keep exact override$' "$install_dir/docker-compose.override.yml"
grep -q '^keep exact config$' "$install_dir/custom-configs/decypharr/config.json"
grep -q 'up -d --no-deps silo$' "$DOCKER_TEST_LOG"
if grep -q -- '--remove-orphans\|--build' "$DOCKER_TEST_LOG"; then
    echo 'FAIL: adding Silo attempted a whole-stack operation' >&2
    exit 1
fi
bash "$PROJECT_ROOT/add-silo.sh" "$install_dir" >>"$test_dir/output"
[[ $(env_val SILO_SECRET_KEY "$install_dir/.env") == "$key" ]]
[[ $(env_val COMPOSE_PROFILES "$install_dir/.env") == plex,silo ]]
urls=$(bash "$install_dir/manage.sh" urls)
grep -q 'Plex.*32400/web' <<<"$urls"
grep -q 'Silo.*18090' <<<"$urls"
bash "$install_dir/manage.sh" pull >>"$test_dir/output"
grep -q 'pull prowlarr byparr radarr sonarr bazarr seerr plex silo$' "$DOCKER_TEST_LOG"
echo 'PASS: adds only Silo; preserves base, overrides, credentials and key; management supports both profiles'

fixture jellyfin jellyfin
bash "$PROJECT_ROOT/add-silo.sh" "$install_dir" >>"$test_dir/output"
urls=$(bash "$install_dir/manage.sh" urls)
grep -q 'Jellyfin.*8096' <<<"$urls"
bash "$install_dir/manage.sh" pull >>"$test_dir/output"
grep -q 'pull prowlarr byparr radarr sonarr bazarr seerr jellyfin silo$' "$DOCKER_TEST_LOG"
help=$(bash "$PROJECT_ROOT/setup.sh" --help)
grep -q "TORBOX_MEDIA_SERVER.*silo" <<<"$help"
grep -q "TORBOX_ENABLE_SILO" <<<"$help"
[[ -n $(env_val SILO_SECRET_KEY "$install_dir/.env") ]]
echo 'PASS: Jellyfin add-on works and the central installer exposes Silo modes'

fixture pull-failure
if FAIL_PULL=true bash "$PROJECT_ROOT/add-silo.sh" "$install_dir" >"$test_dir/failure" 2>&1; then
    echo 'FAIL: pull failure was ignored' >&2
    exit 1
fi
cmp "$test_dir/original-env" "$install_dir/.env"
grep -q '^original management$' "$install_dir/manage.sh"
[[ ! -f "$install_dir/docker-compose.silo.yml" ]]
echo 'PASS: pull failure restores the original deployment files'

fixture start-failure
if FAIL_START=true bash "$PROJECT_ROOT/add-silo.sh" "$install_dir" >"$test_dir/failure" 2>&1; then
    echo 'FAIL: start failure was ignored' >&2
    exit 1
fi
key=$(env_val SILO_SECRET_KEY "$install_dir/.env")
[[ ${#key} -ge 32 ]]
bash "$PROJECT_ROOT/add-silo.sh" "$install_dir" >>"$test_dir/output"
[[ $(env_val SILO_SECRET_KEY "$install_dir/.env") == "$key" ]]
mkdir -p "$install_dir/custom-configs/silo/postgres"
printf 'database marker\n' >"$install_dir/custom-configs/silo/postgres/marker"
: >"$DOCKER_TEST_LOG"
bash "$install_dir/manage.sh" backup >"$test_dir/backup-output"
backup_archive=$(find "$test_dir" -name configs.tar -print -quit)
[[ -n "$backup_archive" ]]
tar -tf "$backup_archive" | grep -q './silo/postgres/marker'
grep -q 'stop silo$' "$DOCKER_TEST_LOG"
grep -q 'start silo$' "$DOCKER_TEST_LOG"
# Simulate disk/copy failure and ensure a stopped Silo is resumed.
printf '#!/usr/bin/env bash\nexit 1\n' >"$test_dir/bin/tar"
chmod +x "$test_dir/bin/tar"
: >"$DOCKER_TEST_LOG"
if bash "$install_dir/manage.sh" backup >"$test_dir/failure" 2>&1; then
    echo 'FAIL: failed backup reported success' >&2
    exit 1
fi
grep -q 'start silo$' "$DOCKER_TEST_LOG"
rm "$test_dir/bin/tar"
if bash "$install_dir/manage.sh" restore >"$test_dir/failure" 2>&1; then
    echo 'FAIL: unsafe legacy restore was accepted' >&2
    exit 1
fi
echo 'PASS: startup retry retains key; backups stop/resume Silo and resume even when copying fails'

fixture missing-key
mkdir -p "$install_dir/custom-configs/silo/postgres"
printf 'existing database\n' >"$install_dir/custom-configs/silo/postgres/marker"
if bash "$PROJECT_ROOT/add-silo.sh" "$install_dir" >"$test_dir/failure" 2>&1; then
    echo 'FAIL: generated a replacement key for an existing database' >&2
    exit 1
fi
cmp "$test_dir/original-env" "$install_dir/.env"
grep -q 'original key' "$test_dir/failure"
echo 'PASS: custom config location with existing database never receives a replacement encryption key'

# Exercise GPU overlay preparation without needing a physical GPU or root.
source "$PROJECT_ROOT/lib/silo.sh"
fixture overlay-switch
TORBOX_SILO_GPU=dri silo_prepare "$install_dir" "$PROJECT_ROOT" >>"$test_dir/output"
files=$(env_val COMPOSE_FILE "$install_dir/.env")
[[ "$files" == *:docker-compose.silo-gpu.yml ]]
TORBOX_SILO_GPU=none silo_prepare "$install_dir" "$PROJECT_ROOT" >>"$test_dir/output"
[[ $(env_val COMPOSE_FILE "$install_dir/.env") == docker-compose.yml:docker-compose.override.yml:docker-compose.silo.yml ]]
echo 'PASS: GPU-to-CPU switch removes only the GPU overlay and retains the existing hardware override'

fixture old-compose
if DOCKER_TEST_VERSION=v2.23.3 bash "$PROJECT_ROOT/add-silo.sh" "$install_dir" >"$test_dir/failure" 2>&1; then
    echo 'FAIL: accepted unsupported Compose version' >&2
    exit 1
fi
cmp "$test_dir/original-env" "$install_dir/.env"
echo 'PASS: unsupported Compose is rejected before changing the install'

fixture custom-identity
printf '\nSILO_PUID=1234\nSILO_PGID=0\nSILO_SECRET_KEY=preserve-this-existing-generated-key-1234567890\n' >>"$install_dir/.env"
silo_prepare "$install_dir" "$PROJECT_ROOT" >>"$test_dir/output"
[[ $(env_val SILO_PUID "$install_dir/.env") == 1234 ]]
[[ $(env_val SILO_PGID "$install_dir/.env") == 0 ]]
[[ $(env_val SILO_SECRET_KEY "$install_dir/.env") == preserve-this-existing-generated-key-1234567890 ]]
echo 'PASS: explicit nonroot Silo identity and existing encryption key are preserved'
