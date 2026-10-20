--!strict
--!native
--[[
	CodesService
	============
	Server-authoritative redeem-code system: validation, reward
	grants, redemption persistence, and pending slot-bound
	delivery. The client sends ONLY the typed string
	(CodesAction { Action = 'Redeem', Code }); EVERYTHING else
	(rewards, amounts, validity, expiry) resolves here from
	CodesConfig. Client reward data is never read — there is
	none to read.

	Authority model:
	  CodesConfig (catalog + rules)
	        |
	        +-- server normalizes (trim + UPPER), validates,
	        v     grants, persists
	  Redeem: exists -> enabled -> expiry -> per-player cap ->
	  global cap -> reward-shape -> systems-ready -> tools ->
	  cash -> slot rewards (direct or pending) -> mark redeemed
	  -> notify + result. Player-facing text + SFX travel on the
	  existing Notify channel (NotificationService); CodesResult
	  carries presentation state only (clear TextBox, restore
	  Continue) and never decides the grant.

	Transaction safety (§22): commit order is tools -> cash ->
	slot rewards -> mark redeemed.
	  * Tool grants are idempotent (EnsureGearTool no-ops when
	    the Tool is already present), so a retry after a later
	    failure can neither duplicate nor lose.
	  * Cash (EconomyService.AddMoney, reason 'CodeReward') is
	    validated before the call and cannot fail after it.
	  * Slot rewards (eggs/animals) either spawn into a freshly
	    reserved free slot or are persisted as pending entries —
	    pending counts as safely committed, never as loss.
	  * The code is marked redeemed ONLY after the above lands.
	No timers, no polling, no Heartbeat: delivery retries ride
	existing events (join via OnPlayerReady, freed slots via the
	SellService hook) plus the redeem attempt itself.

	Studio requirements (all fail-soft with [Codes] warns):
	StarterGui.Main.Codes (client-resolved), TopbarPlus package
	(client), ServerStorage egg/animal/gear assets (resolved by
	the owning services, never here).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

local CodesConfig = require(ReplicatedStorage.Config.Economy.Rewards).Codes
local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)
local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Validation = require(ReplicatedStorage.Utility.Validation)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local Debug = require(ReplicatedStorage.Utility.Debug)
local NotificationService = require(ServerScriptService.Base.NotificationService)
local MoneyIcon = require(ServerScriptService.Utility.MoneyIcon)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(ServerScriptService.FunnelService)

local CodesService = {}

local playerServiceRef: any = nil
local economyServiceRef: any = nil
local slotServiceRef: any = nil
local eggServiceRef: any = nil
local animalServiceRef: any = nil
local gearShopServiceRef: any = nil

-- Per-player/per-code redemption mutex (double-click, multi
-- fire, exploiter spam). Set synchronously on ingress before
-- any yield; cleared when the request settles. Luau is
-- single-threaded, so check-and-set cannot race.
local locks: { [string]: boolean } = {}
-- Pending-delivery reentrancy guard (join hook + sell hook +
-- redeem path can overlap on the same player).
local delivering: { [number]: boolean } = {}
-- Best-effort per-server global counters (NOT persisted, NOT
-- shared across servers — documented limitation in CodesConfig).
local globalCounts: { [string]: number } = {}

local started = false

function CodesService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function CodesService.SetEconomyService(svc: any)
	economyServiceRef = svc
end

function CodesService.SetSlotService(svc: any)
	slotServiceRef = svc
end

function CodesService.SetEggService(svc: any)
	eggServiceRef = svc
end

function CodesService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

function CodesService.SetGearShopService(svc: any)
	gearShopServiceRef = svc
end

local function logCode(message: string, context: any?)
	if context ~= nil then
		Debug.Log('CD', message, context)
	else
		Debug.Log('CD', message, {})
	end
end

local function lockKey(userId: number, norm: string): string
	return tostring(userId) .. '\0' .. norm
end

local function pushResult(player: Player, payload: any)
	pcall(Remotes.FireClient, player, Remotes.Names.CodesResult, payload)
end

-- Failure terminal: notifies on the existing warning channel
-- (with the existing warning SFX) and builds the result table.
-- Callers push the result exactly once (see Redeem).
local function failRedeem(player: Player, reason: string, warningId: string, warningData: any?): { [string]: any }
	local message: string? = nil
	pcall(function()
		message = NotificationService.GetWarningText(warningId, warningData)
	end)
	pcall(NotificationService.NotifyWarning, player, warningId, warningData)
	return { Success = false, Reason = reason, Message = message }
end

local function getData(userId: number): any?
	if playerServiceRef == nil then
		return nil
	end
	local data: any = nil
	pcall(function()
		data = playerServiceRef.GetPlayerData(userId)
	end)
	return data
end

-- Pending-queue entry sanitation (pure shape check; slot
-- availability is NOT checked here — undeliverable-now entries
-- are well-formed and must be kept, not dropped).
local function sanitizePendingEntry(entry: any): { [string]: any }?
	if type(entry) ~= 'table' then
		return nil
	end
	local kind = entry.Kind
	if kind == 'Egg' then
		if type(entry.Rarity) ~= 'string' or EggConfig.Price[entry.Rarity] == nil then
			return nil
		end
		if type(entry.Code) ~= 'string' or entry.Code == '' then
			return nil
		end
		return { Code = entry.Code, Kind = 'Egg', Rarity = entry.Rarity }
	elseif kind == 'Animal' then
		if type(entry.DefId) ~= 'string' then
			return nil
		end
		local rarity = AnimalConfig.Get(entry.DefId)
		if rarity == nil then
			return nil
		end
		if entry.Trait ~= nil and type(entry.Trait) ~= 'string' then
			return nil
		end
		if entry.Level ~= nil and (type(entry.Level) ~= 'number' or entry.Level < 1) then
			return nil
		end
		if type(entry.Code) ~= 'string' or entry.Code == '' then
			return nil
		end
		return {
			Code = entry.Code,
			Kind = 'Animal',
			DefId = entry.DefId,
			Trait = entry.Trait,
			Level = entry.Level,
		}
	end
	return nil
end

-- Load-time + join-time repair for the Codes profile slice
-- (mirrors ArenaProgressionService.NormalizeArena; called from
-- bootstrap after the profile loads). Malformed entries are
-- dropped with a log; well-formed ones (including
-- undeliverable-now) are preserved verbatim.
function CodesService.NormalizePlayer(userId: number)
	pcall(function()
		local data = getData(userId)
		if type(data) ~= 'table' then
			return
		end
		if type(data.RedeemedCodes) ~= 'table' then
			data.RedeemedCodes = {}
		end
		if type(data.PendingCodeRewards) ~= 'table' then
			data.PendingCodeRewards = {}
			return
		end
		local kept: { any } = {}
		for _, entry in ipairs(data.PendingCodeRewards) do
			local clean = sanitizePendingEntry(entry)
			if clean ~= nil then
				kept[#kept + 1] = clean
			else
				logCode('pending entry dropped (malformed)', { userId = tostring(userId) })
			end
		end
		data.PendingCodeRewards = kept
	end)
end

local function queuePending(data: any, entry: { [string]: any })
	if type(data.PendingCodeRewards) ~= 'table' then
		data.PendingCodeRewards = {}
	end
	data.PendingCodeRewards[#data.PendingCodeRewards + 1] = entry
	logCode('egg reward queued', { code = tostring(entry.Code), kind = tostring(entry.Kind) })
end

-- Direct slot-bound delivery: reserve a free base slot, write
-- the persistence record through the canonical PlayerService
-- API, and spawn through the owning service's persistence
-- path (same path rejoin reconstruction uses). Returns
-- { ok } on delivery, { queued } when no slot is available
-- right now (caller persists as pending — never a loss), or
-- { failed } on unexpected errors (caller also persists as
-- pending; a retry is always safe).
local function deliverEgg(userId: number, data: any, codeId: string, rarity: string): { [string]: boolean }
	local failed = { ok = false, queued = false, failed = false }
	if slotServiceRef == nil or eggServiceRef == nil or playerServiceRef == nil then
		failed.failed = true
		return failed
	end
	local outcome = { ok = false, queued = false, failed = false }
	pcall(function()
		local slot = slotServiceRef.GetFreeSlot(userId)
		if type(slot) ~= 'table' or type(slot.id) ~= 'string' then
			outcome.queued = true
			return
		end
		if slotServiceRef.ReserveSlot(slot.id) ~= true then
			outcome.queued = true
			return
		end
		-- Identify the record we are about to create by diffing
		-- Ids (AddEgg returns bool, not the record).
		local before: { [string]: boolean } = {}
		pcall(function()
			for _, rec in ipairs(data.LuckyBlocks) do
				if type(rec) == 'table' and type(rec.Id) == 'string' then
					before[rec.Id] = true
				end
			end
		end)
		local written = false
		pcall(function()
			written = playerServiceRef.AddEgg(userId, slot.id, rarity, nil, nil) == true
		end)
		if not written then
			pcall(function()
				slotServiceRef.ReleaseSlot(slot.id)
			end)
			outcome.queued = true
			return
		end
		local record: any = nil
		pcall(function()
			for _, rec in ipairs(data.LuckyBlocks) do
				if
					type(rec) == 'table'
					and type(rec.Id) == 'string'
					and not before[rec.Id]
					and rec.SlotId == slot.id
				then
					record = rec
					break
				end
			end
		end)
		if type(record) ~= 'table' then
			pcall(function()
				slotServiceRef.ReleaseSlot(slot.id)
			end)
			outcome.queued = true
			return
		end
		local r: any = nil
		pcall(function()
			r = eggServiceRef.SpawnFromPersistence(userId, record, slot)
		end)
		if type(r) == 'table' and r.success == true then
			logCode('egg reward delivered', { code = codeId, rarity = rarity, slot = slot.id })
			outcome.ok = true
			return
		end
		-- Spawn failed: remove the record, release the slot, and
		-- let the caller queue as pending (retry is safe).
		pcall(function()
			playerServiceRef.RemoveEgg(userId, record.Id)
		end)
		pcall(function()
			slotServiceRef.ReleaseSlot(slot.id)
		end)
		logCode('egg spawn failed, queued as pending', { code = codeId, error = tostring(r and r.error) })
		outcome.queued = true
	end)
	if not outcome.ok and not outcome.queued then
		outcome.failed = true
	end
	return outcome
end

local function deliverAnimal(
	userId: number,
	data: any,
	codeId: string,
	defId: string,
	trait: string?,
	level: number?
): { [string]: boolean }
	if slotServiceRef == nil or animalServiceRef == nil or playerServiceRef == nil then
		return { ok = false, queued = false, failed = true }
	end
	local outcome = { ok = false, queued = false, failed = false }
	pcall(function()
		local slot = slotServiceRef.GetFreeSlot(userId)
		if type(slot) ~= 'table' or type(slot.id) ~= 'string' then
			outcome.queued = true
			return
		end
		if slotServiceRef.ReserveSlot(slot.id) ~= true then
			outcome.queued = true
			return
		end
		local before: { [string]: boolean } = {}
		pcall(function()
			for _, rec in ipairs(data.Brainrots) do
				if type(rec) == 'table' and type(rec.Id) == 'string' then
					before[rec.Id] = true
				end
			end
		end)
		local written = false
		pcall(function()
			written = playerServiceRef.AddAnimal(userId, slot.id, defId, nil, {
				Level = level or 1,
				Trait = trait,
			}) == true
		end)
		if not written then
			pcall(function()
				slotServiceRef.ReleaseSlot(slot.id)
			end)
			outcome.queued = true
			return
		end
		local record: any = nil
		pcall(function()
			for _, rec in ipairs(data.Brainrots) do
				if
					type(rec) == 'table'
					and type(rec.Id) == 'string'
					and not before[rec.Id]
					and rec.SlotId == slot.id
				then
					record = rec
					break
				end
			end
		end)
		if type(record) ~= 'table' then
			pcall(function()
				slotServiceRef.ReleaseSlot(slot.id)
			end)
			outcome.queued = true
			return
		end
		local r: any = nil
		pcall(function()
			r = animalServiceRef.SpawnFromPersistence(userId, record, slot)
		end)
		if type(r) == 'table' and r.success == true then
			logCode('animal reward granted', {
				code = codeId,
				defId = defId,
				slot = slot.id,
			})
			outcome.ok = true
			return
		end
		pcall(function()
			playerServiceRef.RemoveAnimal(userId, record.Id)
		end)
		pcall(function()
			slotServiceRef.ReleaseSlot(slot.id)
		end)
		logCode('animal spawn failed, queued as pending', { code = codeId, error = tostring(r and r.error) })
		outcome.queued = true
	end)
	if not outcome.ok and not outcome.queued then
		outcome.failed = true
	end
	return outcome
end

-- Attempt every queued reward for one player (join hook, sell
-- hook, redeem path). No polling, no timers: callers are
-- existing lifecycle events. Malformed entries are dropped;
-- well-formed but still-slotless entries stay queued.
function CodesService.TryDeliverPending(userId: number): boolean
	if type(userId) ~= 'number' then
		return false
	end
	if delivering[userId] then
		return false
	end
	delivering[userId] = true
	local delivered: { string } = {}
	pcall(function()
		local data = getData(userId)
		if type(data) ~= 'table' or type(data.PendingCodeRewards) ~= 'table' then
			return
		end
		if #data.PendingCodeRewards < 1 then
			return
		end
		local player: Player? = nil
		pcall(function()
			player = game:GetService('Players'):GetPlayerByUserId(userId)
		end)
		if player == nil then
			return
		end
		local remaining: { any } = {}
		for _, entry in ipairs(data.PendingCodeRewards) do
			local clean = sanitizePendingEntry(entry)
			if clean == nil then
				logCode('pending entry dropped (malformed)', { userId = tostring(userId) })
				continue
			end
			local done = false
			if clean.Kind == 'Egg' then
				local r = deliverEgg(userId, data, clean.Code, clean.Rarity)
				done = r.ok == true
			elseif clean.Kind == 'Animal' then
				local r = deliverAnimal(userId, data, clean.Code, clean.DefId, clean.Trait, clean.Level)
				done = r.ok == true
			end
			if done then
				if clean.Kind == 'Egg' then
					delivered[#delivered + 1] = ('+1 %s Egg'):format(clean.Rarity)
				else
					delivered[#delivered + 1] = ('+%s'):format(tostring(clean.DefId))
				end
			else
				remaining[#remaining + 1] = clean
			end
		end
		data.PendingCodeRewards = remaining
		if #delivered > 0 and player ~= nil then
			pcall(
				NotificationService.NotifySuccess,
				player,
				'Codes_PendingDelivered',
				{ RewardText = ' ' .. table.concat(delivered, ', ') }
			)
			logCode('redemption committed', { userId = tostring(userId), delivered = table.concat(delivered, ', ') })
		end
	end)
	delivering[userId] = nil
	return #delivered > 0
end

-- Shared reward pipeline (also used by DailyRewardsService —
-- one delivery implementation, not two). Thin wrappers over
-- the locals above; same semantics: { ok } delivered,
-- { queued } no slot right now (caller persists as pending),
-- { failed } systems missing.
function CodesService.DeliverEggReward(
	userId: number,
	data: any,
	codeLabel: string,
	rarity: string
): { [string]: boolean }
	return deliverEgg(userId, data, codeLabel, rarity)
end

function CodesService.DeliverAnimalReward(
	userId: number,
	data: any,
	codeLabel: string,
	defId: string,
	trait: string?,
	level: number?
): { [string]: boolean }
	return deliverAnimal(userId, data, codeLabel, defId, trait, level)
end

function CodesService.QueuePendingReward(data: any, entry: { [string]: any })
	queuePending(data, entry)
end

-- Reward summary for the success toast (server-formatted;
-- the client never calculates). Queued units are marked so
-- the player knows to free a base slot.
local function describeRewards(
	cashText: string?,
	eggParts: { string },
	toolParts: { string },
	animalParts: { string },
	queuedCount: number
): string
	local parts: { string } = {}
	if cashText ~= nil and cashText ~= '' then
		parts[#parts + 1] = cashText
	end
	for _, p in ipairs(eggParts) do
		parts[#parts + 1] = p
	end
	for _, p in ipairs(toolParts) do
		parts[#parts + 1] = p
	end
	for _, p in ipairs(animalParts) do
		parts[#parts + 1] = p
	end
	local text = ' ' .. table.concat(parts, ', ')
	if queuedCount > 0 then
		text ..= ' (queued: free a base slot!)'
	end
	return text
end

local function formatCash(amount: string): string
	local text: string? = nil
	pcall(function()
		text = BigNumber.Format(amount)
	end)
	if type(text) == 'string' and text ~= '' then
		return '+$' .. text
	end
	return '+$' .. tostring(amount)
end

-- The one authoritative redeem path. Returns the result table
-- (also pushed to CodesResult + the Notify channel).
function CodesService.Redeem(player: Player, codeText: any): { [string]: any }
	local userId = player.UserId
	logCode('redeem requested', { player = player.Name, userId = tostring(userId) })
	local norm = CodesConfig.NormalizeCode(codeText)
	if norm == nil then
		logCode('invalid code', { player = player.Name })
		local result = failRedeem(player, 'unknown-code', 'Codes_InvalidCode', nil)
		pushResult(player, result)
		return result
	end
	logCode('code normalized', { player = player.Name, code = norm })
	local key = lockKey(userId, norm)
	if locks[key] then
		-- Double-click / multi-fire / spam: the first request
		-- owns the transaction; this one only waits out.
		local busy = failRedeem(player, 'busy', 'General_Cooldown', nil)
		pushResult(player, busy)
		return busy
	end
	locks[key] = true
	local result: { [string]: any } = { Success = false, Reason = 'internal' }
	local ok = false
	pcall(function()
		result = CodesService.RedeemInner(player, userId, norm)
		ok = true
	end)
	locks[key] = nil
	if not ok then
		warn(('[Codes] Redeem errored player=%s code=%s'):format(player.Name, norm))
		result = failRedeem(player, 'internal', 'General_Generic', nil)
	end
	-- Funnel: successful redemption only (promo code ids are
	-- public by design — no PII).
	if result.Success == true then
		pcall(function()
			FunnelService:LogStep(player, 'Rewards', 'CodeRedeemed', { code = norm })
		end)
	end
	pushResult(player, result)
	return result
end

function CodesService.RedeemInner(player: Player, userId: number, norm: string): { [string]: any }
	-- 1. Code exists.
	local def = CodesConfig.FindById(norm)
	if def == nil then
		logCode('invalid code', { player = player.Name, code = norm })
		return failRedeem(player, 'unknown-code', 'Codes_InvalidCode', nil)
	end
	-- 2. Code is enabled.
	if def.Enabled ~= true then
		logCode('disabled code', { player = player.Name, code = norm })
		return failRedeem(player, 'disabled', 'Codes_CodeDisabled', nil)
	end
	-- 3. Code has not expired (server time only).
	if type(def.ExpiresAt) == 'number' and os.time() >= (def.ExpiresAt :: number) then
		logCode('expired code', { player = player.Name, code = norm })
		return failRedeem(player, 'expired', 'Codes_CodeExpired', nil)
	end
	-- Systems + profile must exist before any validation that
	-- reads them.
	if playerServiceRef == nil or economyServiceRef == nil then
		logCode('systems not wired', { player = player.Name, code = norm })
		return failRedeem(player, 'no-systems', 'General_Generic', nil)
	end
	local data = getData(userId)
	if type(data) ~= 'table' then
		return failRedeem(player, 'no-systems', 'General_Generic', nil)
	end
	if type(data.RedeemedCodes) ~= 'table' then
		data.RedeemedCodes = {}
	end
	-- 4. Per-player limit.
	local maxPer = def.MaxPerPlayer or 1
	local redeemed = data.RedeemedCodes[norm]
	if type(redeemed) ~= 'number' then
		redeemed = 0
	end
	if redeemed >= maxPer then
		logCode('already redeemed', { player = player.Name, code = norm })
		return failRedeem(player, 'already-redeemed', 'Codes_AlreadyRedeemed', nil)
	end
	-- 5. Global limit (best-effort per-server counter).
	if
		type(def.MaxGlobalRedemptions) == 'number'
		and (globalCounts[norm] or 0) >= (def.MaxGlobalRedemptions :: number)
	then
		logCode('global cap reached', { player = player.Name, code = norm })
		return failRedeem(player, 'disabled', 'Codes_CodeDisabled', nil)
	end
	-- 6. Reward configuration is valid (defense in depth:
	-- boot validation should already guarantee this).
	if #CodesConfig.ValidateRewards(def.Rewards) > 0 then
		logCode('invalid reward config', { player = player.Name, code = norm })
		return failRedeem(player, 'invalid-config', 'General_Generic', nil)
	end
	-- 7/8. Required systems for the configured categories.
	local needsSlots = (def.Rewards.Eggs ~= nil) or (def.Rewards.Animals ~= nil)
	if needsSlots and (slotServiceRef == nil or eggServiceRef == nil or animalServiceRef == nil) then
		return failRedeem(player, 'no-systems', 'General_Generic', nil)
	end
	if def.Rewards.Tools ~= nil and gearShopServiceRef == nil then
		return failRedeem(player, 'no-systems', 'General_Generic', nil)
	end

	logCode('redemption started', { player = player.Name, code = norm })

	-- Commit order: tools -> cash -> slot rewards -> mark.
	-- Tools are idempotent (re-grant no-ops), cash cannot fail
	-- post-validation, slot rewards persist as pending instead
	-- of failing. Nothing is marked redeemed until all three
	-- land.
	local toolParts: { string } = {}
	if def.Rewards.Tools ~= nil then
		for _, tool in ipairs(def.Rewards.Tools :: { any }) do
			local granted = false
			pcall(function()
				granted = gearShopServiceRef.EnsureGearTool(player, tool.Id) == true
			end)
			if not granted then
				logCode('tool grant failed', { player = player.Name, code = norm, gear = tostring(tool.Id) })
				return failRedeem(player, 'grant-failed', 'General_Generic', nil)
			end
			local gearName = tostring(tool.Id)
			pcall(function()
				local CodesGearConfig = require(ReplicatedStorage.Config.Economy.Gear)
				local entry = CodesGearConfig.FindGear(tool.Id)
				if entry ~= nil and type(entry.Name) == 'string' then
					gearName = entry.Name
				end
			end)
			toolParts[#toolParts + 1] = '+' .. gearName
			logCode('tool reward granted', { player = player.Name, code = norm, gear = tostring(tool.Id) })
		end
	end

	local cashText: string? = nil
	if def.Rewards.Cash ~= nil then
		local cash = def.Rewards.Cash :: string
		local oldMoney: string? = nil
		pcall(function()
			oldMoney = economyServiceRef.GetMoney(userId)
		end)
		local res: any = nil
		pcall(function()
			res = economyServiceRef.AddMoney(userId, cash, 'CodeReward', { ApplyMultiplier = false })
		end)
		if type(res) ~= 'table' or res.Success ~= true then
			logCode('cash grant failed', { player = player.Name, code = norm })
			return failRedeem(player, 'grant-failed', 'General_Generic', nil)
		end
		cashText = formatCash(cash)
		-- Same money-burst presentation as collects/sales/arena:
		-- the existing CashCollected remote drives the icon
		-- burst + count-up in MoneyPoolController (raw BigNumber
		-- strings, never formatted; no world Origin for code
		-- grants, same as arena rewards). Skipped on zero
		-- amounts, like the collect path.
		if not BigNumber.IsZero(cash) then
			pcall(function()
				Remotes.FireClient(player, Remotes.Names.CashCollected, {
					Amount = cash,
					NewMoney = res.NewMoney,
					Icon = MoneyIcon.Resolve(),
				})
			end)
		end
		logCode('cash reward granted', {
			player = player.Name,
			code = norm,
			amount = cash,
			old = tostring(oldMoney),
			new = tostring(res.NewMoney),
		})
	end

	local eggParts: { string } = {}
	local animalParts: { string } = {}
	local queuedCount = 0
	if def.Rewards.Eggs ~= nil then
		for _, egg in ipairs(def.Rewards.Eggs :: { any }) do
			for _ = 1, egg.Amount do
				local r = deliverEgg(userId, data, norm, egg.Rarity)
				if r.ok then
					eggParts[#eggParts + 1] = ('+1 %s Egg'):format(egg.Rarity)
				else
					queuePending(data, { Code = norm, Kind = 'Egg', Rarity = egg.Rarity })
					eggParts[#eggParts + 1] = ('+1 %s Egg'):format(egg.Rarity)
					queuedCount += 1
				end
			end
		end
	end
	if def.Rewards.Animals ~= nil then
		for _, animal in ipairs(def.Rewards.Animals :: { any }) do
			for _ = 1, animal.Amount do
				local r = deliverAnimal(userId, data, norm, animal.DefId, animal.Trait, animal.Level)
				if r.ok then
					animalParts[#animalParts + 1] = ('+%s'):format(tostring(animal.DefId))
				else
					queuePending(data, {
						Code = norm,
						Kind = 'Animal',
						DefId = animal.DefId,
						Trait = animal.Trait,
						Level = animal.Level,
					})
					animalParts[#animalParts + 1] = ('+%s'):format(tostring(animal.DefId))
					queuedCount += 1
				end
			end
		end
	end

	-- Mark redeemed ONLY now: everything is committed or safely
	-- persisted as pending.
	data.RedeemedCodes[norm] = redeemed + 1
	globalCounts[norm] = (globalCounts[norm] or 0) + 1
	logCode('redemption committed', { player = player.Name, code = norm, queued = tostring(queuedCount) })

	local rewardText = describeRewards(cashText, eggParts, toolParts, animalParts, queuedCount)
	pcall(NotificationService.NotifySuccess, player, 'Codes_Success', { RewardText = rewardText })
	return { Success = true, RewardText = rewardText }
end

-- Join hook (bootstrap, after base restore + offline earnings
-- so the snapshot already includes any delivered reward).
function CodesService.OnPlayerReady(player: Player)
	pcall(function()
		CodesService.NormalizePlayer(player.UserId)
		CodesService.TryDeliverPending(player.UserId)
	end)
end

function CodesService.ForgetPlayer(userId: number)
	for key in pairs(locks) do
		if key:sub(1, #tostring(userId) + 1) == tostring(userId) .. '\0' then
			locks[key] = nil
		end
	end
	delivering[userId] = nil
end

-- --- Remote ingress ----------------------------------------------------

local function handleAction(player: Player, payload: any)
	local ok, err = pcall(function()
		if not Validation.LivePlayer(player) then
			return
		end
		-- The ONLY accepted input: { Action = 'Redeem', Code }.
		-- Any reward/cash/egg/tool/animal field on the payload
		-- is ignored — the server resolves everything from
		-- CodesConfig, so exploit payloads grant nothing extra.
		if type(payload) ~= 'table' or payload.Action ~= 'Redeem' then
			return
		end
		if type(payload.Code) ~= 'string' or #payload.Code > 64 then
			pushResult(player, failRedeem(player, 'unknown-code', 'Codes_InvalidCode', nil))
			return
		end
		CodesService.Redeem(player, payload.Code)
	end)
	if not ok then
		warn(('[Codes] Action handler errored: %s'):format(tostring(err)))
	end
end

-- --- Init ------------------------------------------------------------------

function CodesService.Init()
	if started then
		return
	end
	started = true
	for _, issue in ipairs(CodesConfig.ValidateLive()) do
		warn(('[Codes] Config issue: %s'):format(issue))
	end
	local ok, err = pcall(function()
		local folder = Remotes.GetFolder()
		local remote = folder:WaitForChild(Remotes.Names.CodesAction, 10)
		assert(remote and remote:IsA('RemoteEvent'), 'CodesAction remote missing')
		local actionRemote = remote :: RemoteEvent
		actionRemote.OnServerEvent:Connect(handleAction)
	end)
	if not ok then
		warn(('[Codes] Action remote wiring failed: %s'):format(tostring(err)))
	end
	logCode('Init done', nil)
end

function CodesService._TestReset()
	for key in pairs(locks) do
		locks[key] = nil
	end
	for key in pairs(delivering) do
		delivering[key] = nil
	end
end

return table.freeze(CodesService)
