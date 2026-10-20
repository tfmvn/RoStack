--!strict
--[[
	Tutorials — consolidated tunables
	=================================
	A read-only, commented copy of every tunable the tutorial
	system exposes.

	This file does NOT change the behaviour of the running game:
	`TutorialService` does not require it. The tunables live as
	literals inside
	`ServerScriptService/Tutorial/TutorialService.lua`.

	It exists so a new game can see every knob in one place and copy
	the values it wants to change into its own copy of the service.

	When you fork the system, edit the literals in
	`TutorialService.lua` directly (and mirror them here), or replace
	this module with a real config and change the requires in
	`TutorialService.lua` to point at it.
]]

local TutorialConfig = {}

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- The CollectionService tag PREFIX. The full tag is
-- `<prefix>_<userId>`.
--
-- DEFAULT: 'TutorialTarget'.
-- MEANING: the server tags the tracked egg/animal model with
--   `'TutorialTarget_<userId>'` and the client controller finds it by
--   the same name. The tag MUST be per-player: a shared
--   'TutorialTarget' tag would expose every player's tracked object
--   to every client, and each client would beam at whoever was
--   tagged last.
-- VALID RANGE: any string that is safe in an Instance name.
-- SAFE TO CHANGE: yes, but the CLIENT must derive the same name.
--   The client reads it from the same rule
--   (`<prefix>_<userId>`); changing it means changing both sides.
-- READ BY: `TutorialService.TagFor` (local `TutorialService.TAG` at
--   line 74).
-- PLACEHOLDER: no.
TutorialConfig.TagPrefix = 'TutorialTarget'

-- ---------------------------------------------------------------------------
-- Client assets
-- ---------------------------------------------------------------------------

-- The InsertService asset id for the tutorial Beam template.
--
-- DEFAULT: 14403995847.
-- MEANING: loaded once at `TutorialService.Init()` in a spawned
--   thread (so it never stalls boot) and parented to
--   `ReplicatedStorage` as `TutorialBeamTemplate`. The client
--   inspects it and adapts — ANY instance type is accepted (Model,
--   MeshPart, Beam, Decal, ...). If the load fails, the exact Roblox
--   error is printed and the client falls back to a beam it builds
--   itself.
-- VALID RANGE: any Roblox asset id the experience may load.
-- SAFE TO CHANGE: yes, if the asset is public to the experience.
-- READ BY: `TutorialService.BeamAssetId` (line 90).
-- PLACEHOLDER: yes — this is Brainrot Arena's asset. Replace it, or
--   author your own Beam template in `ReplicatedStorage` under the
--   name `TutorialBeamTemplate` (the publisher then skips the load
--   entirely).
TutorialConfig.BeamAssetId = 14403995847

-- The name the published template is given in `ReplicatedStorage`.
--
-- DEFAULT: 'TutorialBeamTemplate'.
-- MEANING: the client looks the template up by this name. If an
--   instance with this name already exists, the publisher returns
--   immediately and does not load anything.
-- VALID RANGE: any Instance name.
-- SAFE TO CHANGE: yes, if the client uses the same name.
-- READ BY: `TutorialService._publishBeamTemplate` (line 159).
-- PLACEHOLDER: no.
TutorialConfig.BeamTemplateName = 'TutorialBeamTemplate'

-- ---------------------------------------------------------------------------
-- Recovery sweep
-- ---------------------------------------------------------------------------

-- The recovery sweep period, in seconds.
--
-- DEFAULT: 1.
-- MEANING: `TutorialService.Start()` accumulates `RunService`
--   heartbeat `dt` and fires `RecoverFor` for every ACTIVE tutorial
--   player once the accumulator reaches this value. The sweep
--   re-validates the tracked egg/animal ids against the live
--   registries, so a destroyed mid-hatch egg or a parked arena
--   stand does not strand the player.
-- VALID RANGE: >= 0.1. Lower values cost more registry lookups per
--   second; higher values make the guide react more slowly to a
--   replaced target.
-- SAFE TO CHANGE: yes.
-- READ BY: `TutorialService.Start` (the accumulator check at line
--   1060).
-- PLACEHOLDER: no.
TutorialConfig.RecoverySweepSeconds = 1

