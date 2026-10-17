# shellcheck shell=bash
#
# update.sh - installing a new server build, and going back.
#
# UPDATE AND ROLLBACK ARE NOT RESTORE
# -----------------------------------
#   coop update / coop rollback   move the SOFTWARE forward or back
#   coop backup restore           puts SAVES AND CONFIGURATION back
# They never touch each other's territory. An update carries the campaign
# across untouched; a restore leaves the installed build alone.
#
# WHY UPDATES ARE NOT AUTOMATIC BY DEFAULT
# ----------------------------------------
# The server verifies its own Coop assemblies, and clients have to run the
# same build. An unattended nightly update would lock out every player who
# has not updated yet. So the check runs on a schedule and reports; the
# update itself is a decision.

# ----------------------------------------------------------- version check --
_fmt_ts() {
    [[ "${1:-0}" =~ ^[0-9]+$ ]] && (( $1 > 0 )) \
        && date -d "@$1" '+%Y-%m-%d %H:%M' || printf 'unknown'
}

# The Workshop timestamp of the build that is INSTALLED, as recorded when
# the manager put it in place.
#
# Steam's own manifest cannot answer this. It describes the last download,
# and the download and the installed build part ways twice: after a
# rollback, and when an update was fetched but not installed. Reading the
# manifest there reported "up to date" over a server still running the
# previous build, and `coop update` then declined to install the very
# update it had just downloaded.
installed_workshop_time() {
    local t; t="$(state_get workshop_version)"
    if [[ "$t" =~ ^[0-9]+$ ]] && (( t > 0 )); then
        printf '%s' "$t"
        return 0
    fi
    workshop_local_time
}

# update_available
#   0  a newer version exists
#   1  up to date
#   2  cannot tell (Steam unreachable)
update_available() {
    local local_ts remote_ts
    local_ts="$(installed_workshop_time)"
    remote_ts="$(workshop_remote_time || true)"

    [[ -n "$remote_ts" ]] || return 2
    debug "installed $(_fmt_ts "$local_ts") / workshop $(_fmt_ts "$remote_ts")"
    (( remote_ts > local_ts ))
}

# update_check [--exit-status]
#
# Exit code 0 means THE CHECK SUCCEEDED, which is the convention every
# other tool follows; whether an update exists is in the output. Scripts
# that want it as a code ask for --exit-status and get 100.
#
# shellcheck disable=SC2120  # called with --exit-status from bin/coop
update_check() {
    local exit_status=0
    [[ "${1:-}" == "--exit-status" ]] && exit_status=1

    [[ "$(cfg INSTALL_CHANNEL)" == "workshop" ]] || {
        is_json && json_emit '{ok:true, channel:$c, update_available:false, reason:"not the workshop channel"}' --arg c "$(cfg INSTALL_CHANNEL)"
        out_line "Install channel is '$(cfg INSTALL_CHANNEL)'; there is nothing to check against."
        return 0
    }

    local rc=0 local_ts remote_ts
    update_available || rc=$?
    local_ts="$(installed_workshop_time)"
    remote_ts="$(workshop_remote_time || true)"

    if (( rc == 2 )); then
        update_marker_clear
        if is_json; then
            json_emit '{ok:false, update_available:null, error:"Steam API unreachable"}'
        fi
        warn "Could not reach the Steam API; update status is unknown."
        return "$EX_STEAM"
    fi

    if (( rc == 0 )); then
        update_marker_set
        if is_json; then
            json_emit '{ok:true, update_available:true, installed:$i, available:$a}' \
                --arg i "$(_fmt_ts "$local_ts")" --arg a "$(_fmt_ts "$remote_ts")"
        else
            out_line "A Workshop update is available."
            out_line "  installed: $(_fmt_ts "$local_ts")"
            out_line "  available: $(_fmt_ts "$remote_ts")"
            out_line ""
            out_line "  Install it with: coop update"
            out_line "  Remember that every player needs the same Coop build."
        fi
        (( exit_status )) && return "$EX_UPDATE_AVAILABLE"
        return 0
    fi

    update_marker_clear
    if is_json; then
        json_emit '{ok:true, update_available:false, installed:$i}' --arg i "$(_fmt_ts "$local_ts")"
    else
        out_line "The server is up to date (installed $(_fmt_ts "$local_ts"))."
    fi
    return 0
}

