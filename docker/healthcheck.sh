#!/bin/sh
# Container health check.
#
# A bare process check reports a hung server as healthy, so this also asks
# whether the server has said anything recently. The server emits a "pulse"
# line on every campaign tick, which makes log freshness a fair liveness
# signal once it is serving.
#
# During start-up the campaign load takes minutes on a grown save; that is
# what compose's start_period covers, and the log-age test is skipped while
# no log file exists yet.
#
# Without mods the official launcher runs the server; with mods the engine
# runs without it (see docker/entrypoint.sh). Either process counts.

pgrep -f 'BannerlordCoopServer|TaleWorlds\.Starter\.DotNetCore' >/dev/null 2>&1 || exit 1

MAX_AGE="${COOP_LOG_MAX_AGE:-300}"
LOG_DIR=/data/logs

[ -d "$LOG_DIR" ] || exit 0
NEWEST=$(ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -1)
[ -n "$NEWEST" ] || exit 0

NOW=$(date +%s)
MTIME=$(stat -c %Y "$NEWEST" 2>/dev/null || echo "$NOW")
AGE=$(( NOW - MTIME ))

[ "$AGE" -le "$MAX_AGE" ] || exit 1
exit 0
