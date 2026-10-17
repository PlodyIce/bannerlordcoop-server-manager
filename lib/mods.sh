# shellcheck shell=bash
#
# mods.sh - Steam Workshop mods on a dedicated server.
#
# WHY A SERVER WITH MODS IS STARTED DIFFERENTLY
# ---------------------------------------------
# BannerlordCoopServer.exe starts the game engine with a fixed module list,
#     _MODULES_*Native*SandBoxCore*Sandbox*Coop*DedicatedServer.Windows*_MODULES_
# and has no option to add to it. Coop's join check, on the other hand,
# requires every community module to be loaded on both sides, versions
# included. A player's mod is refused unless the server loads it too, and
# the official launcher cannot.
#
# So with mods the manager starts the engine itself, the way the launcher
# does: the same program, arguments, working directory and environment,
# read from a running official server. Everything the manager relies on
# lives in the engine rather than in the launcher: the license check (still
# exit 6 without acceptance), the checksum verification of the Coop
# assemblies, server-config.json, the console and the @DS@ events. Without
# mods nothing changes; the official launcher starts the server as before.
#
# WHAT A MOD NEEDS ON A DEDICATED SERVER
# --------------------------------------
# Measured on Coop v0.1.6 with the CoopModPatch set on 2026-10-16, and
# following the community's hosting tools:
#
#  1. A server copy of its manifest. Frameworks such as Harmony and MCM
#     stay in the module list, because the join check compares it, but
#     load no code: a server has no interface for them to extend. Gameplay
#     mods mark themselves "not for dedicated servers" and are loaded
#     anyway; mods like CoopModPatch exist to make exactly that work.
#  2. Help finding libraries. Mods reference interface assemblies that a
#     server only has inside the Coop module, and the engine loads Coop
#     after every mod. Unhelped, that ends in exit 82. The startup hook in
#     docker/hook answers the runtime's "assembly not found" from Coop's
#     folder first, then from the mods' own.
#  3. A writable Documents\...\Configs, where some mods keep data of their
#     own, Improved Garrisons some of it per campaign. userconfigs/ is
#     mounted there and goes into every backup.
#
# None of the mods' files is changed. The server sees a view, runtime/,
# which is server/ and mods/ linked together, plus the rewritten manifests,
# the hook and a launch file for docker/entrypoint.sh. It is rebuilt before
# every start, in a fraction of a second, and only while the server is
# stopped.
#
# WHERE THINGS LIVE
# -----------------
#   workshop/content/<app>/<id>   SteamCMD's download, as for Coop itself
#   mods/<id>                     the installed copy, by Workshop id
#   runtime/                      the view the server runs from
#   state/hook/CoopHook.dll       the startup hook, built from source
#   install-state.json .mods      what was installed, and when

# --------------------------------------------------------------- knowledge --
# Frameworks. In the module list, for the join check, but no code on a
# server. The value is each one's Workshop item, so that a mod which needs
# one gets it without anybody having to look it up.
declare -gA MODS_FRAMEWORKS=(
    [Bannerlord.Harmony]=2859188632
    [Bannerlord.ButterLib]=2859232415
    [Bannerlord.UIExtenderEx]=2859222409
    [Bannerlord.MBOptionScreen]=2859238197
)

# What each framework needs in turn, as its manifest says. Only used to
# fetch a whole chain in one SteamCMD session instead of one per link; the
# manifests themselves are still read and still decide.
declare -gA MODS_FRAMEWORK_NEEDS=(
    [Bannerlord.ButterLib]="Bannerlord.Harmony"
    [Bannerlord.UIExtenderEx]="Bannerlord.Harmony"
    [Bannerlord.MBOptionScreen]="Bannerlord.Harmony Bannerlord.ButterLib Bannerlord.UIExtenderEx"
)

# Submodules of a framework that do load on a server. MCM's settings core
# is how mods read their settings, and how CoopModPatch hands the server's
# values to every player; MCM's interface stays behind.
declare -gA MODS_KEEP_SUBMODULES=(
    [Bannerlord.MBOptionScreen]="MCM.MCMSubModule MCM.Internal.MCMImplementationSubModule"
)

# The game's own modules and its DLC. A Workshop item may not claim one of
# these ids, and as a dependency each counts as met: Coop's join check
# exempts them, and a server does without StoryMode or CustomBattle.
_mods_official_id() {
    case "${1,,}" in
        native|sandboxcore|sandbox|storymode|custombattle|multiplayer|birthanddeath|fastmode|navaldlc) return 0 ;;
    esac
    return 1
}

# Those, and Coop's own modules, which the server always loads.
_mods_reserved_id() {
    _mods_official_id "$1" && return 0
    case "${1,,}" in
        coop|coopnightly|dedicatedserver.*) return 0 ;;
    esac
    return 1
}

mods_workshop_url() { printf 'https://steamcommunity.com/sharedfiles/filedetails/?id=%s' "$1"; }

# ------------------------------------------------------------------ basics --
mods_configured() { [[ -n "$(cfg MODS)" ]]; }

# The configured Workshop ids, one per line, in the order given.
mods_ids() {
    local ids=() id
    read -ra ids <<<"$(cfg MODS)"
    for id in "${ids[@]}"; do printf '%s\n' "$id"; done
}

_mods_download_dir() { printf '%s/content/%s/%s' "$DIR_WORKSHOP" "$(cfg WORKSHOP_APP_ID)" "$1"; }
_mods_dir()          { printf '%s/%s' "$DIR_MODS" "$1"; }
mods_installed()     { [[ -f "$(_mods_dir "$1")/SubModule.xml" ]]; }

_mods_in() {
    local want="$1" x; shift
    for x in "$@"; do [[ "$x" == "$want" ]] && return 0; done
    return 1
}

