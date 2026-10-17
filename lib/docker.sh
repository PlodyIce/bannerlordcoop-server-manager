# shellcheck shell=bash
#
# docker.sh - everything that talks to Docker Compose or inspects the
# container. Keeping it in one file means the rest of the project never has
# to remember the project name, the env file or the compose file path.

# dc <compose-args...>
#
# Always fully qualified: an explicit project name and env file mean the
# result does not depend on the current working directory, and two
# instances on one host cannot collide.
dc() {
    docker compose \
        --project-name "$COMPOSE_PROJECT" \
        --env-file "$FILE_COMPOSE_ENV" \
        --file "${COOP_ROOT}/compose.yaml" \
        "$@"
}

container_exists()   { docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; }
container_running()  { [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)" == "true" ]]; }
container_health()   { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo none; }
container_started()  { docker inspect -f '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null || echo ""; }
container_exitcode() { docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo "?"; }

# How often Docker has restarted this container. With restart:unless-stopped
# a container that dies immediately is "running" often enough to fool a
# plain liveness test, so this is how a crash loop is told apart from a slow
# start.
container_restart_count() {
    local n
    n="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'
}

container_uptime_seconds() {
    local started epoch
    started="$(container_started)"
    [[ -n "$started" ]] || { echo 0; return; }
    epoch="$(date -d "$started" +%s 2>/dev/null)" || { echo 0; return; }
    echo $(( $(date +%s) - epoch ))
}

# Logs of the CURRENT container start only.
#
# This is not a detail: wait_serving() looks for a "serving" event, and a
# "serving" line left over from a previous run would make a failed start
# look successful.
container_logs_current() {
    local since
    since="$(container_started)"
    [[ -n "$since" ]] || { echo ""; return 0; }
    docker logs --since "$since" "$CONTAINER_NAME" 2>&1 | tr -d '\r'
}

container_logs_tail() {
    docker logs --tail "${1:-100}" "$CONTAINER_NAME" 2>&1 | tr -d '\r'
}

container_stats() {
    # Single shot; the streaming form would never return.
    docker stats --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' "$CONTAINER_NAME" 2>/dev/null
}

docker_require() {
    command -v docker >/dev/null 2>&1 || fail "$EX_DEPS" \
        "Docker is not installed." \
        "Run 'coop doctor' for details."
    docker info >/dev/null 2>&1 || fail "$EX_DEPS" \
        "The Docker daemon is not responding." \
        "Check: systemctl status docker"
}

image_name() { printf 'bannerlordcoop/server:%s' "$(cfg WINE_BRANCH)"; }

image_exists() {
    docker image inspect "$(image_name)" >/dev/null 2>&1
}

# A checksum of what the image is built from. The image carries it as a
# label, so an image built from older files can be recognised: a checkout
# updated with git pull brings a new entrypoint, and the image would
# otherwise keep running the old one until somebody thought of rebuilding.
image_fingerprint() {
    cat "${COOP_ROOT}/docker/Dockerfile" "${COOP_ROOT}/docker/entrypoint.sh" \
        "${COOP_ROOT}/docker/coop-cmd" "${COOP_ROOT}/docker/healthcheck.sh" 2>/dev/null \
        | sha256sum | cut -c1-16
}

image_is_current() {
    [[ "$(docker image inspect -f '{{ index .Config.Labels "org.bannerlordcoop.fingerprint" }}' \
            "$(image_name)" 2>/dev/null)" == "$(image_fingerprint)" ]]
}

# Builds the runtime image. Slow the first time - Wine plus a Wine prefix.
image_build() {
    step "Building the server runtime image (this takes a few minutes on first run)"
    dc build "$@" || fail "$EX_RUNTIME" \
        "Could not build the runtime image." \
        "Re-run with --verbose to see the build output."
    ok "Runtime image ready"
}

# The same, for the start of a server: nothing to do when the image is
# current, and a failure is reported rather than ending the run, because a
# caller such as an update has to be able to roll back. Usually only the
# scripts changed, and they sit last in the image: seconds.
image_refresh() {
    image_is_current && return 0
    log "The runtime image was built from older files. Rebuilding it."
    if ! dc build >/dev/null 2>&1; then
        warn "Could not rebuild the runtime image."
        out_line "    See why with a repair, which rebuilds it in full view: sudo coop install"
        return 1
    fi
    ok "Runtime image rebuilt"
}
