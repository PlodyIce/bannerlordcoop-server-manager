# Command reference

One entry point: `coop`. Everything a person or a script does goes through
it.

## Global options

These work with any command and may appear before or after it.

| Option | Effect |
|---|---|
| `--install-dir <path>` | Operate on the installation in `<path>` |
| `--instance <id>` | Operate on a named instance |
| `--config <file>` | Read settings from `<file>` |
| `--json` | Machine-readable output, where the command supports it |
| `--non-interactive` | Never prompt; a missing required value is an error |
| `--yes`, `-y` | Answer confirmations with yes |
| `--accept-eula` | Accept the Coop server's license terms without a prompt. `--yes` never does. Read them first. |
| `--quiet`, `-q` | Only warnings and errors |
| `--verbose`, `-v` | Extra detail |
| `-h`, `--help` | Usage |

Every configuration setting is also a flag, derived from its name:
`--save-name`, `--game-port`, `--backup-keep-auto`. Aliases: `--password`,
`--channel`, `--backup-retention`. See [CONFIGURATION.md](CONFIGURATION.md).

## Setup

### `coop install`

Installs a server on this host. Needs root.

| Option | Effect |
|---|---|
| `--default` | Recommended mode: campaign name, password, Steam |
| `--advanced` | Also ports, paths, backups, updates, limits |
| `--non-interactive` | Take every value from flags or a config file |

Runs in eight steps: compatibility check, setup mode, configuration, Steam
authentication, summary, installation, start, validation. Nothing is
changed until after the summary is confirmed.

Running it again on an existing installation offers update, repair,
reconfigure or exit. It never silently overwrites a campaign.

