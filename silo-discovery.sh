#!/usr/bin/env bash
set -Eeuo pipefail

# Silo watch-history discovery -> Radarr importer.
#
# This is intentionally a small, optional companion to the main stack.  It
# talks to Silo's Jellyfin-compatible HTTP API for watched movies and similar
# titles, then asks Radarr to add/search a bounded number of movies.  It never
# enables AIOStreams and it does not change Decypharr's storage settings.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${TORBOX_ENV_FILE:-${SCRIPT_DIR}/.env}"
STATE_DIR="${TORBOX_DISCOVERY_STATE_DIR:-${SCRIPT_DIR}/configs/silo-discovery}"
STATE_FILE="${STATE_DIR}/state.json"
LOCK_FILE="${STATE_DIR}/run.lock"

if [[ -f "${SCRIPT_DIR}/lib/env.sh" ]]; then
    # shellcheck source=lib/env.sh
    source "${SCRIPT_DIR}/lib/env.sh"
else
    env_val() {
        local key="$1" file="${2:-${ENV_FILE}}"
        [[ -f "$file" ]] || return 1
        grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- |
            sed 's/[[:space:]]#.*$//' | tr -d '"' | tr -d "'" | tr -d '\r' |
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    }
fi

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARN: $*" >&2; }
die() { log "ERROR: $*" >&2; exit 1; }
cfg() { env_val "$1" "$ENV_FILE" 2>/dev/null || true; }

require_tools() {
    command -v curl >/dev/null 2>&1 || die "curl is required."
    command -v jq >/dev/null 2>&1 || die "jq is required. Install jq and retry."
    [[ -f "$ENV_FILE" ]] || die "Missing installed environment file: $ENV_FILE"
}

SILO_JF_URL="$(cfg SILO_DISCOVERY_JF_URL)"
SILO_JF_URL="${SILO_JF_URL:-http://127.0.0.1:${SILO_JF_PORT:-8097}}"
SILO_DISCOVERY_USER="$(cfg SILO_DISCOVERY_USER)"
SILO_DISCOVERY_PASS="$(cfg SILO_DISCOVERY_PASS)"
RADARR_URL="$(cfg SILO_DISCOVERY_RADARR_URL)"
RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
RADARR_API_KEY="$(cfg RADARR_API_KEY)"
BATCH_SIZE="$(cfg SILO_DISCOVERY_BATCH_SIZE)"
BATCH_SIZE="${BATCH_SIZE:-8}"
DAILY_LIMIT="$(cfg SILO_DISCOVERY_DAILY_LIMIT)"
DAILY_LIMIT="${DAILY_LIMIT:-192}"
LOOKBACK="$(cfg SILO_DISCOVERY_LOOKBACK)"
LOOKBACK="${LOOKBACK:-20}"
QUALITY_PROFILE="$(cfg SILO_DISCOVERY_QUALITY_PROFILE)"
QUALITY_PROFILE="${QUALITY_PROFILE:-Any}"
ROOT_FOLDER="$(cfg SILO_DISCOVERY_ROOT_FOLDER)"
ROOT_FOLDER="${ROOT_FOLDER:-/data/media/movies}"

