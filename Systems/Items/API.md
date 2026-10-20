# Items — API Reference

Every public function of every module in the Items system. The system
has exactly **one** module: `ServerScriptService.GearShop.GearShopService`.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[Dependencies.md](Dependencies.md) · [Setup.md](Setup.md)

**Failure-mode convention.** No function in this module **throws**. Every
error path returns a value:

- `Purchase` / `SetAutoBuy` → `{ success = false, error = '<string>' }`.
- The grant / equip / Robux functions → `false`.
- `BuildState` → `nil` for a non-player.

Internal calls that could fail are `pcall`-guarded and logged.

---

## `ServerScriptService.GearShop.GearShopService`

### `GearShopService.Init()`

Initialises the service: validates the config, publishes the previews,
wires the shop prompt, and connects the action remote.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none. Every sub-step is `pcall`-guarded and
  warns on failure:
  - `GearConfig.ValidateLive()` issues → warned as
    `'[GearShop] Config issue: <issue>'`.
  - Preview publish failure → `'[GearShop] Preview publish failed: ...'`.
  - Prompt wiring failure → `'[GearShop] PromptPart missing ...'` or
    `'[GearShop] Shop prompt wiring failed: ...'`.
  - Action remote missing → `'[GearShop] Action remote wiring failed: ...'`
    (it waits up to 10 seconds for `GearShopAction`).
- **Idempotency:** guarded by a `started` flag. A second call does
  **nothing** — it will not re-publish the previews or re-wire the
  prompt. There is no public way to reset `started`.

---

### `GearShopService.SetPlayerService(svc)`

Injects the profile accessor.

- **Parameters:** `svc: any` — must provide
  `GetPlayerData(userId: number) -> table?`.
- **Returns:** nothing.
- **Failure modes:** none. Passing `nil` un-wires it; the service
  degrades gracefully (`SetAutoBuy` then returns
  `error = 'service-not-ready'`).

---

### `GearShopService.SetEconomyService(svc)`

Injects the money service.

- **Parameters:** `svc: any` — must provide
  `GetMoney(userId: number) -> string`,
  `TrySpendMoney(userId: number, amount: string, reason: string) -> { Success: boolean, Code?: string }`,
  and `AddMoney(userId: number, amount: string, reason: string, opts?: table)`.
- **Returns:** nothing.
- **Failure modes:** none. Without it, `BuildState` reports
  `Money = '0'` and `Purchase` fails with
  `error = 'service-not-ready'`.

---

### `GearShopService.DefaultGearId()`

- **Parameters:** none.
- **Returns:** `string` — always `'DefaultBat'`.
- **Failure modes:** none.

---

### `GearShopService.GetEquippedGear(userId)`

- **Parameters:** `userId: number`.
- **Returns:** `string?` — the session-equipped gear id, or `nil`.
- **Failure modes:** a non-number `userId` → `nil`.

---

### `GearShopService.GetPlayerRebirth(userId)`

The live rebirth count, used as the gear unlock ladder.

- **Parameters:** `userId: number`.
- **Returns:** `number` — the player's completed rebirth count.
- **Failure modes:** **fails closed to `0`.** `RebirthService` is
  required lazily inside a `pcall`; if the require fails, the service
  is unwired, or the returned value is not a non-negative integer, the
  result is `0` — which **locks every rebirth-gated gear**. The failure
  is silent.

---

### `GearShopService.HasLiveTool(player, toolName)`

Does a live `Tool` with that exact name exist in the player's
`Backpack` **or** `Character`?

- **Parameters:** `player: Player`, `toolName: string`.
- **Returns:** `boolean`.
- **Failure modes:** none. A non-`Player` argument, an empty
  `toolName`, or an exception inside the scan → `false`. The match is
  on the **exact** `Tool.Name`.

---

### `GearShopService.ResolveTool(toolName)`

- **Parameters:** `toolName: string`.
- **Returns:** `Tool?` — the authored asset at
  `ServerStorage.Assets.Ui.GearShop.Tools.<toolName>`.
- **Failure modes:** a non-string or empty name → `nil`. A missing
  asset → `nil`. An asset that exists but is **not** a `Tool` → `nil`
  (use `ToolStatus` to distinguish the two cases).

---

### `GearShopService.ToolStatus(toolName)`

- **Parameters:** `toolName: string`.
- **Returns:** `{ found: Tool?, class: string? }`.
  - `found` is the `Tool` when the asset is a `Tool`.
  - `class` is the actual `ClassName` when an `Instance` exists under
    the exact name but is **not** a `Tool`.
  - Both are `nil` when the asset is missing (or the name is invalid).
- **Failure modes:** none.

---

### `GearShopService.BuildState(player)`

The shop snapshot.

