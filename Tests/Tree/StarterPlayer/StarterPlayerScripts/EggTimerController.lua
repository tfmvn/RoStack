--!strict
--!native
--[[
	EggTimerController
	====================
	Client presentation for the server-authoritative egg rarity
	guarantee timers. Node (shared CenterPartBillboards
	resolver — the Egg BillboardGui sibling is found by its
	`Egg` child marker, never positionally):
	  Map.CenterPart.BillboardGui.Egg with one label per
	  guaranteed rarity (Egg.Mythic, Egg.Legendary).
	LEGACY fallback: Map.EggTimer.BillboardGui.Frame.
	Label lookup is recursive by rarity name so both
	structures paint identically.

	This controller NEVER touches the sibling Event
	BillboardGui (Map.CenterPart.BillboardGui.Event.TextLabel)
	— that belongs to EventController.

	Authority model (display-only client):
	  Server (SpawnService) writes two attributes per enabled
	  guarantee on the Frame (BillboardGui fallback):
	    Guarantee_<Rarity>_NextAt  (absolute server timestamp)
	    Guarantee_<Rarity>_Interval (integer total seconds)
	  ...only when they CHANGE (boot, every center spawn that
	  resets a timer). Zero remote traffic, zero per-second
	  pushes. Attributes replicate + persist, so late joiners
	  read current values.

	  This controller snapshots (nextAt, interval) on every
	  attribute change and repaints at 4Hz from the shared
	  server clock:
	    remaining = max(0, nextAt - workspace:GetServerTimeNow())

	A rarity with no guarantee configuration (or Enabled =
	false) has its label hidden — a disabled system must not
	show a live-looking countdown. Nothing is destroyed; the
	Studio objects stay exactly as authored.

	The client NEVER decides due/spawn/reset — it only renders
	the countdown. Four explicitly colored segments: static
	words WHITE, rarity word in the canonical
	RarityConfig.RarityColor, timer lerping the configured
	EggConfig.GuaranteeTimerUI StartColor (far) -> EndColor
	(due) by elapsed fraction. MM:SS (H:MM:SS past the hour),
	clamped at 00:00, never negative.

	All Studio lookups are defensive and non-blocking: a
	missing EggTimer degrades to a warn + a ChildAdded re-try,
	never an error, never a boot block.
]]

local Workspace = game:GetService('Workspace')
local RunService = game:GetService('RunService')

local EggConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Eggs)
local RarityConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Rarity)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local CenterPartBillboards = require(game:GetService('ReplicatedStorage').Utility.CenterPartBillboards)

local EggTimerController = {}

local REPAINT_INTERVAL = 0.25

local _resolved = false
local _node: Instance? = nil -- Frame (or BillboardGui fallback): attribute source
local _labels: { [string]: TextLabel } = {} -- rarity -> label
local _snap: { [string]: { nextAt: number, interval: number } } = {}
local _rev = 0 -- highest guarantee revision applied (out-of-order guard)
local _accum = 0
local _conn: RBXScriptConnection? = nil
local _warned: { [string]: boolean } = {}

local function _warnOnce(key: string, message: string)
	if _warned[key] then
		return
	end
	_warned[key] = true
	Debug.Warn('EG', message, {})
end

local function _attrBase(rarity: string): string
	return 'Guarantee_' .. tostring(rarity)
end

local function _snapshotRarity(rarity: string)
	if _node == nil then
		return
	end
	pcall(function()
		local node = _node :: Instance
		local nextAt = node:GetAttribute(_attrBase(rarity) .. '_NextAt')
		local interval = node:GetAttribute(_attrBase(rarity) .. '_Interval')
		if type(nextAt) ~= 'number' or type(interval) ~= 'number' then
			return
		end
		-- Out-of-order protection: the server bumps a shared
		-- revision on every reset; an older snapshot must never
		-- overwrite newer state (join bursts, attribute replays).
		local rev = node:GetAttribute(_attrBase(rarity) .. '_Revision')
		if type(rev) == 'number' then
			if rev < _rev then
				return
			end
			_rev = math.max(_rev, math.floor(rev))
		end
		_snap[rarity] = {
			nextAt = nextAt,
			interval = math.max(1, math.floor(interval)),
		}
	end)
