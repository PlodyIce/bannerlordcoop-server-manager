# shellcheck shell=bash
#
# health.sh - `coop status` and `coop doctor`.
#
# status answers "what is it doing right now". doctor answers "why is it
# not doing what I expect". Both read the same sources and both can speak
# JSON, because a hosting backend needs exactly these two questions
# answered without a human in front of them.

# Each check is "status<TAB>category<TAB>name<TAB>detail".
declare -ga HEALTH_CHECKS=()
HEALTH_WORST=0   # 0 ok, 1 warning, 2 failure

_hc() {
    HEALTH_CHECKS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"${4:-}")
    case "$1" in
        fail) HEALTH_WORST=2 ;;
        warn) (( HEALTH_WORST < 1 )) && HEALTH_WORST=1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------ status --
status_report() {
    local running=0 phase="" health="" players=0 uptime=0 last_backup="" last_backup_age=0

    if container_exists && container_running; then
        running=1
        phase="$(server_phase)"
        health="$(container_health)"
        players="$(player_count)"
        uptime="$(container_uptime_seconds)"
    fi

    local f
    f="$(_backup_all_files | head -1)"
    if [[ -n "$f" ]]; then
        last_backup="$(basename "$f")"
        last_backup_age=$(( $(date +%s) - $(stat -c %Y "$f") ))
    fi

    # true or false when the build ships license terms, null when it has
    # none to accept.
    local license="null" bans
    if [[ -n "$(license_id "$DIR_SERVER")" ]]; then
        license_accepted_for "$DIR_SERVER" && license="true" || license="false"
    fi
    bans="$(bans_count)"

    if is_json; then
        local state="offline"
        (( running )) && case "$phase" in
            serving) state="online" ;;
            loading) state="loading" ;;
            boot)    state="starting" ;;
            *)       state="running" ;;
        esac
        jq -n \
            --arg status "$state" \
            --arg label "$(cfg SERVER_LABEL)" \
            --arg save "$(cfg SAVE_NAME)" \
            --arg campaign "$(pulse_time)" \
            --arg channel "$(cfg INSTALL_CHANNEL)" \
            --arg version "$(server_version)" \
            --arg manager "$MANAGER_VERSION" \
            --arg health "${health:-none}" \
            --arg backup "$last_backup" \
            --arg instance "$INSTANCE_ID" \
            --arg address "$(host_primary_address)" \
            --argjson players "${players:-0}" \
            --argjson port "$(cfg GAME_PORT)" \
            --argjson uptime "${uptime:-0}" \
            --argjson backup_age "${last_backup_age:-0}" \
            --argjson password "$( [[ -n "$(cfg SERVER_PASSWORD)" ]] && echo true || echo false )" \
            --argjson update "$( update_marker_is_set && echo true || echo false )" \
            --argjson license "$license" \
            --arg bans "$bans" \
            --arg exit_code "$( (( running )) || container_exitcode )" \
            --argjson save_exists "$( campaign_exists "$(cfg SAVE_NAME)" && echo true || echo false )" \
            --argjson campaigns "$(campaign_names | grep -c . || true)" \
            --argjson mods "$(_backup_mods_json)" \
            --argjson mods_update "$( mods_update_marker_is_set && echo true || echo false )" \
            '{
               ok:true, status:$status, instance:$instance, server_label:$label,
               save_name:$save, campaign_date:$campaign, players:$players,
               install_channel:$channel, coop_version:$version,
               manager_version:$manager, container_health:$health,
               game_port:$port, host_address:$address,
               password_set:$password, uptime_seconds:$uptime,
               last_backup:$backup, last_backup_age_seconds:$backup_age,
               update_available:$update, license_accepted:$license,
               save_exists:$save_exists, campaigns:$campaigns,
               mods:$mods, mods_update_available:$mods_update,
               banned_accounts:(if $bans == "invalid" then null else ($bans | tonumber) end),
               last_exit_code:(if $exit_code == "" or $exit_code == "?" then null else ($exit_code | tonumber) end)
             }'
        return 0
    fi

    out_title "$(cfg SERVER_LABEL)"

    if ! container_exists; then
        out_kv "Status" "NOT INSTALLED" "$C_YEL"
        out_line ""
        out_line "  Set the server up with: coop install"
        out_line ""
        return 0
    fi

    if (( running )); then
        case "$phase" in
            serving) out_kv "Status" "ONLINE" "$C_GRN" ;;
            loading) out_kv "Status" "LOADING CAMPAIGN" "$C_YEL" ;;
            boot)    out_kv "Status" "STARTING" "$C_YEL" ;;
            *)       out_kv "Status" "RUNNING (${health})" "$C_YEL" ;;
        esac
        out_kv "Uptime" "$(human_duration "$uptime")"
    else
        local code meaning
        code="$(container_exitcode)"
        meaning="$(exit_code_meaning "$code")"
        out_kv "Status" "OFFLINE" "$C_RED"
        out_kv "Last exit" "${code}${meaning:+  ($meaning)}"
    fi

    local campaign_note=""
    if ! campaign_exists "$(cfg SAVE_NAME)"; then
        if [[ "$(state_get new_world)" == "$(cfg SAVE_NAME)" ]]; then
            campaign_note="  (new world, created on the next start)"
        else
            campaign_note="  (no save: the server will not start. See: coop campaign list)"
        fi
    elif [[ -n "$(pulse_time)" ]]; then
        campaign_note="  ($(pulse_time))"
    fi
    out_kv "Campaign" "$(cfg SAVE_NAME)${campaign_note}"
    (( running )) && out_kv "Players" "$players$( [[ -n "$(pulse_field parties)" ]] && printf '  (%s parties)' "$(pulse_field parties)" )"
    out_kv "Connect to" "$(host_primary_address):$(cfg GAME_PORT)$( [[ -n "$(cfg SERVER_PASSWORD)" ]] && printf '  (password set)' || printf '  (no password)' )"
    out_kv "Install channel" "$( [[ "$(cfg INSTALL_CHANNEL)" == workshop ]] && printf 'Steam Workshop' || printf 'Custom build' )"
    out_kv "Coop build" "$(server_version)"
    mods_configured && out_kv "Mods" "$(_status_mods_line)"
    out_kv "Manager" "v$MANAGER_VERSION"

    out_line ""
    if (( running )); then
        local stats mem cpu
        stats="$(container_stats)"
        if [[ -n "$stats" ]]; then
            IFS=$'\t' read -r mem cpu <<<"$stats"
            out_kv "Memory" "$mem"
            out_kv "CPU" "$cpu"
        fi
    fi
    out_kv "Disk" "$(compat_disk_gb "$INSTALL_DIR") GB free"

    if [[ -n "$last_backup" ]]; then
        out_kv "Last backup" "$last_backup  ($(human_duration "$last_backup_age") ago)"
    else
        out_kv "Last backup" "none" "$C_YEL"
    fi
    out_kv "Automatic backups" "$( cfg_bool BACKUP_ENABLED && printf 'enabled (%s)' "$(cfg BACKUP_SCHEDULE)" || printf 'disabled' )"
    case "$bans" in
        0) ;;
        invalid) out_kv "Steam bans" "steam-bans.json is not valid JSON. See: coop doctor" "$C_YEL" ;;
        *)       out_kv "Steam bans" "$bans account(s). List them: coop ban" ;;
    esac

    # Only while it is down: a server that runs has had its terms accepted
    # one way or another, even if not through this manager.
    if [[ "$license" == "false" ]] && (( ! running )); then
        out_line ""
        out_line "  ${C_YEL}The license terms of this build have not been accepted${C_OFF}, so the"
        out_line "  server will not start. See: coop eula"
    fi
    if update_marker_is_set; then
        out_line ""
        out_line "  ${C_YEL}A Workshop update is available${C_OFF}. Install it with: coop update"
    fi
    if mods_update_marker_is_set; then
        out_line ""
        out_line "  ${C_YEL}Mod updates are available${C_OFF}. Players get them by themselves;"
        out_line "  install them before they are refused: coop mods update"
    fi
    out_line ""
}

