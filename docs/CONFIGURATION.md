# Configuration

Everything about one installation is described by a single file:

```
/srv/bannerlordcoop/config/server.env
```

It is plain `KEY="value"` lines with comments, and it is meant to be edited
by hand. Two other files in the same directory are **generated** from it -
`server-config.json` for the game server and `compose.env` for Docker
Compose. Edits to those two are overwritten.

## Changing a setting

```bash
coop config                      # walk through the common settings
coop config --advanced           # include the rest
coop config --list               # every setting, value and type
coop config --get GAME_PORT
coop config --set GAME_PORT=4210
coop config --apply              # regenerate and restart if needed
```

Or edit `server.env` directly and then run `coop config --apply`.

Every setting is also a command-line flag, derived from its name by
lowercasing and replacing underscores with hyphens:

```bash
coop --save-name "My Campaign" --game-port 4210 install --default
```

Three shorter aliases exist for convenience: `--password`, `--channel` and
`--backup-retention`.

## Where a value comes from

When the same setting is given in more than one place, the later one wins:

1. `config/defaults.env` in this repository, the project defaults
2. `$INSTALL_DIR/config/server.env`, your installation
3. `--config <file>`, a supplied file
4. Command-line flags, which win over everything above

Values from the command line are validated immediately, because you can fix
a typo on the spot. Values already on disk are reported by `coop doctor`
instead, which has to keep working precisely when something is wrong.

## The file is data, not code

`server.env` is parsed line by line. It is **never** sourced, so nothing in
it is executed:

```bash
SAVE_NAME=$(rm -rf /)      # stored as that literal text, never run
```

Keys are checked against a whitelist and values against their type. An
unknown key is reported and ignored rather than silently accepted, so an
installation written by a newer version of the manager stays readable by an
older one.

This matters beyond tidiness: it is what makes the file safe for a
provisioning system to write from data it did not author.

## Secrets

`server.env` contains `SERVER_PASSWORD` and is written with mode `0600`.
Backups include it, so **backup archives are secrets too**. They are
written `0600` as well.

Your Steam password is not in this file, or in any other. Only Steam's own
session lives under `state/steam`. See [STEAM.md](STEAM.md).

## Settings

