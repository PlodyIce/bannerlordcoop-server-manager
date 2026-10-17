# shellcheck shell=bash
#
# server.sh - talking to the game server and knowing what it is doing.
#
# The server publishes two things a manager can rely on, both discovered by
# reading its output rather than by guessing:
#
#   1. Structured events, one JSON object per line behind an @DS@ prefix:
#        @DS@{"ev":"state","phase":"serving","save":"Campaign","pw":true}
#        @DS@{"ev":"players","list":[]}
#      phase is one of boot, loading, serving.
#
#   2. A pulse line, refreshed on every campaign tick:
#        pulse: time=Spring 1, 1095 timeMode=Stop players=0 parties=1954
#
# Everything below is built on those two. The functions that wait for
# something return status codes rather than exiting, because their callers -
# update in particular - need the chance to roll back.

# ------------------------------------------------------------ server state --
ds_event() {
    container_logs_current \
        | sed -n 's/.*@DS@\({.*}\)$/\1/p' \
        | jq -c --arg ev "$1" 'select(.ev==$ev)' 2>/dev/null \
        | tail -1
}

server_phase() { ds_event state | jq -r '.phase // empty' 2>/dev/null || true; }
server_is_serving() { [[ "$(server_phase)" == "serving" ]]; }

last_pulse()  { container_logs_current | grep -a 'pulse: ' | tail -1; }
pulse_field() { last_pulse | sed -n "s/.*[[:space:]]$1=\([^[:space:]]*\).*/\1/p"; }
pulse_time()  { last_pulse | sed -n 's/.*time=\(.*\) timeMode=.*/\1/p'; }

