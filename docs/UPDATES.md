# Updates

## Two kinds of update, kept apart

| What | Source | Command |
|---|---|---|
| The Coop server build | Steam Workshop | `coop update` |
| This manager | git | `git pull`, then `coop config --apply` |

And a distinction that matters more:

| Command | Moves |
|---|---|
| `coop update` / `coop rollback` | the **software** forward or back |
| `coop backup restore` | the **saves and configuration** back |

They never touch each other's territory. An update carries your campaign
across untouched; a restore leaves the installed build alone.

## Checking

```bash
coop update --check
```

The check compares the Workshop timestamp of the build that is installed,
recorded when the manager put it in place, against the public Steam Web
API. It needs no API key and no login, which is why the scheduled check
can run unattended.

```
A Workshop update is available.
  installed: 2026-09-07 16:32
  available: 2026-10-07 01:42

  Install it with: coop update
  Remember that every player needs the same Coop build.
```

### Exit codes

`coop update --check` exits **0 when the check succeeded**. Whether an
update exists is in the output, or in `.update_available` with `--json`.
That is the convention every other tool follows.

Scripts that would rather have it as an exit code:

```bash
coop update --check --exit-status
```

100 means an update is available, 0 means up to date, 30 means Steam could
not be reached.

## Installing

```bash
coop update
```

1. Check the version, and stop here if there is nothing new, unless `--force`
2. Download from Steam, **while the server keeps running**
3. Settle the new build's license terms, if it ships any (see below)
4. Stop the server cleanly, which writes a closing save
5. Create a `pre-update` backup
6. Copy the current build to `rollback/`
7. Synchronise the new files into `server/`
8. Carry the gameplay settings across (see below)
9. Start, and wait until the server is serving clients
10. Record the new version

Everything that can fail or be declined without consequences happens
while the current build is still serving. A failed download, or license
terms you do not accept, leave the server exactly as it was: nothing has
been stopped yet.

**If step 9 fails, the manager rolls back by itself** and tells you so. You
are left on the previous build with the server running, not on a broken
one.

```
Workshop update

Downloaded: build 2026-10-06 / Mount & Blade II: Bannerlord v1.4.8
Stopping the server (console shutdown, with a closing save)
  + Server stopped cleanly
Creating a pre-update backup
  + Backup created: pre-update-20261010-183650.tar.gz (12 MB)
Copying the current build to rollback/
Synchronising the new build into server/
New build: build 2026-10-06 / Mount & Blade II: Bannerlord v1.4.8
  + Gameplay settings brought up to this build; your values were kept
Starting the server
  + Server is serving ('My Campaign')
  + Update complete: build 2026-10-06 / Mount & Blade II: Bannerlord v1.4.8
```

That is the update from Coop v0.1.5 to v0.1.6 on a real server: about
90 seconds from the first line to serving again.

## License terms

From Coop v0.1.6 on, the dedicated server ships with license terms of its
own, `EULA.md` and `LICENSE.txt`, and will not host a campaign until they
have been accepted. A build that comes with terms you have not accepted
asks before anything is stopped:

```
License terms

  This Coop server build comes with license terms of its own. The
  server will not host a campaign until they have been accepted:

    /srv/bannerlordcoop/workshop/content/261550/3770450698/DedicatedServer/EULA.md
    /srv/bannerlordcoop/workshop/content/261550/3770450698/DedicatedServer/LICENSE.txt

  They are the Bannerlord Coop team's terms, not this installer's, and
  accepting them is your decision. Acceptance alone does not permit
  commercial hosting; the terms say what does.

Read them now? [Y/n]
Do you accept these license terms? [y/N]
```

Declining leaves everything as it was, with exit 80. Accepting is
recorded against a checksum of exactly those documents, so:

- a later build with **the same** terms installs without asking again;
- a later build whose terms **changed** asks again, because the terms say
  that changed terms need a fresh acceptance;
- a rollback to a build whose terms you accepted earlier starts without
  asking.

Without a terminal the question cannot be asked, so the update stops
before touching the server unless you pass `--accept-eula`. Do that only
once you have read the terms. `--yes` never accepts a license: a flag that
confirms an operation is not consent to terms.

```bash
coop update --accept-eula
```

An unattended update never accepts terms on its own. With
`AUTO_UPDATE=true`, a build with new terms is downloaded but not
installed, and waits for you to run `coop update`.

`coop eula` shows where you stand. See [CLI.md](CLI.md).

## Rolling back

```bash
coop rollback
```

Restores `server/` from `rollback/` and puts back the gameplay
configuration that went with that build. Campaign saves are not touched.

The rollback copy is a full directory rather than a re-download. It costs
about 6 GB of disk and turns a rollback into a rename instead of a
twenty-minute download at the worst possible moment.

A rollback copy exists from the first `coop update` onwards. Before that
there is nothing to go back to, and the command says so.

## The scheduled check

Runs nightly at 04:00 by default and **reports only**.

```bash
coop config --set UPDATE_CHECK_SCHEDULE="*-*-* 04:00:00"
coop config --set UPDATE_CHECK_ENABLED=false
```

