# External Services

**Status: there is no HTTP-client abstraction in the source game. The one
outbound HTTP call is made directly, and it is documented here.**

---

## 1. The complete outbound surface

Every network call the source game makes:

| Call | From | To | When |
|---|---|---|---|
| `DataStoreService` (via ProfileService) | `PlayerService` | Roblox DataStore | Profile load / save |
| `DataStoreService` (direct) | `PlayerRegistry` | Roblox DataStore | Registry upsert on join / leave |
| `OrderedDataStore` | `LeaderboardService` | Roblox OrderedDataStore | Leaderboard refresh |
| `MarketplaceService` | `ShopService`, `ShopController` | Roblox Marketplace | Purchases, receipts, product info |
| `HttpService:RequestAsync` | `PlayerLogger` | `discord.com/api/webhooks/…` | Join / leave / milestone embeds |
| `AnalyticsService` | `FunnelService` | Roblox telemetry | Funnel steps |

**There is no other HTTP call anywhere in `src/`.** No third-party API, no
webhook service, no REST client, no game backend.

---

## 2. Why there is no abstraction layer

The source game makes **one** HTTP call, to one host, with one payload
shape. A wrapper would have been a wrapper around one call site.

If you add a second external service, you will want an abstraction. Here is
the shape that fits this codebase's conventions:

```lua
-- ServerScriptService/Integration/MyService.lua
local MyService = {}

function MyService.Init()
    -- read config, validate, spawn a worker
end

function MyService.Send(payload): boolean
    -- pcall-wrapped, returns false on failure
    -- NEVER gameplay-critical
end

return table.freeze(MyService)
```

The conventions it should follow, taken from `FunnelService` and
`PlayerLogger`:

- **`pcall` the send.** A telemetry or webhook failure must never cost a
  player a purchase. The source game's rule: *"Never gameplay-critical."*
- **Never replicate a credential to a client.** A secret belongs in a
  Studio attribute, an `HttpService:GetSecret`, or an environment variable.
- **Never put a secret in `ReplicatedStorage`.** It replicates.
- **Queue and rate-limit.** `PlayerLogger` caps its queue at 200, drop-oldest,
  and honours Discord's 429 with `Retry-After`.
- **Degrade, don't crash.** `PlayerLogger` falls back to registry-only mode
  when HTTP is disabled, with one warning.

---

## 3. The Discord webhook — the only HTTP call

Full detail is in [`../Discord/README.md`](../Discord/README.md). The parts
that matter here:

| Property | Value |
|---|---|
| Method | `POST` |
| URL | read from a `ServerScriptService` attribute at boot |
| Header | `Content-Type: application/json` |
| Body | `{ username = <game name>, embeds = { <embed> } }` |
| Success | 2xx |
| Rate limit | 429 → honour `Retry-After`, capped at 60s |
| Disabled | `HttpService.HttpEnabled == false` → registry-only mode, one warning |
| Queue | 200 cap, drop-oldest |
| Interval | 1.2s between sends |
| Retries | 3 attempts, backoff `{2, 8}` |

**Requires "Allow HTTP Requests" in the place's security settings.**

---

## 4. Adding a new external service

### 4.1 The checklist

- [ ] The credential is supplied via a **Studio attribute**, an
      `HttpService:GetSecret`, or an environment variable — **never** a
      `ReplicatedStorage` constant and **never** in source.
- [ ] The URL is validated before use (the source game does this:
      `string.match(raw, '^https://discord%.com/api/webhooks/')`).
- [ ] The send is `pcall`-wrapped and returns a boolean.
- [ ] Failures are logged via `Debug.Warn` with a tag, and **do not** affect
      gameplay.
- [ ] The request is rate-limited and queued if it can burst.
- [ ] The payload contains **no PII** beyond what the service needs.
- [ ] The service is documented in this folder: what it sends, where, and
      how to disable it.

### 4.2 The secrets rule, restated

> **Secrets must never be included in the library. Use placeholders and
> explain how the future game should configure secrets securely.**

The library contains no credentials. The one place a credential would have
gone — `PlayerLoggerConfig.WebhookAttribute` — is documented in
`SECURITY_NOTES.md` §2 and §3, and the library copy holds the *attribute
name* rather than the URL.

---

## 5. External APIs used, and their permissions

| API | Permission needed | Where to enable |
|---|---|---|
| `DataStoreService` | Studio → Game Settings → Security → **Enable Studio Access to API Services** | Studio only; published places need nothing. |
| `OrderedDataStore` | same | same |
| `MarketplaceService` | none | — |
| `HttpService` (webhook) | **Allow HTTP Requests** | Published place → Game Settings → Security. **Required in production**; the logger degrades without it. |
| `AnalyticsService` | none | — |

---

## 6. The `discord_bot/` service (out of scope)

The source repo has a Python Discord bot at `discord_bot/`. It is:

- **gitignored** and never in `src/`,
- **not** part of this library,
- decoupled from the Luau code — it talks only through the DataStores, via
  the **Roblox Open Cloud API**.

Its credentials live in a gitignored `.env`, with a committed `.env.example`
holding the placeholders. Its contract with the game is documented in
[`../Discord/README.md`](../Discord/README.md) §3.2.
