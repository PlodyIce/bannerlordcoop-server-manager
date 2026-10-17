# shellcheck shell=bash
#
# backup.sh - backup, retention, listing and restore.
#
# WHAT IS IN A BACKUP
# -------------------
# Always the same directories, because only together do they make a
# playable state:
#     saves/        the campaign
#     config/       server.env and the generated server-config.json
#     coopdata/     mod-config.json, the gameplay settings owned by the mod
#     userconfigs/  what mods keep for themselves, some of it per campaign
#
# Everything else - the server files, the Workshop downloads, the mods, the
# rollback copy, the container image - can be produced again from Steam and
# this repository. These cannot. The manifest names the mods a backup was
# made with, because a campaign played with mods needs them again.
#
# NOTE: config/server.env contains the server password. Backups are
# written 0600 and should be treated as secrets.
#
# RESTORE IS A TRANSACTION
# ------------------------
# Unpacking an archive straight over a live installation leaves a mixture
# of old and new campaign files if anything goes wrong halfway. So the
# archive is verified, extracted to a staging directory on the same
# filesystem, and only then swapped in by renaming directories - which is
# instant and, crucially, reversible.

readonly BACKUP_DIRS=(saves config coopdata userconfigs)

# Settings that describe the host rather than the server: where the
# installation lives, its name, the numeric ids of the service user, and the
# Steam account whose session is in state/. A backup from another machine
# carries that machine's values, and a restore keeps this one's. Taking the
# backup's would point the manager at another directory, or hand files to a
# user id that does not exist here: measured, the service user is 988 on one
# test host and 999 on the other.
readonly BACKUP_HOST_SETTINGS=(INSTALL_DIR INSTANCE_ID PUID PGID STEAM_USERNAME)
readonly BACKUP_TYPES=(auto manual pre-update pre-restore)

_backup_keep_for() {
    case "$1" in
        auto)        cfg BACKUP_KEEP_AUTO ;;
        pre-update)  cfg BACKUP_KEEP_PREUPDATE ;;
        pre-restore) cfg BACKUP_KEEP_PRERESTORE ;;
        *)           cfg BACKUP_KEEP_MANUAL ;;
    esac
}

# <type>-<YYYYmmdd>-<HHMMSS>.tar.gz  ->  <YYYYmmdd>-<HHMMSS>
backup_id_from_file() {
    local base; base="$(basename "$1")"
    base="${base%.tar.gz}"
    printf '%s' "${base#*-}"
}

backup_sidecar() { printf '%s.json' "${1%.tar.gz}"; }

# --------------------------------------------------------------- creating --
# An automatic backup of an unchanged world is waste: with nobody connected
# the campaign is paused and the save is byte-identical. Both conditions
# have to hold before a run is skipped.
# WHY NOT A CHECKSUM OF THE SAVE
#
# It was a checksum, and it almost never matched: the server autosaves
# every few minutes whether or not the world is moving, so the file
# changes even while the campaign is paused. Measured over one night on an
# idle server: 23 timer runs, 21 full backups, 480 MB of byte-different
# copies of a world that had not advanced by a single day.
#
# The campaign date is the honest signal. It only moves while players are
# connected, because the campaign pauses without them - and Bannerlord
# time runs fast enough that any real session changes it. A checksum is
# still used when the server is not running, where there is no campaign
# date to read and the file genuinely does sit still.
#
# The campaign's name is part of the comparison. Two worlds can stand at
# the same date - two fresh ones always do - and a switch to the other one
# must not look like "nothing has happened".
_auto_backup_marker() {
    local date; date="$(pulse_time)"
    [[ -n "$date" ]] && printf '%s|%s' "$(cfg SAVE_NAME)" "$date"
}

