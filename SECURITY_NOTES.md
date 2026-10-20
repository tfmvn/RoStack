# Security Notes

What this library does and does not contain, where secrets belong, and the
issues found in the source game during extraction.

**Read this before putting the library into a new project.**

---

## 1. The Rule

> Secrets must never be included in the library. Use placeholders and explain
> how the future game should configure secrets securely.

This library contains **no** live API keys, Discord bot tokens, webhook URLs,
Open Cloud keys, or other credentials. Every credential-shaped value in the
extracted code is either:

- a **placeholder** with a documented way to supply the real value, or
- a **name of a Studio attribute / environment variable** that the code reads
  at runtime (never the value itself).

---

## 2. Audit Result

The following scans were run over the whole library tree. They were
**re-run after every change to the library**; the counts below are from the
final state.

| Scan | Pattern | Result |
|---|---|---|
| URLs | `https?://…` | **1 match** in code, and it is a URL *pattern* used for validation, not a value: `PlayerLogger.lua:268` matches `^https://discord%.com/api/webhooks/`. |
| Credential words | `api_key`, `token`, `secret`, `password`, `webhook`, `bearer`, `authorization` | **0 credentials.** All hits are the rarity tier `Secret`, session/dedupe *tokens* (opaque strings), or prose in documentation. |
| Discord webhook URLs | `discord(app)?\.com/api/webhooks/[0-9]{17,}` | **0 live URLs** in the library. The 8 documentation hits are all placeholders — `…`, `<id>`, `<webhook_id>/<webhook_token>`. |
| Bot credentials | `DISCORD_TOKEN`, `OPENCLOUD_API_KEY`, `ghp_`, `sk-`, `AKIA…` | **0**. |
| Bot token in `.env` | `discord_bot/.env` | **Not in this library.** The `discord_bot/` folder is gitignored in the source repo and was never part of `src/`. |
| Long opaque blobs | `[0-9a-fA-F]{32,}`, `sk-…`, `xox[baprs]-…`, UUIDs | **0 credentials.** The 4 hits are a documented md5 integrity hash, and BigNumber/spec fixture values. |
| Live admin ids | the source game's superadmin userIds | **0** in the library (removed — see §5 S-5). |

**Reproduce it yourself:**

```bash
grep -rInE "discord(app)?\.com/api/webhooks/[0-9]{17,}" ReusableSystems/ \
  | grep -v "/Tests/Tree/"        # → no output
grep -rInE "[0-9a-fA-F]{32,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}" \
  ReusableSystems/ --include="*.lua" --include="*.md" --include="*.json" \
  | grep -v "/Tests/Tree/"        # → only a documented md5 and test fixtures
```

### The one value that WAS a live secret

`src/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua:30` in the
source game contained a **live Discord webhook URL** as a string literal,
directly beneath a comment reading *"Set manually in Studio; never in source."*

**In this library that literal has been removed** and the field now holds the
*attribute name* the consuming code actually expects:

```lua
-- Source game (SECRET, wrong — see below)
PlayerLoggerConfig.WebhookAttribute = 'https://discord.com/api/webhooks/…/…'

-- This library (no secret, and functionally correct)
PlayerLoggerConfig.WebhookAttribute = 'PlayerLoggerWebhookUrl'
```

This is not only a secret leak — it was a **bug**. `PlayerLogger.lua:267` does:

```lua
local raw: any = ServerScriptService:GetAttribute(Config.WebhookAttribute)
```

so the config field is meant to be the *name* of a `ServerScriptService`
attribute. With a URL in it, the lookup never matches, the logger silently
degrades to registry-only delivery, and the webhook is never posted to.
The library copy therefore has *different, better* behaviour than the source
game. **The production file was deliberately left untouched** (see §5).

---

## 3. Where Secrets Belong

### 3.1 Studio attributes (recommended for this codebase)

The pattern the source game already uses for the Discord webhook is a
`ServerScriptService` string attribute:

```lua
-- in the Studio place, not in source
ServerScriptService:SetAttribute('PlayerLoggerWebhookUrl', 'https://…')
```

Read at runtime with `ServerScriptService:GetAttribute('PlayerLoggerWebhookUrl')`.

**Why this is good:** the value lives in the place file, not in version
control, and can be changed without a code deploy. It is visible to anyone
with place access, though — do not put a high-value credential here.

