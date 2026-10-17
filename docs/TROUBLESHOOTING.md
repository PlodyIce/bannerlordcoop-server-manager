# Troubleshooting

Start here:

```bash
coop doctor
```

It checks the system, Docker, the configuration, the data directories, the
Steam session, the server process and the backups. Every failing line says
what to do. If that is not enough, find your symptom below.

Each entry follows the same shape: **symptom, cause, check, solution.**

---

## The installer refuses to start

### "This operating system does not provide all dependencies"

**Cause.** Your distribution is too old to supply a current Docker Engine,
or the packages the manager needs are no longer in its repositories.

**Check.**
```bash
cat /etc/os-release
```

**Solution.** Upgrade the operating system. The installer will not add
third-party repositories, download loose `.deb` files, or borrow libraries
from another release to work around it. Those are exactly the things that
turn into an unexplainable failure six months later. Nothing on your system
was changed.

### "x86_64 is required" / arm64 detected

**Cause.** The dedicated server is a Windows x64 binary run under Wine. On
arm64 that needs an x86 emulation layer as well.

**Check.**
```bash
uname -m
```

**Solution.** Use an x86_64 machine. Many inexpensive VPS offers are arm64
now; check before you buy.

### "Docker is installed but the daemon is not reachable"

**Check.**
```bash
systemctl status docker
```

**Solution.**
```bash
sudo systemctl enable --now docker
```

---

## Steam

### "Steam authentication did not complete"

**Cause.** Wrong password, a Steam Guard code that was not entered or had
expired, or an account without Bannerlord.

**Check.** Can you sign in to the same account in the Steam client?

**Solution.**
```bash
sudo coop steam login
```

Steam Guard codes are short-lived. If you were slow, ask for a new one.

### "The Steam session has expired"

**Cause.** Steam sessions do not last forever, particularly after a
password change or a sign-out-everywhere.

**Check.**
```bash
coop steam status --probe
```

**Solution.** Log in once more, then repeat what you were doing. Exit code
30 always means Steam.

### "The Workshop download failed"

**Cause.** Steam unreachable, the item unavailable, or the account does not
own Bannerlord.

