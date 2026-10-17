# shellcheck shell=bash
#
# campaign.sh - which world the server hosts, and switching between them.
#
# THE DANGER THIS FILE EXISTS FOR
# -------------------------------
# The server hosts exactly one campaign: the save named by SAVE_NAME. When
# no save of that name exists it does not complain. It creates a fresh world
# from default_new_game.sav and saves it under that name. On a first start
# that is exactly right; after a typo it is the worst thing that can happen
# on a server that switches between long-running campaigns. The real
# campaign stays on disk, untouched, while players connect to an empty
# world and start playing in it.
#
# So a new world is only created when somebody asked for one: at
# installation, with `coop campaign new`, or with --new-world. The request
# is recorded, and server_start() refuses to start into a save that does
# not exist without it. That one check covers every way SAVE_NAME can
# change - the commands, the interactive configuration, a hand edit of
# server.env - rather than only the commands that remember to ask.
#
# WHAT COUNTS AS A CAMPAIGN
# -------------------------
# A <name>.sav in saves/. The <name>.json beside it carries every player's
# character and co-op progress; without it the world still loads, but
# returning players are sent to character creation. A save made in
# singleplayer has no .json until its first co-op save, so a missing one is
# a warning, never a refusal.
#
# Not campaigns, although they look like one:
#   default_new_game            the template new worlds are made from
#   <name>.backup1, .backup2    generations the server rotates by itself
#   coop_bug_report             written by the in-game bug report
#   TransferSave                written on every join
#
# Names are compared without regard to case. The server is a Windows
# program, and Wine finds "Campaign.sav" when asked for "campaign.sav" - so
# a check that told the two apart would refuse a start the server would
# have served from the right save.

# Set by the interactive collector when the operator confirmed that a name
# with no campaign behind it is meant to be a new world. The request is
# only recorded once the settings are actually saved.
: "${CAMPAIGN_NEW_WORLD_OK:=0}"

_campaign_reserved() {
    case "${1,,}" in
        default_new_game|coop_bug_report|transfersave|*.backup1|*.backup2) return 0 ;;
    esac
    return 1
}

