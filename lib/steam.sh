# shellcheck shell=bash
#
# steam.sh - Steam authentication and Workshop downloads, as a capability
# of its own.
#
# Nothing in this file knows about the installer's user interface, and the
# installer does not know how Steam works. That separation is what makes
# the later hosting case possible: a backend can place a prepared session
# in state/steam and provision an instance without a single prompt.
#
# WHY THE PASSWORD NEVER PASSES THROUGH THIS CODE
# -----------------------------------------------
# The tempting shape is to read the password with `read -s` and hand it to
# `steamcmd +login user password`. That would put the password in the
# container's command line, where `ps` and `docker inspect` can read it.
# So the terminal is handed to SteamCMD instead: it prompts for the
# password and the Steam Guard code itself, and the manager never sees
# either. What persists afterwards is Steam's own session in a volume -
# not a credential this project invented a place for.
#
# Steam Guard is respected as it stands. There is no way around it and no
# attempt is made to find one.

_steam_volumes() {
    printf '%s\n' \
        -v "${DIR_STEAM}:/root/.local/share/Steam" \
        -v "${DIR_WORKSHOP}:/root/.local/share/Steam/steamapps/workshop"
}

# _steamcmd [docker-flags...] -- [steamcmd-args...]
_steamcmd() {
    local docker_flags=() steam_args=() seen=0 arg
    for arg in "$@"; do
        if [[ "$arg" == "--" && $seen -eq 0 ]]; then seen=1; continue; fi
        if (( seen )); then steam_args+=("$arg"); else docker_flags+=("$arg"); fi
    done

    mkdir -p "$DIR_STEAM" "$DIR_WORKSHOP"
    # shellcheck disable=SC2046  # word splitting of the volume list is intended
    docker run --rm "${docker_flags[@]}" \
        $(_steam_volumes) \
        "$(cfg STEAMCMD_IMAGE)" "${steam_args[@]}"
}

# Files Steam writes once a session exists. Checking for them is an offline
# test: it proves a session was established, not that it is still valid.
steam_session_files_present() {
    [[ -d "$DIR_STEAM" ]] || return 1
    compgen -G "${DIR_STEAM}/config/config.vdf" >/dev/null 2>&1 && return 0
    compgen -G "${DIR_STEAM}/ssfn*" >/dev/null 2>&1 && return 0
    return 1
}

# steam_status [--probe]
#
# Without --probe this is instant and offline. With it, SteamCMD actually
# logs in and quits - a few seconds, no download - which is the only way to
# tell an expired session from a valid one.
#
# Prints one of: absent | present | valid | expired
steam_status() {
    local probe=0
    [[ "${1:-}" == "--probe" ]] && probe=1

    if [[ -z "$(cfg STEAM_USERNAME)" ]]; then
        printf 'absent'; return 0
    fi
    if ! steam_session_files_present; then
        printf 'absent'; return 0
    fi
    if (( ! probe )); then
        printf 'present'; return 0
    fi

    local out
    out="$(_steamcmd -- +login "$(cfg STEAM_USERNAME)" +quit 2>&1 | _steam_clean)" || true
    # "Logging in using cached credentials" means success; "Cached
    # credentials not found" means the opposite. Matching the bare phrase
    # would read the failure as a success, so the verb has to be in it.
    if grep -qiE 'Logging in using cached credentials|Logged in OK|Waiting for (user info|client config)' <<<"$out"; then
        printf 'valid'
    elif grep -qiE 'Login Failure|Cached credentials not found|two-factor|Steam Guard|password:' <<<"$out"; then
        printf 'expired'
    else
        # Cannot tell - Steam may simply be unreachable. Saying "expired"
        # would send the user off to re-authenticate for nothing.
        printf 'present'
    fi
}

steam_status_explain() {
    case "$1" in
        absent)  printf 'no Steam session. Run: coop steam login' ;;
        present) printf 'a session exists (not verified)' ;;
        valid)   printf 'authenticated' ;;
        expired) printf 'session expired. Run: coop steam login' ;;
    esac
}

# ------------------------------------------------------------------- login --
# Everything `coop steam login` needs in order to run on a host where
# nothing has been installed yet.
#
# This command has to be the one that can go first: Steam Guard cannot be
# answered without a terminal, so the documented way to provision a server
# unattended is to authenticate once by hand and let the install reuse the
# session. A login that required an existing installation would make that
# order impossible - which is exactly what it did.
#
# SteamCMD itself runs in a container, so Docker is a genuine prerequisite
# rather than a convenience. Installing it here is announced, not silent.
steam_prepare() {
    mkdir -p "$DIR_STEAM" "$DIR_WORKSHOP" "$DIR_CONFIG" "$DIR_STATE" \
        || fail "$EX_RUNTIME" "Cannot create $INSTALL_DIR"
    chmod 0750 "$INSTALL_DIR" 2>/dev/null || true

    if ! docker info >/dev/null 2>&1; then
        log "SteamCMD runs in a container, so Docker has to be available first."
        compat_detect
        deps_install_base
        deps_install_docker
    fi
}