# "8: Harmony, ButterLib, UIExtenderEx and 5 more", from what was recorded
# at installation, so status needs no XML tools.
_status_mods_line() {
    local names=() n shown=3
    mapfile -t names < <(_backup_mods_json | jq -r '.[] | .name // .module_id // .workshop_id' 2>/dev/null)
    n="${#names[@]}"
    if (( n <= shown + 1 )); then
        printf '%s: %s' "$n" "$(printf '%s, ' "${names[@]}" | sed 's/, $//')"
    else
        printf '%s: %s and %s more. See: coop mods' "$n" \
            "$(printf '%s, ' "${names[@]:0:$shown}" | sed 's/, $//')" "$(( n - shown ))"
    fi
}

# ------------------------------------------------------------------ doctor --
doctor_run() {
    HEALTH_CHECKS=(); HEALTH_WORST=0

    _doctor_system
    _doctor_docker

    # On a host with nothing installed, every remaining check has the same
    # cause. Reporting a dozen consequences of one fact buries it, so say
    # the fact once and stop. It still counts as a failure: automation
    # asking "is the server healthy" must not get a clean bill of health
    # from a machine that has no server on it.
    if ! installation_present; then
        if [[ -d "$INSTALL_DIR" && ! -x "$INSTALL_DIR" ]]; then
            _hc fail "Installation" "Not readable" \
                "$INSTALL_DIR exists but cannot be read as $(id -un). Try: sudo coop doctor"
        else
            _hc fail "Installation" "Not installed" \
                "no installation in $INSTALL_DIR. Create one with: sudo coop install"
        fi
    else
        _doctor_configuration
        _doctor_data
        _doctor_steam
        _doctor_server
        _doctor_mods
        _doctor_backups
    fi

    if is_json; then
        local arr="[]" row status category name detail
        for row in "${HEALTH_CHECKS[@]}"; do
            IFS=$'\t' read -r status category name detail <<<"$row"
            arr="$(jq -c -n --argjson acc "$arr" \
                --arg s "$status" --arg c "$category" --arg n "$name" --arg d "$detail" \
                '$acc + [{status:$s, category:$c, check:$n, detail:$d}]')"
        done
        jq -n --argjson checks "$arr" --argjson worst "$HEALTH_WORST" \
            '{ok: ($worst < 2), severity: (if $worst==0 then "ok" elif $worst==1 then "warning" else "failure" end),
              checks: $checks,
              summary: {
                total: ($checks|length),
                failures: ([$checks[]|select(.status=="fail")]|length),
                warnings: ([$checks[]|select(.status=="warn")]|length)
              }}'
    else
        local row status category name detail current=""
        out_title "Diagnostics"
        for row in "${HEALTH_CHECKS[@]}"; do
            IFS=$'\t' read -r status category name detail <<<"$row"
            if [[ "$category" != "$current" ]]; then
                [[ -n "$current" ]] && out_line ""
                out_section "$category"
                current="$category"
            fi
            out_check "$status" "$(printf '%-26s %s' "$name" "$detail")"
        done
        out_line ""
        case "$HEALTH_WORST" in
            0) out_line "  Everything checks out." ;;
            1) out_line "  Usable, with warnings above." ;;
            2) out_line "  Problems found. Each failing line above says what to look at." ;;
        esac
        out_line ""
    fi

    (( HEALTH_WORST < 2 )) || return "$EX_HEALTH"
    return 0
}