player_count() {
    local n; n="$(pulse_field players)"
    [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'
}

player_list() { ds_event players | jq -r '.list[]? // empty' 2>/dev/null || true; }

# The installed Coop build, read from the file the Workshop item ships.
server_version() { server_version_of "$DIR_SERVER"; }

# server_version_of <build-dir> - the same for any build on disk, such as
# a download that has not been installed yet.
server_version_of() {
    local f="$1/release-info.txt" built game
    [[ -f "$f" ]] || { printf 'not installed'; return 0; }
    # The file ships with a Windows build and has CRLF line endings. A
    # trailing carriage return is invisible in a terminal but travels into
    # the JSON backup manifest and the status output, where it is not.
    built="$(sed -n 's/^Built:[[:space:]]*//p'        "$f" | tr -d '\r' | head -1)"
    game="$(sed -n 's/^Game version:[[:space:]]*//p'  "$f" | tr -d '\r' | head -1)"
    printf 'build %s / %s' "${built:-unknown}" "${game:-unknown}"
}

server_installed() { [[ -f "$DIR_SERVER/BannerlordCoopServer.exe" ]]; }

# ------------------------------------------------------------- interaction --
# Sends a command to the server console through the FIFO the entrypoint
# attached to its stdin.
server_cmd() {
    container_running || fail "$EX_RUNTIME" "The server is not running."
    docker exec "$CONTAINER_NAME" coop-cmd "$@"
}

# Forces a save AND waits until the file on disk is actually newer.
#
# A blind `save; sleep 5` would be the weakest link in the whole backup
# chain, so this watches the modification time instead.
server_save() {
    local timeout="${1:-120}" name file before=0 waited=0
    name="$(cfg SAVE_NAME)"
    [[ -n "$name" ]] || { warn "SAVE_NAME is empty; cannot verify the save."; return 1; }
    file="$DIR_SAVES/${name}.sav"
    [[ -f "$file" ]] && before="$(stat -c %Y "$file")"

    log "Requesting save of '$name'"
    server_cmd save >/dev/null || return 1

    while (( waited < timeout )); do
        sleep 2; waited=$(( waited + 2 ))
        if [[ -f "$file" ]] && (( $(stat -c %Y "$file") > before )); then
            ok "Save written after ${waited}s ($(human_size_simple "$(stat -c %s "$file")"))"
            return 0
        fi
    done
    warn "No new save appeared within ${timeout}s"
    return 1
}

# ---------------------------------------------------------- start and stop --
# The server's own words when its license terms have not been accepted.
# Looked for only in output since <since> (a Unix time), so a refusal left
# over from an earlier attempt cannot be mistaken for a new one.
server_license_refused() {
    docker logs --since "$1" "$CONTAINER_NAME" 2>&1 \
        | grep -qE 'EULA acceptance required|DS_ACCEPT_EULA=true to accept and persist'
}

# Waits until the server actually serves clients - not merely until the
# container is up. Loading a grown campaign takes about two minutes.
#
#   0  serving
#   1  timed out
#   2  the container stopped on its own
#   3  the container is crash looping
#   4  the server refused to start: its license terms are not accepted
wait_serving() {
    local timeout="${1:-600}" since="${2:-}" waited=0 restarts_before restarts_now
    restarts_before="$(container_restart_count)"

    while (( waited < timeout )); do
        # Checked before anything else. A server refusing its terms exits
        # within seconds, and restart:unless-stopped starts it again and
        # again, so at any given moment it may be between two attempts and
        # look like a container that merely stopped.
        if [[ -n "$since" ]] && server_license_refused "$since"; then
            return 4
        fi
        container_running || return 2
        server_is_serving && return 0

        # A crash loop is not a slow start. With restart:unless-stopped a
        # container that dies on every attempt still reads as "running"
        # between attempts, so without this the full timeout would elapse
        # before anyone was told - ten minutes before an update rolls back.
        restarts_now="$(container_restart_count)"
        if (( restarts_now - restarts_before >= 3 )); then
            return 3
        fi

        sleep 5; waited=$(( waited + 5 ))
    done
    return 1
}

#   0  serving        1  did not reach serving in time
#   2  exited         4  refused: license terms not accepted
#   5  not started: it would have created a world nobody asked for
#   6  not started: the image or the mods could not be prepared
server_start() {
    local timeout="${1:-600}" since
    docker_require
    server_installed || fail "$EX_RUNTIME" \
        "No server files found in $DIR_SERVER." \
        "Install them first: coop update --force"

    # A typo in SAVE_NAME must not quietly become a new, empty world that
    # players then start playing in. See lib/campaign.sh.
    if ! campaign_start_allowed; then
        campaign_explain_refusal
        return 5
    fi

    # Only for a container about to start. A running one has its files
    # open, and the view lib/mods.sh rebuilds is what it has mounted.
    if ! container_running && ! _server_prepare; then
        return 6
    fi

    since="$(( $(date +%s) - 1 ))"
    log "Starting the server"
    # DS_ACCEPT_EULA reaches the container only when it is set here (see
    # compose.yaml), and it is set only for terms the operator accepted.
    if license_accepted_for "$DIR_SERVER"; then
        DS_ACCEPT_EULA=true dc up -d --remove-orphans >/dev/null 2>&1 \
            || { warn "docker compose up failed"; return 1; }
    else
        dc up -d --remove-orphans >/dev/null 2>&1 \
            || { warn "docker compose up failed"; return 1; }
    fi

    local rc=0
    wait_serving "$timeout" "$since" || rc=$?
    case "$rc" in
        0) # The campaign date comes from the pulse line, which has not
           # necessarily been printed yet the moment the server starts
           # serving - so it is appended only when there is one.
           local when; when="$(pulse_time)"
           ok "Server is serving ('$(cfg SAVE_NAME)'${when:+, $when})"
           campaign_settle_new_world
           return 0 ;;
        4) # Left alone, Docker would restart it into the same refusal
           # for as long as the machine runs.
           dc stop >/dev/null 2>&1 || true
           warn "The server will not start: its license terms have not been accepted."
           out_line "    Read them:  coop eula show"
           out_line "    Accept:     coop eula accept"
           return 4 ;;
        3) # Mid-restart, the reported exit code is whatever Docker happened
           # to be holding, so it is not worth printing. The log is.
           warn "The server is not starting: the container exits at once and Docker keeps restarting it."
           out_line "    See what it says:  coop logs -n 50"
           return 2 ;;
        2) warn "The container exited during start-up (exit $(container_exitcode))."
           _explain_exit_code "$(container_exitcode)"
           return 2 ;;
        *) warn "The server did not reach 'serving' within ${timeout}s."
           return 1 ;;
    esac
}

