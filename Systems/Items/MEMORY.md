# Items — engineering notes

## Purpose, in one line

A server-authoritative Gear Shop: it sells gear from a data catalog,
provisions the physical `Tool` into the player's inventory exactly once,
keeps exactly one bat equipped, and persists only the AutoBuy
preference and the Robux entitlement.

---

## How it actually works

### The central idea

> **The live `Tool` in the player's inventory is the ownership record.
> There is no second "unlocked" store that can disagree with what the
> player is actually holding.**

This is why the code has `hasLiveTool` in three places and reads the
session flag `ownedBy` in others — and why the two are not the same
thing:

| Concept | Source of truth | Where |
|---|---|---|
| "Does the UI show this as Owned?" | **live `Tool` presence** | `hasLiveTool(player, toolName)` |
| "Is this gear in the session ownership set?" | `ownedBy[userId][gearId]` | `isOwned(userId, gearId)` |
| "Should the shop let me buy it again?" | `ownedBy` **first**, then live `Tool` | `purchaseInner` |
| "Should auto-buy skip it?" | `ownedBy` | `OnPlayerReady` |
| "May I equip it?" | `ownedBy` (except `DefaultBat`) | `EquipGear` |

The split is deliberate: `ownedBy` is a *session* concept (it dies with
the server), while the UI's `Owned` flag must reflect reality *now*
(a tool may have been destroyed or dropped).

### The tables

```lua
ownedBy:    { [userId]: { [gearId]: true } }  -- session ownership
equippedBy: { [userId]: gearId }             -- session equipped choice
readyBy:    { [userId]: true }               -- join-once guard
busyBy:     { [userId]: true }               -- per-player purchase mutex
```

All four are plain module locals. `GearShopService` is `table.freeze`d
at the bottom of the file, so the tables are only reachable through
the API.

### The grant: `EnsureGearTool(player, gearId)`

```text
1. Validation.LivePlayer(player)?        no -> false
2. GearConfig.FindGear(gearId)?           no -> false + warn
3. resolveToolStatus(entry.ToolName)      -> { found = Tool?, class = string? }
     source == nil -> warn (missing OR wrong class) -> false
4. hasLiveTool(player, source.Name)?      yes -> watch it, return true
5. Clone the source Tool.
     gearClone.Name = source.Name
     gearClone.CanBeDropped = false
     Parent to Backpack, else Character, else Destroy + error('grant-nowhere')
     Assert gearClone.Parent is one of the two containers
6. Verify: hasLiveTool(player, source.Name)
     false -> warn -> return false
7. watchTool(...) and return true
```

Three details that matter:

- **`CanBeDropped = false`.** On death the `Tool` returns to the
  `Backpack` instead of dropping a `Workspace` copy. A dropped copy
  would look like a duplicate on the next ensure.
- **Both containers are checked** (`Backpack` **and** `Character`).
  An equipped `Tool` is parented to the Character, so checking only
  the Backpack would duplicate it on every ensure.
- **It never charges and never yields.** If neither container exists
  (no Backpack, no Character — a very early join), the grant fails
  loudly and the *caller* decides. The purchase path rolls back and
  refunds; the respawn path re-runs it on `CharacterAdded`.

`EnsureOwnedTools(player)` is a thin loop over `EnsureGearTool` for
every gear in `ownedBy`. It returns the number granted.

### The equip: `EquipGear(player, gearId)`

```text
1. LivePlayer? gearId a non-empty string?   no -> false
2. GearConfig.FindGear(gearId)?             no -> false
3. Ownership gate:
     gearId == DefaultBat  -> self-heal ownedBy[userId][gearId] = true
     otherwise not owned   -> log 'equip-rejected' -> false
4. Locate the tool in Character (held) and Backpack (stowed).
     Neither -> return WITHOUT touching anything.
        (equipping a missing bat must not strip the current one)
5. Single-equipped invariant:
     for every Tool child of Character whose Name ~= toolName:
         move it to the Backpack
6. If it was stowed (not held):
     humanoid.Health > 0 -> humanoid:EquipTool(stowed)
     else                -> stowed.Parent = character   (fallback)
7. Re-check: is the tool now a child of the Character?  -> equipped
8. Duplicate-bat cleanup:
     for each Tool child of the Backpack whose Name is a known BAT:
         if the name was already seen -> Destroy()
         else -> mark seen
     Ownership flags are NEVER touched. Non-bat Tools are never
     matched, moved, or destroyed.
9. equipped -> equippedBy[userId] = gearId; log; funnel 'FirstGearEquipped'
              (skipped for DefaultBat)
```