_doctor_system() {
    compat_detect
    compat_matrix
    case "$COMPAT_STATUS" in
        supported)    _hc ok   "System" "Operating system" "$OS_NAME" ;;
        experimental) _hc warn "System" "Operating system" "$OS_NAME (experimental)" ;;
        *)            _hc fail "System" "Operating system" "$OS_NAME. $COMPAT_REASON" ;;
    esac

    if [[ "$SYS_ARCH" == "x86_64" || "$SYS_ARCH" == "amd64" ]]; then
        _hc ok "System" "Architecture" "$SYS_ARCH"
    else
        _hc fail "System" "Architecture" "$SYS_ARCH is not supported"
    fi

    local missing=()
    compat_missing_packages missing "${REQUIRED_COMMANDS[@]}"
    if (( ${#missing[@]} == 0 )); then
        _hc ok "System" "Required tools" "all present"
    else
        _hc fail "System" "Required tools" "missing: ${missing[*]}"
    fi

    local free; free="$(compat_disk_gb "$INSTALL_DIR")"
    if   (( free >= 10 )); then _hc ok   "System" "Disk space" "${free} GB free"
    elif (( free >= 3 ));  then _hc warn "System" "Disk space" "${free} GB free, an update needs about 7 GB"
    else                        _hc fail "System" "Disk space" "${free} GB free, too little to update or back up"
    fi

    if (( SYS_MEM_MB >= MIN_MEM_MB )); then
        _hc ok "System" "Memory" "${SYS_MEM_MB} MB"
    else
        _hc warn "System" "Memory" "${SYS_MEM_MB} MB is below the recommended minimum"
    fi
}

_doctor_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        _hc fail "Docker" "Docker Engine" "not installed"
        return
    fi
    if docker info >/dev/null 2>&1; then
        _hc ok "Docker" "Docker daemon" "$(compat_docker_version)"
    else
        _hc fail "Docker" "Docker daemon" "not responding. Try: systemctl status docker"
        return
    fi

    local cv; cv="$(compat_compose_version)"
    [[ -n "$cv" ]] && _hc ok "Docker" "Compose plugin" "$cv" \
                   || _hc fail "Docker" "Compose plugin" "missing"

    if image_exists; then
        _hc ok "Docker" "Runtime image" "bannerlordcoop/server:$(cfg WINE_BRANCH)"
    else
        _hc warn "Docker" "Runtime image" "not built yet. Run: coop install"
    fi
}

_doctor_configuration() {
    if [[ -f "$FILE_CONFIG" ]]; then
        _hc ok "Configuration" "server.env" "$FILE_CONFIG"
    else
        _hc fail "Configuration" "server.env" "not found, this host has no installation yet"
        return
    fi

    local perms; perms="$(stat -c %a "$FILE_CONFIG" 2>/dev/null)"
    if [[ "$perms" == "600" || "$perms" == "640" ]]; then
        _hc ok "Configuration" "File permissions" "$perms"
    else
        _hc warn "Configuration" "File permissions" "$perms, the file holds the server password; 600 is expected"
    fi

    local key reason problems=0
    for key in $(config_keys); do
        reason="$(_validate_value "$key" "${CFG[$key]:-}")"
        [[ -n "$reason" ]] && { _hc fail "Configuration" "$key" "$reason"; problems=$(( problems + 1 )); }
    done
    (( problems == 0 )) && _hc ok "Configuration" "Values" "all valid"

    if config_selfcheck >/dev/null 2>&1; then
        _hc ok "Configuration" "Defaults consistency" "spec and defaults.env agree"
    else
        _hc warn "Configuration" "Defaults consistency" "defaults.env and the spec have drifted. Reinstall the manager files"
    fi

    if [[ -f "$FILE_SERVER_JSON" ]]; then
        _hc ok "Configuration" "server-config.json" "generated"
    else
        _hc fail "Configuration" "server-config.json" "missing. Run: coop config --apply"
    fi

    if [[ ! -d /etc/update-motd.d ]]; then
        _hc info "Configuration" "Login message" "this host has no update-motd, so there is none"
    elif ! cfg_bool LOGIN_MESSAGE; then
        _hc info "Configuration" "Login message" "switched off (LOGIN_MESSAGE=false)"
    elif [[ -x "$(motd_file)" ]]; then
        _hc ok "Configuration" "Login message" "$(motd_file)"
    else
        _hc warn "Configuration" "Login message" "not installed. Run: coop config --apply"
    fi
}

_doctor_data() {
    local d
    for d in "$DIR_SAVES" "$DIR_CONFIG" "$DIR_COOPDATA" "$DIR_BACKUPS" "$DIR_LOGS" "$DIR_STATE"; do
        [[ -d "$d" ]] || { _hc fail "Data" "$(basename "$d")/" "missing: $d"; continue; }
        _hc ok "Data" "$(basename "$d")/" "$(du -sh "$d" 2>/dev/null | cut -f1) in $d"
    done

    # Only meaningful once the directory exists; otherwise stat returns
    # nothing and the message reads "owned by , expected 1000:1000".
    if [[ -d "$DIR_SAVES" ]]; then
        local owner expect
        expect="$(cfg PUID):$(cfg PGID)"
        owner="$(stat -c '%u:%g' "$DIR_SAVES" 2>/dev/null)"
        if [[ "$owner" == "$expect" ]]; then
            _hc ok "Data" "Ownership" "$owner"
        else
            _hc warn "Data" "Ownership" "saves/ is owned by $owner, expected $expect, so the container may not be able to write"
        fi
    fi

    local save name
    name="$(campaign_resolve "$(cfg SAVE_NAME)")"
    save="$DIR_SAVES/${name}.sav"
    if [[ -n "$name" ]]; then
        _hc ok "Data" "Campaign save" "$name ($(human_size_simple "$(stat -c %s "$save")"))"
        [[ -f "${save%.sav}.json" ]] \
            || _hc warn "Data" "Player data" "$name.json is missing beside the save, so returning players start at character creation"
    elif [[ "$(state_get new_world)" == "$(cfg SAVE_NAME)" ]]; then
        _hc ok "Data" "Campaign save" "'$(cfg SAVE_NAME)' is a new world, created on the next start"
    else
        _hc fail "Data" "Campaign save" "no save named '$(cfg SAVE_NAME)', and no new world was asked for, so the server will not start. See: coop campaign list"
    fi
    _hc ok "Data" "Campaigns" "$(campaign_names | grep -c . || true) in $DIR_SAVES. List them: coop campaign list"

    if [[ -f "$FILE_MOD_JSON" ]]; then
        _hc ok "Data" "Gameplay config" "mod-config.json present"
    else
        _hc warn "Data" "Gameplay config" "mod-config.json not created yet, the mod writes it on first launch"
    fi
}

_doctor_steam() {
    [[ "$(cfg INSTALL_CHANNEL)" == "workshop" ]] || {
        _hc ok "Steam" "Channel" "custom build, so Steam is not used"
        return
    }
    if [[ -z "$(cfg STEAM_USERNAME)" ]]; then
        _hc fail "Steam" "Account" "not configured. Run: coop steam login"
        return
    fi
    _hc ok "Steam" "Account" "$(cfg STEAM_USERNAME)"

    local st; st="$(steam_status)"
    case "$st" in
        valid|present) _hc ok   "Steam" "Session" "$(steam_status_explain "$st")" ;;
        expired)       _hc fail "Steam" "Session" "$(steam_status_explain "$st")" ;;
        *)             _hc fail "Steam" "Session" "$(steam_status_explain "$st")" ;;
    esac

    if [[ -d "$(workshop_item_dir)" ]]; then
        _hc ok "Steam" "Workshop files" "$(du -sh "$(workshop_item_dir)" 2>/dev/null | cut -f1)"
    else
        _hc warn "Steam" "Workshop files" "not downloaded yet. Run: coop update --force"
    fi
}

