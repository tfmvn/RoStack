--!strict
--!native
--[[
	MoneyIcon
	=========
	Shared server-only resolver for the MoneyIcon visual config
	used by the HUD cash-pooling effect. The config is read
	fresh on every call from Assets.Decals.MoneyIcon —
	ServerStorage first, ReplicatedStorage fallback — which is
	expected to be an ImageLabel. The config table travels in
	the CashCollected payload so the client never hardcodes an
	asset id and never reads a server-only container
	(LocalScripts cannot touch ServerStorage). Fresh-per-grant
	means retargeting MoneyIcon.Image in Studio takes effect
	on the next grant with no code changes. Warn-once when
	missing (the client falls back to a "$" chip). Only
	ImageLabel sources are honored — anything else is treated
	as missing.

	Single implementation used by IncomeService (collects),
	CodesService, and DailyRewardsService — not three copies.
]]

local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)

local MoneyIcon = {}

local warnedMissingIcon = false

function MoneyIcon.Resolve(): { [string]: any }?
	local found: { [string]: any }? = nil
	pcall(function()
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
			local icon = decals and decals:FindFirstChild('MoneyIcon') or nil
			if icon and icon:IsA('ImageLabel') then
				local label = icon :: ImageLabel
				local image = label.Image
				if type(image) == 'string' and image ~= '' then
					local cfg: { [string]: any } = { Image = image }
					pcall(function()
						cfg.RectOffset = { label.ImageRectOffset.X, label.ImageRectOffset.Y }
					end)
					pcall(function()
						cfg.RectSize = { label.ImageRectSize.X, label.ImageRectSize.Y }
					end)
					pcall(function()
						cfg.ScaleType = label.ScaleType.Name
					end)
					pcall(function()
						local sc = label.SliceCenter
						cfg.SliceCenter = { sc.Min.X, sc.Min.Y, sc.Max.X, sc.Max.Y }
					end)
					pcall(function()
						cfg.SliceScale = label.SliceScale
					end)
					pcall(function()
						local c = label.ImageColor3
						cfg.Color = { c.R, c.G, c.B }
					end)
					pcall(function()
						cfg.Transparency = label.ImageTransparency
					end)
					pcall(function()
						cfg.BgTransparency = label.BackgroundTransparency
					end)
					found = cfg
					break
				end
			end
		end
	end)
	if found == nil and not warnedMissingIcon then
		warnedMissingIcon = true
		Debug.Warn(
			'IN',
			'Assets.Decals.MoneyIcon ImageLabel missing/unpopulated — HUD pooling uses fallback chip',
			{}
		)
	end
	return found
end

return table.freeze(MoneyIcon)
