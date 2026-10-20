--!strict
--!native
--[[
	ArenaCameraImpacts
	==================
	Client-only cartoony camera punch for Arena hits. The
	server stays fully authoritative (attacker, target,
	damage, timing); this controller only presents impact
	feel for NEARBY spectators from the existing
	ArenaCombatEvent attack feed.

	Distance falloff (camera -> impact position):
	  0-15 studs   noticeable but controlled micro shake
	  15-30 studs  subtle shake, fading to nothing
	  30+ studs    no shake, no work

	ONE RenderStepped connection, created lazily on the first
	in-range impact and disconnected when no impulses remain.
	Impulses combine by summation (clamped). Offsets are
	ADDITIVE on the live camera CFrame every frame — no base
	transform is ever stored, so camera type, player controls,
	cutscenes, and respawns are never disturbed. Short,
	damped, cartoony ("BOOM", never earthquake).
]]

local RunService = game:GetService('RunService')
local Workspace = game:GetService('Workspace')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
local ArenaPresentationConfig = require(ReplicatedStorage.Config.World.ArenaFeel)

local ArenaCameraImpacts = {}

local wired = false

-- Presentation-only tunables (never authority). Canonical source:
-- ArenaPresentationConfig.CameraShake. Values preserved exactly.
local Shake = ArenaPresentationConfig.CameraShake
local FULL_RANGE = Shake.FullRange
local MAX_RANGE = Shake.MaxRange
local DURATION = Shake.Duration
local MAX_POS = Shake.MaxPosition
local MAX_ROT = Shake.MaxRotation

type Impulse = {
	position: Vector3,
	strength: number,
	startedAt: number,
	phase: number,
}

local active: { Impulse } = {}
local connection: RBXScriptConnection? = nil
local impulseSeq = 0

-- 0-1 strength for a camera distance. Pure (headless-safe).
local function falloff(distance: number): number
	if type(distance) ~= 'number' or distance ~= distance or distance < 0 then
		return 0
	end
	if distance <= FULL_RANGE then
		return 1
	end
	if distance >= MAX_RANGE then
		return 0
	end
	return 1 - (distance - FULL_RANGE) / (MAX_RANGE - FULL_RANGE)
end

local function prune(now: number)
	for i = #active, 1, -1 do
		if now - active[i].startedAt >= DURATION then
			table.remove(active, i)
		end
	end
	if #active == 0 and connection ~= nil then
		pcall(function()
			(connection :: RBXScriptConnection):Disconnect()
		end)
		connection = nil
	end
end

local function ensureLoop()
	if connection ~= nil then
		return
	end
	pcall(function()
		connection = RunService.RenderStepped:Connect(function()
			local ok = pcall(function()
				local now = os.clock()
				local camera = Workspace.CurrentCamera
				if camera == nil then
					prune(now)
					return
				end
				local px, py, rx, ry = 0, 0, 0, 0
				for _, impulse in ipairs(active) do
					local age = now - impulse.startedAt
					if age >= 0 and age < DURATION then
						-- Fast attack + exponential decay: an
						-- opening thump that settles quickly.
						local envelope = math.exp(-age * 12) * (0.6 + 0.4 * math.exp(-age * 40))
						local s = impulse.strength * envelope
						local p = impulse.phase
						px += s * math.sin(age * 55 + p)
						py += s * math.sin(age * 47 + p * 1.7) * 0.7
						rx += s * math.sin(age * 61 + p * 2.3) * 0.6
						ry += s * math.sin(age * 52 + p * 0.6) * 0.6
					end
				end
				-- Stack clamp: rapid hits combine, never explode.
				px = math.clamp(px * MAX_POS, -MAX_POS, MAX_POS)
				py = math.clamp(py * MAX_POS, -MAX_POS, MAX_POS)
				rx = math.clamp(rx * MAX_ROT, -MAX_ROT, MAX_ROT)
				ry = math.clamp(ry * MAX_ROT, -MAX_ROT, MAX_ROT)
				camera.CFrame = camera.CFrame * CFrame.new(px, py, 0) * CFrame.Angles(rx, ry, 0)
				prune(now)
			end)
			if not ok then
				prune(os.clock())
			end
		end)
	end)
end

local function onImpact(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	-- Authoritative hit packets only (one per attack — the
	-- sim 'attack' feed would double-trigger). Result/menu
	-- payloads lack a contact point and are ignored.
	if payload.Event ~= 'ArenaHit' then
		return
	end
	-- Server broadcasts ImpactPosition (capital I). Accept the
	-- lowercase mirror too so presentation never silently drops
	-- the punch over a key-casing drift.
	local pos = payload.ImpactPosition
	if typeof(pos) ~= 'Vector3' then
		pos = payload.impactPosition
	end
	if typeof(pos) ~= 'Vector3' then
		return
	end
	local camera: Camera? = nil
	pcall(function()
		camera = Workspace.CurrentCamera
	end)
	if camera == nil then
		return
	end
	local distance = 0
	pcall(function()
		distance = ((camera :: Camera).CFrame.Position - (pos :: Vector3)).Magnitude
	end)
	local strength = falloff(distance)
	if strength <= 0 then
		return
	end
	impulseSeq += 1
	active[#active + 1] = {
		position = pos,
		strength = strength,
		startedAt = os.clock(),
		phase = impulseSeq * 1.37,
	}
	ensureLoop()
end

function ArenaCameraImpacts.Init()
	if wired then
		return
	end
	wired = true
	local folder = Remotes.WaitForReady()
	local okEvent, combatEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.ArenaCombatEvent, 10)
	end)
	if okEvent and combatEvent ~= nil and (combatEvent :: Instance):IsA('RemoteEvent') then
		pcall(function()
			(combatEvent :: RemoteEvent).OnClientEvent:Connect(onImpact)
		end)
	end
end

-- TEST-ONLY seam (pure falloff math, no camera needed).
function ArenaCameraImpacts._TestFalloff(distance: number): number
	return falloff(distance)
end

return table.freeze(ArenaCameraImpacts)