_doctor_server() {
    if server_installed; then
        _hc ok "Server" "Server files" "$(server_version)"
    else
        _hc fail "Server" "Server files" "BannerlordCoopServer.exe not found in $DIR_SERVER"
    fi

    if server_installed; then
        local id acc
        id="$(license_id "$DIR_SERVER")"
        acc="$(license_acceptance "$id")"
        if [[ -z "$id" ]]; then
            _hc ok "Server" "License terms" "none shipped with this build"
        elif [[ -n "$acc" ]]; then
            _hc ok "Server" "License terms" "accepted $(jq -r '"\(.accepted_at) by \(.accepted_by)"' <<<"$acc")"
        elif container_running; then
            _hc warn "Server" "License terms" "not accepted through coop, though the server runs. Record it: coop eula accept"
        else
            _hc fail "Server" "License terms" "not accepted, so the server will not start. See: coop eula"
        fi
    fi

    case "$(bans_count)" in
        0)       _hc ok   "Server" "Steam bans" "nobody banned" ;;
        invalid) _hc fail "Server" "Steam bans" "$FILE_BANS is not valid JSON; the server keeps its last valid list" ;;
        *)       _hc ok   "Server" "Steam bans" "$(bans_count) account(s) banned" ;;
    esac

    if ! container_exists; then
        _hc warn "Server" "Container" "not created yet"
        return
    fi
    if container_running; then
        _hc ok "Server" "Container" "running, health: $(container_health)"
        case "$(server_phase)" in
            serving) _hc ok   "Server" "Server process" "serving clients" ;;
            loading) _hc warn "Server" "Server process" "still loading the campaign" ;;
            boot)    _hc warn "Server" "Server process" "starting up" ;;
            *)       _hc warn "Server" "Server process" "no state event seen yet" ;;
        esac
    else
        _hc warn "Server" "Container" "stopped (exit $(container_exitcode))"
    fi

    # The host port being bound proves only that Docker is listening. If
    # the container exposes a different port, traffic arrives and is
    # forwarded to one nobody is listening on, which looks from outside
    # exactly like a blocked firewall.
    if container_running; then
        if [[ -n "$(docker port "$CONTAINER_NAME" "$(cfg GAME_PORT)/udp" 2>/dev/null)" ]]; then
            _hc ok "Server" "Port mapping" "UDP $(cfg GAME_PORT) reaches the server"
        else
            _hc fail "Server" "Port mapping" \
                "the container does not expose UDP $(cfg GAME_PORT), so traffic on the host port goes nowhere. Run: sudo coop config --apply"
        fi
    fi

    if port_in_use "$(cfg GAME_PORT)" udp; then
        _hc ok "Server" "Game port" "UDP $(cfg GAME_PORT) is bound"
    elif container_running; then
        _hc fail "Server" "Game port" "UDP $(cfg GAME_PORT) is not bound although the container runs"
    else
        _hc warn "Server" "Game port" "UDP $(cfg GAME_PORT) is not bound, the server is stopped"
    fi
    case "$(firewall_state)" in
        active)
            _hc warn "Server" "Host firewall" "ufw is active, but it does not govern the published game port; Docker publishes past it"
            ;;
        inactive) _hc info "Server" "Host firewall" "ufw is installed but inactive" ;;
        absent)   _hc info "Server" "Host firewall" "no ufw on this host" ;;
        *)        _hc info "Server" "Host firewall" "could not be determined" ;;
    esac
    _hc info "Server" "Reachability" "UDP $(cfg GAME_PORT) has to be open at your provider; that firewall is the one that counts"

    if container_exists; then
        local errors
        errors="$(container_logs_tail 300 | grep -ciE '^\[?(error|fatal)|Unhandled exception' || true)"
        if (( errors > 0 )); then
            _hc warn "Server" "Recent log errors" "$errors error line(s) in the last 300. See: coop logs"
        else
            _hc ok "Server" "Recent log errors" "none in the last 300 lines"
        fi
    fi
}

