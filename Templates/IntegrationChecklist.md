# Integration Checklist

Use this when lifting a system (or the whole library) into a new game.

Copy it into your project as `Docs/INTEGRATION_CHECKLIST.md` and tick the
boxes. Every item is derived from something that will actually bite you.

---

## 1. Before you copy anything

- [ ] Read the system's `README.md` and `Dependencies.md`.
- [ ] Read `SYSTEM_INDEX.md` and note the **Portability** grade.
- [ ] Read the system's `Dependencies.md` → *Other Systems Required*. If any
      of them is **not** optional, you are taking a dependency too. The
      closure is in `DEPENDENCY_MAP.md` §10.
- [ ] Read `MEMORY.md` §7 — *Compatibility and Known Issues*. Some systems
      have open bugs you must know about before you inherit them.
- [ ] Decide what you are **not** taking. A partial system is often better
      than a whole one with the wrong content in it.

---

## 2. Copying the files

- [ ] Copied the system's whole `Source/` tree, preserving the sub-paths.
- [ ] Copied every `Shared/` module the system requires, to the right
      destination:
      - `Shared/Types/*` → `ReplicatedStorage/Types/`
      - `Shared/Utilities/*` → `ReplicatedStorage/Utility/`
      - `Shared/CommonModules/*` → `ReplicatedStorage/Utility/`
      - `ShopAnimations.lua` → `ReplicatedStorage/ShopAnimations.lua`
        (**not** into `Utility/`)
- [ ] Copied the config domains the system reads. **These are spread across
      systems** — `Config/Economy/Money.lua` lives under
      `Systems/Economy/Source/…`, but `Config/Systems/Debug.lua` lives under
      `Systems/SharedUtilities/Source/…`. Read the require list, not the
      folder name.
- [ ] Copied the `Tests/` specs, if you want them.
- [ ] `git status` shows **only** your new files. Nothing under `src/` of
      the source repo changed.

---

## 3. Third-party packages

- [ ] `wally install` succeeded.
- [ ] `ProfileService` is present at `ServerScriptService.Packages.ProfileService`
      (only if you took `PlayerData`).
- [ ] `Janitor` is installed (used by `PlayerData`, `Animals`, and others).
- [ ] `Cmdr` is installed (only if you took `AdminTools`).
- [ ] `Signal` and `t` are installed (`Shared/Utilities/Signals.lua` and
      `Validation.lua` re-export them).
- [ ] `TopbarPlus` is installed (only if you took the client topbar UI).
- [ ] You did **not** copy `Fusion` or `Promise` — they are dead
      dependencies in the source game.

---

## 4. The bootstrap

- [ ] `createRemotes()` is in your bootstrap (copied from
      `bootstrap.server.lua:203-222`).
- [ ] `createRemotes()` is called **before** any service `Init()`.
- [ ] The services are initialised in the order in `DEPENDENCY_MAP.md` §2.
- [ ] Every `Set<Peer>Service()` injection the system needs is present.
- [ ] `ConfigValidator.ValidateAll()` runs early, and you understand that a
      validation failure is a **hard error in Studio** and a **warning in a
      live server**.
- [ ] `Players.CharacterAutoLoads = false` is set before the first player
      joins (if you took the character lifecycle).
- [ ] The player lifecycle (load → assign base → restore → mark loaded →
      push state) is wired, and **a failed load kicks the player** rather
      than leaving them in a half-loaded state.

---

## 5. Studio assets

None of these are in the repository. Author them.

- [ ] The `Workspace` hierarchy the system expects (see
      `Dependencies.md` → *Assets*).
- [ ] Every base has a `Collector` child — **a base without one is a fatal
      error** in the source game's setup.
- [ ] The stand `Button.PressPart` cash triggers exist.
- [ ] The `PlayerGui` hierarchy each client controller expects.
- [ ] Sounds, animations, and tools.

---

## 6. Environment-specific values

See `SECURITY_NOTES.md` §4 for the full list.

- [ ] The profile **DataStore name** changed, with an environment suffix
      (`dev` / `live`) and a schema version.
- [ ] The registry DataStore name changed.
- [ ] The slot-id prefix changed (if you are not continuing this game's
      data).
- [ ] Every `ProductId` and gamepass id replaced.
- [ ] The admin allowlist reviewed (the library copy is **empty**).
- [ ] `Config/Systems/Debug.lua` reviewed — `SkipPersistence` must be
      `false` in production.
- [ ] `Config/Systems/Security.lua` reviewed for your expected traffic.

---

## 7. Secrets

- [ ] **No** credential in any `ReplicatedStorage` module. Config replicates
      to every client.
- [ ] The Discord webhook (if you took `PlayerLogger`) is set as a
      `ServerScriptService` **attribute**, not in source:
      ```lua
      ServerScriptService:SetAttribute('PlayerLoggerWebhookUrl', '<url>')
      ```
- [ ] `grep -rniE "(api[_-]?key|token|secret|password|webhook)" --include=*.lua`
      run over your copy, and **every hit explained**. (In the library the
      hits are the `Secret` rarity tier and opaque id tokens — not
      credentials.)
- [ ] Nothing in `.gitignore` is missing.

---

## 8. Behavioural verification

- [ ] `rojo build` succeeds.
- [ ] The place opens in Studio with **no errors in the Output window**.
- [ ] A player joins, and the profile loads.
- [ ] The profile **persists** — join, quit, rejoin, and the data is there.
- [ ] Money is a **decimal string** end to end. A number appearing in the
      wallet is a bug.
- [ ] A client **cannot** buy something it cannot afford, by sending a
      modified remote payload. (Try it.)
- [ ] The remote count matches `Remotes.Names` — 47 for the full library.

---

## 9. Tests

- [ ] The specs are copied and the test place builds.
- [ ] The test suite is **actually run** in Studio.
- [ ] You have read `Tests/README.md` and you know the source game's suite
      **has never been executed as committed** — see `MEMORY.md` §7.1. Fix
      the three known defects before trusting a green run.

---

## 10. Before you ship

- [ ] `stylua --check` passes on your copy.
- [ ] `selene` reports no **errors** (warnings are tolerable; the source
      game has 12).
- [ ] You have read `SECURITY_NOTES.md` §7 and completed its checklist.
- [ ] You have written a `README.md` for your fork, stating which systems
      you took, what you changed, and what you left out.
