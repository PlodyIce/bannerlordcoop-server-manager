# shellcheck shell=bash
#
# config.sh - configuration model: specification, parsing, validation and
# atomic writing.
#
# WHY THIS FILE DOES NOT USE `source`
# -----------------------------------
# The obvious way to read a KEY=VALUE file in bash is `set -a; . file`. That
# executes the file. A value like SAVE_NAME=$(rm -rf /) would run. Today the
# only author of that file is the server's owner - but the whole point of
# this project is that a provisioning backend may write it, per instance,
# from data it did not author. So the file is parsed line by line, keys are
# checked against a whitelist, values are validated by type, and nothing is
# ever evaluated.
#
# PRIORITY (later wins)
#   1. config/defaults.env        project defaults, versioned
#   2. $INSTALL_DIR/config/server.env    the existing installation
#   3. --config <file>            a supplied configuration file
#   4. command line flags         highest

declare -gA CFG=()          # effective configuration
declare -gA CFG_OVERRIDE=() # values from the command line, applied last

# ------------------------------------------------------------------- spec --
# One row per setting: TYPE|RESTART|DESCRIPTION
#
#   TYPE      identifier | path | string | savename | int | port | bool |
#             enum:a|b | schedule
#   RESTART   yes  - the server must be restarted for a change to take effect
#             no   - picked up on the next operation
#             install - only meaningful at install time
#
# Defaults live in config/defaults.env, not here, so there is exactly one
# place to look up a default value. config_selfcheck() verifies that this
# table and that file describe the same set of keys.
declare -gA CONFIG_SPEC=(
    [INSTANCE_ID]="identifier|install|Identifier for this installation. Shapes the container, lock and systemd unit names, so one host can run more than one server."
    [INSTALL_DIR]="path|install|Absolute path holding all persistent data for this installation."
    [SERVER_LABEL]="string|no|Name used by the manager in status output and backup manifests. Not visible to joining players, because the game has no server name field."

    [INSTALL_CHANNEL]="enum:workshop,custom|install|Where the server files come from. 'workshop' downloads from the Steam Workshop; 'custom' installs from a local directory."
    [WORKSHOP_APP_ID]="int|install|Steam application ID of Mount & Blade II: Bannerlord."
    [WORKSHOP_ITEM_ID]="int|install|Steam Workshop item ID of the Bannerlord Coop dedicated server."
    [CUSTOM_SOURCE_PATH]="path|install|Directory holding the server files. Only used when INSTALL_CHANNEL=custom."

    [STEAM_USERNAME]="string|no|Steam account used to download the Workshop item. The password is never stored, only Steam's own session under state/steam."

    [MODS]="modlist|yes|Steam Workshop items the server loads as mods, as their IDs in load order. Manage them with 'coop mods'. Empty runs the server exactly as the Coop team ships it."
    [DOTNET_SDK_IMAGE]="string|no|Container image used once to build the small startup hook a server with mods needs. Pin it to a digest for reproducible installs."

    [SAVE_NAME]="savename|yes|Campaign save to host. Change it with 'coop campaign use'. A name with no save behind it starts a fresh world, which only happens when one was asked for: at installation, with 'coop campaign new', or with --new-world."
    [SERVER_PASSWORD]="string|yes|Password players must enter to join. Empty means anyone who knows the address can join."
    [GAME_PORT]="port|yes|UDP port players connect to. This is the only port that has to be reachable from the internet."
    [AUTOSAVE_MINUTES]="int|yes|Minutes between automatic world saves. 0 disables autosaving."
    [STEAM_ADVERTISE]="bool|yes|Advertise the server in a public Steam lobby when a logged-in Steam client runs on the host. Off means direct connect only."
    [SERVER_LOG_FILE]="bool|yes|Write the server's output to a file per launch in logs/, in addition to the container log."

    [LOGIN_MESSAGE]="bool|no|Show this server's state in the message at an SSH login: a Workshop update waiting, and the last backup. Ubuntu and Debian only; elsewhere it does nothing."

    [TIMEZONE]="string|yes|Time zone inside the container. 'system' adopts the host's zone."
    [MEMORY_LIMIT]="string|yes|Memory limit for the container, e.g. 4g. Empty means no limit. Measured usage is 1.2-1.6 GB."
    [PUID]="int|yes|User ID owning the data directories and running the server process."
    [PGID]="int|yes|Group ID owning the data directories."
    [WINE_BRANCH]="enum:stable,staging,devel|yes|WineHQ branch built into the runtime image."

    [BACKUP_ENABLED]="bool|no|Run automatic backups on a schedule."
    [BACKUP_SCHEDULE]="schedule|no|When automatic backups run, as a systemd OnCalendar expression."
    [BACKUP_KEEP_AUTO]="int|no|Number of automatic backups to keep."
    [BACKUP_KEEP_MANUAL]="int|no|Number of manual backups to keep."
    [BACKUP_KEEP_PREUPDATE]="int|no|Number of pre-update backups to keep."
    [BACKUP_KEEP_PRERESTORE]="int|no|Number of pre-restore safety backups to keep."
    [BACKUP_MAX_AGE_DAYS]="int|no|Delete automatic backups older than this many days. 0 disables the age limit."
    [BACKUP_MAX_TOTAL_GB]="int|no|Total size cap for the backup directory. Oldest automatic backups are removed first. 0 disables the cap."

    [AUTO_UPDATE]="bool|no|Install Workshop updates automatically. Off by default: every player must run the same Coop build, so an unattended update would lock out anyone who has not updated."
    [UPDATE_CHECK_ENABLED]="bool|no|Check for new Workshop versions on a schedule and report them."
    [UPDATE_CHECK_SCHEDULE]="schedule|no|When the update check runs, as a systemd OnCalendar expression."

    [STEAMCMD_IMAGE]="string|no|Container image used to run SteamCMD. Pin it to a digest for reproducible installs."
    [LOG_MAX_SIZE]="string|no|Maximum size of a single container log file before it rotates."
    [LOG_MAX_FILES]="int|no|Number of rotated container log files to keep."
)

