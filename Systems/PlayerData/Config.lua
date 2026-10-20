--!strict
--[[
	PlayerData — consolidated tunables
	===================================

	A single, documented view of every value the PlayerData system
	reads. The authoritative copies live in the config modules below;
	this file is a CONSOLIDATION, not a replacement. Copy any value you
	change back into the module that owns it, or replace the `require`
	calls at the bottom with your own modules and delete the local
	copies.

	Owning modules (the authoritative source of truth):
	  * ReplicatedStorage.Config.Economy.Money    -- starting balance
	  * ReplicatedStorage.Config.Systems.Debug     -- debug switches
	  * ReplicatedStorage.Config.Creatures.Progression -- level normalisation

	Not owned here (owned elsewhere, referenced only):
	  * The PROFILE TEMPLATE -- it lives INSIDE PlayerService.lua as
	    `STUDIO_PROFILE_TEMPLATE`. It is this game's content, and it is
	    documented in `API.md`, not duplicated here.
	  * The profile DataStore name -- a module-local literal inside
	    PlayerService.lua. See "Environment-specific" below.
	  * Types.PlayerDataType -- STALE. Do not use it as the schema.

	Every value below carries: default, meaning, valid range,
	whether it is safe to change, which module reads it, and
	whether it is a placeholder.
]]

local PlayerDataConfig = {}

-- =========================================================================
-- Environment-specific (MUST be changed for a new game)
-- =========================================================================

-- The profile DataStore name.
-- Default: 'p7_PlayerData_Money_v1_dev_1'
-- Meaning: the ProfileService store name, and therefore the identity
--   of the whole saved-game schema. It is a module-local literal in
--   `PlayerService.lua` (line 115) — it is NOT in a config module,
--   because renaming it is a one-line, deliberate, ship-once decision.
--   The name encodes three things: the `p7_` source-game prefix, the
--   `v1` schema version, and the `_dev_1` environment suffix.
-- Valid range: any string. Use only characters Roblox DataStore names
--   allow.
-- Safe to change: YES for a new game, and you SHOULD change it.
--   Renaming ORPHANS every existing profile: the old data stays in
--   the old store and the new store starts empty. For a new game that
--   is exactly what you want. For a port of an existing game it is
--   data loss, so decide before you ship, not after.
-- Read by: PlayerService (the only module that touches ProfileService).
-- Placeholder: YES -- it carries the source game's identifier.
PlayerDataConfig.ProfileStoreName = 'p7_PlayerData_Money_v1_dev_1'

-- The prefix of the per-profile key.
-- Default: 'Player_'
-- Meaning: the key a profile is stored under is
--   `'Player_' .. tostring(userId)`. The literal `Player_` prefix is
--   part of the key, not a bare userId.
-- Valid range: any string.
-- Safe to change: NO for a game with existing players — it changes
--   every profile key, and every existing profile is orphaned.
--   Changing it for a NEW game is fine.
-- Read by: PlayerService.LoadPlayerData.
-- Placeholder: NO -- a real, working value.
PlayerDataConfig.ProfileKeyPrefix = 'Player_'

-- The profile load policy.
-- Default: 'ForceLoad'
-- Meaning: how a profile is opened when it may already be locked by
--   another session. 'ForceLoad' takes the session lock. The other
--   ProfileService option is 'Load', which refuses if the profile is
--   already in use.
-- Valid range: 'ForceLoad' or 'Load'.
-- Safe to change: NO for a live game. 'Load' would kick any player
--   who is already online in another server, which is a playable
--   game with a shared world and a broken one without.
-- Read by: PlayerService.LoadPlayerData.
-- Placeholder: NO -- a real, tuned value.
PlayerDataConfig.ProfileLoadPolicy = 'ForceLoad'

-- =========================================================================
-- Wallet
-- =========================================================================

-- The balance a brand-new profile starts with.
-- Default: '5000'
-- Meaning: the seed for a first-join wallet. It is a BigNumber decimal
--   STRING, never a Lua number — a number above 2^53 silently loses
--   precision, which is the entire reason `BigNumber` exists.
--   The reconcile pass writes this value only when the profile has no
--   `Money` field at all, so changing it never touches an existing
--   balance.
-- Valid range: any BigNumber decimal string, '0' or more, no signs.
-- Safe to change: YES -- affects new players only. Raising it far
--   enough skips the early game entirely, so re-solve the early
--   progression first.
-- Read by: Economy.Money.StartingMoney (authoritative);
--   PlayerService.LoadPlayerData seeds from it.
-- Placeholder: NO -- a real, tuned value.
PlayerDataConfig.StartingMoney = '5000'

