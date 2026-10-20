--!strict
--!native
--[[
	AdminDelivery
	=============
	The ONE admin path for granting slot-bound items (eggs,
	animals). It mirrors CodesService's deliverEgg/deliverAnimal
	step for step — the same canonical pipeline every code,
	daily, and playtime reward uses:

	  GetFreeSlot -> ReserveSlot -> PlayerService.AddEgg/AddAnimal
	  -> locate the new persistence record
	  -> EggService/AnimalService.SpawnFromPersistence
	  -> PlayerService.PushState

	Full base? The reward is queued through
	CodesService.QueuePendingReward (Code 'ADMIN') so the
	existing join/sell hooks deliver it later — never silently
	lost, never force-placed. Spawn failures remove the record,
	release the slot, and queue the same way.

	Returns { ok = true, record = ... } on delivery,
	{ queued = true } when no slot is free right now,
	{ failed = true, error = ... } on unexpected errors.
	Callers notify ONLY on ok (success toast) or queued
	(queued explanation) — never a false success.
]]

local Players = game:GetService('Players')
local ServerScriptService = game:GetService('ServerScriptService')

local PlayerService = require(ServerScriptService.PlayerService)
local BaseService = require(ServerScriptService.BaseService)

local AdminDelivery = {}

local function _services(): any
	local okSlot, slotSvc = pcall(require, ServerScriptService.Base.SlotService)
	local okCodes, codesSvc = pcall(require, ServerScriptService.Codes.CodesService)
	if not okSlot or not okCodes then
		return nil
	end
	return { slot = slotSvc, codes = codesSvc }
end

local function _push(userId: number)
	pcall(function()
		local player = Players:GetPlayerByUserId(userId)
		if player then
			PlayerService.PushState(player, BaseService.Snapshot(userId))
		end
	end)
end

local function _idSet(records: { any }): { [string]: boolean }
	local seen: { [string]: boolean } = {}
	for _, rec in ipairs(records) do
		if type(rec) == 'table' and type(rec.Id) == 'string' then
			seen[rec.Id] = true
		end
	end
	return seen
end

local function _findNew(records: { any }, before: { [string]: boolean }, slotId: string): any?
	for _, rec in ipairs(records) do
		if type(rec) == 'table' and type(rec.Id) == 'string' and not before[rec.Id] and rec.SlotId == slotId then
			return rec
		end
	end
	return nil
end

-- Grant one egg of `rarity` (with optional hidden trait +
-- mutations) to the player's base.
function AdminDelivery.GiveEgg(
	userId: number,
	rarity: string,
	trait: string?,
	mutations: { string }?
): { [string]: any }
	local outcome: { [string]: any } = { ok = false, queued = false, failed = false }
	local svc = _services()
	if svc == nil then
		outcome.failed = true
		outcome.error = 'delivery services unavailable'
		return outcome
	end
	local eggSvc: any = nil
	pcall(function()
		eggSvc = require(ServerScriptService.EggService)
	end)
	if eggSvc == nil then
		outcome.failed = true
		outcome.error = 'egg service unavailable'
		return outcome
	end
	local data: any = nil
	pcall(function()
		data = PlayerService.GetPlayerData(userId)
	end)
	if type(data) ~= 'table' then
		outcome.failed = true
		outcome.error = 'no profile'
		return outcome
	end
	local function queuePending()
		pcall(function()
			svc.codes.QueuePendingReward(data, { Code = 'ADMIN', Kind = 'Egg', Rarity = rarity })
		end)
		outcome.queued = true
	end
	local slot: any = nil
	pcall(function()
		slot = svc.slot.GetFreeSlot(userId)
	end)
	if type(slot) ~= 'table' or type(slot.id) ~= 'string' then
		queuePending()
		return outcome
	end
	local reserved = false
	pcall(function()
		reserved = svc.slot.ReserveSlot(slot.id) == true
	end)
	if not reserved then
		queuePending()
		return outcome
	end
	local before = _idSet(data.LuckyBlocks)
	local written = false
	pcall(function()
		written = PlayerService.AddEgg(userId, slot.id, rarity, nil, { Mutations = mutations, Trait = trait }) == true
	end)
	if not written then
		pcall(function()
			svc.slot.ReleaseSlot(slot.id)
		end)
		outcome.failed = true
		outcome.error = 'persistence write failed'
		return outcome
	end
	local record = _findNew(data.LuckyBlocks, before, slot.id)
	if record == nil then
		pcall(function()
			svc.slot.ReleaseSlot(slot.id)
		end)
		outcome.failed = true
		outcome.error = 'record not found after write'
		return outcome
	end
	local r: any = nil
	pcall(function()
		r = eggSvc.SpawnFromPersistence(userId, record, slot)
	end)
	if type(r) == 'table' and r.success == true then
		_push(userId)
		outcome.ok = true
		outcome.record = record
		return outcome
	end
	pcall(function()
		PlayerService.RemoveEgg(userId, record.Id)
	end)
	pcall(function()
		svc.slot.ReleaseSlot(slot.id)
	end)
	queuePending()
	return outcome
