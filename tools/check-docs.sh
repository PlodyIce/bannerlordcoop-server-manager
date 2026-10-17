#!/usr/bin/env bash
#
# check-docs.sh - verifies that the documentation describes the software
# that actually exists.
#
# Three things drift silently between code and prose: command names,
# configuration keys, and links. All three are checkable, so they are
# checked in CI rather than trusted.

set -uo pipefail
COOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$COOP_ROOT" || exit 1
export COOP_ROOT

# shellcheck source=/dev/null
. lib/common.sh
# shellcheck source=/dev/null
. lib/output.sh
# shellcheck source=/dev/null
. lib/config.sh

problems=0
note() { printf '  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; problems=$(( problems + 1 )); }

FILES=(README.md docs/*.md)

# --------------------------------------------------------------- commands --
# The commands bin/coop actually dispatches on.
mapfile -t KNOWN < <(
    awk '/^# ---.*dispatch/,0' bin/coop \
        | sed -n 's/^[[:space:]]*\([a-z|-]*\))[[:space:]].*/\1/p' \
        | tr '|' '\n' | grep -vE '^\*?$' | sort -u
)
# Subcommands, which are dispatched inside a command rather than by the
# top-level case statement.
EXTRA=(list info restore status login logout)

# Phrases that begin with "coop" but are not invocations: quoted server log
# lines. Kept explicit rather than loosening the pattern, so a genuinely
# wrong command name still fails.
NOT_A_COMMAND=(assembly)

is_known() {
    local c
    for c in "${KNOWN[@]}" "${EXTRA[@]}" "${NOT_A_COMMAND[@]}"; do
        [[ "$c" == "$1" ]] && return 0
    done
    return 1
}

printf '\nCommands referenced in the documentation\n'
mapfile -t USED < <(
    # Not preceded by a slash: "bin/coop in the checkout" inside a diagram
    # is prose about a path, not a command reference.
    grep -rhoE '(^|[^/[:alnum:]])coop (--[a-z-]+ [^ ]+ )*[a-z][a-z-]*' "${FILES[@]}" \
        | sed -E 's/^[^c]*coop ( *--[a-z-]+ [^ ]+)* *//' \
        | awk '{print $1}' | sort -u
)
for c in "${USED[@]}"; do
    [[ -n "$c" ]] || continue
    if is_known "$c"; then
        note "ok    coop $c"
    else
        bad "documented command does not exist: coop $c"
    fi
done

# ---------------------------------------------------------- config keys --
printf '\nConfiguration keys referenced in the documentation\n'
# Words that look like a setting but are not one. The last group are the
# dedicated server's own environment variables, which are not settings of
# this manager.
IGNORE='^(BEGIN|END|GENERATED|SETTINGS|UDP|TCP|MIT|JSON|JSONC|SHA|CPU|RAM|GB|MB|KB|ID|OS|CI|CLI|API|URL|VPS|SSH|DNS|PID|LTS|RHEL|BANNERLORD|COOP|STEAM|DOCKER|WINE|SIGTERM|SIGKILL|PATH|HOME|TMPDIR|NO_COLOR|DEBIAN_FRONTEND|EX_[A-Z]+|FORWARD|DOCKER-USER|ON_?CALENDAR|ONCALENDAR|README|LICENSE|VERSION|INSTALL_DIR_[A-Z]*|DS_ACCEPT_EULA|COOP_DATA_DIR|COOP_STEAM_BAN_FILE|BANNERLORD_USER_DIR|SERVING)$'
mapfile -t KEYS_USED < <(
    grep -rhoE '`[A-Z][A-Z0-9_]{2,}`' "${FILES[@]}" | tr -d '`' | sort -u
)
for k in "${KEYS_USED[@]}"; do
    [[ "$k" =~ $IGNORE ]] && continue
    if [[ -n "${CONFIG_SPEC[$k]:-}" ]]; then
        note "ok    $k"
    else
        bad "documented setting does not exist: $k"
    fi
done

# Every setting should be documented somewhere.
printf '\nSettings missing from the documentation\n'
while IFS= read -r k; do
    grep -rqF "\`$k\`" "${FILES[@]}" || bad "setting is not documented anywhere: $k"
done < <(config_keys)
(( problems == 0 )) && note "none"

# -------------------------------------------------------------- paths --
printf '\nGenerated and referenced files\n'
for f in templates/server-config.json.tmpl templates/motd/bannerlordcoop.sh.tmpl config/defaults.env \
         templates/systemd/bannerlordcoop-backup@.service \
         templates/systemd/bannerlordcoop-backup@.timer \
         templates/systemd/bannerlordcoop-update-check@.service \
         templates/systemd/bannerlordcoop-update-check@.timer \
         docker/Dockerfile docker/entrypoint.sh docker/coop-cmd \
         docker/healthcheck.sh compose.yaml bin/coop install.sh LICENSE VERSION; do
    [[ -f "$f" ]] && note "ok    $f" || bad "referenced by the code but missing: $f"
done

# -------------------------------------------------------------- links --
printf '\nInternal documentation links\n'
mapfile -t LINKS < <(grep -rhoE '\]\(([A-Za-z0-9_./-]+\.md)(#[^)]*)?\)' "${FILES[@]}" \
    | sed -E 's/^\]\(//; s/(#[^)]*)?\)$//' | sort -u)
for l in "${LINKS[@]}"; do
    if [[ -f "$l" || -f "docs/$l" ]]; then
        note "ok    $l"
    else
        bad "broken link: $l"
    fi
done

printf '\n'
if (( problems == 0 )); then
    printf 'Documentation matches the implementation.\n'
    exit 0
fi
printf '%d problem(s) found.\n' "$problems"
exit 1