end

local function _toHex(color: Color3): string
	local r = math.clamp(math.floor(color.R * 255 + 0.5), 0, 255)
	local g = math.clamp(math.floor(color.G * 255 + 0.5), 0, 255)
	local b = math.clamp(math.floor(color.B * 255 + 0.5), 0, 255)
	return string.format('#%02X%02X%02X', r, g, b)
end

local function _formatTime(totalSeconds: number): string
	local s = math.max(0, math.floor(totalSeconds or 0))
	local hours = math.floor(s / 3600)
	local mins = math.floor((s % 3600) / 60)
	local secs = s % 60
	if hours > 0 then
		return string.format('%d:%02d:%02d', hours, mins, secs)
	end
	return string.format('%02d:%02d', mins, secs)
end

-- Pure text builder (TEST seam): every static word is WHITE,
-- ONLY the rarity word carries the canonical rarity color and
-- ONLY the timer carries the urgency ramp. TextColor3 stays
-- white underneath so a non-RichText label degrades to
-- all-white (never a fully rarity/timer-colored label).
function EggTimerController._TestFormat(rarity: string, rarityHex: string, timerHex: string, timeText: string): string
	return 'Guaranteed <font color="'
		.. tostring(rarityHex)
		.. '">'
		.. tostring(rarity)
		.. '</font> in: <font color="'
		.. tostring(timerHex)
		.. '">'
		.. tostring(timeText)
		.. '</font>'
end

local function _findLabel(frame: Instance, rarity: string): TextLabel?
	local found: TextLabel? = nil
	pcall(function()
		local direct = (frame :: Instance):FindFirstChild(rarity)
		if direct ~= nil and direct:IsA('TextLabel') then
			found = direct
		else
			for _, desc in ipairs((frame :: Instance):GetDescendants()) do
				if desc.Name == rarity and desc:IsA('TextLabel') then
					found = desc
					break
				end
			end
		end
	end)
	return found
end

local function _repaint()
	if _node == nil then
		return
	end
	-- Shared server clock (same source the server stamps
	-- NextAt with): lag on either side can't drift the
	-- countdown, which is derived, never decremented.
	local serverNow: number? = nil
	pcall(function()
		serverNow = Workspace:GetServerTimeNow()
	end)
	if type(serverNow) ~= 'number' then
		serverNow = os.time()
	end
	local ui = EggConfig.GuaranteeTimerUI
	-- No guarantee UI config (e.g. the spawn-guarantee system
	-- is not present in this build): leave authored text alone.
	if type(ui) ~= 'table' then
		return
	end
	local farColor: Color3 = ui.StartColor
	local nearColor: Color3 = ui.EndColor
	for rarity, label in pairs(_labels) do
		local snap = _snap[rarity]
		if snap == nil then
			-- No authoritative state yet (server push
			-- pending): leave the authored text alone rather
			-- than inventing a countdown.
			continue
		end
		if (label :: TextLabel).Parent == nil then
			_labels[rarity] = nil
		else
			pcall(function()
				-- Clamped at 00:00, never negative. Due shows
				-- full green until the server's actual spawn
				-- pushes a fresh NextAt — the client never
				-- resets locally.
				local remaining = math.max(0, snap.nextAt - (serverNow :: number))
				local frac = 1 - math.clamp(remaining / snap.interval, 0, 1)
				local rarityColor: Color3? = nil
				pcall(function()
					rarityColor = RarityConfig.RarityColor[rarity]
				end)
				if typeof(rarityColor) ~= 'Color3' then
					rarityColor = Color3.new(1, 1, 1)
				end
				local target = label :: TextLabel
				-- Four explicitly colored segments (white /
				-- rarity / white / timer ramp). TextColor3 stays
				-- white so only the two font tags ever carry
				-- color. RichText attempted — a non-rich label
				-- degrades to all-white, never single-colored.
				pcall(function()
					target.RichText = true
				end)
				target.TextColor3 = Color3.new(1, 1, 1)
				target.Text = EggTimerController._TestFormat(
					rarity,
					_toHex(rarityColor :: Color3),
					_toHex((farColor :: Color3):Lerp(nearColor, frac)),
					_formatTime(remaining)
				)
			end)
		end
	end
