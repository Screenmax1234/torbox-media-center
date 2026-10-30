#!/usr/bin/env bash
# Authenticated Seerr connection setup shared by the installer and diagnostics.

seerr_request() {
    local method="$1" path="$2" payload="${3:-}"
    local args=(-sf --connect-timeout 5 --max-time 30
        -H "X-Api-Key: ${SEERR_CONNECTION_KEY}" -H 'Content-Type: application/json'
        -X "$method")
    [[ -n "$payload" ]] && args+=(--data-binary "$payload")
    curl "${args[@]}" "${SEERR_CONNECTION_URL}${path}" 2>/dev/null
}

seerr_connect() {
    SEERR_CONNECTION_URL="$1"
    local config_dir="$2" public
    if ! command -v jq >/dev/null 2>&1; then
        echo '[FAIL] jq is required for Seerr connection setup.'
        return 1
    fi
    SEERR_CONNECTION_KEY=$(jq -er '.main.apiKey | select(type == "string" and length > 0)' \
        "${config_dir}/seerr/settings.json" 2>/dev/null) || {
        echo '[FAIL] Cannot read Seerr API key. Complete its web setup wizard first.'
        return 1
    }
    public=$(seerr_request GET /api/v1/settings/public) || {
        echo '[FAIL] Seerr did not respond.'
        return 1
    }
    if ! jq -e '.initialized == true' <<<"$public" >/dev/null 2>&1; then
        echo '[FAIL] Complete the Seerr web setup wizard, then retry.'
        return 1
    fi
    if ! seerr_request GET /api/v1/settings/main >/dev/null; then
        echo '[FAIL] Seerr rejected its stored API key; check for a container API_KEY override.'
        return 1
    fi
}

# Test from Seerr's network before writing; keep existing profile, root folder,
# hostname, port, anime/4K options and library choices when refreshing a key.
seerr_sync_arr() {
    local service="$1" api_key="$2" repair="${3:-false}"
    local port=7878 root='/data/media/movies' records matches record payload result method path
    [[ "$service" == sonarr ]] && port=8989 && root='/data/media/tv'
    records=$(seerr_request GET "/api/v1/settings/${service}") || {
        echo "[FAIL] Cannot read Seerr's ${service} settings."
        return 1
    }
    if ! jq -e 'type == "array"' <<<"$records" >/dev/null 2>&1; then
        echo "[FAIL] Invalid Seerr ${service} settings response."
        return 1
    fi
    matches=$(jq --arg service "$service" '[.[] | select(
        .hostname == $service or ((.name // "" | ascii_downcase) == $service))]' <<<"$records")
    if [[ $(jq length <<<"$matches") -gt 1 ]]; then
        echo "[FAIL] Multiple Seerr ${service} entries match; select the intended one in its web UI."
        return 1
    fi
    record=$(jq -c '.[0] // empty' <<<"$matches")
    if [[ -z "$record" ]] && [[ $(jq length <<<"$records") -gt 0 ]]; then
        echo "[WARN] Custom Seerr ${service} entries found; review them in its web UI."
        return 1
    fi
    if [[ -n "$record" ]]; then
        payload="$record"
        if [[ "$repair" == true ]]; then
            payload=$(jq --arg key "$api_key" '.apiKey = $key' <<<"$record")
        fi
        method=PUT
        path="/api/v1/settings/${service}/$(jq -r .id <<<"$record")"
    else
        if [[ "$repair" != true ]]; then
            echo "[FAIL] ${service} is missing from Seerr."
            return 1
        fi
        payload=$(jq -n --arg service "$service" --arg key "$api_key" --arg root "$root" --argjson port "$port" \
            '{name: $service, hostname: $service, port: $port, apiKey: $key,
              useSsl: false, baseUrl: "", activeDirectory: $root, is4k: false,
              tags: [], isDefault: true, externalUrl: ""}
             + if $service == "radarr" then {minimumAvailability: "released"} else {} end')
        method=POST
        path="/api/v1/settings/${service}"
    fi
    result=$(seerr_request POST "/api/v1/settings/${service}/test" "$payload") || {
        echo "[FAIL] Seerr cannot connect to ${service} with these settings (key, hostname or port)."
        return 1
    }
    if [[ "$repair" != true ]]; then
        echo "[OK] Seerr -> ${service}: connection test passed."
        return 0
    fi
    if [[ -n "$record" ]] && jq -e --arg key "$api_key" '.apiKey == $key' <<<"$record" >/dev/null; then
        echo "[OK] Seerr -> ${service}: connection test passed; settings are current."
        return 0
    fi
    if [[ -z "$record" ]]; then
        # Use real profiles/root folders returned by Seerr's connection test.
        if ! jq -e '.profiles[0].id != null and (.rootFolders | length > 0)' <<<"$result" >/dev/null 2>&1; then
            echo "[FAIL] ${service} needs a quality profile and root folder before adding it to Seerr."
            return 1
        fi
        payload=$(jq --argjson result "$result" '.activeProfileId = $result.profiles[0].id
            | .activeProfileName = $result.profiles[0].name
            | .activeDirectory as $wanted
            | .activeDirectory = (if any($result.rootFolders[]; .path == $wanted)
                then .activeDirectory else $result.rootFolders[0].path end)' <<<"$payload")
    fi
    if ! seerr_request "$method" "$path" "$payload" >/dev/null; then
        echo "[FAIL] Seerr tested ${service}, but saving its settings failed."
        return 1
    fi
    echo "[OK] Seerr -> ${service}: tested and saved."
}