<!-- BEGIN GENERATED SETTINGS -->
| Setting | Default | Type | Restart required | Description |
|---|---|---|---|---|
| `AUTOSAVE_MINUTES` | `5` | int | Yes | Minutes between automatic world saves. 0 disables autosaving. |
| `AUTO_UPDATE` | `false` | bool | No | Install Workshop updates automatically. Off by default: every player must run the same Coop build, so an unattended update would lock out anyone who has not updated. |
| `BACKUP_ENABLED` | `true` | bool | No | Run automatic backups on a schedule. |
| `BACKUP_KEEP_AUTO` | `48` | int | No | Number of automatic backups to keep. |
| `BACKUP_KEEP_MANUAL` | `20` | int | No | Number of manual backups to keep. |
| `BACKUP_KEEP_PRERESTORE` | `10` | int | No | Number of pre-restore safety backups to keep. |
| `BACKUP_KEEP_PREUPDATE` | `10` | int | No | Number of pre-update backups to keep. |
| `BACKUP_MAX_AGE_DAYS` | `30` | int | No | Delete automatic backups older than this many days. 0 disables the age limit. |
| `BACKUP_MAX_TOTAL_GB` | `20` | int | No | Total size cap for the backup directory. Oldest automatic backups are removed first. 0 disables the cap. |
| `BACKUP_SCHEDULE` | `hourly` | schedule | No | When automatic backups run, as a systemd OnCalendar expression. |
| `CUSTOM_SOURCE_PATH` | _(empty)_ | path | Install only | Directory holding the server files. Only used when INSTALL_CHANNEL=custom. |
| `DOTNET_SDK_IMAGE` | `mcr.microsoft.com/dotnet/sdk:10.0` | string | No | Container image used once to build the small startup hook a server with mods needs. Pin it to a digest for reproducible installs. |
| `GAME_PORT` | `4200` | port | Yes | UDP port players connect to. This is the only port that has to be reachable from the internet. |
| `INSTALL_CHANNEL` | `workshop` | one of: workshop, custom | Install only | Where the server files come from. 'workshop' downloads from the Steam Workshop; 'custom' installs from a local directory. |
| `INSTALL_DIR` | `/srv/bannerlordcoop` | path | Install only | Absolute path holding all persistent data for this installation. |
| `INSTANCE_ID` | `default` | identifier | Install only | Identifier for this installation. Shapes the container, lock and systemd unit names, so one host can run more than one server. |
| `LOGIN_MESSAGE` | `true` | bool | No | Show this server's state in the message at an SSH login: a Workshop update waiting, and the last backup. Ubuntu and Debian only; elsewhere it does nothing. |
| `LOG_MAX_FILES` | `5` | int | No | Number of rotated container log files to keep. |
| `LOG_MAX_SIZE` | `50m` | string | No | Maximum size of a single container log file before it rotates. |
| `MEMORY_LIMIT` | _(empty)_ | string | Yes | Memory limit for the container, e.g. 4g. Empty means no limit. Measured usage is 1.2-1.6 GB. |
| `MODS` | _(empty)_ | modlist | Yes | Steam Workshop items the server loads as mods, as their IDs in load order. Manage them with 'coop mods'. Empty runs the server exactly as the Coop team ships it. |
| `PGID` | `1000` | int | Yes | Group ID owning the data directories. |
| `PUID` | `1000` | int | Yes | User ID owning the data directories and running the server process. |
| `SAVE_NAME` | `Campaign` | savename | Yes | Campaign save to host. Change it with 'coop campaign use'. A name with no save behind it starts a fresh world, which only happens when one was asked for: at installation, with 'coop campaign new', or with --new-world. |
| `SERVER_LABEL` | `Bannerlord Coop Server` | string | No | Name used by the manager in status output and backup manifests. Not visible to joining players, because the game has no server name field. |
| `SERVER_LOG_FILE` | `true` | bool | Yes | Write the server's output to a file per launch in logs/, in addition to the container log. |
| `SERVER_PASSWORD` | _(empty)_ | string | Yes | Password players must enter to join. Empty means anyone who knows the address can join. |
| `STEAMCMD_IMAGE` | `steamcmd/steamcmd:ubuntu` | string | No | Container image used to run SteamCMD. Pin it to a digest for reproducible installs. |
| `STEAM_ADVERTISE` | `false` | bool | Yes | Advertise the server in a public Steam lobby when a logged-in Steam client runs on the host. Off means direct connect only. |
| `STEAM_USERNAME` | _(empty)_ | string | No | Steam account used to download the Workshop item. The password is never stored, only Steam's own session under state/steam. |
| `TIMEZONE` | `system` | string | Yes | Time zone inside the container. 'system' adopts the host's zone. |
| `UPDATE_CHECK_ENABLED` | `true` | bool | No | Check for new Workshop versions on a schedule and report them. |
| `UPDATE_CHECK_SCHEDULE` | `*-*-* 04:00:00` | schedule | No | When the update check runs, as a systemd OnCalendar expression. |
| `WINE_BRANCH` | `stable` | one of: stable, staging, devel | Yes | WineHQ branch built into the runtime image. |
| `WORKSHOP_APP_ID` | `261550` | int | Install only | Steam application ID of Mount & Blade II: Bannerlord. |
| `WORKSHOP_ITEM_ID` | `3770450698` | int | Install only | Steam Workshop item ID of the Bannerlord Coop dedicated server. |
<!-- END GENERATED SETTINGS -->

The table above is generated from the specification in `lib/config.sh` and
the defaults in `config/defaults.env`, and CI fails if it falls out of
step. Regenerate it with `tools/gen-config-docs.sh --write`.

## Notes on individual settings

### `SAVE_NAME`

The campaign to host. If a save of that name exists in `saves/`, it is
loaded. If not, the server would create a fresh world under that name, and
the manager only lets that happen when a new world was asked for: at
installation, with `coop campaign new`, or with `--new-world`.

```bash
sudo coop campaign use "My Campaign"         # switch, with a backup first
sudo coop config --set SAVE_NAME="My Campaign"
sudo coop config --set SAVE_NAME="Fresh Start" --new-world
```

