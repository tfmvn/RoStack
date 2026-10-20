--!strict
--[[
	ArenaUIState
	============
	Shared client-only coordination for the Arena screens. The Start
	menu (ArenaController) and the result panel
	(ArenaResultController) are owned by separate controllers, but
	the lifecycle rule "ArenaResult wins over ArenaStart" needs one
	authoritative answer both can read WITHOUT inferring game state
	from UI visibility.

	Single flag: whether the result panel is currently open (plus
	which session it shows). The result controller sets it on open
	and clears it on every close path; the menu controller reads it
	before opening the Start menu. No remotes, no combat data, no
	rewards — presentation coordination only.
]]

local ArenaUIState = {}

local resultOpen = false
local resultSession: string? = nil

-- Called ONLY by ArenaResultController: openFromPayload (true) and
-- close() (false — every terminal path funnels through close, so
-- the flag can never stick).
function ArenaUIState.SetResultOpen(open: boolean, session: string?)
	if open then
		resultOpen = true
		resultSession = session
	else
		resultOpen = false
		resultSession = nil
	end
end

function ArenaUIState.IsResultOpen(): boolean
	return resultOpen
end

function ArenaUIState.ResultSession(): string?
	return resultSession
end

function ArenaUIState._TestReset()
	resultOpen = false
	resultSession = nil
end

return table.freeze(ArenaUIState)