_doctor_mods() {
    if ! mods_configured; then
        _hc info "Mods" "Mods" "none, the server runs as the Coop team ships it"
        return
    fi
    local ids=() wid name absent=0
    mapfile -t ids < <(mods_ids)
    if command -v xmlstarlet >/dev/null 2>&1; then
        _hc ok "Mods" "xmlstarlet" "present"
    else
        _hc warn "Mods" "xmlstarlet" "missing; installed at the next start, or now: sudo coop mods update"
    fi
    for wid in "${ids[@]}"; do
        name="$(state_mod_get "$wid" name)"
        if mods_installed "$wid"; then
            _hc ok "Mods" "${name:-$wid}" "$(state_mod_get "$wid" version), Workshop item $wid"
        else
            _hc fail "Mods" "${name:-$wid}" "Workshop item $wid is configured but not installed. Run: sudo coop mods update"
            absent=1
        fi
    done
    if mods_hook_current; then
        _hc ok "Mods" "Startup hook" "built from docker/hook"
    else
        _hc warn "Mods" "Startup hook" "not built yet, or its source changed; it is built at the next start"
    fi
    if (( ! absent )) && [[ -f "$DIR_RUNTIME/coop-launch.txt" ]]; then
        _hc ok "Mods" "Server view" "runtime/ is in place"
    elif (( ! absent )); then
        _hc warn "Mods" "Server view" "runtime/ is missing; it is put together at the next start"
    fi
    if mods_update_marker_is_set; then
        _hc warn "Mods" "Updates" "available on the Workshop. Players get them by themselves: sudo coop mods update"
    fi
}

