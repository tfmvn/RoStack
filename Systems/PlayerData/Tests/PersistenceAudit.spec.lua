--!strict
--!native
--[[
	PersistenceAudit.spec
	=====================
	Phase 2.5.1: tests the ONE validation layer for the
	persisted inventory, in the pure form the runtime never gets
	to see — malformed profiles go IN, audited lists come OUT.

	Covered (spec §25):
	  * round-trip: valid lists survive unchanged, Type stamped
	  * type preservation BOTH directions: a record is never
	    reinterpreted as the other kind, never migrates lists
	    (the §7 hard requirement — an Animal must never become
	    an Egg because of a load fallback)
	  * identity: missing / wrong-namespace Id repaired in the
	    list's own namespace; duplicates quarantined
	  * Level/XP: valid pairs preserved EXACTLY, malformed
	    normalized through LevelConfig.Normalize
	  * collisions: same-kind duplicate SlotIds and cross-kind
	    slot collisions resolved deterministically (Animal
	    wins; the phantom Egg record is quarantined —
	    THE regression test for the reported rejoin bug)
	  * invalid rows: non-table records and whole missing lists
	    never crash, always report
	  * purity: the input lists are not reordered or truncated
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local PersistenceAudit = require(ServerScriptService['Base'].PersistenceAudit)
	local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)
	local OwnedObjectIdentity = require(ReplicatedStorage.Utility.OwnedObjectIdentity)

	local SLOT1 = 'p7:1:slot:1'
	local SLOT2 = 'p7:1:slot:2'
	local SLOT3 = 'p7:1:slot:3'
	local DEF = 'Chicken' -- a real catalog definition (Common)

	-- A Level/XP pair below the next threshold, so Normalize
	-- must return it EXACTLY (preserved, not repaired).
	local GOOD_LEVEL = 2
	local GOOD_XP = LevelConfig.GetXPRequired(GOOD_LEVEL) - 1

	local function animal(slotId: string, id: string?, level: any?, xp: any?): any
		return {
			Type = 'Brainrot',
			SlotId = slotId,
			DefId = DEF,
			Id = id or OwnedObjectIdentity.Generate('Brainrot'),
			Level = level or 1,
			XP = xp or 0,
		}
	end

	local function egg(slotId: string, id: string?): any
		return {
			Type = 'LuckyBlock',
			SlotId = slotId,
			Rarity = 'Common',
			Id = id or OwnedObjectIdentity.Generate('LuckyBlock'),
		}
	end

	local function countIssues(issues: { string }, needle: string): number
		local n = 0
		for _, issue in ipairs(issues) do
			if string.find(issue, needle, 1, true) then
				n += 1
			end
		end
		return n
	end

	describe('valid inventory round-trip', function()
		it('keeps every valid record, stamps Type, and reports no issues', function()
			local b1 = animal(SLOT1, 'BR_testbr0001', GOOD_LEVEL, GOOD_XP)
			local b2 = animal(SLOT2, 'BR_testbr0002')
			local l1 = egg(SLOT3, 'LB_testlb0001')
			local profileData = { Brainrots = { b1, b2 }, LuckyBlocks = { l1 } }

			local result = PersistenceAudit.Audit(profileData)

			expect(#result.Issues).to.equal(0)
			expect(result.Quarantined).to.equal(0)
			expect(result.Repaired).to.equal(0)
			expect(#result.Brainrots).to.equal(2)
			expect(#result.LuckyBlocks).to.equal(1)
			-- Same record references (repaired in place when needed;
			-- untouched when valid).
			expect(result.Brainrots[1]).to.equal(b1)
			expect(result.LuckyBlocks[1]).to.equal(l1)
			-- Explicit discriminator stamped (Phase 2.5.1 §4).
			expect(b1.Type).to.equal('Brainrot')
			expect(b2.Type).to.equal('Brainrot')
			expect(l1.Type).to.equal('LuckyBlock')
			-- Valid progression preserved EXACTLY.
			expect(b1.Level).to.equal(GOOD_LEVEL)
			expect(b1.XP).to.equal(GOOD_XP)
		end)
	end)

	describe('type preservation (never converted)', function()
		it('keeps an Animal with a Lucky-Block-prefixed Id an Animal, re-keyed in place', function()
			-- The §7 hard requirement: a wrong Id prefix is a
			-- filing error, never a type change. The record
			-- must NOT migrate to the Eggs list.
			local rec = { SlotId = SLOT1, DefId = DEF, Id = 'LB_wrongns001', Level = 1, XP = 0 }
			local profileData = { Brainrots = { rec }, LuckyBlocks = {} }

			local result = PersistenceAudit.Audit(profileData)

			expect(#result.Brainrots).to.equal(1)
			expect(#result.LuckyBlocks).to.equal(0)
			expect(result.Brainrots[1]).to.equal(rec)
			expect(result.Brainrots[1].Type).to.equal('Brainrot')
			-- Identity migrated (not minted): legacy LB_ body
			-- preserved under the canonical AN_ prefix.
			expect(rec.Id).to.equal('AN_wrongns001')
			expect(OwnedObjectIdentity.IsValid(rec.Id, OwnedObjectIdentity.Kind.Animal)).to.equal(true)
			expect(countIssues(result.Issues, 'migrated')).to.equal(1)
		end)

		it('keeps an Egg with Type="Brainrot" an Egg, re-stamped in place', function()
			local rec = { SlotId = SLOT1, Rarity = 'Common', Id = 'LB_testlb0042', Type = 'Brainrot' }
			local profileData = { Brainrots = {}, LuckyBlocks = { rec } }

			local result = PersistenceAudit.Audit(profileData)

			expect(#result.Brainrots).to.equal(0)
			expect(#result.LuckyBlocks).to.equal(1)
			expect(rec.Type).to.equal('LuckyBlock')
		end)
	end)

	describe('identity repair', function()
		it('mints an Animal-namespace Id for a record with none', function()
			local rec = { SlotId = SLOT1, DefId = DEF, Level = 1, XP = 0 }
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(OwnedObjectIdentity.IsValid(rec.Id, OwnedObjectIdentity.Kind.Animal)).to.equal(true)
		end)

		it('quarantines a same-list duplicate Id (first wins)', function()
			local first = animal(SLOT1, 'BR_dupetest0001')
			local second = animal(SLOT2, 'BR_dupetest0001')
			local result = PersistenceAudit.Audit({ Brainrots = { first, second }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(result.Brainrots[1]).to.equal(first)
			expect(result.Quarantined).to.equal(1)
			expect(countIssues(result.Issues, 'duplicate Id')).to.equal(1)
		end)
	end)

	describe('legacy prefix migration (2.11.5 BR_/LB_ -> AN_/EG_)', function()
		it('rewrites legacy ids in place, preserving bodies and records', function()
			local rec = animal(SLOT1, 'BR_migrate0001', 3, 50)
			rec.Trait = 'Gold'
			rec.Mutations = { 'Galactic' }
			rec.CashPool = '777'
			local lrec = egg(SLOT2, 'LB_migrate0001')
			lrec.Trait = 'Rainbow'
			local profileData = { Brainrots = { rec }, LuckyBlocks = { lrec } }

			local result = PersistenceAudit.Audit(profileData)

			expect(rec.Id).to.equal('AN_migrate0001')
			expect(lrec.Id).to.equal('EG_migrate0001')
			expect(rec.Level).to.equal(3)
			expect(rec.XP).to.equal(50)
			expect(rec.Trait).to.equal('Gold')
			expect(rec.CashPool).to.equal('777')
			expect(lrec.Trait).to.equal('Rainbow')
			expect(countIssues(result.Issues, 'migrated')).to.equal(2)
			expect(result.Quarantined).to.equal(0)
		end)

		it('leaves canonical ids untouched (idempotent)', function()
			local rec = animal(SLOT1, 'AN_stable00001', 1, 0)
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(rec.Id).to.equal('AN_stable00001')
			expect(countIssues(result.Issues, 'migrated')).to.equal(0)
		end)

		it('quarantines a legacy/canonical body collision deterministically', function()
			-- BR_collide01 migrates to AN_collide01, colliding
			-- with the pre-existing canonical record: first wins.
			local first = animal(SLOT1, 'AN_collide001')
			local second = animal(SLOT2, 'BR_collide001')
			local result = PersistenceAudit.Audit({ Brainrots = { first, second }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(result.Brainrots[1]).to.equal(first)
			expect(result.Quarantined).to.equal(1)
		end)

		it('mints fresh (not migrated) for malformed legacy bodies', function()
			local rec = animal(SLOT1, 'BR_not valid!!', 1, 0)
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(OwnedObjectIdentity.IsValid(rec.Id, OwnedObjectIdentity.Kind.Animal)).to.equal(true)
			expect(countIssues(result.Issues, 'minted')).to.equal(1)
		end)
	end)

	describe('Level/XP normalization', function()
		it('repairs malformed Level/XP to 1/0 and keeps the record', function()
			local rec = animal(SLOT1, 'BR_malformed01', 'garbage', -5)
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(rec.Level).to.equal(1)
			expect(rec.XP).to.equal(0)
		end)

		it('clamps an over-max Level to MaxLevel', function()
			local rec = animal(SLOT1, 'BR_overmax0001', LevelConfig.MaxLevel + 10, 0)
			PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })
			expect(rec.Level).to.equal(LevelConfig.MaxLevel)
		end)

		it('does not touch Egg records with Level/XP fields', function()
			local rec = egg(SLOT1, 'LB_testlb0007')
			rec.Level = 'garbage' -- junk field on the wrong kind
			local result = PersistenceAudit.Audit({ Brainrots = {}, LuckyBlocks = { rec } })

			expect(#result.Issues).to.equal(0)
			expect(rec.Level).to.equal('garbage') -- untouched, not normalized
		end)
	end)

	describe('slot collisions (Phase 2.5.1 §8)', function()
		it('resolves a same-kind duplicate SlotId deterministically (first wins)', function()
			local first = animal(SLOT1, 'BR_slotslot001')
			local second = animal(SLOT1, 'BR_slotslot002')
			local result = PersistenceAudit.Audit({ Brainrots = { first, second }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(result.Brainrots[1]).to.equal(first)
			expect(result.Quarantined).to.equal(1)
		end)

		it('quarantines the phantom Egg when an Animal claims the same slot', function()
			-- THE regression test for the reported bug: a phantom
			-- LB record survived its own open and claimed the slot
			-- the Animal was created on. The Animal wins, the
			-- phantom is quarantined, nothing is converted.
			local animal = animal(SLOT1, 'BR_realbr0001', GOOD_LEVEL, GOOD_XP)
			local phantom = egg(SLOT1, 'LB_phantomlb01')
			local profileData = { Brainrots = { animal }, LuckyBlocks = { phantom } }

			local result = PersistenceAudit.Audit(profileData)

			expect(#result.Brainrots).to.equal(1)
			expect(result.Brainrots[1]).to.equal(animal)
			expect(result.Brainrots[1].Type).to.equal('Brainrot')
			expect(#result.LuckyBlocks).to.equal(0)
			expect(result.Quarantined).to.equal(1)
			expect(countIssues(result.Issues, 'BOTH an Animal and an Egg')).to.equal(1)
		end)

		it(
			'keeps an Egg when the collision goes the other way is impossible — LB list is quarantined, not moved',
			function()
				-- Determinism check in the reverse direction: the
				-- quarantined phantom must be REMOVED, never merged
				-- into the Animals list as a fake Animal.
				local animal = animal(SLOT1, 'BR_realbr0002')
				local phantom = egg(SLOT1, 'LB_phantomlb02')
				local result = PersistenceAudit.Audit({ Brainrots = { animal }, LuckyBlocks = { phantom } })

				for _, record in ipairs(result.Brainrots) do
					expect(record.Id).never.to.equal('LB_phantomlb02')
				end
			end
		)
	end)

	describe('unknown DefId / Rarity (§17 — report, never convert)', function()
		it('keeps an Animal with an unknown DefId and reports it', function()
			local rec = { SlotId = SLOT1, DefId = 'NotARealDef', Id = 'BR_unknowndef1', Level = 1, XP = 0 }
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(result.Brainrots[1].Type).to.equal('Brainrot')
			expect(countIssues(result.Issues, 'unknown DefId')).to.equal(1)
		end)

		it('keeps an Egg with an unknown Rarity and reports it', function()
			local rec = { SlotId = SLOT1, Rarity = 'NotARarity', Id = 'LB_unknownrar1' }
			local result = PersistenceAudit.Audit({ Brainrots = {}, LuckyBlocks = { rec } })

			expect(#result.LuckyBlocks).to.equal(1)
			expect(countIssues(result.Issues, 'unknown rarity')).to.equal(1)
		end)
	end)

	describe('malformed input never crashes', function()
		it('quarantines non-table rows', function()
			local ok = animal(SLOT1, 'BR_okrecord001')
			local result = PersistenceAudit.Audit({ Brainrots = { 'junk', ok, 42 }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(result.Quarantined).to.equal(2)
		end)

		it('handles a profile with missing or wrong-typed lists', function()
			local result = PersistenceAudit.Audit({ Money = '0' })
			expect(#result.Brainrots).to.equal(0)
			expect(#result.LuckyBlocks).to.equal(0)

			local result2 = PersistenceAudit.Audit({ Brainrots = 'not-a-list', LuckyBlocks = 7 })
			expect(#result2.Brainrots).to.equal(0)
			expect(#result2.LuckyBlocks).to.equal(0)

			local result3 = PersistenceAudit.Audit(nil)
			expect(#result3.Brainrots).to.equal(0)
		end)

		it('keeps a record with an invalid SlotId and reports it (restore re-homes)', function()
			local rec = animal('not-a-slot-id', 'BR_badslot0001')
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(result.Brainrots[1]).to.equal(rec)
			expect(countIssues(result.Issues, 'invalid SlotId')).to.equal(1)
		end)
	end)

	describe('purity', function()
		it('does not reorder or truncate the input lists', function()
			local r1 = animal(SLOT2, 'BR_puritytest01')
			local r2 = 'junk'
			local r3 = animal(SLOT1, 'BR_puritytest02')
			local animals = { r1, r2, r3 }
			local eggs = {}
			PersistenceAudit.Audit({ Brainrots = animals, LuckyBlocks = eggs })

			-- Input list object and its length are unchanged;
			-- quarantining built a NEW output list instead.
			expect(#animals).to.equal(3)
			expect(animals[1]).to.equal(r1)
			expect(animals[2]).to.equal(r2)
			expect(animals[3]).to.equal(r3)
			expect(#eggs).to.equal(0)
		end)
	end)

	describe('CashPool normalization (Phase 2.6)', function()
		it('stamps a MISSING CashPool to "0" silently (a pre-2.6 save is not a repair)', function()
			local rec = animal(SLOT1, 'BR_poolmissing01') -- no CashPool field at all
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(result.Repaired).to.equal(0)
			expect(#result.Issues).to.equal(0)
			expect(rec.CashPool).to.equal('0')
		end)

		it('keeps a valid BigNumber-string pool EXACTLY (the pool rides the record)', function()
			local rec = animal(SLOT1, 'BR_poolvalid001')
			rec.CashPool = '12345'
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(#result.Issues).to.equal(0)
			expect(result.Repaired).to.equal(0)
			expect(rec.CashPool).to.equal('12345')
		end)

		it('recovers a NUMBER CashPool through tostring+sanitize (counted as a repair)', function()
			local rec = animal(SLOT1, 'BR_poolnumber01')
			rec.CashPool = 100 -- a legacy/foreign number, not the string schema
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(rec.CashPool).to.equal('100')
			expect(result.Repaired).to.equal(1)
			expect(#result.Issues).to.equal(0)
		end)

		it('resets an unrecoverable CashPool to "0" with a loud issue (pool lost, Animal kept)', function()
			local rec = animal(SLOT1, 'BR_poolinvalid01')
			rec.CashPool = 'not-a-number'
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(#result.Brainrots).to.equal(1)
			expect(rec.CashPool).to.equal('0')
			expect(countIssues(result.Issues, 'invalid CashPool')).to.equal(1)
		end)

		it('resets a negative-number CashPool to "0" (money is never negative)', function()
			local rec = animal(SLOT1, 'BR_poolnegative')
			rec.CashPool = -5
			local result = PersistenceAudit.Audit({ Brainrots = { rec }, LuckyBlocks = {} })

			expect(rec.CashPool).to.equal('0')
			expect(countIssues(result.Issues, 'invalid CashPool')).to.equal(1)
		end)

		it('never touches Egg records with a CashPool policy (eggs carry no pool)', function()
			local l1 = egg(SLOT3, 'LB_pooluntouched')
			l1.CashPool = 'whatever' -- even a junk field passes through untouched
			local result = PersistenceAudit.Audit({ Brainrots = {}, LuckyBlocks = { l1 } })

			expect(#result.LuckyBlocks).to.equal(1)
			expect(#result.Issues).to.equal(0)
			expect(l1.CashPool).to.equal('whatever')
		end)
	end)
end