Two things to notice:

- **Step 8 only cleans up *bats*.** The "is this a bat?" test is
  `GearConfig.Combat.GetByToolName(toolName) ~= nil`. Coils and cloaks
  have no combat entry, so a duplicated `Speed Coil` is **not** cleaned
  up. This is deliberate — the cleanup must never touch unrelated
  gear.
- **`EquipGear` never grants.** If the tool is not in the inventory the
  call returns `false` and the player's current bat is left alone.

### The purchase: `Purchase(player, gearId, quiet?)`

`Purchase` is the validated wrapper; `purchaseInner` is the ordered
commit. The order is:

```text
VALIDATE
  already session-owned?      -> EnsureGearTool + EquipGear (top up),
                                 notify 'Gear_AlreadyOwned',
                                 return { success = false, error = 'already-owned' }
  live Tool present but no
  session flag?               -> adopt the flag, notify 'Gear_AlreadyOwned',
                                 return { success = false, error = 'already-owned' }
  entry.RobuxOnly?            -> notify 'Gear_RobuxOnly',
                                 return { success = false, error = 'robux-only' }
  GearConfig.IsLocked(rebirth,
  entry.RequiredRebirth)?     -> notify 'Gear_LockedRebirth',
                                 return { success = false, error = 'locked-rebirth' }
  tool asset missing?         -> notify 'Gear_ToolUnavailable',
                                 return { success = false, error = 'tool-missing' }
  economyServiceRef nil?      -> warn,
                                 return { success = false, error = 'service-not-ready' }

DEDUCT
  economyServiceRef.TrySpendMoney(userId, entry.Price, 'GearPurchase')
  result.Success ~= true:
     code == 'insufficient' -> notify 'Gear_InsufficientCash' with the
                                 RAW BigNumber shortfall string,
                                 return { success = false, error = 'insufficient-money' }
     otherwise              -> warn,
                                 return { success = false, error = 'debit-failed' }

COMMIT
  ownedBy[userId][gearId] = true

GRANT
  EnsureGearTool(player, gearId)   (pcall-guarded)

VERIFY
  granted == true AND hasLiveTool(player, entry.ToolName)
     no -> ownedBy[userId][gearId] = nil          <-- roll back the flag
           AddMoney(userId, entry.Price, 'GearRefund', { ApplyMultiplier = false })
           notify 'Gear_ToolUnavailable'
           return { success = false, error = 'grant-failed' }

SUCCESS
  notify 'Gear_Success'
  funnel 'FirstGearPurchased' (skipped for DefaultBat)
  EquipGear(player, gearId)     <-- best-effort, never fails the sale
  return { success = true }
```

**The refund is the load-bearing part.** The debit lands before the
grant, so a failed grant must undo both the session flag and the
money. `GearRefund` is passed `ApplyMultiplier = false` so the refund
is the exact price, not a multiplied amount.

**The order of the funnel steps is deliberate.** `FirstGearPurchased`
is logged *before* the equip so the Gear funnel reads
`Purchased(1) → Equipped(2)` in definition order.

**`Purchase` is serialised per player** by `busyBy`. The mutex is
cleared on **every** exit path, including the `pcall` failure path, so
it can never stick. A concurrent purchase gets
`{ success = false, error = 'in-progress' }` — it does not queue.

### The join flow: `OnPlayerReady(player)`

Guarded by `readyBy` — it runs **exactly once** per server session per
player.

```text
1. EnsureDefaultBat + EquipGear(DefaultBat)
   (the safe fallback while auto-buy resolves; it stays if auto-buy
    buys nothing)
2. NormalizeAutoBuy(profile data)
3. for each catalog entry in ORDER with GearAutoBuy[id] == true and not
   session-owned:
       Purchase(player, id, quiet = true)
       success -> attempted += 1
       failure -> Debug.Log 'autobuy skipped'
4. for each persisted OwnedRobuxGear[id]:
       if not session-owned:
           EnsureGearTool + rehydrate ownedBy[userId][id] = true
5. if attempted > 0 -> pushState(player)
```

