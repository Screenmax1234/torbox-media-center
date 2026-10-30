#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
install_dir="$test_dir/install with spaces"
mkdir -p "$install_dir"

# Exercise the actual installed script with disposable credentials, not a
# string match against its template. No Docker daemon or real secrets needed.
cat >"$install_dir/.env" <<'ENV'
TORBOX_API_KEY=torbox-test-secret-12345
RADARR_API_KEY=radarr-test-secret-12345
SONARR_API_KEY=sonarr-test-secret-12345
PROWLARR_API_KEY=prowlarr-test-secret-12345
RADARR_ADMIN_USER=radarr-admin
RADARR_ADMIN_PASS=radarr-password-12345
SONARR_ADMIN_USER=sonarr-admin
SONARR_ADMIN_PASS=sonarr-password-12345
PROWLARR_ADMIN_USER=prowlarr-admin
PROWLARR_ADMIN_PASS=prowlarr-password-12345
ENV
cp "$install_dir/.env" "$test_dir/original-env"
printf '%s\n' 'previous management script' >"$install_dir/manage.sh"

TORBOX_INSTALL_DIR="$install_dir" bash "$PROJECT_ROOT/setup.sh" --refresh-management
cmp "$test_dir/original-env" "$install_dir/.env"
grep -q '^previous management script$' "$install_dir/manage.sh.bak"
bash -n "$install_dir/manage.sh"

masked=$(bash "$install_dir/manage.sh" keys)
revealed=$(bash "$install_dir/manage.sh" keys --show-secrets)
grep -q 'Secrets masked' <<<"$masked"
while IFS='=' read -r name value; do
    case "$name" in
        *_KEY | *_PASS)
            if grep -Fq "$value" <<<"$masked"; then
                echo "FAIL: keys exposed $name without --show-secrets" >&2
                exit 1
            fi
            if ! grep -Fq "$value" <<<"$revealed"; then
                echo "FAIL: keys --show-secrets did not display $name" >&2
                exit 1
            fi
            ;;
    esac
done <"$install_dir/.env"

echo 'PASS: keys works without optional arguments, masks secrets, and reveals only on request'
