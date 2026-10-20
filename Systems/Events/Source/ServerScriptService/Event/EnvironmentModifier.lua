--!strict
--!native
--[[
	Event.EnvironmentModifier
	=========================
	The ONE generic map/environment transformation system for
	events. It knows NOTHING about Galaxy/Snowfall — it reads
	color categories + target-path arrays from EventConfig and
	applies them. No path-specific branches exist anywhere in
	this module: adding "Map.MainIsland.Island.Bush" (or any
	future target) to a config Targets array picks it up with
	zero engine changes.

	Path convention (from EventConfig):
	  * "Map...."  — Workspace-relative INCLUDING the Map
	    segment ("Map.MainIsland.Paths" walks Workspace ->
	    Map -> MainIsland -> Paths).
	  * "Base...." — resolved inside EVERY player-base folder
	    (every child of the authoritative bases container —
	    never only Base_1): "Base.Build.Paths" walks
	    <each base> -> Build -> Paths.

	Every configured path is a RECURSIVE ROOT:
	  * the resolved instance itself is processed when it is
	    a renderable BasePart (Parts, MeshParts,
	    UnionOperations, ... — all inherit BasePart), AND
	  * EVERY descendant BasePart at ANY depth is processed.
	    GetDescendants() alone would miss a Part-root, so the
	    root check is explicit (see CollectParts).

	Restoration: original Color (+ Material) is snapshotted
	per instance BEFORE the first write (never assumed
	defaults). Restore() puts the exact originals back and is
	idempotent (second call is a no-op).

	Only visual properties are touched (Color + optional
	Material) — never deletion, reparenting, collision, or
	prompts. Missing paths / bases log and are skipped; one
	bad path never aborts the rest. Per-target resolution is
	printed (one-shot per event start, never per frame) so a
	place-authoring mismatch is diagnosable in Studio output:

	  [EventEnvironment] Resolved target: Map.MainIsland.Paths
	  [EventEnvironment] Root Class: Folder
	  [EventEnvironment] Renderable parts found: 37
]]

local Workspace = game:GetService('Workspace')

local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local EnvironmentModifier = {}

export type EnvSnapshot = {
	entries: { { inst: Instance, color: Color3, material: Enum.Material } },
}

export type ResolveOptions = {
	mapRoot: Instance?,
	baseRoots: { Instance }?,
}

