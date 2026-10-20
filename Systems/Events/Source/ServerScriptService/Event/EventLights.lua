--!strict
--!native
--[[
	Event.EventLights
	=================
	The ONE event light switchboard. It knows NOTHING about
	Galaxy/Snowfall — it reads container-path arrays from an
	event definition's `Lights` key and toggles the actual
	Light instances underneath. No path-specific branches
	exist anywhere in this module.

	Path convention (same as EnvironmentModifier):
	  * "Map...."  — Workspace-relative INCLUDING the Map
	    segment ("Map.MainIsland.PointLights" walks Workspace
	    -> Map -> MainIsland -> PointLights).
	  * "Base...." — resolved inside EVERY player-base folder
	    (every child of the authoritative bases container —
	    never only Base_1).

	Every configured path is a RECURSIVE ROOT: the resolved
	instance itself is processed when it IsA('Light')
	(PointLight, SpotLight, SurfaceLight — all inherit Light),
	AND every descendant Light at ANY depth is processed.
	A container Folder/Model around the lights behaves the
	same as a lone Light root.

	Restoration: the original Enabled state is snapshotted
	per instance BEFORE the first write (never assumed
	defaults — a light authored ON stays ON). Restore() puts
	the exact originals back and is idempotent (second call
	is a no-op). Nothing is cloned, created, or destroyed;
	missing paths / bases log and are skipped; one bad path
	never aborts the rest.
]]

local EnvironmentModifier = require(script.Parent.EnvironmentModifier)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local EventLights = {}

export type LightSnapshot = {
	entries: { { inst: Light, enabled: boolean } },
}

export type LightsOptions = {
	mapRoot: Instance?,
	baseRoots: { Instance }?,
}

-- Collect every Light under `root`, INCLUDING `root`
-- itself. Never throws.
local function _collectLights(root: Instance?): { Light }
	local out: { Light } = {}
	pcall(function()
		if typeof(root) ~= 'Instance' then
			return
		end
		local node = root :: Instance
		if node:IsA('Light') then
			out[#out + 1] = node :: Light
		end
		for _, desc in ipairs(node:GetDescendants()) do
			if desc:IsA('Light') then
				out[#out + 1] = desc :: Light
			end
		end
	end)
	return out
end

-- Apply one event's Lights.Containers: every resolved Light
-- turns ON. `opts` overrides the live roots (headless-test
-- seam; production passes nil). Returns a snapshot for
-- Restore(). First write wins the snapshot. Never throws.
function EventLights.ApplyLights(lightCfg: any, opts: LightsOptions?): LightSnapshot
	local snapshot: LightSnapshot = { entries = {} }
	pcall(function()
		if type(lightCfg) ~= 'table' then
			return
		end
		local containers: any = lightCfg.Containers
		if type(containers) ~= 'table' then
			return
		end
		local saved: { [Instance]: boolean } = {}
		for _, target in ipairs(containers) do
			if type(target) ~= 'string' or target == '' then
				continue
			end
			local roots = EnvironmentModifier.ResolveRoots(target, opts)
			if #roots == 0 then
				Debug.Warn('EV', 'event light container resolved to nothing; skipped', { target = target })
				continue
			end
			local lit = 0
			for _, root in ipairs(roots) do
				for _, light in ipairs(_collectLights(root)) do
					pcall(function()
						if not saved[light] then
							saved[light] = true
							snapshot.entries[#snapshot.entries + 1] =
								{ inst = light, enabled = (light :: Light).Enabled }
						end
						(light :: Light).Enabled = true
					end)
					lit += 1
				end
			end
			if lit == 0 then
				Debug.Warn('EV', 'event light container has no lights; skipped', { target = target })
			end
		end
	end)
	return snapshot
end

-- Restore a snapshot from ApplyLights. Exact originals back,
-- missing/destroyed instances skipped. Idempotent: restores
-- once (entries cleared), second call is a no-op. Never throws.
function EventLights.Restore(snapshot: LightSnapshot?)
	pcall(function()
		if type(snapshot) ~= 'table' then
			return
		end
		local snap = snapshot :: LightSnapshot
		if type(snap.entries) ~= 'table' then
			return
		end
		for _, entry in ipairs(snap.entries) do
			pcall(function()
				local raw: any = entry.inst
				if typeof(raw) == 'Instance' and raw.Parent ~= nil and raw:IsA('Light') then
					(raw :: Light).Enabled = entry.enabled == true
				end
			end)
		end
		table.clear(snap.entries)
	end)
end

-- TEST seam: count of lights one container path would hit
-- (pure resolution, no writes). Overrides inject fake roots
-- so specs never touch the live Workspace.
function EventLights._TestCollectCount(
	target: string,
	mapRootOverride: Instance?,
	baseRootsOverride: { Instance }?
): number
	local count = 0
	pcall(function()
		local roots =
			EnvironmentModifier.ResolveRoots(target, { mapRoot = mapRootOverride, baseRoots = baseRootsOverride })
		for _, root in ipairs(roots) do
			count += #_collectLights(root)
		end
	end)
	return count
end

return table.freeze(EventLights)
