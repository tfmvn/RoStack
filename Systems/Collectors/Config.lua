--!strict
--[[
	Collectors — consolidated tunables
	==================================

	A single, documented view of every value the Collectors system
	reads. The authoritative copies live in the three config modules
	below; this file is a CONSOLIDATION, not a replacement. Copy any
	value you change back into the module that owns it, or replace the
	three `require` calls at the bottom with your own modules and
	delete the local copies.

	Owning modules (the authoritative source of truth):
	  * ReplicatedStorage.Config.Presentation.Audio  -- sound pool size
	  * ReplicatedStorage.Config.Systems.Debug        -- debug switches
	  * ReplicatedStorage.Config.World.Bases          -- collector look

	Not owned here (owned elsewhere, referenced only):
	  * Economy.Money.*                 -- what a collection pays
	  * Animals.SellBaseValue           -- what the pool is worth
	  * CollectorArrival timing         -- lives in the service

	Every value below carries: default, meaning, valid range,
	whether it is safe to change, which module reads it, and
	whether it is a placeholder.
]]

local CollectorsConfig = {}

-- =========================================================================
-- Audio
-- =========================================================================

-- How many collect sounds may play at once.
-- Default: 4
-- Meaning: the size of the round-robin pool `CollectFeedback` cycles
--   when a collection fires. Two collections in the same frame play two
--   different sounds rather than cutting each other off.
-- Valid range: integer >= 1. 0 would silence every collection.
-- Safe to change: YES -- presentation only. No gameplay effect.
-- Read by: CollectFeedback (the pool size it cycles).
-- Placeholder: NO -- a real, tuned value.
CollectorsConfig.CollectSoundPoolSize = 4

-- =========================================================================
-- Debug
-- =========================================================================

-- Whether debug audio is enabled.
-- Default: false
-- Meaning: the master switch for the debug sound bank. When false, the
--   debug sounds never load or play. This is NOT the same as the
--   game's normal sound effects, which are governed by
--   `Presentation.Audio`.
-- Valid range: boolean.
-- Safe to change: YES -- but leave it false in production. It is a
--   developer aid, and it is deliberately off by default.
-- Read by: CollectFeedback (gates the debug-audio branch).
-- Placeholder: NO -- a real, tuned value.
CollectorsConfig.DebugAudioEnabled = false

-- =========================================================================
-- Collector appearance
-- =========================================================================

-- The colour of the collector part.
-- Default: Color3.fromRGB(85, 255, 127) -- bright green
-- Meaning: the physical collector's body colour.
-- Valid range: any Color3.
-- Safe to change: YES -- presentation only.
-- Read by: Bases.Collector (authoritative); the collector part is
--   authored in Studio, so this only applies to a part the service
--   builds itself.
-- Placeholder: NO -- a real, tuned value.
CollectorsConfig.CollectorPartColor = Color3.fromRGB(85, 255, 127)

-- The height, in studs, of a collector part the service builds.
-- Default: 4
-- Meaning: the vertical size of a collector that does not already
--   exist in the map. Authored map parts are NEVER resized — this
--   only applies to a missing one.
-- Valid range: number > 0.
-- Safe to change: YES -- presentation only.
-- Read by: Bases.Collector.Height.
-- Placeholder: NO -- a real, tuned value.
CollectorsConfig.CollectorHeight = 4

-- The transparency of a collector part the service builds.
-- Default: 0.6
-- Meaning: how see-through an auto-built collector is. 0 is opaque,
--   1 is invisible.
-- Valid range: number in [0, 1].
-- Safe to change: YES -- presentation only.
-- Read by: Bases.Collector.Transparency.
-- Placeholder: NO -- a real, tuned value.
CollectorsConfig.CollectorTransparency = 0.6

-- =========================================================================
-- INVARIANTS
-- =========================================================================
--
-- * The collector's world-space amount label colour is
--   `Bases.Collector.AmountTextColor`. It is not duplicated here
--   because only the label renderer reads it, and that renderer is
--   in the stand-presentation code, not in this system.
--
-- * A collector with no `Bases.Collector` entry at all is a FATAL
--   error at base registration. `BaseService.RegisterBases` requires
--   one collector per base, and `Tests/_Helpers.lua`'s
--   `EnsureCollectors` exists purely to satisfy that requirement in
--   tests. Do not remove the collector requirement.

-- =========================================================================
-- Optional: wire this file to the authoritative modules
-- =========================================================================
--
-- Uncomment to make this consolidation the live source of truth. The
-- defaults above are the current live values, so switching over is a
-- no-op until you edit something.

-- local Audio = require(game:GetService('ReplicatedStorage').Config.Presentation.Audio)
-- local Debug = require(game:GetService('ReplicatedStorage').Config.Systems.Debug)
-- local Bases = require(game:GetService('ReplicatedStorage').Config.World.Bases)
-- CollectorsConfig.CollectSoundPoolSize = Audio.Collect.PoolSize
-- CollectorsConfig.DebugAudioEnabled = Debug.Audio.Enabled
-- CollectorsConfig.CollectorPartColor = Bases.Collector.PartColor
-- CollectorsConfig.CollectorHeight = Bases.Collector.Height
-- CollectorsConfig.CollectorTransparency = Bases.Collector.Transparency

return table.freeze(CollectorsConfig)
