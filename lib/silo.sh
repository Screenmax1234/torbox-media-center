#!/usr/bin/env bash
# Optional Silo deployment helpers. Callers source lib/env.sh first.

silo_check_host() {
    local gpu="${TORBOX_SILO_GPU:-dri}" dev version
    case "$gpu" in
        dri)
            local found=false
            for dev in /dev/dri/renderD*; do
                [[ -c "$dev" ]] && found=true
            done
            if [[ "$found" != true ]]; then
                echo '[ERROR] No /dev/dri/renderD* character device found. Pass the GPU into the Linux host/LXC first, or set TORBOX_SILO_GPU=none for a CPU-only trial.' >&2
                return 1
            fi
            ;;
        none) ;;
        *)
            echo '[ERROR] TORBOX_SILO_GPU must be dri (Intel/AMD, default) or none.' >&2
            return 1
            ;;
    esac
    version=$(docker compose version --short) || return 1
    version="${version#v}"
    if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+) ]] ||
        ((BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 24))); then
        echo '[ERROR] Silo requires Docker Compose 2.24 or newer.' >&2
        return 1
    fi
}

# Prepare the optional overlays and extend the .env Compose file list. Existing
# configs, image pins, hardware override and credentials are never rewritten.
silo_prepare() {
    local install="$1" source_dir="$2" env_file="$1/.env"
    local key profiles files uid gid gpu entry item found config_dir work_dir
    local -a file_entries
    config_dir=$(env_val CONFIG_DIR "$env_file")
    [[ "$config_dir" == /* ]] || config_dir="$install/$config_dir"
    key=$(env_val SILO_SECRET_KEY "$env_file" || true)
    if [[ -z "$key" ]]; then
        # Never invent another encryption key for an existing Silo database.
        if [[ -d "$config_dir/silo" ]] && [[ -n $(ls -A "$config_dir/silo") ]]; then
            echo '[ERROR] Silo data exists but SILO_SECRET_KEY is missing. Restore the original key before continuing.' >&2
            return 1
        fi
        key=$(openssl rand -base64 48) || return 1
    fi
    if [[ ${#key} -lt 32 || ! "$key" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
        echo '[ERROR] SILO_SECRET_KEY must be a generated key of at least 32 characters.' >&2
        return 1
    fi
    gpu=$(env_val SILO_GPU "$env_file" || true)
    gpu="${TORBOX_SILO_GPU:-${gpu:-dri}}"
    uid=$(env_val SILO_PUID "$env_file" || true)
    gid=$(env_val SILO_PGID "$env_file" || true)
    if [[ -z "$uid" ]]; then
        uid=$(env_val PUID "$env_file" || true)
        # Silo refuses UID 0 (already occupied by root in its image).
        [[ -z "$uid" || "$uid" == 0 ]] && uid=911
    fi
    if [[ -z "$gid" ]]; then
        gid=$(env_val PGID "$env_file" || true)
        [[ -z "$gid" || "$gid" == 0 ]] && gid=911
    fi
    if [[ ! "$uid" =~ ^[0-9]+$ || "$uid" == 0 || ! "$gid" =~ ^[0-9]+$ ]]; then
        echo '[ERROR] Silo needs numeric SILO_PUID/SILO_PGID and a nonzero SILO_PUID.' >&2
        return 1
    fi
    profiles=$(env_val COMPOSE_PROFILES "$env_file" || true)
    case ",$profiles," in *,silo,*) ;; *) profiles="${profiles:+$profiles,}silo" ;; esac
    files=$(env_val COMPOSE_FILE "$env_file" || true)
    if [[ -z "$files" ]]; then
        files=docker-compose.yml
        [[ -f "$install/docker-compose.override.yml" ]] && files+=:docker-compose.override.yml
        [[ -f "$install/docker-compose.override.yaml" && ! -f "$install/docker-compose.override.yml" ]] && files+=:docker-compose.override.yaml
    fi
    case "$gpu" in dri | none) ;; *)
        echo '[ERROR] Invalid Silo GPU setting.' >&2
        return 1
        ;;
    esac
    # Keep the operator's existing Compose list and avoid duplicate overlays.
    for entry in docker-compose.silo.yml docker-compose.silo-gpu.yml; do
        [[ "$entry" == *-gpu.yml && "$gpu" == none ]] && continue
        found=false
        IFS=: read -ra file_entries <<<"$files"
        for item in "${file_entries[@]}"; do
            [[ "$item" == "$entry" || "$item" == "$install/$entry" ]] && found=true
        done
        [[ "$found" == true ]] || files+=":$entry"
    done
    # Switching to CPU removes only our GPU fragment, never an operator override.
    if [[ "$gpu" == none ]]; then
        files=":$files:"
        files="${files//:docker-compose.silo-gpu.yml:/:}"
        files="${files//:$install\/docker-compose.silo-gpu.yml:/:}"
        files="${files#:}"
        files="${files%:}"
    fi
    cp "$source_dir/docker-compose.silo.yml" "$install/docker-compose.silo.yml"
    cp "$source_dir/docker-compose.silo-gpu.yml" "$install/docker-compose.silo-gpu.yml"
    # Strip only settings we own. Unrelated lines remain byte-for-byte unchanged.
    local tmp
    tmp=$(mktemp "$install/.silo-env.XXXXXXXX") || return 1
    chmod 600 "$tmp"
    sed -E '/^(SILO_SECRET_KEY|SILO_PUID|SILO_PGID|SILO_GPU|COMPOSE_PROFILES|COMPOSE_FILE)=/d' "$env_file" >"$tmp"
    printf '\nSILO_SECRET_KEY="%s"\nSILO_PUID="%s"\nSILO_PGID="%s"\nSILO_GPU="%s"\nCOMPOSE_PROFILES="%s"\nCOMPOSE_FILE="%s"\n' \
        "$key" "$uid" "$gid" "$gpu" "$profiles" "$files" >>"$tmp"
    mv "$tmp" "$env_file"
    chmod 600 "$env_file" "$install/docker-compose.silo.yml" "$install/docker-compose.silo-gpu.yml"
    work_dir=$(env_val SILO_WORK_DIR "$env_file" || true)
    work_dir="${work_dir:-$install/silo-work}"
    [[ "$work_dir" == /* ]] || work_dir="$install/$work_dir"
    mkdir -p "$config_dir/silo" "$work_dir/transcode" "$work_dir/download-artifacts"
    echo '[INFO] Silo overlays prepared. Save SILO_SECRET_KEY from .env separately in a password manager.'
}
