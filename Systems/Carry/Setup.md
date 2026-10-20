# Carry — Setup

How to install the Carry system into a new Rojo project.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[API.md](API.md) · [Dependencies.md](Dependencies.md) ·
[Config.lua](Config.lua)

---

## 1. Copy the files

| From this library | To in your Rojo project |
|---|---|
| `Source/ServerScriptService/Carry/CarryRegistry.lua` | `ServerScriptService/Carry/CarryRegistry.lua` |
| `Source/ServerScriptService/Carry/ToolLockService.lua` | `ServerScriptService/Carry/ToolLockService.lua` |
| `Source/ServerScriptService/Carry/ResetProtectionService.lua` | `ServerScriptService/Carry/ResetProtectionService.lua` |
| `Source/ServerScriptService/Carry/PlayerGrabService.lua` | `ServerScriptService/Carry/PlayerGrabService.lua` |
| `Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage/Config/World/Prompts.lua` |

Plus the shared modules Carry requires (see
[Dependencies.md](Dependencies.md)):

| Shared module | Roblox destination |
|---|---|
| `Shared/CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `Shared/Types/SlotType.lua` | `ReplicatedStorage/Types/SlotType.lua` |

`Remotes.lua` itself requires `Shared/CommonModules/Signals.lua`,
`Shared/Utilities/Validation.lua` and `Shared/Utilities/Debug.lua` — copy
those too (`Signals` → `ReplicatedStorage/Utility/Signals.lua`).

### Rojo mapping

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",

    "ReplicatedStorage": {
      "$className": "ReplicatedStorage",
      "Utility": {
        "$path": "src/ReplicatedStorage/Utility"
      },
      "Types": {
        "$path": "src/ReplicatedStorage/Types"
      },
      "Config": {
        "$path": "src/ReplicatedStorage/Config"
      }
    },

    "ServerScriptService": {
      "$className": "ServerScriptService",
      "Carry": {
        "$path": "src/ServerScriptService/Carry"
      }
    },

    "ServerStorage": {
      "$className": "ServerStorage",
      "Assets": {
        "$path": "src/ServerStorage/Assets"
      }
    }
  }
}
```

**Watch the folder names.** The source uses two different spellings —
`ReplicatedStorage.Utility.*` and `ReplicatedStorage.Types.*`. If you
name the folders differently, either fix the requires or rename the
destinations to match. The relative requires
(`script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug`) assume the
`Carry` folder sits at `ServerScriptService/Carry/` — one level deep.

---

## 2. Third-party packages

**None.** Carry has no Wally dependencies. It uses only Roblox engine
services (`Players`, `ServerStorage`, `ReplicatedStorage`) and the
shared `Remotes` / `Debug` / `SlotType` modules.

The one optional package is whatever you use for profiles
(e.g. `evaera/persist` / ProfileService) — but Carry itself reads and
writes **no** profile fields.

---

## 3. Configuration to tune

Carry **owns** `ReplicatedStorage/Config/World/Prompts.lua`. The values
that matter to Carry:

| Key | Shipped value | What to tune it for |
|---|---|---|
| `Prompts.CarryMaxDistance` | `8` | How close the player must be to grab/place. |
| `Prompts.CarryHoldDuration` | `1` | Seconds to hold Pick Up / Place. |
| `Prompts.CarryVisual.HeadClearanceStuds` | `2.5` | How high the carried object floats above the head. |
| `Prompts.Carry.Actions` | see [Config.lua](Config.lua) | Which actions exist per kind/state. **This is a server-side allowlist — changing it changes what the server accepts.** |
| `Prompts.Carry.ActionText` | labels/keys | Display only. |
| `Prompts.Carry.PerKind` | text | Display only. |

The other per-prompt blocks in `Prompts.lua` (`AnimalPickup`, `EggHatch`,
`Place`, `AnimalSell`, `Steal`, `DoorOpen`, `CenterEggBuy`, `Arena`,
`GearShop`) belong to other systems; leave them as they are if you are
only porting Carry.

`Config.lua` in this folder is a **reference consolidation** of the same
values, not a live module. See its header.

---

## 4. Bootstrap sequence

### 4a. Create the remotes

The two derived services fire `CarryLock` and `ResetProtection` through
`Remotes.FireClient`, so the remote folder must exist and be registered
before the first push.

```lua
-- ServerScriptService/bootstrap.server.lua (or your own bootstrap)
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Remotes = require(ReplicatedStorage.Utility.Remotes)

local remotes = Instance.new('Folder')
remotes.Name = 'Remotes'
remotes.Parent = ReplicatedStorage
for _, name in Remotes.Names do
	local ev = Instance.new('RemoteEvent')
	ev.Name = name
	ev.Parent = remotes
end
Remotes.SetRemotes(remotes)
```

### 4b. Require and init Carry

```lua
local CarryRegistry = require(script.Parent.Carry.CarryRegistry)
local ResetProtectionService = require(script.Parent.Carry.ResetProtectionService)
local ToolLockService = require(script.Parent.Carry.ToolLockService)
local PlayerGrabService = require(script.Parent.Carry.PlayerGrabService)

-- 1. Registry FIRST. Init() clears BOTH the state and the
--    subscriber list, so every subscriber must come after.
CarryRegistry.Init()

-- 2. The three derived services, in any order among themselves.
ResetProtectionService.Init()
ToolLockService.Init()
PlayerGrabService.Init()
```

