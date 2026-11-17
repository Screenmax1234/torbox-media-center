#!/usr/bin/env bash
# Optional Listseerr deployment helpers. Callers source lib/env.sh first.

listseerr_prepare() {
    local install="$1" source_dir="$2" env_file="$1/.env"
    local profiles files entry found tmp port image log_level config_dir key
    local -a file_entries

    port="${TORBOX_LISTSEERR_PORT:-${LISTSEERR_PORT:-$(env_val LISTSEERR_PORT "$env_file" || true)}}"
    port="${port:-3001}"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
        echo "[ERROR] LISTSEERR_PORT must be a valid TCP port." >&2
        return 1
    }
    image="${TORBOX_LISTSEERR_IMAGE:-${LISTSEERR_IMAGE:-$(env_val LISTSEERR_IMAGE "$env_file" || true)}}"
    image="${image:-ghcr.io/guillevc/listseerr:latest}"
    log_level="${TORBOX_LISTSEERR_LOG_LEVEL:-${LISTSEERR_LOG_LEVEL:-$(env_val LISTSEERR_LOG_LEVEL "$env_file" || true)}}"
    log_level="${log_level:-info}"
    key="${TORBOX_LISTSEERR_ENCRYPTION_KEY:-${LISTSEERR_ENCRYPTION_KEY:-$(env_val LISTSEERR_ENCRYPTION_KEY "$env_file" || true)}}"
    if [[ -z "$key" ]]; then
        key="$(openssl rand -hex 32 2>/dev/null || true)"
    fi
    [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]] || {
        echo "[ERROR] LISTSEERR_ENCRYPTION_KEY must be 64 hexadecimal characters." >&2
        return 1
    }
    config_dir=$(env_val CONFIG_DIR "$env_file" || true)
    [[ "$config_dir" == /* ]] || config_dir="$install/${config_dir:-configs}"

    profiles=$(env_val COMPOSE_PROFILES "$env_file" || true)
    case ",$profiles," in *,listseerr,*) ;; *) profiles="${profiles:+$profiles,}listseerr" ;; esac
    files=$(env_val COMPOSE_FILE "$env_file" || true)
    if [[ -z "$files" ]]; then
        files=docker-compose.yml
        [[ -f "$install/docker-compose.override.yml" ]] && files+=:docker-compose.override.yml
        [[ -f "$install/docker-compose.override.yaml" && ! -f "$install/docker-compose.override.yml" ]] && files+=:docker-compose.override.yaml
    fi
    found=false
    IFS=: read -ra file_entries <<<"$files"
    for entry in "${file_entries[@]}"; do
        [[ "$entry" == docker-compose.listseerr.yml || "$entry" == "$install/docker-compose.listseerr.yml" ]] && found=true
    done
    [[ "$found" == true ]] || files+=:docker-compose.listseerr.yml

    cp "$source_dir/docker-compose.listseerr.yml" "$install/docker-compose.listseerr.yml"
    mkdir -p "$config_dir/listseerr"
    tmp=$(mktemp "$install/.listseerr-env.XXXXXXXX") || return 1
    chmod 600 "$tmp"
    sed -E '/^(LISTSEERR_ENABLED|LISTSEERR_PORT|LISTSEERR_IMAGE|LISTSEERR_LOG_LEVEL|LISTSEERR_ENCRYPTION_KEY|COMPOSE_PROFILES|COMPOSE_FILE)=/d' "$env_file" >"$tmp"
    printf '\nLISTSEERR_ENABLED="true"\nLISTSEERR_PORT="%s"\nLISTSEERR_IMAGE="%s"\nLISTSEERR_LOG_LEVEL="%s"\nLISTSEERR_ENCRYPTION_KEY="%s"\nCOMPOSE_PROFILES="%s"\nCOMPOSE_FILE="%s"\n' \
        "$port" "$image" "$log_level" "$key" "$profiles" "$files" >>"$tmp"
    mv "$tmp" "$env_file"
    chmod 600 "$env_file" "$install/docker-compose.listseerr.yml"
    echo "[INFO] Listseerr overlay prepared on port ${port}."
}