Before the first start, the Coop server's own license terms are put to
you. Unattended, `--accept-eula` accepts them; without it the installation
completes, the server is not started, and the command exits 80. See
[License terms](#license-terms).

```bash
sudo coop install --advanced
```

```bash
sudo coop install --default --non-interactive --yes --accept-eula --save-name "Customer Campaign" --server-password "s3cret" --game-port 4210
```

### License terms

| Command | Root | Notes |
|---|---|---|
| `coop eula` | no | Does the installed build ship terms, and are they accepted? `--json`. |
| `coop eula show` | no | Print them. On a terminal they open in a pager: Space scrolls, `q` quits |
| `coop eula accept` | yes | Accept them, after a question; `--accept-eula` skips the question |

From Coop v0.1.6 on, the dedicated server ships with an EULA and a license
of its own and will not host a campaign until they have been accepted.
Acceptance is recorded against a checksum of exactly the documents you
accepted. A build whose terms differ asks again; `coop update` and
`coop install` ask on their own when they meet new terms. The answer is
yours to give: the manager never accepts on anyone's behalf, and `--yes`
does not count as consent.

## Running the server

| Command | Root | Notes |
|---|---|---|
| `coop status` | no | What the server is doing. Supports `--json`. |
| `coop start` | yes | Starts and waits for the server to serve clients |
| `coop stop` | yes | Console shutdown with a closing save |
| `coop restart` | yes | Stop, then start |
| `coop save` | yes | Force a save and wait for the file |
| `coop console <cmd>` | no | Send a command to the server console |
| `coop logs [--follow] [-n N]` | no | Show the server log |

`coop start` returns only once the server reports that it is serving, which
on a grown campaign takes about two minutes. It exits 50 if that never
happens, 80 if the build's license terms have not been accepted, 10 if
`SAVE_NAME` names no campaign and no new world was asked for, and 40 if the
runtime image or the mods could not be prepared.

Console commands the server accepts: `status`, `players`, `save`, `say`,
`kick`, `help`.

```bash
coop console players
```

## Campaigns

| Command | Root | Notes |
|---|---|---|
| `coop campaign list` | no | The campaigns in `saves/`, and which one is hosted. `--json`. Alias: `coop campaigns` |
| `coop campaign use <name>` | yes | Host an existing campaign |
| `coop campaign new <name>` | yes | Start a new world under a new name |

The server hosts one campaign, the save named by `SAVE_NAME`. Both
switching commands do the same four things in the same order: stop with a
closing save, create a backup, change `SAVE_NAME`, start and wait until the
server serves. If the server will not serve the new campaign, the previous
one is put back and started. When players are connected, you are asked
first; `--yes` answers for you.

`campaign use` refuses a name with no campaign behind it and changes
nothing. A different spelling of the same name in another case finds the
campaign, as the server itself would. `campaign new` refuses a name that
already has a campaign.

```bash
sudo coop campaign use "My Campaign"
```

```bash
sudo coop campaign new "Second Campaign"
```

A new world is only ever created when it was asked for: at installation,
with `campaign new`, or with `config --set SAVE_NAME=... --new-world`. Any
other start with a name that has no save behind it is refused, so a typo
cannot quietly send your players into an empty world.

Not campaigns, and never listed: `default_new_game` (the template new
worlds are made from), `<name>.backup1` and `.backup2` (generations the
server keeps by itself), `coop_bug_report` and `TransferSave`.

Gameplay settings (`mod-config.json`) are shared by every campaign on the
server.

## Mods

| Command | Root | Notes |
|---|---|---|
| `coop mods` | no | The installed mods, in load order, and what players need. `--json`. Same as `coop mods list` |
| `coop mods add <id>...` | yes | Install Steam Workshop mods, by ID or link |
| `coop mods remove <id>...` | yes | Remove mods, by Workshop ID, link, module id or name |
| `coop mods update` | yes | Install newer versions of the mods |
| `coop mods update --check` | no | Only report whether there are any. `--json`. |

`add`, `remove` and `update` change the server the way a campaign switch
does: stop with a closing save, back up, change, start and wait until the
server serves. If it will not serve, the previous mods, or their previous
versions, are put back and started. When players are connected, you are
asked first.

`add` brings the frameworks the new mods need along by itself and refuses,
changing nothing, when a mod needs something no named item provides.
`remove` refuses to take away what a remaining mod needs, and asks with a
default of no, because a campaign played with a mod can carry data of it.

```bash
sudo coop mods add https://steamcommunity.com/sharedfiles/filedetails/?id=3786391685
```

```bash
sudo coop mods remove "My Little Warband"
```

The mods are the setting `MODS`. [MODS.md](MODS.md) explains what a server
does with them and what players need.

## Players

| Command | Root | Notes |
|---|---|---|
| `coop ban` | no | List banned Steam accounts. `--json`. |
| `coop ban <steam64-id> [--name "<hero name>"]` | yes | Ban a Steam account |
| `coop unban <steam64-id>` | yes | Lift a ban |

From Coop v0.1.6 on, the server refuses the Steam accounts in its ban list
when they try to join. It re-reads the list whenever it changes, so a ban
needs no restart. The Steam64 id is the number in a player's profile
address, `steamcommunity.com/profiles/<id>`. `--name` only notes who it
was.

The list lives in `config/steam-bans.json`, which every backup carries.

## Configuration

| Command | Root | Notes |
|---|---|---|
| `coop config` | yes | Walk through the common settings |
| `coop config --advanced` | yes | Include the rest |
| `coop config --list` | no | Every setting, value and type. `--json`. |
| `coop config --get KEY` | no | Print one value |
| `coop config --set KEY=VALUE` | yes | Change one value. `SAVE_NAME` must name a campaign unless `--new-world` is given |
| `coop config --apply` | yes | Regenerate generated files, restart if needed |

A change to a setting marked "restart required" offers a restart; without
a terminal it does not, and you restart when it suits you.

`coop config --set SAVE_NAME=...` refuses a name with no campaign behind
it, for the same reason `coop campaign use` does. `--new-world` says that a
new world is what you want. `coop campaign use` is the better route for a
switch, because it also makes a backup and restarts.

## Software

| Command | Root | Notes |
|---|---|---|
| `coop update` | yes | Install a newer Coop build |
| `coop update --check` | no | Only report. `--json`. |
| `coop update --force` | yes | Install even when the check disagrees |
| `coop update --accept-eula` | yes | Accept new license terms without a prompt |
| `coop rollback` | yes | Return to the previous Coop build |
| `coop steam status [--probe]` | no | Is the session usable? `--json`. |
| `coop steam login` | yes | Authenticate with Steam |
| `coop steam logout` | yes | Discard the stored session |

`coop update --check` exits **0 when the check succeeded**, and says in its
output whether an update exists, which is the convention every other tool
follows. Scripts that prefer it as an exit code add `--exit-status` and get
100 when one is available.

`coop steam status` is instant and offline; `--probe` contacts Steam, which
is the only way to tell an expired session from a valid one.

## Data

| Command | Root | Notes |
|---|---|---|
| `coop backup [--note "..."]` | yes | Create a backup now. `--json`. |
| `coop backup list` | no | List backups with their IDs. `--json`. |
| `coop backup info <id>` | no | What is in one. `--json`. |
| `coop backup restore [<id>]` | yes | Restore saves and configuration. Without an ID, pick from a list. |
| `coop import-save <dir>` | yes | Import campaign saves from a directory |

A backup is identified by its ID (`20260911-004626`), by its file name, or
by its position in the last listing. It is never taken from an arbitrary
path.

```bash
coop backup list
```

```bash
coop backup restore 20260911-004626
```

## Diagnostics

| Command | Root | Notes |
|---|---|---|
| `coop doctor` | no | Check everything and say what is wrong. `--json`. |
| `coop version` | no | Manager and Coop versions. `--json`. |

`coop doctor` exits 50 if anything failed and 0 otherwise. Warnings alone
do not make it fail.

## Exit codes

Automation can tell failure classes apart:

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Wrong invocation: unknown command, missing argument |
| 10 | Invalid configuration, or a required value is missing |
| 20 | Unsupported system, or a dependency is unavailable |
| 30 | Steam authentication or download failed |
| 40 | Container or server process failure |
| 50 | Health check failed |
| 60 | Backup or restore failed |
| 70 | Another operation holds the lock |
| 80 | The Coop server's license terms have not been accepted |
| 100 | `update --check --exit-status` only: an update is available |

## Non-interactive behaviour

`--non-interactive` is a promise, not a hint:

| Situation | Interactive | `--non-interactive` |
|---|---|---|
| A required value is missing | asks | exit 10, naming the flag |
| A destructive step needs confirmation | asks | exit 10 unless `--yes` |
| The Steam session is missing | offers to log in | exit 30 with instructions |
| New license terms | asks | exit 80 unless `--accept-eula`; `--yes` does not count |
| Output | colour when on a terminal | plain; `--json` for machines |

There are no hidden confirmations. A destructive operation without `--yes`
fails rather than proceeding.

## JSON output

Supported by `status`, `doctor`, `config --list`, `backup list`,
`backup info`, `backup`, `update --check`, `steam status`, `eula`,
`campaign list`, `mods`, `mods update --check`, `ban` and `version`.

Logs and progress always go to stderr, so stdout carries nothing but the
JSON document:

```bash
coop status --json | jq -r .status
```

```bash
coop doctor --json | jq -r '.checks[] | select(.status=="fail")'
```
