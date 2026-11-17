#!/usr/bin/env bash
# Optional SuggestArr deployment helpers. Callers source lib/env.sh first.

suggestarr_prepare() {
    local install="$1" source_dir="$2" env_file="$1/.env"
    local profiles files entry found tmp port image log_level config_dir
    local -a file_entries

    port="${TORBOX_SUGGESTARR_PORT:-${SUGGESTARR_PORT:-$(env_val SUGGESTARR_PORT "$env_file" || true)}}"
    port="${port:-5000}"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
        echo "[ERROR] SUGGESTARR_PORT must be a valid TCP port." >&2
        return 1
    }
    image="${TORBOX_SUGGESTARR_IMAGE:-${SUGGESTARR_IMAGE:-$(env_val SUGGESTARR_IMAGE "$env_file" || true)}}"
    image="${image:-ciuse99/suggestarr:latest}"
    log_level="${TORBOX_SUGGESTARR_LOG_LEVEL:-${SUGGESTARR_LOG_LEVEL:-$(env_val SUGGESTARR_LOG_LEVEL "$env_file" || true)}}"
    log_level="${log_level:-INFO}"
    config_dir=$(env_val CONFIG_DIR "$env_file" || true)
    [[ "$config_dir" == /* ]] || config_dir="$install/${config_dir:-configs}"

    profiles=$(env_val COMPOSE_PROFILES "$env_file" || true)
    case ",$profiles," in *,suggestarr,*) ;; *) profiles="${profiles:+$profiles,}suggestarr" ;; esac
    files=$(env_val COMPOSE_FILE "$env_file" || true)
    if [[ -z "$files" ]]; then
        files=docker-compose.yml
        [[ -f "$install/docker-compose.override.yml" ]] && files+=:docker-compose.override.yml
        [[ -f "$install/docker-compose.override.yaml" && ! -f "$install/docker-compose.override.yml" ]] && files+=:docker-compose.override.yaml
    fi
    found=false
    IFS=: read -ra file_entries <<<"$files"
    for entry in "${file_entries[@]}"; do
        [[ "$entry" == docker-compose.suggestarr.yml || "$entry" == "$install/docker-compose.suggestarr.yml" ]] && found=true
    done
    [[ "$found" == true ]] || files+=:docker-compose.suggestarr.yml

    cp "$source_dir/docker-compose.suggestarr.yml" "$install/docker-compose.suggestarr.yml"
    mkdir -p "$config_dir/suggestarr"
    tmp=$(mktemp "$install/.suggestarr-env.XXXXXXXX") || return 1
    chmod 600 "$tmp"
    sed -E '/^(SUGGESTARR_ENABLED|SUGGESTARR_PORT|SUGGESTARR_IMAGE|SUGGESTARR_LOG_LEVEL|COMPOSE_PROFILES|COMPOSE_FILE)=/d' "$env_file" >"$tmp"
    printf '\nSUGGESTARR_ENABLED="true"\nSUGGESTARR_PORT="%s"\nSUGGESTARR_IMAGE="%s"\nSUGGESTARR_LOG_LEVEL="%s"\nCOMPOSE_PROFILES="%s"\nCOMPOSE_FILE="%s"\n' \
        "$port" "$image" "$log_level" "$profiles" "$files" >>"$tmp"
    mv "$tmp" "$env_file"
    chmod 600 "$env_file" "$install/docker-compose.suggestarr.yml"
    echo "[INFO] SuggestArr overlay prepared on port ${port}."
}
