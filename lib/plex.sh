#!/usr/bin/env bash
# Configure import-triggered Plex scans without relying on FUSE file watching.

plex_notification_request() {
    local method="$1" endpoint="$2" payload="${3:-}"
    local args=(-sf --connect-timeout 5 --max-time 30 -X "$method"
        -H "X-Api-Key: ${plex_arr_key}" -H 'Content-Type: application/json')
    [[ -n "$payload" ]] && args+=(--data-binary "$payload")
    curl "${args[@]}" "${plex_arr_url}/api/v3/${endpoint}" 2>/dev/null
}

plex_sync_notification() {
    local name="$1" plex_arr_url="$2" plex_arr_key="$3" config_dir="$4" backup_dir="${5:-}"
    local prefs="${config_dir}/plex/Library/Application Support/Plex Media Server/Preferences.xml"
    local token records matches record payload schema method=POST endpoint=notification delete_field
    token=$(sed -n 's/.*PlexOnlineToken="\([^"][^"]*\)".*/\1/p' "$prefs" 2>/dev/null) || true
    if [[ -z "$token" ]]; then
        echo "[FAIL] ${name}: claim Plex first, then retry Plex notification repair."
        return 1
    fi
    records=$(plex_notification_request GET notification) || {
        echo "[FAIL] ${name}: cannot read notification settings. Check its API key and service status."
        return 1
    }
    if ! jq -e 'type == "array"' <<<"$records" >/dev/null 2>&1; then
        echo "[FAIL] ${name}: invalid notification response."
        return 1
    fi
    matches=$(jq '[.[] | select(.implementation == "PlexServer") | select(
        any(.fields[]?; .name == "host" and .value == "plex"))]' <<<"$records")
    if [[ $(jq length <<<"$matches") -gt 1 ]]; then
        echo "[FAIL] ${name}: multiple connections target Plex; review Settings -> Connect first."
        return 1
    fi
    record=$(jq -c '.[0] // empty' <<<"$matches")
    if [[ -z "$record" ]]; then
        if jq -e 'any(.[]; .implementation == "PlexServer")' <<<"$records" >/dev/null; then
            echo "[FAIL] ${name}: an existing Plex connection uses a custom host; review it in Settings -> Connect."
            return 1
        fi
        schema=$(plex_notification_request GET notification/schema) || {
            echo "[FAIL] ${name}: cannot read Plex notification schema."
            return 1
        }
        record=$(jq -ce '[.[] | select(.implementation == "PlexServer")][0] // empty' <<<"$schema") || {
            echo "[FAIL] ${name}: Plex notification schema not found."
            return 1
        }
        record=$(jq 'del(.id) | .name = "Plex" | .tags = []' <<<"$record")
    else
        method=PUT
        endpoint="notification/$(jq -r .id <<<"$record")"
    fi
    delete_field=onMovieFileDelete
    [[ "$name" == Sonarr ]] && delete_field=onEpisodeFileDelete
    payload=$(jq --arg token "$token" --arg deletion "$delete_field" '
        .onDownload = true | .onUpgrade = true | .onRename = true | .[$deletion] = true
        | .fields |= map(
            if .name == "host" then .value = "plex"
            elif .name == "port" then .value = 32400
            elif .name == "useSsl" then .value = false
            elif .name == "authToken" then .value = $token
            elif .name == "updateLibrary" then .value = true
            else . end)' <<<"$record") || return 1
    # This runs from the *arr container and validates its Plex connection.
    if ! plex_notification_request POST notification/test "$payload" >/dev/null; then
        echo "[FAIL] ${name} -> Plex: connection test failed; settings were not changed."
        return 1
    fi
    if [[ -n "$backup_dir" ]]; then
        if ! (
            umask 077
            printf '%s\n' "$records" >"${backup_dir}/${name,,}-notifications.json"
        ); then
            echo "[FAIL] ${name}: cannot back up notification settings; repair skipped."
            return 1
        fi
    fi
    if ! plex_notification_request "$method" "$endpoint" "$payload" >/dev/null; then
        echo "[FAIL] ${name}: Plex connection tested, but saving failed."
        return 1
    fi
    echo "[OK] ${name} -> Plex: tested and enabled library updates on import, upgrade and rename."
}
