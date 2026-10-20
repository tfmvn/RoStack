# Roblox Marketplace Integration

**Status: implemented in the source game, and in the library. There is no
abstraction layer over it — the Marketplace calls are made directly.**

---

## 1. What exists

| Piece | Where | In this library? |
|---|---|---|
| Developer products and gamepasses | `src/ReplicatedStorage/Config/Economy/Shop.lua` | **Yes** — `Systems/ShopsAndPurchases/` |
| Receipt processing | `src/ServerScriptService/Shop/ShopService.lua` | **Yes** — `Systems/ShopsAndPurchases/` |
| The unlock door | `src/ServerScriptService/Shop/DoorService.lua` | **Yes** — `Systems/ShopsAndPurchases/` |
| The client prompt flow | `src/StarterPlayer/StarterPlayerScripts/ShopController.lua` | **Yes** — `Systems/ClientPresentation/` |
| Gear | `src/ServerScriptService/GearShop/GearShopService.lua` | **Yes** — `Systems/Items/` |

There is **no** `MarketplaceService` wrapper module, no provider interface,
and no entitlement cache. `ShopService` calls
`MarketplaceService:GetProductInfo` and `ProcessReceipt` directly.

---

## 2. The model

### 2.1 Products are **config**

`ReplicatedStorage/Config/Economy/Shop.lua` holds the catalogue. Each entry
carries:

```lua
{
  Key      = 'Luck4x',
  Name     = 'Luck 4x',
  Robux    = 79,
  Kind     = 'Luck',      -- the dispatch discriminator
  ProductId = 123456789,  -- the Roblox developer product id
}
```

A second, reverse lookup — `ByProductId` — is built at module load, and
**duplicate `ProductId`s are a boot error**.

Gamepasses are the same shape with a different `Kind` and a `GamePassId`.

### 2.2 The receipt router

```text
MarketplaceService.ProcessReceipt(receiptInfo)
  → look up receiptInfo.ProductId in ShopConfig.ByProductId
      → not found  → NotProcessedYet  (a LOUD retry, not a silent drop)
      → found     → dispatch on entry.Kind
          → grant the effect (luck, money, gear, doors, …)
          → return true
```

**An unknown `ProductId` returns `NotProcessedYet`**, which tells Roblox to
retry the purchase. That is deliberate: a temporary failure (the profile was
not loaded yet, a service was not ready) must not lose the purchase.

### 2.3 The prompt flow

```text
Client: player clicks a shop button
  → ShopController reads the ProductId attribute from the button
  → MarketplaceService:PromptProductPurchase(player, productId)
  → Roblox shows the purchase prompt
  → the purchase completes
  → Roblox delivers a receipt to the server
  → ShopService.ProcessReceipt → grant
  → the client sees the grant via the PlayerState push
```

The client also fires a `FunnelPrompt` analytics event with the
`ProductId` — so you can measure the prompt → purchase conversion.

---

## 3. What to replace for a new game

| # | What | Where | Notes |
|---|---|---|---|
| 1 | Every `ProductId` | `Config/Economy/Shop.lua` | Public developer-product ids. Wrong ids are simply rejected. |
| 2 | Every gamepass id | `Config/Economy/Shop.lua` | Same. |
| 3 | Every `Robux` price | `Config/Economy/Shop.lua` | The price shown in the prompt. **The server must not trust the client**, and it does not — the price is read from the config, not from the client. |
| 4 | Every `Kind` | `Config/Economy/Shop.lua` | The dispatch discriminator. A new kind needs a new branch in `ShopService`. |
| 5 | The grant logic per kind | `ShopService` | The `Kind` → effect mapping. |

**Product ids are not secrets.** They are public Marketplace identifiers —
anyone can look one up. They are *environment-specific*, not *secret*. This
distinction matters: do not try to hide them, do change them.

---

## 4. Security properties (preserved from the source game)

- **The client never supplies a price.** The client sends a `ProductId`; the
  server resolves the price from the config and the grant from the server
  state.
- **Unknown product → retry, not free grant.** A `ProductId` the server does
  not know never produces a grant.
- **The receipt handler is the only grant path.** Nothing else grants
  Robux-content.
- **`Security.Receipts` is configured**: `SeenCap = 5000` (the receipt
  dedupe cache size) and `ActionCooldownSeconds = 5` (the per-player
  cooldown between purchase actions).

---

## 5. Gamepasses specifically

There is **no separate gamepass system** in the source game. Entitlement is
handled in two places:

| Concern | Where |
|---|---|
| The catalogue entry | `Config/Economy/Shop.lua` — a `Kind = 'Gamepass'` entry. |
| The entitlement check | `ShopService` — reads `Data.OwnedRobuxGear` from the profile. |
| The persistence | `Data.OwnedRobuxGear` — a map in the player profile. |
| The auto-buy preference | `Data.GearAutoBuy` — a map in the player profile. |

The profile fields are owned by `ShopsAndPurchases` (`OwnedRobuxGear`) and
`Items` (`GearAutoBuy`). See `DEPENDENCY_MAP.md` §8.

---

## 6. Checklist for a new game

- [ ] Every `ProductId` and gamepass id replaced with your own.
- [ ] Every `Robux` price set.
- [ ] Every `Kind` handled by `ShopService`, or removed from the catalogue.
- [ ] The products created in the Roblox Creator Dashboard and their ids
      copied into the config.
- [ ] `MarketplaceService.ProcessReceipt` wired in the bootstrap, and the
      handler returns `true` only on a confirmed grant.
- [ ] The client prompt flow wired: the shop buttons need a numeric
      `ProductId` **attribute** — `ShopController` reads it from the
      attribute, not from a child element.
- [ ] `Config/Systems/Security.lua` → `Receipts` reviewed.
- [ ] The shop GUI authored — it is **not** in this repository.
