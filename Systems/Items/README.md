# Items

Owns the **Gear Shop**: the catalog-driven purchase of gear (bats,
coils, cloaks), the **session ownership** of what a player has bought,
the **grant** of the physical `Tool` into their inventory, the
**equip** invariant (exactly one bat in hand), and the **AutoBuy**
preference.

**Portability:** Grade **A — portable core** for the ownership /
grant / equip / purchase pipeline (the session store, the idempotent
grant, the single-equipped invariant, the validate → deduct → grant →
verify discipline with a refund rollback, and the change-only "Owned"
flag derived from live `Tool` presence). Grade **B — game-specific
adapter** for the catalog itself (the 12 gear entries, their prices,
the rebirth unlock ladder, the Robux-exclusive `GalaxyBat` product),
the `ServerStorage.Assets.Ui.GearShop.Tools/<ToolName>` asset layout,
and the `DefaultBat` free-tier policy. The **A** parts are
`GearShopService`'s grant/equip/purchase logic and the session tables;
the **B** parts are `ReplicatedStorage/Config/Economy/Gear.lua` (owned
by the **Combat** system) and the Studio `Tool` assets.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

The Gear Shop lets a player spend cash on gear. The design principle it
is built around is:

> **The physical `Tool` in the player's inventory IS the ownership
> record. There is no separate "unlocked" store that can disagree with
> what the player is actually holding.**

Concretely:

- **The catalog is data.** `ReplicatedStorage/Config/Economy/Gear.lua`
  lists 12 gear entries. Each entry has a stable `Id`, a display
  `Name`, a `Price` (a BigNumber decimal **string**), a
  `Description`, a `RequiredRebirth`, a `ToolName` (the EXACT `Tool`
  instance name under `ServerStorage`), and an optional `RobuxOnly`
  flag. The order in the list **is** the shop display order.
- **Ownership is session-only.** `ownedBy[userId][gearId] = true` lives
  in memory and is discarded when the player leaves. Nothing about
  purchases is persisted — except two things: the **AutoBuy**
  preference (`GearAutoBuy` in the profile) and the **Robux
  entitlement** (`OwnedRobuxGear` in the profile).
- **The grant is idempotent.** `EnsureGearTool` looks for a live `Tool`
  with the exact `ToolName` in the player's `Backpack` **or**
  `Character`. If found → done. If not → clone the authored asset,
  set `CanBeDropped = false`, parent it to the `Backpack` (or the
  `Character` if there is no Backpack), then **verify** it is present.
  It never charges and never duplicates.
- **The equip invariant is "exactly one bat".** `EquipGear` parks every
  other live `Tool` back in the `Backpack` before equipping, then
  destroys surplus duplicate bats in the Backpack. Ownership flags are
  never touched by the cleanup.
- **The purchase pipeline is ordered.** VALIDATE → DEDUCT (atomic, via
  `EconomyService.TrySpendMoney`) → COMMIT session ownership → GRANT
  the actual `Tool` → VERIFY it exists. If the grant or the
  verification fails, the session flag is rolled back and the money is
  refunded (`GearRefund`, with `ApplyMultiplier = false`). A failed
  grant **never** reports success.
- **`DefaultBat` is free and permanent.** Every player is granted and
  equipped `DefaultBat` on join. It costs nothing, needs no unlock, and
  is never removed from ownership when other bats are bought.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `GearShopService.Init()` | Server | Idempotent (`started` flag). Publishes previews, wires the shop prompt, connects `GearShopAction`. |
