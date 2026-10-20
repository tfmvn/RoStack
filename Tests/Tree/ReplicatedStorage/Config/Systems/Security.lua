--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	Single source of truth for its domain. New code must require this path.
	Values preserved exactly from the pre-migration configs - do NOT rebalance
	without a gameplay review. See Docs/configuration/ for domain docs.
]]
-- Security: server-enforced rate limits, caps, and budgets.
-- SERVER-AUTHORITATIVE: services READ these values; replication to
-- clients is visibility only and weakens nothing (limits enforce on server).
-- Values moved verbatim from AdminRateLimit / ShopService / DoorService /
-- Placement / SlotMenuService / DebugService. Tune deliberately.
local Security = {}

-- Admin command sliding window (former AdminRateLimit locals).
Security.Admin = {
	WindowSeconds = 10,
	MaxPerWindow = 30,
	MinGapSeconds = 0.2,
}

-- Marketplace receipt handling (former ShopService locals).
Security.Receipts = {
	SeenCap = 5000,
	ActionCooldownSeconds = 5,
}

-- Locked-base door flow (former DoorService locals).
Security.Door = {
	RequestCooldownSeconds = 5,
	RangeSlackStuds = 2,
}

-- Center-egg placement search (former Placement locals).
Security.Placement = {
	MaxRandomAttempts = 20,
	MaxSpiralRadiusMult = 2,
}

-- Shared snapshot/menu request throttle (former SlotMenuService + DebugService).
Security.RequestThrottleSeconds = 0.5

function Security.Validate(): { string }
	local issues: { string } = {}
	local function pos(path: string, v: any)
		if type(v) ~= 'number' or v <= 0 then
			issues[#issues + 1] = path .. ' must be a number > 0'
		end
	end
	pos('Admin.WindowSeconds', Security.Admin.WindowSeconds)
	pos('Admin.MaxPerWindow', Security.Admin.MaxPerWindow)
	pos('Receipts.SeenCap', Security.Receipts.SeenCap)
	pos('Receipts.ActionCooldownSeconds', Security.Receipts.ActionCooldownSeconds)
	pos('Door.RequestCooldownSeconds', Security.Door.RequestCooldownSeconds)
	pos('Placement.MaxRandomAttempts', Security.Placement.MaxRandomAttempts)
	pos('RequestThrottleSeconds', Security.RequestThrottleSeconds)
	return issues
end

return table.freeze(Security)
