--!strict
--!native
--[[
	Combat.BatService
	=================
	Server-authoritative Bat PvP. The client sends ONE minimal event
	("I swung") and the server decides everything else: validity,
	cooldown, hitbox, targets, SFX, ragdoll, knockback, and carry
	interruption — synchronously in the swing path (no waits, no
	polling, no animation-gating). No hit VFX by design.

	Design (all Player-vs-Player, no damage):
	  * Validation: LivePlayer, live character/humanoid/HRP, an
	    actually-equipped Bat Tool whose name maps to BatConfig,
	    attacker not ragdolled, per-attacker cooldown elapsed.
	  * Hitbox: one immediate workspace:GetPartBoundsInBox in front
	    of the attacker (OverlapParams excludes the attacker).
	    Parts resolve to players via GetPlayerFromCharacter and
	    dedupe by Player (many body parts = one target). Self and
	    dead targets are skipped.
	  * Per target, immediately: carry interruption first (steal
	    via idempotent StealService rollback, else the owner's own
	    animal/egg via the existing Recover paths), then
	    RagdollService.Ragdoll (skipped while target ragdoll
	    immunity holds — knockback still applies), directional
	    knockback (attacker->target + vertical launch), then one
	    cycled HitSfx (Attack1->2->3) played at the target.
	  * Hit SFX is server-mounted in the target (Debris-cleaned):
	    audible to everyone with zero client trust and zero extra
	    round trips.
]]

local Players = game:GetService('Players')
local Workspace = game:GetService('Workspace')
local ServerStorage = game:GetService('ServerStorage')
local Debris = game:GetService('Debris')

local Validation = require(game:GetService('ReplicatedStorage').Utility.Validation)
local Remotes = require(game:GetService('ReplicatedStorage').Utility.Remotes)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local BatConfig = require(game:GetService('ReplicatedStorage').Config.Economy.Gear).Combat
local SlotType = require(game:GetService('ReplicatedStorage').Types.SlotType)
local AudioGroups = require(game:GetService('ReplicatedStorage').Utility.AudioGroups)

local RagdollService = require(script.Parent.RagdollService)
local StealService = require(script.Parent.Parent.Steal.StealService)
local CarryRegistry = require(game:GetService('ServerScriptService').Carry.CarryRegistry)
local AnimalService = require(game:GetService('ServerScriptService').AnimalService)
local EggService = require(game:GetService('ServerScriptService').EggService)

local BatService = {}

local _wired = false
local _lastSwing: { [number]: number } = {}
local _nextRagdollAt: { [number]: number } = {}
local _sfxCycle = 0

local SFX_LIFETIME_S = 6

-- --- Asset resolution (tolerant, warn-once) -------------------------

local _sfxTemplates: { Sound? } = { nil, nil, nil }
local _sfxWarned = false

local function resolveSfx(index: number): Sound?
	local idx = math.clamp(math.floor(tonumber(index) or 1), 1, 3)
	local cached = _sfxTemplates[idx]
	if cached ~= nil and (cached :: Sound).Parent ~= nil then
		return cached
	end
	local found: Sound? = nil
	pcall(function()
		local assets = ServerStorage:FindFirstChild('Assets')
		local sfx = assets and assets:FindFirstChild('Sfx') or nil
		-- Canonical per spec: Assets.Sfx.HitSfx.Attack<N>; the boot
		-- mirror reads a flat Assets.Sfx.Attack<N>, so accept both.
		local hit = sfx and sfx:FindFirstChild('HitSfx') or nil
		local node = (hit and hit:FindFirstChild('Attack' .. tostring(idx)))
			or (sfx and sfx:FindFirstChild('Attack' .. tostring(idx)))
		if node ~= nil then
			if node:IsA('Sound') then
				found = node
			else
				local inner = node:FindFirstChildWhichIsA('Sound', true)
				if inner ~= nil and inner:IsA('Sound') then
					found = inner
				end
			end
		end
	end)
	if found ~= nil then
		_sfxTemplates[idx] = found
	elseif not _sfxWarned then
		_sfxWarned = true
		Debug.Warn('Bat', 'HitSfx missing (Assets.Sfx.HitSfx/Attack1..3) — hits run without SFX', {})
	end
	return found