# Rebuilds an image made from older files while the server still runs.
# Called by everything that stops the server only to start it again, so a
# rebuild after a manager update, which can take minutes when Docker's
# build cache is gone, is not added to the time players wait. A failure
# here changes nothing: the start tries again and reports it.
server_refresh_image() {
    image_is_current && return 0
    config_write_compose_env
    image_refresh || true
}

# What has to be in place before a container starts: the directories the
# compose file mounts, owned by the service user rather than by Docker,
# which would create a missing one as root; an image built from the current
# files; and with mods, their view of the server.
_server_prepare() {
    mkdir -p "$DIR_USERCONFIGS" "$DIR_LOGS/engine" \
        && chown "$(cfg PUID):$(cfg PGID)" "$DIR_USERCONFIGS" "$DIR_LOGS/engine" 2>/dev/null
    _server_prune_engine_logs
    config_write_compose_env
    image_refresh || return 1

    if mods_configured; then
        log "Preparing $(mods_ids | grep -c .) mod(s)"
        if ! mods_prepare_start; then
            warn "Not starting: $MODS_ERROR."
            return 1
        fi
    elif [[ -e "$DIR_RUNTIME" ]]; then
        # A view left from mods that are gone. Nothing mounts it any more.
        rm -rf -- "$DIR_RUNTIME"
    fi
    return 0
}

# The engine starts a new set of logs at every launch and writes a folder
# per crash, each with a dump. Kept: the newest 30 log files and 5 crashes.
_server_prune_engine_logs() {
    local d="$DIR_LOGS/engine" f n
    n=0
    while IFS= read -r f; do
        n=$(( n + 1 ))
        (( n > 30 )) && rm -f -- "$f"
    done < <(ls -1t "$d"/logs/*.txt 2>/dev/null)
    n=0
    while IFS= read -r f; do
        n=$(( n + 1 ))
        (( n > 5 )) && rm -rf -- "$f"
    done < <(ls -1td "$d"/crashes/*/ 2>/dev/null)
    return 0
}

# The newest error log the engine wrote: the engine loses the end of its
# console output when it crashes, and this file still has it.
server_engine_errors() {
    ls -1t "$DIR_LOGS"/engine/logs/rgl_log_errors_*.txt 2>/dev/null | head -1
}

# For commands that end in a start: the exit code says why it failed.
server_start_or_exit() {
    local rc=0
    server_start "$@" || rc=$?
    case "$rc" in
        0) return 0 ;;
        4) exit "$EX_LICENSE" ;;
        5) exit "$EX_CONFIG" ;;
        6) exit "$EX_RUNTIME" ;;
        *) exit "$EX_HEALTH" ;;
    esac
}

# The server's own exit codes. Naming them turns a support question into a
# one-line answer.
_explain_exit_code() {
    case "${1:-}" in
        2) out_line "    Exit 2: the save could not be loaded, or loading timed out." ;;
        3) out_line "    Exit 3: the server failed while running. See 'coop logs'." ;;
        4) out_line "    Exit 4: the Coop assemblies do not match the release. Files under"
           out_line "            Modules/Coop were modified. Try 'coop update --force' or"
           out_line "            'coop rollback'." ;;
        5) out_line "    Exit 5: the engine crashed. Its own error log says why:"
           out_line "            $(server_engine_errors || true)" ;;
        6) out_line "    Exit 6: the license terms of this build have not been accepted."
           out_line "            See: coop eula" ;;
        82) out_line "    Exit 82: the engine gave up while loading its modules. With mods,"
            out_line "             the usual cause is a mod that cannot run on a dedicated"
            out_line "             server. Its error log: $(server_engine_errors || true)" ;;
        137) out_line "    Exit 137: the container was killed. This should not happen with the"
             out_line "              console shutdown path; please report it." ;;
    esac
}

# The same, in a few words, for status output.
exit_code_meaning() {
    case "${1:-}" in
        0)   printf 'clean shutdown' ;;
        2)   printf 'save could not be loaded' ;;
        3)   printf 'failed while running' ;;
        4)   printf 'Coop files modified' ;;
        5)   printf 'the engine crashed, see logs/engine/logs' ;;
        6)   printf 'license terms not accepted, see: coop eula' ;;
        82)  printf 'a module could not be loaded, see logs/engine/logs' ;;
        137) printf 'killed' ;;
    esac
}