# A Workshop id from an id or from a link to the item's page.
_mods_parse_id() {
    if [[ "$1" =~ ^[0-9]{1,20}$ ]]; then
        printf '%s' "$1"
    elif [[ "$1" =~ [?\&]id=([0-9]{1,20}) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

# Manifests are XML, which xmlstarlet reads properly where sed would guess.
# It is installed the first time mods are used, so a server without mods
# needs nothing it did not need before.
mods_require_tools() {
    command -v xmlstarlet >/dev/null 2>&1 && return 0
    log "Mods need xmlstarlet to read their manifests. Installing it."
    compat_detect
    deps_install_packages xmlstarlet
}

# --------------------------------------------------------------- manifests --
_mods_xml() { local f="$1"; shift; xmlstarlet sel -T -t "$@" "$f" 2>/dev/null; }

# mods_manifest_value <module-dir> <Id|Name|Version>
mods_manifest_value() { _mods_xml "$1/SubModule.xml" -v "/Module/$2/@value"; }

# The module ids that have to load before this one: what it depends on,
# and what its manifest asks to load first. Optional ones are left out.
mods_manifest_needs() {
    _mods_xml "$1/SubModule.xml" \
        -m '/Module/DependedModules/DependedModule[not(@Optional="true")]' -v '@Id' -n -b \
        -m '/Module/DependedModuleMetadatas/DependedModuleMetadata[@order="LoadBeforeThis" and not(@optional="true")]' -v '@id' -n \
        | sed '/^[[:space:]]*$/d' | sort -u
}

# A framework asks the game's own modules to load after it, which is how
# the TaleWorlds launcher knows to sort it above Native.
mods_manifest_is_framework() {
    [[ "$(_mods_xml "$1/SubModule.xml" \
        -v 'count(/Module/DependedModuleMetadatas/DependedModuleMetadata[@id="Native" and @order="LoadAfterThis"])')" =~ ^[1-9] ]]
}

# How a module takes part on the server: "framework", listed with no code
# but what MODS_KEEP_SUBMODULES keeps, or "loads".
mods_role() { [[ -n "${MODS_FRAMEWORKS[$1]:-}" ]] && printf 'framework' || printf 'loads'; }

# ------------------------------------------------------ the set of modules --
# What is known about a set of mods once it has been read. Keyed by
# Workshop id, except _MOD_BY_ID, which maps a lowercased module id back.
declare -gA _MOD_ID=() _MOD_NAME=() _MOD_VERSION=() _MOD_NEEDS=() _MOD_FRAMEWORK=() _MOD_BY_ID=()
MODS_ERROR=""
MODS_ORDER=()

_mods_reset() {
    _MOD_ID=(); _MOD_NAME=(); _MOD_VERSION=(); _MOD_NEEDS=(); _MOD_FRAMEWORK=(); _MOD_BY_ID=()
    MODS_ORDER=(); MODS_ERROR=""
}

# _mods_read <workshop-id> <module-dir>
#
# Adds one module to the set, refusing what the server cannot load: a
# manifest it cannot read, an id that is not a plain name, an id of the
# game or of Coop, or an id another item in the set already has.
_mods_read() {
    local wid="$1" dir="$2" id other
    if [[ ! -f "$dir/SubModule.xml" ]]; then
        MODS_ERROR="Workshop item $wid is not a Bannerlord module: it has no SubModule.xml"
        return 1
    fi
    id="$(mods_manifest_value "$dir" Id)"
    if [[ -z "$id" ]]; then
        MODS_ERROR="the SubModule.xml of Workshop item $wid cannot be read"
        return 1
    fi
    if [[ ! "$id" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        MODS_ERROR="Workshop item $wid has a module id this server cannot use: '$id'"
        return 1
    fi
    if _mods_reserved_id "$id"; then
        MODS_ERROR="Workshop item $wid calls itself '$id', which is a module of the game or of Coop"
        return 1
    fi
    other="${_MOD_BY_ID[${id,,}]:-}"
    if [[ -n "$other" && "$other" != "$wid" ]]; then
        MODS_ERROR="Workshop items $other and $wid are both the module '$id'; only one can load"
        return 1
    fi
    _MOD_ID[$wid]="$id"
    _MOD_NAME[$wid]="$(mods_manifest_value "$dir" Name)"
    _MOD_VERSION[$wid]="$(mods_manifest_value "$dir" Version)"
    _MOD_NEEDS[$wid]="$(mods_manifest_needs "$dir" | tr '\n' ' ')"
    mods_manifest_is_framework "$dir" && _MOD_FRAMEWORK[$wid]=1
    _MOD_BY_ID[${id,,}]="$wid"
    return 0
}

# _mods_scan <workshop-id>... - reads the installed copies.
_mods_scan() {
    local wid
    _mods_reset
    for wid in "$@"; do
        _mods_read "$wid" "$(_mods_dir "$wid")" || return 1
    done
}

# Module ids the set needs and does not contain, one per line. The game's
# modules and Coop's count as present.
_mods_missing_needs() {
    local wid need
    for wid in "${!_MOD_ID[@]}"; do
        for need in ${_MOD_NEEDS[$wid]}; do
            _mods_reserved_id "$need" && continue
            [[ -n "${_MOD_BY_ID[${need,,}]:-}" ]] && continue
            printf '%s\n' "$need"
        done
    done | sort -u
}

# _mods_order <workshop-id>...
#
# The load order, into MODS_ORDER: frameworks first, then the rest in the
# order given, each one moved behind whatever it needs. A given order is
# kept wherever the manifests do not contradict it.
_mods_order() {
    local wid
    local -A _placed=() _visiting=()
    MODS_ORDER=()
    for wid in "$@"; do
        [[ -n "${_MOD_FRAMEWORK[$wid]:-}" ]] && _mods_place "$wid"
    done
    for wid in "$@"; do
        _mods_place "$wid"
    done
}

# Uses _placed and _visiting from _mods_order. A dependency cycle is cut
# where it is found rather than followed forever.
_mods_place() {
    local wid="$1" need dep
    [[ -n "${_placed[$wid]:-}" || -n "${_visiting[$wid]:-}" ]] && return 0
    _visiting[$wid]=1
    for need in ${_MOD_NEEDS[$wid]}; do
        dep="${_MOD_BY_ID[${need,,}]:-}"
        [[ -n "$dep" ]] && _mods_place "$dep"
    done
    _placed[$wid]=1
    MODS_ORDER+=("$wid")
}

# The Coop module's folder and id in the installed build, as "<folder>
# <id>". Searched rather than assumed: a nightly build calls it CoopNightly.
_mods_coop_module() {
    local d id
    for d in Coop CoopNightly; do
        [[ -f "$DIR_SERVER/engine/Modules/$d/SubModule.xml" ]] || continue
        id="$(mods_manifest_value "$DIR_SERVER/engine/Modules/$d" Id)"
        printf '%s %s' "$d" "${id:-$d}"
        return 0
    done
    printf 'Coop Coop'
}

# The engine's module list for MODS_ORDER. Frameworks go before the game's
# own modules, the rest after them, and Coop with the server module last,
# where the official launcher puts them.
mods_module_token() {
    local pre=() post=() wid coop
    for wid in "${MODS_ORDER[@]}"; do
        if [[ -n "${_MOD_FRAMEWORK[$wid]:-}" ]]; then
            pre+=("${_MOD_ID[$wid]}")
        else
            post+=("${_MOD_ID[$wid]}")
        fi
    done
    coop="$(_mods_coop_module)"
    printf '_MODULES_'
    printf '*%s' "${pre[@]}" Native SandBoxCore Sandbox "${post[@]}" "${coop#* }" DedicatedServer.Windows
    printf '*_MODULES_'
}

# Where the startup hook looks, in order: the server's own folders first,
# so that a library the server and a mod both carry comes from the server,
# then each mod's, in load order. As the engine sees them, under Z:.
_mods_assembly_dirs() {
    local dirs=() d wid out="" coop
    coop="$(_mods_coop_module)"
    dirs=("${coop%% *}" DedicatedServer.Windows SandBox)
    for wid in "${MODS_ORDER[@]}"; do dirs+=("${_MOD_ID[$wid]}"); done
    for d in "${dirs[@]}"; do
        out+="Z:\\server\\engine\\Modules\\${d}\\bin\\Win64_Shipping_Server;"
    done
    printf '%s' "$out"
}

# ------------------------------------------------------ the server's view --
# _mods_server_manifest <module-dir> <module-id>
#
# Rewrites the view's copy of a manifest for the server. That copy is a
# hard link to the installed file, so it is replaced, never edited in
# place. Id and Version are left alone: they are what the join check
# compares with the players' copies.
_mods_server_manifest() {
    local dir="$1" id="$2" f="$1/SubModule.xml" expr cond="" c count
    if [[ "$(mods_role "$id")" == framework ]]; then
        for c in ${MODS_KEEP_SUBMODULES[$id]:-}; do
            cond+="${cond:+ or }SubModuleClassType/@value=\"$c\""
        done
        expr="/Module/SubModules/SubModule${cond:+[not($cond)]}"
    elif [[ "$(_mods_xml "$f" -v 'count(/Module/SubModules/SubModule/Tags/Tag[@key="DedicatedServerType" and @value!="none"])')" =~ ^[1-9] ]]; then
        # The author split the mod into a server half and a players' half.
        # Loading both would run the players' half in a process without a
        # screen, so the split is honoured.
        expr='/Module/SubModules/SubModule[Tags/Tag[@key="DedicatedServerType" and @value="none"]]'
    else
        # A mod written for players marks itself as not for dedicated
        # servers, and the engine would skip its code.
        expr='/Module/SubModules/SubModule/Tags/Tag[@key="DedicatedServerType" or @key="IsNoRenderModeElement"]'
    fi

    count="$(_mods_xml "$f" -v "count($expr)")"
    [[ "$count" =~ ^[1-9] ]] || return 0
    xmlstarlet ed -d "$expr" "$f" >"$f.server" 2>/dev/null || { rm -f -- "$f.server"; return 1; }
    rm -f -- "$f" && mv -f -- "$f.server" "$f"
}

_mods_write_launch_file() {
    {
        printf '# Written by coop before every start with mods; read by docker/entrypoint.sh.\n'
        printf 'MODULES=%s\n' "$(mods_module_token)"
        printf 'HOOK=%s\n' 'Z:\server\coop-hook\CoopHook.dll'
        printf 'ASSEMBLY_DIRS=%s\n' "$(_mods_assembly_dirs)"
    } >"$1"
}

# mods_build_runtime - after _mods_scan and _mods_order.
#
# Puts the view together beside the old one and swaps it in. Linked, not
# copied, so it costs neither time nor space; which is also why it has to
# share a file system with server/ and mods/.
mods_build_runtime() {
    local new="${DIR_RUNTIME}.new" old="${DIR_RUNTIME}.old" wid id dest
    rm -rf -- "$new" "$old"
    if ! cp -al -- "$DIR_SERVER" "$new" 2>/dev/null; then
        rm -rf -- "$new"
        MODS_ERROR="server/ could not be linked into runtime/; both have to be on the same file system"
        return 1
    fi
    for wid in "${MODS_ORDER[@]}"; do
        id="${_MOD_ID[$wid]}"
        dest="$new/engine/Modules/$id"
        if ! cp -al -- "$(_mods_dir "$wid")" "$dest" 2>/dev/null; then
            rm -rf -- "$new"
            MODS_ERROR="$id could not be linked into runtime/"
            return 1
        fi
        if ! _mods_server_manifest "$dest" "$id"; then
            rm -rf -- "$new"
            MODS_ERROR="the manifest of $id could not be rewritten for the server"
            return 1
        fi
        # The engine loads a module's code from its server bin. A mod built
        # for players ships only the client bin, which is the same code.
        if [[ ! -d "$dest/bin/Win64_Shipping_Server" && -d "$dest/bin/Win64_Shipping_Client" ]]; then
            cp -al -- "$dest/bin/Win64_Shipping_Client" "$dest/bin/Win64_Shipping_Server"
        fi
    done
    mkdir -p "$new/coop-hook" && cp -f -- "$FILE_HOOK" "$new/coop-hook/CoopHook.dll"
    _mods_write_launch_file "$new/coop-launch.txt"

    [[ -e "$DIR_RUNTIME" ]] && mv -- "$DIR_RUNTIME" "$old"
    if ! mv -- "$new" "$DIR_RUNTIME"; then
        [[ -e "$old" ]] && mv -- "$old" "$DIR_RUNTIME"
        MODS_ERROR="runtime/ could not be put in place"
        return 1
    fi
    rm -rf -- "$old"
    debug "runtime view: $(mods_module_token)"
}

# ------------------------------------------------------------ startup hook --
_mods_hook_fingerprint() {
    { cat "${COOP_ROOT}"/docker/hook/*.cs "${COOP_ROOT}"/docker/hook/*.csproj; cfg DOTNET_SDK_IMAGE; } \
        | sha256sum | cut -c1-16
}

mods_hook_current() {
    [[ -f "$FILE_HOOK" && "$(cat "${FILE_HOOK}.fingerprint" 2>/dev/null)" == "$(_mods_hook_fingerprint)" ]]
}

# mods_hook_build
#
# Builds the startup hook from docker/hook with Microsoft's .NET SDK image:
# once, and again only when its source changes. Built here rather than
# shipped, so that what runs inside the server is source anybody can read.
# The SDK image is large and needed for nothing else, so it is removed
# afterwards unless it was there before. Returns non-zero rather than
# ending the run.
mods_hook_build() {
    mods_hook_current && return 0
    local image work had=0
    image="$(cfg DOTNET_SDK_IMAGE)"
    docker image inspect "$image" >/dev/null 2>&1 && had=1
    log "Building the startup hook a server with mods needs, from docker/hook."
    (( had )) || log "This downloads Microsoft's .NET SDK image ($image) once and removes it afterwards."

    make_temp_dir "$DIR_STATE" work
    cp -a "${COOP_ROOT}/docker/hook" "$work/src"
    docker run --rm -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 \
        -v "$work:/work" -w /work/src "$image" \
        dotnet build CoopHook.csproj -c Release -o /work/out -nologo >"$work/build.log" 2>&1
    if [[ ! -f "$work/out/CoopHook.dll" ]]; then
        tail -n 15 "$work/build.log" >&2
        (( had )) || docker image rm "$image" >/dev/null 2>&1 || true
        MODS_ERROR="the startup hook could not be built"
        return 1
    fi
    mkdir -p "$(dirname "$FILE_HOOK")"
    cp -f "$work/out/CoopHook.dll" "$FILE_HOOK"
    _mods_hook_fingerprint >"${FILE_HOOK}.fingerprint"
    (( had )) || docker image rm "$image" >/dev/null 2>&1 || true
    ok "Startup hook built"
}

# -------------------------------------------------------- installing items --
# _mods_record <workshop-id> - what was installed, for the update check and
# for backups, which name the mods they were made with.
_mods_record() {
    local wid="$1" dir; dir="$(_mods_dir "$1")"
    state_mod_set "$wid" "$(jq -n \
        --arg id "$(mods_manifest_value "$dir" Id)" \
        --arg name "$(mods_manifest_value "$dir" Name)" \
        --arg version "$(mods_manifest_value "$dir" Version)" \
        --arg updated "$(workshop_item_time "$wid")" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{module_id:$id, name:$name, version:$version, workshop_updated:$updated, installed_at:$at}')"
}

# _mods_install_download <workshop-id> - copies a download into mods/.
#
# The download stays where SteamCMD put it; mods/ holds the copy the server
# uses. Copied beside the old one and swapped in, so the files a running
# server has open are never written to.
_mods_install_download() {
    local wid="$1" src dest
    src="$(_mods_download_dir "$wid")"
    dest="$(_mods_dir "$wid")"
    if [[ ! -f "$src/SubModule.xml" ]]; then
        MODS_ERROR="Workshop item $wid is not a Bannerlord module: it has no SubModule.xml"
        return 1
    fi
    mkdir -p "$DIR_MODS"
    rm -rf -- "${dest}.new"
    if ! rsync -a --delete -- "$src/" "${dest}.new/"; then
        rm -rf -- "${dest}.new"
        MODS_ERROR="Workshop item $wid could not be copied into $DIR_MODS"
        return 1
    fi
    rm -rf -- "$dest" && mv -- "${dest}.new" "$dest"
    _mods_record "$wid"
}

# mods_fetch_install <workshop-id>... - download and install, for a start
# that finds configured mods missing, as after restoring a backup.
mods_fetch_install() {
    local wid
    steam_download_items "$@"
    for wid in "$@"; do
        _mods_install_download "$wid" || fail "$EX_CONFIG" "$MODS_ERROR"
    done
}

# _mods_add_needed_frameworks <workshop-id>...
#
# After the given downloads have been read into the set: downloads the
# frameworks the set needs and does not have, then whatever those need,
# until nothing is missing. Fails naming any module that no known item
# provides. The ids added come back in MODS_ADDED.
MODS_ADDED=()
_mods_add_needed_frameworks() {
    local need wid unknown=() fetch=() names=() _round
    MODS_ADDED=()
    # Four rounds cover the deepest chain there is: a mod needs MCM, MCM
    # needs ButterLib, ButterLib needs Harmony.
    local chained
    for _round in 1 2 3 4; do
        unknown=(); fetch=(); names=()
        while IFS= read -r need; do
            [[ -n "$need" ]] || continue
            wid="${MODS_FRAMEWORKS[$need]:-}"
            if [[ -z "$wid" ]]; then unknown+=("$need"); continue; fi
            _mods_in "$need" "${names[@]}" || { fetch+=("$wid"); names+=("$need"); }
            for chained in ${MODS_FRAMEWORK_NEEDS[$need]:-}; do
                [[ -n "${_MOD_BY_ID[${chained,,}]:-}" ]] && continue
                _mods_in "$chained" "${names[@]}" && continue
                fetch+=("${MODS_FRAMEWORKS[$chained]}"); names+=("$chained")
            done
        done < <(_mods_missing_needs)
        if (( ${#unknown[@]} )); then
            MODS_ERROR="the mods need module(s) that none of them provides: ${unknown[*]}"
            return 1
        fi
        (( ${#fetch[@]} )) || return 0
        log "They need $(printf '%s, ' "${names[@]}" | sed 's/, $//'), which come from the Workshop as well."
        steam_download_items "${fetch[@]}"
        for wid in "${fetch[@]}"; do
            _mods_read "$wid" "$(_mods_download_dir "$wid")" || return 1
            MODS_ADDED+=("$wid")
        done
    done
    need="$(_mods_missing_needs | paste -sd ' ')"
    [[ -z "$need" ]] || { MODS_ERROR="the mods still need module(s) after four rounds: $need"; return 1; }
    return 0
}

# ------------------------------------------------------------ preparation --
# mods_prepare_start
#
# Everything a start with mods needs: the tools, the configured mods
# (downloaded if missing, as after a restore), the hook, and a fresh view.
# Returns non-zero with MODS_ERROR set, rather than ending the run, because
# an update that cannot start the new build has to be able to roll back.
mods_prepare_start() {
    local ids=() wid missing=() need
    mapfile -t ids < <(mods_ids)

    if ! command -v xmlstarlet >/dev/null 2>&1 && ! ( mods_require_tools ); then
        MODS_ERROR="xmlstarlet is missing and could not be installed"
        return 1
    fi
    for wid in "${ids[@]}"; do mods_installed "$wid" || missing+=("$wid"); done
    if (( ${#missing[@]} )); then
        log "Configured but not installed: Workshop item(s) ${missing[*]}. Downloading."
        if ! ( mods_fetch_install "${missing[@]}" ); then
            MODS_ERROR="Workshop item(s) ${missing[*]} are configured but could not be installed"
            return 1
        fi
    fi
    _mods_scan "${ids[@]}" || return 1
    need="$(_mods_missing_needs | paste -sd ' ')"
    if [[ -n "$need" ]]; then
        MODS_ERROR="the configured mods need module(s) none of them provides: $need. Add them with: coop mods add <Workshop ID>"
        return 1
    fi
    _mods_order "${ids[@]}"
    mods_hook_build || return 1
    mods_build_runtime
}

# ----------------------------------------------------------- update check --
# mods_update_check
#
# Which configured mods have a newer version on the Workshop than the one
# installed, into MODS_UPDATES, and as a marker the login message reads.
# Anonymous, like the check for Coop itself.
#   0  checked        2  Steam could not be asked
MODS_UPDATES=()
mods_update_check() {
    local ids=() details wid remote installed
    MODS_UPDATES=()
    mapfile -t ids < <(mods_ids)
    if (( ${#ids[@]} == 0 )); then
        mods_update_marker_clear
        return 0
    fi
    details="$(workshop_details "${ids[@]}")"
    [[ -n "$details" ]] || return 2
    for wid in "${ids[@]}"; do
        remote="$(jq -r --arg w "$wid" '.[] | select(.publishedfileid == $w) | .time_updated // empty' <<<"$details")"
        installed="$(state_mod_get "$wid" workshop_updated)"
        [[ "$remote" =~ ^[0-9]+$ && "$installed" =~ ^[0-9]+$ ]] || continue
        (( remote > installed )) && MODS_UPDATES+=("$wid")
    done
    if (( ${#MODS_UPDATES[@]} )); then
        mods_update_marker_set "${MODS_UPDATES[@]}"
    else
        mods_update_marker_clear
    fi
    return 0
}

# mods_engine_errors <error log> - its lines worth showing.
#
# The engine looks for every library in its own folder first and logs each
# one it does not find there, so a start with mods that works logs dozens
# of "Cannot load"; the startup hook then finds them in the folders the
# launch file names. Only a library that is in none of those is a reason.
mods_engine_errors() {
    local launch="$DIR_RUNTIME/coop-launch.txt" dirs d name line
    local -A found=()
    dirs="$(sed -n 's/^ASSEMBLY_DIRS=//p' "$launch" 2>/dev/null)"
    while IFS= read -r -d ';' d; do
        d="${d//\\//}"
        d="${DIR_RUNTIME}${d#Z:/server}"
        while IFS= read -r name; do
            found["${name,,}"]=1
        done < <(ls -1 -- "$d" 2>/dev/null)
    done <<<"$dirs"

    while IFS= read -r line; do
        if [[ "$line" =~ Cannot\ load:\ ([^[:space:]]+) ]]; then
            name="${BASH_REMATCH[1],,}"
            [[ -n "${found[$name]:-}" ]] && continue
        fi
        printf '%s\n' "$line"
    done < <(tr -d '\r' <"$1" | grep -aE 'Cannot load|Exception|ERROR' \
        | sed -E 's/^\[[0-9:.]+\] //' | awk '!seen[$0]++')
}

# ---------------------------------------------------------------- changing --
_mods_apply() {
    cfg_set MODS "$1"
    config_persist "$FILE_CONFIG" MODS
    config_write_compose_env
}

# _mods_change <new MODS value> <backup note> [<function to undo files>]
#
# The order of a campaign switch: stop with a closing save, back up,
# change, start, and wait until the server serves. If it will not serve
# with the change, the previous set is put back and started, so a failed
# change never leaves the server down. Connected players have been asked
# about by the caller, before anything was installed.
_mods_change() {
    local value="$1" note="$2" undo="${3:-}" previous rc=0
    previous="$(cfg MODS)"

    server_refresh_image
    server_stop
    log "Creating a backup first"
    backup_create manual "$note" >/dev/null
    _mods_apply "$value"

    server_start || rc=$?
    (( rc == 0 )) && return 0
    (( rc == 4 )) && exit "$EX_LICENSE"
    (( rc == 5 )) && exit "$EX_CONFIG"

    # The way back starts the server again, and the container's log of the
    # failed start may go with it. The engine's own error log stays, and
    # when the engine crashed it is the one that still has the reason: its
    # console output loses the end. So that is what the message points at,
    # read now, while runtime/ is still the view that failed.
    local errors line hints=()
    errors="$(server_engine_errors)"
    if [[ -n "$errors" ]]; then
        hints+=("The engine's error log: $errors")
        while IFS= read -r line; do
            hints+=("  ${line}")
        done < <(mods_engine_errors "$errors" | tail -n 3)
    else
        hints+=("See why: coop logs -n 200")
    fi

    warn "The server did not serve with the change. Going back to the mods it had."
    server_stop
    [[ -n "$undo" ]] && "$undo"
    _mods_apply "$previous"
    if server_start; then
        fail "$EX_HEALTH" \
            "The change did not work; the server runs with the mods it had before." "${hints[@]}"
    fi
    fail "$EX_HEALTH" \
        "The change did not work, and the server did not start with the previous mods either." "${hints[@]}"
}

# _mods_wrap <indent> <item>... - the items, comma-separated and wrapped,
# without breaking a name that contains spaces.
_mods_wrap() {
    local indent="$1" line="" item; shift
    for item in "$@"; do
        if [[ -n "$line" ]] && (( ${#indent} + ${#line} + ${#item} + 2 > 76 )); then
            out_line "${indent}${line},"
            line="$item"
        else
            line+="${line:+, }$item"
        fi
    done
    [[ -n "$line" ]] && out_line "${indent}${line}"
    return 0
}

# What players need, after _mods_scan and _mods_order: the launcher's
# names, in the launcher's order, with Coop last.
_mods_players_note() {
    local wid pre=() post=()
    for wid in "${MODS_ORDER[@]}"; do
        if [[ -n "${_MOD_FRAMEWORK[$wid]:-}" ]]; then
            pre+=("${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}")
        else
            post+=("${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}")
        fi
    done
    out_line "  Players need the same mods, in the same versions, in this order:"
    _mods_wrap "    " "${pre[@]}" "Native" "SandBox Core" "Sandbox" "${post[@]}" "Coop"
    out_line "  StoryMode and CustomBattle may stay on. War Sails, Birth and Aging"
    out_line "  Options and Fast Mode stay off."
}

# ---------------------------------------------------------------- commands --
# coop mods [list]
mods_cmd_list() {
    local ids=() wid scanned=0 rows=() n=0 json="[]" role installed note updates=()
    mapfile -t ids < <(mods_ids)
    [[ -f "$DIR_STATE/mods-update-available" ]] && mapfile -t updates <"$DIR_STATE/mods-update-available"

    if (( ${#ids[@]} )) && command -v xmlstarlet >/dev/null 2>&1 && _mods_scan "${ids[@]}" 2>/dev/null; then
        _mods_order "${ids[@]}"
        scanned=1
    else
        MODS_ORDER=("${ids[@]}")
    fi

    if is_json; then
        for wid in "${MODS_ORDER[@]}"; do
            n=$(( n + 1 ))
            json="$(jq -c --argjson acc "$json" --argjson n "$n" --arg w "$wid" \
                --arg id "${_MOD_ID[$wid]:-$(state_mod_get "$wid" module_id)}" \
                --arg name "${_MOD_NAME[$wid]:-$(state_mod_get "$wid" name)}" \
                --arg version "${_MOD_VERSION[$wid]:-$(state_mod_get "$wid" version)}" \
                --arg role "$(mods_role "${_MOD_ID[$wid]:-$(state_mod_get "$wid" module_id)}")" \
                --arg url "$(mods_workshop_url "$wid")" \
                --argjson installed "$(mods_installed "$wid" && echo true || echo false)" \
                --argjson update "$(_mods_in "$wid" "${updates[@]}" && echo true || echo false)" \
                -n '$acc + [{order:$n, workshop_id:$w, module_id:$id, name:$name, version:$version,
                             role:$role, installed:$installed, update_available:$update, url:$url}]')"
        done
        jq -n --argjson m "$json" --arg token "$( (( scanned )) && mods_module_token)" \
            '{ok:true, count:($m|length), mods:$m, module_list:(if $token == "" then null else $token end)}'
        return 0
    fi

    out_title "Mods"
    if (( ${#ids[@]} == 0 )); then
        out_line "  None. The server runs exactly as the Coop team ships it."
        out_line ""
        out_line "  Add one with: sudo coop mods add <Workshop ID or link>"
        out_line ""
        return 0
    fi

    rows=($'#\tNAME\tVERSION\tWORKSHOP\tON THE SERVER\tNOTE')
    for wid in "${MODS_ORDER[@]}"; do
        n=$(( n + 1 ))
        role="$(mods_role "${_MOD_ID[$wid]:-$(state_mod_get "$wid" module_id)}")"
        [[ "$role" == framework ]] && role="listed, no code" || role="loads"
        installed=1; mods_installed "$wid" || installed=0
        note=""
        (( installed )) || note="not installed"
        _mods_in "$wid" "${updates[@]}" && note="update available"
        rows+=("$(printf '%d\t%s\t%s\t%s\t%s\t%s' "$n" \
            "${_MOD_NAME[$wid]:-$(state_mod_get "$wid" name)}" \
            "${_MOD_VERSION[$wid]:-$(state_mod_get "$wid" version)}" \
            "$wid" "$role" "$note")")
    done
    out_table "${rows[@]}"
    out_line ""
    if (( scanned )); then
        _mods_players_note
        out_line ""
        local width=0 name
        for wid in "${MODS_ORDER[@]}"; do
            name="${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}"
            (( ${#name} > width )) && width=${#name}
        done
        out_line "  Workshop pages:"
        for wid in "${MODS_ORDER[@]}"; do
            out_line "    $(printf '%-*s  %s' "$width" "${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}" "$(mods_workshop_url "$wid")")"
        done
    else
        out_line "  Some mods are not installed, so the load order is not known yet."
        out_line "  Install them: sudo coop mods update"
    fi
    if (( ${#updates[@]} )); then
        out_line ""
        out_line "  ${C_YEL}Updates are available${C_OFF}. Install them with: sudo coop mods update"
    fi
    out_line ""
}

# coop mods add <Workshop ID or link>...
mods_cmd_add() {
    local arg id ids=() current=() new=() wid
    for arg in "$@"; do
        id="$(_mods_parse_id "$arg")" || fail "$EX_USAGE" \
            "Not a Workshop ID or link: $arg" \
            "Use the number in the item's address, as in ...filedetails/?id=3786391685"
        _mods_in "$id" "${ids[@]}" || ids+=("$id")
    done
    (( ${#ids[@]} )) || fail "$EX_USAGE" "Usage: coop mods add <Workshop ID or link>..."

    mapfile -t current < <(mods_ids)
    for id in "${ids[@]}"; do
        if _mods_in "$id" "${current[@]}"; then
            log "Workshop item $id is installed already."
        else
            new+=("$id")
        fi
    done
    (( ${#new[@]} )) || { log "Nothing to add."; return 0; }

    mods_require_tools
    docker_require
    out_title "Add mods"

    # Read what is installed, then what came, and what that needs.
    _mods_scan "${current[@]}" || fail "$EX_CONFIG" "$MODS_ERROR" \
        "Install the configured mods first: sudo coop mods update"
    steam_download_items "${new[@]}"
    for wid in "${new[@]}"; do
        _mods_read "$wid" "$(_mods_download_dir "$wid")" \
            || fail "$EX_CONFIG" "$MODS_ERROR" "Nothing was changed."
    done
    _mods_add_needed_frameworks || fail "$EX_CONFIG" "$MODS_ERROR" \
        "Add the Workshop item that provides each, in the same command." \
        "Nothing was changed."
    new+=("${MODS_ADDED[@]}")
    _mods_order "${current[@]}" "${new[@]}"

    out_line ""
    for wid in "${new[@]}"; do
        out_kv "Adding" "$(printf '%s %s  (%s)' "${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}" "${_MOD_VERSION[$wid]}" "$wid")"
    done
    out_line ""
    _mods_players_note
    out_line ""
    out_line "  The server stops with a closing save, is backed up, and starts again"
    out_line "  with the mods. Compatibility with Coop is not guaranteed by anyone: if"
    out_line "  it will not serve, the previous set is put back by itself."
    out_line ""
    confirm "Install these mods and restart with them?" yes || { log "Nothing was changed."; return 0; }
    _campaign_confirm_players

    mods_hook_build || fail "$EX_RUNTIME" "$MODS_ERROR" "Nothing was changed."
    for wid in "${new[@]}"; do
        _mods_install_download "$wid" || fail "$EX_RUNTIME" "$MODS_ERROR" "Nothing was changed."
    done

    local names; names="$(for wid in "${new[@]}"; do printf '%s, ' "${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}"; done)"
    _mods_change "${MODS_ORDER[*]}" "before adding ${names%, }"
    mods_update_check >/dev/null 2>&1 || true
    ok "The server serves with $(( ${#MODS_ORDER[@]} )) mod(s)"
    out_line "  See what players need at any time: coop mods"
    out_line ""
}

# Resolves a Workshop id, a link, a module id or a mod's name to an
# installed mod, into MODS_RESOLVED, after _mods_scan. A name may stop
# short at a word boundary, as long as only one mod's name begins that way:
# names often carry versions, as in "My Little Warband (v1.2.6/1.4.6)". A
# fragment of a word never matches, so "S" removes nothing. Sets
# MODS_ERROR when it fails.
MODS_RESOLVED=""
_mods_resolve() {
    local a="$1" wid hits=()
    MODS_RESOLVED=""
    if wid="$(_mods_parse_id "$a")" && [[ -n "${_MOD_ID[$wid]:-}" ]]; then
        MODS_RESOLVED="$wid"; return 0
    fi
    wid="${_MOD_BY_ID[${a,,}]:-}"
    [[ -n "$wid" ]] && { MODS_RESOLVED="$wid"; return 0; }
    for wid in "${!_MOD_NAME[@]}"; do
        [[ "${_MOD_NAME[$wid],,}" == "${a,,}" ]] && { MODS_RESOLVED="$wid"; return 0; }
        [[ -n "$a" && "${_MOD_NAME[$wid],,}" == "${a,,}"[\ \(]* ]] && hits+=("$wid")
    done
    if (( ${#hits[@]} == 1 )); then
        MODS_RESOLVED="${hits[0]}"; return 0
    fi
    if (( ${#hits[@]} > 1 )); then
        MODS_ERROR="'$a' could be any of: $(for wid in "${hits[@]}"; do printf '%s, ' "${_MOD_NAME[$wid]}"; done | sed 's/, $//')"
    else
        MODS_ERROR="no installed mod matches '$a'"
    fi
    return 1
}

# Does any module in the list need <module id>?
_mods_needed_by() {
    local want="${1,,}" wid need; shift
    for wid in "$@"; do
        for need in ${_MOD_NEEDS[$wid]}; do
            [[ "${need,,}" == "$want" ]] && return 0
        done
    done
    return 1
}

# coop mods remove <Workshop ID, link, module id or name>...
mods_cmd_remove() {
    local current=() remove=() keep=() arg wid changed=1 blockers=() needer
    (( $# )) || fail "$EX_USAGE" "Usage: coop mods remove <Workshop ID, link or module id>..."
    mods_require_tools
    mapfile -t current < <(mods_ids)
    _mods_scan "${current[@]}" || fail "$EX_CONFIG" "$MODS_ERROR" \
        "Install what is missing first: sudo coop mods update"

    for arg in "$@"; do
        _mods_resolve "$arg" \
            || fail "$EX_CONFIG" "${MODS_ERROR^}. Nothing was changed." "See them: coop mods"
        _mods_in "$MODS_RESOLVED" "${remove[@]}" || remove+=("$MODS_RESOLVED")
    done
    for wid in "${current[@]}"; do _mods_in "$wid" "${remove[@]}" || keep+=("$wid"); done

    # A mod that stays may not lose what it needs.
    for wid in "${remove[@]}"; do
        for needer in "${keep[@]}"; do
            _mods_needed_by "${_MOD_ID[$wid]}" "$needer" \
                && blockers+=("${_MOD_NAME[$needer]:-${_MOD_ID[$needer]}} needs ${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}")
        done
    done
    (( ${#blockers[@]} == 0 )) || fail "$EX_CONFIG" \
        "$(printf '%s; ' "${blockers[@]}" | sed 's/; $//'). Nothing was changed." \
        "Remove those as well, in the same command."

    # Frameworks that only the removed mods needed go with them.
    while (( changed )); do
        changed=0
        for wid in "${keep[@]}"; do
            [[ "$(mods_role "${_MOD_ID[$wid]}")" == framework ]] || continue
            _mods_needed_by "${_MOD_ID[$wid]}" "${remove[@]}" || continue
            local others=()
            for needer in "${keep[@]}"; do [[ "$needer" != "$wid" ]] && others+=("$needer"); done
            _mods_needed_by "${_MOD_ID[$wid]}" "${others[@]}" && continue
            remove+=("$wid")
            keep=("${others[@]}")
            changed=1
            break
        done
    done

    out_title "Remove mods"
    for wid in "${remove[@]}"; do
        out_kv "Removing" "$(printf '%s %s  (%s)' "${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}" "${_MOD_VERSION[$wid]}" "$wid")"
    done
    out_line ""
    out_line "  A campaign played with a mod can carry data of it. Loading it without"
    out_line "  the mod may lose that data or fail. The backup made now is the way"
    out_line "  back: coop backup restore, then the mods again with coop mods add."
    out_line ""
    confirm "Remove these mods and restart without them?" no || { log "Nothing was changed."; return 0; }
    _campaign_confirm_players

    local names; names="$(for wid in "${remove[@]}"; do printf '%s, ' "${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}"; done)"
    _mods_scan "${keep[@]}" || fail "$EX_CONFIG" "$MODS_ERROR"
    _mods_order "${keep[@]}"
    _mods_change "${MODS_ORDER[*]}" "before removing ${names%, }"
    for wid in "${remove[@]}"; do
        rm -rf -- "$(_mods_dir "$wid")"
        state_mod_remove "$wid"
    done
    mods_update_check >/dev/null 2>&1 || true
    if (( ${#keep[@]} )); then
        ok "Removed. The server serves with $(( ${#keep[@]} )) mod(s)"
    else
        ok "Removed. The server serves without mods, as the Coop team ships it"
    fi
    out_line ""
}

# coop mods update --check
mods_cmd_check() {
    local rc=0 wid
    mods_configured || {
        is_json && json_emit '{ok:true, update_available:false, updates:[]}'
        out_line "No mods are installed."
        return 0
    }
    mods_update_check || rc=$?
    if (( rc == 2 )); then
        is_json && json_emit '{ok:false, update_available:null, error:"Steam API unreachable"}'
        warn "Could not reach the Steam API; whether the mods have updates is unknown."
        return "$EX_STEAM"
    fi
    if is_json; then
        jq -n '{ok:true, update_available:($ARGS.positional|length > 0), updates:$ARGS.positional}' \
            --args "${MODS_UPDATES[@]}"
        return 0
    fi
    if (( ${#MODS_UPDATES[@]} == 0 )); then
        out_line "Every mod is up to date."
        return 0
    fi
    out_line "Updates are available on the Workshop for:"
    for wid in "${MODS_UPDATES[@]}"; do
        out_line "  $(state_mod_get "$wid" name) ($wid)"
    done
    out_line ""
    out_line "  Install them with: sudo coop mods update"
    out_line "  Players get Workshop updates by themselves, and a server left behind"
    out_line "  refuses them with \"Wrong version of module\"."
}

# Puts back the copies _mods_cmd_update set aside.
_MODS_PREVIOUS_DIR=""
_mods_restore_previous() {
    local d wid
    [[ -n "$_MODS_PREVIOUS_DIR" && -d "$_MODS_PREVIOUS_DIR" ]] || return 0
    for d in "$_MODS_PREVIOUS_DIR"/*; do
        [[ -d "$d" ]] || continue
        wid="$(basename "$d")"
        rm -rf -- "$(_mods_dir "$wid")"
        mv -- "$d" "$(_mods_dir "$wid")"
        _mods_record "$wid"
    done
}

# mods_prune - removes the installed copies, and their records, of mods
# MODS does not name. After a restore those belong to the state it
# replaced; left in place, a later start that names them again would run
# them as they were instead of fetching the current versions.
mods_prune() {
    local d wid ids=()
    mapfile -t ids < <(mods_ids)
    for d in "$DIR_MODS"/*/; do
        wid="$(basename "$d")"
        [[ "$wid" =~ ^[0-9]+$ ]] || continue
        _mods_in "$wid" "${ids[@]}" && continue
        rm -rf -- "${d%/}"
        state_mod_remove "$wid"
    done
    return 0
}

# _mods_changed <wid> - whether the download differs from the installed
# copy: a file with other contents, a new one, or one gone. Times alone do
# not count; a download touches folders without changing anything in them.
_mods_changed() {
    local line
    line="$(rsync -a --delete --checksum --dry-run --itemize-changes -- \
            "$(_mods_download_dir "$1")/" "$(_mods_dir "$1")/" 2>/dev/null \
            | grep -m1 -E '^([<>ch]|\*deleting)' || true)"
    [[ -n "$line" ]]
}

# coop mods update
mods_cmd_update() {
    local ids=() wid changed=()
    mapfile -t ids < <(mods_ids)
    (( ${#ids[@]} )) || { log "No mods are installed."; return 0; }
    mods_require_tools
    docker_require
    out_title "Update mods"

    steam_download_items "${ids[@]}"
    for wid in "${ids[@]}"; do
        if ! mods_installed "$wid"; then
            changed+=("$wid")
            continue
        fi
        _mods_changed "$wid" && changed+=("$wid")
    done
    if (( ${#changed[@]} == 0 )); then
        for wid in "${ids[@]}"; do _mods_record "$wid"; done
        mods_update_marker_clear
        ok "Every mod is up to date"
        return 0
    fi

    # The set as it will be: the updated items from their downloads.
    _mods_reset
    for wid in "${ids[@]}"; do
        if _mods_in "$wid" "${changed[@]}"; then
            _mods_read "$wid" "$(_mods_download_dir "$wid")"
        else
            _mods_read "$wid" "$(_mods_dir "$wid")"
        fi || fail "$EX_CONFIG" "$MODS_ERROR" "Nothing was changed."
    done
    _mods_add_needed_frameworks || fail "$EX_CONFIG" "$MODS_ERROR" "Nothing was changed."
    changed+=("${MODS_ADDED[@]}")
    _mods_order "${ids[@]}" "${MODS_ADDED[@]}"

    for wid in "${changed[@]}"; do
        local was; was="$(state_mod_get "$wid" version)"
        if [[ -n "$was" && "$was" != "${_MOD_VERSION[$wid]}" ]]; then
            out_kv "Updating" "${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}  $was -> ${_MOD_VERSION[$wid]}"
        elif mods_installed "$wid"; then
            out_kv "Updating" "${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}  ${_MOD_VERSION[$wid]}, new files"
        else
            out_kv "Installing" "${_MOD_NAME[$wid]:-${_MOD_ID[$wid]}}  ${_MOD_VERSION[$wid]}"
        fi
    done
    out_line ""
    out_line "  The server stops with a closing save, is backed up, and starts again."
    out_line "  If it will not serve, the previous versions are put back by themselves."
    out_line ""
    confirm "Install the updates and restart?" yes || { log "Nothing was changed."; return 0; }
    _campaign_confirm_players

    mods_hook_build || fail "$EX_RUNTIME" "$MODS_ERROR" "Nothing was changed."
    make_temp_dir "$DIR_MODS" _MODS_PREVIOUS_DIR
    for wid in "${changed[@]}"; do
        mods_installed "$wid" && mv -- "$(_mods_dir "$wid")" "$_MODS_PREVIOUS_DIR/$wid"
        if ! _mods_install_download "$wid"; then
            _mods_restore_previous
            fail "$EX_RUNTIME" "$MODS_ERROR" "The previous versions are in place again."
        fi
    done
    _mods_change "${MODS_ORDER[*]}" "before updating mods" _mods_restore_previous
    mods_update_marker_clear
    ok "Mods updated; the server serves with them"
    out_line ""
}