validate_config() {
    [[ "$(cfg SILO_DISCOVERY_ENABLED)" == "true" ]] || die "Silo discovery is disabled. Run setup-fixed.sh --add-silo-discovery to enable it."
    [[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]] || die "SILO_DISCOVERY_BATCH_SIZE must be a positive integer."
    [[ "$DAILY_LIMIT" =~ ^[1-9][0-9]*$ ]] || die "SILO_DISCOVERY_DAILY_LIMIT must be a positive integer."
    [[ "$LOOKBACK" =~ ^[1-9][0-9]*$ ]] || die "SILO_DISCOVERY_LOOKBACK must be a positive integer."
    (( BATCH_SIZE <= DAILY_LIMIT )) || die "Batch size cannot exceed the daily limit."
    [[ "$ROOT_FOLDER" == /* && "$ROOT_FOLDER" != *[[:space:]]* ]] || die "SILO_DISCOVERY_ROOT_FOLDER must be an absolute path without spaces."
    [[ "$SILO_JF_URL" =~ ^https?://[^[:space:]]+$ ]] || die "SILO_DISCOVERY_JF_URL must start with http:// or https://."
    [[ "$RADARR_URL" =~ ^https?://[^[:space:]]+$ ]] || die "SILO_DISCOVERY_RADARR_URL must start with http:// or https://."
    [[ -n "$SILO_DISCOVERY_USER" && -n "$SILO_DISCOVERY_PASS" ]] || die "Silo discovery credentials are missing. Run setup-fixed.sh --add-silo-discovery."
    [[ "$RADARR_API_KEY" =~ ^[A-Za-z0-9._-]+$ ]] || die "RADARR_API_KEY is missing or malformed."
}

ensure_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    if [[ ! -s "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        printf '%s\n' '{"date":"","added":0,"last_run":"","seen":[]}' >"$STATE_FILE"
        chmod 600 "$STATE_FILE"
    fi
}

state_value() { jq -r "$1" "$STATE_FILE"; }

state_reset_if_needed() {
    local today current
    today="$(date +%F)"
    current="$(state_value '.date // ""')"
    if [[ "$current" != "$today" ]]; then
        local tmp
        tmp=$(mktemp "${STATE_FILE}.XXXXXX")
        jq --arg today "$today" '.date=$today | .added=0 | .last_run=(now|todate) | .seen=(.seen // [])' "$STATE_FILE" >"$tmp"
        mv "$tmp" "$STATE_FILE"
        chmod 600 "$STATE_FILE"
    fi
}

state_add_seen() {
    local tmdb="$1" tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq --arg tmdb "$tmdb" '.seen=((.seen // []) + [$tmdb] | unique | .[-1000:])' "$STATE_FILE" >"$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

state_increment() {
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq '.added=((.added // 0)+1) | .last_run=(now|todate)' "$STATE_FILE" >"$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

jellyfin_get() {
    local path="$1"
    local -a args=(curl -fsS --connect-timeout 5 --max-time 30
        -H "X-Emby-Authorization: MediaBrowser Client=\"TorBox Discovery\", Device=\"TorBox\", DeviceId=\"torbox-silo-discovery\", Version=\"1.0\"")
    [[ -n "${DISCOVERY_TOKEN:-}" ]] && args+=(-H "X-Emby-Token: ${DISCOVERY_TOKEN}" -H "X-MediaBrowser-Token: ${DISCOVERY_TOKEN}")
    args+=(-H 'Accept: application/json' "${SILO_JF_URL%/}${path}")
    "${args[@]}"
}

radarr_get() {
    local path="$1"
    curl -fsS --connect-timeout 5 --max-time 30 \
        -H "X-Api-Key: ${RADARR_API_KEY}" -H 'Accept: application/json' \
        "${RADARR_URL%/}${path}"
}

radarr_post() {
    local path="$1" body="$2"
    curl -sS --connect-timeout 5 --max-time 45 \
        -H "X-Api-Key: ${RADARR_API_KEY}" -H 'Content-Type: application/json' \
        -X POST "${RADARR_URL%/}${path}" -d "$body" -w $'\n%{http_code}'
}

authenticate_silo() {
    local body response code auth_user candidate
    local -a candidates=("$SILO_DISCOVERY_USER")
    # Silo's compatibility layer commonly identifies a profile as
    # username#profile.  If the operator entered only the account name, try
    # the common same-name profile before reporting the 401.  An explicit
    # username#profile value is always used as-is.
    if [[ "$SILO_DISCOVERY_USER" != *#* ]]; then
        candidates+=("${SILO_DISCOVERY_USER}#${SILO_DISCOVERY_USER}")
    fi
    for candidate in "${candidates[@]}"; do
        auth_user="$candidate"
        body=$(jq -cn --arg user "$auth_user" --arg pass "$SILO_DISCOVERY_PASS" '{Username:$user,Pw:$pass}')
        response=$(curl -sS --connect-timeout 5 --max-time 30 \
            -H 'Content-Type: application/json' \
            -H 'X-Emby-Authorization: MediaBrowser Client="TorBox Discovery", Device="TorBox", DeviceId="torbox-silo-discovery", Version="1.0"' \
            -X POST "${SILO_JF_URL%/}/Users/AuthenticateByName" -d "$body" \
            -w $'\n%{http_code}') || true
        code="${response##*$'\n'}"
        response="${response%$'\n'*}"
        if [[ "$code" == 2* ]]; then
            DISCOVERY_TOKEN=$(jq -r '.AccessToken // empty' <<<"$response")
            DISCOVERY_USER_ID=$(jq -r '.User.Id // empty' <<<"$response")
            if [[ -n "$DISCOVERY_TOKEN" && -n "$DISCOVERY_USER_ID" ]]; then
                [[ "$auth_user" == "$SILO_DISCOVERY_USER" ]] || log "Silo accepted the compatibility username#profile form (${auth_user%%#*}#...)."
                return 0
            fi
        fi
    done
    warn "Silo Jellyfin-compatible login failed (HTTP 401). Use the Silo compatibility username as username#profile (for example admin#admin) and verify the password."
    return 1
}

discover_candidates() {
    local watched similar recommendations item_id
    watched=$(jellyfin_get "/Users/${DISCOVERY_USER_ID}/Items?IsPlayed=true&IncludeItemTypes=Movie&Recursive=true&SortBy=DatePlayed&SortOrder=Descending&Limit=${LOOKBACK}&Fields=ProviderIds" 2>/dev/null) || {
        warn "Silo did not return watched movies. Enable Jellyfin compatibility and check the account's library access."; return 1;
    }
    recommendations='[]'
    while IFS= read -r item_id; do
        [[ -n "$item_id" ]] || continue
        similar=$(jellyfin_get "/Items/${item_id}/Similar?UserId=${DISCOVERY_USER_ID}&IncludeItemTypes=Movie&Limit=25&Fields=ProviderIds" 2>/dev/null || true)
        if [[ -n "$similar" ]]; then
            similar=$(jq -c 'if type=="array" then . else (.Items // []) end' <<<"$similar" 2>/dev/null || echo '[]')
            recommendations=$(jq -nc --argjson a "$recommendations" --argjson b "$similar" '$a+$b' 2>/dev/null || echo '[]')
        fi
    done < <(jq -r '.Items[]?.Id // empty' <<<"$watched")

    # Some compatible servers expose Recommendations but not /Similar.  Use it
    # as a fallback so a missing optional endpoint does not make the feature
    # unusable.
    if [[ "$recommendations" == '[]' ]]; then
        recommendations=$(jellyfin_get "/Movies/Recommendations?UserId=${DISCOVERY_USER_ID}&Limit=100&Fields=ProviderIds" 2>/dev/null || echo '[]')
        recommendations=$(jq -c 'if type=="array" then map(.Items // .) | add else (.Items // []) end' <<<"$recommendations" 2>/dev/null || echo '[]')
    fi
    jq -c 'map(select((.Type // "Movie") == "Movie" and (.ProviderIds.Tmdb // .ProviderIds.tmdb // "") != "")) | unique_by((.ProviderIds.Tmdb // .ProviderIds.tmdb)|tostring)' <<<"$recommendations"
}

choose_quality_profile() {
    local profiles profile_id
    profiles=$(radarr_get '/api/v3/qualityprofile') || { warn 'Radarr quality profiles could not be read.'; return 1; }
    profile_id=$(jq -r --arg name "$QUALITY_PROFILE" '[.[] | select(.name == $name)][0].id // empty' <<<"$profiles")
    if [[ -z "$profile_id" ]]; then
        profile_id=$(jq -r '[.[] | select(.name|test("4k|uhd|any";"i"))][0].id // empty' <<<"$profiles")
        [[ -n "$profile_id" ]] && warn "Quality profile '$QUALITY_PROFILE' was not found; using a matching 4K/Any profile."
    fi
    [[ "$profile_id" =~ ^[0-9]+$ ]] || { warn "Quality profile '$QUALITY_PROFILE' was not found. Set SILO_DISCOVERY_QUALITY_PROFILE to an existing Radarr profile."; return 1; }
    printf '%s' "$profile_id"
}

add_candidate() {
    local item="$1" profile_id="$2" tmdb title year lookup movie payload response code
    tmdb=$(jq -r '.ProviderIds.Tmdb // .ProviderIds.tmdb // empty' <<<"$item")
    title=$(jq -r '.Name // empty' <<<"$item")
    year=$(jq -r '.ProductionYear // 0' <<<"$item")
    [[ "$tmdb" =~ ^[0-9]+$ ]] || return 1
    [[ "$year" =~ ^[0-9]+$ ]] || year=0

    if jq -e --arg tmdb "$tmdb" 'any(.[]; tostring == $tmdb)' <<<"${EXISTING_TMDB_IDS:-[]}" >/dev/null 2>&1; then
        return 2
    fi
    if jq -e --arg tmdb "$tmdb" 'any(.seen[]?; tostring == $tmdb)' "$STATE_FILE" >/dev/null 2>&1; then
        return 2
    fi

    lookup=$(radarr_get "/api/v3/movie/lookup/tmdb?tmdbId=${tmdb}" 2>/dev/null || true)
    movie=$(jq -c 'if type=="array" then .[0] else . end' <<<"$lookup" 2>/dev/null || echo '')
    [[ -n "$movie" && "$movie" != null && "$(jq -r '.title // .Title // empty' <<<"$movie")" != '' ]] || {
        warn "Radarr could not resolve TMDB ${tmdb} (${title:-unknown}); skipping."; return 1;
    }
    payload=$(jq -c --arg root "$ROOT_FOLDER" --argjson profile "$profile_id" \
        'del(.id) | .qualityProfileId=$profile | .rootFolderPath=$root | .monitored=true | .addOptions={monitor:"movieOnly",searchForMovie:true}' <<<"$movie")
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log "DRY RUN: would add/search TMDB ${tmdb} (${title:-unknown}, ${year}) using profile ${QUALITY_PROFILE}."
        return 0
    fi
    response=$(radarr_post '/api/v3/movie' "$payload") || true
    code="${response##*$'\n'}"
    response="${response%$'\n'*}"
    if [[ "$code" == 2* ]]; then
        log "Added/searching ${title:-TMDB ${tmdb}} (${year}) via Radarr."
        EXISTING_TMDB_IDS=$(jq -c --arg tmdb "$tmdb" '. + [$tmdb]' <<<"${EXISTING_TMDB_IDS:-[]}")
        state_add_seen "$tmdb"
        state_increment
        return 0
    fi
    warn "Radarr rejected ${title:-TMDB ${tmdb}} (HTTP ${code:-unknown}); it will be eligible again on a later run."
    return 1
}

run_once() {
    require_tools
    command -v flock >/dev/null 2>&1 || die "flock is required (provided by util-linux)."
    validate_config
    ensure_state
    state_reset_if_needed
    local added_today remaining profile_id movies item result
    added_today=$(state_value '.added // 0')
    remaining=$((DAILY_LIMIT - added_today))
    (( remaining > 0 )) || { log "Daily limit of ${DAILY_LIMIT} reached; waiting for the next day."; return 0; }
    (( remaining < BATCH_SIZE )) && BATCH_SIZE=$remaining

    authenticate_silo || return 1
    EXISTING_TMDB_IDS=$(radarr_get '/api/v3/movie' | jq -c '[.[]?.tmdbId // empty | tostring]') || {
        warn 'Radarr movies could not be read.'; return 1;
    }
    profile_id=$(choose_quality_profile) || return 1
    movies=$(discover_candidates) || return 1
    [[ -n "$movies" ]] || { log 'No Silo recommendations were available in this run.'; return 0; }

    added=0
    while IFS= read -r item; do
        (( added >= BATCH_SIZE )) && break
        add_candidate "$item" "$profile_id" && added=$((added + 1)) || result=$?
    done < <(jq -c '.[]' <<<"$movies")
    log "Discovery run complete: ${added}/${BATCH_SIZE} movies added or queued."
}

status() {
    require_tools
    ensure_state
    printf 'Silo discovery: %s\n' "$(cfg SILO_DISCOVERY_ENABLED)"
    printf 'Schedule: up to %s per hour, %s per day\n' "$BATCH_SIZE" "$DAILY_LIMIT"
    printf 'Quality profile: %s\n' "$QUALITY_PROFILE"
    printf 'Silo compatibility URL: %s\n' "$SILO_JF_URL"
    printf 'State: %s\n' "$(cat "$STATE_FILE")"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-enabled torbox-silo-discovery.timer 2>/dev/null || true
        systemctl is-active torbox-silo-discovery.timer 2>/dev/null || true
    fi
}

main() {
    local command="${1:-once}"
    case "$command" in
        once) mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"; exec 9>"$LOCK_FILE"; flock -n 9 || { log 'Another discovery run is already active.'; exit 0; }; run_once ;;
        --dry-run) DRY_RUN=true; mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"; exec 9>"$LOCK_FILE"; flock -n 9 || exit 0; run_once ;;
        status) status ;;
        *) die "Usage: $0 [once|--dry-run|status]" ;;
    esac
}

main "$@"