When an update is found, a marker is written, and `coop status` and the
message at an SSH login both show it. A successful `coop update` removes it.

The same run checks the mods, if there are any, and reports updates for
them the same way. Those matter sooner than a Coop build: Steam updates the
players' copies of a mod by itself, and a server left on the old version
refuses them. `coop mods update` installs them; see [MODS.md](MODS.md).

If Steam cannot be reached the service exits 30, which its unit file
declares a success. An unreachable Steam API is weather, not a failure of
the timer.

## Why automatic updates are off

The server verifies its own Coop assemblies with SHA-256, and **clients
must run the same build**. An update installed overnight would lock out
every player who has not yet updated their own client. The server would be
running, and nobody could join.

So the default is to check and report, and let you install when your group
can update together.

If that trade suits you:

```bash
coop config --set AUTO_UPDATE=true
```

The scheduled check will then install updates as it finds them, with the
same pre-update backup and automatic rollback as a manual run. It stops
short of a build whose license terms you have not accepted: those wait for
`coop update`, and the timer's unit reports the run as failed so that it
shows up in `systemctl --failed`.

## Gameplay configuration during an update

`mod-config.json` holds the gameplay settings such as difficulty, world
ageing and battle size. It belongs to the Coop mod, not to this manager.

The mod creates it once, from the template its build ships
(`mod-config.default.json`), and **never replaces it afterwards**. So the
settings a new build introduces never reach an existing file on their own:
they run at their defaults, invisible, and nothing tells you they exist.
Coop v0.1.6 added nine of them, among them `voiceEnabled` and
`coopClansEnabled`.

So before the new build first starts, the manager **merges**. The new
build's template is the base: it brings the new settings and the comments
that document them. Every value from your file is written into it.

| Setting | What happens |
|---|---|
| In both | Your value is kept |
| New in this build | Added at the build's default, with its comment, and reported by name |
| Gone from this build | Removed, and reported by name |
| Default changed in this build | Your value is kept, and the change is reported where your file still holds the old default |

```
  + Gameplay settings brought up to this build; your values were kept
    New in this build, at their defaults:
      mapFullVolumeDistance, mapMaximumDistance, sceneFullVolumeDistance,
      sceneMaximumDistance, voiceEnabled,
      blockAiWarDeclarationsOnOfflinePlayers, ensureUnaffiliatedWanderers,
      coopClansEnabled, enablePlayerExecutions
    Defaults this build changed. Your file keeps the value it had:
      birthAndDeath                            false, now true
      enableHeroExecutions                     true, now false
      goldFoodInfluenceChangeInBattles         "OneDayMax", now "Disabled"
      goldFoodInfluenceChangeInSettlements     true, now false
      playerBattleAiJoinWindowHours            24, now 6
    To follow a new default, edit /srv/bannerlordcoop/coopdata/mod-config.json
    and run: coop restart
```

That is the actual report from the update to v0.1.6.

**Changed defaults are reported, not applied.** A value that equals the
old default may still be a deliberate choice, and changing difficulty or
the economy in the middle of a running campaign is a decision for whoever
runs it. The report names exactly the settings worth a look; if you want
the new default, change the value and restart.

If the merged file would not account for every setting the template has,
it is thrown away and your file is left exactly as it was. The mod runs
anything the file does not mention at its default, so the server still
works; a merge that quietly lost settings would be worse than none.

When the new build's template is identical to the old one, nothing is
merged and nothing is reported.

### How the merge works

The file is JSONC, so `jq` cannot read it. It is also strictly one setting
per line, which makes a line-oriented merge both possible and safe: values
are substituted in place and every comment survives untouched. All setting
names in the file are unique, so a value is matched by name regardless of
which section it lives in. The file has Windows line endings, and a line
that receives a value keeps them.

A rollback is different: `coop rollback` puts the whole previous
`mod-config.json` back, because the older build expects exactly the keys it
shipped with.

## After updating

```bash
coop status
coop doctor
```

And tell your players to update their client. `coop version` prints the
build both sides need to match.

With mods, check them too. A new Coop build is a common reason for mods to
update as well, and the update itself rolls back if the server will not
serve with them:

```bash
coop mods update --check
```

The check compares against the build that is actually **installed**, not
against the last download. After a rollback, or after an update that was
downloaded but not installed, `coop update --check` therefore still reports
the newer build, and `coop update` installs it.

## Updating the manager itself

```bash
cd /path/to/bannerlordcoop-server-manager
git pull
sudo coop config --apply
```

`--apply` regenerates the files the server reads and reinstalls the systemd
units. Your `server.env` is not touched: new settings fall back to their
defaults, and settings you have changed keep your values.

The runtime image carries a checksum of the files it was built from. When
a manager update changes them, the image is rebuilt before the server next
starts: by `coop restart`, `coop update`, a campaign switch or a change of
mods while the server still serves, so that players do not wait for it.
Usually only the scripts changed, which sit last in the image and take
seconds; when Docker has discarded its build cache, the rebuild installs
Wine again and takes a few minutes.