-- =========================================================================
-- Debug
-- =========================================================================

-- Whether persistence is skipped entirely.
-- Default: false
-- Meaning: when true, the profile is an in-memory stub — no DataStore
--   read, no DataStore write, and every join starts from a fresh
--   template. It exists so a developer can iterate without touching
--   live data.
-- Valid range: boolean.
-- Safe to change: YES for development. It MUST be false in
--   production — with it on, every player's progress is discarded
--   silently, with no error and no warning.
-- Read by: Debug.SkipPersistence (authoritative); PlayerService
--   branches on it in the load and cleanup paths.
-- Placeholder: NO -- a real, tuned value.
PlayerDataConfig.SkipPersistence = false

-- =========================================================================
-- Levels
-- =========================================================================

-- The hard level ceiling.
-- Default: 100
-- Meaning: the maximum level a stored animal can have. Used to
--   sanitise a level read out of a profile.
-- Valid range: integer >= 1.
-- Safe to change: NO for a live game -- see `Inventory/Config.lua` for
--   the full argument. It is repeated here because PlayerData reads it
--   directly.
-- Read by: Progression.MaxLevel (authoritative).
-- Placeholder: NO -- a real, tuned value.
PlayerDataConfig.MaxLevel = 100

-- =========================================================================
-- INVARIANTS
-- =========================================================================
--
-- * `profile.Data.Money` is a BigNumber decimal STRING. It is NOT a
--   Lua number, ever. `PlayerService`'s ~20 repair blocks enforce
--   this on load, and `profile:Reconcile()` alone does NOT -- a
--   profile written by an older build can carry `Money = 5000` (a
--   number) and `Reconcile` will leave it there. Do not remove the
--   repair blocks.
--
-- * `PlayerService` is the ONLY module in the game that touches
--   ProfileService. Every other system goes through its mutators
--   (`AddAnimal`, `RemoveAnimal`, `AddEgg`, `ConsumeEggIntoAnimal`,
--   `SetAnimalSlot`, `BumpStat`, `AssignBase`, `WipeUser`, ...). That
--   is what makes the profile a single-writer surface, and it keeps
--   the audit and the repair blocks in one place. Do not require
--   ProfileService anywhere else -- add a mutator instead.
--
-- * `PersistenceAudit` runs on EVERY load, before any other system
--   can read the profile. It repairs, quarantines, or re-homes invalid
--   owned-object records. It is not optional.
--
-- * `profile.Data.Multipliers` is DEPRECATED compat data. It is
--   always `{ Money = 1 }` in a legitimate profile and nothing writes
--   any other value. Do not add code that writes it.
--
-- * `profile.Data.Tutorial.Step = 'BuyEgg'` is this game's step name.
--   Replace it with your own.

-- =========================================================================
-- Optional: wire this file to the authoritative modules
-- =========================================================================
--
-- Uncomment to make this consolidation the live source of truth. The
-- defaults above are the current live values, so switching over is a
-- no-op until you edit something.
--
-- Note that `ProfileStoreName`, `ProfileKeyPrefix` and
-- `ProfileLoadPolicy` are module-locals inside `PlayerService.lua`,
-- not config-module fields. To make this file authoritative for them
-- you must edit `PlayerService.lua` to read from here -- which means
-- the consolidation file has to be requirable from `PlayerService`,
-- and `PlayerService` is in `ServerScriptService`, while this file
-- would live in `ReplicatedStorage`. That is a legal but unusual
-- arrangement. Editing the three literals in `PlayerService.lua`
-- directly is the simpler path.

-- local Money = require(game:GetService('ReplicatedStorage').Config.Economy.Money)
-- local Debug = require(game:GetService('ReplicatedStorage').Config.Systems.Debug)
-- local Progression = require(game:GetService('ReplicatedStorage').Config.Creatures.Progression)
-- PlayerDataConfig.StartingMoney = Money.StartingMoney
-- PlayerDataConfig.SkipPersistence = Debug.SkipPersistence
-- PlayerDataConfig.MaxLevel = Progression.MaxLevel

return table.freeze(PlayerDataConfig)
