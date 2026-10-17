# Architecture

How this works, and why it works that way. The figures below come from
running servers on Ubuntu 26.04 and Debian 13, not from documentation.
They are recorded so that anyone tempted to simplify something can see
what it was protecting against.

## The layers

```
Host: Linux, x86_64, headless
 |
 +-- systemd            two timers: backup, update check
 +-- /usr/local/bin/coop -> bin/coop in the checkout
 +-- Docker Engine
     |
     +-- container "bannerlordcoop-<instance>"   long-running
     |   +-- Debian + WineHQ (amd64 + i386)
     |       +-- wine BannerlordCoopServer.exe --data-dir Z:\data
     |           or, with mods, the engine it starts, directly
     |
     +-- steamcmd container                       throwaway, on demand

/srv/bannerlordcoop: persistent, outside the container
    server/       -> /server  (read-only; runtime/ instead with mods)
    config/       -> /data
    saves/        -> /data/Game Saves
    logs/         -> /data/logs
    coopdata/     -> the Bannerlord user folder inside the Wine prefix
    userconfigs/  -> the game's Configs folder there, for mods
    logs/engine/  -> the engine's own logs and crash reports in the prefix
    workshop/  mods/  runtime/  state/  rollback/  backups/
```

The container is disposable. Every piece of state lives on the host and is
bind-mounted in, so the image can be rebuilt at any time without risking a
campaign.

## Wine is required

The dedicated server ships as a **Windows x64** build. `release-info.txt`
in the Workshop item says so, and `engine/bin/` contains only
`Win64_Shipping_Server`. There is no Linux build.

The case is friendlier than it sounds. The server is a pure console process
with no graphics, and it brings its own self-contained .NET 6 runtime. No
Steam client is needed at runtime. So the image needs a slim Wine with no
Mono, no Gecko and no X server.

**i386 is not optional.** WineHQ packages `winehq-stable` with a hard
dependency on `wine-stable-i386`, even for a pure win64 application.

This is also why arm64 is unsupported: running a Windows x64 binary there
would need box64 or FEX on top of Wine. That is exactly the kind of
dependency layering this project refuses to perform, so the architecture
check rejects it up front rather than half-working.

## The container must not be stopped by signal

Stopping the container with a signal does not work. `docker compose stop`
runs into its 120 second timeout and ends in exit 137, a SIGKILL, possibly
in the middle of writing a save.

PID 1 ignores signals without a handler of its own, and Wine does not
forward them to the Windows process.

The server does have a console:

```
status  players  save  say  kick  stop  help
```

So `docker/entrypoint.sh` attaches a FIFO to the server's stdin, traps
SIGTERM, and writes `stop`. Measured result: **2 seconds, exit 0, closing
save written**.

The same channel carries commands from outside:

```bash
docker exec bannerlordcoop-default coop-cmd save
```

```bash
coop console players
```

`stop_grace_period` in `compose.yaml` is 180s, deliberately longer than the
entrypoint's own 150s timeout, so Docker never loses patience first.

## Knowing what the server is doing

Two things the server publishes, both discovered by reading its output.

**Structured events**, one JSON object per line behind an `@DS@` prefix:

```
@DS@{"ev":"state","phase":"serving","save":"Campaign","pw":true}
@DS@{"ev":"players","list":[]}
```

`phase` is `boot`, `loading` or `serving`. `wait_serving()` is built on it.

**A pulse line**, refreshed on every campaign tick:

```
pulse: time=Spring 1, 1095 timeMode=Stop players=0 parties=1954
```

Both are read from the logs of the **current container start only**. A
`serving` line left over from a previous run would make a failed start look
successful. That is a failure mode worth preventing once rather than
debugging twice.

## Server exit codes

| Code | Meaning |
|---|---|
| 0 | Clean shutdown |
| 2 | Load error or timeout |
| 3 | Runtime failure |
| 4 | Module verification failed: files under `Modules/Coop` were modified |
| 5 | The engine crashed. Seen with a mod whose code could not be loaded; the engine's error log in `logs/engine/logs` has the reason |
| 6 | The build's license terms have not been accepted (Coop v0.1.6 and later) |
| 82 | The engine gave up while loading its modules; with mods, usually one that cannot run on a dedicated server |

Exit 4 is why `/server` is mounted **read-only**: the server checks its
Coop assemblies with SHA-256 and refuses to start if they differ. What
cannot be written cannot drift.

## License terms are the operator's to accept

From Coop v0.1.6 on, the server ships with an EULA and a license of its
own, and exits 6 until they have been accepted. It records an acceptance
itself, in `eula.txt` in its data directory, when it is started with
`DS_ACCEPT_EULA=true`. The terms ask for a deliberate acceptance and
forbid bypassing the check, so the manager does neither:

- `compose.yaml` declares `DS_ACCEPT_EULA` **without a value**. Compose then
  passes it only when it is set in the environment of `docker compose`
  itself, and `coop` sets it only when starting a build whose terms the
  operator accepted.