- **Parameters:** `player: Player`.
- **Returns:** `{ [string]: any }?` — `nil` for a non-player.
  ```lua
  {
    Money = '1234',
    MoneyText = '$1,234',
    Rebirth = 2,
    Gears = {
      { Id, Name, Description, Price, PriceText,
        RequiredRebirth, ToolName, Locked, Owned, AutoBuy },
      ...
    },
  }
  ```
- **Failure modes:** none. A missing `EconomyService` → `Money = '0'`.
  A missing `PlayerService` → `AutoBuy` is `false` for every entry. A
  missing `RebirthService` → `Rebirth = 0`.
- **`Owned` is a live `Tool` probe** — not the session flag, not the
  profile. A player with a provisioned tool but a cleared session flag
  still shows `Owned = true`.

---

### `GearShopService.Purchase(player, gearId, quiet?)`

The validated purchase entry point.

- **Parameters:**
  - `player: Player`.
  - `gearId: string` — the stable catalog `Id` (never the display
    `Name`).
  - `quiet: boolean?` — when `true`, **no toasts** are sent. Used by
    the auto-buy path.
- **Returns:** `{ success: boolean, error: string? }`.
- **Error strings:**
  | `error` | Cause |
  |---|---|
  | `'invalid-player'` | Not a live player. |
  | `'invalid-gear'` | Unknown `gearId`. |
  | `'in-progress'` | Another purchase for this player is running. |
  | `'already-owned'` | Already session-owned. The tool is topped up and equipped; **no charge**. |
  | `'robux-only'` | `RobuxOnly` gear. **Never debited** — use `GrantRobuxGear`. |
  | `'locked-rebirth'` | `RequiredRebirth` not met. **Never debited**. |
  | `'tool-missing'` | The `Tool` asset is missing. **Never debited**. |
  | `'service-not-ready'` | `EconomyService` is not wired. |
  | `'insufficient-money'` | Not enough cash. The shortfall is in the `Gear_InsufficientCash` toast as a **raw BigNumber string**. |
  | `'debit-failed'` | The debit failed for another reason. |
  | `'grant-failed'` | The grant or the verification failed **after** the debit. The session flag was rolled back and the money **was refunded**. |
  | `'internal'` | `purchaseInner` threw. |
- **Failure modes:** never throws. The per-player mutex is cleared on
  every exit path, including the throw path.
- **Side effects on success:** money debited with the reason
  `GearPurchase`, the session ownership flag set, the `Tool` granted
  and verified, the gear equipped (best-effort — a missing character
  defers to `CharacterAdded` and does **not** fail the sale), the
  `Gear_Success` toast sent, and the funnel step
  `FirstGearPurchased` logged (skipped for `DefaultBat`).

---

### `GearShopService.SetAutoBuy(player, gearId, enabled)`

Writes the AutoBuy preference.

- **Parameters:**
  - `player: Player`.
  - `gearId: string` — the catalog `Id`.
  - `enabled: boolean` — **strict**. The strings `"true"` / `"false"`,
    numbers, and `nil` are **rejected, never coerced**.
- **Returns:** `{ success: boolean, error: string? }`.
- **Error strings:** `'invalid-player'`, `'invalid-gear'`,
  `'invalid-value'` (non-boolean), `'service-not-ready'` (no
  `PlayerService`), `'internal'` (the profile write threw).
- **Failure modes:** never throws.
- **Side effects on success:** the preference is written into
  `data.GearAutoBuy[gearId]`, a fresh state is pushed, and — **if
  `enabled` is `true` and the gear is not already session-owned** — a
  **quiet** purchase is attempted immediately. Disabling AutoBuy never
  interrupts an in-flight purchase.

---

### `GearShopService.GrantRobuxGear(player, gearId)`

The **only** path that grants a `RobuxOnly` gear. Call it from your
Developer Product receipt handler.

- **Parameters:** `player: Player`, `gearId: string`.
- **Returns:** `boolean` — `true` when the gear was granted.
- **Failure modes:** returns `false` (never throws) when:
  - the player is not live,
  - the `gearId` is unknown (warned),
  - the `Tool` asset is missing (warned as
    `'[GearShop][RobuxGear] grant failed ... (asset missing?)'`).
- **Side effects on success:** the `Tool` is granted **and** the
  session ownership flag is set in the **same** table a cash purchase
  commits to, and the persisted entitlement
  `OwnedRobuxGear[gearId] = true` is written to the profile.
- **Important:** when it returns `false` because the asset is missing,
  the **purchase must not be consumed** — the receipt has to be
  retried later. The retry policy lives in the Shop system.

---

### `GearShopService.EquipGear(player, gearId)`

The one equip path.