end

-- --- Presentation (server-mounted hit SFX, Debris-cleaned) -------

local function playHitSfx(targetHrp: BasePart): string?
	_sfxCycle = _sfxCycle % 3 + 1
	local template = resolveSfx(_sfxCycle)
	if template == nil then
		return nil
	end
	local played: string? = nil
	pcall(function()
		local clone = (template :: Sound):Clone()
		AudioGroups.AssignSfx(clone)
		clone.Parent = targetHrp
		clone:Play()
		Debris:AddItem(clone, SFX_LIFETIME_S)
		played = 'Attack' .. tostring(_sfxCycle)
	end)
	return played
end

-- --- Swing pipeline --------------------------------------------------

-- Interrupt ANY active hold on the target: steal (either kind) via
-- the idempotent StealService rollback, else the owner's own
-- animal/egg via the existing Recover paths (which restore to the
-- correct Stand/slot). Never reconstructs placement manually.
-- Returns true when something was interrupted. Declared before
-- onSwing (lexical order matters for locals).
local function interruptCarry(target: Player): boolean
	local uid = target.UserId
	if StealService.RollbackIfStealing(uid, 'HitByBat') then
				Debug.Log('Bat', ('steal cancelled player=%s'):format(target.Name))
		return true
	end
	local item: any = nil
	pcall(function()
		item = CarryRegistry.Get(uid)
	end)
	if type(item) ~= 'table' or item.steal ~= nil then
		return false
	end
	if item.kind == SlotType.OccupantKind.Animal then
		pcall(function()
			AnimalService.RecoverCarriedAnimal(uid, 'HitByBat')
		end)
		return true
	elseif item.kind == SlotType.OccupantKind.Egg then
		pcall(function()
			EggService.RecoverCarriedEgg(target, 'HitByBat')
		end)
		return true
	end
	return false
end

local function equippedBat(character: Model): (Tool?, any)
	local tool = character:FindFirstChildOfClass('Tool')
	if tool == nil or not tool:IsA('Tool') then
		return nil, nil
	end
	local entry: any = nil
	pcall(function()
		entry = BatConfig.GetByToolName(tool.Name)
	end)
	if entry == nil then
		return nil, nil
	end
	return tool, entry
end