**Check.**
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.steampowered.com/
```

**Solution.** Retry, because Steam has bad days. If it persists, verify
the account owns the game and check the manager log for SteamCMD's own
output:

```bash
tail -50 /srv/bannerlordcoop/logs/manager.log
```

### Steam Guard on an automated host

**Cause.** Steam Guard needs a human. There is no way around it, and none
is attempted.

**Solution.** Authenticate once interactively. The session is then reused,
and everything else runs unattended:

```bash
sudo coop steam login
```

---

## The server will not start

### Exit 6, "EULA acceptance required"

**Cause.** From Coop v0.1.6 on, the server ships with license terms of its
own and will not host a campaign until they have been accepted. Without
that it prints the terms and exits 6, over and over, because Docker
restarts it.

**Check.**
```bash
coop eula
```

**Solution.** Read the terms, and accept them if you agree:

```bash
coop eula show
sudo coop eula accept
sudo coop start
```

The manager stops the restart loop itself as soon as it sees the refusal,
and never accepts on your behalf. After a restore from a backup older than
your acceptance, nothing needs doing: the acceptance is remembered by the
manager and passed to the server again.

### "Not starting: there is no campaign named ..."

**Cause.** `SAVE_NAME` names a campaign that is not in `saves/`, usually a
typo. Starting would make the server create a new, empty world under that
name, so the manager refuses unless a new world was asked for.

**Check.**
```bash
coop campaign list
```

**Solution.** Host the campaign you meant:

```bash
sudo coop campaign use "<name>"
```

or, if a new world really is what you want:

```bash
sudo coop campaign new "<name>"
```

### It stops immediately, exit 4

**Cause.** The Coop assemblies do not match the release. The server
verifies them with SHA-256 and refuses to run if files under
`Modules/Coop` were modified.

**Check.**
```bash
coop logs | tail -50
```

**Solution.**
```bash
sudo coop update --force
```

or, if that build was working before:

```bash
sudo coop rollback
```

`server/` is mounted read-only precisely to prevent this, so if it happens,
something wrote to it from outside the container.

### Exit 2, the save will not load

**Cause.** A damaged or incomplete save, or a save written by a different
Coop build. A missing `.json` is not the cause: without it the world still
loads, and only returning players have to create their character again.

**Check.**
```bash
ls -la /srv/bannerlordcoop/saves/
```

**Solution.** Restore the last known-good backup:

```bash
coop backup list
sudo coop backup restore <id>
```

### "The server did not reach 'serving' within 600s"

**Cause.** A large campaign genuinely takes a while, but ten minutes is
beyond that.

**Check.**
```bash
coop logs --follow
```

Look for `CAMPAIGN LOADED`. If lines are still appearing, it is loading;
if the log is silent, it is stuck.

**Solution.** Restart. If it repeats, restore a backup, and check free
disk space, because a full disk produces exactly this symptom.

### "No server files found"

**Cause.** The Workshop download never completed.

**Check.**
```bash
ls /srv/bannerlordcoop/server/
```

**Solution.**
```bash
sudo coop update --force
```

---

## Players cannot connect

### Connection times out

**Cause.** Almost always the port, in one of three places.

**Check.**
```bash
coop status
```
```bash
sudo ss -lunp | grep 4200
```
From another machine:
```bash
nc -zvu your-server-ip 4200
```

**Solution.** Work through them in order:

1. **The server is running and bound.** `coop status` says ONLINE.
2. **Your provider's firewall allows UDP 4200.** This is the usual
   culprit. Note that `ufw` does *not* cover it: Docker publishes ports
   ahead of ufw's rules, so a ufw rule neither opens nor closes a
   container port.
3. **Players typed the right address.** In the co-op menu, Direct
   Connection takes one field: `ip:4200`. Port 7210 appears in some
   guides; it belongs to the standard TaleWorlds multiplayer and has
   nothing to do with this server.

### "Wrong password"

**Check.**
```bash
coop config --get SERVER_PASSWORD
```

**Solution.** Set it and restart:

```bash
sudo coop config --set SERVER_PASSWORD="the password"
```

A password change needs a restart to take effect; `coop config --set`
offers one.

### A player joins and is immediately dropped

**Cause.** Their Coop build differs from the server's.

**Check.**
```bash
coop version
```

**Solution.** Everyone must run the same build. This is also why automatic
updates are off by default. See [UPDATES.md](UPDATES.md).

### A banned player can still join

**Cause.** The ban list is new in Coop v0.1.6, and it is only read from
where the manager points the server: `config/steam-bans.json`.

**Check.**
```bash
coop ban
coop doctor
coop version
```

`coop doctor` fails the `Steam bans` line when the file is not valid JSON.
The server then keeps using the last list it could read.

**Solution.** Ban by Steam64 id, the number in the player's profile
address, `steamcommunity.com/profiles/<id>`:

```bash
sudo coop ban 76561198000000042 --name "Troublemaker"
```

No restart is needed. The server reads the list again at the next join
attempt and logs `Steam ban list loaded from Z:\data\steam-bans.json`.

---

## The campaign does not advance

### Time is frozen, `timeMode=Stop`

**Cause.** Nothing is wrong. With no players connected the campaign pauses
itself.

**Check.**
```bash
coop status
```
`Players 0`.

**Solution.** None needed. This is why an idle server is cheap to leave
running, and why an hourly backup of one costs nothing.

---

## Backups and restores

### "The archive contains unexpected entries and will not be restored"

**Cause.** The archive is not one of ours, or was modified. A restore only
accepts entries under `saves/`, `config/`, `coopdata/` and `userconfigs/`,
with no absolute or traversing paths.

**Check.**
```bash
tar -tzf /srv/bannerlordcoop/backups/<file>.tar.gz | head
```

**Solution.** Use an archive made by `coop backup`. If you trust this one
and want it anyway, unpack its directories by hand with the server
stopped. See [BACKUPS.md](BACKUPS.md).

### The server will not start after a restore

**Cause.** The restored campaign does not match the installed Coop build,
or the save itself is damaged.

**Check.**
```bash
coop logs | tail -50
```

**Solution.** The pre-restore safety backup is still there:

```bash
coop backup list
sudo coop backup restore <the pre-restore id>
```

Nothing is lost: the restore swapped directories rather than overwriting
files, and took a safety copy first.

### Backups have stopped appearing

**Check.**
```bash
systemctl list-timers 'bannerlordcoop-*'
```
```bash
journalctl -u "bannerlordcoop-backup@$(systemd-escape --path /srv/bannerlordcoop).service" -n 50
```

**Solution.** If the log says `skipped: the campaign is unchanged and
nobody is connected`, that is the design working. Otherwise:

```bash
sudo coop config --set BACKUP_ENABLED=true
sudo coop config --apply
```

### The disk is full

**Check.**
```bash
df -h /srv
du -sh /srv/bannerlordcoop/*
```

**Solution.** The game files take about 18 GB across `workshop/`,
`server/` and `rollback/`; that is the design and not waste. Tighten
backup retention instead:

```bash
sudo coop config --set BACKUP_KEEP_AUTO=24
sudo coop config --set BACKUP_MAX_TOTAL_GB=10
sudo coop backup
```

The new limits are applied on the next backup.

---

## Updates

### The update failed and rolled itself back

**Cause.** The new build did not reach "serving".

**Check.**
```bash
coop logs | tail -80
```

**Solution.** You are already back on the previous build with the server
running. Report the failure to the Coop project, and wait for the next
release. `coop update` will offer it again.

### "The update was not installed"

**Cause.** The new build comes with license terms that have not been
accepted. Exit code 80.

**Solution.** Nothing was changed; the server is still running the
previous build. Read the terms in the files the message lists, then:

```bash
sudo coop update
```

on a terminal, which asks, or `sudo coop update --accept-eula` without
one. `--yes` does not accept a license.

### "Could not determine whether an update exists"

**Cause.** The Steam Web API was unreachable. Exit code 30.

**Solution.** Retry later, or force it if you know an update is out:

```bash
sudo coop update --force
```

The scheduled check treats this as a normal outcome and does not mark
itself failed.

---

## Mods

### A player is refused: "Server does not support module ..."

**Cause.** Coop compares every community mod between server and player,
versions included. The player runs a mod the server does not, or the other
way round ("To join the server the module ... is required"), or both run
it in different versions ("Wrong version of module ..."). The last one
usually means the Workshop updated the players' copy and not yet the
server's.

**Check.**
```bash
coop mods
coop mods update --check
```

**Solution.** The player enables exactly what `coop mods` lists, in that
order, and nothing else. After a Workshop update: `sudo coop mods update`.
The message names the module, and [MODS.md](MODS.md) has the full list of
messages.

### Exit 82 or exit 5 with mods

**Cause.** The engine gave up while loading its modules (82), or crashed
(5). With mods the usual cause is one that cannot run on a dedicated
server: it needs the game's interface, or a library the server does not
have. `coop mods add` and `coop mods update` put the previous set back by
themselves when this happens, and their message names the engine's error
log.

A crashing engine loses the end of its console output, so `coop logs`
stops in the middle of a line and does not show the reason. The engine's
own logs and crash reports do; they are kept in `logs/engine/`.

**Check.**
```bash
sudo bash -c 'tail -n 20 "$(ls -1t /srv/bannerlordcoop/logs/engine/logs/rgl_log_errors_*.txt | head -1)"'
```

**Solution.** A line such as `Cannot load: <name>.dll` names what was
missing; the mod that needs it is the one to remove, with
`sudo coop mods remove <name>`. Look in the community's list for a patch
that makes it work with Coop.

### "Not starting: Workshop item(s) ... are configured but could not be installed"

**Cause.** `MODS` names a mod that is not installed, typically after a
restore or a hand edit of `server.env`, and downloading it failed.

**Check.**
```bash
coop steam status --probe
coop doctor
```

**Solution.** Renew an expired session with `sudo coop steam login`, then
`sudo coop mods update`. An item that was removed from the Workshop cannot
come back; take it out of `MODS` with `sudo coop mods remove <id>`.

### "the configured mods need module(s) none of them provides"

**Cause.** A mod depends on another mod that is not installed, and that is
not one of the frameworks the manager knows where to find.

**Solution.** Find the Workshop item that provides the named module (the
mod's Workshop page usually lists it under required items) and add it:
`sudo coop mods add <its ID>`.

### "the startup hook could not be built"

**Cause.** The hook is built once from `docker/hook` with Microsoft's .NET
SDK image, which needs to be downloaded, about a gigabyte. Usually the
download failed or the disk is full.

**Check.**
```bash
df -h /var/lib/docker
docker pull "$(coop config --get DOTNET_SDK_IMAGE)"
```

**Solution.** Free space or fix the network, then `sudo coop start`; the
build is retried at every start with mods until it succeeds.

## Permissions

### "saves/ is owned by 0:0, expected 998:998"

**Cause.** Something wrote into the data directories as root, often an
unpacked archive or a manual copy.

**Check.**
```bash
ls -ln /srv/bannerlordcoop/
```

**Solution.**
```bash
cd /srv/bannerlordcoop
sudo chown -R "$(coop config --get PUID):$(coop config --get PGID)" saves config coopdata userconfigs logs server
```

Leave `state/steam` alone. SteamCMD runs as root, and handing that
directory to the service user makes the next download fail with
`Couldn't create cache directory`, which looks exactly like an expired
session.

`coop backup restore` sets ownership itself, which is why a backup from a
machine with different user IDs restores cleanly.

---

## Getting more detail

```bash
coop --verbose <command>
coop doctor --json | jq .
tail -100 /srv/bannerlordcoop/logs/manager.log
coop logs -n 200
journalctl -u docker -n 50
```

When reporting a problem, include `coop doctor --json` and the last 100
lines of `coop logs`. Neither contains your password, because the manager
does not log secrets.