# update_scheduled
#
# What the systemd timer runs. The decision of whether to install lives
# here rather than in the unit file, so changing AUTO_UPDATE takes effect
# without touching systemd.
update_scheduled() {
    local rc=0
    update_check || rc=$?

    # Mods are checked on the same schedule, and only ever reported:
    # players get Workshop updates by themselves, so the report is how an
    # operator learns that the server has fallen behind them.
    if mods_configured; then
        if mods_update_check && (( ${#MODS_UPDATES[@]} )); then
            log "Updates for ${#MODS_UPDATES[@]} mod(s) are available. Install them with 'coop mods update'."
        fi
    fi

    # 30 means Steam was unreachable - weather, not a failure. The unit
    # declares it a success for exactly this reason.
    (( rc == EX_STEAM )) && return "$EX_STEAM"

    if update_marker_is_set && cfg_bool AUTO_UPDATE; then
        log "AUTO_UPDATE is enabled. Installing the update now."
        # A build with license terms nobody has accepted stops here, before
        # the server is touched: an unattended run never accepts terms.
        update_apply
        return $?
    fi

    if update_marker_is_set; then
        log "An update is available. Install it with 'coop update' once every player can update too."
    fi
    return 0
}

# ---------------------------------------------------------------- rollback --
rollback_available() { [[ -f "$DIR_ROLLBACK/BannerlordCoopServer.exe" ]]; }

# rollback_apply [--auto]
#
# --auto is the path taken by a failed update: no questions, because the
# decision was already made by the failure.
rollback_apply() {
    local auto=0
    [[ "${1:-}" == "--auto" ]] && auto=1

    rollback_available || fail "$EX_RUNTIME" \
        "There is no previous version to roll back to." \
        "A rollback copy is created the first time you run 'coop update'."

    if (( ! auto )); then
        out_title "Roll back to the previous server build"
        out_line "  Current : $(server_version)"
        out_line "  Previous: $(_rollback_version)"
        out_line ""
        out_line "  This replaces the server software. Campaign saves are not touched."
        out_line ""
        confirm "Continue?" no || { log "Cancelled."; return 0; }
    fi

    server_refresh_image
    server_stop
    log "Restoring the previous server build"
    rsync -a --delete \
        --exclude 'mod-config.json.bak' --exclude '.timeupdated' \
        "$DIR_ROLLBACK/" "$DIR_SERVER/" \
        || fail "$EX_RUNTIME" "Could not restore the previous build."

    if [[ -f "$DIR_ROLLBACK/mod-config.json.bak" ]]; then
        cp -a "$DIR_ROLLBACK/mod-config.json.bak" "$FILE_MOD_JSON"
        log "Restored the gameplay configuration that went with that build."
    fi
    chown -R "$(cfg PUID):$(cfg PGID)" "$DIR_SERVER" "$DIR_COOPDATA" 2>/dev/null || true

    if [[ -f "$DIR_ROLLBACK/.timeupdated" ]]; then
        state_set workshop_version "$(cat "$DIR_ROLLBACK/.timeupdated")"
    fi
    state_set installed_version "$(server_version)"

    server_start || fail "$EX_HEALTH" \
        "The previous build did not start either." \
        "Inspect the logs: coop logs"

    ok "Rolled back to $(server_version)"
}

_rollback_version() {
    local f="$DIR_ROLLBACK/release-info.txt" built
    [[ -f "$f" ]] || { printf 'unknown'; return; }
    built="$(sed -n 's/^Built:[[:space:]]*//p' "$f" | tr -d '\r' | head -1)"
    printf 'build %s' "${built:-unknown}"
}

# ------------------------------------------------------------------ update --
# THE ORDER IS THE POINT
# ----------------------
#   1. download          the server keeps running
#   2. license terms     the server keeps running
#   3. stop, with a closing save
#   4. pre-update backup
#   5. keep the current build in rollback/
#   6. put the new build in place
#   7. carry the gameplay settings across
#   8. start, and roll back by itself if the new build will not serve
#
# Everything that can fail or be declined without consequences happens
# while the current build is still serving. A failed download, or terms
# the operator does not accept, leave the server exactly as it was. It
# used to stop first, and a download failure then left the server down.
#
# shellcheck disable=SC2120  # called with --force from bin/coop
update_apply() {
    local force=0 arg
    for arg in "$@"; do
        case "$arg" in
            --force) force=1 ;;
            *) fail "$EX_USAGE" "Unknown option for update: $arg" ;;
        esac
    done

    local rc=0
    update_available || rc=$?

    if (( rc == 1 && ! force )); then
        update_marker_clear
        out_line "The server is already up to date. Nothing to do."
        return 0
    fi
    if (( rc == 2 && ! force )); then
        fail "$EX_STEAM" \
            "Could not determine whether an update exists; the Steam API is unreachable." \
            "Retry later, or force the update with: coop update --force"
    fi

    out_title "Workshop update"

    # 1. fetch. The download lands in workshop/, which the running server
    #    never reads.
    source_fetch
    local staging; staging="$(source_staging_dir)"
    [[ -f "$staging/BannerlordCoopServer.exe" ]] || fail "$EX_RUNTIME" \
        "The downloaded files are not where they were expected: $staging" \
        "Nothing was changed; the server keeps running the current build."
    log "Downloaded: $(server_version_of "$staging")"

    # 2. the new build's license terms, settled before anything stops
    if ! license_require "$staging"; then
        warn "The update was not installed. Nothing was changed; the server keeps running the current build."
        return "$EX_LICENSE"
    fi

    # 3. stop cleanly - this writes a closing save. A runtime image built
    #    from older files is rebuilt first, while the server still serves.
    server_refresh_image
    server_stop

    # 4. campaign, configuration and gameplay settings first
    log "Creating a pre-update backup"
    backup_create pre-update "before Workshop update" >/dev/null

    # 5. keep the working build so a failure has somewhere to go back to.
    #    A directory copy costs disk but turns a rollback into a rename
    #    instead of a 6 GB download.
    log "Copying the current build to rollback/"
    mkdir -p "$DIR_ROLLBACK"
    if ! rsync -a --delete "$DIR_SERVER/" "$DIR_ROLLBACK/"; then
        warn "Could not create the rollback copy. Restarting the current build unchanged."
        server_start
        fail "$EX_RUNTIME" "The update was not installed: no rollback copy could be made." \
            "Check the free space in $INSTALL_DIR."
    fi
    cp -a "$FILE_MOD_JSON" "$DIR_ROLLBACK/mod-config.json.bak" 2>/dev/null || true
    installed_workshop_time >"$DIR_ROLLBACK/.timeupdated"

    # 6. put the new files in place
    log "Synchronising the new build into server/"
    if ! rsync -a --delete "$staging/" "$DIR_SERVER/"; then
        warn "Could not synchronise the new build."
        rollback_apply --auto
        fail "$EX_RUNTIME" \
            "The update failed and was rolled back automatically." \
            "The server is running the previous build again."
    fi
    chown -R "$(cfg PUID):$(cfg PGID)" "$DIR_SERVER" 2>/dev/null || true
    log "New build: $(server_version)"

    # 7. before the first start, so the server boots on the merged file
    _update_merge_mod_config

    # 8. start - and if it will not serve, go back on its own
    if ! server_start; then
        warn "The server did not come up with the new build."
        rollback_apply --auto
        fail "$EX_HEALTH" \
            "The update failed and was rolled back automatically." \
            "The server is running the previous build again." \
            "Logs: coop logs"
    fi

    state_set installed_version "$(server_version)"
    state_set workshop_version "$(workshop_local_time)"
    update_marker_clear

    ok "Update complete: $(server_version)"
    out_line ""
    out_line "  Every player needs the same Coop build to connect."
    out_line "  The previous build is kept; undo with: coop rollback"
    if mods_configured; then
        out_line "  The server runs with its mods. Mods often follow a new Coop build"
        out_line "  with updates of their own: coop mods update --check"
    fi
    out_line ""
}

# ----------------------------------------------------- gameplay settings --
# WHY THE MANAGER MERGES AT ALL
# -----------------------------
# mod-config.json holds the gameplay settings - difficulty, world ageing,
# battle size - and belongs to the Coop mod. The mod creates it from the
# template it ships, mod-config.default.json, and after that never
# replaces it. A new build's settings therefore never reach an existing
# file: they run at their defaults, invisible and undocumented, and the
# operator has no way of knowing they exist.
#
# So before the new build first starts, its template is merged with the
# file the operator has. The TEMPLATE is the base, because it brings the
# new settings and the comments that document them. Every value from the
# operator's file is transplanted into it. Settings the build dropped are
# gone, because they no longer do anything.
#
# Defaults the new build changed are reported, not applied. A value equal
# to the old default may still be a choice, and changing difficulty or the
# economy in the middle of a running campaign is the operator's decision.
#
# The file is JSONC, which jq cannot read - but it is strictly one setting
# per line, which makes a line-oriented merge both possible and safe, and
# leaves every comment untouched. Its line endings are CRLF, and a line
# that gets a new value keeps them.

# modconfig_template <build-dir> - the template a build ships, if any.
# Searched rather than assumed: the module's folder name has changed
# between builds before.
modconfig_template() {
    find "$1/engine/Modules" -mindepth 2 -maxdepth 2 -name mod-config.default.json \
        -type f 2>/dev/null | sort | head -1
}

# modconfig_values <file> - "key<TAB>value" for every setting in the file.
modconfig_values() {
    awk '
    /^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:/ {
        line = $0
        sub(/\r$/, "", line)
        p = index(line, "\"")
        rest = substr(line, p + 1)
        k = substr(rest, 1, index(rest, "\"") - 1)
        v = substr(line, index(line, ":") + 1)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); sub(/,$/, "", v)
        if (v != "{" && v != "") print k "\t" v
    }' "$1"
}

