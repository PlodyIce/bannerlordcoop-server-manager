# Mod manifest fixtures

Trimmed copies of the `SubModule.xml` files `tests/unit.sh` checks the
manifest handling of `lib/mods.sh` against. The four frameworks follow the
real Workshop manifests of Harmony, ButterLib, UIExtenderEx and Mod
Configuration Menu v5 as of October 2026; the rest are made up to cover one
case each:

| Folder | Case |
|---|---|
| `gameplay` | A mod for players that marks itself as not for dedicated servers, needs two frameworks, an official module and an optional one, and ships only a client bin |
| `split` | A mod with a server half and a players' half |
| `patch` | A mod that needs nothing rewritten and ships a server bin |
| `reserved` | An item claiming the id of a game module, which is refused |

The DLLs are placeholders.
