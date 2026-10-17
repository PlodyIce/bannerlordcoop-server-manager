# Installation

## Requirements

| | |
|---|---|
| Architecture | **x86_64 only** |
| Operating system | Linux with a current Docker Engine and systemd |
| CPU | 2 cores minimum, 4 recommended. The server uses about 1.2 cores when idle |
| Memory | 4 GB minimum, 8 GB recommended. The check reads what the kernel reports, which is noticeably less than the amount fitted |
| Disk | 25 GB minimum, 40 GB recommended |
| Privileges | root |
| Network | Outbound to Steam, Docker and WineHQ; inbound UDP 4200 |
| Steam | An account that owns Mount & Blade II: Bannerlord |

Docker Engine, the Compose plugin, and `curl git jq rsync tar flock` are
installed for you if they are missing.

### Why x86_64 only

The dedicated server is a Windows x64 binary run under Wine. On arm64 that
would additionally need box64 or FEX. This installer will not set up an
emulation layer, so the architecture check refuses rather than
half-working. Many inexpensive VPS offers are arm64, so check before you buy.

### Supported systems

| Distribution | Status | Tested |
|---|---|---|
| Ubuntu 26.04 LTS | Supported | **yes**: full install, update to a newer Coop build, rollback, backup, restore, campaign switching |
| Debian 13 | Supported | **yes**: full install, update to a newer Coop build, rollback, campaign switching, on a German-locale host |
| Ubuntu 22.04 / 24.04 LTS | Supported | no, same package sources as 26.04 |
| Debian 12 | Supported | no, same package sources as 13 |
| Ubuntu 20.04+, other releases | Experimental | no |
| Debian 11 | Experimental | no, nearing end of life |
| Rocky / AlmaLinux / RHEL 9+ | Experimental | no, the `dnf` path has never run |
| Fedora | Experimental | no, moves faster than this is tested against |
| Anything older | Unsupported | no current Docker Engine |
| Any distribution, arm64 | Unsupported | see above |

"Supported" without "tested" means the compatibility matrix accepts it and
the package sources are the same as a release that was tested. It does not
mean somebody has run it. The two rows marked **yes** are the ones with
evidence behind them.

The host distribution matters less than it might seem: Wine, the .NET
runtime and the game live inside the container. What the host provides is
x86_64, Docker and systemd, so the matrix tracks Docker CE support.

Without systemd the server still runs; only the scheduled backup and
update check are skipped, and the installer says so.

## Preflight

`coop install` begins with a **read-only** check. Nothing on your system is
changed until you have seen the result and agreed.

It checks the distribution and version, architecture, kernel, root
privileges, the package manager, whether the required packages are
**actually available** from your repositories, Docker and Compose, memory,
free disk space at the installation path, whether UDP 4200 is free, and
reachability of Steam, Docker and WineHQ.

```
System compatibility

  + Operating system   Debian GNU/Linux 13 (trixie)
  + Architecture       x86_64
    Kernel             6.12.107+deb13-amd64
  + Privileges         running as root
  + Package manager    apt
  > Required tools     will be installed: jq rsync
  > Docker Engine      not installed, will be installed from Docker's own repository
  > Docker Compose     compose plugin missing, will be installed
  + Memory             7946 MB
  + Disk space         67 GB free at /srv/bannerlordcoop
  + CPU cores          4
  + Game port          UDP 4200 is free
  + Internet access    Steam, Docker and WineHQ reachable
```

A `>` marks something the installer is about to do on purpose. Only `!`
and `x` are warnings and failures.

Checking real package availability matters on older systems: a release can
still be installable while no longer carrying the packages it needs. On
Debian and Ubuntu this uses `apt-cache policy` rather than inferring from
the version number.

If the system is unsupported, the installer stops with exit 20 and the
message ends with a sentence that is actually true: no changes have been
made to your system.

## Installing

```bash
git clone https://github.com/PlodyIce/bannerlordcoop-server-manager
cd bannerlordcoop-server-manager
sudo ./install.sh
```

`install.sh` only checks that it is running on Linux as root with a modern
bash, then hands over to `coop install`. Everything it could do, the CLI
can do too, so there is one implementation rather than two.

### The eight steps

| Step | What happens |
|---|---|
| 1 | Compatibility check (read-only) |
| 2 | Setup mode: default or advanced |
| 3 | Configuration questions |
| 4 | Summary, and the point of no return |
| 5 | Dependencies: Docker, tools, service user |
| 6 | Steam authentication |
| 7 | Directories, configuration, image build, download |
| 8 | The Coop server's license terms, first start and validation |

The confirmation at step 4 comes before Steam rather than after it, which
is a deliberate departure from the obvious order. Authenticating with
Steam needs SteamCMD, SteamCMD runs in a container, and installing Docker
changes your host. Putting the summary first is what makes "nothing has
been changed yet" true when it is printed.

## Default setup

Two questions and a Steam login:

```
[3/8] Server configuration

Campaign

  The campaign name decides what the server hosts. If a save of this
  name already exists it is loaded; otherwise a new world is created.

Campaign name [Campaign]: My Campaign
Server password (empty for none): ********
```

The game port is only asked about if UDP 4200 is already taken, in which
case the next free port is offered.

Everything else comes from `config/defaults.env`, documented setting by
setting in [CONFIGURATION.md](CONFIGURATION.md).

Gameplay settings are not part of that. Difficulty, battle size and the
rest belong to `mod-config.json`, which the Coop mod writes with its own
defaults on first start.

> **There is no "server name" and no "maximum players" question**, because
> the dedicated server has neither setting. `server-config.json` has nine
> fields and neither is among them. `SERVER_LABEL` names the installation
> in `coop status` and in backups, but players never see it; they join by
> direct connect, not through a server list.