# The campaigns on disk, one name per line, sorted.
campaign_names() {
    local f base
    [[ -d "$DIR_SAVES" ]] || return 0
    for f in "$DIR_SAVES"/*.sav; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f" .sav)"
        _campaign_reserved "$base" || printf '%s\n' "$base"
    done | LC_ALL=C sort
}

# campaign_resolve <name> - the campaign's name as it is spelled on disk,
# or nothing when there is no such campaign.
campaign_resolve() {
    local want="$1" name
    [[ -n "$want" ]] || return 0
    _campaign_reserved "$want" && return 0
    [[ -f "$DIR_SAVES/${want}.sav" ]] && { printf '%s' "$want"; return 0; }
    while IFS= read -r name; do
        [[ "${name,,}" == "${want,,}" ]] && { printf '%s' "$name"; return 0; }
    done < <(campaign_names)
    return 0
}

campaign_exists() { [[ -n "$(campaign_resolve "$1")" ]]; }

# ------------------------------------------------------- new-world requests --
campaign_allow_new_world() { state_set new_world "$1"; }

# True when the configured campaign exists, or a new world under its name
# was asked for. server_start() starts nothing else.
campaign_start_allowed() {
    local name; name="$(cfg SAVE_NAME)"
    campaign_exists "$name" && return 0
    [[ "$(state_get new_world)" == "$name" ]]
}

# Once the server has written the new world, the request has done its job.
# Until then it stays: a world that was created but not yet saved has to
# be allowed to start again.
campaign_settle_new_world() {
    local pending; pending="$(state_get new_world)"
    [[ -n "$pending" ]] && campaign_exists "$pending" && state_set new_world ""
    return 0
}

# What server_start() says when it refuses.
campaign_explain_refusal() {
    local name; name="$(cfg SAVE_NAME)"
    warn "Not starting: there is no campaign named '$name' in $DIR_SAVES."
    out_line "    Starting would create a new, empty world under that name."
    out_line "    To host an existing campaign:  coop campaign list"
    out_line "                                   coop campaign use \"<name>\""
    out_line "    To start a new world:          coop campaign new \"$name\""
}

# ------------------------------------------------------------------ listing --
# A new world starts as a byte-for-byte copy of the template, timestamp
# included, and stays one until its first save. Measured on Coop v0.1.6:
# "Second World.sav" carried the template's date from the installation
# day, which made a campaign created a minute earlier look the oldest.
_campaign_never_saved() {
    [[ -f "$DIR_SAVES/default_new_game.sav" ]] \
        && cmp -s "$DIR_SAVES/${1}.sav" "$DIR_SAVES/default_new_game.sav"
}

# "Last saved" is the later of the .sav and the .json.
_campaign_last_saved() {
    local name="$1" t j
    t="$(stat -c %Y "$DIR_SAVES/${name}.sav" 2>/dev/null || echo 0)"
    j="$(stat -c %Y "$DIR_SAVES/${name}.json" 2>/dev/null || echo 0)"
    (( j > t )) && t="$j"
    printf '%s' "$t"
}

_campaign_size() {
    local name="$1" s j
    s="$(stat -c %s "$DIR_SAVES/${name}.sav" 2>/dev/null || echo 0)"
    j="$(stat -c %s "$DIR_SAVES/${name}.json" 2>/dev/null || echo 0)"
    printf '%s' $(( s + j ))
}

campaign_list() {
    local active name names=() rows=() json="[]" saved size note pending
    active="$(campaign_resolve "$(cfg SAVE_NAME)")"
    pending=""
    [[ -z "$active" ]] && pending="$(cfg SAVE_NAME)"
    mapfile -t names < <(campaign_names)

    if is_json; then
        for name in "${names[@]}"; do
            json="$(jq -c --argjson acc "$json" --arg n "$name" \
                --argjson active "$( [[ "$name" == "$active" ]] && echo true || echo false )" \
                --argjson bytes "$(_campaign_size "$name")" \
                --argjson saved "$(_campaign_last_saved "$name")" \
                --argjson fresh "$( _campaign_never_saved "$name" && echo true || echo false )" \
                --argjson player_data "$( [[ -f "$DIR_SAVES/${name}.json" ]] && echo true || echo false )" \
                -n '$acc + [{name:$n, active:$active, bytes:$bytes,
                             last_saved:(if $fresh then null else ($saved | todate) end),
                             player_data:$player_data}]')"
        done
        jq -n --argjson c "$json" --arg dir "$DIR_SAVES" --arg active "$(cfg SAVE_NAME)" \
              --argjson exists "$( [[ -n "$active" ]] && echo true || echo false )" \
            '{ok:true, directory:$dir, active:$active, active_exists:$exists,
              count:($c|length), campaigns:$c}'
        return 0
    fi

    out_title "Campaigns"
    if (( ${#names[@]} == 0 )) && [[ -z "$pending" ]]; then
        out_line "  No campaigns in $DIR_SAVES yet."
        out_line ""
        return 0
    fi

    rows=($'\tNAME\tSIZE\tLAST SAVED\tNOTE')
    for name in "${names[@]}"; do
        size="$(_campaign_size "$name")"
        note=""
        if _campaign_never_saved "$name"; then
            saved="-"
            note="new world, not saved yet"
        else
            saved="$(date -d "@$(_campaign_last_saved "$name")" '+%Y-%m-%d %H:%M')"
            [[ -f "$DIR_SAVES/${name}.json" ]] || note="no player data (.json)"
        fi
        rows+=("$(printf '%s\t%s\t%s\t%s\t%s' \
            "$( [[ "$name" == "$active" ]] && printf '*' )" \
            "$name" "$(human_size_simple "$size")" "$saved" "$note")")
    done
    [[ -n "$pending" ]] && rows+=("$(printf '*\t%s\t-\t-\t%s' "$pending" \
        "$( [[ "$(state_get new_world)" == "$pending" ]] \
            && printf 'new world, created on the next start' \
            || printf 'no save: the server will not start' )")")

    out_table "${rows[@]}"
    out_line ""
    out_line "  * the campaign this server hosts"
    out_line "  Switch:  coop campaign use \"<name>\""
    out_line "  New:     coop campaign new \"<name>\""
    out_line ""
}

# ---------------------------------------------------------------- switching --
# Switching disconnects everyone, so it asks first when anybody is on.
_campaign_confirm_players() {
    container_running || return 0
    local n; n="$(player_count)"
    (( n > 0 )) || return 0
    confirm "$n player(s) are connected and will be disconnected. Continue?" no \
        || { log "Nothing was changed."; exit 0; }
}

_campaign_apply_name() {
    cfg_set SAVE_NAME "$1"
    config_persist "$FILE_CONFIG" SAVE_NAME
    server_config_render
}

# _campaign_switch <name> <backup note>
#
# The same order for `use` and `new`: stop with a closing save, back up,
# change SAVE_NAME, start, and wait until the server actually serves. If
# the server will not serve the new campaign, the previous one is put back
# and started, so a failed switch never leaves the server down.
_campaign_switch() {
    local name="$1" note="$2" previous rc=0
    previous="$(cfg SAVE_NAME)"

    _campaign_confirm_players
    server_refresh_image
    server_stop
    log "Creating a backup before the switch"
    backup_create manual "$note" >/dev/null
    _campaign_apply_name "$name"

    server_start || rc=$?
    (( rc == 0 )) && return 0
    (( rc == 4 )) && exit "$EX_LICENSE"

    warn "The server did not serve '$name'. Switching back to '$previous'."
    server_stop
    # A new world that never came up is no longer a request anybody has.
    [[ "$(state_get new_world)" == "$name" ]] && ! campaign_exists "$name" && state_set new_world ""
    _campaign_apply_name "$previous"
    if server_start; then
        fail "$EX_HEALTH" \
            "The switch to '$name' failed; the server hosts '$previous' again." \
            "See why: coop logs -n 100"
    fi
    fail "$EX_HEALTH" \
        "The switch to '$name' failed, and '$previous' did not start again either." \
        "See why: coop logs -n 100"
}

# campaign_use <name>
campaign_use() {
    local want="$1" name current
    [[ -n "$want" ]] || fail "$EX_USAGE" "Usage: coop campaign use \"<name>\""
    name="$(campaign_resolve "$want")"
    if [[ -z "$name" ]]; then
        if _campaign_reserved "$want"; then
            fail "$EX_CONFIG" "'$want' is a file the server keeps for its own use, not a campaign." \
                "See the campaigns there are: coop campaign list"
        fi
        fail "$EX_CONFIG" \
            "There is no campaign named '$want' in $DIR_SAVES. Nothing was changed." \
            "See the campaigns there are:     coop campaign list" \
            "To start a new world under it:   coop campaign new \"$want\""
    fi

    current="$(cfg SAVE_NAME)"
    if [[ "$name" == "$current" ]]; then
        log "'$name' is already the campaign this server hosts. Nothing to do."
        return 0
    fi

    out_title "Switch campaign"
    out_kv "From" "$current"
    out_kv "To"   "$name"
    out_line ""
    [[ -f "$DIR_SAVES/${name}.json" ]] || warn \
        "$name.json is missing: the world loads, but returning players start again at character creation."

    _campaign_switch "$name" "before switching to $name"
    ok "The server hosts '$name'"
    out_line "  '$current' is still in $DIR_SAVES, unchanged. Back with: coop campaign use \"$current\""
    out_line ""
}

# campaign_new <name>
campaign_new() {
    local name="$1" reason existing current
    [[ -n "$name" ]] || fail "$EX_USAGE" "Usage: coop campaign new \"<name>\""
    reason="$(_validate_value SAVE_NAME "$name")"
    [[ -z "$reason" ]] || fail "$EX_CONFIG" "Campaign name '$name' $reason."

    existing="$(campaign_resolve "$name")"
    [[ -z "$existing" ]] || fail "$EX_CONFIG" \
        "There is already a campaign named '$existing'. Nothing was changed." \
        "To host it: coop campaign use \"$existing\""

    current="$(cfg SAVE_NAME)"
    out_title "New campaign"
    out_kv "Name"    "$name"
    out_kv "Current" "$current, which stays in $DIR_SAVES untouched"
    out_line ""
    out_line "  The server creates the world itself when it starts, from the"
    out_line "  template its build ships with. Gameplay settings (mod-config.json)"
    out_line "  are shared by every campaign on this server."
    out_line ""

    campaign_allow_new_world "$name"
    _campaign_switch "$name" "before creating $name"
    if campaign_exists "$name"; then
        ok "New campaign '$name' created and served"
    else
        ok "The server serves the new world '$name'"
        out_line "    It is written to $DIR_SAVES at the first save. Force one with: coop save"
    fi
    out_line ""
}