Because the loop is in **catalog order** and each successful purchase
equips *that* bat, the **last affordable** auto-buy gear wins. The
catalog order is `SpeedCoil … HackerBat, GalaxyBat, DefaultBat`, so
the default bat (last) is not in the auto-buy path anyway.

`quiet = true` means **no toasts** — a fresh join is not the place for
a toast stack. An unaffordable auto-buy stays a preference only.

### The Robux path: `GrantRobuxGear(player, gearId)`

The **only** way a `RobuxOnly` gear can be granted. `Purchase` rejects
`RobuxOnly` entries with `'robux-only'` before any debit.

```text
1. LivePlayer?                       no -> false
2. GearConfig.FindGear(gearId)?      no -> false + warn
3. EnsureGearTool(player, gearId)    false -> false + warn
   ("asset missing?")   <-- the receipt must NOT be consumed
4. ownedBy[userId][gearId] = true    (the SAME table cash purchases
                                      commit to)
5. persist OwnedRobuxGear[gearId] = true in the profile
```

Step 4 is the important one: the Robux grant commits into the **same**
session ownership table as a cash purchase. Without it, equip,
respawn re-grant, and auto-buy recognition would all treat the Robux
bat as unowned.

### The respawn flow: `OnCharacterSpawned(player)`

```text
1. EnsureOwnedTools(player)
2. target = equippedBy[userId]
   if target is not a string or not session-owned:
       target = DefaultGearId()
       EnsureDefaultBat(player)
3. EquipGear(player, target)
```

The **session choice survives respawns**. Only a **fresh join** resets
to `DefaultBat`. `EquipGear` no-ops when the tool is already held, so
this never duplicates.

### The AutoBuy write: `SetAutoBuy(player, gearId, enabled)`

```text
1. LivePlayer?                       no -> { success = false, error = 'invalid-player' }
2. FindGear?                         no -> { success = false, error = 'invalid-gear' }
3. type(enabled) ~= 'boolean'        -> { success = false, error = 'invalid-value' }
   (the strings "true"/"false", numbers and nil are REJECTED, never
    coerced — the server owns the final boolean)
4. playerServiceRef nil?             -> { success = false, error = 'service-not-ready' }
5. write data.GearAutoBuy[gearId] = enabled  (pcall-guarded)
   failure -> { success = false, error = 'internal' }
6. pushState(player)
7. if enabled and not session-owned:
       Purchase(player, gearId, quiet = true)
       success -> pushState(player)
```

Enabling AutoBuy **immediately attempts a purchase**. Disabling never
interrupts an in-flight purchase.

### The two preview channels

The client can never read `ServerStorage`, so the server publishes two
things:

- **`ReplicatedStorage.GearShopPreviews`** — a folder of
  **script-stripped** clones of each gear `Tool`, named by `gearId`,
  published **once** at boot. The client renders them in a
  `ViewportFrame`. `Script` and `LocalScript` descendants are
  destroyed before publishing.
- **`PlayerGui…GearShop.ScrollingFrame.GearTemplate`** — a clone of the
  server-only `ServerStorage.Assets.Ui.GearShop.GearTemplate`,
  provisioned into the player's own GUI on every `OpenShop`. It is
  hidden and is the **row prototype**; the actual rows are separate
  `GearId`-stamped clones.

`EnsureRuntimeTemplate` treats an existing template that **already has
a `GearId` attribute** as stale and re-clones it. A prototype with no
`GearId` attribute is accepted as-is.

### The shop prompt

`wireShopPrompt` looks for `Workspace.Map.Shop.PromptPart`. If the
part exists but has no `ProximityPrompt`, it creates one from
`Prompts.GearShop` (`ActionText`, `HoldDuration`,
`MaxActivationDistance`, `RequiresLineOfSight`). The prompt's
`Triggered` event calls `OpenShop(player)`.

### The lifecycle trace

`watchTool` attaches `Equipped`, `Activated`, `Unequipped`,
`AncestryChanged`, `Destroying` to a granted clone, plus
`ChildAdded`/`ChildRemoved` on the Backpack and the Character, plus
`CharacterAdded` for respawns. Everything is filtered to known gear
`ToolName`s. It is **read + warn only** — it never mutates inventory.
The `AncestryChanged` / `Destroying` logs are how the source game
diagnosed "the bat vanished" bugs.

---

## Public API surface

