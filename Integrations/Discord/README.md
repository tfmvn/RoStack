# Discord Integration

**Status: webhook-side only. There is no Discord *bot* in this library.**

---

## 1. What exists in the source game

Two separate things, only one of which is in the library:

| Piece | Where | In this library? |
|---|---|---|
| **The webhook side** — posts Discord embeds on join / leave / milestones | `src/ServerScriptService/PlayerLogger/` | **Yes** — `Systems/PlayerLogging/` |
| **The bot side** — a standalone Python service that reads DataStores through the Roblox Open Cloud API and exposes `/userinfo` and `/users` slash commands | `discord_bot/` (repo root) | **No** — gitignored, never in `src/`, and out of scope for a Luau library |

The bot is **fully decoupled** from the Luau code. It never references
`discord_bot/`, and nothing in `src/` references the bot. They talk only
through the DataStores: the bot reads `p7_PlayerRegistry_v1` and the
gameplay profile via Open Cloud; the game writes them.

---

## 2. The webhook side (in the library)

`Systems/PlayerLogging/` posts a Discord embed on:

| Event | Embed |
|---|---|
| Player joined | 🟢 Player Joined — username, user id, account age, rebirths, first-time/returning, server, joined-at |
| Player left | 🔴 Player Left — username, user id, session duration, rebirths, joined-at, left-at |
| Tutorial completed | 📘 Milestone |
| Arena completed | ⚔️ Milestone (+ stage) |
| Rebirth succeeded | ♻️ Milestone (+ new rebirth count) |
| Purchase granted | 💰 Milestone (+ product and kind) |

**High-frequency gameplay is never logged** — attacks, movement, income
ticks. That is a deliberate config decision, not an oversight.

### The transport

```text
_enqueue(embed)
  → queue, capped at 200, drop-oldest
  → worker polls every 0.5s
  → respects SendIntervalSeconds (1.2s) between sends
  → HttpService:RequestAsync POST to the webhook
  → 2xx: sent
  → 429: honour Retry-After (capped at 60s), re-queue at the FRONT
  → other: retry with backoff {2, 8} up to 3 attempts
```

On shutdown, `game:BindToClose` does a best-effort drain of up to 5 items.

### The URL — **never in source**

The webhook URL is read at boot:

```lua
local raw = ServerScriptService:GetAttribute(Config.WebhookAttribute)
if type(raw) == 'string' and string.match(raw, '^https://discord%.com/api/webhooks/') then
    _webhookUrl = raw
end
```

`Config.WebhookAttribute` is the **name** of the attribute. Set it in the
Studio place:

```lua
ServerScriptService:SetAttribute('PlayerLoggerWebhookUrl', 'https://discord.com/api/webhooks/…')
```

**If the attribute is absent, or HTTP is disabled, the logger degrades to
registry-only mode** with one warning. It never errors, and it never
replicates the URL to a client.

> ### ⚠️ The source game had this wrong
>
> `src/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua:30` held a
> **live webhook URL** as a literal, directly under a comment saying it
> belonged in Studio. Because the consuming code looks the value up as an
> *attribute name*, the lookup never matched — so Discord delivery was
> **permanently dead** in the source game, and the URL was a leaked
> credential in git.
>
> **The library copy is fixed** (it holds `'PlayerLoggerWebhookUrl'`).
> **The source file still holds the URL and should be rotated.**
> See `SECURITY_NOTES.md` §2 and §5.

---

## 3. Adding a Discord integration to a new game

### 3.1 Just the webhook

1. Copy `Systems/PlayerLogging/Source/` → `ServerScriptService/PlayerLogger/`.
2. Install `ProfileService` if you also took `PlayerData` — `PlayerRegistry`
   uses `DataStoreService` directly, not ProfileService.
3. Set the Studio attribute:
   ```lua
   ServerScriptService:SetAttribute('PlayerLoggerWebhookUrl', '<url>')
   ```
4. Wire it into your bootstrap:
   ```lua
   local PlayerLogger = require(script.Parent.PlayerLogger.PlayerLogger)
   -- … after PlayerService.Init(), because the logger reads the profile
   PlayerLogger.Init()
   -- and on join / leave:
   PlayerLogger.NotifyJoin(player)
   PlayerLogger.NotifyLeave(player)
   ```
5. Enable **Game Settings → Security → Allow HTTP Requests** in the
   published place. The logger probes `HttpService.HttpEnabled` and warns
   once if it is off.

### 3.2 The bot side (out of scope, but here is the contract)

If you want the `/userinfo` and `/users` bot, it is a **separate Python
service**, not part of this library. The contract between it and the game is
the DataStore schema:

| Store | Key | Written by | Read by |
|---|---|---|---|
| `p7_PlayerRegistry_v1` | `player_<userId>` | `PlayerRegistry` (the game) | the bot, via Open Cloud |
| `p7_PlayerData_Money_v1_dev_1` | `Player_<userId>` | `PlayerService` (the game) | the bot, via Open Cloud |

The registry entry shape (all JSON-safe):

```lua
{
  userId = 0,
  username = '',
  displayName = '',
  firstSeen = 0,
  lastSeen = 0,
  sessions = 0,
  playtimeSeconds = 0,
  rebirths = 0,
  arenaLevel = 0,
  arenaWins = 0,
  tutorialCompleted = false,
  lastJobId = '',
}
```

**Privacy:** usernames, display names, counters, and timestamps only. No
chat, no credentials, no raw profile data. `PlayerLogger._progressSnapshot`
returns only `{ rebirths, arenaLevel, arenaWins, tutorialCompleted }`.

**The bot's own credentials** belong in a `.env` file that is gitignored,
with a committed `.env.example` holding the placeholders. Never in the
repository, never in the place.

---

## 4. The Open Cloud API key

If you build a bot that reads DataStores, it needs a Roblox **Open Cloud
API key** with DataStore read access for your universe.

**Where it goes:** the bot's environment, never the game. The game does not
need it — the game *writes* the DataStore with its own `DataStoreService`
access.

**How to create one:** Roblox Creator Dashboard → your universe →
**Open Cloud** → **API Keys** → create a key with the `DataStore` scope.

**Never** put it in a `ReplicatedStorage` module, a `Config.lua`, or a
`ServerScriptService` attribute you do not control.

---

## 5. Checklist

- [ ] The webhook URL is in a **Studio attribute**, not in source.
- [ ] `PlayerLoggerConfig.WebhookAttribute` holds the **name**, not the URL.
- [ ] **HTTP Requests** is enabled in the published place's security
      settings.
- [ ] `PlayerLogger.Init()` runs after `PlayerService.Init()`.
- [ ] `NotifyJoin` / `NotifyLeave` are called from the player lifecycle.
- [ ] The embed footer text is changed from "Brainrot Arena" to your game.
- [ ] If you built a bot, its `.env` is gitignored and `.env.example` is
      committed.