- An acceptance is recorded in `state/install-state.json` against a SHA-256
  of exactly the documents that were accepted, with who accepted and how.
  A build whose documents differ by a byte is a build whose terms have not
  been accepted, which is how "changed terms require fresh acceptance"
  holds without anybody having to notice.
- Acceptance takes "y" at a terminal or the explicit `--accept-eula` flag.
  `--yes` confirms operations; it is not consent to a license, and it does
  not count.
- When the server refuses anyway, `server_start()` sees the refusal in
  its output, stops Docker restarting it into the same refusal, and says
  what to do.

`coop update` downloads first and settles the new build's terms before it
stops anything, so declining them, or an unattended run that cannot ask,
leaves the server running the build it had.

## Waiting properly

Two places where a fixed `sleep` would be the weakest link in the chain:

- **`server_save()`** triggers a save and then watches the modification
  time of the `.sav` file until it actually changes. The whole backup
  guarantee rests on this.
- **`server_start()`** waits for `phase=serving`, not for the container to
  be up. Loading a grown campaign takes about two minutes.

## Three copies of the game files

```
Steam Workshop --steamcmd--> workshop/ --rsync--> server/ --ro-mount--> container
                                                     |
                                    before an update: rsync --> rollback/
```

This costs about 18 GB, and buys two things: a download can never quietly
change the running installation, and a rollback is a directory swap rather
than a six-gigabyte download at the worst possible moment.

## mod-config.json does not follow `--data-dir`

Configuration, saves and logs land in the mounted volumes because of
`--data-dir Z:\data`. **`mod-config.json` does not.** It follows
Bannerlord's own user folder inside the Wine prefix:

```
C:\users\coop\Documents\Mount and Blade II Bannerlord\CoopData\mod-config.json
```

Without its own bind mount it would be lost on every container rebuild.
That is what the `coopdata/` mount is for.

The mod creates the file once from the template its build ships and never
replaces it, so a new build's settings would never reach it. An update
therefore merges the new template with the file before the new build
first starts. [UPDATES.md](UPDATES.md) has the details.

## The ban list lives in config/

From Coop v0.1.6 on, the server refuses the Steam accounts in
`steam-bans.json`. Left to itself it looks in `server-data/` beside its
engine directory, which is inside `server/`: mounted read-only, and
replaced wholesale by every update and rollback. A ban kept there would
vanish at the next update and be in no backup.

`compose.yaml` therefore sets `COOP_STEAM_BAN_FILE=Z:\data\steam-bans.json`,
which is `config/steam-bans.json` on the host. The variable is the one
that moves only the ban list; `COOP_DATA_DIR` would also move
`mod-config.json`.

## Mods: the engine without its launcher

`BannerlordCoopServer.exe` is a launcher. It sets up its data directory and
its console, then starts the game engine as a child process:

```
cwd  engine\bin\Win64_Shipping_Server
     engine\dotnet\dotnet.exe TaleWorlds.Starter.DotNetCore.dll
         _MODULES_*Native*SandBoxCore*Sandbox*Coop*DedicatedServer.Windows*_MODULES_
         /dedicatedcustomserver 7210 EU 0
env  DOTNET_ROOT=Z:\server\engine\dotnet  DOTNET_MULTILEVEL_LOOKUP=0
     BANNERLORD_USER_DIR=Z:\data
     COOP_DATA_DIR=C:\users\coop\Documents\Mount and Blade II Bannerlord\CoopData
```

That is what a running official server shows: its process list for the
command line, and the engine process's own memory for the environment,
which Wine keeps there rather than in `/proc/<pid>/environ`. The module
list is fixed in the launcher, and it has no option to extend it. Coop's
join check, meanwhile, requires every community module on both sides. So a
server with mods has the entrypoint start the engine exactly as above, with
the mods added to the list, and the launcher is not involved.

That was only acceptable because the parts that matter turned out to live
in the engine, in the `DedicatedServer.Windows` module, not in the
launcher. Measured with Coop v0.1.6:

| | Without the launcher |
|---|---|
| License terms | Checked by the engine: the EULA is printed and it exits 6 without an acceptance; with `DS_ACCEPT_EULA=true` it writes `eula.txt` itself |
| Coop checksum check | Done by the engine, "verified against release pins" |
| `server-config.json`, port, password | Read by the engine |
| `@DS@` events, `SERVING`, pulse lines | Printed by the engine |
| Console: `save`, `players`, `stop` | Read by the engine from stdin; `stop` ends in 2 seconds, exit 0, closing save |
| A log file per launch | The launcher's. The entrypoint writes it instead |

The rest is about making mods loadable on a machine with no screen, and is
described in [MODS.md](MODS.md): server copies of their manifests, a
startup hook that resolves interface libraries from the Coop module,
because the engine loads Coop after every mod, and a writable `Configs`
folder. The server runs from `runtime/`, a view of `server/` and `mods/`
made of hard links, which is rebuilt before every start and never while a
container has it mounted.