| `GearShopService.SetPlayerService(svc)` | Server | Injects the profile accessor (`GetPlayerData`). |
| `GearShopService.SetEconomyService(svc)` | Server | Injects the money service (`GetMoney`, `TrySpendMoney`, `AddMoney`). |
| `GearShopService.OnPlayerReady(player)` | Server | **Join-once** flow: default bat → auto-buy attempts → Robux re-grant. |
| `GearShopService.OnCharacterSpawned(player)` | Server | Respawn: re-grant owned tools, re-equip the session choice. |
| `GearShopService.Purchase(player, gearId, quiet?)` | Server | The validated purchase entry point. Returns `{ success, error? }`. |
| `GearShopService.SetAutoBuy(player, gearId, enabled)` | Server | Strict-boolean preference write. Returns `{ success, error? }`. |
| `GearShopService.GrantRobuxGear(player, gearId)` | Server | The **only** path that grants a `RobuxOnly` gear. Returns `boolean`. |
| `GearShopService.EquipGear(player, gearId)` | Server | The one equip path. Returns `boolean`. |
| `GearShopService.EnsureGearTool(player, gearId)` | Server | Idempotent single-gear grant. Returns `boolean`. |
| `GearShopService.EnsureOwnedTools(player)` | Server | Re-grant every session-owned gear. Returns the count granted. |
| `GearShopService.EnsureDefaultBat(player)` | Server | Grant the free starting bat. Returns `boolean`. |
| `GearShopService.EnsureRuntimeTemplate(player)` | Server | Clone the server-only row template into the player's GUI. |
| `GearShopService.BuildState(player)` | Server | The shop snapshot table, or `nil` for a non-player. |
| `GearShopService.OpenShop(player)` | Server | Provision the template and push the state with `Show = true`. |
| `GearShopService.ForgetPlayer(userId)` | Server | Clear all session state for a leaving player. |
| `GearShopService.HasLiveTool(player, toolName)` | Server | Does a live `Tool` with that exact name exist? |
| `GearShopService.ResolveTool(toolName)` | Server | The authored `Tool` asset, or `nil`. |
| `GearShopService.ToolStatus(toolName)` | Server | `{ found = Tool?, class = string? }` — distinguishes "missing" from "wrong class". |
| `GearShopService.GetEquippedGear(userId)` | Server | The session-equipped gear id, or `nil`. |
| `GearShopService.DefaultGearId()` | Server | `'DefaultBat'`. |
| `GearShopService.GetPlayerRebirth(userId)` | Server | Live rebirth count, fail-closed to `0`. |
| `GearShopService.NormalizeAutoBuy(data)` | Server | Repairs the profile's `GearAutoBuy` table. |
| `GearShopService.NormalizeOwnedRobuxGear(data)` | Server | Repairs the profile's `OwnedRobuxGear` table. |
| `GearShopService._TestReset()` | Server | Test seam — clears every session table. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/GearShop/GearShopService.lua` | `ServerScriptService.GearShop.GearShopService` | The whole system: catalog consumption, session ownership, grants, equip, purchase, auto-buy, previews, prompt wiring. |

**There is no `Config.lua` in this folder, and there is no config
module in this system's `Source` tree.** The gear catalog and its
balance live in `ReplicatedStorage/Config/Economy/Gear.lua`, which is
owned by the **Combat** system (it also holds the per-bat combat
tuning). See [Configuration](#configuration).

---

## Configuration

This system **does not own a config module.** Its tunables live in
**other systems'** config trees:

| Value | Owned by | Roblox path | Default |
|---|---|---|---|
| The 12-entry gear catalog (`Id`, `Name`, `Price`, `Description`, `RequiredRebirth`, `ToolName`, `RobuxOnly`) | **Combat** | `ReplicatedStorage/Config/Economy/Gear.lua` | see the table below |
| `Gear.Combat` — per-bat swing cooldown, hitbox, knockback, ragdoll | **Combat** | `ReplicatedStorage/Config/Economy/Gear.lua` | 8 bat entries |
| `Gear.Viewport` — the shop preview framing | **Combat** | `ReplicatedStorage/Config/Economy/Gear.lua` | `DistanceFactor = 1.4`, `MinDistance = 2`, `Direction = Vector3.new(1, 0.6, 1.6)` |
| `Prompts.GearShop` — the shop `ProximityPrompt` (action text, hold, distance, line-of-sight) | **Carry** | `ReplicatedStorage/Config/World/Prompts.lua` | — |
| `TransactionReason.GearPurchase` / `.GearRefund` | **Shared** | `ReplicatedStorage/Types/TransactionReason.lua` | — |

### The shipped catalog (as of extraction)

| # | `Id` | `Name` | `Price` | `RequiredRebirth` | `ToolName` | Notes |
|---|---|---|---|---|---|---|
| 1 | `SpeedCoil` | Speed Coil | `500` | 0 | `Speed Coil` | |
| 2 | `SilverBat` | Silver Bat | `1000` | 0 | `Silver Bat` | |
| 3 | `GravityCoil` | Gravity Coil | `5000` | 1 | `Gravity Coil` | |
| 4 | `GoldBat` | Gold Bat | `7500` | 1 | `Gold Bat` | |
| 5 | `CoilCombo` | Coil Combo | `20000` | 2 | `Coil Combo` | |
| 6 | `DiamondBat` | Diamond Bat | `25000` | 2 | `Diamond Bat` | |
| 7 | `ObsidianBat` | Obsidian Bat | `30000` | 3 | `Obsidian Bat` | |
| 8 | `CrystalBat` | Crystal Bat | `50000` | 4 | `Crystal Bat` | |
| 9 | `InvisibleCloak` | Invisible Cloak | `55000` | 4 | `Invisible Cloak` | |
| 10 | `HackerBat` | Hacker Bat | `70000` | 5 | `Hacker Bat` | |
| 11 | `GalaxyBat` | Galaxy Bat | `0` | 0 | `Galaxy Bat` | `RobuxOnly = true` — **never cash-purchasable** |
| 12 | `DefaultBat` | Default Bat | `0` | 0 | `Default Bat` | The free starting bat; **last** in the list |

Every `Description` in the shipped catalog begins with `PLACEHOLDER:`
— the descriptions are placeholders awaiting a balance pass. The
`Price` values are likewise initial values, not final balance.

**The catalog order is load-bearing in two places:** it is the shop
display order, and it is the order in which `OnPlayerReady` attempts
auto-buy purchases — so the **last affordable** auto-buy gear wins the
equip.

---

## Dependencies

See `Dependencies.md` for the exact require paths, remotes, and profile
fields. The load-bearing ones:

- `ReplicatedStorage.Config.Economy.Gear` — the catalog (Combat-owned).
- `ReplicatedStorage.Utility.Remotes` — `GearShopAction`,
  `GearShopState`, `GearShopResult`.
- `ReplicatedStorage.Utility.BigNumber` — price formatting and the
  insufficient-cash shortfall.
- `ServerScriptService.Base.NotificationService` — the toasts.
- `ServerScriptService.FunnelService` — the `FirstGearPurchased` /
  `FirstGearEquipped` analytics.

**Injected dependencies (not required):** `PlayerService` (via
`SetPlayerService`) and `EconomyService` (via `SetEconomyService`).
Both are injected to keep the module require-cycle-free. The service
degrades gracefully if either is missing — but a purchase without
`EconomyService` fails with `'service-not-ready'`.

---

## Initialization Order

```text
1.  Remotes folder created + Remotes.SetRemotes(folder)
2.  GearShopService.SetPlayerService(PlayerService)
3.  GearShopService.SetEconomyService(EconomyService)
4.  GearShopService.Init()
        -> GearConfig.ValidateLive()  (config issues are warns)
        -> publishPreviews()          (ReplicatedStorage.GearShopPreviews)
        -> wireShopPrompt()           (Workspace.Map.Shop.PromptPart)
        -> connect GearShopAction.OnServerEvent