end

local function _subscribe(node: Instance)
	local list = EggConfig.Guarantees
	-- No guarantees configured: nothing to subscribe (the
	-- Studio labels keep their authored text).
	if type(list) ~= 'table' then
		return
	end
	for _, g in ipairs(list) do
		if type(g) == 'table' and type(g.Rarity) == 'string' then
			local rarity = g.Rarity
			_snapshotRarity(rarity)
			-- NextAt is the live edge (rewritten on every
			-- reset); Interval is static config, snapshotted
			-- once above.
			pcall(function()
				(node :: Instance):GetAttributeChangedSignal(_attrBase(rarity) .. '_NextAt'):Connect(function()
					_snapshotRarity(rarity)
				end)
			end)
		end
	end
end

local function _resolveLabels(frame: Instance)
	local list = EggConfig.Guarantees
	if type(list) ~= 'table' then
		return
	end
	for _, g in ipairs(list) do
		if type(g) == 'table' and type(g.Rarity) == 'string' then
			local label = _findLabel(frame, g.Rarity)
			if label == nil then
				continue
			end
			if g.Enabled == true then
				_labels[g.Rarity] = label
			else
				-- Disabled guarantee: hide the label (Visible
				-- only — the Studio object stays exactly as
				-- authored). A disabled system must not show
				-- a live-looking countdown.
				pcall(function()
					(label :: TextLabel).Visible = false
				end)
			end
		end
	end
end

-- Resolve the Studio asset once (non-blocking, spawned by
-- Init). The node comes from the shared CenterPartBillboards
-- resolver (Egg BillboardGui sibling by `Egg` child marker,
-- legacy EggTimer fallback). Missing nodes degrade to a warn
-- + a ChildAdded re-try — the timer appears late rather than
-- never.
local function _resolve()
	local map: Instance? = nil
	pcall(function()
		map = Workspace:WaitForChild('Map', 10)
	end)
	if map == nil then
		_warnOnce('no-map', '[EggTimer] Workspace.Map missing; guarantee timers unavailable')
		return false
	end
	-- CenterPart first (the Egg BillboardGui lives under it);
	-- the resolver itself never waits, so give streaming a
	-- bounded chance before falling back to legacy/ retry.
	pcall(function()
		(map :: Instance):WaitForChild('CenterPart', 10)
	end)
	local node: Instance? = nil
	pcall(function()
		node = CenterPartBillboards.FindEggTimerNode(map)
	end)
	if node == nil then
		-- One bounded legacy wait before giving up for now
		-- (dev places predating CenterPart stream EggTimer).
		pcall(function()
			(map :: Instance):WaitForChild('EggTimer', 5)
			node = CenterPartBillboards.FindEggTimerNode(map)
		end)
	end
	if node == nil then
		_warnOnce(
			'no-timer',
			'[EggTimer] Map.CenterPart.BillboardGui.Egg and legacy Map.EggTimer missing; guarantee timers unavailable'
		)
		pcall(function()
			(map :: Instance).ChildAdded:Connect(function(child: Instance)
				if (child.Name == 'EggTimer' or child.Name == 'CenterPart') and not _resolved then
					task.spawn(function()
						if _resolve() then
							_repaint()
						end
					end)
				end
			end)
		end)
		return false
	end
	_node = node
	_resolveLabels(node)
	_subscribe(_node :: Instance)
	_resolved = true
	return true
end

function EggTimerController.Init()
	if _conn ~= nil then
		return
	end
	-- Resolve Studio content without blocking boot; repaint on
	-- a throttled Heartbeat (4Hz for two labels is plenty —
	-- the text only changes once per second anyway).
	task.spawn(function()
		pcall(_resolve)
	end)
	_conn = RunService.Heartbeat:Connect(function(dt: number)
		_accum += dt
		-- Throttled repaint: the text changes once per second
		-- and there are two labels — no reason to repaint
		-- every frame.
		if _accum < REPAINT_INTERVAL then
			return
		end
		_accum = 0
		pcall(_repaint)
	end)
	Debug.Log('EG', 'EggTimerController started', {})
end

return table.freeze(EggTimerController)
