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

# Configure the first-run Silo account and the two media libraries through
# Silo's current native v2 API. The endpoint contracts are part of Silo's
# source/docs (POST /api/v2/auth/setup and POST /api/v2/libraries). Existing
# accounts and libraries are detected and left untouched.
configure_silo() {
    [[ "${SILO_ENABLED:-false}" == "true" ]] || return 0

    local base="http://localhost:${SILO_HTTP_PORT:-8090}"
    local setup_status needs_setup token setup_body setup_response setup_code
    local login_body login_response login_code libraries library_type library_name library_path
    local existing_count create_body create_response create_code

    if ! command -v jq &>/dev/null; then
        log_warn "Silo auto-configuration requires jq; finish Silo onboarding and libraries in its web UI."
        return 1
    fi

    log_step "Auto-configuring Silo..."
    # The omnibus image may run PostgreSQL migrations before it is ready. Keep
    # this aligned with the Compose healthcheck's 20-minute start period so a
    # slow first boot does not unnecessarily fall back to manual onboarding.
    local elapsed=0
    while [[ $elapsed -lt 1200 ]]; do
        if curl -sf --connect-timeout 3 --max-time 10 "${base}/api/v1/ready" -o /dev/null 2>/dev/null; then
            break
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    if [[ $elapsed -ge 1200 ]]; then
        log_warn "Silo did not become ready within 20 minutes; its web onboarding remains available at ${base}."
        return 1
    fi

    setup_status=$(curl -sf --connect-timeout 5 --max-time 15 "${base}/api/v2/system/setup" 2>/dev/null) || true
    if [[ -z "$setup_status" ]]; then
        # Older prerelease images expose the same setup state on the v1 bridge.
        setup_status=$(curl -sf --connect-timeout 5 --max-time 15 "${base}/api/v1/auth/setup" 2>/dev/null) || true
    fi
    needs_setup=$(echo "$setup_status" | jq -r '.needs_setup // .needsSetup // empty' 2>/dev/null) || true
    if [[ "$needs_setup" != true && "$needs_setup" != false ]]; then
        log_warn "Could not read Silo setup status; finish onboarding at ${base} and rerun setup.sh."
        return 1
    fi

    if [[ "$needs_setup" == true ]]; then
        setup_body=$(jq -cn \
            --arg username "${SILO_ADMIN_USER:-admin}" \
            --arg email "${SILO_ADMIN_EMAIL:-admin@torbox.local}" \
            --arg password "${SILO_ADMIN_PASS:-}" \
            '{username:$username,email:$email,password:$password,create_default_profile:true}')
        setup_response=$(curl -sS --connect-timeout 5 --max-time 30 \
            -H 'Content-Type: application/json' \
            -X POST "${base}/api/v2/auth/setup" -d "$setup_body" \
            -w $'\n%{http_code}' 2>/dev/null) || true
        setup_code="${setup_response##*$'\n'}"
        setup_response="${setup_response%$'\n'*}"
        token=$(echo "$setup_response" | jq -r '.access_token // empty' 2>/dev/null) || true
        if [[ "$setup_code" != 201 || -z "$token" ]]; then
            log_warn "Silo first-admin setup did not complete (HTTP ${setup_code:-unknown})."
            log_warn "Open ${base}, complete onboarding, then rerun setup.sh to retry library setup."
            return 1
        fi
        log_info "Silo admin account created (username: ${SILO_ADMIN_USER:-admin})."
    else
        login_body=$(jq -cn \
            --arg username "${SILO_ADMIN_USER:-admin}" \
            --arg password "${SILO_ADMIN_PASS:-}" \
            '{username:$username,password:$password}')
        login_response=$(curl -sS --connect-timeout 5 --max-time 30 \
            -H 'Content-Type: application/json' \
            -X POST "${base}/api/v2/auth/login" -d "$login_body" \
            -w $'\n%{http_code}' 2>/dev/null) || true
        login_code="${login_response##*$'\n'}"
        login_response="${login_response%$'\n'*}"
        token=$(echo "$login_response" | jq -r '.access_token // empty' 2>/dev/null) || true
        if [[ "$login_code" != 200 || -z "$token" ]]; then
            log_warn "Silo already has an account, but the saved installer credentials did not authenticate."
            log_warn "Log in at ${base} manually, or set TORBOX_SILO_ADMIN_USER and TORBOX_SILO_ADMIN_PASS, then rerun setup.sh."
            return 1
        fi
        log_info "Silo admin account already exists; preserved it."
    fi

    libraries=$(curl -sf --connect-timeout 5 --max-time 20 \
        -H "Authorization: Bearer ${token}" "${base}/api/v2/libraries" 2>/dev/null) || true
    if [[ -z "$libraries" ]]; then
        log_warn "Silo libraries could not be read with the admin session; finish them in the web UI."
        return 1
    fi

    while IFS=$'\t' read -r library_type library_name library_path; do
        existing_count=$(echo "$libraries" | jq --arg type "$library_type" --arg path "$library_path" \
            '[.items[]? | select(.type == $type and ((.paths // []) | index($path) != null))] | length' 2>/dev/null) || existing_count=0
        if [[ "$existing_count" -gt 0 ]]; then
            log_info "Silo library already exists: ${library_name}."
            continue
        fi
        create_body=$(jq -cn --arg type "$library_type" --arg name "$library_name" --arg path "$library_path" \
            '{paths:[$path],type:$type,name:$name,metadata_language:"en",realtime_monitoring:true}')
        create_response=$(curl -sS --connect-timeout 5 --max-time 45 \
            -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
            -X POST "${base}/api/v2/libraries" -d "$create_body" \
            -w $'\n%{http_code}' 2>/dev/null) || true
        create_code="${create_response##*$'\n'}"
        create_response="${create_response%$'\n'*}"
        if [[ "$create_code" == 201 ]]; then
            log_info "Silo library created: ${library_name} (${library_path})."
            libraries=$(printf '%s' "$libraries" | jq --arg type "$library_type" --arg name "$library_name" --arg path "$library_path" \
                '.items += [{type:$type,name:$name,paths:[$path]}]' 2>/dev/null) || true
        else
            log_warn "Silo could not create ${library_name} (HTTP ${create_code:-unknown}); configure it at ${base}."
            return 1
        fi
    done <<'LIBRARIES'
movies	Movies	/data/media/movies
series	TV Shows	/data/media/tv
LIBRARIES

    log_info "Silo account and media libraries are configured."
    return 0
}