## Advanced setup

```bash
sudo ./install.sh --advanced
```

Adds: instance id, installation directory, display name, install channel,
game port, autosave interval, public Steam lobby, time zone, memory limit,
backup enable/schedule/retention/age/size, update check enable/schedule,
and automatic updates.

Both modes feed the same engine. Advanced asks more questions; it does not
take a different code path.

## License terms

From Coop v0.1.6 on, the dedicated server comes with license terms of its
own, `EULA.md` and `LICENSE.txt`, and will not host a campaign until they
have been accepted. They arrive with the server files, so step 8 is the
first point at which there is anything to read:

```
License terms

  This Coop server build comes with license terms of its own. The
  server will not host a campaign until they have been accepted:

    /srv/bannerlordcoop/server/EULA.md
    /srv/bannerlordcoop/server/LICENSE.txt

Read them now? [Y/n]
Do you accept these license terms? [y/N]
```

The terms open in a pager. Space scrolls, and `q` returns to the question,
as does Space once you have reached the end. The bottom line says so the
whole time.

They are the Bannerlord Coop team's terms, not this installer's, and the
installer never accepts them for you. Among other things they govern
commercial hosting, which needs the team's written permission. If you
decline, the installation is complete but the server is not started; run
`coop eula accept` and `coop start` when you have decided.

## Steam authentication

See [STEAM.md](STEAM.md) for the detail. In short: the Workshop download
needs an account that owns Bannerlord, SteamCMD asks for the password and
Steam Guard code directly, and what is stored afterwards is Steam's own
session.

## Unattended installation

```bash
sudo coop steam login
```

```bash
sudo coop install --default --non-interactive --yes --accept-eula --save-name "Customer Campaign" --server-password "s3cret" --game-port 4210 --backup-keep-auto 24
```

Steam Guard cannot be answered without a terminal, so authenticate once
first. After that nothing prompts.

`--accept-eula` accepts the Coop server's license terms, which nobody can
be asked about in an unattended run. Read them before you pass it:
`EULA.md` and `LICENSE.txt` in the server files, or `coop eula show` on any
installation of the same build. Without the flag the installation
completes, the server is not started, and the command exits 80. `--yes`
does not accept a license.

`--yes` is required, not decorative. Installing a server onto a host is a
consequential act, and `--non-interactive` promises never to answer a
confirmation on your behalf. Leaving it out gets you exit 10 and the
summary, which is also a convenient way to preview what a provisioning
run would do.

A missing required value is exit 10, naming the flag. A destructive step
without `--yes` is exit 10 as well. There are no hidden confirmations.

Settings can also come from a file:

```bash
sudo coop install --non-interactive --yes --config /root/instance.env
```

Mods can be part of the installation: `--mods` takes Steam Workshop IDs,
and the frameworks they need are added by themselves. They are downloaded
and checked before the server first starts, so a problem with one stops
the installation rather than the server.

```bash
sudo coop install --default --non-interactive --yes --accept-eula --save-name "Modded" --mods "3786391685 2859265386 3777470096 3627538517"
```

[MODS.md](MODS.md) says which mods have been tested, and what players
need.

## Ports and firewall

Only **UDP 4200** has to be reachable from the internet. The Steam
game-server ports are used locally only.

Two things catch people out:

- **Docker publishes ports past `ufw`.** Docker inserts its own chains
  ahead of ufw's, so a `ufw deny` rule does not close a published container
  port. Do not rely on it as your outer defence.
- **Your provider probably has a firewall** in front of the machine. That
  one does work, and it is where to allow UDP 4200 and nothing else except
  SSH.

The installer detects port conflicts but does not change any firewall.
Deciding what is reachable from the internet is not something an
application installer should do behind your back.

## First start

The first start creates a new world if no save of the configured name
exists. Installation is the one moment where that happens without being
asked for separately; afterwards a name with no save behind it is refused,
so a typo cannot quietly start an empty world. See `coop campaign` in
[CLI.md](CLI.md). Loading takes about two minutes on a grown campaign; the installer
waits for the server to report that it is actually serving clients, not
just that the container is up.

## Validating

```
[8/8] Starting the server
Starting the server
  + Server is serving ('My Campaign')

Validation

  + Container running
  + Server process serving clients
  + Configuration generated
  + UDP 4200 bound
  + Backup schedule active
```

Then:

```bash
coop status
coop doctor
```

Players connect with **Direct Connect** to `<your-server-ip>:4200`.

## Installing again

Running `coop install` on an existing installation never overwrites
anything silently. The question comes **before** the compatibility check,
because "can this machine run a server" is the wrong first thing to ask a
machine that is already running one:

```
An existing installation was found

  Directory          /srv/bannerlordcoop
  Campaign           ImportedRun
  Installed          2026-09-12T01:36:51Z
  Build              build 2026-09-06 / Mount & Blade II: Bannerlord v1.4.8

  [1] Update       install a newer Coop build
  [2] Repair       rebuild the image and rewrite generated files,
                   leaving saves and settings alone
  [3] Reconfigure  change settings, then apply them
  [4] Exit         change nothing
```

Reconfigure walks through the advanced questions with your current values
as the defaults, then applies them and restarts, because settings such as
the port or the password only take effect on a restart. It does not
re-download the server; `coop update` is the command for changing the
build. An empty answer at the password prompt keeps the existing password
rather than clearing it.

## Several servers on one host

Each installation needs its own instance id, directory and port:

```bash
sudo coop install --advanced --instance second --install-dir /srv/bannerlordcoop-2 --game-port 4210
```

Container name, Compose project, lock file and systemd units are all
derived from those, so the two do not collide. Note the disk cost: each
installation keeps its own copy of the game files, roughly 18 GB.
