# Mods

The server can load mods from the Steam Workshop. Players need exactly the
same mods, in the same versions, or Coop refuses them when they join.

```bash
sudo coop mods add 3786391685 2859265386 3777470096 3627538517
coop mods
```

> **Community territory.** The Coop team does not support mods: the Workshop
> page of Coop says to disable all other mods, and compatibility is not
> guaranteed. Which mods work with Coop is collected by its community, in
> the `#other-mods` channel of the [Coop Discord](https://discord.gg/bannerlordcoop),
> where a pinned post lists working mods, the patches they need and the
> tools players host with. How this manager loads mods on a server follows
> those tools, ModderLords in particular. Report a problem with a mod to its
> author or in `#other-mods`, not as a Coop bug.

## Adding mods

```bash
sudo coop mods add <Workshop ID or link>...
```

The number in an item's address is its ID, as in
`steamcommunity.com/sharedfiles/filedetails/?id=3786391685`. The whole link
works too. Several items go into one command.

What happens, in this order:

1. The items are downloaded with SteamCMD, with the same Steam session the
   Coop download uses.
2. Their manifests are read. An item that is not a Bannerlord module, or
   that calls itself a module of the game or of Coop, is refused.
3. What they need is worked out. Harmony, ButterLib, UIExtenderEx and Mod
   Configuration Menu come from the Workshop by themselves; anything else
   a mod needs and the command does not name is reported, and nothing is
   changed.
4. You see what will be installed and what players will need, and are
   asked.
5. The first time, the startup hook described below is built.
6. The server stops with a closing save, a backup is made, the mods are
   switched on, and the server starts and has to reach "serving". If it
   does not, the previous set of mods is put back and started by itself.

`--yes` answers the question. With `--non-interactive` and without `--yes`,
the command stops before it changes anything.

## What players need

```bash
coop mods
```

lists the mods and prints what players need, with the names their launcher
shows, in the order to enable them, followed by a link to each Workshop
page. For the CoopModPatch set:

```
  Players need the same mods, in the same versions, in this order:
    Harmony, ButterLib, UIExtenderEx, Mod Configuration Menu v5, Native,
    SandBox Core, Sandbox, CoopModPatch, Improved Garrisons,
    Settlement Culture Drift, My Little Warband (v1.2.6/1.4.6), Coop
  StoryMode and CustomBattle may stay on. War Sails, Birth and Aging
  Options and Fast Mode stay off.
```

The names are the ones the mods give themselves, which is what the game's
launcher shows, version numbers included where a mod puts them there.

The join check compares module names and versions, not whether mods work
together. A player with a mod the server does not have, or a different
version of one, is refused with a message that names it:

| Message | Meaning |
|---|---|
| `Server does not support module ...` | The player has a mod the server does not. Disable it, or add it to the server. |
| `To join the server the module ... is required.` | The server has a mod the player does not. |
| `Wrong version of module ...` | Both have it, in different versions. Usually the Workshop updated one side. |

## Keeping up with Workshop updates

Steam updates the mods players subscribed to without asking them. A server
left on the old version refuses them from then on with
`Wrong version of module`. So the nightly update check also asks the
Workshop about every mod, anonymously, and reports what it finds in
`coop status` and in the message shown at an SSH login:

```bash
coop mods update --check
sudo coop mods update
```

`coop mods update` downloads every mod, installs the ones that changed,
and restarts the same way `add` does: closing save, backup, start, and the
previous versions back by themselves if the server will not serve. Nothing
is updated on a schedule; the moment to restart is yours.

A new Coop build is a common reason for mods to update as well. After
`coop update`, check them.

## Removing mods

```bash
sudo coop mods remove <Workshop ID, link, module id or name>...
```

A name may stop at the end of a word, so `"My Little Warband"` finds
"My Little Warband (v1.2.6/1.4.6)", as long as no other mod's name begins
the same way. A mod another installed mod needs cannot be removed on its
own; the command names which. Frameworks that only the removed mods needed go with
them. The answer defaults to no, because a campaign that was played with a
mod can carry data of it, and loading it without the mod can lose that data
or fail to load. The backup made before the change is the way back.

## Which mods work

There is no official list. The community's list in `#other-mods` is the
place to look, and most of it was tested on Coop v0.1.5 with Windows tools,
so treat entries as "probably" until somebody confirms them on the current
Coop build.

Tested with this manager:

| Set | Workshop items | Tested |
|---|---|---|
| CoopModPatch, with the mods it patches | CoopModPatch 3786391685, Improved Garrisons 2859265386, Settlement Culture Drift 3777470096, My Little Warband 3627538517, plus Harmony, ButterLib, UIExtenderEx and Mod Configuration Menu v5 | Coop v0.1.6 on Debian 13, October 2026: server serves, a player joins and plays, campaign saves and stops cleanly |

What does not work:

- **Mods outside the Steam Workshop.** Total conversions such as The Age of
  Men come from ModDB or Nexus, with compatibility modules of their own,
  and are not supported yet.
- **Mods that need the game's interface to run.** A dedicated server has no
  screen. Coop's join check still requires every mod on both sides, so a
  mod that only changes what players see has to load on the server as
  well, and one that cannot start without an interface stops the server.
  The server then exits with code 82, or crashes with code 5, and the
  engine's own error log in `logs/engine/logs/` names what it could not
  load; see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- **War Sails.** Coop refuses it, with or without mods.

## A new campaign with mods

A world the server creates is made from the template the Coop build ships,
which knows nothing of the mods. Mods that change behaviour, as the
CoopModPatch set does, are fine with that: the server loads the world and
notes the difference in its log as
`module mismatch ... Forcing load anyway`. Mods that add to the world
itself, such as new factions or settlements, are not. For those, start the
campaign in single player with the same mods, save it once, and bring the
save to the server:

```bash
sudo coop import-save /tmp/incoming
sudo coop campaign use "My Modded Campaign"
```

[SAVE-MIGRATION.md](SAVE-MIGRATION.md) has the details, including the
`.json` that has to travel with the save.

## Mod settings

Mods built on Mod Configuration Menu read their settings through it. With
CoopModPatch installed, the server's values are the ones that count, and
they are sent to every player who joins; settings a player made in their
own game do not apply on this server. They live in the server's data
directory:

```
/srv/bannerlordcoop/config/Configs/ModSettings/Global/<mod>/
```

CoopModPatch writes a file there with its defaults the first time it needs
one. Edit it with the server stopped, then start it again. `config/` is in
every backup.

## How it works

### Two ways to start

`BannerlordCoopServer.exe`, the launcher the Coop team ships, starts the
game engine with a fixed list of modules and has no way to add to it. So
without mods it starts the server as before, and with mods the manager
starts the engine directly, the way the launcher does: the same program,
arguments, working directory and environment, read from a running official
server, with the mods added to the module list.

Everything the manager relies on lives in the engine rather than in the
launcher, and keeps working:

- **The license terms.** The engine checks them itself and exits 6 without
  an acceptance, exactly as before. Nothing about [accepting them](CLI.md#license-terms)
  changes.
- **The checksum check** of the Coop assemblies.
- **`server-config.json`**, the console, the closing save, and the status
  events `coop status` reads.

The one thing the launcher did that the engine does not, the log file per
launch, the container's entrypoint does instead.

### What changes for the server

Three things a mod needs on a dedicated server, found by loading them on one:

1. **A server copy of its manifest.** Frameworks such as Harmony and Mod
   Configuration Menu stay in the module list, because the join check
   compares it, but load no code: a server has no interface for them to
   extend. MCM keeps its settings core, which mods read their settings
   through. Mods written for players mark themselves as not for dedicated
   servers and are loaded anyway; making that work is what patches like
   CoopModPatch are for. A mod that ships a server half and a players'
   half has only its server half loaded.
2. **Help finding libraries.** Mods reference interface libraries that a
   server only has inside the Coop module, and the engine loads Coop after
   every mod. A small startup hook, `docker/hook`, answers the runtime's
   "assembly not found" from Coop's folder first, then from the mods' own.
   It patches no game code. It is built on your server from that source,
   once, with Microsoft's .NET SDK image, which is downloaded for the
   purpose and removed again; `DOTNET_SDK_IMAGE` names it.
3. **A writable `Configs` folder** in the game's Documents folder, where
   some mods keep files of their own. Improved Garrisons keeps some per
   campaign. `userconfigs/` is mounted there and is part of every backup.

None of the mods' files is changed. The server runs from `runtime/`, a
view that links `server/` and the mods together and holds the rewritten
manifests, the hook and a launch file for the entrypoint. It is rebuilt
before every start with mods, in a fraction of a second, and takes no space
of its own.

### Where things are

| Path | Purpose | In a backup? |
|---|---|---|
| `mods/<Workshop ID>/` | The installed copy of each mod | No, it comes from the Workshop again |
| `runtime/` | The view the server runs from with mods | No, rebuilt before every start |
| `userconfigs/` | What mods keep in the game's `Configs` folder | Yes |
| `config/Configs/` | Mod settings the server hands to players | Yes, with `config/` |
| `workshop/content/261550/<Workshop ID>/` | SteamCMD's download, as for Coop | No |
| `state/hook/` | The startup hook | No, rebuilt when needed |

The list of mods is the setting `MODS` in `config/server.env`: Workshop
IDs, in load order. `coop mods` keeps it, and it can be edited by hand like
any other setting; the next start downloads whatever it names and is
missing. A backup records the mods it was made with, and restoring one
brings its `MODS` back. The Workshop keeps only the latest version of an
item, so that is the version a restore gets. Installed mods the restored
`MODS` does not name are removed from `mods/` once the server serves.
