#!/usr/bin/env bash
# Optional NZBHydra2 deployment helpers. Callers source lib/env.sh first.

nzbhydra_prepare() {
    local install="$1" source_dir="$2" env_file="$1/.env"
    local profiles files entry item found tmp port image config_dir
    local -a file_entries

    port="${TORBOX_NZBHYDRA_PORT:-${NZBHYDRA_PORT:-$(env_val NZBHYDRA_PORT "$env_file" || true)}}"
    port="${port:-5076}"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
        echo "[ERROR] NZBHYDRA_PORT must be a valid TCP port." >&2
        return 1
    }
    image="${TORBOX_NZBHYDRA_IMAGE:-${NZBHYDRA_IMAGE:-$(env_val NZBHYDRA_IMAGE "$env_file" || true)}}"
    image="${image:-lscr.io/linuxserver/nzbhydra2:latest}"
    config_dir=$(env_val CONFIG_DIR "$env_file" || true)
    [[ "$config_dir" == /* ]] || config_dir="$install/${config_dir:-configs}"

    profiles=$(env_val COMPOSE_PROFILES "$env_file" || true)
    case ",$profiles," in *,nzbhydra,*) ;; *) profiles="${profiles:+$profiles,}nzbhydra" ;; esac
    files=$(env_val COMPOSE_FILE "$env_file" || true)
    if [[ -z "$files" ]]; then
        files=docker-compose.yml
        [[ -f "$install/docker-compose.override.yml" ]] && files+=:docker-compose.override.yml
        [[ -f "$install/docker-compose.override.yaml" && ! -f "$install/docker-compose.override.yml" ]] && files+=:docker-compose.override.yaml
    fi
    found=false
    IFS=: read -ra file_entries <<<"$files"
    for entry in "${file_entries[@]}"; do
        [[ "$entry" == docker-compose.nzbhydra.yml || "$entry" == "$install/docker-compose.nzbhydra.yml" ]] && found=true
    done
    [[ "$found" == true ]] || files+=":docker-compose.nzbhydra.yml"

    cp "$source_dir/docker-compose.nzbhydra.yml" "$install/docker-compose.nzbhydra.yml"
    mkdir -p "$config_dir/nzbhydra"
    tmp=$(mktemp "$install/.nzbhydra-env.XXXXXXXX") || return 1
    chmod 600 "$tmp"
    sed -E '/^(NZBHYDRA_ENABLED|NZBHYDRA_PORT|NZBHYDRA_IMAGE|COMPOSE_PROFILES|COMPOSE_FILE)=/d' "$env_file" >"$tmp"
    printf '\nNZBHYDRA_ENABLED="true"\nNZBHYDRA_PORT="%s"\nNZBHYDRA_IMAGE="%s"\nCOMPOSE_PROFILES="%s"\nCOMPOSE_FILE="%s"\n' \
        "$port" "$image" "$profiles" "$files" >>"$tmp"
    mv "$tmp" "$env_file"
    chmod 600 "$env_file" "$install/docker-compose.nzbhydra.yml"
    echo "[INFO] NZBHydra overlay prepared on port ${port}."
}
