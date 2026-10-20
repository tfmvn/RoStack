--!strict
--[[
	Combat — consolidated tunables
	================================
	Single place to see every number the Combat system reads, copied
	verbatim from the source game's canonical config
	(`ReplicatedStorage/Config/Economy/Gear.lua`, combat table
	`Gear.Combat`).

	This is a DOCUMENTATION-ONLY consolidation. It is NOT required by
	`BatService` or `RagdollService` — the runtime reads
	`ReplicatedStorage.Config.Economy.Gear` directly. Keep the two in
	sync, or replace the config module's combat table with a require of
	this file.

	Every field below documents: default, meaning, valid range, whether
	it is safe to change, which module reads it, and whether it is a
	placeholder.
]]

local Config = {}

-- =====================================================================
-- Bat tuning (mirrors Gear.Combat.COMBAT_ENTRIES)
-- =====================================================================

-- How long, in seconds, between two swings of the same bat. The
-- server rejects a swing fired sooner than this; the client uses the
-- same number for a purely cosmetic local input gate.
-- Meaning: per-attacker swing rate limit.
-- Valid range: number > 0 (enforced by Gear.Combat.Validate).
-- Safe to change: YES. Pure rate limiting, no persistence.
-- Read by: BatService.onSwing (server, authoritative);
--           client BatController.onActivated (cosmetic only).
-- Placeholder: no — the values are tuned per bat tier, but the
--              source header notes the whole combat table was
--              authored as "NEW sensible defaults" because no combat
--              numbers existed in the project before this feature.
Config.SwingCooldown = {
	DefaultBat = 1.0,
	SilverBat = 0.8,
	GoldBat = 0.7,
	DiamondBat = 0.65,
	ObsidianBat = 0.6,
	CrystalBat = 0.55,
	HackerBat = 0.6,
	GalaxyBat = 0.5,
}

-- The size of the bat's hitbox, in studs, as a Vector3 (X, Y, Z).
-- Meaning: the volume in front of the attacker that can be hit.
-- Valid range: all three components > 0.
-- Safe to change: YES, but remember the runtime multiplies this by
--   HARD-CODED 1.75 before the spatial query (BatService.lua:213).
--   The value here is therefore a BASE size, not the in-world size.
-- Read by: BatService.onSwing (hitbox query).
-- Placeholder: no.
Config.HitboxSize = {
	DefaultBat = Vector3.new(4.5, 5, 5.5),
	SilverBat = Vector3.new(5, 5, 6),
	GoldBat = Vector3.new(5, 5, 6),
	DiamondBat = Vector3.new(5.5, 5.5, 6.5),
	ObsidianBat = Vector3.new(5.5, 5.5, 6.5),
	CrystalBat = Vector3.new(6, 6, 7),
	HackerBat = Vector3.new(5.5, 5.5, 6.5),
	GalaxyBat = Vector3.new(6.5, 6.5, 7.5),
}

-- Where the hitbox sits relative to the attacker's HumanoidRootPart,
-- as a CFrame offset. The offset is NOT scaled by the 1.75x multiplier.
-- Meaning: reach and height of the swing volume.
-- Valid range: any CFrame; -Z is forward (Roblox LookVector is -Z).
-- Safe to change: YES.
-- Read by: BatService.onSwing (hitbox centre).
-- Placeholder: no.
Config.HitboxOffset = {
	DefaultBat = CFrame.new(0, 0, -2.8),
	SilverBat = CFrame.new(0, 0, -3),
	GoldBat = CFrame.new(0, 0, -3),
	DiamondBat = CFrame.new(0, 0, -3.2),
	ObsidianBat = CFrame.new(0, 0, -3.2),
	CrystalBat = CFrame.new(0, 0, -3.5),
	HackerBat = CFrame.new(0, 0, -3.2),
	GalaxyBat = CFrame.new(0, 0, -3.7),
}

