# shellcheck shell=bash
#
# state.sh - installation metadata.
#
# What belongs here: facts about the installation that are not settings -
# when it was installed, which manager version wrote it, which Workshop
# version is on disk. What does not belong here: anything secret, and
# anything the user is meant to change. Settings live in server.env.
#
# The file is machine-written and machine-read; it is JSON so a hosting
# backend can consume it directly.

state_init() {
    mkdir -p "$DIR_STATE"
    [[ -f "$FILE_STATE" ]] && return 0
    jq -n \
        --arg manager "$MANAGER_VERSION" \
        --arg channel "$(cfg INSTALL_CHANNEL)" \
        --arg dir "$INSTALL_DIR" \
        --arg instance "$INSTANCE_ID" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            manager_version: $manager,
            install_channel: $channel,
            install_directory: $dir,
            instance_id: $instance,
            setup_profile: "unknown",
            installed_version: null,
            workshop_version: null,
            installed_at: $now,
            updated_at: $now
        }' >"$FILE_STATE"
    chmod 0640 "$FILE_STATE"
}

state_get() {
    [[ -f "$FILE_STATE" ]] || { printf ''; return 0; }
    jq -r --arg k "$1" '.[$k] // "" | if type=="object" or type=="array" then tojson else tostring end' \
        "$FILE_STATE" 2>/dev/null
}

# state_set <key> <value> [--raw]
#
# --raw writes the value as JSON (number, boolean, null) rather than as a
# string.
state_set() {
    local key="$1" value="$2" raw="${3:-}"
    if [[ "$raw" == "--raw" ]]; then
        state_apply '.[$k] = $v' --arg k "$key" --argjson v "$value"
    else
        state_apply '.[$k] = $v' --arg k "$key" --arg v "$value"
    fi
}

# state_apply <jq-filter> [jq-args...]
#
# For the facts that are not a flat key and value. The file is only
# replaced when jq succeeded: an empty result moved over the state file
# would erase every fact about the installation, including which license
# terms the operator accepted.
state_apply() {
    local filter="$1"; shift
    state_init
    local tmp; tmp="$(mktemp "${FILE_STATE}.XXXXXX")"
    if ! jq "$@" "$filter | .updated_at = (now | todate)" "$FILE_STATE" >"$tmp" \
        || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        warn "Could not update $FILE_STATE"
        return 1
    fi
    chmod 0640 "$tmp"
    mv -f "$tmp" "$FILE_STATE"
}

state_exists() { [[ -f "$FILE_STATE" ]]; }

# Is there an installation here at all?
#
# Judged by evidence that provisioning actually happened: the state file
# written by provision_run, or server files on disk. A server.env alone is
# not enough - `coop steam login` creates one on a bare host before
# anything is installed, and treating that as an installation would send
# the very next `coop install` into the "existing installation" menu.
installation_present() {
    [[ -d "$INSTALL_DIR" ]] && { state_exists || server_installed; }
}

# ------------------------------------------------------------- mods --
# What was installed for each mod, keyed by Workshop id: module id, name,
# version, and the Workshop timestamp the update check compares against.
state_mod_get() {
    [[ -f "$FILE_STATE" ]] || return 0
    jq -r --arg w "$1" --arg k "$2" '(.mods // {})[$w][$k] // "" | tostring' "$FILE_STATE" 2>/dev/null
}
state_mod_set()    { state_apply '.mods[$w] = $v' --arg w "$1" --argjson v "$2"; }
state_mod_remove() { state_apply 'del(.mods[$w])' --arg w "$1"; }

# ------------------------------------------------------------ update marker --
# A small file rather than a field, so the MOTD snippet and other cheap
# consumers can test for it without parsing JSON.
update_marker_set()   { date -Is >"$DIR_STATE/update-available"; }
update_marker_clear() { rm -f "$DIR_STATE/update-available"; }
update_marker_is_set(){ [[ -f "$DIR_STATE/update-available" ]]; }

# The same for mods; the file lists the Workshop ids with an update.
mods_update_marker_set()    { printf '%s\n' "$@" >"$DIR_STATE/mods-update-available" 2>/dev/null || true; }
mods_update_marker_clear()  { rm -f "$DIR_STATE/mods-update-available" 2>/dev/null || true; }
mods_update_marker_is_set() { [[ -s "$DIR_STATE/mods-update-available" ]]; }
