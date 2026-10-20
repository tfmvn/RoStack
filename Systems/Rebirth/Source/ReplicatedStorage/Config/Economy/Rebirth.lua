--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	This module is the single source of truth for its domain; the legacy
	flat config under ReplicatedStorage.Config is a deprecated shim.
	New code must require this canonical path.
	Values below are preserved exactly from the pre-migration configs.
	Do NOT rebalance here without a gameplay review.
]]
--[[
	Rebirth
	=============
	Authoritative per-Rebirth progression tuning. Indexed by Rebirth
	number (1-based, sequential: completing N puts the player at
	Rebirth N with N's rewards). Any Rebirth may carry any number
	of Animal requirements (including zero).

	INITIAL TUNING ONLY (edit freely): DefIds below are real
	catalog entries (AnimalConfig), traits are real TraitConfig
	ids ('Normal' = untraited). Money values are BigNumber decimal
	STRINGS (never numbers).

	Shape per Rebirth:
	  Requirements = { Money: string, ArenaLevel: number,
	    Animals: { { DefId, Trait, MinimumLevel } } }
	  Rewards = { StartingCash: string, MoneyMultiplier: number }
	  Reset = { Money: bool, Base: bool, Animals: bool, ArenaLevel: bool }
	  Stands = { Animal: number, Arena: number } (unlocks granted
	    by completing this Rebirth; Rebirth 0 uses InitialStands)
]]

export type RebirthAnimalRequirement = {
	DefId: string,
	Trait: string?,
	MinimumLevel: number,
}

export type RebirthEntry = {
	Requirements: {
		Money: string,
		ArenaLevel: number,
		Animals: { RebirthAnimalRequirement },
	},
	Rewards: {
		StartingCash: string,
		MoneyMultiplier: number,
	},
	Reset: {
		Money: boolean,
		Base: boolean,
		Animals: boolean,
		ArenaLevel: boolean,
	},
	-- Stand unlocks granted BY this Rebirth once completed (a
	-- player AT Rebirth N uses N's counts; Rebirth 0 uses
	-- InitialStands below). Animal = normal stands, Arena =
	-- arena stands. StandLayoutConfig decides WHERE they go.
	Stands: {
		Animal: number,
		Arena: number,
	},
}

-- Stand counts for players who never rebirthed (Rebirth 0 has
-- no completable entry, so it cannot carry Stands itself).
local InitialStands = {
	Animal = 6,
	Arena = 1,
}

local ENTRIES: { [number]: RebirthEntry } = {
	[1] = {
		Requirements = {
			Money = '500000',
			ArenaLevel = 5,
			Animals = {
				{ DefId = 'Dog', Trait = 'Normal', MinimumLevel = 5 },
			},
		},
		Rewards = {
			StartingCash = '25000',
			MoneyMultiplier = 1.5,
		},
		Reset = {
			Money = true,
			Base = true,
			Animals = true,
			ArenaLevel = true,
		},
		Stands = {
			Animal = 6,
			Arena = 2,
		},
	},
	[2] = {
		Requirements = {
			Money = '1500000',
			ArenaLevel = 15,
			Animals = {
				{ DefId = 'Fox', Trait = 'Normal', MinimumLevel = 1 },
				{ DefId = 'Spider', Trait = 'Normal', MinimumLevel = 3 },
			},
		},
		Rewards = {
			StartingCash = '50000',
			MoneyMultiplier = 2.0,
		},
		Reset = {
			Money = true,
			Base = true,
			Animals = true,
			ArenaLevel = true,
		},
		Stands = {
			Animal = 7,
			Arena = 2,
		},
	},
	[3] = {
		Requirements = {
			Money = '3000000',
			ArenaLevel = 25,
			Animals = {
				{ DefId = 'Turtle', Trait = 'Normal', MinimumLevel = 8 },
				{ DefId = 'Walrus', Trait = 'Normal', MinimumLevel = 3 },
			},
		},
		Rewards = {
			StartingCash = '150000',
			MoneyMultiplier = 2.5,
		},
		Reset = {
			Money = true,
			Base = true,
			Animals = true,
			ArenaLevel = true,
		},
		Stands = {
			Animal = 8,
			Arena = 3,
		},
	},
	[4] = {
		Requirements = {
			Money = '4000000',
			ArenaLevel = 40,
			Animals = {
				{ DefId = 'Crocodile', Trait = 'Normal', MinimumLevel = 6 },
				{ DefId = 'Scorpion', Trait = 'Normal', MinimumLevel = 4 },
			},
		},
		Rewards = {
			StartingCash = '200000',
			MoneyMultiplier = 3.0,
		},
		Reset = {
			Money = true,
			Base = true,
			Animals = true,
			ArenaLevel = true,
		},
		Stands = {
			Animal = 8,
			Arena = 3,
		},
	},
	[5] = {
		Requirements = {
			Money = '5000000',
			ArenaLevel = 45,
			Animals = {
				{ DefId = 'Gorilla', Trait = 'Normal', MinimumLevel = 10 },
				{ DefId = 'Tiger', Trait = 'Normal', MinimumLevel = 10 },
			},
		},
		Rewards = {
			StartingCash = '250000',
			MoneyMultiplier = 3.5,
		},
		Reset = {
			Money = true,
			Base = true,
			Animals = true,
			ArenaLevel = true,
		},
		Stands = {
			Animal = 8,
			Arena = 3,
		},
	},
}

local Rebirth = {}

function Rebirth.Get(index: number): RebirthEntry?
	if type(index) ~= 'number' or index ~= math.floor(index) or index < 1 then
		return nil
	end
	return ENTRIES[index]
end

function Rebirth.MaxConfigured(): number
	local max = 0
	for index in pairs(ENTRIES) do
		if type(index) == 'number' and index > max then
			max = index
		end
	end
	return max
end

-- Stand unlocks for a CURRENT rebirth value (0 = never rebirthed
-- -> InitialStands). Falls back to the highest defined entry at
-- or below the value, so future rebirths keep max stands.
-- Returns { Animal: number, Arena: number } (never nil).
function Rebirth.StandsFor(rebirth: number): { Animal: number, Arena: number }
	if type(rebirth) ~= 'number' or rebirth < 1 then
		return { Animal = InitialStands.Animal, Arena = InitialStands.Arena }
	end
	local best: number? = nil
	for index in pairs(ENTRIES) do
		if type(index) == 'number' and index <= rebirth then
			if best == nil or index > best then
				best = index
			end
		end
	end
	if best ~= nil then
		local entry = ENTRIES[best]
		if type(entry) == 'table' and type(entry.Stands) == 'table' then
			return {
				Animal = entry.Stands.Animal,
				Arena = entry.Stands.Arena,
			}
		end
	end
	return { Animal = InitialStands.Animal, Arena = InitialStands.Arena }
end

function Rebirth.Validate(): { string }
	local issues: { string } = {}
	for index, entry in pairs(ENTRIES) do
		local where = 'Rebirth[' .. tostring(index) .. ']'
		if type(entry) ~= 'table' then
			issues[#issues + 1] = where .. ' must be a table'
			continue
		end
		local req = entry.Requirements
		if type(req) ~= 'table' then
			issues[#issues + 1] = where .. '.Requirements must be a table'
		else
			if type(req.Money) ~= 'string' then
				issues[#issues + 1] = where .. '.Requirements.Money must be a BigNumber string'
			end
			if
				type(req.ArenaLevel) ~= 'number'
				or req.ArenaLevel ~= math.floor(req.ArenaLevel)
				or req.ArenaLevel < 0
			then
				issues[#issues + 1] = where .. '.Requirements.ArenaLevel must be an integer >= 0'
			end
			if type(req.Animals) ~= 'table' then
				issues[#issues + 1] = where .. '.Requirements.Animals must be a table'
			else
				for i, rule in ipairs(req.Animals) do
					local rwhere = where .. '.Animals[' .. tostring(i) .. ']'
					if type(rule) ~= 'table' then
						issues[#issues + 1] = rwhere .. ' must be a table'
					else
						if type(rule.DefId) ~= 'string' or rule.DefId == '' then
							issues[#issues + 1] = rwhere .. '.DefId must be a non-empty string'
						end
						if rule.Trait ~= nil and type(rule.Trait) ~= 'string' then
							issues[#issues + 1] = rwhere .. '.Trait must be a string or nil'
						end
						if
							type(rule.MinimumLevel) ~= 'number'
							or rule.MinimumLevel ~= math.floor(rule.MinimumLevel)
							or rule.MinimumLevel < 1
						then
							issues[#issues + 1] = rwhere .. '.MinimumLevel must be an integer >= 1'
						end
					end
				end
			end
		end
		local rewards = entry.Rewards
		if type(rewards) ~= 'table' then
			issues[#issues + 1] = where .. '.Rewards must be a table'
		else
			if type(rewards.StartingCash) ~= 'string' then
				issues[#issues + 1] = where .. '.Rewards.StartingCash must be a BigNumber string'
			end
			if
				type(rewards.MoneyMultiplier) ~= 'number'
				or rewards.MoneyMultiplier ~= rewards.MoneyMultiplier
				or rewards.MoneyMultiplier <= 0
			then
				issues[#issues + 1] = where .. '.Rewards.MoneyMultiplier must be a number > 0'
			end
		end
		if type(entry.Reset) ~= 'table' then
			issues[#issues + 1] = where .. '.Reset must be a table'
		end
		local stands = entry.Stands
		if type(stands) ~= 'table' then
			issues[#issues + 1] = where .. '.Stands must be a table'
		else
			if type(stands.Animal) ~= 'number' or stands.Animal ~= math.floor(stands.Animal) or stands.Animal < 0 then
				issues[#issues + 1] = where .. '.Stands.Animal must be an integer >= 0'
			end
			if type(stands.Arena) ~= 'number' or stands.Arena ~= math.floor(stands.Arena) or stands.Arena < 0 then
				issues[#issues + 1] = where .. '.Stands.Arena must be an integer >= 0'
			end
		end
	end
	-- Sequential integrity: 1..Max must all exist (no gaps — the
	-- server walks current+1 and a gap would strand progression).
	local max = Rebirth.MaxConfigured()
	for i = 1, max do
		if ENTRIES[i] == nil then
			issues[#issues + 1] = 'Rebirth gap: [' .. tostring(i) .. '] missing below max [' .. tostring(max) .. ']'
		end
	end
	if type(InitialStands.Animal) ~= 'number' or InitialStands.Animal < 0 then
		issues[#issues + 1] = 'Rebirth.InitialStands.Animal must be a number >= 0'
	end
	if type(InitialStands.Arena) ~= 'number' or InitialStands.Arena < 0 then
		issues[#issues + 1] = 'Rebirth.InitialStands.Arena must be a number >= 0'
	end
	return issues
end

return table.freeze(Rebirth)