- **Parameters:** `player: Player`, `gearId: string`.
- **Returns:** `boolean` — whether the tool ended up equipped.
- **Failure modes:** returns `false` (never throws) when:
  - the player is not live,
  - `gearId` is not a non-empty string,
  - the `gearId` is unknown,
  - the gear is **not session-owned** (and is not `DefaultBat`) —
    logged as `equip-rejected ... reason=not-owned`,
  - the `Tool` is not in the player's Backpack or Character — logged
    as `equip-deferred ... reason=no-character-yet`.
- **Side effects on success:**
  - every other `Tool` in the Character is parked in the Backpack
    (**exactly one bat equipped**),
  - the target tool is equipped (`Humanoid:EquipTool` when the
    humanoid is alive; parented directly as a fallback),
  - surplus duplicate **bat** instances in the Backpack are destroyed
    (**ownership flags are never touched**; non-bat gear is never
    matched, moved, or destroyed),
  - `equippedBy[userId] = gearId` is recorded,
  - the funnel step `FirstGearEquipped` is logged (skipped for
    `DefaultBat`).
- **It never grants.** If the tool is not in the inventory, the
  currently equipped bat is **left alone**.

---

### `GearShopService.EnsureGearTool(player, gearId)`

The idempotent single-gear grant.

- **Parameters:** `player: Player`, `gearId: string`.
- **Returns:** `boolean` — `true` when the `Tool` is present
  afterwards.
- **Failure modes:** returns `false` (never throws) when:
  - the player is not live,
  - the `gearId` is unknown (warned),
  - the source asset is missing (warned with the expected path),
  - the source asset exists but is not a `Tool` (warned with the
    actual class),
  - neither a Backpack nor a Character exists — the clone is destroyed
    and the grant fails loudly,
  - the post-parent verification fails (warned).
- **Side effects on success:** the clone is parented to the Backpack
  (or the Character if there is no Backpack) with
  `CanBeDropped = false` and `Name` set to the source's name. If the
  tool was already present, it is only observed (the trace attaches),
  not duplicated.
- **It never charges and never yields.**

---

### `GearShopService.EnsureOwnedTools(player)`

Re-grants every session-owned gear.

- **Parameters:** `player: Player`.
- **Returns:** `number` — how many were granted (already-present ones
  count as granted).
- **Failure modes:** a non-live player → `0` (a safe no-op). Never
  throws.

---

### `GearShopService.EnsureDefaultBat(player)`

Grants the free starting bat.

- **Parameters:** `player: Player`.
- **Returns:** `boolean` — whether the `Tool` is present afterwards.
- **Failure modes:** a non-live player → `false`. A missing asset →
  `false`.
- **Side effects:** sets the session ownership flag for `DefaultBat`
  **before** granting, so ownership is recorded even if the grant
  later fails. Never charges, never notifies.

---

### `GearShopService.EnsureRuntimeTemplate(player)`

Clones the server-only row template into the player's GUI.

- **Parameters:** `player: Player`.
- **Returns:** `boolean` — whether a usable template exists afterwards.
- **Failure modes:** returns `false` (never throws) when:
  - the player is not live,
  - `PlayerGui` has no `GearShop` descendant (warned),
  - the `GearShop` GUI has no `ScrollingFrame` descendant (warned),
  - the server-side `ServerStorage.Assets.Ui.GearShop.GearTemplate` is
    missing (warned as an ERROR).
- **Side effects:** clones the template into
  `PlayerGui…GearShop.ScrollingFrame` as a hidden `GearTemplate`. It is
  **idempotent** — an existing template with **no `GearId` attribute**
  is accepted as-is; one that already has a `GearId` attribute is
  treated as stale and re-cloned.

---

### `GearShopService.OnPlayerReady(player)`

The join flow. Runs **exactly once** per server session per player.

- **Parameters:** `player: Player`.
- **Returns:** nothing.
- **Failure modes:** a non-live player → no-op. Every internal step is
  `pcall`-guarded.
- **What it does, in order:**
  1. `EnsureDefaultBat` + `EquipGear(DefaultBat)`.
  2. `NormalizeAutoBuy(profile)`.
  3. For each catalog entry **in catalog order** with
     `GearAutoBuy[id] == true` and not session-owned: a **quiet**
     `Purchase`. Because each success equips that bat, the **last
     affordable** auto-buy gear wins.
  4. For each persisted `OwnedRobuxGear[id]` not session-owned:
     `EnsureGearTool` + rehydrate the session flag.
  5. Push a fresh state if anything was granted.
- **Must be called after the profile is loaded** (post `MarkLoaded`).
  The `readyBy` guard means it will **not** retry.

---

### `GearShopService.OnCharacterSpawned(player)`

The respawn flow.

- **Parameters:** `player: Player`.
- **Returns:** nothing.
- **Failure modes:** a non-live player → no-op. Never throws (all
  internal steps are `pcall`-guarded).
