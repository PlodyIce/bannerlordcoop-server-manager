#!/usr/bin/env bash
#
# Entrypoint for the Bannerlord Coop dedicated server running under Wine.
#
# WHY A WRAPPER IS NEEDED
# -----------------------
# Signals do not stop this server. `docker compose stop` ran into its 120 s
# timeout and ended in exit 137 - a SIGKILL, possibly in the middle of
# writing a save. PID 1 ignores signals without a handler of its own, and
# Wine does not forward them to the Windows process.
#
# The server does have a console:
#     status  players  save  say  kick  stop  help
#
# So this wrapper attaches a FIFO to the server's stdin. On SIGTERM it
# writes "stop" and waits for the server to finish its closing save. The
# same channel lets the manager trigger a save before a backup:
#
#     docker exec <container> coop-cmd save
#
# Measured result of the change: 2 seconds, exit 0, save written.
#
# TWO WAYS TO START
# -----------------
# Without mods, BannerlordCoopServer.exe starts the server, as the Coop team
# ships it. That launcher starts the game engine with a fixed module list
# and cannot add a mod to it, so with mods the engine is started directly
# instead: the same program, arguments, working directory and environment
# the launcher uses, with the mods in the module list. The manager decides
# which by what it mounts at /server: a server with mods carries a launch
# file, coop-launch.txt. lib/mods.sh explains the rest.

set -uo pipefail

SERVER_EXE="${SERVER_EXE:-/server/BannerlordCoopServer.exe}"
DATA_DIR="${DATA_DIR:-Z:\\data}"
STOP_TIMEOUT="${STOP_TIMEOUT:-150}"
FIFO="${COOP_FIFO:-/tmp/coop.cmd}"
LAUNCH_FILE="${COOP_LAUNCH_FILE:-/server/coop-launch.txt}"

rm -f "$FIFO"
mkfifo -m 0600 "$FIFO"

# Hold both ends open. With only a writer attached, the server would see
# EOF on stdin every time a command finished writing.
exec 3<>"$FIFO"

log() { printf '[entrypoint] %s\n' "$*"; }

# The process copying the engine's output into the log file, when there is
# one. When the engine exits, the last lines it wrote may still be in the
# pipe, and exiting before the copy has caught up stops the container and
# takes them with it. So it is waited for, but only briefly, in case a
# child of the engine still holds the pipe open.
#
# A crashing engine loses the end of its output before it ever reaches the
# pipe, so its console log ends mid-line whatever happens here. Its own
# error log in logs/engine/logs has the reason.
TEE=""
finish_log() {
    [[ -n "$TEE" ]] || return 0
    local waited=0
    while kill -0 "$TEE" 2>/dev/null && (( waited < 50 )); do
        sleep 0.1
        waited=$(( waited + 1 ))
    done
    kill "$TEE" 2>/dev/null || true
}

graceful_stop() {
    log "signal received, sending 'stop' to the server console"
    printf 'stop\n' >&3
    local waited=0
    while kill -0 "$SRV" 2>/dev/null && (( waited < STOP_TIMEOUT )); do
        sleep 1
        waited=$(( waited + 1 ))
    done

    if kill -0 "$SRV" 2>/dev/null; then
        log "no response after ${STOP_TIMEOUT}s, terminating"
        kill -TERM "$SRV" 2>/dev/null || true
        sleep 5
        kill -KILL "$SRV" 2>/dev/null || true
    else
        log "server stopped cleanly after ${waited}s"
    fi

    wait "$SRV" 2>/dev/null
    local code=$?
    finish_log
    log "exit code $code"
    exit "$code"
}

# The launch file is written by the manager. It is read as data, one
# KEY=VALUE per line, and never sourced.
LAUNCH_MODULES=""
LAUNCH_HOOK=""
LAUNCH_ASSEMBLY_DIRS=""
read_launch_file() {
    local key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        value="${value%$'\r'}"
        case "$key" in
            MODULES)       LAUNCH_MODULES="$value" ;;
            HOOK)          LAUNCH_HOOK="$value" ;;
            ASSEMBLY_DIRS) LAUNCH_ASSEMBLY_DIRS="$value" ;;
        esac
    done <"$LAUNCH_FILE"
}

