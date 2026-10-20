--!strict
--!native
--[[
	ArenaProgressionService
	=======================
	Server-authoritative player Arena progression (Level / XP /
	Wins). Owns the profile `Arena` table shape, normalization,
	and level-up math. Pure cores (NormalizeArena, AddXPToData)
	are headless-testable; thin wrappers resolve the profile
	through the injected PlayerService.

	Rebirth contract (future, NOT implemented here): Rebirth
	asks ArenaProgressionService:GetArenaLevel(playerOrUserId)
	and knows nothing about combat, waves, or rewards.

	Persistence: profile.Data.Arena = {
		Level: number (1-based, starts 1 — XP progression),
		XP: number (progress toward next level),
		Wins: number (completed expeditions),
		HighestCompleted: number (highest arena LEVEL won,
			0 = none; drives win-unlocks + first/repeat
			rewards WITHOUT touching XP progression),
		LastReached: number (highest stage reached in a
			terminal raid, win or lose, 0 = none; drives
			paid-restart entry, max semantics, never retreats),
		PendingEggs: { { EggId: string, Quantity: number } }
			(Phase 3 reward escrow; field reserved now so the
			persistence shape is final),
	}. Same ProfileService store as everything else — no new
	datastore.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local ArenaConfig = require(ReplicatedStorage.Config.World.Arena)
local Debug = require(ReplicatedStorage.Utility.Debug)

local ArenaProgressionService = {}

local playerServiceRef: any = nil

function ArenaProgressionService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

-- Normalize the Arena table on a profile data table: ensures
-- the table exists and every KNOWN field has a valid value
-- (repairs wrong types, clamps Level into range, never wipes
-- legitimate progress). Unknown keys are preserved. Returns
-- the normalized table (or nil when data is not a table).
function ArenaProgressionService.NormalizeArena(data: any): { [string]: any }?
	if type(data) ~= 'table' then
		warn('[ArenaProgression] missing player profile; cannot normalize')
		return nil
	end
	local arena = data.Arena
	if type(arena) ~= 'table' then
		arena = {}
		data.Arena = arena
	end
	if type(arena.Level) ~= 'number' or arena.Level ~= math.floor(arena.Level) then
		arena.Level = 1
	end
	if arena.Level < 1 then
		arena.Level = 1
	end
	if arena.Level > ArenaConfig.MaxLevel() then
		arena.Level = ArenaConfig.MaxLevel()
	end
	if type(arena.XP) ~= 'number' or arena.XP ~= arena.XP or arena.XP < 0 then
		arena.XP = 0
	end
	if type(arena.Wins) ~= 'number' or arena.Wins ~= math.floor(arena.Wins) or arena.Wins < 0 then
		arena.Wins = 0
	end
	if type(arena.HighestCompleted) ~= 'number' or arena.HighestCompleted ~= math.floor(arena.HighestCompleted) then
		arena.HighestCompleted = 0
	end
	if arena.HighestCompleted < 0 then
		arena.HighestCompleted = 0
	end
	if arena.HighestCompleted > ArenaConfig.MaxLevel() then
		arena.HighestCompleted = ArenaConfig.MaxLevel()
	end
	if type(arena.LastReached) ~= 'number' or arena.LastReached ~= math.floor(arena.LastReached) then
		arena.LastReached = 0
	end
	if arena.LastReached < 0 then
		arena.LastReached = 0
	end
	if arena.LastReached > ArenaConfig.MaxLevel() then
		arena.LastReached = ArenaConfig.MaxLevel()
	end
	if type(arena.PendingEggs) ~= 'table' then
		arena.PendingEggs = {}
	end
	return arena
end

-- Pure level-up core over a normalized arena table. Applies
-- `amount` XP, advancing Level while thresholds are met.
-- Capped at MaxLevel (overflow XP is banked, never lost).
-- Returns { LevelsGained: number, Level: number }.
function ArenaProgressionService.AddXPToData(arena: { [string]: any }, amount: number): { [string]: any }
	local gained = 0
	if type(amount) ~= 'number' or amount ~= amount or amount <= 0 then
		return { LevelsGained = 0, Level = arena.Level }
	end
	arena.XP += amount
	while true do
		local required = ArenaConfig.XPRequired(arena.Level)
		if required == nil then
			break
		end
		if arena.XP < required then
			break
		end
		arena.XP -= required
		arena.Level += 1
		gained += 1
	end
	return { LevelsGained = gained, Level = arena.Level }
end

local function arenaOf(userId: number): { [string]: any }?
	if not playerServiceRef then
		return nil
	end
	local data: any = nil
	pcall(function()
		data = playerServiceRef.GetPlayerData(userId)
	end)
	if type(data) ~= 'table' then
		return nil
	end
	return ArenaProgressionService.NormalizeArena(data)
end

local function userIdOf(playerOrUserId: any): number?
	if typeof(playerOrUserId) == 'Instance' and (playerOrUserId :: Instance):IsA('Player') then
		return (playerOrUserId :: Player).UserId
	end
	if type(playerOrUserId) == 'number' then
		return playerOrUserId
	end
	return nil
end

-- Canonical Rebirth-contract read: accepts a Player or a
-- userId, always returns a valid Level (1 when unknown).
function ArenaProgressionService.GetArenaLevel(playerOrUserId: any): number
	local userId = userIdOf(playerOrUserId)
	if userId == nil then
		return 1
	end
	local arena = arenaOf(userId)
	if arena == nil then
		return 1
	end
	return arena.Level
end

function ArenaProgressionService.GetArenaXP(playerOrUserId: any): number
	local userId = userIdOf(playerOrUserId)
	if userId == nil then
		return 0
	end
	local arena = arenaOf(userId)
	if arena == nil then
		return 0
	end
	return arena.XP
end

-- Full snapshot for ArenaState pushes + menu rendering.
function ArenaProgressionService.GetArenaState(playerOrUserId: any): { [string]: any }
	local level = ArenaProgressionService.GetArenaLevel(playerOrUserId)
	local xp = ArenaProgressionService.GetArenaXP(playerOrUserId)
	local userId = userIdOf(playerOrUserId)
	local wins = 0
	local highestCompleted = 0
	if userId ~= nil then
		local arena = arenaOf(userId)
		if arena ~= nil then
			if type(arena.Wins) == 'number' then
				wins = arena.Wins
			end
			if type(arena.HighestCompleted) == 'number' then
				highestCompleted = arena.HighestCompleted
			end
		end
	end
	return {
		Level = level,
		XP = xp,
		XPRequired = ArenaConfig.XPRequired(level),
		Wins = wins,
		HighestCompleted = highestCompleted,
	}
end

-- Highest legitimately completed arena level (0 = none).
-- Fail-closed: unknown profiles read 0, so only Level 1 is
-- ever unlocked for them.
function ArenaProgressionService.GetHighestCompleted(playerOrUserId: any): number
	local userId = userIdOf(playerOrUserId)
	if userId == nil then
		return 0
	end
	local arena = arenaOf(userId)
	if arena == nil or type(arena.HighestCompleted) ~= 'number' then
		return 0
	end
	return arena.HighestCompleted
end

-- Historical stage record: level N counts as beaten iff it
-- exists in ArenaConfig AND N <= HighestCompleted. Arena XP
-- (GetArenaLevel) NEVER unlocks anything: XP is a separate
-- reward value. In the raid model this is NOT a start gate
-- (normal raids start at stage 1 and advance continuously;
-- paid restarts enter at the authorized stage);
-- it records the highest stage ever reached and selects
-- first-clear vs repeat rewards. Replays never move
-- HighestCompleted backwards (see RecordLevelWin).
function ArenaProgressionService.IsUnlocked(playerOrUserId: any, arenaLevel: number): boolean
	if not ArenaConfig.IsValidLevel(arenaLevel) then
		return false
	end
	return arenaLevel <= ArenaProgressionService.GetHighestCompleted(playerOrUserId) + 1
end

-- Server-side XP grant (Phase 3 completion path; exposed now
-- so the contract is testable). Returns levels gained.
function ArenaProgressionService.AddArenaXP(userId: number, amount: number): { [string]: any }
	if type(userId) ~= 'number' or not playerServiceRef then
		return { LevelsGained = 0, Level = 1 }
	end
	local result: { [string]: any } = { LevelsGained = 0, Level = 1 }
	pcall(function()
		local data = playerServiceRef.GetPlayerData(userId)
		local arena = ArenaProgressionService.NormalizeArena(data)
		if arena ~= nil then
			result = ArenaProgressionService.AddXPToData(arena, amount)
		end
	end)
	Debug.Log('AP', 'AddArenaXP', {
		userId = tostring(userId),
		amount = tostring(amount),
		result = tostring(result.LevelsGained),
	})
	return result
end

function ArenaProgressionService.RecordWin(userId: number): number
	local wins = 0
	pcall(function()
		if not playerServiceRef then
			return
		end
		local data = playerServiceRef.GetPlayerData(userId)
		local arena = ArenaProgressionService.NormalizeArena(data)
		if arena ~= nil then
			arena.Wins += 1
			wins = arena.Wins
		end
	end)
	return wins
end

-- Record a level completion: Wins += 1 and HighestCompleted
-- advances ONLY when arenaLevel == HighestCompleted + 1
-- (never backwards, never gaps). Returns
-- { Wins, HighestCompleted, FirstClear } — FirstClear is true
-- exactly when this win newly completes the next expected
-- level, which is what selects FirstClearCash vs RepeatCash.
function ArenaProgressionService.RecordLevelWin(userId: number, arenaLevel: number): { [string]: any }
	local result: { [string]: any } = { Wins = 0, HighestCompleted = 0, FirstClear = false }
	pcall(function()
		if not playerServiceRef or type(arenaLevel) ~= 'number' then
			return
		end
		local data = playerServiceRef.GetPlayerData(userId)
		local arena = ArenaProgressionService.NormalizeArena(data)
		if arena ~= nil then
			arena.Wins += 1
			result.Wins = arena.Wins
			result.HighestCompleted = arena.HighestCompleted
			-- STRICT SEQUENTIAL: advance ONLY when the won stage
			-- is exactly the next expected one
			-- (HighestCompleted + 1). Raids clear stages in
			-- order so the chain holds; replays keep
			-- HighestCompleted unchanged; forged/gap stages can
			-- never create gaps.
			if arenaLevel == arena.HighestCompleted + 1 then
				arena.HighestCompleted = arenaLevel
				result.HighestCompleted = arenaLevel
				result.FirstClear = true
			end
		end
	end)
	return result
end

-- Highest arena stage actually REACHED in a terminal raid
-- (0 = none). Unlike HighestCompleted (won stages only) this
-- advances on defeat too: reaching stage N and losing records
-- N. Max semantics — never moves backwards, so a later shorter
-- run cannot erase progress. Drives paid-restart entry.
function ArenaProgressionService.GetLastReached(playerOrUserId: any): number
	local userId = userIdOf(playerOrUserId)
	if userId == nil then
		return 0
	end
	local arena = arenaOf(userId)
	if arena == nil or type(arena.LastReached) ~= 'number' then
		return 0
	end
	return arena.LastReached
end

-- Record a terminal raid's reached stage. Called once per
-- terminal raid (victory, defeat, mutual wipe — never retreat:
-- withdrawing records nothing). Max-only: a run that ends
-- earlier than the stored value leaves it unchanged.
function ArenaProgressionService.RecordReachedLevel(userId: number, stage: number): number
	local reached = 0
	pcall(function()
		if not playerServiceRef or type(stage) ~= 'number' then
			return
		end
		local data = playerServiceRef.GetPlayerData(userId)
		local arena = ArenaProgressionService.NormalizeArena(data)
		if arena ~= nil then
			local s = math.floor(stage)
			if s >= 1 and s <= ArenaConfig.MaxLevel() and s > arena.LastReached then
				arena.LastReached = s
			end
			reached = arena.LastReached
		end
	end)
	return reached
end

function ArenaProgressionService._TestReset()
	playerServiceRef = nil
end

-- Full Arena reset for Rebirth: Level/XP/Wins/HighestCompleted/
-- LastReached/PendingEggs back to fresh-profile values. Uses the
-- same normalize-then-write pattern as every other mutator.
function ArenaProgressionService.ResetArena(userId: number): boolean
	if type(userId) ~= 'number' or not playerServiceRef then
		return false
	end
	local ok = false
	pcall(function()
		local data = playerServiceRef.GetPlayerData(userId)
		local arena = ArenaProgressionService.NormalizeArena(data)
		if arena ~= nil then
			arena.Level = 1
			arena.XP = 0
			arena.Wins = 0
			arena.HighestCompleted = 0
			arena.LastReached = 0
			arena.PendingEggs = {}
			ok = true
		end
	end)
	return ok
end

return table.freeze(ArenaProgressionService)