_modconfig_count() {
    grep -cE '^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:' "$1" 2>/dev/null || true
}

# modconfig_merge <previous> <new> <output> <report>
#
# <new> is the base; every value <previous> has is written into it. The
# report receives one "added <key>" or "removed <key>" line per difference,
# so the caller can say what actually changed.
modconfig_merge() {
    local previous="$1" new="$2" output="$3" report="$4"
    : >"$report"

    awk '
    function keyof(line,   p, q) {
        p = index(line, "\"")
        if (p == 0) return ""
        q = index(substr(line, p + 1), "\"")
        if (q == 0) return ""
        return substr(line, p + 1, q - 1)
    }
    function valof(line,   v) {
        v = substr(line, index(line, ":") + 1)
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        return v
    }
    function indentof(line) {
        match(line, /^[[:space:]]*/)
        return substr(line, 1, RLENGTH)
    }

    # First pass: remember what the operator had.
    NR == FNR {
        if ($0 ~ /^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:/) {
            k = keyof($0); v = valof($0); sub(/,$/, "", v)
            # A block opener carries no value of its own.
            if (v != "{" && v != "") kept[k] = v
        }
        next
    }

    # Second pass: the new file, with old values written back in.
    {
        if ($0 ~ /^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:/) {
            k = keyof($0); v = valof($0)
            comma = (v ~ /,$/) ? "," : ""
            cr = ($0 ~ /\r$/) ? "\r" : ""
            sub(/,$/, "", v)
            if (v != "{") {
                if (k in kept) {
                    seen[k] = 1
                    print indentof($0) "\"" k "\": " kept[k] comma cr
                    next
                }
                print "added " k > REPORT
            }
        }
        print
    }

    END {
        for (k in kept) if (!(k in seen)) print "removed " k > REPORT
    }
    ' REPORT="$report" "$previous" "$new" >"$output"
}