### 4c. The exact order, and why

```text
Remotes created + Remotes.SetRemotes(folder)
  -> CarryRegistry.Init()          -- clears state AND subscribers
  -> ResetProtectionService.Init() -- subscribes
  -> ToolLockService.Init()        -- subscribes
  -> PlayerGrabService.Init()      -- subscribes + wires Players events
```

`CarryRegistry.Init()` wiping `_subscribers` is the one order-sensitive
step in the whole system. The three derived services each re-subscribe
on their own `Init` so a wrong order is survivable for them — but a
fourth subscriber would silently lose its feed.

### 4d. Player-leave cleanup

Wire this into your `PlayerRemoving` handler:

```lua
Players.PlayerRemoving:Connect(function(player)
	CarryRegistry.Clear(player.UserId)      -- fires the change feed
	ToolLockService.ForgetPlayer(player.UserId)
	ResetProtectionService.ForgetPlayer(player.UserId)
end)
```

`Clear` is what stops the Grab track and unlocks the tool — it does that
through the change feed, so it must come first.

### 4e. Optional: expose the registry to another service

If a service needs the registry but you want to avoid a require cycle
(some services in the source game use an injected setter instead):

```lua
-- e.g. ArenaService.SetCarryRegistry(CarryRegistry)
```

Check the API of whatever you are wiring — the injection pattern is
per-service, not a Carry feature.

---

## 5. Studio assets to author

```text
ServerStorage
└── Assets
    └── Animations
        └── Player
            └── Grab        -- Animation, non-empty AnimationId
```

Rules:

- **Do not clone it.** `PlayerGrabService` resolves it with
  `FindFirstChild` and loads it onto the character's `Animator`.
- **Do not hard-code the `AnimationId`.** The path is the only
  contract.
- **Author it upper-body-only.** It plays at
  `Enum.AnimationPriority.Action4`, which outranks the stock
  `Idle`/`Movement` locomotion tracks. If the clip contains lower-body
  tracks, the character's legs freeze while walking. Re-author without
  them (preferred) or lower the priority. Do **not** fix it by anchoring
  the character or setting CFrames.
- A missing asset is a **warn**, not an error — the carry still works,
  just without a pose. You can ship without it and add it later.

No Workspace hierarchy is required by Carry itself.

---

## 6. Optional: the client side

Carry is server-side only. To get the full UX you also need two client
controllers, which live in the **ClientPresentation** system, not here:

- A **tool-lock controller** that reads `CarryLock` and locks the
  Backpack / hotbar, force-unequipping on `Locked = true`.
- A **reset-button controller** that greys out the reset button on
  `ResetProtection.Protected = true`, and shows the `Reason` string.
- A **carry visual controller** that welds the carried object above the
  player's head using `Prompts.CarryVisual.HeadClearanceStuds`.

The server works without them; the client mirror just stays out of sync.

---

## 7. Smoke test

1. **Registry loads.** Start the server. No errors in the output. If you
   see a require failure for `ReplicatedStorage.Utility.Remotes`, the
   folder name or path is wrong.
2. **Push wiring.** Grab an animal in-game. The client's `CarryLock`
   should arrive with `Locked = true` within a frame of the grab. If the
   client never locks, the remote folder was not registered with
   `Remotes.SetRemotes` before the first push.
3. **Tool lock.** With an animal in hand, try to equip and swing a bat.
   The bat should be unequipped on grab and refused on activation.
4. **Reset gate.** Open the reset menu while carrying. The reset button
   should be greyed out with the reason (`CarryingAnimal`).
5. **Pose.** The character should raise its arms while carrying. If it
   does not move at all, the `Grab` asset is missing or its
   `AnimationId` is empty — the server logs
   `'Grab animation asset missing: ServerStorage.Assets.Animations.Player.Grab'`.
   If the arms move but the **legs freeze**, the clip has lower-body
   tracks — re-author it.
6. **Single carry.** Try to grab a second object while carrying the
   first. It should be refused (the Inventory system's dispatcher
   rejects it, and `CarryRegistry.Set` would return
   `PlayerAlreadyCarrying`).
7. **Release.** Place the object. `CarryLock` should arrive with
   `Locked = false`, the reset button should re-enable, and the pose
   should stop.
8. **Recovery.** Die while carrying. The object should be returned to
   its slot by the death/recovery path (owned by the PlayerData
   system), `CarryLock` should flip to `false`, and the pose should stop.
9. **Leave.** Leave while carrying. The server should log the recovery
   and clear the registry entry with no errors.
10. **Order check.** Deliberately call `CarryRegistry.Init()` *after*
    `ToolLockService.Init()` and confirm the tool lock stops updating —
    that is the subscriber-wipe footgun, and it is worth seeing once.

### Running the specs

`Tests/CarryRegistry.spec.lua` covers the registry only. It requires the
shared `Tests/_Helpers.lua` and **Roblox Studio** (the suite is a
Studio test, not a standalone Luau runner). See `../../Tests/README.md`.

`ToolLockService`, `ResetProtectionService` and `PlayerGrabService` have
**no spec in this library** — their logic is thin, but the change-only
push behaviour and `ForgetPlayer` are worth testing in a new game.