_auto_backup_redundant() {
    [[ "$1" == "auto" ]] || return 1
    [[ "$(player_count)" == "0" ]] || return 1

    local now_marker last_marker
    now_marker="$(_auto_backup_marker)"

    if [[ -n "$now_marker" ]]; then
        last_marker="$(cat "$DIR_STATE/.last-auto-campaign" 2>/dev/null || true)"
        [[ -n "$last_marker" && "$now_marker" == "$last_marker" ]]
        return $?
    fi

    # Server not running: fall back to the file itself.
    local save_file current last
    save_file="$DIR_SAVES/$(cfg SAVE_NAME).sav"
    [[ -f "$save_file" ]] || return 1
    current="$(md5sum "$save_file" | cut -d' ' -f1)"
    last="$(cat "$DIR_STATE/.last-auto-hash" 2>/dev/null || true)"
    [[ -n "$last" && "$current" == "$last" ]]
}

# backup_create <type> [note]
#
# The path of the new archive comes back in BACKUP_LAST_ARCHIVE rather than
# on stdout. Returning it on stdout invites `a="$(backup_create ...)"`,
# which runs the whole function in a subshell - and the temporary directory
# it registered for cleanup is then forgotten when that subshell ends. That
# is precisely how a staging directory was left behind by every backup.
BACKUP_LAST_ARCHIVE=""
backup_create() {
    local type="${1:-manual}" note="${2:-}"
    local stamp name archive staging

    mkdir -p "$DIR_BACKUPS" "$DIR_STATE"

    if _auto_backup_redundant "$type"; then
        log "Automatic backup skipped: the campaign is unchanged and nobody is connected."
        return 0
    fi

    # A backup of a running server must capture the current state, not the
    # last autosave.
    if container_running && server_is_serving; then
        server_save || warn "Save not confirmed. Backing up what is on disk."
    else
        log "Server is not serving. Backing up the state on disk."
    fi

    stamp="$(date +%Y%m%d-%H%M%S)"
    name="${type}-${stamp}.tar.gz"
    archive="$DIR_BACKUPS/$name"
    make_temp_dir "$DIR_BACKUPS" staging
    # Installations from before mods have no userconfigs/ yet, and tar
    # fails on a directory that is not there.
    mkdir -p "$DIR_USERCONFIGS"

    _backup_write_manifest "$staging/manifest.json" "$type" "$stamp" "$note"
    _backup_write_readme   "$staging/BACKUP-INFO.txt" "$type" "$stamp" "$note"

    log "Creating backup $name"
    # Written as .part first: an interrupted backup must never look like a
    # complete one.
    if ! tar -czf "${archive}.part" \
            --exclude='*.bak' --exclude='compose.env' \
            -C "$INSTALL_DIR" "${BACKUP_DIRS[@]}" \
            -C "$staging" manifest.json BACKUP-INFO.txt 2>/dev/null; then
        rm -f "${archive}.part"
        fail "$EX_BACKUP" "Could not create the backup archive." "Check free space in $DIR_BACKUPS."
    fi

    chmod 0600 "${archive}.part"
    mv -f "${archive}.part" "$archive"
    cp -f "$staging/manifest.json" "$(backup_sidecar "$archive")"
    chmod 0600 "$(backup_sidecar "$archive")"

    ok "Backup created: $name ($(human_size_simple "$(stat -c %s "$archive")"))"

    # Remember what "nothing has happened since" means for the next run.
    if [[ "$type" == "auto" ]]; then
        local marker; marker="$(_auto_backup_marker)"
        [[ -n "$marker" ]] && printf '%s\n' "$marker" >"$DIR_STATE/.last-auto-campaign"
        [[ -f "$DIR_SAVES/$(cfg SAVE_NAME).sav" ]] && \
            md5sum "$DIR_SAVES/$(cfg SAVE_NAME).sav" | cut -d' ' -f1 >"$DIR_STATE/.last-auto-hash"
    fi

    BACKUP_LAST_ARCHIVE="$archive"
    backup_prune
}

