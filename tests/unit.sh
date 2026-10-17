#!/usr/bin/env bash
#
# unit.sh - the guarantees that can be proven without a running server.
#
#   tests/unit.sh
#
# Needs bash, jq and GNU coreutils; nothing is installed and nothing outside
# a temporary directory is touched. Run by the lint workflow on every push.
#
# Each block states the promise it checks. A failure names the broken
# promise, not the line that noticed.

set -euo pipefail
COOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export COOP_ROOT
cd "$COOP_ROOT"
for m in common output config state docker server license bans campaign steam mods compat backup update provision; do
    # shellcheck source=/dev/null
    . "lib/$m.sh"
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass() { printf 'ok    %s\n' "$1"; }
nok()  { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

# A throwaway installation directory. Nothing in it is a real server.
CFG_OVERRIDE[INSTALL_DIR]="$T/inst"
config_load
mkdir -p "$DIR_CONFIG" "$DIR_SAVES" "$DIR_STATE" "$DIR_COOPDATA"
NON_INTERACTIVE=1

# ------------------------------------------------------- gameplay settings --
F=tests/modconfig
modconfig_merge "$F/previous.json" "$F/new.json" "$T/merged.json" "$T/report.txt"
grep -q '"birthAndDeath": false' "$T/merged.json" \
    || nok "a value the operator kept was replaced by the new default"
grep -q '"playerBattleAiJoinWindowHours": 12' "$T/merged.json" \
    || nok "a value the operator chose was replaced by the new default"
pass "values are kept, even where the build changed the default"

changed="$(modconfig_changed_defaults "$F/old-template.json" "$F/new.json" "$T/merged.json")"
[[ "$changed" == $'birthAndDeath\tfalse\ttrue' ]] \
    || nok "changed defaults misreported: '${changed//$'\t'/ | }'"
pass "a changed default is reported only where the old one was still in place"

for f in previous new; do sed 's/$/\r/' "$F/$f.json" >"$T/$f-crlf.json"; done
modconfig_merge "$T/previous-crlf.json" "$T/new-crlf.json" "$T/m-crlf.json" "$T/r-crlf.txt"
[[ "$(grep -vc $'\r$' "$T/m-crlf.json" || true)" == "0" ]] \
    || nok "a merged line lost its CRLF ending"
pass "CRLF line endings survive the merge"

mkdir -p "$T/build/engine/Modules/Coop"
cp "$F/new.json" "$T/build/engine/Modules/Coop/mod-config.default.json"
[[ "$(modconfig_template "$T/build")" == "$T/build/engine/Modules/Coop/mod-config.default.json" ]] \
    || nok "the template of a build was not found"
pass "a build's gameplay template is found"

# ---------------------------------------------------------------- state --
state_init
cp "$FILE_STATE" "$T/state.before"
if state_apply 'this is not a jq program' 2>/dev/null; then nok "a broken update reported success"; fi
cmp -s "$FILE_STATE" "$T/state.before" || nok "a failed update damaged the state file"
pass "a failed state update leaves the state file as it was"

# -------------------------------------------------------------- license --
mkdir -p "$T/old" "$T/terms"
[[ -z "$(license_id "$T/old")" ]] || nok "a build without terms has a terms id"
license_require "$T/old" >/dev/null 2>&1 || nok "a build without terms asked for acceptance"
pass "a build without license terms needs nothing"

printf 'EULA v1\r\n'    >"$T/terms/EULA.md"
printf 'LICENSE v1\r\n' >"$T/terms/LICENSE.txt"
[[ "$(license_id "$T/terms")" =~ ^[0-9a-f]{64}$ ]] || nok "a build with terms has no terms id"

rc=0; license_require "$T/terms" >/dev/null 2>&1 || rc=$?
(( rc == EX_LICENSE )) || nok "terms were accepted without anybody accepting them (rc $rc)"
ASSUME_YES=1
rc=0; license_require "$T/terms" >/dev/null 2>&1 || rc=$?
(( rc == EX_LICENSE )) || nok "--yes accepted license terms"
ASSUME_YES=0
license_accepted_for "$T/terms" && nok "a refusal was recorded as an acceptance"
pass "terms are never accepted without consent, and --yes is not consent"

# An ACCEPT_EULA exported for some other program - GitHub's runners export
# ACCEPT_EULA=Y for Microsoft's SQL tools - must neither accept these terms
# nor break the run.
for inherited in Y 1; do
    env ACCEPT_EULA="$inherited" COOP_ACCEPT_EULA=1 COOP_ROOT="$COOP_ROOT" \
        bash -c 'set -u; . "$COOP_ROOT/lib/common.sh"; [[ "$COOP_ACCEPT_EULA" == 0 ]]' \
        || nok "an inherited environment variable counted as --accept-eula ($inherited)"
done
pass "nothing in the environment accepts license terms"

COOP_ACCEPT_EULA=1
license_require "$T/terms" >/dev/null 2>&1 || nok "--accept-eula did not accept"
COOP_ACCEPT_EULA=0
license_accepted_for "$T/terms" || nok "an acceptance was not recorded"
[[ "$(license_acceptance "$(license_id "$T/terms")" | jq -r .method)" == "--accept-eula" ]] \
    || nok "the acceptance does not say how it was given"
pass "--accept-eula accepts, and the acceptance is recorded"

printf 'EULA v2\r\n' >"$T/terms/EULA.md"
license_accepted_for "$T/terms" && nok "changed terms counted as accepted"
printf 'EULA v1\r\n' >"$T/terms/EULA.md"
license_accepted_for "$T/terms" || nok "terms accepted earlier were forgotten"
pass "changed terms need a new acceptance; earlier ones are remembered for a rollback"

# ----------------------------------------------------------------- bans --
id=76561198000000042
ban_add "$id" "Example" >/dev/null 2>&1
ban_add "$id" ""        >/dev/null 2>&1
jq -e --arg id "$id" '.steamIds == [$id] and .entries == [{steamId: $id, heroName: "Example"}]' \
    "$FILE_BANS" >/dev/null || nok "banning twice duplicated the id or lost its name"
pass "a ban is recorded once, with its name"

printf '{"steamIds":[],"entries":[{"steamId":"76561198000000099","heroName":"Named"}],"note":"kept"}' >"$FILE_BANS"
[[ "$(bans_count)" == "1" ]] || nok "an id listed only under entries was not counted"
ban_remove 76561198000000099 >/dev/null 2>&1
jq -e '.entries == [] and .note == "kept"' "$FILE_BANS" >/dev/null \
    || nok "lifting a ban missed the entries list or dropped unrelated content"
pass "lifting a ban clears both lists and leaves the rest of the file alone"

printf '{"steamIds": ["1",]}' >"$FILE_BANS"
[[ "$(bans_count)" == "invalid" ]] || nok "a broken ban list was not recognised"
if ( ban_add "$id" >/dev/null 2>&1 ); then nok "a broken ban list was overwritten"; fi
grep -q '"1",]' "$FILE_BANS" || nok "a broken ban list was changed"
if ( ban_add 123 >/dev/null 2>&1 ); then nok "an id the server would ignore was accepted"; fi
pass "a broken list is refused rather than overwritten, and bad ids are rejected"

# ------------------------------------------------------------ campaigns --
for n in Alpha "My Campaign" default_new_game Alpha.backup1 Alpha.backup2 coop_bug_report TransferSave; do
    printf 'x' >"$DIR_SAVES/$n.sav"
done
printf '{}' >"$DIR_SAVES/Alpha.json"
[[ "$(campaign_names | paste -sd '|')" == "Alpha|My Campaign" ]] \
    || nok "the list holds files that are not campaigns: $(campaign_names | paste -sd '|')"
pass "templates, generations, bug reports and transfer saves are not campaigns"

[[ "$(campaign_resolve alpha)" == "Alpha" ]] || nok "a campaign was not found by a different case"
[[ -z "$(campaign_resolve Alpah)" ]]        || nok "a typo resolved to a campaign"
[[ -z "$(campaign_resolve TransferSave)" ]] || nok "a server file resolved to a campaign"
pass "names resolve without regard to case, typos do not resolve"

for good in "Campaign" "My Campaign" "Ünterwelt_2"; do
    [[ -z "$(_validate_value SAVE_NAME "$good")" ]] || nok "a valid name was refused: $good"
done
for bad in "" "a/b" 'a\b' "a:b" " lead" "trail " "dot." "CON" "x.backup1" "TransferSave" \
           "$(printf 'x%.0s' {1..65})"; do
    [[ -n "$(_validate_value SAVE_NAME "$bad")" ]] || nok "an unusable name was accepted: '$bad'"
done
pass "campaign names: spaces allowed, separators, reserved and server names refused"

cfg_set SAVE_NAME "Alpha";  campaign_start_allowed || nok "an existing campaign may not start"
cfg_set SAVE_NAME "alpha";  campaign_start_allowed || nok "a campaign in a different case may not start"
cfg_set SAVE_NAME "Alpah";  campaign_start_allowed && nok "a typo would have started a new world"
campaign_allow_new_world "Alpah"
campaign_start_allowed || nok "a requested new world may not start"
printf 'x' >"$DIR_SAVES/Alpah.sav"
campaign_settle_new_world
[[ -z "$(state_get new_world)" ]] || nok "a new world that exists is still marked as pending"
pass "a missing save starts only when a new world was asked for"

# --------------------------------------------------------------- restore --
# A backup from another machine brings that machine's server.env. What
# describes the host has to stay this host's; the rest is the backup's.
config_write_new "$FILE_CONFIG"
declare -A this_host=([INSTALL_DIR]="$INSTALL_DIR" [INSTANCE_ID]=default [PUID]=999 [PGID]=982 [STEAM_USERNAME]=here)
cfg_set PUID 988; cfg_set PGID 988; cfg_set STEAM_USERNAME there; cfg_set INSTANCE_ID other
cfg_set INSTALL_DIR /srv/elsewhere; cfg_set SAVE_NAME "From Backup"
_backup_keep_host_settings this_host >/dev/null 2>&1
[[ "$(cfg PUID):$(cfg PGID):$(cfg STEAM_USERNAME):$(cfg INSTANCE_ID)" == "999:982:here:default" ]] \
    || nok "a restore adopted the other host's ids, account or instance"
[[ "$INSTALL_DIR" == "$T/inst" && "$DIR_SAVES" == "$T/inst/saves" ]] || nok "a restore moved the installation's paths"
[[ "$(cfg SAVE_NAME)" == "From Backup" ]] || nok "a restore dropped a setting that belongs to the backup"
grep -qx 'PUID="999"' "$FILE_CONFIG" || nok "the host's values were not written to server.env"
pass "a restore keeps this host's directory, instance, user ids and Steam account"

# ------------------------------------------------------------------ mods --
for good in "" "3786391685" "2859188632 3786391685"; do
    [[ -z "$(_validate_value MODS "$good")" ]] || nok "a valid mod list was refused: '$good'"
done
for bad in "abc" "1  2" " 1" "1 " "1 1" "1;reboot" '$(id)' "1,2"; do
    [[ -n "$(_validate_value MODS "$bad")" ]] || nok "an unusable mod list was accepted: '$bad'"
done
pass "MODS holds Workshop ids, one space apart, each once"

[[ "$(_mods_parse_id 'https://steamcommunity.com/sharedfiles/filedetails/?id=3786391685&searchtext=')" == 3786391685 ]] \
    || nok "the id was not taken from a Workshop link"
_mods_parse_id 'https://example.com/?x=1' >/dev/null && nok "a link without an id produced one"
pass "a Workshop id is taken from an id or a link"

if command -v xmlstarlet >/dev/null 2>&1; then
    M=tests/mods
    declare -A W=([harmony]=11 [butterlib]=12 [uiextender]=13 [mcm]=14 [gameplay]=21 [split]=22 [patch]=23 [reserved]=91)
    mkdir -p "$DIR_MODS"
    for m in "${!W[@]}"; do cp -r "$M/$m" "$DIR_MODS/${W[$m]}"; done
    mkdir -p "$DIR_SERVER/engine/Modules/Coop" "$DIR_SERVER/engine/bin/Win64_Shipping_Server"
    printf '<Module><Id value="Coop" /></Module>\n' >"$DIR_SERVER/engine/Modules/Coop/SubModule.xml"
    printf 'x' >"$DIR_SERVER/BannerlordCoopServer.exe"
    mkdir -p "$(dirname "$FILE_HOOK")" && printf 'hook' >"$FILE_HOOK"

    _mods_reset
    _mods_read 91 "$DIR_MODS/91" && nok "an item claiming a game module's id was accepted"
    _mods_reset
    _mods_read 21 "$DIR_MODS/21" && _mods_read 99 "$DIR_MODS/21" && nok "two items with one module id were accepted"
    pass "items claiming a game module, or another item's module, are refused"

    _mods_scan 21 || nok "$MODS_ERROR"
    [[ "$(_mods_missing_needs | paste -sd ' ')" == "Bannerlord.Harmony Bannerlord.MBOptionScreen" ]] \
        || nok "missing dependencies misreported: '$(_mods_missing_needs | paste -sd ' ')'"
    pass "what a mod needs is found; game modules and optional ones do not count"

    _mods_scan 21 22 23 14 11 12 13 || nok "$MODS_ERROR"
    _mods_order 21 22 23 14 11 12 13
    [[ "${MODS_ORDER[*]}" == "11 12 13 14 21 22 23" ]] || nok "wrong load order: ${MODS_ORDER[*]}"
    pass "frameworks load first, each after what it needs; the rest keep the given order"

    want='_MODULES_*Bannerlord.Harmony*Bannerlord.ButterLib*Bannerlord.UIExtenderEx*Bannerlord.MBOptionScreen*Native*SandBoxCore*Sandbox*GameplayMod*SplitMod*PatchMod*Coop*DedicatedServer.Windows*_MODULES_'
    [[ "$(mods_module_token)" == "$want" ]] || nok "wrong module list: $(mods_module_token)"
    pass "the engine's module list: frameworks, the game, the mods, Coop and the server module last"

    mods_build_runtime || nok "$MODS_ERROR"
    R="$DIR_RUNTIME/engine/Modules"
    count() { xmlstarlet sel -T -t -v "count($1)" "$2"; }
    [[ "$(count '/Module/SubModules/SubModule' "$R/Bannerlord.Harmony/SubModule.xml")" == 0 ]] \
        || nok "a framework kept code on the server"
    [[ "$(xmlstarlet sel -T -t -m '/Module/SubModules/SubModule' -v 'SubModuleClassType/@value' -n "$R/Bannerlord.MBOptionScreen/SubModule.xml" | paste -sd ' ')" \
        == "MCM.MCMSubModule MCM.Internal.MCMImplementationSubModule" ]] || nok "MCM's settings core was not kept, or its interface was"
    pass "frameworks stay in the list without code, except MCM's settings core"

    [[ "$(count '//Tag[@key="DedicatedServerType" or @key="IsNoRenderModeElement"]' "$R/GameplayMod/SubModule.xml")" == 0 && \
       "$(count '/Module/SubModules/SubModule' "$R/GameplayMod/SubModule.xml")" == 1 ]] \
        || nok "a mod marked as not for servers would still be skipped"
    [[ "$(xmlstarlet sel -T -t -m '/Module/SubModules/SubModule' -v 'Name/@value' -n "$R/SplitMod/SubModule.xml")" == "Server half" ]] \
        || nok "a mod split into halves did not keep exactly its server half"
    pass "mods marked as not for servers load; a mod split into halves keeps its server half"

    for m in mcm gameplay split; do
        [[ "$(mods_manifest_value "$R/$(mods_manifest_value "$M/$m" Id)" Id)" == "$(mods_manifest_value "$M/$m" Id)" && \
           "$(mods_manifest_value "$R/$(mods_manifest_value "$M/$m" Id)" Version)" == "$(mods_manifest_value "$M/$m" Version)" ]] \
            || nok "the server copy of $m changed its Id or Version, which the join check compares"
        cmp -s "$M/$m/SubModule.xml" "$DIR_MODS/${W[$m]}/SubModule.xml" || nok "the installed manifest of $m was changed"
    done
    [[ "$(stat -c %i "$R/PatchMod/SubModule.xml")" == "$(stat -c %i "$DIR_MODS/23/SubModule.xml")" ]] \
        || nok "a manifest that needed no change was copied rather than linked"
    pass "Id and Version are untouched, the installed copies too, and nothing is copied without need"

    [[ -f "$R/GameplayMod/bin/Win64_Shipping_Server/Gameplay.dll" ]] || nok "a client-only mod has no server bin"
    grep -qxF "MODULES=$want" "$DIR_RUNTIME/coop-launch.txt" || nok "the launch file names other modules"
    grep -q '^ASSEMBLY_DIRS=Z:\\server\\engine\\Modules\\Coop\\bin\\Win64_Shipping_Server;' "$DIR_RUNTIME/coop-launch.txt" \
        || nok "the startup hook does not look in Coop's folder first"
    [[ -f "$DIR_RUNTIME/coop-hook/CoopHook.dll" && -f "$DIR_RUNTIME/BannerlordCoopServer.exe" ]] \
        || nok "the view lacks the hook or the server"
    pass "the view has the server, the hook, server bins for every mod, and a launch file that matches"

    printf '%s\r\n' 'Starting new log file...' \
        '[01:46:41.805] Messagebox [ERROR] message: Cannot load: gameplay.DLL' \
        '[01:46:41.852] Messagebox [ERROR] message: Cannot load: Missing.Dependency.dll' \
        '[01:46:41.853] Messagebox [ERROR] message: Cannot load: Missing.Dependency.dll' >"$T/rgl_log_errors_1.txt"
    [[ "$(mods_engine_errors "$T/rgl_log_errors_1.txt")" == "Messagebox [ERROR] message: Cannot load: Missing.Dependency.dll" ]] \
        || nok "the engine's error log was not cut down to its reason: '$(mods_engine_errors "$T/rgl_log_errors_1.txt")'"
    pass "of the engine's error log, only a library the startup hook cannot find either is shown, once"

    _MOD_NAME[21]="My Little Warband (v1.2.6/1.4.6)"; _MOD_NAME[22]="My Little Tavern"
    _mods_resolve "my little warband" && [[ "$MODS_RESOLVED" == 21 ]] || nok "a name cut short at a word was not found"
    _mods_resolve "PatchMod" && [[ "$MODS_RESOLVED" == 23 ]] || nok "a module id was not found"
    _mods_resolve "My Little" && nok "a name two mods begin with picked one of them"
    _mods_resolve "M" && nok "a fragment of a word picked a mod"
    pass "mods are found by id, link, module id, name, or a name cut short at a word, never by a fragment"

    first="$(stat -c %i "$DIR_RUNTIME")"
    mods_build_runtime || nok "$MODS_ERROR"
    [[ -d "$DIR_RUNTIME" && ! -e "${DIR_RUNTIME}.old" && ! -e "${DIR_RUNTIME}.new" && "$(stat -c %i "$DIR_RUNTIME")" != "$first" ]] \
        || nok "rebuilding the view left a half state behind"
    pass "the view is rebuilt beside the old one and swapped in"
else
    printf 'skip  mod manifests: xmlstarlet is not installed\n'
fi

if command -v rsync >/dev/null 2>&1; then
    src="$(_mods_download_dir 31)"
    mkdir -p "$src/bin/Win64_Shipping_Client" "$DIR_MODS"
    printf '<Module />\n' >"$src/SubModule.xml"
    printf 'v1' >"$src/bin/Win64_Shipping_Client/Mod.dll"
    cp -a "$src" "$(_mods_dir 31)"
    touch -d '2001-01-01' "$src/bin" "$src/SubModule.xml"
    _mods_changed 31 && nok "a download with other times and nothing else counted as an update"
    printf 'v2' >"$src/bin/Win64_Shipping_Client/Mod.dll"
    _mods_changed 31 || nok "a file with other contents of the same size went unnoticed"
    cp -a "$src/." "$(_mods_dir 31)/"
    rm "$src/bin/Win64_Shipping_Client/Mod.dll"
    _mods_changed 31 || nok "a file the download no longer has went unnoticed"
    pass "a mod changed when a file did, came or went; a touched folder is no update"
fi

mkdir -p "$DIR_MODS/41/bin" "$DIR_MODS/42" "$DIR_MODS/.coop-tmp.kept"
state_mod_set 41 '{"name":"Gone"}' && state_mod_set 42 '{"name":"Kept"}'
cfg_set MODS "42"
mods_prune
[[ ! -e "$DIR_MODS/41" && -z "$(state_mod_get 41 name)" ]] || nok "a mod MODS no longer names was left installed"
[[ -d "$DIR_MODS/42" && "$(state_mod_get 42 name)" == Kept && -d "$DIR_MODS/.coop-tmp.kept" ]] \
    || nok "pruning removed a configured mod, or something that is not a mod"
cfg_set MODS ""
pass "after a restore, mods the restored MODS does not name are removed, nothing else"

# --------------------------------------------------------- login message --
# Rendered the way provision_install_motd renders it, then run with sh, as
# update-motd would. A path with a quote and a space must survive.
quirky="$T/it's a server"
mkdir -p "$quirky/state" "$quirky/backups"
settings="$(printf 'D=%s\nCOOP=%s\nTITLE=%s' "$(_sh_quote "$quirky")" \
    "$(_sh_quote "coop --install-dir $quirky")" "$(_sh_quote "Bannerlord Coop (second)")")"
COOP_M_SETTINGS="$settings" awk '$0 == "@@SETTINGS@@" { print ENVIRON["COOP_M_SETTINGS"]; next } { print }' \
    templates/motd/bannerlordcoop.sh.tmpl >"$T/motd"

out="$(sh "$T/motd")"
grep -q "No backup yet" <<<"$out"                          || nok "a missing backup was not reported"
grep -q "Overview: coop --install-dir $quirky status" <<<"$out" || nok "the overview command lost the installation's path"
grep -q "Workshop update" <<<"$out"                        && nok "an update was reported without a marker"

grep -q "Mod updates" <<<"$out"                            && nok "mod updates were reported without a marker"

touch "$quirky/state/update-available" "$quirky/backups/auto-20261013-020252.tar.gz"
printf '3786391685\n' >"$quirky/state/mods-update-available"
out="$(sh "$T/motd")"
grep -q "a Workshop update is available" <<<"$out"          || nok "the update marker was not reported"
grep -q "Mod updates are available" <<<"$out"               || nok "the mod update marker was not reported"
grep -q "Last backup: auto-20261013-020252.tar.gz" <<<"$out" || nok "the last backup was not reported"
[[ -z "$(sh "$T/motd" 2>&1 >/dev/null)" ]]                  || nok "the login message wrote errors"

rm -rf "$quirky"
[[ -z "$(sh "$T/motd")" ]] || nok "a removed installation still produced a login message"
pass "the login message reports both update markers and the last backup, for any path"

printf '\nAll unit checks passed.\n'