-- ---------------------------------------------------------------------------
-- Step chain
-- ---------------------------------------------------------------------------

-- The ordered step names.
--
-- DEFAULT: the 11 names below.
-- MEANING: exactly one step is active per player. `Completed` is
--   terminal. The chain is NOT strictly monotonic — `ArenaCancelled`
--   moves `ArenaStarted` back to `StartArena`.
-- VALID RANGE: n/a.
-- SAFE TO CHANGE: yes, but you must edit `TutorialService.NextStep`
--   in the same pass. The transition table there is exhaustive:
--   anything not listed returns `nil` and changes nothing.
-- READ BY: `TutorialService.Step` (line 60) and every `NextStep`
--   branch.
-- PLACEHOLDER: yes — this is Brainrot Arena's onboarding chain.
TutorialConfig.Steps = {
	'BuyEgg',
	'WaitForEgg',
	'HatchEgg',
	'PickUpAnimal',
	'PlaceAnimal',
	'StartArena',
	'ArenaStarted',
	'ArenaEnded',
	'UpgradeAnimal',
	'LockBase',
	'Completed',
}

-- The signal channels the tutorial subscribes to.
--
-- DEFAULT: the 10 names below.
-- MEANING: these are the channels connected in `TutorialService.Init()`.
--   The gameplay services fire them via `TutorialSignals.Fire(name,
--   payload)`. Every one of them must also appear as a `name ==`
--   branch in `NextStep` (plus `ContinueConfirmed`, which is
--   internal and never fired on the bus).
-- VALID RANGE: n/a.
-- SAFE TO CHANGE: yes, in both `Init()` and `NextStep`.
-- READ BY: `TutorialService.Init` (the `channels` list at line 1018).
-- PLACEHOLDER: yes — these are Brainrot Arena's gameplay events.
TutorialConfig.Channels = {
	'EggPurchased',
	'EggPlaced',
	'EggHatched',
	'AnimalPickedUp',
	'AnimalPlaced',
	'ArenaStarted',
	'ArenaEnded',
	'ArenaCancelled',
	'AnimalUpgraded',
	'BaseLocked',
}

-- ---------------------------------------------------------------------------
-- External configuration the system reads
-- ---------------------------------------------------------------------------

-- The starter egg rarity source.
--
-- DEFAULT: 'EggConfig.GetStarterRarity()', falling back to
--   'RarityDefs.Order[1]', then to the literal 'Common'.
-- MEANING: every new tutorial player targets the SAME canonical
--   starter rarity (the cheapest egg). It is informational only —
--   the client derives the same value from the same config; the
--   server never invents an egg target.
-- VALID RANGE: a rarity id present in `RarityDefs.Order`.
-- SAFE TO CHANGE: no — but see the note below.
-- READ BY: `TutorialService.StarterEggRarity` (line 100).
-- PLACEHOLDER: partially. `EggConfig.GetStarterRarity` DOES NOT EXIST
--   in this codebase, so the `pcall` fails and the function always
--   returns `RarityDefs.Order[1]` ('Common'). The result is correct
--   today (Common is the cheapest egg at 100) but the value comes
--   from the rarity DISPLAY ORDER, not from a price scan. Add
--   `GetStarterRarity()` to your egg config to make the contract
--   real.
TutorialConfig.StarterRaritySource = 'EggConfig.GetStarterRarity'

-- The arena-slot index offset.
--
-- DEFAULT: 1000 (from `ReplicatedStorage.Types.SlotType`).
-- MEANING: a slot id whose trailing `:<N>` has `N >= this` is an
--   ARENA slot. The tutorial requires the tracked animal to be placed
--   in an arena slot before the chain advances to `StartArena`.
-- VALID RANGE: n/a — it is a shared constant.
-- SAFE TO CHANGE: no. It must match `SlotType.ArenaSlotIndexBase`.
-- READ BY: `TutorialService._isArenaSlotId` (line 185, via
--   `SlotType.ArenaSlotIndexBase`).
-- PLACEHOLDER: no.
TutorialConfig.ArenaSlotIndexBase = 1000

return table.freeze(TutorialConfig)