_backup_write_manifest() {
    local file="$1" type="$2" stamp="$3" note="$4"
    # Deliberately no hostname: backups travel to other machines and other
    # people, and the host name does not have to travel with them.
    jq -n \
        --arg id "$stamp" \
        --arg type "$type" \
        --arg note "$note" \
        --arg created "$(date -Is)" \
        --arg save "$(cfg SAVE_NAME)" \
        --arg label "$(cfg SERVER_LABEL)" \
        --arg campaign "$(pulse_time)" \
        --arg coop "$(server_version)" \
        --arg manager "$MANAGER_VERSION" \
        --arg channel "$(cfg INSTALL_CHANNEL)" \
        --argjson mods "$(_backup_mods_json)" \
        '{
            id: $id, type: $type, note: $note, created: $created,
            save_name: $save, server_label: $label, campaign_date: $campaign,
            coop_version: $coop, manager_version: $manager,
            install_channel: $channel, mods: $mods,
            contents: ["saves","config","coopdata","userconfigs"]
        }' >"$file"
}

# The configured mods, with what was installed of each.
_backup_mods_json() {
    local state="{}"
    [[ -f "$FILE_STATE" ]] && state="$(cat "$FILE_STATE")"
    jq -c --arg ids "$(cfg MODS)" '
        [ ($ids | split(" ")[] | select(. != "")) as $w
          | {workshop_id: $w} + ((.mods // {})[$w] // {} | {module_id, name, version}) ]
    ' <<<"$state" 2>/dev/null || printf '[]'
}

# One line per mod for the human-readable description.
_backup_mods_text() {
    _backup_mods_json | jq -r '.[] | "  \(.name // .module_id // "?") \(.version // "") (\(.workshop_id))"' 2>/dev/null
}

_backup_write_readme() {
    local file="$1" type="$2" stamp="$3" note="$4"
    cat >"$file" <<EOF
Bannerlord Coop Server backup
=============================

Backup ID     : $stamp
Type          : $type${note:+  ($note)}
Created       : $(date -Is)
Campaign save : $(cfg SAVE_NAME)
Campaign date : $(pulse_time)
Coop build    : $(server_version)
Manager       : $MANAGER_VERSION
Mods          : $( mods_configured && printf '%s' "$(mods_ids | grep -c .)" || printf 'none' )
$(_backup_mods_text)

Contents: saves/, config/, coopdata/, userconfigs/

This archive contains config/server.env, which holds the server password.
Treat it as a secret.

Restore with:
    coop backup restore $stamp

Or by hand, with the server stopped:
    tar -xzf <archive> -C <install-dir> saves config coopdata userconfigs
EOF
}

# --------------------------------------------------------------- retention --
# Three limits, applied in order. The count is per reason, because the
# reasons are not equally replaceable: automatic backups are a rolling
# window, while manual and pre-restore ones exist because somebody chose to
# make them. Those two are never pruned by the age or size limits.
backup_prune() {
    local type keep files=() i

    for type in "${BACKUP_TYPES[@]}"; do
        keep="$(_backup_keep_for "$type")"
        [[ "$keep" =~ ^[0-9]+$ ]] || continue
        mapfile -t files < <(_backup_files_of_type "$type")
        for (( i = keep; i < ${#files[@]}; i++ )); do
            log "Retention: removing $(basename "${files[$i]}")"
            _backup_remove "${files[$i]}"
        done
    done

    _backup_prune_by_age
    _backup_prune_by_size
    _backup_sweep_stale_temp
}

# An EXIT trap does not run when a process is killed outright or the machine
# loses power, so trap-based cleanup cannot be the only defence against
# stray staging directories - each of which holds a full copy of a campaign.
# Anything older than an hour is certainly not in use any more.
_backup_sweep_stale_temp() {
    local d
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        debug "removing stale staging directory $(basename "$d")"
        rm -rf -- "$d"
    done < <(find "$DIR_BACKUPS" "$INSTALL_DIR" -maxdepth 1 -type d \
                  -name '.coop-tmp.*' -mmin +60 2>/dev/null
             find "$INSTALL_DIR" -maxdepth 1 -type d \
                  -name '.restore-old-*' -mmin +60 2>/dev/null)
}

_backup_files_of_type() {
    find "$DIR_BACKUPS" -maxdepth 1 -name "${1}-*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2-
}

_backup_all_files() {
    find "$DIR_BACKUPS" -maxdepth 1 -name '*.tar.gz' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2-
}

_backup_remove() {
    rm -f -- "$1" "$(backup_sidecar "$1")"
}

_backup_prune_by_age() {
    local days; days="$(cfg BACKUP_MAX_AGE_DAYS)"
    [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )) || return 0
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        log "Retention: removing $(basename "$f") (older than ${days} days)"
        _backup_remove "$f"
    done < <(find "$DIR_BACKUPS" -maxdepth 1 -name 'auto-*.tar.gz' -type f -mtime "+${days}" 2>/dev/null)
}

_backup_prune_by_size() {
    local cap_gb cap_bytes total f size
    cap_gb="$(cfg BACKUP_MAX_TOTAL_GB)"
    [[ "$cap_gb" =~ ^[0-9]+$ ]] && (( cap_gb > 0 )) || return 0
    cap_bytes=$(( cap_gb * 1024 * 1024 * 1024 ))

    total=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        total=$(( total + $(stat -c %s "$f") ))
    done < <(_backup_all_files)

    (( total > cap_bytes )) || return 0

    # Oldest automatic backups go first; deliberate ones are left alone
    # even when that means staying over the cap.
    local oldest_first=()
    mapfile -t oldest_first < <(_backup_files_of_type auto | tac)
    for f in "${oldest_first[@]}"; do
        (( total > cap_bytes )) || break
        size="$(stat -c %s "$f")"
        log "Retention: removing $(basename "$f") (total size over ${cap_gb} GB)"
        _backup_remove "$f"
        total=$(( total - size ))
    done
    (( total > cap_bytes )) && warn "Backups still exceed ${cap_gb} GB; only manual and safety backups remain."
    return 0
}

# ---------------------------------------------------------------- listing --
backup_meta() {
    local archive="$1" field="$2" sidecar
    sidecar="$(backup_sidecar "$archive")"
    if [[ -f "$sidecar" ]]; then
        jq -r --arg f "$field" '.[$f] // ""' "$sidecar" 2>/dev/null
    else
        tar -xzOf "$archive" manifest.json 2>/dev/null | jq -r --arg f "$field" '.[$f] // ""' 2>/dev/null
    fi
}

backup_list() {
    local files=() f rows=() n=0
    mapfile -t files < <(_backup_all_files)

    if is_json; then
        local entries="[]"
        for f in "${files[@]}"; do
            entries="$(jq -c \
                --argjson acc "$entries" \
                --arg id "$(backup_meta "$f" id)" \
                --arg type "$(backup_meta "$f" type)" \
                --arg note "$(backup_meta "$f" note)" \
                --arg created "$(backup_meta "$f" created)" \
                --arg file "$(basename "$f")" \
                --argjson bytes "$(stat -c %s "$f")" \
                -n '$acc + [{id:$id, type:$type, note:$note, created:$created, file:$file, bytes:$bytes}]')"
        done
        jq -n --argjson b "$entries" --arg dir "$DIR_BACKUPS" '{ok:true, directory:$dir, count:($b|length), backups:$b}'
        return 0
    fi

    if (( ${#files[@]} == 0 )); then
        out_title "Backups"
        out_line "  No backups yet. Create one with: coop backup"
        out_line ""
        return 0
    fi

    rows=($'#\tID\tCREATED\tTYPE\tSIZE\tNOTE')
    for f in "${files[@]}"; do
        n=$(( n + 1 ))
        rows+=("$(printf '%d\t%s\t%s\t%s\t%s\t%s' \
            "$n" \
            "$(backup_meta "$f" id)" \
            "$(date -d "@$(stat -c %Y "$f")" '+%Y-%m-%d %H:%M')" \
            "$(backup_meta "$f" type)" \
            "$(human_size_simple "$(stat -c %s "$f")")" \
            "$(backup_meta "$f" note)")")
    done
    out_title "Backups"
    out_table "${rows[@]}"
    out_line ""
    out_line "  Restore with: coop backup restore <ID>"
    out_line ""
}

backup_info() {
    local archive; archive="$(backup_resolve "$1")"
    if is_json; then
        tar -xzOf "$archive" manifest.json 2>/dev/null | jq '. + {ok:true}'
        return 0
    fi
    out_title "Backup $(basename "$archive")"
    tar -xzOf "$archive" BACKUP-INFO.txt 2>/dev/null || out_line "  (no manifest in this archive)"
    out_line ""
    out_line "Campaign saves in this archive:"
    tar -tzf "$archive" | grep -E '^saves/.*\.sav$' | sed 's|^saves/|  |'
    out_line ""
}

# ------------------------------------------------------------- resolution --
# Accepts a backup ID, a file name, or a position from the last listing.
# Never a free path: an archive is only ever taken from the backup
# directory, so a crafted argument cannot reach elsewhere on the disk.
backup_resolve() {
    local want="${1:?a backup ID is required}" f files=()

    if [[ "$want" =~ ^[0-9]+$ ]] && (( ${#want} <= 3 )); then
        mapfile -t files < <(_backup_all_files)
        (( want >= 1 && want <= ${#files[@]} )) \
            || fail "$EX_BACKUP" "There is no backup number $want." "List them with: coop backup list"
        printf '%s' "${files[$(( want - 1 ))]}"
        return 0
    fi

    # Reject anything that tries to leave the backup directory.
    [[ "$want" != */* && "$want" != *".."* ]] \
        || fail "$EX_BACKUP" "Invalid backup ID: $want" "Backups are identified by ID or file name, not by path."

    for f in "$DIR_BACKUPS/$want" "$DIR_BACKUPS/$want.tar.gz"; do
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    while IFS= read -r f; do
        [[ "$(backup_meta "$f" id)" == "$want" ]] && { printf '%s' "$f"; return 0; }
    done < <(_backup_all_files)

    fail "$EX_BACKUP" "No backup found with ID '$want'." "List them with: coop backup list"
}

# backup_select_interactive
#
# Used when `coop backup restore` is called without an ID. Shows the list
# and asks. Refuses in non-interactive mode rather than picking something
# on the caller's behalf - choosing which campaign to overwrite is not a
# decision a default should make.
backup_select_interactive() {
    local files=() choice
    mapfile -t files < <(_backup_all_files)
    (( ${#files[@]} > 0 )) || fail "$EX_BACKUP" \
        "There are no backups to restore." \
        "Create one with: coop backup"

    is_interactive || fail "$EX_USAGE" \
        "Which backup should be restored?" \
        "Pass an ID: coop backup restore <id>" \
        "List them with: coop backup list --json"

    backup_list
    ask choice "Select a backup by number or ID"
    [[ -n "$choice" ]] || fail "$EX_USAGE" "No backup selected."
    printf '%s' "$choice"
}

# ------------------------------------------------------------- validation --
# A backup may have come from elsewhere. Before anything is unpacked, the
# archive has to prove it is what it claims to be.
backup_validate() {
    local archive="$1" members

    tar -tzf "$archive" >/dev/null 2>&1 \
        || fail "$EX_BACKUP" "The archive is damaged or not a gzip tar: $(basename "$archive")"

    members="$(tar -tzf "$archive")"

    if grep -qE '^/|(^|/)\.\./' <<<"$members"; then
        fail "$EX_BACKUP" \
            "The archive contains absolute or traversing paths and will not be restored." \
            "This archive is not safe: $(basename "$archive")"
    fi
    if grep -qvE '^(saves|config|coopdata|userconfigs)(/|$)|^manifest\.json$|^BACKUP-INFO\.txt$' <<<"$members"; then
        fail "$EX_BACKUP" \
            "The archive contains unexpected entries and will not be restored." \
            "Inspect it with: tar -tzf $archive"
    fi
    grep -qE '^saves/' <<<"$members" \
        || fail "$EX_BACKUP" "The archive contains no saves/ directory."

    debug "archive validated: $(basename "$archive")"
}

# ---------------------------------------------------------------- restore --
backup_restore() {
    local archive="$1"
    local staging swap_done=() dir old

    archive="$(backup_resolve "$archive")"
    backup_validate "$archive"

    out_title "Restore from $(basename "$archive")"
    tar -xzOf "$archive" BACKUP-INFO.txt 2>/dev/null | sed 's/^/  /' || true
    out_line ""
    out_line "  WARNING"
    out_line "  Restoring replaces the current server configuration and campaign save"
    out_line "  data. A safety backup of the current state is created first."
    out_line ""
    confirm "Continue?" no || { log "Cancelled."; return 0; }

    local key
    local -A host_values=()
    for key in "${BACKUP_HOST_SETTINGS[@]}"; do host_values[$key]="$(cfg "$key")"; done

    # 1. staging on the same filesystem, so the swap below is a rename
    make_temp_dir "$INSTALL_DIR" staging
    log "Unpacking to a staging directory"
    tar -xzf "$archive" -C "$staging" \
        || fail "$EX_BACKUP" "Could not unpack the archive."

    # 2. does the unpacked content make sense?
    local save_name restored_save
    save_name="$(backup_meta "$archive" save_name)"
    if [[ -n "$save_name" ]]; then
        restored_save="$staging/saves/${save_name}.sav"
        [[ -f "$restored_save" ]] \
            || warn "The archive names save '$save_name' but does not contain ${save_name}.sav."
    fi

    # 3. stop, then take the safety backup while the world is at rest
    server_refresh_image
    server_stop
    log "Creating a pre-restore safety backup"
    backup_create pre-restore "before restoring $(basename "$archive")" >/dev/null

    # 4. the swap itself: rename out, rename in, and remember what was
    #    moved so a failure can be undone
    log "Swapping in the restored data"
    for dir in "${BACKUP_DIRS[@]}"; do
        [[ -d "$staging/$dir" ]] || continue
        old="$INSTALL_DIR/.restore-old-$dir.$$"
        if [[ -d "$INSTALL_DIR/$dir" ]]; then
            if ! mv -f "$INSTALL_DIR/$dir" "$old"; then
                _restore_rollback "${swap_done[@]}"
                fail "$EX_BACKUP" "Could not move the existing $dir aside. Nothing was changed."
            fi
        fi
        if ! mv -f "$staging/$dir" "$INSTALL_DIR/$dir"; then
            [[ -d "$old" ]] && mv -f "$old" "$INSTALL_DIR/$dir"
            _restore_rollback "${swap_done[@]}"
            fail "$EX_BACKUP" "Could not put the restored $dir in place. The previous state was kept."
        fi
        swap_done+=("${dir}:${old}")
    done

    # 5. ownership belongs to THIS host. The archive carries the numeric
    #    IDs of wherever it was made; adopting those would leave the
    #    campaign unreadable to the container.
    chown -R "$(cfg PUID):$(cfg PGID)" \
        "$DIR_SAVES" "$DIR_CONFIG" "$DIR_COOPDATA" "$DIR_USERCONFIGS" 2>/dev/null || true

    # 6. the restored config is now the truth - reload and regenerate.
    #    It may name mods this host does not have; the start below
    #    downloads them, in their current versions, since the Workshop
    #    keeps no others. The settings that describe this host stay as
    #    they were.
    CFG=(); config_load
    _backup_keep_host_settings host_values
    config_write_compose_env
    server_config_render

    # 7. The swap is complete, so the displaced copies have done their job.
    #    They are removed whether or not the server starts: the route back
    #    is the pre-restore backup taken in step 6, which is a single
    #    archive rather than three loose directories. Keeping them "just in
    #    case" would leave a full copy of the campaign behind after every
    #    failed restore, without anything ever cleaning it up.
    for dir in "${swap_done[@]}"; do rm -rf -- "${dir#*:}"; done

    # 8. start and verify. Mods of the replaced state go once the restored
    #    one serves; the pre-restore backup names them.
    if server_start; then
        mods_prune
        ok "Restore complete"
        local when; when="$(pulse_time)"
        out_line ""
        out_line "  Campaign : $(cfg SAVE_NAME)${when:+  $when}"
        out_line "  Backup   : $(basename "$archive")"
        out_line ""
        return 0
    fi

    warn "The server did not come up after the restore."
    out_line "    The restored data is in place and the previous state is still available"
    out_line "    as the pre-restore backup. Inspect the logs, then decide:"
    out_line "      coop logs"
    out_line "      coop backup list"
    return "$EX_HEALTH"
}

# _backup_keep_host_settings <name of an associative array>
#
# After a restored server.env has been loaded: puts back this host's value
# of every setting in BACKUP_HOST_SETTINGS where the backup's differs, and
# writes them to server.env. An empty value of this host's is not kept, so
# a host without a Steam account takes the backup's.
_backup_keep_host_settings() {
    local -n _host="$1"
    local key kept=()
    for key in "${BACKUP_HOST_SETTINGS[@]}"; do
        [[ -n "${_host[$key]:-}" && "$(cfg "$key")" != "${_host[$key]}" ]] || continue
        log "Keeping this host's $key, ${_host[$key]}; the backup has $(cfg "$key")."
        cfg_set "$key" "${_host[$key]}"
        kept+=("$key")
    done
    (( ${#kept[@]} )) || return 0
    config_derive_paths
    config_persist "$FILE_CONFIG" "${kept[@]}"
}

_restore_rollback() {
    local entry dir old
    for entry in "$@"; do
        dir="${entry%%:*}"; old="${entry#*:}"
        [[ -d "$old" ]] || continue
        rm -rf -- "${INSTALL_DIR:?}/$dir"
        mv -f "$old" "$INSTALL_DIR/$dir"
    done
    (( $# )) && warn "Rolled back the partial restore; the previous state is in place."
}

# ------------------------------------------------------------- save import --
# Bringing a campaign over from a Windows machine or another server.
backup_import_save() {
    local src="${1:?a source directory is required}"
    local save_file count

    [[ -d "$src" ]] || fail "$EX_USAGE" "Not a directory: $src"

    count="$(find "$src" -maxdepth 1 -name '*.sav' -type f | wc -l)"
    (( count > 0 )) || fail "$EX_USAGE" \
        "No .sav files found in $src" \
        "Point this at the 'Game Saves' directory, not at a single file."

    out_title "Import campaign saves"
    out_line "  Source: $src"
    out_line ""
    while IFS= read -r save_file; do
        local base json
        base="$(basename "$save_file" .sav)"
        json="$src/${base}.json"
        if _campaign_reserved "$base"; then
            out_check info "$(printf '%-28s %s' "$base" "kept by the server for its own use, not a campaign")"
        elif [[ -f "$json" ]]; then
            out_check ok "$(printf '%-28s %s' "$base" "save and player data present")"
        else
            out_check warn "$(printf '%-28s %s' "$base" "no ${base}.json: returning players start at character creation")"
        fi
    done < <(find "$src" -maxdepth 1 -name '*.sav' -type f | sort)
    out_line ""
    out_line "  Existing saves in $DIR_SAVES will be overwritten where names match."
    out_line ""
    confirm "Import these saves?" no || { log "Cancelled."; return 0; }

    server_stop
    log "Creating a backup before importing"
    backup_create manual "before save import" >/dev/null

    mkdir -p "$DIR_SAVES"
    cp -a "$src/." "$DIR_SAVES/" || fail "$EX_BACKUP" "Could not copy the saves."
    chown -R "$(cfg PUID):$(cfg PGID)" "$DIR_SAVES" 2>/dev/null || true
    ok "Saves imported"

    out_line ""
    out_line "  Host the imported campaign, which also starts the server:"
    out_line "    coop campaign use \"<name>\""
    out_line ""
}