steam_login() {
    docker_require
    local user="${1:-$(cfg STEAM_USERNAME)}"

    if [[ -z "$user" ]]; then
        is_interactive || fail "$EX_CONFIG" \
            "No Steam account configured." \
            "Pass --steam-username <name>, or run 'coop steam login' on a terminal."
        ask user "Steam username"
    fi
    [[ -n "$user" ]] || fail "$EX_CONFIG" "A Steam username is required."

    is_interactive || fail "$EX_STEAM" \
        "Steam authentication needs a terminal." \
        "Steam Guard cannot be answered non-interactively." \
        "Authenticate once with 'coop steam login', then automation can reuse the session."

    cfg_set STEAM_USERNAME "$user"

    out_line ""
    out_line "Steam authentication"
    out_line ""
    out_line "  Downloading the Bannerlord Coop Workshop item requires a Steam account"
    out_line "  that owns Mount & Blade II: Bannerlord. Anonymous access does not work."
    out_line ""
    out_line "  SteamCMD will now ask for the password and, if the account has Steam"
    out_line "  Guard enabled, for a code. It asks directly, so the password is not"
    out_line "  handled by this installer and is never written anywhere."
    out_line ""

    # -it hands the terminal straight to SteamCMD.
    _steamcmd -it -- +login "$user" +quit || true

    if steam_session_files_present; then
        _steam_fix_ownership
        ok "Steam session stored in ${DIR_STEAM}"
        return 0
    fi
    fail "$EX_STEAM" \
        "Steam authentication did not complete." \
        "Check the username and password, and the Steam Guard code if one was requested." \
        "Retry with: coop steam login"
}

steam_logout() {
    if ! steam_session_files_present; then
        log "No Steam session to remove."
        return 0
    fi
    confirm "Remove the stored Steam session?" no || return 0
    rm -rf -- "${DIR_STEAM:?}"/config "${DIR_STEAM:?}"/ssfn* 2>/dev/null || true
    ok "Steam session removed. The next download will need 'coop steam login'."
}

# The downloaded Workshop files are read by the game server, which runs as
# the service user, so those have to change hands.
#
# The session directory must NOT. It is mounted over the image's own
# /root/.local/share/Steam, which means it holds SteamCMD's installation as
# well as the session - and SteamCMD runs as root in that container.
# Chowning it away from root makes the next run die with
# "Couldn't create cache directory ... error 13", which looks for all the
# world like an expired session and is not.
_steam_fix_ownership() {
    chown -R "$(cfg PUID):$(cfg PGID)" "$DIR_WORKSHOP" 2>/dev/null || true
}

# Strips the colour codes SteamCMD writes even when not on a terminal.
# Every pattern below is matched against the cleaned text, because
# "Logging in user ... to Steam Public...<esc>[0mOK" does not contain the
# literal string a naive match would look for.
_steam_clean() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }

# ---------------------------------------------------------------- download --
workshop_item_dir() {
    printf '%s/content/%s/%s' "$DIR_WORKSHOP" "$(cfg WORKSHOP_APP_ID)" "$(cfg WORKSHOP_ITEM_ID)"
}

workshop_manifest() {
    printf '%s/appworkshop_%s.acf' "$DIR_WORKSHOP" "$(cfg WORKSHOP_APP_ID)"
}

# steam_download
#
# Never prompts. A missing or expired session is an error with an
# instruction, which is what lets a provisioning backend call this.
steam_download() {
    docker_require
    local user; user="$(cfg STEAM_USERNAME)"
    [[ -n "$user" ]] || fail "$EX_STEAM" \
        "No Steam account configured." \
        "Run: coop steam login"

    steam_session_files_present || fail "$EX_STEAM" \
        "No Steam session found." \
        "Authenticate once, then this will run unattended: coop steam login"

    log "Downloading Workshop item $(cfg WORKSHOP_ITEM_ID) (about 6 GB on a first install)"

    local out rc=0
    out="$(_steamcmd -- +login "$user" \
            +workshop_download_item "$(cfg WORKSHOP_APP_ID)" "$(cfg WORKSHOP_ITEM_ID)" validate \
            +quit 2>&1 | _steam_clean)" || rc=$?

    printf '%s\n' "$out" | tail -6 >&2
    _steam_fix_ownership

    if grep -q 'Success. Downloaded item' <<<"$out"; then
        ok "Workshop item downloaded"
        return 0
    fi

    if grep -qiE 'Login Failure|Cached credentials not found|two-factor|Steam Guard|password:' <<<"$out"; then
        fail "$EX_STEAM" \
            "The Steam session has expired." \
            "Re-authenticate once, then retry: coop steam login"
    fi
    if grep -qiE 'Timeout downloading|Failure|ERROR!' <<<"$out"; then
        fail "$EX_STEAM" \
            "The Workshop download failed." \
            "Possible causes: Steam is unreachable, the item is unavailable," \
            "or the account does not own Mount & Blade II: Bannerlord." \
            "Full output: ${COOP_LOG_FILE:-run with --verbose}"
    fi
    fail "$EX_STEAM" \
        "The Workshop download did not report success (steamcmd exit $rc)." \
        "Run 'coop doctor' and check the log."
}