_doctor_backups() {
    local newest age days
    newest="$(_backup_all_files | head -1)"
    if [[ -z "$newest" ]]; then
        _hc warn "Backups" "Last backup" "none yet. Create one with: coop backup"
    else
        age=$(( $(date +%s) - $(stat -c %Y "$newest") ))
        days=$(( age / 86400 ))
        if   (( days >= 7 )); then _hc warn "Backups" "Last backup" "$(human_duration "$age") ago, older than a week"
        else                       _hc ok   "Backups" "Last backup" "$(basename "$newest"), $(human_duration "$age") ago"
        fi
    fi

    local count total
    count="$(_backup_all_files | wc -l)"
    total="$(du -sh "$DIR_BACKUPS" 2>/dev/null | cut -f1)"
    _hc ok "Backups" "Stored" "${count} archive(s), ${total:-0} in $DIR_BACKUPS"

    if cfg_bool BACKUP_ENABLED; then
        if systemctl is-enabled "bannerlordcoop-backup@$(systemd_instance).timer" >/dev/null 2>&1; then
            _hc ok "Backups" "Schedule" "$(cfg BACKUP_SCHEDULE), timer enabled"
        else
            _hc warn "Backups" "Schedule" "enabled in the configuration but the systemd timer is not active"
        fi
    else
        _hc warn "Backups" "Schedule" "automatic backups are disabled"
    fi

    _hc info "Backups" "Off-host copies" "a backup that only exists on this server is not a backup"
}
