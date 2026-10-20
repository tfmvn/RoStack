--!strict
--!native
--[[
	MutationIcon
	============
	Shared server-only resolver for mutation overhead icons.
	The ONE canonical mapping of mutation id -> decal asset:

	  Galactic -> Assets.Decals.GalaxyIcon
	  Frost    -> Assets.Decals.SnowfallIcon

	The decal config is read fresh on every call from
	ServerStorage first, ReplicatedStorage fallback — each
	expected to be an ImageLabel with a populated Image (same
	contract as MoneyIcon). Fresh-per-paint means retargeting
	a decal Image in Studio takes effect on the next paint
	with no code changes. Warn-once when missing (the caller
	keeps the prototype's authored visuals).

	Single implementation used by EggOverhead + AnimalOverhead
	— not two copies. Painting applies ONLY to freshly cloned
	generic icons: a Studio-authored per-id icon child (a
	`Galactic`/`Frost` node already living in the template's
	Mutations container) is never touched, so authored art
	always wins and the decal mapping is the fallback that
	makes the icon correct even when the template was never
	customized per mutation.
]]

local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)

local MutationIcon = {}

-- Canonical mutation -> decal asset name. Unknown ids map to
-- nil (no invented assets, no crash).
local DECAL_BY_MUTATION: { [string]: string } = {
	Galactic = 'GalaxyIcon',
	Frost = 'SnowfallIcon',
}

function MutationIcon.DecalNameFor(mutationId: any): string?
	if type(mutationId) ~= 'string' then
		return nil
	end
	return DECAL_BY_MUTATION[mutationId]
end

local _warnedMissing: { [string]: boolean } = {}

-- Resolve the decal Image string for a mutation id (or nil
-- when the id is unmapped or the asset is absent/unpopulated).
-- Never throws.
function MutationIcon.ResolveImage(mutationId: any): string?
	local image: string? = nil
	pcall(function()
		local decalName = MutationIcon.DecalNameFor(mutationId)
		if decalName == nil then
			return
		end
		local containers: { Instance } = {}
		local ss = game:GetService('ServerStorage'):FindFirstChild('Assets')
		if ss then
			containers[#containers + 1] = ss
		end
		local rs = game:GetService('ReplicatedStorage'):FindFirstChild('Assets')
		if rs then
			containers[#containers + 1] = rs
		end
		for _, assets in ipairs(containers) do
			local decals = assets:FindFirstChild('Decals')
			local icon = decals and decals:FindFirstChild(decalName :: string) or nil
			if icon and icon:IsA('ImageLabel') then
				local candidate = (icon :: ImageLabel).Image
				if type(candidate) == 'string' and candidate ~= '' then
					image = candidate
					break
				end
			end
		end
	end)
	if image == nil then
		local key = tostring(mutationId)
		if not _warnedMissing[key] then
			_warnedMissing[key] = true
			Debug.Warn('MI', 'mutation decal missing/unpopulated — overhead keeps prototype visuals', {
				mutation = key,
			})
		end
	end
	return image
end

-- Paint a freshly cloned generic mutation icon with the
-- canonical decal for `mutationId`. Host may be the ImageLabel
-- itself or a container holding one (first descendant wins).
-- Returns true when an Image was applied. Never throws. No-op
-- (false) when unmapped or asset missing — the caller keeps
-- the prototype's authored visuals.
function MutationIcon.PaintIcon(host: Instance?, mutationId: any): boolean
	local painted = false
	pcall(function()
		if typeof(host) ~= 'Instance' then
			return
		end
		local image = MutationIcon.ResolveImage(mutationId)
		if image == nil then
			return
		end
		local target: ImageLabel? = nil
		if (host :: Instance):IsA('ImageLabel') then
			target = host :: ImageLabel
		else
			local deep = (host :: Instance):FindFirstChildWhichIsA('ImageLabel', true)
			if deep ~= nil then
				target = deep
			end
		end
		if target ~= nil then
			(target :: ImageLabel).Image = image :: string
			painted = true
		end
	end)
	return painted
end

return table.freeze(MutationIcon)
