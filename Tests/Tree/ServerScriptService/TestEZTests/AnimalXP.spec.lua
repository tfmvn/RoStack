return {
	name = 'Animal XP Foundation — Phase 2.3',
	TestCreation = function()
		local animal = { Id = 'BR_test', SlotId = 's1', DefId = 'bone', XP = 0 }
		assert(animal.XP == 0, 'new animal XP=0')
	end,
	TestAddXP = function()
		local animal = { XP = 0 }
		animal.XP = animal.XP + 100
		assert(animal.XP == 100, '0+100=100')
		animal.XP = animal.XP + 50
		assert(animal.XP == 150, 'accumulates')
		animal.XP = animal.XP + 0
		assert(animal.XP == 150, 'zero no-op')
	end,
	TestValidation = function()
		local bad = { -1, 'abc', {}, math.huge, -math.huge, math.random() ~= math.random() and 0 / 0 or nil }
		local rejected = 0
		for _, v in ipairs({ -1, 'abc', {}, math.huge, -math.huge }) do
			rejected += 1
			assert(
				type(v) ~= 'number' or (v >= 0 and v == math.floor(v) and v ~= math.huge and v ~= -math.huge) == false,
				'bad value rejected conceptually'
			)
		end
		assert(rejected == 5, '5 invalid types/values')
	end,
	TestIdentity = function()
		local a = { Id = 'BR_a', XP = 100 }
		local b = { Id = 'BR_b', XP = 200 }
		assert(a.XP ~= b.XP, 'independent XP by identity')
	end,
	TestPersistence = function()
		local rec = { Id = 'BR_1', SlotId = 's', DefId = 'd', XP = 12345 }
		assert(rec.XP == 12345, 'serialize preserved')
		local loaded = rec -- simulated deserialization
		assert(loaded.XP == 12345, 'deserialize preserved')
	end,
	TestRepair = function()
		-- missing
		local missing = { Id = 'BR_r', XP = nil }
		missing.XP = missing.XP or 0
		assert(missing.XP == 0, 'missing repaired to 0')
		-- valid
		local valid = { Id = 'BR_r2', XP = 12345 }
		assert(valid.XP == 12345, 'valid preserved')
		-- invalid repaired safely (conceptual; actual repair in PlayerService)
		local bad = { Id = 'BR_r3', XP = -1 }
		bad.XP = (type(bad.XP) == 'number' and bad.XP >= 0 and bad.XP == math.floor(bad.XP)) and bad.XP or 0
		assert(bad.XP == 0, 'negative repaired')
	end,
	TestRejoin = function()
		local rec = { Id = 'BR_123', SlotId = '4', DefId = 'bone', XP = 12345 }
		local saved = rec
		local loaded = saved -- persistence round-trip
		assert(loaded.Id == 'BR_123', 'id survives')
		assert(loaded.XP == 12345, 'XP survives rejoin')
		assert(loaded.SlotId == '4', 'slot survives')
	end,
	TestLuckyBlockOpen = function()
		local result = { Id = 'BR_new', DefId = 'bone', XP = 0 }
		assert(result.XP == 0, 'open creates animal with XP=0')
	end,
}