# The launcher writes a log file per launch, keeping the newest ten, when
# server-config.json asks for one. Without the launcher this does the same.
engine_log_file() {
    [[ "${COOP_SERVER_LOG_FILE:-true}" == "true" ]] || return 0
    local dir=/data/logs
    [[ -d "$dir" ]] || return 0
    ls -1t "$dir"/coop-server-*.log 2>/dev/null | tail -n +10 | while IFS= read -r old; do
        rm -f -- "$old"
    done
    printf '%s/coop-server-%s.log' "$dir" "$(date +%Y%m%d-%H%M%S)"
}

if [[ ! -f "$SERVER_EXE" ]]; then
    log "server executable not found: $SERVER_EXE"
    log "the server files are missing. Run 'coop update --force' on the host"
    exit 2
fi

if [[ -f "$LAUNCH_FILE" ]]; then
    read_launch_file
    if [[ -z "$LAUNCH_MODULES" ]]; then
        log "$LAUNCH_FILE names no modules. Run 'coop mods update' on the host"
        exit 2
    fi

    # Exactly what BannerlordCoopServer.exe sets for the engine, read from
    # the environment of a running official server (Coop v0.1.6). The
    # CoopData path is the one the launcher works out for the Wine user,
    # and the folder compose.yaml mounts.
    export DOTNET_ROOT='Z:\server\engine\dotnet'
    export DOTNET_MULTILEVEL_LOOKUP=0
    export BANNERLORD_USER_DIR="$DATA_DIR"
    export COOP_DATA_DIR='C:\users\coop\Documents\Mount and Blade II Bannerlord\CoopData'
    export DOTNET_STARTUP_HOOKS="$LAUNCH_HOOK"
    export COOP_ASSEMBLY_DIRS="$LAUNCH_ASSEMBLY_DIRS"

    cd /server/engine/bin/Win64_Shipping_Server || { log "the engine is missing from /server"; exit 2; }
    LOG_FILE="$(engine_log_file)"
    log "starting with mods: wine dotnet.exe TaleWorlds.Starter.DotNetCore.dll $LAUNCH_MODULES /dedicatedcustomserver 7210 EU 0"
    if [[ -n "$LOG_FILE" ]]; then
        log "log file: $LOG_FILE"
        OUT_PIPE=/tmp/coop.out
        rm -f "$OUT_PIPE"
        mkfifo -m 0600 "$OUT_PIPE"
        tee -a "$LOG_FILE" <"$OUT_PIPE" &
        TEE=$!
        wine ../../dotnet/dotnet.exe TaleWorlds.Starter.DotNetCore.dll "$LAUNCH_MODULES" \
            /dedicatedcustomserver 7210 EU 0 <&3 >"$OUT_PIPE" 2>&1 &
    else
        wine ../../dotnet/dotnet.exe TaleWorlds.Starter.DotNetCore.dll "$LAUNCH_MODULES" \
            /dedicatedcustomserver 7210 EU 0 <&3 &
    fi
else
    log "starting: wine $SERVER_EXE --data-dir $DATA_DIR"
    wine "$SERVER_EXE" --data-dir "$DATA_DIR" <&3 &
fi
SRV=$!
trap graceful_stop TERM INT

wait "$SRV"
CODE=$?
finish_log
log "server process ended, exit code $CODE"

# The server's own exit codes, worth naming in the log because the most
# common one is easy to misread as a crash:
#   0  clean shutdown
#   2  load error or timeout
#   3  runtime failure
#   4  module verification failed - files under Modules/Coop were modified
#   6  the license terms of this build have not been accepted
#  82  the engine gave up while loading its modules
case "$CODE" in
    4) log "exit 4 means the Coop assemblies do not match the release." \
           "Run 'coop update --force' or 'coop rollback' on the host." ;;
    6) log "exit 6 means the license terms of this build have not been accepted." \
           "Run 'coop eula' on the host." ;;
    82) log "exit 82 means the engine gave up while loading its modules." \
            "With mods, the usual cause is a mod that cannot run on a dedicated server. See the lines above." ;;
esac
exit "$CODE"
