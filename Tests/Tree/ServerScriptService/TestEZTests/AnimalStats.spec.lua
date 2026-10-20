--!strict
--!native
--[[
	AnimalStats.spec
	==================
	Phase 2.5 tests for the authoritative Animal stat layer
	(ReplicatedStorage/Utility/AnimalStats.lua) over
	AnimalConfig.Stats + LevelConfig + StatCalculator.

	What this spec locks in:
	  * Level 1 -> the configured Base, bit-exact, for every rarity
	    that has a definition (Health balance preserved; Damage is
	    Health / 10 by the 10:1 combat invariant).
	  * MaxLevel -> the configured Maximum, bit-exact (Damage is
	    Health Maximum / 10).
	  * 10:1 INVARIANT: Damage == Health / 10, bit-exact, for every
	    rarity and every level 1..MaxLevel (no drift possible —
	    Damage is derived from the Health result, never from
	    independent parameters).
	  * Intermediate levels follow the logarithmic curve
	    (L1 < L2 < L10 < MaxLevel) and are monotonically
	    non-decreasing across the whole range.
	  * Bounds: Base <= stat <= Maximum for every level.
	  * Each rarity resolves to its own config row (no cross-wiring).
	  * StatCalculator integration: the layer delegates — results are
	    bit-exact against a direct StatCalculator call with the same
	    resolved parameters (no duplicated formula).
	  * Fail-safe contract: malformed Level (nil / 0 / -5 / "10" /
	    NaN / > MaxLevel) repairs through LevelConfig.Normalize; an
	    unknown/missing DefId fails safe to 0; unsupported statName
	    and a non-table animal throw (programming errors).
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
	local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)
	local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)
	local StatCalculator = require(ReplicatedStorage.Utility.StatCalculator)
	local Rarity = require(ReplicatedStorage.Types.RarityType)
	local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)

	local MAX = LevelConfig.MaxLevel

	-- First definition id in a rarity bucket, or nil when the
	-- bucket is empty (Uncommon and Secret currently have no definitions).
	local function defIdFor(rarity: string): string?
		local bucket = AnimalConfig.Catalog[rarity]
		if not bucket then
			return nil
		end
		local id = next(bucket)
		return id
	end

	-- Catalog rarities that actually have definitions (calculable).
	local function calculableRarities(): { string }
		local out = {}
		for _, rarity in ipairs(RarityConfig.Order) do
			if defIdFor(rarity) then
				out[#out + 1] = rarity
			end
		end
		return out
	end

	local function statAt(rarity: string, level: number, statName: string): number
		return AnimalStats.Calculate({ DefId = defIdFor(rarity), Level = level }, statName)
	end

	local function configFor(rarity: string, statName: string): any
		return AnimalConfig.Stats[statName][rarity]
	end

	describe('config completeness (require-time contract)', function()
		it('has an explicit row for every rarity tier in RarityConfig.Order', function()
			for _, statName in ipairs({ 'Health', 'Damage', 'Income' }) do
				for _, rarity in ipairs(RarityConfig.Order) do
					local cfg = AnimalConfig.Stats[statName][rarity]
					expect(type(cfg)).to.equal('table')
					expect(cfg.Base > 0).to.equal(true)
					expect(cfg.Maximum >= cfg.Base).to.equal(true)
					expect(cfg.Curve > 0).to.equal(true)
				end
			end
		end)

		it('covers Secret even though the catalog has no Secret definitions', function()
			expect(defIdFor(Rarity.Secret)).to.equal(nil)
			expect(type(AnimalStats.GetStatConfig(Rarity.Secret, 'Health'))).to.equal('table')
			expect(type(AnimalStats.GetStatConfig(Rarity.Secret, 'Damage'))).to.equal('table')
			expect(type(AnimalStats.GetStatConfig(Rarity.Secret, 'Income'))).to.equal('table')
		end)

		it('preserves the legacy Level-1 balance (Base = floor(base * old multiplier))', function()
			-- Sample check on the documented derivation: Common health.
			expect(configFor(Rarity.Common, 'Health').Base).to.equal(5)
			expect(configFor(Rarity.Divine, 'Health').Base).to.equal(792)
			-- Damage rows document the 10:1 invariant (Health / 10).
			expect(configFor(Rarity.Divine, 'Damage').Base).to.equal(79.2)
			expect(configFor(Rarity.Common, 'Damage').Base).to.equal(0.5)
		end)
	end)

	describe('Level 1 returns the configured Base (spec §8 compatibility)', function()
		it('for every rarity with a definition, both stats, bit-exact', function()
			for _, rarity in ipairs(calculableRarities()) do
				expect(statAt(rarity, 1, 'Health')).to.equal(configFor(rarity, 'Health').Base)
				expect(statAt(rarity, 1, 'Damage')).to.equal(configFor(rarity, 'Damage').Base)
			end
		end)
	end)

	describe('MaxLevel returns the configured Maximum', function()
		it('for every rarity with a definition, both stats, bit-exact', function()
			for _, rarity in ipairs(calculableRarities()) do
				expect(statAt(rarity, MAX, 'Health')).to.equal(configFor(rarity, 'Health').Maximum)
				expect(statAt(rarity, MAX, 'Damage')).to.equal(configFor(rarity, 'Damage').Maximum)
			end
		end)
	end)

	describe('intermediate levels follow the logarithmic curve', function()
		it('L1 < L2 < L10 < MaxLevel for both stats (Base < Maximum rows)', function()
			for _, rarity in ipairs(calculableRarities()) do
				for _, statName in ipairs({ 'Health', 'Damage' }) do
					local cfg = configFor(rarity, statName)
					if cfg.Maximum > cfg.Base then
						local l1 = statAt(rarity, 1, statName)
						local l2 = statAt(rarity, 2, statName)
						local l10 = statAt(rarity, 10, statName)
						local lmax = statAt(rarity, MAX, statName)
						expect(l1 < l2).to.equal(true)
						expect(l2 < l10).to.equal(true)
						expect(l10 < lmax).to.equal(true)
					end
				end
			end
		end)
	end)

	describe('monotonicity and bounds across the whole level range', function()
		it('stat(L+1) >= stat(L) for every level and rarity', function()
			for _, rarity in ipairs(calculableRarities()) do
				for _, statName in ipairs({ 'Health', 'Damage' }) do
					local previous = statAt(rarity, 1, statName)
					for level = 2, MAX do
						local value = statAt(rarity, level, statName)
						expect(value >= previous).to.equal(true)
						previous = value
					end
				end
			end
		end)

		it('Base <= stat <= Maximum for every level and rarity', function()
			for _, rarity in ipairs(calculableRarities()) do
				for _, statName in ipairs({ 'Health', 'Damage' }) do
					local cfg = configFor(rarity, statName)
					for level = 1, MAX do
						local value = statAt(rarity, level, statName)
						expect(value >= cfg.Base).to.equal(true)
						expect(value <= cfg.Maximum).to.equal(true)
					end
				end
			end
		end)
	end)

	describe('rarity separation', function()
		it('each rarity resolves to its own config row', function()
			for _, rarity in ipairs(RarityConfig.Order) do
				for _, statName in ipairs({ 'Health', 'Damage' }) do
					local cfg = AnimalStats.GetStatConfig(rarity, statName)
					expect(cfg).to.equal(AnimalConfig.Stats[statName][rarity])
				end
			end
		end)

		it('Level-1 values differ between adjacent tiers (configs are explicit)', function()
			-- The catalog's one-def-per-tier Base values are distinct;
			-- this asserts resolution is not collapsing onto one row.
			for _, statName in ipairs({ 'Health', 'Damage' }) do
				local seen = {}
				for _, rarity in ipairs(RarityConfig.Order) do
					seen[configFor(rarity, statName).Base] = true
				end
				local count = 0
				for _ in pairs(seen) do
					count += 1
				end
				expect(count).to.equal(#RarityConfig.Order)
			end
		end)
	end)

	describe('StatCalculator integration (delegation, not duplication)', function()
		it('Health is bit-exact against a direct StatCalculator call at intermediate levels', function()
			-- Levels 1..99 route through StatCalculator with the exact
			-- resolved parameters; the result matches a direct call
			-- bit-for-bit (no duplicated logarithmic formula).
			-- Damage is Health / 10 (covered below), so only
			-- Health is checked against the raw formula here.
			for _, rarity in ipairs(calculableRarities()) do
				for _, level in ipairs({ 1, 2, 7, 50, 99 }) do
					local cfg = configFor(rarity, 'Health')
					local expected = StatCalculator.Calculate({
						Points = LevelConfig.GetPointsForLevel(level),
						Base = cfg.Base,
						Maximum = cfg.Maximum,
						Curve = cfg.Curve,
						MaxPoints = LevelConfig.GetMaxPoints(),
					})
					expect(statAt(rarity, level, 'Health')).to.equal(expected)
				end
			end
		end)

		it('MaxLevel returns Maximum exactly even where the raw formula leaves 1-ulp dust', function()
			-- ((M-B)*ln(1+P/C))/ln(1+P/C) can differ from M-B by one
			-- ulp at P = P_max; the layer's boundary fast path makes
			-- the game-facing guarantee exact instead. Health only:
			-- Damage is Health / 10 (covered below).
			for _, rarity in ipairs(calculableRarities()) do
				local cfg = configFor(rarity, 'Health')
				local raw = StatCalculator.Calculate({
					Points = LevelConfig.GetMaxPoints(),
					Base = cfg.Base,
					Maximum = cfg.Maximum,
					Curve = cfg.Curve,
					MaxPoints = LevelConfig.GetMaxPoints(),
				})
				expect(math.abs(raw - cfg.Maximum) < 1e-6).to.equal(true)
				expect(statAt(rarity, MAX, 'Health')).to.equal(cfg.Maximum)
			end
		end)
	end)

	describe('10:1 combat invariant (Damage == Health / 10, bit-exact)', function()
		it('holds for every rarity with a definition at probe levels', function()
			for _, rarity in ipairs(calculableRarities()) do
				for _, level in ipairs({ 1, 2, 10, 30, 50, 99, MAX }) do
					local health = statAt(rarity, level, 'Health')
					local damage = statAt(rarity, level, 'Damage')
					expect(damage).to.equal(health / 10)
				end
			end
		end)

		it('holds across the whole level range for every rarity', function()
			for _, rarity in ipairs(calculableRarities()) do
				for level = 1, MAX do
					local animal = { DefId = defIdFor(rarity), Level = level }
					expect(AnimalStats.Calculate(animal, 'Damage')).to.equal(
						AnimalStats.Calculate(animal, 'Health') / 10
					)
				end
			end
		end)

		it('holds at the boundaries (Base and Maximum rows)', function()
			for _, rarity in ipairs(calculableRarities()) do
				expect(statAt(rarity, 1, 'Damage')).to.equal(configFor(rarity, 'Damage').Base)
				expect(statAt(rarity, MAX, 'Damage')).to.equal(configFor(rarity, 'Damage').Maximum)
				expect(configFor(rarity, 'Damage').Base).to.equal(configFor(rarity, 'Health').Base / 10)
				expect(configFor(rarity, 'Damage').Maximum).to.equal(configFor(rarity, 'Health').Maximum / 10)
			end
		end)

		it('spot-checks the reported specimen shape (Epic L30)', function()
			-- The observed-bug shape (~400 HP with ~312 Damage)
			-- is impossible post-fix: Epic L30 HP derives from
			-- the log curve and Damage is exactly HP / 10.
			local health = statAt(Rarity.Epic, 30, 'Health')
			local damage = statAt(Rarity.Epic, 30, 'Damage')
			expect(health > 300 and health < 500).to.equal(true)
			expect(damage).to.equal(health / 10)
			expect(math.abs(damage - 312) > 1).to.equal(true)
		end)

		it('snapshot carries the invariant (single path for every consumer)', function()
			local snapshot = AnimalStats.Snapshot({ DefId = defIdFor(Rarity.Common), Level = 3 })
			expect(snapshot.Damage).to.equal(snapshot.Health / 10)
		end)
	end)

	describe('Snapshot', function()
		it('returns both derived stats through the same path', function()
			local snapshot = AnimalStats.Snapshot({ DefId = defIdFor(Rarity.Common), Level = 3 })
			expect(type(snapshot)).to.equal('table')
			expect(snapshot.Health).to.equal(statAt(Rarity.Common, 3, 'Health'))
			expect(snapshot.Damage).to.equal(statAt(Rarity.Common, 3, 'Damage'))
		end)
	end)

	describe('Income (Phase 2.6)', function()
		it('has a complete per-rarity config row set (validated at require time)', function()
			for _, rarity in ipairs(RarityConfig.Order) do
				local cfg = AnimalStats.GetStatConfig(rarity, 'Income')
				expect(type(cfg)).to.equal('table')
				expect(cfg.Base > 0).to.equal(true)
				expect(cfg.Maximum >= cfg.Base).to.equal(true)
				expect(cfg.Curve > 0).to.equal(true)
			end
		end)

		it('Level 1 returns the configured Base exactly (the per-second rate) for every rarity', function()
			for _, rarity in ipairs(calculableRarities()) do
				expect(statAt(rarity, 1, 'Income')).to.equal(configFor(rarity, 'Income').Base)
			end
		end)

		it('MaxLevel returns the configured Maximum exactly', function()
			for _, rarity in ipairs(calculableRarities()) do
				expect(statAt(rarity, MAX, 'Income')).to.equal(configFor(rarity, 'Income').Maximum)
			end
		end)

		it('intermediate levels rise strictly inside (Base, Maximum)', function()
			for _, rarity in ipairs(calculableRarities()) do
				local l1 = statAt(rarity, 1, 'Income')
				local l2 = statAt(rarity, 2, 'Income')
				local lmax = statAt(rarity, MAX, 'Income')
				expect(l1 < l2).to.equal(true)
				expect(l2 < lmax).to.equal(true)
			end
		end)

		it('is monotonically non-decreasing across the whole level range', function()
			for _, rarity in ipairs(calculableRarities()) do
				local previous = statAt(rarity, 1, 'Income')
				for level = 2, MAX do
					local value = statAt(rarity, level, 'Income')
					expect(value >= previous).to.equal(true)
					previous = value
				end
			end
		end)

		it('stays within [Base, Maximum] and is never NaN for every level and rarity', function()
			for _, rarity in ipairs(calculableRarities()) do
				local cfg = configFor(rarity, 'Income')
				for level = 1, MAX do
					local value = statAt(rarity, level, 'Income')
					expect(value >= cfg.Base).to.equal(true)
					expect(value <= cfg.Maximum).to.equal(true)
					expect(value == value).to.equal(true)
				end
			end
		end)

		it('the rate is DERIVED from Level+config, never persisted — accumulation math stays external', function()
			-- The spec's $10/s x 5s = $50 shape: the rate comes from
			-- the config chain at full precision; IncomeService owns
			-- the single rounding boundary (floor at accumulation).
			local rate = AnimalStats.Calculate({ DefId = defIdFor(Rarity.Common), Level = 1 }, 'Income')
			expect(rate).to.equal(configFor(Rarity.Common, 'Income').Base)
			expect(math.floor(rate * 5)).to.equal(math.floor(configFor(Rarity.Common, 'Income').Base * 5))
		end)

		it('delegates to StatCalculator like Health/Damage (no duplicated formula)', function()
			local rarity = Rarity.Rare
			local cfg = configFor(rarity, 'Income')
			local expected = StatCalculator.Calculate({
				Points = LevelConfig.GetPointsForLevel(50),
				Base = cfg.Base,
				Maximum = cfg.Maximum,
				Curve = cfg.Curve,
				MaxPoints = LevelConfig.GetMaxPoints(),
			})
			expect(statAt(rarity, 50, 'Income')).to.equal(expected)
		end)
	end)

	describe('fail-safe: malformed Level (spec §17)', function()
		it('repairs through LevelConfig.Normalize — nil / 0 / -5 / "10" / NaN -> Level-1 Base', function()
			for _, badLevel in ipairs({ nil, 0, -5, '10', 0 / 0, 2.5 }) do
				local value = AnimalStats.Calculate({ DefId = defIdFor(Rarity.Common), Level = badLevel }, 'Health')
				expect(value).to.equal(configFor(Rarity.Common, 'Health').Base)
			end
		end)

		it('clamps Level > MaxLevel to the Maximum stat, never NaN or negative', function()
			local value = AnimalStats.Calculate({ DefId = defIdFor(Rarity.Common), Level = 10 ^ 9 }, 'Health')
			expect(value).to.equal(configFor(Rarity.Common, 'Health').Maximum)
		end)

		it('accepts the runtime-record shape (definitionId) identically', function()
			local viaDefId = AnimalStats.Calculate({ DefId = defIdFor(Rarity.Epic), Level = 5 }, 'Damage')
			local viaRuntime = AnimalStats.Calculate({ definitionId = defIdFor(Rarity.Epic), Level = 5 }, 'Damage')
			expect(viaDefId).to.equal(viaRuntime)
		end)
	end)

	describe('fail-safe: unknown / missing definition (spec §16)', function()
		it('returns 0 (never NaN, never negative, never throws) for an unknown DefId', function()
			local snapshot = AnimalStats.Snapshot({ DefId = 'NotARealDefinition', Level = 10 })
			expect(snapshot.Health).to.equal(0)
			expect(snapshot.Damage).to.equal(0)
		end)

		it('returns 0 when DefId is missing entirely', function()
			expect(AnimalStats.Calculate({ Level = 10 }, 'Health')).to.equal(0)
			expect(AnimalStats.Calculate({}, 'Damage')).to.equal(0)
		end)
	end)

	describe('programming errors fail loudly', function()
		it('throws on an unsupported statName', function()
			expect(function()
				AnimalStats.Calculate({ DefId = defIdFor(Rarity.Common), Level = 1 }, 'Defense')
			end).to.throw()
			expect(function()
				AnimalStats.Calculate({ DefId = defIdFor(Rarity.Common), Level = 1 }, nil)
			end).to.throw()
		end)

		it('throws on a non-table animal', function()
			expect(function()
				AnimalStats.Calculate(nil, 'Health')
			end).to.throw()
			expect(function()
				AnimalStats.Calculate('BR_x', 'Health')
			end).to.throw()
		end)

		it('GetStatConfig throws on an unsupported statName', function()
			expect(function()
				AnimalStats.GetStatConfig(Rarity.Common, 'Speed')
			end).to.throw()
		end)
	end)
end