The second form refuses a name with no campaign behind it; the third says
that a new world is intended. A name differing only in case finds the
campaign it matches. Changing `SAVE_NAME` points the server at a different
campaign; it never renames or removes one.

Names may contain spaces, up to 64 characters. They become file names for
a Windows program, so `/ \ : * ? " < > |` are refused, as are names the
server uses for itself (`default_new_game`, `coop_bug_report`,
`TransferSave`, anything ending in `.backup1` or `.backup2`).

### `MODS`

Steam Workshop IDs, one space apart, in load order:

```bash
MODS="2859188632 2859232415 2859222409 2859238197 2859265386 3777470096 3627538517 3786391685"
```

Empty, the default, runs the server exactly as the Coop team ships it.
`coop mods add` and `coop mods remove` keep it, and the better way to
change it is through them, because they also download, back up and
restart. A hand edit works too: the next start downloads whatever is named
and missing, and refuses to start with a mod that needs something nobody
provides. Frameworks such as Harmony are sorted ahead of the game's own
modules whatever their position here; otherwise the order given is the
order the server loads them in, except where a mod needs another loaded
first. [MODS.md](MODS.md) has the rest.

### `DOTNET_SDK_IMAGE`

Only matters with mods. A server with mods needs a small startup hook,
which is built from `docker/hook` on the server itself the first time, and
again whenever its source changes. This is the image it is built with,
Microsoft's .NET SDK. It is downloaded for the build and removed again
unless it was already there. Pin it to a digest if your builds have to be
reproducible.

### `LOGIN_MESSAGE`

A few lines about the server in the message shown at an SSH login, next to
the pending package updates:

```
 * Bannerlord Coop: a Workshop update is available  ->  coop update
   Last backup: auto-20261013-020252.tar.gz (2026-10-13 02:02)
   Overview: coop status
```

It is a script in `/etc/update-motd.d`, one per installation, that reads
files only, so a login stays fast. It therefore cannot say whether the
server is running; `coop status` can. Ubuntu and Debian run these scripts;
other distributions have no such directory, and the setting does nothing
there. `coop config --apply` writes or removes it.

### `SERVER_LABEL`

A name for your own benefit: it appears in `coop status` and in backup
manifests. **Players never see it.** The dedicated server has no server-name
field, and co-op players join by direct connect rather than through a server
list.

### `STEAM_ADVERTISE`

Off by default. With a logged-in Steam client running on the same machine,
turning it on would publish a **public** lobby. Without a Steam client the
server logs that Steam is unavailable and serves direct connections as
usual, so the setting does nothing either way on a typical headless host.

### `AUTO_UPDATE`

Off by default, and worth leaving that way for most groups. The server
verifies its Coop assemblies and clients must run the same build, so an
update installed overnight locks out every player who has not updated their
own client yet. The scheduled check still runs and reports.

### `MEMORY_LIMIT`

Empty means no limit. Measured usage is 1.2-1.6 GB. On a small host a limit
is worth setting anyway, not because the server needs it, but so that a
runaway process cannot take the whole machine, and your SSH session, down
with it.

### `PUID` / `PGID`

Written by the installer from the service user it creates. They exist
because the numeric owner of the files on the host and inside the container
has to match. You should not normally change them; if you do, re-run
`coop config --apply` and check that `saves/` is still owned correctly.

### `BACKUP_SCHEDULE` and `UPDATE_CHECK_SCHEDULE`

systemd `OnCalendar` expressions. `hourly`, `daily`, `Mon *-*-* 03:00:00`
and similar all work. `man systemd.time` has the full syntax. The manager
writes them into a systemd drop-in, so an upgrade of the unit files does not
discard your choice.

### Retention

Four counts, one per reason, plus an age limit and a total size cap:

- Automatic backups are a rolling window. The count, the age limit and the
  size cap all apply to them.
- Manual and pre-restore backups exist because somebody decided to make
  them. They are only ever removed by their own count limit, never by the
  age or size limits.

That asymmetry is deliberate: an aggressive size cap should not be able to
delete the safety backup you took before a restore.