local function _splitPath(path: string): { string }
	local segments: { string } = {}
	for seg in string.gmatch(path, '[^.]+') do
		segments[#segments + 1] = seg
	end
	return segments
end

-- Walk one segment list under each root, one level per
-- segment, operating on the SET of current matches: each
-- component resolves against ALL current matches and the
-- results become the new set.
--   * normal component: the single named child per match
--     (FindFirstChild — duplicate names do NOT fan out).
--   * '*' wildcard:     ALL children of every match, then the
--     remaining components resolve under each of them.
--     Multiple wildcards fan out level by level; a trailing
--     '*' yields every child as a root. No names are ever
--     hardcoded here. Roots whose chain breaks contribute
--     nothing (no abort, no error).
local function _walkSegments(roots: { Instance }, segments: { string }): { Instance }
	local current: { Instance } = {}
	for _, root in ipairs(roots) do
		if typeof(root) == 'Instance' then
			current[#current + 1] = root
		end
	end
	for _, seg in ipairs(segments) do
		local next: { Instance } = {}
		if seg == '*' then
			for _, node in ipairs(current) do
				local children: { Instance } = {}
				pcall(function()
					children = (node :: Instance):GetChildren()
				end)
				for _, child in ipairs(children) do
					next[#next + 1] = child
				end
			end
		else
			for _, node in ipairs(current) do
				local child: Instance? = nil
				pcall(function()
					child = (node :: Instance):FindFirstChild(seg)
				end)
				if child ~= nil then
					next[#next + 1] = child :: Instance
				end
			end
		end
		current = next
		if #current == 0 then
			break
		end
	end
	return current
end

-- Base roots: EVERY direct child of the authoritative bases
-- container (Workspace.Map.Bases, legacy Workspace.Bases
-- fallback — same rule as StandResolver). Generic across
-- Base_1..Base_N with no name/number hardcoding: a base
-- missing the expected subtree simply resolves to nothing
-- for that target. `override` is the headless-test seam.
local function _baseRoots(override: { Instance }?): { Instance }
	if override ~= nil then
		return override
	end
	local roots: { Instance } = {}
	pcall(function()
		local map = Workspace:FindFirstChild('Map')
		local folder = map and map:FindFirstChild('Bases') or nil
		if folder == nil then
			folder = Workspace:FindFirstChild('Bases')
		end
		if folder ~= nil then
			for _, child in ipairs((folder :: Instance):GetChildren()) do
				roots[#roots + 1] = child
			end
		end
	end)
	return roots
end

-- Map root: Workspace.Map (override is the headless-test
-- seam; production always resolves live).
local function _mapRoot(override: Instance?): Instance?
	if override ~= nil then
		return override
	end
	local found: Instance? = nil
	pcall(function()
		found = Workspace:FindFirstChild('Map')
	end)
	return found
end

-- Collect every renderable BasePart under `root, INCLUDING
-- `root` itself. The single reusable traversal for all
-- targets: Part-roots (e.g. a lone Grass part) and
-- container-roots (Folders/Models around Paths) behave
-- identically, at any nesting depth. Never throws.
function EnvironmentModifier.CollectParts(root: Instance?): { BasePart }
	local out: { BasePart } = {}
	pcall(function()
		if typeof(root) ~= 'Instance' then
			return
		end
		local node = root :: Instance
		if node:IsA('BasePart') then
			out[#out + 1] = node
		end
		for _, desc in ipairs(node:GetDescendants()) do
			if desc:IsA('BasePart') then
				out[#out + 1] = desc
			end
		end
	end)
	return out
end

-- Resolve one configured target string to its ROOT instances
-- (NOT the parts — roots are expanded by CollectParts by the
-- caller). 'Map....' yields at most one root;
-- 'Base....' yields one root per base folder. Unknown scopes
-- and short paths yield {} (the caller warns once per target).
-- Never throws.
function EnvironmentModifier.ResolveRoots(target: string, opts: ResolveOptions?): { Instance }
	local roots: { Instance } = {}
	pcall(function()
		if type(target) ~= 'string' or target == '' then
			return
		end
		local segments = _splitPath(target)
		if #segments < 2 then
			return
		end
		local scope = segments[1]
		local rest: { string } = {}
		for i = 2, #segments do
			rest[#rest + 1] = segments[i]
		end
		if scope == 'Map' then
			local map = _mapRoot(opts and opts.mapRoot or nil)
			if map ~= nil then
				-- NOTE: the walk starts AT Workspace.Map, so
				-- rest drops the scope segment: 'Map' itself is
				-- the first root, NOT a looked-up child. (An
				-- earlier revision walked rest under Workspace
				-- and silently resolved every Map.* target to
				-- nothing — see the module history.)
				local walked = _walkSegments({ map }, rest)
				for _, node in ipairs(walked) do
					roots[#roots + 1] = node
				end
			end
		elseif scope == 'Base' then
			local bases = _baseRoots(opts and opts.baseRoots or nil)
			local walked = _walkSegments(bases, rest)
			for _, node in ipairs(walked) do
				roots[#roots + 1] = node
			end
		else
			Debug.Warn('EV', 'environment target has unknown scope (want Map/Base); skipped', { target = target })
		end
	end)
	return roots
end

-- Apply one event's Environment.Colors. `opts` overrides the
-- live roots (headless-test seam; production passes nil).
-- Returns a snapshot for Restore(). Deterministic: categories
-- apply in sorted key order; first write wins the snapshot,
-- last write wins the visual. Never throws.
function EnvironmentModifier.ApplyColors(colors: any, opts: ResolveOptions?): EnvSnapshot
	local snapshot: EnvSnapshot = { entries = {} }
	pcall(function()
		if type(colors) ~= 'table' then
			return
		end
		local saved: { [Instance]: boolean } = {}
		local categories: { string } = {}
		for name, _ in pairs(colors) do
			if type(name) == 'string' then
				categories[#categories + 1] = name
			end
		end
		table.sort(categories)
		for _, name in ipairs(categories) do
			local category: any = colors[name]
			if type(category) ~= 'table' then
				continue
			end
			local color: any = category.Color
			if typeof(color) ~= 'Color3' then
				Debug.Warn('EV', 'environment color category has no Color3; skipped', { category = name })
				continue
			end
			local targets: any = category.Targets
			if type(targets) ~= 'table' then
				continue
			end
			for _, target in ipairs(targets) do
				if type(target) ~= 'string' or target == '' then
					continue
				end
				local roots = EnvironmentModifier.ResolveRoots(target, opts)
				if #roots == 0 then
					Debug.Warn('EV', 'environment target resolved to nothing; skipped', { target = target })
					Debug.Log('EventEnvironment', ('Resolved target: %s'):format(target))
					Debug.Log('EventEnvironment', 'Root Class: <missing>')
					Debug.Log('EventEnvironment', 'Renderable parts found: 0')
					continue
				end
				local painted = 0
				for _, root in ipairs(roots) do
					local parts = EnvironmentModifier.CollectParts(root)
					Debug.Log('EventEnvironment', ('Resolved target: %s'):format(target))
										Debug.Log('EventEnvironment', ('Root Class: %s'):format(root.ClassName))
										Debug.Log('EventEnvironment', ('Renderable parts found: %d'):format(#parts))
					for _, part in ipairs(parts) do
						pcall(function()
							if not saved[part] then
								saved[part] = true
								snapshot.entries[#snapshot.entries + 1] =
									{ inst = part, color = part.Color, material = part.Material }
							end
							part.Color = color
						end)
						painted += 1
					end
				end
				if painted == 0 then
					Debug.Warn('EV', 'environment target has no renderable parts; skipped', { target = target })
				end
			end
		end
	end)
	return snapshot
end

-- Restore a snapshot from ApplyColors. Exact originals back,
-- missing/destroyed instances skipped. Idempotent: restores
-- once (entries cleared), second call is a no-op. Never throws.
function EnvironmentModifier.Restore(snapshot: EnvSnapshot?)
	pcall(function()
		if type(snapshot) ~= 'table' then
			return
		end
		local snap = snapshot :: EnvSnapshot
		if type(snap.entries) ~= 'table' then
			return
		end
		for _, entry in ipairs(snap.entries) do
			pcall(function()
				local raw: any = entry.inst
				if typeof(raw) == 'Instance' and raw.Parent ~= nil and raw:IsA('BasePart') then
					local part = raw :: BasePart
					part.Color = entry.color
					part.Material = entry.material
				end
			end)
		end
		table.clear(snap.entries)
	end)
end

-- TEST seam: count of paintable parts one target string would
-- hit (pure resolution, no writes). Overrides inject fake
-- roots so specs never touch the live Workspace.
function EnvironmentModifier._TestResolveCount(
	target: string,
	mapRootOverride: Instance?,
	baseRootsOverride: { Instance }?
): number
	local count = 0
	pcall(function()
		local roots =
			EnvironmentModifier.ResolveRoots(target, { mapRoot = mapRootOverride, baseRoots = baseRootsOverride })
		for _, root in ipairs(roots) do
			count += #EnvironmentModifier.CollectParts(root)
		end
	end)
	return count
end

return table.freeze(EnvironmentModifier)