```lua
-- Module
GearShopService.Init()
GearShopService.SetPlayerService(svc: any)
GearShopService.SetEconomyService(svc: any)

-- Queries
GearShopService.DefaultGearId(): string                                   -- 'DefaultBat'
GearShopService.GetEquippedGear(userId: number): string?
GearShopService.GetPlayerRebirth(userId: number): number
GearShopService.HasLiveTool(player: Player, toolName: string): boolean
GearShopService.ResolveTool(toolName: string): Tool?
GearShopService.ToolStatus(toolName: string): { found: Tool?, class: string? }
GearShopService.BuildState(player: Player): { [string]: any }?

-- Mutations
GearShopService.Purchase(player: Player, gearId: string, quiet: boolean?): { [string]: any }
GearShopService.SetAutoBuy(player: Player, gearId: string, enabled: boolean): { [string]: any }
GearShopService.GrantRobuxGear(player: Player, gearId: string): boolean
GearShopService.EquipGear(player: Player, gearId: string): boolean
GearShopService.EnsureGearTool(player: Player, gearId: string): boolean
GearShopService.EnsureOwnedTools(player: Player): number
GearShopService.EnsureDefaultBat(player: Player): boolean
GearShopService.EnsureRuntimeTemplate(player: Player): boolean
GearShopService.NormalizeAutoBuy(data: any): { [string]: boolean }?
GearShopService.NormalizeOwnedRobuxGear(data: any): { [string]: boolean }?

-- Lifecycle
GearShopService.OnPlayerReady(player: Player)
GearShopService.OnCharacterSpawned(player: Player)
GearShopService.OpenShop(player: Player)
GearShopService.ForgetPlayer(userId: number)
GearShopService._TestReset()
```

### Error strings returned by `Purchase` / `SetAutoBuy`

`'invalid-player'`, `'invalid-gear'`, `'invalid-value'`,
`'service-not-ready'`, `'in-progress'`, `'already-owned'`,
`'robux-only'`, `'locked-rebirth'`, `'tool-missing'`,
`'insufficient-money'`, `'debit-failed'`, `'grant-failed'`,
`'internal'`.

---

## Invariants the code enforces

1. **Exactly one bat is equipped.** Every other `Tool` in the
   Character is parked in the Backpack before the equip.
2. **A grant never duplicates.** `EnsureGearTool` checks both the
   Backpack and the Character and returns early if the tool is already
   there.
3. **A granted clone is never droppable.** `CanBeDropped = false`.
4. **A failed grant never reports success.** The session flag is rolled
   back and the money is refunded.
5. **A refund is the exact price.** `GearRefund` is passed
   `ApplyMultiplier = false`.
6. **`RobuxOnly` gear is never cash-purchasable.** The check happens
   before any debit.
7. **Money only moves through `EconomyService`.** Two reasons:
   `GearPurchase` and `GearRefund`.
8. **The purchase mutex never sticks.** It is cleared on every exit
   path, including the `pcall` failure path.
9. **Ownership flags are never touched by the physical cleanup.** Only
   surplus `Tool` instances are destroyed.
10. **The duplicate cleanup only matches bats** (names present in
    `GearConfig.Combat`). Coils and cloaks are never matched, moved or
    destroyed.
11. **AutoBuy is strictly boolean.** Non-boolean values are rejected,
    never coerced.
12. **`Normalize*` repairs, never resets.** An existing `true` survives;
    unknown keys survive; a missing known gear becomes `false`.
13. **The session equipped choice survives respawns.** Only a fresh
    join resets it to `DefaultBat`.
14. **`OnPlayerReady` runs once per session.** The `readyBy` guard is
    cleared on leave.
15. **`Init` is idempotent.** The `started` flag means a second call
    does nothing.

---

## Failure and edge-case behaviour