### 3.2 Studio attributes (for Roblox secret types)

Roblox provides `Enum.SecretType` and `HttpService:GetSecret`, which stores a
value encrypted in the place's data:

```lua
local secret = HttpService:GetSecret('MyApiKey')
local value = secret:DisplayValue()
```

Use this for anything that grants access to an external service. The library
does not use it anywhere, but `Templates/SystemConfigTemplate.lua` §4
recommends it.

### 3.3 Environment variables (for out-of-place services)

The `discord_bot/` Python service reads its credentials from a `.env` file
(`.env.example` is the committed, placeholder-only version). That is the
right pattern for a service that runs outside Roblox.

### 3.4 Never

- Never put a credential in a `Config.lua` module. Config modules are
  `ReplicatedStorage` — they replicate to **every client**, so a secret there
  is a public secret.
- Never put a credential in `ReplicatedStorage` at all, for the same reason.
- Never commit a `.env`, a `*.pem`, a `*.key`, or a webhook URL.
- Never let a client supply a credential. Clients send intent and ids only.

---

## 4. Environment-Specific Identifiers in the Library

These are **not secrets** — they are public deployment identifiers, and the
code needs them to function. They are listed here so a new game knows
exactly what to replace.

| Identifier | Where | What it is | Replace it? |
|---|---|---|---|
| Roblox developer product IDs | `ReplicatedStorage/Config/Economy/Shop.lua` — `ProductId` fields | Public Marketplace product IDs. A purchase for the wrong universe is simply rejected. | **Yes**, for a new game. |
| Roblox gamepass IDs | `ReplicatedStorage/Config/Economy/Shop.lua` / `Gear.lua` | Public gamepass IDs. | **Yes**. |
| `p7_PlayerData_Money_v1_dev_1` | `PlayerService.lua:115` | The profile DataStore name. Contains a schema version and a manual environment suffix. | **Yes.** Changing it abandons the old data. |
| `p7_PlayerRegistry_v1` | `PlayerLoggerConfig.lua` | The logger's registry DataStore name. | **Yes**, or keep it if you want the same registry. |
| `p7:<userId>:slot:<index>` | `ReplicatedStorage/Types/SlotType.lua` | The slot-id prefix. The `p7` is the source game's project code. | **Recommended** — see §6. |
| `AN_` / `EG_` id prefixes | `ReplicatedStorage/Utility/OwnedObjectIdentity.lua` | Animal and egg id prefixes. | Optional. |
| `PlayerLoggerWebhookUrl` | `PlayerLoggerConfig.lua` | The *name* of the Studio attribute. | Optional, but it must match what you set in Studio. |
| Admin user IDs | `ServerScriptService/Admin/AdminConfig.lua` | The admin allowlist. | **Yes** — a new game must supply its own. |

Nothing in the library identifies a **specific human** or grants access to a
specific account.

---

## 5. Issues Found in the Source Game (NOT fixed here)

Per the extraction rules, production files were not modified. These are
recorded for the owner to fix in the source game, separately from this
library.

### S-1 — Live Discord webhook committed to git 🔴

- **File:** `src/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua:30`
- **Committed in:** `5a1cb35` ("Finalpush"). The file is tracked by git.
- **Impact:** anyone with read access to the repository can post to that
  Discord channel. It also contradicts `discord_bot/README.md` §4 and §12,
  which both say the webhook must never enter git.
- **Recommended fix (in the source game):**
  1. **Rotate the webhook** in the Discord channel settings — treat the
     existing one as compromised.
  2. Replace the literal with the attribute *name*
     (`PlayerLoggerConfig.WebhookAttribute = 'PlayerLoggerWebhookUrl'`).
  3. Set the attribute in the Studio place.
- **Library status:** already handled in the library copy (§2).

### S-2 — `discord_bot/.env` on disk

`discord_bot/.env` holds a real `DISCORD_TOKEN` and `OPENCLOUD_API_KEY`. It is
**correctly gitignored** and not in the committed tree, and it is not in this
library. Worth confirming it is not in any backup, CI artefact, or screen
share.

### S-3 — `StealService.lua:444` reads an undefined global

`selene` reports `undefined_variable` for `_thiefSpeed` at
`src/ServerScriptService/Steal/StealService.lua:444`. The `local`
declaration of `_thiefSpeed` is at line **587** — below the use — so at
line 444 the name resolves to an undefined global (`nil`), not the table.