-- Horizontal knockback speed, in studs/second, applied to the target's
-- HumanoidRootPart.AssemblyLinearVelocity.
-- Meaning: how far the target is shoved.
-- Valid range: number >= 0 (enforced by Gear.Combat.Validate).
-- Safe to change: YES.
-- Read by: BatService.onSwing (knockback step).
-- Placeholder: no.
Config.KnockbackHorizontal = {
	DefaultBat = 60,
	SilverBat = 70,
	GoldBat = 80,
	DiamondBat = 90,
	ObsidianBat = 100,
	CrystalBat = 115,
	HackerBat = 90,
	GalaxyBat = 130,
}

-- Vertical knockback speed, in studs/second, added on top of the
-- horizontal vector.
-- Meaning: how high the target is launched.
-- Valid range: number >= 0 (enforced by Gear.Combat.Validate).
-- Safe to change: YES.
-- Read by: BatService.onSwing (knockback step).
-- Placeholder: no.
Config.KnockbackVertical = {
	DefaultBat = 20,
	SilverBat = 25,
	GoldBat = 30,
	DiamondBat = 35,
	ObsidianBat = 40,
	CrystalBat = 45,
	HackerBat = 35,
	GalaxyBat = 50,
}

-- How long, in seconds, the target stays ragdolled.
-- Meaning: duration of the ragdoll state.
-- Valid range: number > 0 (enforced by Gear.Combat.Validate). A
--   non-number / NaN / <= 0 makes RagdollService.Ragdoll return
--   false and the hit silently skips the ragdoll.
-- Safe to change: YES.
-- Read by: BatService.onSwing -> RagdollService.Ragdoll.
-- Placeholder: no.
Config.RagdollDuration = {
	DefaultBat = 1.25,
	SilverBat = 1.5,
	GoldBat = 1.75,
	DiamondBat = 2.0,
	ObsidianBat = 2.25,
	CrystalBat = 2.5,
	HackerBat = 2.0,
	GalaxyBat = 2.75,
}

-- Extra time, in seconds, after the ragdoll ends during which the
-- target cannot be ragdolled again. The immunity window is
-- `RagdollDuration + RagdollImmunity` from the moment of the hit.
-- Meaning: anti-spam window so repeated bat hits cannot chain-ragdoll.
-- Valid range: number >= 0 (enforced by Gear.Combat.Validate).
-- Safe to change: YES, but 0 means a target can be re-ragdolled the
--   instant it gets up.
-- Read by: BatService.onSwing (writes BatService._nextRagdollAt).
-- Placeholder: no. NOTE: identical (1.25) for EVERY bat in the
--              source table — it is a constant in practice, not a
--              per-tier tuning knob.

Config.RagdollImmunity = {
	DefaultBat = 1.25,
	SilverBat = 1.25,
	GoldBat = 1.25,
	DiamondBat = 1.25,
	ObsidianBat = 1.25,
	CrystalBat = 1.25,
	HackerBat = 1.25,
	GalaxyBat = 1.25,
}

-- =====================================================================
-- Hard-coded constants (NOT in the source config — documented so a
-- porter does not hunt for them)
-- =====================================================================

-- The hitbox Size is multiplied by this before the spatial query.
-- Meaning: the real in-world hitbox is 1.75x the configured Size.
-- Valid range: number > 0.
-- Safe to change: only in code (BatService.lua:213). It is NOT a
--   config value, so changing it means editing the service.
-- Read by: BatService.onSwing.
-- Placeholder: no.
Config.HitboxSizeMultiplier = 1.75

-- Seconds a cloned hit SFX is kept in the world before Debris removes
-- it.
-- Meaning: SFX lifetime.
-- Valid range: number > 0.
-- Safe to change: only in code (BatService.lua:58, SFX_LIFETIME_S).
-- Read by: BatService.playHitSfx.
-- Placeholder: no.
Config.HitSfxLifetimeSeconds = 6