| Situation | Result |
|---|---|
| `Purchase` with a non-player | `{ success = false, error = 'invalid-player' }` |
| `Purchase` with an unknown gear id | `{ success = false, error = 'invalid-gear' }` + a `Gear_InvalidGear` toast |
| `Purchase` while another purchase is in flight | `{ success = false, error = 'in-progress' }` + a `Gear_Busy` toast |
| `Purchase` for a gear already session-owned | tops up the tool, equips it, `Gear_AlreadyOwned` toast, `{ success = false, error = 'already-owned' }` — **no double charge** |
| `Purchase` for a `RobuxOnly` gear | `{ success = false, error = 'robux-only' }` + a `Gear_RobuxOnly` toast, **no debit** |
| `Purchase` for a rebirth-gated gear the player has not reached | `{ success = false, error = 'locked-rebirth' }` + a `Gear_LockedRebirth` toast, **no debit** |
| `Purchase` with the `Tool` asset missing | `{ success = false, error = 'tool-missing' }` + a `Gear_ToolUnavailable` toast, **no debit** |
| `Purchase` with `EconomyService` unwired | `{ success = false, error = 'service-not-ready' }` + a warn |
| `Purchase` with insufficient cash | `{ success = false, error = 'insufficient-money' }` + a `Gear_InsufficientCash` toast carrying the **raw** BigNumber shortfall |
| `Purchase` where the debit fails for another reason | `{ success = false, error = 'debit-failed' }` + a warn |
| `Purchase` where the grant throws after the debit | the session flag is rolled back, the money is refunded, `{ success = false, error = 'grant-failed' }` |
| `Purchase` where `purchaseInner` throws | `{ success = false, error = 'internal' }` + a warn; the mutex is still cleared |
| `SetAutoBuy` with a non-boolean `enabled` | `{ success = false, error = 'invalid-value' }` — **never coerced** |
| `SetAutoBuy` with `PlayerService` unwired | `{ success = false, error = 'service-not-ready' }` |
| `SetAutoBuy` where the profile write throws | `{ success = false, error = 'internal' }` |
| `GrantRobuxGear` with a missing `Tool` asset | `false` + a warn — the receipt must be retried, never consumed |
| `GrantRobuxGear` for an unknown gear id | `false` + a warn |
| `GrantRobuxGear` twice | `true` both times; the second is a no-op (idempotent) |
| `EquipGear` for a gear that is not session-owned | `false` + an `equip-rejected` log (`reason=not-owned`) |
| `EquipGear` for a gear whose tool is not in the inventory | `false` + an `equip-deferred` log (`reason=no-character-yet`); the current bat is **not** stripped |
| `EquipGear` with no `Humanoid` (or a dead one) | the tool is parented to the Character directly as a fallback; `CharacterAdded` re-runs the path |
| `EquipGear` on a `Tool` already held | idempotent — no duplicate, `equipped = true` |
| `EnsureGearTool` with no Backpack and no Character | `false` + a warn; the clone is destroyed (`error('grant-nowhere')`) |
| `EnsureGearTool` where the source exists but is not a `Tool` | `false` + a "source is not a Tool" warn naming the actual class |
| `EnsureOwnedTools` without a live player | `0` (safe no-op) |
| `BuildState` for a non-player | `nil` |
| `BuildState` with `EconomyService` unwired | `Money = '0'` |
| `BuildState` with `RebirthService` unwired | `Rebirth = 0` (fail-closed) |
| `EnsureRuntimeTemplate` with no `PlayerGui` GearShop | `false` + a warn |
| `EnsureRuntimeTemplate` with no `ScrollingFrame` | `false` + a warn |
| `EnsureRuntimeTemplate` with no server-side `GearTemplate` | `false` + an ERROR warn |
| `Init` with a missing `GearShopAction` remote | a warn; the service still initialises |
| `Init` with a missing `Workspace.Map.Shop.PromptPart` | a warn; the shop has no world entry but the GUI path still works |
| `Init` with a `Tool` asset of the wrong class | `GearConfig.ValidateLive()` reports it as a config issue warn |
| `ForgetPlayer` with a non-number | no-op |

---

## Gotchas that would bite you

1. **Cash purchases are not persisted.** The session ownership dies
   with the server. A player who buys a `Silver Bat` and rejoins is
   back to `DefaultBat`. Only AutoBuy and the Robux entitlement
   survive.
2. **The UI's `Owned` flag is NOT the session flag.** It is a live
   `Tool` probe. `BuildState` sets `Owned = hasLiveTool(...)`, so a
   player with a provisioned tool but a cleared session flag still sees
   "Owned" — and the purchase path then takes the *second* branch
   (adopt the flag, report already-owned).
3. **The `ToolName` must match the `Tool` instance name exactly.**
   `resolveToolStatus` and `hasLiveTool` both use `FindFirstChild`
   with the exact string. A rename breaks it silently.
4. **`Prompts.GearShop` lives in the Carry system's config**, not in
   this one. `GearShopService` requires
   `ReplicatedStorage.Config.World.Prompts` for the shop prompt only.