# Byte order, whatever the locale: a German one sorts STEAM_ADVERTISE before
# STEAMCMD_IMAGE, and the generated settings table then no longer matched
# the one in the documentation.
config_keys() { printf '%s\n' "${!CONFIG_SPEC[@]}" | LC_ALL=C sort; }

# TYPE|RESTART|DESCRIPTION. Enum alternatives are comma-separated, so the
# type field never contains the field separator and the description may
# contain anything at all.
config_type()     { local s="${CONFIG_SPEC[$1]}"; printf '%s' "${s%%|*}"; }
config_restart()  { local s="${CONFIG_SPEC[$1]#*|}"; printf '%s' "${s%%|*}"; }
config_describe() { local s="${CONFIG_SPEC[$1]#*|}"; printf '%s' "${s#*|}"; }

config_is_enum()  { [[ "$(config_type "$1")" == enum:* ]]; }
_enum_values()    { local t; t="$(config_type "$1")"; printf '%s' "${t#enum:}"; }

# Normalised type: "enum" for every enumeration, the literal type otherwise.
config_effective_type() {
    local t; t="$(config_type "$1")"
    [[ "$t" == enum:* ]] && t="enum"
    printf '%s' "$t"
}

# -------------------------------------------------------------- validation --
# validate_value <key> <value>  ->  prints an error reason, or nothing
_validate_value() {
    local key="$1" value="$2" type
    type="$(config_effective_type "$key")"

    # Control characters have no legitimate use here and are how a crafted
    # value would try to break out of a generated file.
    if [[ "$value" == *[$'\n\r\t\v\f']* ]]; then
        printf 'contains a control character'; return
    fi

    case "$type" in
        identifier)
            [[ "$value" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] \
                || printf 'must be 1-32 characters of a-z, 0-9, hyphen or underscore'
            ;;
        path)
            [[ -z "$value" ]] && return
            [[ "$value" == /* ]] || { printf 'must be an absolute path'; return; }
            [[ "$value" == *..* ]] && printf 'must not contain ".."'
            ;;
        int)
            [[ "$value" =~ ^[0-9]+$ ]] || printf 'must be a whole number'
            ;;
        port)
            if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then :
            else printf 'must be a port number between 1 and 65535'; fi
            ;;
        bool)
            [[ "$value" == "true" || "$value" == "false" ]] || printf 'must be true or false'
            ;;
        enum)
            local allowed; allowed="$(_enum_values "$key")"
            [[ ",${allowed}," == *",${value},"* ]] || printf 'must be one of: %s' "${allowed//,/, }"
            ;;
        schedule)
            [[ -n "$value" ]] || printf 'must not be empty'
            ;;
        modlist)
            # Steam Workshop IDs, one space apart. Each becomes part of a
            # SteamCMD command line and of a path, so nothing else passes.
            [[ -z "$value" ]] && return
            if [[ ! "$value" =~ ^[0-9]{1,20}(\ [0-9]{1,20})*$ ]]; then
                printf 'must be Steam Workshop IDs separated by single spaces'
                return
            fi
            local ids=() id
            local -A seen=()
            read -ra ids <<<"$value"
            (( ${#ids[@]} <= 64 )) || { printf 'must name at most 64 Workshop items'; return; }
            for id in "${ids[@]}"; do
                [[ -z "${seen[$id]:-}" ]] || { printf 'names Workshop item %s twice' "$id"; return; }
                seen[$id]=1
            done
            ;;
        string)
            (( ${#value} <= 512 )) || printf 'must be at most 512 characters'
            ;;
        savename)
            # Becomes a file name for a Windows program: <name>.sav and
            # <name>.json in "Game Saves". Spaces are fine and common.
            local bad='[/\\:*?"<>|]'
            if [[ -z "$value" ]]; then
                printf 'must not be empty'
            elif (( ${#value} > 64 )); then
                printf 'must be at most 64 characters'
            elif [[ "$value" =~ $bad ]]; then
                printf 'must not contain any of / \\ : * ? " < > |'
            elif [[ "$value" == [[:space:]]* || "$value" == *[[:space:]] || "$value" == *. ]]; then
                printf 'must not begin or end with a space, or end with a dot'
            elif [[ "${value,,}" =~ ^(con|prn|aux|nul|com[1-9]|lpt[1-9])$ ]]; then
                printf 'is a device name Windows reserves'
            elif [[ "${value,,}" =~ ^(default_new_game|coop_bug_report|transfersave)$|\.backup[12]$ ]]; then
                printf 'is a name the server uses for its own files'
            fi
            ;;
    esac
    # A reason is reported by printing it, never by the exit status. Some
    # branches above end on a test that is legitimately false for a valid
    # value, and under `set -e` that would abort the caller.
    return 0
}

config_validate_all() {
    local key reason problems=0
    for key in $(config_keys); do
        reason="$(_validate_value "$key" "${CFG[$key]:-}")"
        if [[ -n "$reason" ]]; then
            error "$key: $reason (got: '${CFG[$key]:-}')"
            problems=$(( problems + 1 ))
        fi
    done

    # Cross-field rules the per-value checks cannot see.
    if [[ "${CFG[INSTALL_CHANNEL]:-}" == "custom" && -z "${CFG[CUSTOM_SOURCE_PATH]:-}" ]]; then
        error "CUSTOM_SOURCE_PATH is required when INSTALL_CHANNEL=custom"
        problems=$(( problems + 1 ))
    fi
    if [[ "${CFG[AUTO_UPDATE]:-}" == "true" && "${CFG[UPDATE_CHECK_ENABLED]:-}" == "false" ]]; then
        error "AUTO_UPDATE=true requires UPDATE_CHECK_ENABLED=true"
        problems=$(( problems + 1 ))
    fi

    (( problems == 0 )) || die "$EX_CONFIG" \
        "Configuration is not valid ($problems problem(s))." \
        "Edit ${CFG[INSTALL_DIR]:-<install-dir>}/config/server.env, or pass corrected values as flags."
}

# ----------------------------------------------------------------- parsing --
# Reverses _quote_value(). Walks the string once rather than running two
# global replacements: a value such as \\" would be mangled by the second
# pass of a naive replace-then-replace.
_unquote_value() {
    local s="$1" out="" i c len="${#1}"
    for (( i = 0; i < len; i++ )); do
        c="${s:i:1}"
        if [[ "$c" == "\\" && $(( i + 1 )) -lt len ]]; then
            i=$(( i + 1 ))
            out+="${s:i:1}"
        else
            out+="$c"
        fi
    done
    printf '%s' "$out"
}

# config_parse_file <file>
#
# Reads KEY=VALUE lines into CFG. Comments and blank lines are ignored.
# Unknown keys are reported but do not stop the run, so an installation
# written by a newer manager version stays readable by an older one.
config_parse_file() {
    local file="$1" line key value lineno=0
    [[ -f "$file" ]] || return 0
    debug "reading config: $file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$(( lineno + 1 ))
        line="${line%$'\r'}"                       # tolerate CRLF
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            warn "$file:$lineno: ignoring unparsable line"
            continue
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        # Strip one layer of matching quotes; keep everything else verbatim.
        # Double-quoted values are unescaped, which must be the exact
        # inverse of _quote_value() - a password containing a backslash
        # would otherwise grow one more on every read/write round trip.
        if   [[ "$value" =~ ^\"(.*)\"$ ]]; then value="$(_unquote_value "${BASH_REMATCH[1]}")"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"
        else value="${value%"${value##*[![:space:]]}"}"   # trim trailing space
        fi

        if [[ -z "${CONFIG_SPEC[$key]:-}" ]]; then
            warn "$file:$lineno: unknown setting '$key' (ignored)"
            continue
        fi
        CFG["$key"]="$value"
    done <"$file"
}

# config_load [--config <file>]
#
# Applies the full priority chain. Call once, early, from bin/coop.
config_load() {
    local extra_file="" arg
    while (( $# )); do
        case "$1" in
            --config) extra_file="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    # 1. project defaults
    config_parse_file "${COOP_ROOT}/config/defaults.env"

    # 2. an existing installation - INSTALL_DIR may already have been
    #    redirected by a flag or by the defaults file
    local dir="${CFG_OVERRIDE[INSTALL_DIR]:-${CFG[INSTALL_DIR]:-}}"
    [[ -n "$dir" ]] && config_parse_file "${dir}/config/server.env"

    # 3. a supplied file
    if [[ -n "$extra_file" ]]; then
        [[ -f "$extra_file" ]] || die "$EX_CONFIG" "Configuration file not found: $extra_file"
        config_parse_file "$extra_file"
    fi

    # 4. command line
    #
    # These are validated immediately, unlike values read from files. A
    # flag was typed a second ago and can be corrected on the spot, so
    # accepting a bad one silently - and acting on it - would be the wrong
    # trade. Values already on disk are reported by `coop doctor` instead,
    # which has to stay usable precisely when something is wrong.
    local reason
    for arg in "${!CFG_OVERRIDE[@]}"; do
        reason="$(_validate_value "$arg" "${CFG_OVERRIDE[$arg]}")"
        [[ -z "$reason" ]] || die "$EX_CONFIG" \
            "--$(tr 'A-Z_' 'a-z-' <<<"$arg"): $reason" \
            "Got: '${CFG_OVERRIDE[$arg]}'"
        CFG["$arg"]="${CFG_OVERRIDE[$arg]}"
    done

    config_derive_paths
}

# Recomputes everything that follows from INSTALL_DIR and INSTANCE_ID.
#
# Separate from config_load on purpose. After the interactive collector has
# run, the paths may need recomputing because the advanced questions can
# change the installation directory or the instance id, but the values in
# CFG must NOT be re-read: calling config_load there reloads defaults.env
# over the top and silently discards every answer the user just gave.
config_derive_paths() {
    INSTALL_DIR="${CFG[INSTALL_DIR]}"
    INSTANCE_ID="${CFG[INSTANCE_ID]}"

    # Directory layout, derived and never configured separately, so there
    # is only ever one answer to "where does this live".
    DIR_CONFIG="$INSTALL_DIR/config"
    DIR_SAVES="$INSTALL_DIR/saves"
    DIR_COOPDATA="$INSTALL_DIR/coopdata"
    DIR_SERVER="$INSTALL_DIR/server"
    DIR_WORKSHOP="$INSTALL_DIR/workshop"
    DIR_ROLLBACK="$INSTALL_DIR/rollback"
    DIR_BACKUPS="$INSTALL_DIR/backups"
    DIR_LOGS="$INSTALL_DIR/logs"
    DIR_STATE="$INSTALL_DIR/state"
    DIR_STEAM="$INSTALL_DIR/state/steam"
    DIR_MODS="$INSTALL_DIR/mods"
    DIR_RUNTIME="$INSTALL_DIR/runtime"
    DIR_USERCONFIGS="$INSTALL_DIR/userconfigs"
    FILE_HOOK="$INSTALL_DIR/state/hook/CoopHook.dll"
    FILE_CONFIG="$DIR_CONFIG/server.env"
    FILE_SERVER_JSON="$DIR_CONFIG/server-config.json"
    FILE_MOD_JSON="$DIR_COOPDATA/mod-config.json"
    FILE_BANS="$DIR_CONFIG/steam-bans.json"
    FILE_STATE="$DIR_STATE/install-state.json"
    FILE_COMPOSE_ENV="$DIR_CONFIG/compose.env"
    CONTAINER_NAME="bannerlordcoop-${INSTANCE_ID}"
    COMPOSE_PROJECT="bannerlordcoop-${INSTANCE_ID}"

    log_open "$INSTALL_DIR"
}

# config_default <key> - the project default, straight from defaults.env,
# whatever the installation has configured. For the few places that need
# to know whether a value is the default one.
config_default() {
    local line
    line="$(grep -m1 -E "^${1}=" "${COOP_ROOT}/config/defaults.env" 2>/dev/null)" || return 0
    line="${line#*=}"; line="${line%\"}"; line="${line#\"}"
    printf '%s' "$line"
}

# cfg <key> - the only supported way to read a setting.
cfg() {
    [[ -n "${CONFIG_SPEC[$1]:-}" ]] || die "$EX_CONFIG" "Internal error: unknown setting '$1'"
    printf '%s' "${CFG[$1]:-}"
}

cfg_bool() { [[ "$(cfg "$1")" == "true" ]]; }

# cfg_set <key> <value> - validates, then updates the in-memory value.
cfg_set() {
    local key="$1" value="$2" reason
    [[ -n "${CONFIG_SPEC[$key]:-}" ]] || die "$EX_CONFIG" \
        "Unknown setting: $key" \
        "Run 'coop config --list' to see every supported setting."
    reason="$(_validate_value "$key" "$value")"
    [[ -z "$reason" ]] || die "$EX_CONFIG" "$key: $reason (got: '$value')"
    CFG["$key"]="$value"
}

# ----------------------------------------------------------------- writing --
_quote_value() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '"%s"' "$v"
}

# config_write_new <file>
#
# Produces a fully commented configuration file. Used at install time.
config_write_new() {
    local file="$1" key
    mkdir -p "$(dirname "$file")"
    {
        cat <<'HEADER'
# Bannerlord Coop Server - instance configuration
#
# This file is the source of truth for this installation. Every value can be
# edited by hand; run `coop config --apply` afterwards to regenerate the
# files the server itself reads and to restart if needed.
#
# `coop config --set KEY=VALUE` edits it safely and keeps your comments.
#
# Settings marked "restart required" only take effect after `coop restart`.

HEADER
        for key in $(config_keys); do
            printf '# %s\n' "$(config_describe "$key" | fold -s -w 74 | sed '2,$s/^/# /')"
            [[ "$(config_restart "$key")" == "yes" ]] && printf '# restart required\n'
            printf '%s=%s\n\n' "$key" "$(_quote_value "${CFG[$key]:-}")"
        done
    } >"$file.tmp"
    chmod 0600 "$file.tmp"
    mv -f "$file.tmp" "$file"
}

# config_persist <file> <key>...
#
# Surgically updates the named keys in an existing file and appends any that
# are missing. Comments and hand-made edits elsewhere in the file survive.
config_persist() {
    local file="$1"; shift
    local key value tmp
    [[ -f "$file" ]] || { config_write_new "$file"; return 0; }

    tmp="$(mktemp "${file}.XXXXXX")"
    cp -a "$file" "$tmp"
    for key in "$@"; do
        value="$(_quote_value "${CFG[$key]:-}")"
        if grep -qE "^${key}=" "$tmp"; then
            # Key and value travel through the environment on purpose:
            # `awk -v` expands backslash escapes inside the value, and sed
            # would additionally interpret its delimiter and '&'. A password
            # containing a backslash must survive being written verbatim.
            COOP_K="$key" COOP_V="$value" awk '
                index($0, ENVIRON["COOP_K"] "=") == 1 {
                    print ENVIRON["COOP_K"] "=" ENVIRON["COOP_V"]; next
                }
                { print }
            ' "$tmp" >"${tmp}.new" && mv -f "${tmp}.new" "$tmp"
        else
            printf '\n%s=%s\n' "$key" "$value" >>"$tmp"
        fi
    done
    chmod 0600 "$tmp"
    mv -f "$tmp" "$file"
}

# config_write_compose_env
#
# Docker Compose gets its own generated file. Keeping it separate means the
# hand-editable configuration never has to satisfy Compose's quoting rules,
# and Compose never sees a setting that is none of its business.
# The host's time zone, asked for in the order systems actually answer.
# /etc/timezone alone is not enough: modern systemd hosts do not have it,
# and reading only that file hands the container UTC on a machine set to
# Europe/Berlin - silently, which is the worst way to be wrong about time.
_host_timezone() {
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
    [[ -n "$tz" ]] && { printf '%s' "$tz"; return; }

    tz="$(readlink -f /etc/localtime 2>/dev/null)"
    tz="${tz#/usr/share/zoneinfo/}"
    [[ -n "$tz" && "$tz" != /* ]] && { printf '%s' "$tz"; return; }

    tz="$(cat /etc/timezone 2>/dev/null)"
    printf '%s' "${tz:-UTC}"
}

config_write_compose_env() {
    local tz mem server_dir
    tz="$(cfg TIMEZONE)"
    [[ "$tz" == "system" ]] && tz="$(_host_timezone)"
    # Compose reads an empty mem_limit as a syntax error; 0 is its way of
    # saying "no limit".
    mem="$(cfg MEMORY_LIMIT)"; [[ -n "$mem" ]] || mem="0"
    # With mods the server runs from runtime/, the view lib/mods.sh puts
    # together before every start; without them from server/ as it is.
    server_dir="$DIR_SERVER"
    [[ -n "$(cfg MODS)" ]] && server_dir="$DIR_RUNTIME"
    mkdir -p "$DIR_CONFIG"
    {
        printf '# Generated by coop - do not edit. Change config/server.env instead.\n'
        printf 'COMPOSE_PROJECT_NAME=%s\n' "$COMPOSE_PROJECT"
        printf 'COOP_CONTAINER_NAME=%s\n'  "$CONTAINER_NAME"
        printf 'COOP_INSTALL_DIR=%s\n'     "$INSTALL_DIR"
        printf 'COOP_SERVER_DIR=%s\n'      "$server_dir"
        printf 'COOP_SERVER_LOG_FILE=%s\n' "$(cfg SERVER_LOG_FILE)"
        printf 'COOP_IMAGE_FINGERPRINT=%s\n' "$(image_fingerprint)"
        printf 'COOP_GAME_PORT=%s\n'       "$(cfg GAME_PORT)"
        printf 'COOP_PUID=%s\n'            "$(cfg PUID)"
        printf 'COOP_PGID=%s\n'            "$(cfg PGID)"
        printf 'COOP_TZ=%s\n'              "$tz"
        printf 'COOP_WINE_BRANCH=%s\n'     "$(cfg WINE_BRANCH)"
        printf 'COOP_MEMORY_LIMIT=%s\n'    "$mem"
        printf 'COOP_LOG_MAX_SIZE=%s\n'    "$(cfg LOG_MAX_SIZE)"
        printf 'COOP_LOG_MAX_FILES=%s\n'   "$(cfg LOG_MAX_FILES)"
    } >"${FILE_COMPOSE_ENV}.tmp"
    chmod 0640 "${FILE_COMPOSE_ENV}.tmp"
    mv -f "${FILE_COMPOSE_ENV}.tmp" "$FILE_COMPOSE_ENV"
}

# --------------------------------------------------------------- self check --
# Verifies that config/defaults.env and CONFIG_SPEC describe the same keys.
# Called by `coop doctor` and by CI, so the two can never drift apart
# unnoticed.
config_selfcheck() {
    local file="${COOP_ROOT}/config/defaults.env" key problems=0
    local -A in_file=()

    while IFS= read -r key; do
        [[ -n "$key" ]] && in_file["$key"]=1
    done < <(grep -oE '^[A-Z][A-Z0-9_]*=' "$file" 2>/dev/null | tr -d '=')

    for key in $(config_keys); do
        [[ -n "${in_file[$key]:-}" ]] || { error "defaults.env is missing a default for $key"; problems=$(( problems + 1 )); }
    done
    for key in "${!in_file[@]}"; do
        [[ -n "${CONFIG_SPEC[$key]:-}" ]] || { error "defaults.env defines $key, which is not in CONFIG_SPEC"; problems=$(( problems + 1 )); }
    done
    return $(( problems > 0 ))
}