Without mods, none of this happens: the launcher starts the server as the
Coop team ships it.

## A new world only on request

The server hosts the save named by `SAVE_NAME`, and when there is none it
quietly creates a fresh world under that name. On a first start that is
right; after a typo it sends players into an empty world while the real
campaign sits unused on disk.

So a request for a new world is recorded (at installation, by
`coop campaign new`, or by `--new-world`), and `server_start()` refuses to
start into a save that does not exist without one. The check sits at the
start rather than in the commands that change `SAVE_NAME`, because a hand
edit of `server.env` or the interactive configuration changes it too.

Names are compared without regard to case, as Wine does when the server
opens the file. A check that told `campaign` from `Campaign` apart would
refuse a start the server would have served from the right save.

## Configuration is data

`config/server.env` is parsed line by line and never sourced. Keys are
whitelisted, values are validated by type, and nothing is executed.

The reason is not tidiness. The interactive installer and a provisioning
backend write the same file through the same code, and the backend writes
values it did not author. `SAVE_NAME=$(rm -rf /)` has to be a campaign with
an unfortunate name, not a command.

`server-config.json` is **generated** from a template rather than edited in
place. It is JSONC, with comments and trailing commas, so `jq` cannot read
it, and patching it with a regular expression is how a campaign gets
lost. Substitution is literal, because `awk`'s `gsub()` treats `&` in a
replacement as a backreference and a password containing `&` would
otherwise be mangled.

## One engine, two front ends

```
collect  ->  validate  ->  summarise  ->  provision
```

The collectors (default mode, advanced mode, command-line flags, a config
file) do nothing but gather values. `provision_run()` does nothing but
apply them, and never asks a question.

```
human      -> coop install                       -> provision_run()
automation -> coop install --non-interactive ... -> provision_run()
```

Below the collection layer there is no `read`, no confirmation and no
colour. That single rule is what stops the interactive installer and a
future hosting backend from becoming two implementations that drift apart.

The Steam session is a directory, which is the other half of the same idea:
a prepared `state/steam` lets provisioning run without a terminal, because
no code path asks for a password when a session is present.

## Instances

Container name, Compose project, lock file and systemd units are all
derived from `INSTANCE_ID` and the installation path. Nothing is hardcoded
to one server, so a host can run several. That costs nothing to allow for
now and would be expensive to retrofit.

The systemd units are templates instantiated with the escaped installation
path, so `%f` gives the directory back and no separate registry of
instances is needed.

## Locking

One lock per installation, not one per operation. Start, stop, update,
backup and restore all touch the same files, and an hourly backup timer
must never be able to fire in the middle of an update. A second operation
exits 70 rather than waiting.

## Measured behaviour

| | |
|---|---|
| Memory | 0.9 to 1.6 GB: about 890 MB on a fresh world, 1.2 to 1.6 GB on a grown campaign |
| CPU | about 1.2 cores, with or without players (120 to 122% on Ubuntu 26.04, 121% on Debian 13) |
| Bandwidth | about 58 KB/s per player |
| Campaign load time | about 50 seconds for a fresh world, about 2 minutes for a grown save |
| Workshop item | about 6.1 GB |
| Backup archive | 12-25 MB, depending on how grown the campaign is |
| Clean shutdown | 2 seconds |

With no players connected the campaign pauses on its own, so the server can
be left running around the clock. An hourly backup of an idle server is
skipped, but the test for "idle" has to be the campaign date rather than
the save file: the server autosaves every few minutes regardless, so the
file changes even while the world stands still.

**The process does not idle down, though.** Measured over five samples on a
four-core machine with nobody connected and the campaign paused: 120-122%
CPU, steady. That is the server's own loop, not the campaign, and it is why
the requirements ask for two cores rather than one. A single-core host is
saturated before the first player joins.

## Harmless log messages

- `Cannot load: GameInterface.dll` and similar right at startup. The server
  looks in the default location first; `coop assembly resolver installed`
  follows immediately.
- `Could not find the event index for: event:/...` is a sound definition,
  meaningless on a headless server.
- `The 'coop_*' attribute is not declared` refers to the mod's own XML
  attributes, which are not in the TaleWorlds schema.
- `[Coop] ["ObjectManager"] Failed to get id ...` is a mod-internal warning
  during normal play.

## Networking

| Port | Purpose |
|---|---|
| **UDP 4200** | Direct connect. The only port that must be reachable. Proximity voice chat (Coop v0.1.6) travels over it too. |
| UDP 27315/27316 | Steam game-server session, local only |

Port 7210, which appears in some guides, belongs to the standard TaleWorlds
multiplayer and is irrelevant here.

**Docker publishes ports past `ufw`.** Docker inserts its own chains ahead
of ufw's in `FORWARD`, so `ufw deny <port>` has no effect on a published
container port. Only a firewall in front of the machine, such as your
provider's, reliably closes one. If you ever need to restrict a container
port by source address, the `DOCKER-USER` chain is the right place.