```

Per player:

```text
Player joins, profile loaded (MarkLoaded)
  -> GearShopService.OnPlayerReady(player)
        1. EnsureDefaultBat + EquipGear(DefaultBat)
        2. for each gear with GearAutoBuy[id] == true and not owned:
              Purchase(player, id, quiet = true)
        3. for each persisted OwnedRobuxGear[id]:
              EnsureGearTool + rehydrate the session flag

Character spawns (respawn)
  -> GearShopService.OnCharacterSpawned(player)
        1. EnsureOwnedTools(player)
        2. EquipGear(session choice, or DefaultBat)

Player leaves
  -> GearShopService.ForgetPlayer(userId)
```

`SetEconomyService` must come before `Init()` **if** you want the
`Init` validation to be meaningful; functionally the service only
needs it before the first `Purchase`.

---

## Data

### Session (never persisted)

| Table | Shape | Meaning |
|---|---|---|
| `ownedBy` | `{ [userId]: { [gearId]: true } }` | Which gears this player owns **this session**. |
| `equippedBy` | `{ [userId]: gearId }` | Which gear is equipped. Exactly one. |
| `readyBy` | `{ [userId]: true }` | Join-once guard for `OnPlayerReady`. |
| `busyBy` | `{ [userId]: true }` | Per-player purchase mutex (spam-click guard). |

### Profile fields (persisted)

| Field | Type | Written by | Read by |
|---|---|---|---|
| `GearAutoBuy` | `{ [gearId]: boolean }` | `SetAutoBuy`, `NormalizeAutoBuy` | `BuildState`, `OnPlayerReady` |
| `OwnedRobuxGear` | `{ [gearId]: true }` | `GrantRobuxGear`, `NormalizeOwnedRobuxGear` | `OnPlayerReady` (re-grant) |

Both tables are **repaired**, never reset: `NormalizeAutoBuy` adds an
explicit `false` for every known gear that is missing, and never
resets an existing `true`. Unknown keys are preserved.

### Money

Money moves only through `EconomyService.TrySpendMoney` /
`AddMoney`, with the reasons `GearPurchase` and `GearRefund`. Prices
are BigNumber **decimal strings**, never numbers.

### The shop snapshot (`GearShopState` payload)

```lua
{
  Money = '1234',            -- BigNumber string
  MoneyText = '$1,234',      -- formatted
  Rebirth = 2,               -- number
  Show = true,               -- only on OpenShop
  Gears = {
    {
      Id = 'SilverBat',
      Name = 'Silver Bat',
      Description = '...',
      Price = '1000',
      PriceText = '$1,000',
      RequiredRebirth = 0,
      ToolName = 'Silver Bat',
      Locked = false,
      Owned = false,
      AutoBuy = false,
    }
  },
}
```

**`Owned` is derived from live `Tool` presence only** — never from the
session flag and never from persisted data. A player who rejoins with
no provisioned `Tool` sees the price again, not "Owned".

---

## Known Limitations

- **Ownership is session-only.** Buying a `Silver Bat` does **not**
  persist. On a fresh join the player is back to `DefaultBat` (plus
  whatever AutoBuy re-buys, plus persisted Robux entitlements). This
  is a deliberate design choice in the source game, but in a new game
  it is almost certainly wrong — persist a `OwnedGear` set.
- **The Robux entitlement set is persisted but the cash purchases are
  not.** The asymmetry is deliberate (a receipt must survive a
  rejoin), but it means the two purchase paths have different
  persistence semantics in the same UI.
- **`GearShopService` never persists the equipped choice.** A fresh
  join always starts on `DefaultBat`, then AutoBuy may replace it.
  Within the same server session the choice survives respawns.
- **`GrantRobuxGear` is not transactional with the receipt.** It
  returns `false` when the `Tool` asset is missing so the receipt can
  be retried, but the caller (the Shop system) owns that retry. If
  the Shop system does not retry, the purchase is consumed without a
  grant.
- **A missing `Tool` asset is fatal to that gear only.** Purchases of
  it fail with `'tool-missing'` before any debit. Auto-buy for it
  fails silently (quiet mode).
- **`GetPlayerRebirth` fails closed to `0`.** If `RebirthService` is
  missing or unwired, every rebirth-gated gear is locked. It is
  required lazily inside a `pcall`, so the require cycle is broken.
- **The `ServerStorage` asset layout is hard-coded**:
  `Assets.Ui.GearShop.Tools.<ToolName>` and
  `Assets.Ui.GearShop.GearTemplate`. The `ToolName` must match the
  instance name **exactly**.
- **`hasLiveTool` matches on exact `Tool.Name`.** Renaming a `Tool`
  instance at runtime breaks ownership detection silently.
- **The `Tool` lifecycle trace is always on.** The
  `GearToolLifecycle` / `[ToolTrace]` diagnostics emit a `Debug.Warn`
  on every grant, equip, unequip, activation, ancestry change, and
  backpack add/remove. It is **read-only** (it never mutates
  inventory), but it is noisy. In a new game you may want to gate it.
- **`EquipGear` can only equip a `Tool` that already exists** in the
  player's Backpack or Character. It never grants. If the tool is
  missing it returns `false` and leaves the currently equipped bat
  alone (it does **not** strip it).
- **`EquipGear` self-heals `DefaultBat` ownership** — equipping
  `DefaultBat` works even if the session flag was cleared. Any other
  gear must already be session-owned.
- **The duplicate-bat cleanup only matches names in
  `GearConfig.Combat`.** Coils and cloaks are never matched, moved, or
  destroyed by it, so a duplicated `Speed Coil` is **not** cleaned up.
- **`OnPlayerReady` runs once per server session.** It does not
  re-run on a respawn (that is `OnCharacterSpawned`'s job), and it
  does not re-run if the profile finishes loading late — the caller
  must invoke it after `MarkLoaded`.
- **`Purchase` serialises per player** with the `busyBy` mutex. A
  concurrent purchase returns `{ success = false, error = 'in-progress' }`
  rather than queueing.
- **`SetAutoBuy` with `enabled = true` immediately attempts a
  purchase** (quietly). With `enabled = false` it never interrupts an
  in-flight purchase.
- **`Init()` is guarded by a `started` flag.** Calling it twice does
  nothing the second time — it will **not** re-publish previews or
  re-wire the prompt.

---

## Testing

`Tests/GearShop.spec.lua` — 30 cases across two `describe` blocks:

- **Catalog rules** (headless-safe): twelve gears with `DefaultBat`
  last and a stable order; `DefaultBat` is free, unlocked and
  combat-tuned weakest; `FindGear` resolves by stable `Id` and **not**
  by display `Name`; `IsLocked` compares rebirth fail-closed; the live
  catalog validates; `ValidateList` rejects duplicates, bad fields and
  missing tools and flags a wrong-class tool distinctly.
- **Service rules**: the service loads and resets cleanly;
  `NormalizeAutoBuy` defaults every gear to false, preserves `true`,
  and adds future gears; `SetAutoBuy` rejects non-players and
  non-boolean values; `EnsureOwnedTools` is a safe no-op without a live
  player; the grant is idempotent; the `GearRefund` reason exists.
- **BatSystem** (join / equip / isolation): join grants and equips
  `DefaultBat` with no purchase; a manual purchase equips **that exact**
  bat, never another; respawn re-equips the session bat without
  duplicating; the equipped choice never leaks across players and leave
  clears the session; `OnPlayerReady` is join-once (default first,
  auto-buy upgrades after); a replacement parks the old bat (never two
  equipped, never duplicates); equipping a missing bat never strips the
  current one; the Galaxy Bat receipt composition (grant persists, equip
  swaps, respawn restores); a rejoin rehydrates the persisted Robux
  entitlement into session ownership; `GalaxyBat` is a normal
  combat-catalog bat; `Default → Galaxy → Default` and
  `Silver → Galaxy → Silver` keep one active bat with ownership intact;
  a repeated equip of the same bat is idempotent; the equip cleans
  duplicate physical bats without touching ownership or non-bats; two
  players keep fully isolated bat state; a respawn preserves an
  equipped Galaxy Bat without duplicating; the shop snapshot
  recognizes a Robux-granted `GalaxyBat` as owned.

The spec requires the shared `Tests/_Helpers.lua` and still requires
**Roblox Studio**. See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Decide whether purchases persist.** The shipped model does not
   persist cash purchases. If your game should, add a
   `OwnedGear: { [gearId]: true }` profile field, normalise it the way
   `NormalizeOwnedRobuxGear` does, and change
   `OnPlayerReady` to re-grant from it. `EnsureGearTool` is already
   idempotent — the re-grant is one line.
2. **Move the catalog into this system** if you want the shop to be
   self-contained. Copy `ReplicatedStorage/Config/Economy/Gear.lua` to
   `ReplicatedStorage/Config/Economy/Gear.lua` in your tree (it is
   already there — you just need to know that the **Combat** system
   also reads `Gear.Combat` from the same file). If you split it, the
   combat tuning and the shop catalog must agree on `ToolName`.
3. **Author one `Tool` asset per catalog entry** at
   `ServerStorage.Assets.Ui.GearShop.Tools/<ToolName>`, where
   `<ToolName>` matches the entry's `ToolName` **exactly**. A `Tool`
   with `RequiresHandle = true` needs a `Handle` child that is a
   `BasePart` — the trace dump reports `handle=missing` otherwise, and
   the player can hold it but never properly equip it.
4. **Author the shop row template** at
   `ServerStorage.Assets.Ui.GearShop.GearTemplate`. The server clones
   it into the player's `PlayerGui` as `GearShop.ScrollingFrame.GearTemplate`
   (hidden). Rows are separate `GearId`-stamped clones. The template
   must have **no `GearId` attribute** — the server treats a template
   that already has one as stale and re-clones it.
5. **Build the client GUI** in `StarterGui` with a `GearShop` folder
   containing a `ScrollingFrame`. The server finds it by
   `PlayerGui:FindFirstChild('GearShop', true)` and then
   `:FindFirstChild('ScrollingFrame', true)`.
6. **Wire the world prompt.** `Workspace.Map.Shop.PromptPart` with a
   `ProximityPrompt`. If the prompt does not exist, the server creates
   one from `Prompts.GearShop`. `OpenShop` is what fires.
7. **Inject your services:**
   ```lua
   GearShopService.SetPlayerService(PlayerService)
   GearShopService.SetEconomyService(EconomyService)
   GearShopService.Init()
   ```
   Both injected services only need `GetPlayerData` and
   `GetMoney` / `TrySpendMoney` / `AddMoney` respectively.
8. **Call `OnPlayerReady` after the profile is loaded** (post
   `MarkLoaded`) and `OnCharacterSpawned` on every `CharacterAdded`.
   Call `ForgetPlayer` on `PlayerRemoving`.
9. **Add a `GearShopAction` remote** with the payload
   `{ Action: 'Purchase' | 'Equip' | 'SetAutoBuy', GearId: string,
   Enabled: boolean? }` and push `GearShopState` / `GearShopResult`
   from the server. The server ignores any action it does not
   recognise.
10. **Keep the "live `Tool` presence is ownership" rule** or change it
    deliberately. If you add a persisted ownership store, make the UI's
    `Owned` flag read from the *store* and keep the grant path
    idempotent — but be aware that the shipped code's `Owned` flag is
    a live-`Tool` probe and several paths (the already-owned branch,
    the Robux re-grant) depend on that.