-- Number of distinct hit sounds. The runtime cycles 1 -> 2 -> 3 -> 1
-- across hits, globally (not per attacker).
-- Meaning: hit SFX pool size.
-- Valid range: 1..3 (the resolver clamps the index to this range).
-- Safe to change: only in code. The three names are hard-coded as
--   'Attack1'..'Attack3' at BatService.lua:78-79.
-- Read by: BatService.playHitSfx / resolveSfx.
-- Placeholder: no.
Config.HitSfxCount = 3

-- The idle poll interval, in seconds, used while waiting for a
-- ragdolled target to land.
-- Meaning: how often the landing wait re-checks.
-- Valid range: number > 0.
-- Safe to change: only in code (RagdollService.lua:68).
-- Read by: RagdollService.applyRagdoll.
-- Placeholder: no.
Config.RagdollLandingPollSeconds = 0.05

-- =====================================================================
-- Gear shop catalog (mirrors Gear.ENTRIES — the same config module)
-- =====================================================================

-- Id -> price, as a BigNumber decimal STRING (never a number).
-- Meaning: shop price per gear.
-- Valid range: a non-empty decimal string.
-- Safe to change: YES, but every price and every Description in the
--   source catalog is explicitly marked PLACEHOLDER ("initial values,
--   not final balance"). Tune before release.
-- Read by: GearShopService (the Shops system), not by Combat.
-- Placeholder: YES.
Config.GearPrice = {
	SpeedCoil = '500',
	SilverBat = '1000',
	GravityCoil = '5000',
	GoldBat = '7500',
	CoilCombo = '20000',
	DiamondBat = '25000',
	ObsidianBat = '30000',
	CrystalBat = '50000',
	InvisibleCloak = '55000',
	HackerBat = '70000',
	GalaxyBat = '0',
	DefaultBat = '0',
}

-- Id -> required completed rebirth count to unlock the gear.
-- Meaning: the gear unlock ladder.
-- Valid range: integer >= 0.
-- Safe to change: YES.
-- Read by: GearShopService via Gear.IsLocked.
-- Placeholder: no.
Config.GearRequiredRebirth = {
	SpeedCoil = 0,
	SilverBat = 0,
	GravityCoil = 1,
	GoldBat = 1,
	CoilCombo = 2,
	DiamondBat = 2,
	ObsidianBat = 3,
	CrystalBat = 4,
	InvisibleCloak = 4,
	HackerBat = 5,
	GalaxyBat = 0,
	DefaultBat = 0,
}

-- Id -> the EXACT name of the Tool Instance under
-- ServerStorage.Assets.Ui.GearShop.Tools. The combat table is keyed
-- by this same name (Combat.GetByToolName).
-- Meaning: the asset binding.
-- Valid range: a non-empty string matching an existing Tool's Name.
-- Safe to change: only if you rename the Studio Tool too. A mismatch
--   means the gear cannot be granted (fails loudly, receipts retry).
-- Read by: GearShopService (grant) and BatService (combat lookup).
-- Placeholder: no.
Config.GearToolName = {
	SpeedCoil = 'Speed Coil',
	SilverBat = 'Silver Bat',
	GravityCoil = 'Gravity Coil',
	GoldBat = 'Gold Bat',
	CoilCombo = 'Coil Combo',
	DiamondBat = 'Diamond Bat',
	ObsidianBat = 'Obsidian Bat',
	CrystalBat = 'Crystal Bat',
	InvisibleCloak = 'Invisible Cloak',
	HackerBat = 'Hacker Bat',
	GalaxyBat = 'Galaxy Bat',
	DefaultBat = 'Default Bat',
}

-- Shop-preview viewport framing, read by GearShopController (the
-- Shops system), not by Combat. Presentation only.
-- Valid range: DistanceFactor / MinDistance > 0.
-- Safe to change: YES.
-- Read by: GearShopController.
-- Placeholder: no.
Config.GearViewport = {
	DistanceFactor = 1.4,
	MinDistance = 2,
	Direction = Vector3.new(1, 0.6, 1.6),
}

return table.freeze(Config)