In Luau `nil[userId]` is a runtime **error** (*"attempt to index nil"*), not
a silent wrong value, so `StealService.ForgetPlayer` throws on every player
leave. **Not fixed** — out of scope for extraction. S-7 gives the full
analysis of the same line.

### S-4 — Test suite has never been executed as committed

`src/Tests/ServerScriptService/TestEZTests/TestRunner.server.lua` has two
blocking defects that mean the suite cannot currently run:

1. It requires `script.Parent.Parent.Packages.TestEZ`, but the real path is
   `script.Parent.Parent.Packages.DevPackages.TestEZ` (`test.project.json`
   nests `DevPackages` inside `Packages`).
2. It calls `TestEZ.RunBootstrap()`, which does not exist in TestEZ 0.4.1.
   The 0.4.1 idiom is `TestEZ.TestBootstrap:run({script.Parent})`.

Separately, `AnimalXP.spec.lua` returns a **table** rather than a function, so
it will not be collected as a spec under TestEZ 0.4.1 (the other 88 return
`return function() … end`).

**Library status:** the library copies the files verbatim and documents these
in `Tests/README.md`. Fixing them is a source-game change.

### S-5 — Live admin userIds committed to git 🟠

- **File:** `src/ServerScriptService/Admin/AdminConfig.lua:43-44`
- **Committed in:** `5a1cb35` ("Finalpush"). The file is tracked by git.
- **Content:** two real `discord-roblox` userIds, plus the Studio test ids
  `0`, `1` and `2`, all mapped to `rank = 'superadmin'`.
- **Impact:** the Studio test ids `0`/`1`/`2` are **not** gated behind
  `RunService:IsStudio()`. In a published place, Roblox does not hand out
  userId 0/1/2 to real players, so the practical exposure is limited — but
  the two real userIds grant standing superadmin to whoever owns them, in
  every build of the game, including any public fork.
- **Library status: FIXED in the library copy.** The allowlist is now
  **empty**, which is the safe default (nobody is an admin until you add
  someone). See §3 "The two adapted files" in `EXTRACTION_MANIFEST.md`.
  **The production file still contains the live ids** — treat the two real
  userIds as compromised and remove them from the source game.

### S-6 — `AdminConfig.SuperadminGroup` never matches `RankOrder` 🟠

- **File:** `src/ServerScriptService/Admin/AdminConfig.lua:77` vs `:54-58`
- **Content:** `AdminConfig.RankOrder` keys are lowercase
  (`mod`, `admin`, `superadmin`), but `AdminConfig.SuperadminGroup` is
  `'Superadmin'` — capitalised.