- **What it does:**
  1. `EnsureOwnedTools(player)` — re-grants every session-owned gear.
  2. `EquipGear(session choice)` — the choice survives respawns. If
     the session choice is missing or no longer owned, it falls back
     to `DefaultBat` (granting it first).
- **It never duplicates** — `EquipGear` no-ops when the tool is already
  held.

---

### `GearShopService.OpenShop(player)`

Opens the shop for a player.

- **Parameters:** `player: Player`.
- **Returns:** nothing.
- **Failure modes:** a non-live player → no-op. A missing GUI or a
  missing template → the template provisioning warns, but the state is
  still pushed (the client may still show a list).
- **Side effects:** calls `EnsureRuntimeTemplate(player)`, then pushes
  the state with `Show = true`.

---

### `GearShopService.ForgetPlayer(userId)`

Clears all session state for a leaving player.

- **Parameters:** `userId: number`.
- **Returns:** nothing.
- **Failure modes:** a non-number → no-op. Never throws.
- **Side effects:** clears `ownedBy`, `equippedBy`, `readyBy` and
  `busyBy` for that user, and disconnects the lifecycle-trace
  connections. It does **not** destroy any granted `Tool` — those
  disappear with the player.

---

### `GearShopService.NormalizeAutoBuy(data)`

Repairs the profile's AutoBuy table.

- **Parameters:** `data: any` — the profile data table.
- **Returns:** `{ [string]: boolean }?` — the normalized table, or
  `nil`.
- **Failure modes:** a non-table `data` → `nil` + a warn
  (`'[GearShop][AutoBuy] missing player profile; cannot normalize'`).
- **What it does:** creates `data.GearAutoBuy` if it is missing or is
  not a table, then gives every **known** catalog gear an explicit
  boolean (default `false`). It **never resets** an existing `true`, and
  it **preserves unknown keys** — so future gears arrive as `false` and
  existing grants survive.

---

### `GearShopService.NormalizeOwnedRobuxGear(data)`

Repairs the profile's Robux entitlement table.

- **Parameters:** `data: any` — the profile data table.
- **Returns:** `{ [string]: boolean }?` — the normalized table, or
  `nil`.
- **Failure modes:** a non-table `data` → `nil` + a warn
  (`'[GearShop][RobuxGear] missing player profile; cannot normalize'`).
- **What it does:** creates `data.OwnedRobuxGear` if it is missing or is
  not a table. Existing grants are **never reset** and unknown keys are
  preserved.

---

### `GearShopService._TestReset()`

Test seam.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effects:** clears `ownedBy`, `equippedBy`, `readyBy`, `busyBy`,
  the trace connection table, `backpackWatched` and `characterHooked`.
  It does **not** reset the `started` flag.

---

## Private / internal

Not part of the public surface, but named here so a reader does not
mistake them for API.

| Function | Purpose |
|---|---|
| `gearToolsFolder()` | Resolves `ServerStorage.Assets.Ui.GearShop.Tools` as a `Folder?`. |
| `toolsPathFor(toolName)` | The expected asset path, for warn messages. |
| `resolveToolStatus(toolName)` | `{ found, class }` — the single source of truth for tool resolution. |
| `hasLiveTool(player, toolName)` | The live-`Tool` presence probe. |
| `autoBuyOf(data)` | Reads `data.GearAutoBuy` or returns `{}`. |
| `ownedRobuxOf(data)` | Reads `data.OwnedRobuxGear` or returns `{}`. |
| `isOwned(userId, gearId)` | The session-ownership probe. |
| `formatPrice(price)` | `'$' .. BigNumber.Format(price)`, falling back to the raw string. |
| `purchaseInner(player, entry, quiet)` | The ordered VALIDATE → DEDUCT → COMMIT → GRANT → VERIFY commit. |
| `_isBatToolName(toolName)` | Whether the combat catalog knows this tool name (used by the duplicate cleanup). |
| `_batlog(player, action, detail)` | The `BatSystem` log line. |
| `_ownedList(userId)` | A sorted `{id,id}` string of the session ownership set. |
| `pushState(player, show?)` | Pushes `GearShopState`. |
| `pushResult(player, action, gearId, success, err?)` | Pushes `GearShopResult`. |
| `handleAction(player, payload)` | The `GearShopAction` handler. |
| `publishPreviews()` | Publishes the script-stripped preview clones. |
| `resolveAuthoritativeTemplate()` | Resolves the server-side `GearTemplate`. |
| `findPlayerShopGui(player)` | Finds `PlayerGui…GearShop`. |
| `wireShopPrompt()` | Wires `Workspace.Map.Shop.PromptPart`. |
| `watchTool`, `watchBackpack`, `watchCharacterForever`, `watchCharacterContainer`, `lifecycleSnapshot`, `dumpToolValidity`, `fullNameOf`, `gearToolNameToId`, `trackConn`, `untrackPlayer` | The always-on lifecycle trace (read + warn only). |