# steam_download_items <workshop-id>...
#
# Any number of Workshop items in one SteamCMD session: a mod set is often
# eight items, and eight logins would be eight times the wait. Never
# prompts, like steam_download. Fails naming the items that did not come.
steam_download_items() {
    (( $# )) || return 0
    docker_require
    local user; user="$(cfg STEAM_USERNAME)"
    [[ -n "$user" ]] || fail "$EX_STEAM" \
        "No Steam account configured." \
        "Run: coop steam login"
    steam_session_files_present || fail "$EX_STEAM" \
        "No Steam session found." \
        "Authenticate once, then this will run unattended: coop steam login"

    local args=() id out rc=0 missing=()
    for id in "$@"; do
        args+=(+workshop_download_item "$(cfg WORKSHOP_APP_ID)" "$id" validate)
    done
    log "Downloading $# Workshop item(s)"
    out="$(_steamcmd -- +login "$user" "${args[@]}" +quit 2>&1 | _steam_clean)" || rc=$?
    _steam_fix_ownership

    if grep -qiE 'Login Failure|Cached credentials not found|two-factor|Steam Guard|password:' <<<"$out"; then
        fail "$EX_STEAM" \
            "The Steam session has expired." \
            "Re-authenticate once, then retry: coop steam login"
    fi
    for id in "$@"; do
        grep -q "Success. Downloaded item $id " <<<"$out" || missing+=("$id")
    done
    if (( ${#missing[@]} )); then
        printf '%s\n' "$out" | grep -E 'ERROR|Failure' | tail -6 >&2
        fail "$EX_STEAM" \
            "Steam did not deliver Workshop item(s) ${missing[*]} (steamcmd exit $rc)." \
            "Each has to be a Bannerlord Workshop item, not a collection, and visible to your account." \
            "Steam may also be unreachable. Nothing was changed; retry later."
    fi
    ok "Downloaded $# Workshop item(s)"
}

# ------------------------------------------------------------ installed version --
# workshop_item_time <workshop-id> - when the downloaded copy of an item was
# published, from Steam's own manifest.
workshop_item_time() {
    local acf; acf="$(workshop_manifest)"
    [[ -f "$acf" ]] || { printf '0'; return 0; }
    grep -A6 "\"$1\"" "$acf" 2>/dev/null \
        | sed -n 's/.*"timeupdated"[[:space:]]*"\([0-9]*\)".*/\1/p' \
        | head -1 | grep -E '^[0-9]+$' || printf '0'
}

# Timestamp of the INSTALLED version, from Steam's own manifest.
workshop_local_time() { workshop_item_time "$(cfg WORKSHOP_ITEM_ID)"; }

# workshop_details <workshop-id>... - what Steam publishes about the items,
# as a JSON array. Anonymous, no API key, no login.
workshop_details() {
    local args=(-d "itemcount=$#") i=0 id
    for id in "$@"; do
        args+=(-d "publishedfileids[$i]=$id")
        i=$(( i + 1 ))
    done
    curl -fsS --max-time 20 \
        -X POST "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
        "${args[@]}" 2>/dev/null \
        | jq -c '.response.publishedfiledetails // empty' 2>/dev/null
}

# Timestamp of the LATEST version according to Steam. Anonymous, no API key,
# no login - which is why the nightly check can use it.
workshop_remote_time() {
    workshop_details "$(cfg WORKSHOP_ITEM_ID)" | jq -r '.[0].time_updated // empty' 2>/dev/null
}

# -------------------------------------------------------------- custom channel --
# The alternative source provider. Deliberately plain: it exists so the
# architecture is not tied to the Workshop, not because it is the
# comfortable path.
custom_source_available() {
    local src; src="$(cfg CUSTOM_SOURCE_PATH)"
    [[ -n "$src" && -f "$src/BannerlordCoopServer.exe" ]]
}

source_fetch() {
    case "$(cfg INSTALL_CHANNEL)" in
        workshop) steam_download ;;
        custom)
            custom_source_available || fail "$EX_CONFIG" \
                "CUSTOM_SOURCE_PATH does not contain BannerlordCoopServer.exe: $(cfg CUSTOM_SOURCE_PATH)"
            ok "Using custom build from $(cfg CUSTOM_SOURCE_PATH)"
            ;;
        *) fail "$EX_CONFIG" "Unknown install channel: $(cfg INSTALL_CHANNEL)" ;;
    esac
}

# Where the freshly fetched files live, per channel.
source_staging_dir() {
    case "$(cfg INSTALL_CHANNEL)" in
        workshop) printf '%s/DedicatedServer' "$(workshop_item_dir)" ;;
        custom)   printf '%s' "$(cfg CUSTOM_SOURCE_PATH)" ;;
    esac
}