- **Impact:** three admin commands call
  `AdminService.AssertCanRun(context.Executor.UserId, AdminConfig.SuperadminGroup)`:
  `addAdminServer.lua:19`, `removeAdminServer.lua:19`, and
  `shutdownServer.lua:19`. `AdminService.CanRun` looks the name up in
  `RankOrder`; an unknown name is **refused by default** (the code says
  *"Better to deny than to silently allow a typo'd group to be a free
  pass"*). `RankOrder['Superadmin']` is `nil`, so `CanRun` returns `false`
  for **everyone** — including real superadmins.
  **Net effect: `/addadmin`, `/removeadmin` and `/shutdown` deny all
  users, always.** They cannot bootstrap an admin, and they cannot shut
  the server down.
- **Fix (one character, in the source game):**
  `AdminConfig.SuperadminGroup = 'superadmin'`.
- **Library status: NOT fixed.** The library copy is byte-identical here
  (apart from the §5 allowlist removal), so it carries the same bug. It is
  documented in `Systems/AdminTools/README.md` and `MEMORY.md` so a porter
  does not ship a dead admin system. Fixing it would have meant editing
  behaviour during an extraction, which the task rules forbid.

### S-7 — `StealService.ForgetPlayer` writes an undefined global 🟡

- **File:** `src/ServerScriptService/Steal/StealService.lua:444`
- **Content:** `_thiefSpeed[userId] = nil` in `ForgetPlayer`, but
  `local _thiefSpeed: { [number]: number } = {}` is declared at **line
  587** — *below* the use. Lua locals are lexically scoped, so at line 444
  `_thiefSpeed` is an **undefined global**, not the table.
- **Impact:** `ForgetPlayer` raises *"attempt to index nil with 'userId'"*
  on every player leave, and the real per-thief speed snapshot at line 618
  is never cleared. The speed table therefore **leaks entries for the
  lifetime of the server** and a leaving player's entry is never removed.
  `selene` flags it as `undefined_variable`.
- **Not fixed** — out of scope for extraction. See S-3 for the sibling
  note on the same file.

### S-8 — Two spec files assert values the config does not have 🟡

Neither of these is a security issue, but both are recorded here because
they are the kind of thing that makes a "green" suite a lie.

| Spec | Asserts | Reality |
|---|---|---|
| `ConfigArchitecture.spec.lua:183` | `Movement.Player.WalkSpeed == 24` | `Config/World/Movement.lua:129` sets `WalkSpeed = 20`. The config's own comment reads *"CURRENT: 20 (spec baseline; comment once said 16)"*. |
| `BaseLockTimer.spec.lua:99` | `BaseLockConfig.LockDurationSeconds == 30` | `Config/World/Bases.lua:187` sets `Bases.Lock.LockDurationSeconds = 60`. |

**Not fixed** — the specs are byte-identical copies of the source game's.

### S-9 — `AnimalOverhead.spec.lua` expects a rarity the animal does not have 🟡

`AnimalOverhead.spec.lua` expects `Triceratops` to be **Legendary**; it is
**Mythic** (`Config/Creatures/Animals.lua:161`). The spec's other cases
also disagree with `AnimalWalkHandoff.spec.lua`'s two no-op assertions
(`expect(true).to.equal(true)`), which assert nothing at all.

**Not fixed** — spec files are copied verbatim.

### S-10 — `EventService._TestReset()` leaves a live heartbeat 🟡

`EventService._TestReset()` clears the service's state but does **not**
stop the running heartbeat connection, so a test that calls it leaves a
live `Heartbeat` handler bound to a service the test believes is idle.

**Not fixed** — out of scope for extraction.

### S-11 — The production *test* build cannot load `ProfileService` 🟡

`PlayerService.lua:61` requires
`ServerScriptService.Packages.ProfileService`. In the production
**game** build that module exists, because `default.project.json` maps it:

```json
"ProfileService": { "$path": "src/Vendored/ProfileService.lua" }
```

But the production **test** build (`test.project.json`) maps
`ServerScriptService/Packages` to the `ServerPackages/` folder, which
contains `Cmdr.lua`, `Janitor.lua` and `_Index/` — **not**
`ProfileService`. So in `p-7-tests` the require cannot resolve.

**This is pre-existing and was NOT fixed here**, per the task's STRICT
RULE. It is provably not caused by the extraction: `default.project.json`,
`test.project.json`, `src/` and `ServerPackages/` are all byte-identical
to commit `5a1cb35`, so the `p-7-tests` build output is unchanged from
HEAD.

**The library's own test project does not have this problem** —
`ReusableSystems/test.project.json` maps `Vendored/ProfileService.lua`
correctly, and `ReusableSystems/Examples/MinimalGame/minimalgame.project.json`
does too. Both build with 0 broken requires.

**Why it matters beyond a red build:** if the production test suite is
ever run in Studio, any spec that touches `PlayerService` will fail for
this reason rather than because of the code under test. Fixing it is a
one-line addition to `test.project.json`.

### 5.1 Summary of this section

| # | Issue | Severity | Fixed in the library? | Fixed in the source game? |
|---|---|---|---|---|
| S-1 | Live Discord webhook in git | 🔴 | **Yes** | **No** |
| S-5 | Live admin userIds in git | 🟠 | **Yes** | **No** |
| S-2 | `discord_bot/.env` on disk | 🟠 | n/a — not in the library | n/a — gitignored |
| S-6 | `SuperadminGroup` vs `RankOrder` | 🟠 | **No** | **No** |
| S-7 | `_thiefSpeed` undefined global | 🟡 | **No** | **No** |
| S-3 | `StealService` undefined global | 🟡 | **No** | **No** |
| S-4 | Test suite cannot run | 🟡 | Partly — the runner is fixed | **No** |
| S-8 | Two spec/config value mismatches | 🟡 | **No** | **No** |
| S-9 | `AnimalOverhead` rarity mismatch | 🟡 | **No** | **No** |
| S-10 | `_TestReset` leaves a heartbeat | 🟡 | **No** | **No** |
| S-11 | `p-7-tests` build missing `ProfileService` | 🟡 | **Yes** — the library's test project maps it correctly | **No** |

**Only the two secret-bearing issues (S-1 and S-5) were fixed in the
library**, because leaving a live credential in a file whose entire purpose
is to be shared would defeat the purpose of the extraction. Everything else
is a behaviour change, and behaviour changes are the source game's call.

---

## 6. Other Security-Relevant Design Properties

These are **intentional** in the source game and were preserved exactly.

### 6.1 Server authority

Clients send **intent and ids**. The server re-resolves every price, level,
weight, and eligibility itself. There is no client-supplied price anywhere in
the codebase. This is the single most important security property of the
extraction; breaking it in a port is the main way to introduce an exploit.

### 6.2 Remote allow-listing

Every `OnServerEvent` handler validates its payload shape before use. Several
also apply a throttle (`Config/Systems/Security.lua` →
`RequestThrottleSeconds = 0.5`).

### 6.3 Admin commands

- The admin allowlist lives in `AdminConfig.lua` and is enforced by
  `AdminService`.
- Admin commands are additionally **rate-limited** by `AdminRateLimit.lua`
  using `Config/Systems/Security.lua` → `Admin.{WindowSeconds = 10,
  MaxPerWindow = 30, MinGapSeconds = 0.2}`.
- Every admin action is written to an **audit log** (`AdminAudit.lua`).
- Admin commands are exposed through **Cmdr**, which has its own permission
  groups. The Cmdr permission set is Studio-side configuration and is not in
  the repository.

### 6.4 Receipt handling

`ShopService` routes Marketplace receipts through a config-driven table and
treats an unknown `ProductId` as `NotProcessedYet` (a loud retry) rather than
silently granting nothing or granting the wrong thing.

### 6.5 `StudioTestMode`

`StudioTestMode.Enabled` allows UserIds `0` and negative values, but **only**
when `RunService:IsStudio()` **and** the developer has opted in. The guard is
in `Shared/Utilities/StudioTestMode.lua`.

### 6.6 `Debug.SkipPersistence`

Studio-only. It bypasses the DataStore entirely. It must never be enabled in
a published place.

---

## 7. Checklist Before Shipping a New Game

- [ ] Every `ProductId` / gamepass ID in `ReplicatedStorage/Config/Economy/`
      replaced with your own.
- [ ] The profile DataStore name changed, **with an environment suffix**
      (`dev` / `live`) and a schema version.
- [ ] The admin allowlist in `AdminConfig.lua` replaced with your own.
      It ships **empty** in the library (§5, S-5) — nobody is an admin
      until you add someone. Bootstrap yourself from a server console.
- [ ] **`AdminConfig.SuperadminGroup` corrected to `'superadmin'`**
      (lowercase) — otherwise `/addadmin`, `/removeadmin` and `/shutdown`
      deny everyone, including you. See §5, S-6. **This is the single
      most likely thing to trip you up in this library.**
- [ ] `StealService.ForgetPlayer` — the `_thiefSpeed` undefined-global
      bug at `StealService.lua:444` is still present (§5, S-7). Fix it, or
      do not install the `Stealing` system.
- [ ] The slot-id prefix in `SlotType.lua` changed if you are not continuing
      this game's data.
- [ ] `Config/Systems/Debug.lua` reviewed — `SkipPersistence` must be
      `false` in production.
- [ ] `Config/Systems/Security.lua` reviewed for your expected traffic.
- [ ] Any webhook / API credential supplied via a Studio attribute, an
      `HttpService:GetSecret`, or an environment variable — **never** a
      `ReplicatedStorage` constant.
- [ ] `grep -rniE "(api[_-]?key|token|secret|password|webhook)" --include=*.lua`
      run over your copy, and every hit explained.
- [ ] `rojo build` succeeds and the place opens in Studio with no errors in
      the Output window.
- [ ] The test suite is actually **run** (see `Tests/README.md`) — the source
      game's suite was never executed as committed (§5, S-4).
- [ ] The **source game's** two live secrets are **rotated**: the Discord
      webhook (§5, S-1) and the two superadmin userIds (§5, S-5). They are
      still in the production tree and in git history.