local function onSwing(player: Player)
	if not Validation.LivePlayer(player) then
		return
	end
	local character = player.Character
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass('Humanoid')
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	local attackerHrp = character:FindFirstChild('HumanoidRootPart')
	if attackerHrp == nil or not (attackerHrp :: Instance):IsA('BasePart') then
		return
	end
	local _, entry = equippedBat(character)
	if entry == nil then
		return
	end
	if RagdollService.IsRagdolled(player) then
		return
	end
	-- Global tool lock: carrying/stealing players cannot activate
	-- gameplay Tools (server-authoritative; the equipped Tool was
	-- already moved to the Backpack at carry start, so this covers
	-- forged requests and mid-carry re-equips).
	if CarryRegistry.IsCarrying(player.UserId) then
		Debug.Log('Bat', ('rejected carrying player=%s bat=%s'):format(player.Name, (entry :: any).GearId))
		return
	end
	local now = os.clock()
	local last = _lastSwing[player.UserId] or 0
	if now - last < (entry :: any).SwingCooldown then
		Debug.Log('Bat', ('rejected cooldown player=%s bat=%s'):format(player.Name, (entry :: any).GearId))
		return
	end
	_lastSwing[player.UserId] = now
	Debug.Log('Bat', ('swing player=%s bat=%s'):format(player.Name, (entry :: any).GearId))

	-- Single immediate spatial query (the swing's one hit window).
	-- 1.75x the configured hitbox, position unchanged (still in
	-- front of the attacker). Knockback values are NOT scaled.
	local size: Vector3 = (entry :: any).Hitbox.Size * 1.75
	local offset: CFrame = (entry :: any).Hitbox.Offset
	local box = (attackerHrp :: BasePart).CFrame * offset
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params:AddToFilter(character)
	local parts: { BasePart } = {}
	pcall(function()
		parts = Workspace:GetPartBoundsInBox(box, size, params)
	end)
	-- Resolve + dedupe by Player (many body parts = one target).
	local targets: { Player } = {}
	local seen: { [Player]: boolean } = {}
	for _, part in ipairs(parts) do
		local node: Instance? = part
		local target: Player? = nil
		pcall(function()
			local cursor: Instance? = node
			while cursor ~= nil and target == nil do
				target = Players:GetPlayerFromCharacter(cursor :: Model)
				cursor = (cursor :: Instance).Parent
			end
		end)
		if target ~= nil and target ~= player and seen[target] == nil then
			seen[target] = true
			local tChar = target.Character
			local tHum = if tChar ~= nil then tChar:FindFirstChildOfClass('Humanoid') else nil
			if tHum ~= nil and tHum.Health > 0 then
				targets[#targets + 1] = target
			end
		end
	end
	for _, target in ipairs(targets) do
		local tChar = target.Character
		if tChar == nil then
			continue
		end
		local targetHrp = tChar:FindFirstChild('HumanoidRootPart')
		if targetHrp == nil or not (targetHrp :: Instance):IsA('BasePart') then
			continue
		end
				Debug.Log('Bat', ('hit attacker=%s target=%s bat=%s'):format(player.Name, target.Name, (entry :: any).GearId))
		-- Immediate confirmed-hit response, same execution path:
		-- interrupt carry -> ragdoll (immunity-gated) ->
		-- knockback -> hit SFX. No VFX by design.
		local hrp = targetHrp :: BasePart
		if interruptCarry(target) then
						Debug.Log('Bat', ('carry interrupted player=%s'):format(target.Name))
		end
		do
			local nowHit = os.clock()
			local immuneUntil = _nextRagdollAt[target.UserId] or 0
			if nowHit >= immuneUntil then
				-- Opportunistic prune: the table only ever holds
				-- one timestamp per recently-hit player.
				for uid, untilTs in pairs(_nextRagdollAt) do
					if untilTs <= nowHit and uid ~= target.UserId then
						_nextRagdollAt[uid] = nil
					end
				end
				if RagdollService.Ragdoll(target, (entry :: any).RagdollDuration) then
					_nextRagdollAt[target.UserId] = nowHit + (entry :: any).RagdollDuration + (entry :: any).RagdollImmunity
										Debug.Log('Bat', ('ragdoll target=%s duration=%.2f'):format(target.Name, (entry :: any).RagdollDuration))
				end
			else
								Debug.Log('Bat', ('ragdoll immune target=%s remaining=%.2f'):format(target.Name, immuneUntil - nowHit))
			end
		end
		do
			local aPos = (attackerHrp :: BasePart).Position
			local tPos = hrp.Position
			local flat = Vector3.new(tPos.X - aPos.X, 0, tPos.Z - aPos.Z)
			if flat.Magnitude < 1e-3 then
				flat = (attackerHrp :: BasePart).CFrame.LookVector
				flat = Vector3.new(flat.X, 0, flat.Z)
				if flat.Magnitude < 1e-3 then
					flat = Vector3.new(0, 0, -1)
				end
			end
			flat = flat.Unit
			local kb: any = (entry :: any).Knockback
			hrp.AssemblyLinearVelocity = flat * kb.Horizontal + Vector3.new(0, kb.Vertical, 0)
						Debug.Log('Bat', ('knockback target=%s horizontal=%s vertical=%s'):format(target.Name, tostring(kb.Horizontal), tostring(kb.Vertical)))
		end
		local soundName = playHitSfx(hrp)
		if soundName ~= nil then
			Debug.Log('Bat', ('hitSFX target=%s sound=%s'):format(target.Name, soundName))
		end
	end
end

function BatService.Init()
	if _wired then
		return
	end
	_wired = true
	pcall(function()
		local folder = Remotes.GetFolder()
		local event = folder:WaitForChild(Remotes.Names.BatSwing, 10)
		if event ~= nil and (event :: Instance):IsA('RemoteEvent') then
			(event :: RemoteEvent).OnServerEvent:Connect(onSwing)
		else
			Debug.Warn('Bat', 'BatSwing remote missing; bat hits disabled', {})
		end
	end)
end

function BatService._TestReset()
	table.clear(_lastSwing)
	table.clear(_nextRagdollAt)
	_sfxCycle = 0
end

return table.freeze(BatService)