end

-- Grant one animal (`defId`, optional single trait, optional
-- mutation list, level) to the player's base.
function AdminDelivery.GiveAnimal(
	userId: number,
	defId: string,
	trait: string?,
	mutations: { string }?,
	level: number?
): { [string]: any }
	local outcome: { [string]: any } = { ok = false, queued = false, failed = false }
	local svc = _services()
	if svc == nil then
		outcome.failed = true
		outcome.error = 'delivery services unavailable'
		return outcome
	end
	local animalSvc: any = nil
	pcall(function()
		animalSvc = require(ServerScriptService.AnimalService)
	end)
	if animalSvc == nil then
		outcome.failed = true
		outcome.error = 'animal service unavailable'
		return outcome
	end
	local data: any = nil
	pcall(function()
		data = PlayerService.GetPlayerData(userId)
	end)
	if type(data) ~= 'table' then
		outcome.failed = true
		outcome.error = 'no profile'
		return outcome
	end
	local function queuePending()
		pcall(function()
			svc.codes.QueuePendingReward(data, {
				Code = 'ADMIN',
				Kind = 'Animal',
				DefId = defId,
				Trait = trait,
				Level = level or 1,
			})
		end)
		outcome.queued = true
	end
	local slot: any = nil
	pcall(function()
		slot = svc.slot.GetFreeSlot(userId)
	end)
	if type(slot) ~= 'table' or type(slot.id) ~= 'string' then
		queuePending()
		return outcome
	end
	local reserved = false
	pcall(function()
		reserved = svc.slot.ReserveSlot(slot.id) == true
	end)
	if not reserved then
		queuePending()
		return outcome
	end
	local before = _idSet(data.Brainrots)
	local written = false
	pcall(function()
		written = PlayerService.AddAnimal(userId, slot.id, defId, nil, {
			Level = level or 1,
			Trait = trait,
			Mutations = mutations,
		}) == true
	end)
	if not written then
		pcall(function()
			svc.slot.ReleaseSlot(slot.id)
		end)
		outcome.failed = true
		outcome.error = 'persistence write failed'
		return outcome
	end
	local record = _findNew(data.Brainrots, before, slot.id)
	if record == nil then
		pcall(function()
			svc.slot.ReleaseSlot(slot.id)
		end)
		outcome.failed = true
		outcome.error = 'record not found after write'
		return outcome
	end
	local r: any = nil
	pcall(function()
		r = animalSvc.SpawnFromPersistence(userId, record, slot)
	end)
	if type(r) == 'table' and r.success == true then
		_push(userId)
		outcome.ok = true
		outcome.record = record
		return outcome
	end
	pcall(function()
		PlayerService.RemoveAnimal(userId, record.Id)
	end)
	pcall(function()
		svc.slot.ReleaseSlot(slot.id)
	end)
	queuePending()
	return outcome
end

return table.freeze(AdminDelivery)
