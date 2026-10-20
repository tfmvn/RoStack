--!strict
--!native
--[[
	AdminRateLimit
	==============
	Server-side sliding-window throttle for admin commands.
	Prevents accidental machine-gun execution (e.g. pasting
	"/giveegg all ..." on repeat) from melting slot state.

	Budget: 30 executions per 10-second window per admin, with a
	5-per-second burst cap. Normal interactive use never touches
	it; only runaway loops do. Exceeding it fails THAT execution
	with a plain message (no punishment, no lockout).

	Called AFTER the permission gate so rejected non-admins never
	consume budget and never learn limits exist.

	Budget lives in Systems.Security (Security.Admin): window / max /
	burst-gap below read the config as the single source of truth.
]]

local Security = require(game:GetService('ReplicatedStorage').Config.Systems.Security)

local AdminRateLimit = {}

local _windowSeconds = Security.Admin.WindowSeconds
local _maxPerWindow = Security.Admin.MaxPerWindow
local _minGapSeconds = Security.Admin.MinGapSeconds

local _stamps: { [number]: { number } } = {}

-- Returns (true) when the execution may proceed, or
-- (false, message) when this execution must be dropped.
function AdminRateLimit.Check(userId: number): (boolean, string?)
	if type(userId) ~= 'number' then
		return false, 'Rate limiter: invalid caller.'
	end
	local now = os.clock()
	local stamps = _stamps[userId]
	if stamps == nil then
		stamps = {}
		_stamps[userId] = stamps
	end
	-- Evict expired stamps (in place, from the back).
	for i = #stamps, 1, -1 do
		if now - stamps[i] > _windowSeconds then
			table.remove(stamps, i)
		end
	end
	if #stamps >= 1 and now - stamps[#stamps] < _minGapSeconds then
		return false, 'Slow down: admin commands are rate limited (burst).'
	end
	if #stamps >= _maxPerWindow then
		return false, ('Slow down: admin commands are rate limited (%d per %ds).'):format(
			_maxPerWindow,
			_windowSeconds
		)
	end
	stamps[#stamps + 1] = now
	return true, nil
end

function AdminRateLimit._TestReset()
	table.clear(_stamps)
end

return table.freeze(AdminRateLimit)
