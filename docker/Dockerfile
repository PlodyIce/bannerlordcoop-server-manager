# Bannerlord Coop dedicated server - Wine runtime
#
# WHY WINE
# --------
# The dedicated server is shipped as a Windows x64 build; release-info.txt
# in the Workshop item says so, and engine/bin/ contains only
# Win64_Shipping_Server. There is no Linux build and none is planned.
#
# The case is friendlier than it sounds: the server is a pure console
# process with no graphics, and it brings its own self-contained .NET 6
# runtime under engine/dotnet/. No Steam client is needed at runtime. A
# slim Wine without Mono, Gecko or an X server is therefore enough.
#
# i386 IS NOT OPTIONAL. WineHQ packages winehq-stable with a hard
# dependency on wine-stable-i386, even for a pure win64 application.
#
# The image contains the runtime only. Server files and game data are
# mounted at run time under /server (read-only) and /data.

ARG BASE_IMAGE=debian:trixie-slim
# For reproducible builds, pin a digest instead:
#   --build-arg BASE_IMAGE=debian@sha256:<digest>
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG WINE_BRANCH=stable
ARG PUID=1000
ARG PGID=1000

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates wget gnupg procps tzdata \
 && install -d -m 0755 /etc/apt/keyrings \
 && wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && printf 'Types: deb\nURIs: https://dl.winehq.org/wine-builds/debian\nSuites: trixie\nComponents: main\nArchitectures: amd64 i386\nSigned-By: /etc/apt/keyrings/winehq-archive.key\n' \
        > /etc/apt/sources.list.d/winehq.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends "winehq-${WINE_BRANCH}" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# The numeric IDs matter, not the name: files on the host and files inside
# the container have to be owned by the same ID. The installer passes the
# IDs of the service user it created.
RUN groupadd -g "${PGID}" coop \
 && useradd -u "${PUID}" -g "${PGID}" -m -d /home/coop -s /bin/bash coop \
 && install -d -o coop -g coop /server /data \
 && install -d -o coop -g coop -m 0700 /home/coop/.runtime

ENV HOME=/home/coop \
    WINEPREFIX=/home/coop/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    COOP_FIFO=/tmp/coop.cmd \
    XDG_RUNTIME_DIR=/home/coop/.runtime \
    PATH="/opt/wine-stable/bin:/opt/wine-staging/bin:/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

USER coop
WORKDIR /server

# Create the Wine prefix during the build: faster starts, and no persistent
# state outside the volumes, so the container stays disposable.
RUN wineboot --init && wineserver -w

# The scripts come after everything slow. They are what changes when the
# manager is updated, and placed here a change to them rebuilds seconds'
# worth of layers instead of the Wine prefix.
USER root
COPY entrypoint.sh coop-cmd healthcheck.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/coop-cmd /usr/local/bin/healthcheck.sh
USER coop

HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# A checksum of this directory's scripts and of this file, worked out by
# the manager. An image whose label differs from the manager's checksum was
# built from older files, and is rebuilt before the next start, so an
# updated checkout never runs with a stale entrypoint.
ARG IMAGE_FINGERPRINT=unknown
LABEL org.bannerlordcoop.fingerprint="${IMAGE_FINGERPRINT}"
