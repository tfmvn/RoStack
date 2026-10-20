# Vendored third-party code

This folder holds **third-party code that is not part of the Brainrot Arena
extraction**. It is here so that the library's own test project and its
`Examples/MinimalGame` build without reaching back into the production
`src/` tree.

| File | What | Licence | Upstream |
|---|---|---|---|
| `ProfileService.lua` | The standalone ProfileService — session-locked DataStore profiles. Required by the `PlayerData` system. | MIT (MadworkRoblox) | <https://madstudioroblox.github.io/ProfileService/> |

**This is a verbatim copy of the file the source game vendors at
`src/Vendored/ProfileService.lua`.** It was not modified during extraction.

## In your own game

You do not have to keep this copy. `ProfileService` is a normal Wally
dependency:

```toml
[dependencies]
ProfileService = "0.0.0-..."
```

Point your own Rojo project at the package and delete this folder. The
library's `Systems/PlayerData/Source/ServerScriptService/PlayerService.lua`
requires it as:

```lua
local ProfileService = require(game:GetService('ServerScriptService').Packages.ProfileService)
```

so the only requirement is that a module named `ProfileService` exists at
`ServerScriptService.Packages.ProfileService`. See
`Systems/PlayerData/Setup.md` and the root `README.md` §"Third-party
packages".

## Why it is vendored here at all

`ReusableSystems/test.project.json` and
`ReusableSystems/Examples/MinimalGame/minimalgame.project.json` need a
`ProfileService` instance to build. Pointing them at `../src/Vendored/...`
would make the library depend on the production tree, which breaks the
moment the library folder is copied into a different repository. Vendoring
the single file keeps the library self-contained.

## Accounting

This file is **not** part of the extraction accounting in
`EXTRACTION_MANIFEST.md` §1. It is third-party code copied verbatim, not a
`src/` game file — the same status as `ServerPackages/` and `DevPackages/`
in the host repository. The manifest records it in §5.7 alongside the
`src/` files that were deliberately not copied.
