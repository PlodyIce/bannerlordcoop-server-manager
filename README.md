# Bannerlord Coop Server

Install and run a **Mount & Blade II: Bannerlord** co-op dedicated server on
your own Linux machine, and manage it afterwards with a single command.

```
sudo ./install.sh
coop status
```

> **Unofficial.** This is a third-party installer and manager. It is not made
> by, endorsed by, or affiliated with TaleWorlds Entertainment or the
> Bannerlord Coop team. The server software it installs comes from the
> [Bannerlord Coop Steam Workshop item](https://steamcommunity.com/sharedfiles/filedetails/?id=3770450698);
> all credit for the mod belongs to its authors.

---

## What it does

- **Guided install.** A read-only compatibility check first, a report, and
  nothing touched until you agree. Then three questions and a Steam login.
- **Runs the server in Docker.** The dedicated server is a Windows binary;
  it runs under Wine inside a container so nothing lands on your host.
- **Shuts down properly.** Stopping sends `stop` to the server console and
  waits for the closing save, rather than killing the process mid-write.
- **Backs up on a schedule.** Saves, server settings and gameplay settings
  as one archive. The run is skipped when the campaign has not advanced and
  nobody is connected.
- **Updates with a way back.** Pre-update backup, a kept copy of the
  previous build, and an automatic rollback if the new one will not start.
- **Restores as a transaction.** A restore is validated, staged, and swapped
  in. It is never unpacked over your campaign and left half-finished.
- **Switches campaigns safely.** `coop campaign use` backs up, switches and
  waits until the server serves. A mistyped name is refused instead of
  quietly becoming a new, empty world.
- **Leaves the license decision to you.** From Coop v0.1.6 the server comes
  with license terms of its own. They are shown and put to you, never
  accepted on your behalf, and asked again when they change.
- **Keeps bans where they survive.** `coop ban` maintains the server's Steam
  ban list in a place that updates leave alone and backups include.
- **Runs Workshop mods.** `coop mods add` downloads them, works out what
  they need, and restarts with a backup first. `coop mods` prints exactly
  what players have to enable.
- **Scriptable.** Every command that reports something supports `--json`,
  exit codes distinguish failure classes, and `--non-interactive` never
  hides a prompt.

## Requirements

| | |
|---|---|
| Architecture | **x86_64 only.** The server is a Windows x64 binary run under Wine; arm64 would need an emulation layer this installer will not set up. |
| Operating system | A Linux distribution with a current Docker Engine and systemd (see below) |
| CPU | **2 cores minimum, 4 recommended.** The server uses about 1.2 cores even with nobody connected, because it does not idle down. |
| Memory | 4 GB minimum, 8 GB recommended (the server uses 0.9-1.6 GB) |
| Disk | 25 GB minimum, 40 GB recommended. The game files occupy about 18 GB across three directories, plus backups. |
| Network | UDP 4200 reachable from the internet |
| Steam | An account that **owns Mount & Blade II: Bannerlord**. The Workshop download is not available anonymously. |
| License | The Coop server's own terms (`EULA.md`, `LICENSE.txt`), which you accept during installation. Commercial hosting needs the Bannerlord Coop team's written permission. |

Docker Engine, the Compose plugin and a handful of standard tools are
installed for you if they are missing.

### Supported Linux versions

| Distribution | Status |
|---|---|
| Ubuntu 26.04 LTS | Supported, tested |
| Debian 13 | Supported, tested |
| Ubuntu 22.04 / 24.04 LTS | Supported |
| Debian 12 | Supported |
| Rocky, AlmaLinux, RHEL 9+ | Experimental |
| Fedora | Experimental |
| Anything older than the above | Unsupported |

Two of those have actually been installed on; the rest share their package
sources. [INSTALLATION.md](docs/INSTALLATION.md) says which is which.

The host distribution matters less than it might seem: Wine, the .NET
runtime and the game all live inside the container. What the host has to
provide is x86_64, Docker and systemd. `coop install` checks your system
and tells you where you stand before changing anything.

## Getting a server

### Rented from the Bannerlord Coop team

If you would rather not look after a Linux machine at all, the Bannerlord
Coop team rents managed servers to supporters on its **$20+ Patreon
tiers**. Connect your Patreon account to your
[bannerlordcoop.com](https://bannerlordcoop.com/) account, wait a few
minutes, then look at
[bannerlordcoop.com/servers](https://bannerlordcoop.com/servers).

### Your own Linux server

<a href="https://www.netcup.com/en">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/netcup-logo-white.svg">
    <img src="docs/images/netcup-logo.svg" alt="netcup" width="150">
  </picture>
</a>

> **Advertisement.** This project was tested on a server rented from
> [netcup](https://www.netcup.com/en). New customers get **5 € off** with
> the voucher code **`36nc17889838270`** (not valid for domains).

| | [RS 1000 G12.5](https://www.netcup.com/en/server/root-server) | [VPS 1000 G12.5](https://www.netcup.com/en/server/vps) |
|---|---|---|
| CPU | 4 dedicated cores, AMD EPYC 9645 | 4 vCores (x86), shared |
| Memory | 8 GB | 8 GB |
| Disk | 128 GB NVMe | 128 GB SSD |
| Price, October 2026 | 25.00 € a month | 16.68 € a month |

Prices include 19 % German VAT, and both have a one-month term.

The RS 1000 is the one used for testing. Its cores are dedicated, which
suits a server that uses about 1.2 cores around the clock, even with
nobody connected. The VPS 1000 shares its cores with other customers and
should work well too.

**Choose an x86 server.** netcup also rents ARM servers, and the Coop
server cannot run on those.

## Quick start

```bash
git clone https://github.com/PlodyIce/bannerlordcoop-server-manager
cd bannerlordcoop-server-manager
sudo ./install.sh
```

The installer walks through eight steps, asks for a campaign name, a server
password and your Steam login, downloads about 6 GB, and puts the Coop
server's license terms to you before the first start. When it finishes:

```bash
coop status
```

The installer ends by printing the address to connect to:

```
Installation complete.

  Connect to         203.0.113.17:4200
  Password           set
  Campaign           My Campaign
  Next               coop status

  Players join through Direct Connect in the co-op menu.
```

`coop status` shows the same address at any time.

### Default setup

The recommended path. Two questions and a Steam login; everything else
comes from `config/defaults.env`: the game's own value wherever the server
has one, and conservative choices for backups and updates.

Gameplay settings are not among them. Difficulty, battle size and the rest
live in `mod-config.json`, which the Coop mod creates with its own defaults
the first time the server starts. This installer neither ships nor
overwrites that file; it only carries your changes across an update.

```
[3/8] Campaign

  Campaign name: My Campaign
  Server password (empty for none): ********
```

The campaign name is the one answer that changes the outcome: if a save of
that name exists it is loaded, otherwise a new world is created under it.

> There is no "server name" and no "maximum players" setting, because the
> dedicated server does not have either. `server-config.json` has nine
> fields and neither is among them. `SERVER_LABEL` names the server in
> `coop status` and in backups, but players never see it.

### Advanced setup

```bash
sudo ./install.sh --advanced
```

Adds the installation directory, instance id, ports, install channel,
autosave interval, time zone, memory limit, backup schedule and retention,
and the update policy.

### Unattended install

Both modes feed the same engine, so automation uses the same code path a
person does:

```bash
sudo coop install --default --non-interactive --yes --accept-eula \
     --save-name "Customer Campaign" \
     --server-password "s3cret" \
     --game-port 4210
```

`--accept-eula` accepts the Coop server's license terms, which nobody can
be asked about in an unattended run, so read them first. `--yes` never
accepts a license.

Steam Guard cannot be answered without a terminal, so authenticate once
first. After that the session is reused and nothing prompts:

```bash
sudo coop steam login
```

## Steam authentication

Downloading the Workshop item requires a Steam account that owns Bannerlord.
The password is **never handled by this installer**: the terminal is handed
to SteamCMD, which asks for the password and the Steam Guard code itself.
What persists afterwards is Steam's own session under `state/steam`.

```bash
coop steam status     # is the session still good?
coop steam login      # authenticate (once)
coop steam logout     # discard the session
```

More in [docs/STEAM.md](docs/STEAM.md).

## Commands

| Command | Description |
|---|---|
| `coop install` | Install a server on this host |
| `coop status` | Show what the server is doing |
| `coop start` / `stop` / `restart` | Start or stop, with a closing save |
| `coop save` | Force a save and wait for it |
| `coop console <command>` | Send a command to the server console |
| `coop logs [--follow]` | Show the server log |
| `coop campaign list` | The campaigns on this server, and which one is hosted |
| `coop campaign use <name>` | Host another campaign, with a backup first |
| `coop campaign new <name>` | Start a new world, leaving the others alone |
| `coop mods` | The installed mods, and what players need |
| `coop mods add <id>...` | Install Steam Workshop mods |
| `coop mods remove <id>...` | Remove mods |
| `coop mods update [--check]` | Install, or check for, newer versions of the mods |
| `coop ban [<steam64-id>]` | List bans, or ban a Steam account |
| `coop unban <steam64-id>` | Lift a ban |
| `coop config` | Edit common settings |
| `coop config --list` | Show every setting and its value |
| `coop config --set KEY=VALUE` | Change one setting |
| `coop update [--check]` | Install, or check for, a newer Coop build |
| `coop rollback` | Go back to the previous Coop build |
| `coop backup [--note "..."]` | Create a backup now |
| `coop backup list` | List backups |
| `coop backup info <id>` | Show what is in one |
| `coop backup restore [<id>]` | Restore saves and configuration |
| `coop import-save <dir>` | Import campaign saves from a directory |
| `coop steam status\|login\|logout` | Manage the Steam session |
| `coop eula [show\|accept]` | The Coop server's license terms |
| `coop doctor` | Check the installation and say what is wrong |
| `coop version` | Manager and Coop versions, reported separately |

Full reference: [docs/CLI.md](docs/CLI.md).

## Configuration

Everything lives in one file, and it is meant to be edited by hand:

```
/srv/bannerlordcoop/config/server.env
```

```bash
coop config --list             # every setting, value and type
coop config --set GAME_PORT=4210
coop config --apply            # regenerate and restart if needed
```

Any setting is also a command-line flag, derived from its name:
`--save-name`, `--game-port`, `--backup-keep-auto`.

The file is **parsed, never executed**. A value is a value, even if it looks
like a shell command. That is what makes it safe for a provisioning system
to write.

Every setting, its default and whether it needs a restart:
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Important files and directories

Everything below sits under the installation directory, `/srv/bannerlordcoop`
by default.

| Path | Purpose | In a backup? |
|---|---|---|
| `config/server.env` | Your settings. **Contains the server password.** | Yes |
| `config/server-config.json` | Generated for the server. Do not edit. | Yes |
| `config/steam-bans.json` | Banned Steam accounts. Edit with `coop ban`. | Yes |
| `config/eula.txt` | Written by the server when its license terms are accepted | Yes |
| `config/compose.env` | Generated for Docker Compose. Do not edit. | No |
| `saves/` | Campaign saves (`.sav` with a matching `.json`) | Yes |
| `coopdata/mod-config.json` | Gameplay settings, owned by the mod | Yes |
| `userconfigs/` | What mods keep for themselves | Yes |
| `mods/` | Installed Workshop mods | No |
| `runtime/` | The server and its mods, linked together for the server to run from | No |
| `backups/` | Backup archives and their manifests | — |
| `logs/` | Server logs and the manager's own log; the engine's own logs and crash reports in `logs/engine/` | No |
| `state/` | Installation metadata, Steam session | No |
| `server/` | The active server files, mounted read-only | No |
| `workshop/` | Raw Steam Workshop download | No |
| `rollback/` | The previous build, kept for `coop rollback` | No |

The split between `workshop/`, `server/` and `rollback/` is deliberate: a
download can never quietly change the running installation, and a rollback
is a directory swap instead of a 6 GB download.

## Updates

```bash
coop update --check     # is there a new build?
coop update             # install it
coop rollback           # go back
```

An update downloads while the server keeps running, settles any new
license terms, then stops the server cleanly, backs up, keeps a copy of the
current build, installs, brings the gameplay settings up to the new build,
starts, and **rolls back by itself if the new build will not serve**.

A scheduled check runs nightly and only reports, in `coop status` and in
the message you see when you log in over SSH. Automatic installation is
off by default on purpose: the server verifies its Coop assemblies and every
player has to run the same build, so an unattended update would lock out
anyone who has not updated their client. Turn it on with
`coop config --set AUTO_UPDATE=true` if that trade suits your group.

Details: [docs/UPDATES.md](docs/UPDATES.md).

## Campaigns

The server hosts one campaign at a time, and switching is one command:

```bash
coop campaign list
sudo coop campaign use "Second Campaign"
sudo coop campaign new "Fresh Start"
```

Both stop the server with a closing save, back up, switch and wait until
the server serves again, and both put the previous campaign back if the
new one will not serve. A name with no campaign behind it is refused, by
these commands and by every other way of starting the server: the server
would otherwise quietly create an empty world under the mistyped name.

## Mods

```bash
sudo coop mods add 3786391685 2859265386 3777470096 3627538517
coop mods
```

Steam Workshop mods are installed by their ID or the link to their page.
The frameworks they need come along by themselves, the server restarts
with a backup first, and if it will not serve with them, the previous set
is put back. `coop mods` prints what players have to enable, in which
order, with links.

The Coop team does not support mods; which ones work is collected by its
community. The official launcher cannot load mods, so with mods the server
is started without it, with the license check still in force.
[MODS.md](docs/MODS.md) explains how, which mods have been tested, and what
does not work.

## Banning players

```bash
sudo coop ban 76561198000000042 --name "Troublemaker"
coop ban
sudo coop unban 76561198000000042
```

Bans take effect at the next join attempt, without a restart. The id is
the number in the player's Steam profile address.

## Backups

Automatic, hourly, and skipped when the campaign has not advanced and
nobody is connected, because the world only moves while players are on it.

```bash
coop backup --note "before the siege"
coop backup list
coop backup restore 20260911-004626
```

Each archive holds the campaign, the server configuration and the gameplay
configuration together, because only all three make a playable state.

**Copy backups off this machine.** A backup that only exists on the server
you are protecting is not a backup:

```bash
scp your-server:/srv/bannerlordcoop/backups/auto-*.tar.gz ~/backups/
```

Details: [docs/BACKUPS.md](docs/BACKUPS.md).

## Firewall

Only **UDP 4200** has to be reachable. Two things catch people out:

- **Docker publishes ports past `ufw`.** A `ufw deny` rule does not close a
  published container port. Do not rely on it.
- **Your provider probably has its own firewall** in front of the machine.
  That one does work, and it is where to allow UDP 4200.

## Troubleshooting

Start here:

```bash
coop doctor
```

It checks the system, Docker, the configuration, the data directories, the
Steam session, the server process and the backups, and each failing line
says what to do. [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) covers
the specific symptoms.

## Documentation

| | |
|---|---|
| [INSTALLATION.md](docs/INSTALLATION.md) | Requirements, preflight, both setup modes, first start |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every setting, default and restart requirement |
| [CLI.md](docs/CLI.md) | Every command, flag and exit code |
| [STEAM.md](docs/STEAM.md) | Why an account is needed, Steam Guard, sessions |
| [UPDATES.md](docs/UPDATES.md) | Update flow, rollback, why updates are manual |
| [BACKUPS.md](docs/BACKUPS.md) | Contents, types, retention, restore |
| [MODS.md](docs/MODS.md) | Workshop mods: installing, what players need, how it works |
| [SAVE-MIGRATION.md](docs/SAVE-MIGRATION.md) | Bringing a campaign from Windows or another host |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom, cause, check, solution |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works, and why it works that way |
| [DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md) | Rebuilding from nothing |

## Versioning

The manager has its own version, separate from the Coop mod:

```
$ coop version
Bannerlord Coop Server Manager v0.3.0
Installed Coop build:       build 2026-10-06 / Mount & Blade II: Bannerlord v1.4.8
```

## Status

**v0.3.0.** Installed and exercised end to end on Ubuntu 26.04 and
Debian 13:

- install from nothing: dependency and Docker setup, Workshop download,
  world creation, first start
- the update from Coop v0.1.5 to v0.1.6, a genuinely newer build: its new
  license terms declined and accepted, the gameplay settings merge, and an
  automatic rollback when the server would not start
- rollback, and installing the same update again afterwards
- clean shutdown through the server console, with the closing save
- backup, listing, and restore of a deliberately destroyed campaign, with
  its pre-restore safety copy
- switching between two campaigns and back, each time with a backup
- save import, scheduled backups, and the diagnostics
- Workshop mods, with the CoopModPatch set of eight items: added, listed,
  removed and added again; a real update, and a deliberately broken one
  that put the previous version back by itself; a player joined and
  played with them
- a new server with mods in one command, `coop install --mods`
- a backup with mods restored on another machine that had none: the mods
  downloaded, the host's own user IDs kept

The ban list is written where the server reads it and survives updates.
A refused join has not been observed yet, because that needs a second
Steam account and a client.

## Licence

The manager is MIT licensed. See [LICENSE](LICENSE).

The Bannerlord Coop dedicated server it installs is not. It is proprietary
software of Bannerlord Coop LLC, under the EULA and license that come with
every build. The manager does not include or redistribute it: it downloads
the official build from the Steam Workshop onto your own machine, and asks
you to accept its terms. Running a paid or commercial service with it
needs written permission from the Bannerlord Coop team
(admin@bannerlordcoop.com).
