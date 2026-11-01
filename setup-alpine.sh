#!/bin/sh
# TorBox Media Server - Alpine Linux entry point
#
# Alpine ships with BusyBox ash instead of Bash and uses OpenRC instead of
# systemd.  Keep those host-specific steps here so the main setup.sh remains
# the single source of truth for stack generation and auto-configuration.

set -eu

case "$0" in
    */*) SCRIPT_DIR=${0%/*}; [ -n "$SCRIPT_DIR" ] || SCRIPT_DIR=/ ;;
    *) SCRIPT_DIR=. ;;
esac
SCRIPT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR" && pwd)

usage() {
    cat <<'EOF'
TorBox Media Server Alpine Linux setup wrapper

This wrapper installs the Alpine host prerequisites, starts Docker through
OpenRC, then runs the normal setup.sh with all supplied arguments.

Usage:
  bash setup-alpine.sh [setup.sh options]

Examples:
  TORBOX_API_KEY="your-api-key" bash setup-alpine.sh --yes
  TORBOX_API_KEY="your-api-key" TORBOX_MEDIA_SERVER=silo bash setup-alpine.sh --yes
  bash setup-alpine.sh --dry-run

The normal setup.sh options are passed through unchanged. Run
"bash setup-alpine.sh --help" to see them.
EOF
}

# Keep --help usable even when this file is inspected from a non-Alpine host.
case "${1:-}" in
    -h|--help|help)
        usage
        if [ -x "${SCRIPT_DIR}/setup.sh" ] || [ -f "${SCRIPT_DIR}/setup.sh" ]; then
            printf '\nMain installer options:\n'
            if command -v bash >/dev/null 2>&1; then
                bash "${SCRIPT_DIR}/setup.sh" --help
            else
                printf '  (Install Bash on Alpine to display the main installer options.)\n'
            fi
        fi
        exit 0
        ;;
esac

if [ ! -f /etc/alpine-release ] || ! command -v apk >/dev/null 2>&1; then
    printf '%s\n' '[ERROR] setup-alpine.sh must be run on Alpine Linux.' >&2
    printf '%s\n' '        Use setup.sh on Debian, Ubuntu, Fedora, Arch, or another Linux host.' >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    run_root() { "$@"; }
else
    if ! command -v sudo >/dev/null 2>&1; then
        printf '%s\n' '[ERROR] Alpine dependencies require root or sudo.' >&2
        printf '%s\n' '        Re-run as root, or install sudo and retry.' >&2
        exit 1
    fi
    run_root() { sudo "$@"; }
fi

# A dry run must not mutate the host. The main installer will report missing
# dependencies without attempting to install them.
case " ${*:-} " in
    *' --dry-run '*|*' -d '*)
        if ! command -v bash >/dev/null 2>&1; then
            printf '%s\n' '[ERROR] --dry-run requires Bash, which is not installed yet.' >&2
            printf '%s\n' '        Run the normal Alpine setup once, or install Bash with: apk add bash' >&2
            exit 1
        fi
        exec bash "${SCRIPT_DIR}/setup.sh" "$@"
        ;;
esac

printf '%s\n' '[INFO] Installing/checking Alpine prerequisites...'
# docker-cli-compose provides the Docker Compose v2 plugin used by setup.sh.
# util-linux provides findmnt/mount, and fuse3 provides the userspace FUSE
# helpers used by the TorBox mount.
run_root apk add --no-cache \
    bash \
    docker \
    docker-cli-compose \
    curl \
    jq \
    openssl \
    fuse3 \
    util-linux

if ! command -v rc-service >/dev/null 2>&1 || ! command -v rc-update >/dev/null 2>&1; then
    printf '%s\n' '[ERROR] OpenRC tools are unavailable. This Alpine installation cannot manage Docker.' >&2
    exit 1
fi

run_root rc-update add docker default >/dev/null 2>&1 || true
if ! run_root docker info >/dev/null 2>&1; then
    printf '%s\n' '[INFO] Starting Docker through OpenRC...'
    run_root rc-service docker start
fi

if ! run_root docker info >/dev/null 2>&1; then
    printf '%s\n' '[ERROR] Docker is still unavailable after starting the OpenRC service.' >&2
    printf '%s\n' '        Check Alpine Docker/OpenRC logs, then re-run this script.' >&2
    exit 1
fi

if ! run_root docker compose version >/dev/null 2>&1; then
    printf '%s\n' '[ERROR] Docker Compose v2 is unavailable (expected: docker compose).' >&2
    printf '%s\n' '        Verify that the docker-cli-compose Alpine package is installed.' >&2
    exit 1
fi

if [ ! -e /dev/fuse ]; then
    printf '%s\n' '[ERROR] /dev/fuse is unavailable.' >&2
    printf '%s\n' '        Pass FUSE through to the Alpine VM/LXC before continuing.' >&2
    exit 1
fi

if [ ! -e /dev/dri ]; then
    printf '%s\n' '[WARN] /dev/dri is unavailable; hardware transcoding will not work.' >&2
    printf '%s\n' '      Pass the render device through to the Alpine VM/LXC, or use' >&2
    printf '%s\n' '      TORBOX_SILO_GPU=none for a CPU-only Silo installation.' >&2
fi

if [ "$(id -u)" -ne 0 ] && command -v addgroup >/dev/null 2>&1; then
    # Alpine's addgroup syntax is addgroup USER GROUP. Ignore the result when
    # the user is already a member or the group was managed externally.
    run_root addgroup "$(id -un)" docker >/dev/null 2>&1 || true
fi

printf '%s\n' '[INFO] Alpine host is ready; handing off to setup.sh...'
if [ "$(id -u)" -ne 0 ]; then
    # The main installer must be able to access the Docker socket during its
    # dependency checks. A fresh supplementary-group change is not visible to
    # the current shell, so run the handoff through sudo for this invocation.
    printf '%s\n' '[WARN] Running the main installer through sudo so it can access Docker.' >&2
    exec sudo -E bash "${SCRIPT_DIR}/setup.sh" "$@"
fi
exec bash "${SCRIPT_DIR}/setup.sh" "$@"