# modconfig_changed_defaults <old-template> <new-template> <current>
#
# "key<TAB>old<TAB>new" for every setting whose default changed between the
# two builds while <current> still holds the old default: the settings an
# operator most likely never chose, and might want to follow.
modconfig_changed_defaults() {
    local old_t new_t cur
    old_t="$(mktemp)"; new_t="$(mktemp)"; cur="$(mktemp)"
    modconfig_values "$1" >"$old_t"
    modconfig_values "$2" >"$new_t"
    modconfig_values "$3" >"$cur"
    awk -F'\t' '
        FILENAME == OLD { old[$1] = $2; next }
        FILENAME == NEW { new[$1] = $2; next }
        { cur[$1] = $2 }
        END {
            for (k in cur)
                if ((k in old) && (k in new) && old[k] != new[k] && cur[k] == old[k])
                    print k "\t" old[k] "\t" new[k]
        }
    ' OLD="$old_t" NEW="$new_t" "$old_t" "$new_t" "$cur" | sort
    rm -f "$old_t" "$new_t" "$cur"
}

# Prints a list as wrapped, indented lines.
_wrap_list() {
    local indent="$1"; shift
    printf '%s\n' "$*" | sed 's/ /, /g' | fold -s -w $(( 76 - ${#indent} )) | sed "s/^/${indent}/"
}

_update_merge_mod_config() {
    local new_tmpl old_tmpl
    new_tmpl="$(modconfig_template "$DIR_SERVER")"
    old_tmpl="$(modconfig_template "$DIR_ROLLBACK")"

    # Nothing to merge into yet: the mod creates the file on first start.
    [[ -f "$FILE_MOD_JSON" && -n "$new_tmpl" ]] || return 0
    if [[ -n "$old_tmpl" ]] && cmp -s "$old_tmpl" "$new_tmpl"; then
        debug "the gameplay settings template is unchanged"
        return 0
    fi

    local merged report
    merged="$(mktemp "${FILE_MOD_JSON}.merge.XXXXXX")"
    report="$(mktemp "${FILE_MOD_JSON}.report.XXXXXX")"
    cleanup_register "$merged"; cleanup_register "$report"

    modconfig_merge "$FILE_MOD_JSON" "$new_tmpl" "$merged" "$report"

    # A merge that lost settings would be worse than none. The file the
    # operator has keeps working as it is: the mod runs anything it does
    # not mention at the default.
    local want got
    want="$(_modconfig_count "$new_tmpl")"
    got="$(_modconfig_count "$merged")"
    if [[ "$got" != "$want" || "$got" == "0" ]]; then
        warn "The new build's gameplay settings could not be merged safely; mod-config.json was left as it is."
        out_line "    Settings it does not mention run at their defaults. Compare:"
        out_line "      diff $FILE_MOD_JSON $new_tmpl"
        return 0
    fi

    local added=() removed=() what key
    while IFS=' ' read -r what key; do
        case "$what" in
            added)   added+=("$key") ;;
            removed) removed+=("$key") ;;
        esac
    done <"$report"

    if ! cmp -s "$merged" "$FILE_MOD_JSON"; then
        chmod 0644 "$merged"
        chown "$(cfg PUID):$(cfg PGID)" "$merged" 2>/dev/null || true
        mv -f "$merged" "$FILE_MOD_JSON"
    fi

    ok "Gameplay settings brought up to this build; your values were kept"
    if (( ${#added[@]} )); then
        out_line "    New in this build, at their defaults:"
        _wrap_list "      " "${added[@]}"
    fi
    if (( ${#removed[@]} )); then
        out_line "    No longer in this build, removed:"
        _wrap_list "      " "${removed[@]}"
    fi

    [[ -n "$old_tmpl" ]] || return 0
    local changed old new
    changed="$(modconfig_changed_defaults "$old_tmpl" "$new_tmpl" "$FILE_MOD_JSON")"
    if [[ -n "$changed" ]]; then
        out_line "    Defaults this build changed. Your file keeps the value it had:"
        while IFS=$'\t' read -r key old new; do
            out_line "$(printf '      %-40s %s, now %s' "$key" "$old" "$new")"
        done <<<"$changed"
        out_line "    To follow a new default, edit $FILE_MOD_JSON"
        out_line "    and run: coop restart"
    fi
}
