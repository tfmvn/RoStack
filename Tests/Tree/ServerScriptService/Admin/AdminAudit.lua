--!strict
--!native
--[[
	AdminAudit
	==========
	Server-side audit trail for every admin command execution.
	Two sinks:
	  1. Debug.Log('ADMIN', ...) — permanent Studio/output trail.
	  2. In-memory ring buffer (last 100) — readable live via the
	     /adminlog command. No persistence: audit history is
	     operational, never sensitive payload (amounts and counts
	     are logged; no profile internals).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)

local AdminAudit = {}

local _buffer: { string } = {}
local _maxEntries = 100
local _sequence = 0

local function _flatten(fields: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(fields) == 'table' then
		for k, v in pairs(fields) do
			if type(v) == 'table' then
				out[tostring(k)] = table.concat(v, ',')
			else
				out[tostring(k)] = tostring(v)
			end
		end
	end
	return out
end

-- Record one execution. success + message describe the outcome.
function AdminAudit.Log(executorUserId: number, command: string, fields: any?, success: boolean, message: string?)
	_sequence += 1
	local flat = _flatten(fields)
	flat.actor = tostring(executorUserId)
	flat.command = tostring(command)
	flat.success = if success then 'true' else 'false'
	if message ~= nil then
		flat.result = (string.sub(tostring(message), 1, 180))
	end
	pcall(Debug.Log, 'ADMIN', 'command', flat)
	local line = ('#%d actor=%s command=%s success=%s'):format(
		_sequence,
		tostring(executorUserId),
		tostring(command),
		if success then 'true' else 'false'
	)
	if message ~= nil then
		line ..= ' :: ' .. (string.sub(tostring(message), 1, 160))
	end
	_buffer[#_buffer + 1] = line
	if #_buffer > _maxEntries then
		table.remove(_buffer, 1)
	end
end

-- Newest-first snapshot for /adminlog.
function AdminAudit.Recent(count: number?): { string }
	local n = 10
	if type(count) == 'number' and count >= 1 then
		n = math.min(math.floor(count), _maxEntries)
	end
	local out: { string } = {}
	for i = #_buffer, math.max(1, #_buffer - n + 1), -1 do
		out[#out + 1] = _buffer[i]
	end
	return out
end

return table.freeze(AdminAudit)