# Stops through the server console, never by signal alone: the entrypoint
# turns SIGTERM into a console "stop" and waits for the closing save.
server_stop() {
    if ! container_running; then
        log "The server is already stopped."
        return 0
    fi
    log "Stopping the server (console shutdown, with a closing save)"
    dc stop >/dev/null 2>&1 || true

    local code; code="$(container_exitcode)"
    if [[ "$code" == "0" ]]; then
        ok "Server stopped cleanly"
        return 0
    fi
    warn "The server exited with code $code"
    _explain_exit_code "$code"
    return 0
}

# --------------------------------------------------- the game's own config --
# server-config.json is JSONC: it carries comments and trailing commas, so
# jq cannot read it and an in-place regex edit is how a campaign gets lost.
# The manager therefore *generates* it from templates/server-config.json.tmpl
# and owns the file; users change config/server.env instead.
server_config_render() {
    local tmpl="${COOP_ROOT}/templates/server-config.json.tmpl"
    [[ -f "$tmpl" ]] || fail "$EX_CONFIG" "Missing template: $tmpl"

    mkdir -p "$DIR_CONFIG"
    [[ -f "$FILE_SERVER_JSON" ]] && cp -a "$FILE_SERVER_JSON" "${FILE_SERVER_JSON}.bak"

    local pw; pw="$(cfg SERVER_PASSWORD)"
    # JSON string escaping for the two characters that can occur in a
    # password and would otherwise break the file.
    pw="${pw//\\/\\\\}"; pw="${pw//\"/\\\"}"
    local save; save="$(cfg SAVE_NAME)"
    save="${save//\\/\\\\}"; save="${save//\"/\\\"}"

    # Substitution is literal on purpose. awk's gsub() treats '&' in the
    # replacement as "the text that matched" and eats backslashes, so a
    # password of "a&b" would silently become "a@@SERVER_PASSWORD@@b".
    # Values reach awk through the environment, which skips -v's escape
    # processing as well.
    COOP_T_SAVE="$save" \
    COOP_T_PASSWORD="$pw" \
    COOP_T_PORT="$(cfg GAME_PORT)" \
    COOP_T_AUTOSAVE="$(cfg AUTOSAVE_MINUTES)" \
    COOP_T_STEAM="$(cfg STEAM_ADVERTISE)" \
    COOP_T_LOGFILE="$(cfg SERVER_LOG_FILE)" \
    awk '
        function lit(s, from, to,   p, out) {
            while ((p = index(s, from)) > 0) {
                out = out substr(s, 1, p - 1) to
                s = substr(s, p + length(from))
            }
            return out s
        }
        {
            $0 = lit($0, "@@SAVE_NAME@@",        ENVIRON["COOP_T_SAVE"])
            $0 = lit($0, "@@SERVER_PASSWORD@@",  ENVIRON["COOP_T_PASSWORD"])
            $0 = lit($0, "@@GAME_PORT@@",        ENVIRON["COOP_T_PORT"])
            $0 = lit($0, "@@AUTOSAVE_MINUTES@@", ENVIRON["COOP_T_AUTOSAVE"])
            $0 = lit($0, "@@STEAM_ADVERTISE@@",  ENVIRON["COOP_T_STEAM"])
            $0 = lit($0, "@@SERVER_LOG_FILE@@",  ENVIRON["COOP_T_LOGFILE"])
            print
        }
    ' "$tmpl" >"${FILE_SERVER_JSON}.tmp" \
        || fail "$EX_CONFIG" "Could not render $FILE_SERVER_JSON"

    # A placeholder left behind means the template and the renderer have
    # drifted apart - better to catch it here than at the next server start.
    if grep -q '@@[A-Z_]*@@' "${FILE_SERVER_JSON}.tmp"; then
        rm -f "${FILE_SERVER_JSON}.tmp"
        fail "$EX_CONFIG" "Template placeholders were left unfilled. This is a bug in the manager."
    fi

    chown "$(cfg PUID):$(cfg PGID)" "${FILE_SERVER_JSON}.tmp" 2>/dev/null || true
    chmod 0640 "${FILE_SERVER_JSON}.tmp"
    mv -f "${FILE_SERVER_JSON}.tmp" "$FILE_SERVER_JSON"
    debug "rendered $FILE_SERVER_JSON"
}