5. **`GearConfig` lives in the Combat system.**
   `ReplicatedStorage/Config/Economy/Gear.lua` holds both the shop
   catalog and the per-bat combat tuning. Splitting it means the shop
   and combat must agree on `ToolName`.
6. **`GetPlayerRebirth` fails closed to `0`** and it `pcall`s a lazy
   `require` of `RebirthService` to break a require cycle. If
   `RebirthService` is unwired, every rebirth-gated gear is locked and
   the failure is invisible.
7. **`SetAutoBuy` requires `PlayerService`** but `SetAutoBuy` is the
   only write path that does — `Purchase` does not need it.
8. **`EquipGear` self-heals `DefaultBat` ownership** but nothing else.
   Any other gear must already be in `ownedBy`.
9. **The duplicate cleanup only handles bats.** A duplicated coil is
   not cleaned up.
10. **`EnsureRuntimeTemplate` writes into the client's `PlayerGui`.**
    The server mutating a client GUI is unusual but necessary here,
    because the authoritative template lives in `ServerStorage`.
11. **The trace is always on and always warns.** Every grant, equip,
    unequip and activation emits `Debug.Warn` lines. In a production
    game you probably want that behind a debug flag.
12. **`Init` is guarded by `started`.** A second `Init` will not
    re-publish the previews or re-wire the prompt. If you tear down the
    remotes you must reset that flag manually (there is no public
    setter — `_TestReset` does **not** reset `started`).
13. **`OnPlayerReady` must run after the profile is loaded.** Called
    too early, `autoBuyOf(data)` sees no profile, the auto-buy loop
    does nothing, and the `readyBy` guard means it will **not** retry.
14. **`ForgetPlayer` does not disconnect the trace connections' scope
    for `equippedBy` re-entry** — it does (`untrackPlayer` is called),
    but note it does **not** destroy any granted `Tool`. The tools stay
    in the player's inventory until the player leaves.
15. **The purchase funnel excludes `DefaultBat`.** `DefaultBat` is
    free equipment, never a purchase or equip milestone.

---

## What to change to reuse it

**Keep (Grade A):**

- The "live `Tool` presence is ownership" rule and the separation of
  `Owned` (live probe) from `ownedBy` (session flag).
- `EnsureGearTool`'s idempotence: check both containers, clone with
  `CanBeDropped = false`, verify after parenting, never charge, never
  yield.
- The purchase order VALIDATE → DEDUCT → COMMIT → GRANT → VERIFY, and
  the rollback-plus-refund on grant failure.
- The single-equipped invariant and the "cleanup only destroys surplus
  physical instances, never ownership flags" rule.
- The per-player purchase mutex that cannot stick.
- `Normalize*` repairing rather than resetting.
- The two preview channels (script-stripped `GearShopPreviews` +
  the runtime `GearTemplate` provisioned into the PlayerGui).
- The `RobuxOnly` rejection in the cash path, and the Robux grant
  committing into the **same** session ownership table.

**Change (Grade B):**

- The 12-entry catalog, its prices, and the rebirth ladder.
- `DefaultBat` as the free starting tier — keep the idea, rename it.
- The `ServerStorage.Assets.Ui.GearShop.Tools/<ToolName>` asset layout.
- `Workspace.Map.Shop.PromptPart` and the `StarterGui` GearShop
  structure.
- The `GearAutoBuy` / `OwnedRobuxGear` profile field names.
- The `GearPurchase` / `GearRefund` transaction reasons.

**Change if your game needs it:**

- **Persist cash purchases.** Add an `OwnedGear` profile set, normalise
  it like `NormalizeOwnedRobuxGear`, and re-grant from it in
  `OnPlayerReady`. `EnsureGearTool` is already idempotent.
- **Persist the equipped choice** across joins.
- **Extend the duplicate cleanup** to non-bat gear (today it only
  matches `GearConfig.Combat` names).

**Delete outright if unused:**

- The whole lifecycle-trace section (`watchTool`, `watchBackpack`,
  `watchCharacterForever`, `watchCharacterContainer`,
  `lifecycleSnapshot`, `dumpToolValidity`) — it is pure diagnostics
  and is always on.
- `GrantRobuxGear` and the `RobuxOnly` flag, if you have no Robux
  products.
- `EnsureRuntimeTemplate` and the `GearTemplate` asset, if your client
  builds its rows from the config instead of a Studio template.
