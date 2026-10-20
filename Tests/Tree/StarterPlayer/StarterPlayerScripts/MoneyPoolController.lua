--!strict
--!native
--[[
	MoneyPoolController
	===================
	Client-side accumulative cash-pool HUD. Presentation ONLY:
	server-authoritative money is the single source of truth;
	this controller never awards, computes, or trusts amounts.

	ONE persistent pooling state (never one animation per
	event, never a restart per collection):
	  * pool    — visual cash awaiting/in-flight icons
	    (BigNumber string, exact Add/Subtract only).
	  * target  — latest authoritative wallet
	    (CashCollected.NewMoney, corrected by each
	    PlayerState.Money push).
	  * visual  — currently displayed value (BigNumber
	    string). Monotonic during collection; ends EXACTLY
	    on target.

	Every CashCollected { Amount, NewMoney } (fired ONLY on
	the committed server claim branch, for this player
	only): pool += Amount, target = NewMoney (when present),
	pump icons while pool > 0 and capacity allows. Icons are
	visual chunks: each spawned icon carries an exact share
	(Divide + remainder to the first, Multiply/Subtract —
	all BigNumber, no floats), deducted from the pool at
	spawn; arrivals destroy + bop + pump again (backlog
	drains as capacity frees). New events never restart the
	stream — they join it. When pool == 0, no icons fly, and
	visual == target, the pool logs drained and idles.

	The number climbs on ONE generation-guarded thread that
	restarts from the CURRENT visual toward the NEWEST
	target (Add + MultiplyDecimal fractions, formatted with
	the project's BigNumber.Format). Spends (target <
	visual) snap exact and clear the pool.

	Icons: tiered burst (6–24, never linear in amount)
	using the server-supplied MoneyIcon visual config (the
	Studio ImageLabel's Image + Rect/ScaleType/Slice/Color/
	Transparency, rebuilt only when its Image changes —
	never a hardcoded id; "$" chip fallback), global
	ACTIVE_ICON_CAP as a concurrency limit only. Icons
	burst FROM the collection button (payload world origin
	projected to screen, clamped; center fallback) with
	full BackgroundTransparency, then fly on ONE central
	Heartbeat loop (created on first icon, disconnected
	when empty — zero per-icon tweens/threads/connections):
	DISTRIBUTED radial burst (N angular sectors, one icon
	per sector with jitter — never a ±14px clump) then a
	quadratic bezier per icon with its OWN control point
	(outward flick 55–120px + perpendicular jitter, so
	trajectories fan apart) → accelerating suck-in to the
	counter center. Durations stagger 0.34–0.53s so arrivals
	stream instead of landing as one blob; sizes vary
	0.75–1.3x with random start rotation and visible spin.
	A rotating burstPhase keeps repeated/spam collections
	from stacking into the same pattern. Shrink over the
	last 20%, fade over the last 15%, absorbed exactly at
	the counter center. Bop strength accumulates with
	arrival density (single shared UIScale tween,
	cancel-restart — arrivals group into one pulse,
	canonical scale restored). NO visual queue: the pool is
	an AMOUNT accumulator cleared at spawn (icons are pure
	visuals after that — arrivals never re-deduct).

	Lifecycle: CashCollected connects EXACTLY ONCE (stored
	connection, Disconnect on cleanup — never invoked).
	Init never blocks on GUI: the counter/overlay resolve
	lazily per use (PlayerGui.HUD.MoneyCounter — the runtime
	instance, never the StarterGui template). CharacterAdded
	cancels threads, destroys live icons, clears tables.
	Pre-Init events are not replayed (engine drops them);
	the first PlayerState snaps visual = target, so money
	is always right and future events are never missed.
]]

local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local TweenService = game:GetService('TweenService')
local Workspace = game:GetService('Workspace')

local Remotes = require(game:GetService('ReplicatedStorage').Utility.Remotes)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local BaseConfig = require(game:GetService('ReplicatedStorage').Config.World.Bases)
local BigNumber = require(game:GetService('ReplicatedStorage').Utility.BigNumber)
local HudTree = require(script.Parent.HudTree)

local MoneyPoolController = {}

local localPlayer = Players.LocalPlayer
assert(localPlayer, 'MoneyPoolController must run on the client')

-- --- Tuning (feel only) --------------------------------------------
-- Canonical source: BaseConfig.MoneyPool. Values preserved exactly.

local MP = BaseConfig.MoneyPool
local ICON_BASE_PX = MP.IconBasePx
local ICON_MIN = MP.IconMin
local ICON_TIER2 = MP.IconTier2
local ICON_TIER3 = MP.IconTier3
local ICON_MAX = MP.IconMax
local ACTIVE_ICON_CAP = MP.ActiveIconCap
local NUMBER_STEPS = MP.NumberSteps
local NUMBER_SECONDS = MP.NumberSeconds
local BOP_CHILD_NAME = 'MoneyPoolBop'
local BOP_UP_SECONDS = MP.BopUpSeconds
local BOP_DOWN_SECONDS = MP.BopDownSeconds

-- --- Pool state (the ONE controller) ---------------------------------

local pool = '0'
local target = '0'
local visual = '0'
local hasVisual = false
local settledIdle = true

local numberGen = 0
local bopGen = 0
local bopTween: Tween? = nil
local arrivalStamps: { number } = {}

-- icon -> exact BigNumber share it represents.
local activeIcons: { [GuiObject]: string } = {}

local overlay: ScreenGui? = nil
local iconTemplate: GuiObject? = nil

local cashConn: RBXScriptConnection? = nil
local stateConn: RBXScriptConnection? = nil

local warnedNoOverlay = false

-- Forward declarations (stream functions reference each
-- other; Lua resolves locals lexically).
local _maybeSettled: () -> ()
local _destroyIcon: (GuiObject) -> ()
local _onIconSettled: (string?) -> ()
local _pump: () -> ()
local _kickNumber: () -> ()

-- Breadcrumb logger, routed through the central Debug module
-- (visible with ClientDebug on, silent otherwise).
local function _log(...: any)
	local parts: { string } = {}
	for _, v in ipairs({ ... }) do
		parts[#parts + 1] = tostring(v)
	end
	Debug.Log('MoneyPool', table.concat(parts, ' '))
end

-- --- Counter resolution (lazy runtime instance) -----------------------

local function _findCounter(): TextLabel?
	local playerGui = localPlayer:FindFirstChildOfClass('PlayerGui')
	if playerGui == nil then
		return nil
	end
	-- Canonical Studio path HUD.BottomLeft.MoneyCounter(.Text);
	-- legacy flat HUD.MoneyCounter accepted as fallback.
	return HudTree.MoneyText(playerGui)
end

local function _paintCounter(counter: TextLabel, value: string)
	local safe = BigNumber.sanitize(value) or '0'
	-- The BottomLeft chain must be up or the paint is invisible.
	HudTree.EnsureChainVisible(counter)
	counter.Text = '$' .. BigNumber.Format(safe)
end

-- --- Overlay + icon template ------------------------------------------

local function _ensureOverlay(): ScreenGui?
	if overlay ~= nil and overlay.Parent ~= nil then
		return overlay
	end
	overlay = nil
	pcall(function()
		local playerGui = localPlayer:FindFirstChildOfClass('PlayerGui')
		if not playerGui then
			return
		end
		local gui = Instance.new('ScreenGui')
		gui.Name = 'MoneyPoolOverlay'
		gui.ResetOnSpawn = true
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 50
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = playerGui
		overlay = gui
	end)
	if overlay == nil and not warnedNoOverlay then
		warnedNoOverlay = true
		_log('overlay unavailable (no PlayerGui); bursts skipped')
	end
	return overlay
end

-- Template source: the latest server-supplied MoneyIcon
-- visual config (read from the Studio ImageLabel every
-- claim — retargeting its Image needs no code changes).
-- The template rebuilds whenever the config Image changes;
-- Size/Position/Rotation/AnchorPoint always stay
-- animation-owned and are never copied from the source.
local latestIconCfg: { [string]: any }? = nil
local templateKey = ''

local function _configKey(cfg: { [string]: any }?): string
	if type(cfg) ~= 'table' then
		return 'chip'
	end
	local image = cfg.Image
	if type(image) ~= 'string' or image == '' then
		return 'chip'
	end
	return 'img:' .. image
end

local function _numList(v: any, n: number): { number }?
	if type(v) ~= 'table' then
		return nil
	end
	local out: { number } = {}
	for i = 1, n do
		local x = (v :: { any })[i]
		if type(x) ~= 'number' or x ~= x then
			return nil
		end
		out[#out + 1] = x
	end
	return out
end

local function _applyIconConfig(img: ImageLabel, cfg: { [string]: any })
	pcall(function()
		img.Image = cfg.Image
	end)
	local rectOffset = _numList(cfg.RectOffset, 2)
	if rectOffset then
		pcall(function()
			img.ImageRectOffset = Vector2.new(rectOffset[1], rectOffset[2])
		end)
	end
	local rectSize = _numList(cfg.RectSize, 2)
	if rectSize then
		pcall(function()
			img.ImageRectSize = Vector2.new(rectSize[1], rectSize[2])
		end)
	end
	if type(cfg.ScaleType) == 'string' then
		pcall(function()
			local enumValue = (Enum.ScaleType :: any)[cfg.ScaleType]
			if enumValue ~= nil then
				img.ScaleType = enumValue
			end
		end)
	end
	local slice = _numList(cfg.SliceCenter, 4)
	if slice then
		pcall(function()
			img.SliceCenter = Rect.new(slice[1], slice[2], slice[3], slice[4])
		end)
	end
	if type(cfg.SliceScale) == 'number' and (cfg.SliceScale :: number) == (cfg.SliceScale :: number) then
		pcall(function()
			img.SliceScale = cfg.SliceScale
		end)
	end
	local color = _numList(cfg.Color, 3)
	if color then
		pcall(function()
			img.ImageColor3 = Color3.new(color[1], color[2], color[3])
		end)
	end
	if type(cfg.Transparency) == 'number' and (cfg.Transparency :: number) == (cfg.Transparency :: number) then
		pcall(function()
			img.ImageTransparency = cfg.Transparency
		end)
	end
	if type(cfg.BgTransparency) == 'number' and (cfg.BgTransparency :: number) == (cfg.BgTransparency :: number) then
		pcall(function()
			img.BackgroundTransparency = cfg.BgTransparency
		end)
	end
end

local function _ensureTemplate(): GuiObject?
	local key = _configKey(latestIconCfg)
	if iconTemplate ~= nil and templateKey == key then
		return iconTemplate
	end
	iconTemplate = nil
	templateKey = key
	local template: GuiObject? = nil
	pcall(function()
		if key ~= 'chip' and type(latestIconCfg) == 'table' then
			local img = Instance.new('ImageLabel')
			img.Name = 'MoneyIcon'
			img.BackgroundTransparency = 1
			img.BorderSizePixel = 0
			_applyIconConfig(img, latestIconCfg :: { [string]: any })
			template = img
		else
			local chip = Instance.new('TextLabel')
			chip.Name = 'MoneyChip'
			chip.Text = '$'
			chip.Font = BaseConfig.Collector.PoolChip.Font
			chip.TextSize = BaseConfig.Collector.PoolChip.TextSize
			chip.TextColor3 = BaseConfig.Collector.PoolChip.TextColor
			chip.BackgroundColor3 = BaseConfig.Collector.PoolChip.Background
			chip.BorderSizePixel = 0
			template = chip
		end
	end)
	iconTemplate = template
	return iconTemplate
end

-- --- Counter bop (single shared tween, density-weighted) ----------------

local function _pulseCounter(counter: TextLabel)
	local now = os.clock()
	local fresh: { number } = {}
	for _, t in ipairs(arrivalStamps) do
		if now - t < MP.ArrivalWindow then
			fresh[#fresh + 1] = t
		end
	end
	fresh[#fresh + 1] = now
	arrivalStamps = fresh
	local peak = MP.BopPeak
	if #fresh >= MP.DenseThreshold then
		peak = MP.BopPeakDense
	end
	bopGen += 1
	local mine = bopGen
	pcall(function()
		local child = counter:FindFirstChild(BOP_CHILD_NAME)
		local scale: UIScale? = nil
		if child and child:IsA('UIScale') then
			scale = child
		else
			local made = Instance.new('UIScale')
			made.Name = BOP_CHILD_NAME
			made.Scale = 1
			made.Parent = counter
			scale = made
		end
		local host = scale :: UIScale
		if bopTween then
			local old = bopTween :: Tween
			bopTween = nil
			old:Cancel()
		end
		local upTween = TweenService:Create(
			host,
			TweenInfo.new(BOP_UP_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = peak }
		)
		bopTween = upTween
		local upConn: RBXScriptConnection? = nil
		upConn = upTween.Completed:Connect(function(upState: Enum.PlaybackState)
			local c = upConn
			upConn = nil
			if c then
				c:Disconnect()
			end
			if upState ~= Enum.PlaybackState.Completed or bopGen ~= mine then
				return
			end
			local downTween = TweenService:Create(
				host,
				TweenInfo.new(BOP_DOWN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
				{ Scale = 1 }
			)
			bopTween = downTween
			local downConn: RBXScriptConnection? = nil
			downConn = downTween.Completed:Connect(function(downState: Enum.PlaybackState)
				local d = downConn
				downConn = nil
				if d then
					d:Disconnect()
				end
				if downState == Enum.PlaybackState.Completed and bopGen == mine then
					bopTween = nil
				end
			end)
			downTween:Play()
		end)
		upTween:Play()
	end)
end

-- --- Number driver (ONE generation-guarded thread) -----------------------

_kickNumber = function()
	numberGen += 1
	local mine = numberGen
	local counter = _findCounter()
	if not counter then
		return
	end
	local from = visual
	local goal = target
	task.spawn(function()
		if numberGen ~= mine then
			return
		end
		local cmp = 0
		pcall(function()
			cmp = BigNumber.Compare(goal, from)
		end)
		if cmp <= 0 then
			-- Equal: re-assert exactness. Less (spend):
			-- snap exact, clear the pool (in-flight visuals
			-- no longer represent anything real).
			visual = goal
			pool = '0'
			local live = _findCounter()
			if live and numberGen == mine then
				_paintCounter(live, goal)
			end
			return
		end
		local delta: string? = nil
		pcall(function()
			delta = BigNumber.Subtract(goal, from)
		end)
		if delta == nil or (delta :: string) == '0' then
			if numberGen == mine then
				visual = goal
				local live = _findCounter()
				if live then
					_paintCounter(live, goal)
				end
			end
			return
		end
		local stepWait = NUMBER_SECONDS / NUMBER_STEPS
		for i = 1, NUMBER_STEPS do
			if numberGen ~= mine then
				return
			end
			if i < NUMBER_STEPS then
				local frac = string.format('%.4f', i / NUMBER_STEPS)
				local shown: string? = nil
				pcall(function()
					shown = BigNumber.Add(from, BigNumber.MultiplyDecimal(delta :: string, frac))
				end)
				if shown ~= nil then
					visual = shown :: string
					local live = _findCounter()
					if live then
						_paintCounter(live, visual)
					end
				end
				task.wait(stepWait)
			else
				visual = goal
				local live = _findCounter()
				if live then
					_paintCounter(live, goal)
					_pulseCounter(live)
				end
				_maybeSettled()
			end
		end
	end)
end

-- --- Icon stream -----------------------------------------------------------

local function _burstTierCount(gained: string): number
	local big = false
	pcall(function()
		big = BigNumber.Compare(gained, '10000000') >= 0
	end)
	if big then
		return ICON_MAX
	end
	local mid = false
	pcall(function()
		mid = BigNumber.Compare(gained, '100000') >= 0
	end)
	if mid then
		return ICON_TIER3
	end
	local small = false
	pcall(function()
		small = BigNumber.Compare(gained, '1000') >= 0
	end)
	if small then
		return ICON_TIER2
	end
	return ICON_MIN
end

local function _activeCount(): number
	local n = 0
	for _ in pairs(activeIcons) do
		n += 1
	end
	return n
end

-- Exact split of `amount` across `k` icons (Divide floors;
-- remainder rides on the first icon). Returns share list.
local function _splitShares(amount: string, k: number): { string }
	local out: { string } = {}
	if k <= 0 then
		return out
	end
	local share: string? = nil
	pcall(function()
		share = BigNumber.Divide(amount, tostring(k))
	end)
	if share == nil then
		-- No division: first icon represents everything,
		-- the rest are pure decoration (still exact —
		-- money truth lives in the target thread).
		out[#out + 1] = amount
		for _ = 2, k do
			out[#out + 1] = '0'
		end
		return out
	end
	local covered = amount
	pcall(function()
		covered = BigNumber.Multiply(share :: string, k)
	end)
	local remainder = '0'
	pcall(function()
		remainder = BigNumber.Subtract(amount, covered)
	end)
	for i = 1, k do
		if i == 1 then
			local first = share :: string
			pcall(function()
				first = BigNumber.Add(share :: string, remainder)
			end)
			out[#out + 1] = first
		else
			out[#out + 1] = share :: string
		end
	end
	return out
end

-- --- Central flight loop (ONE Heartbeat, idle-disconnected) ------------
--
-- Every live icon carries its full trajectory: t0, dur, P0
-- (screen spawn at the collection button), P1 (flick control
-- point), P2 (counter center + jitter), size0, rot0, rotVel,
-- baseT (authored transparency), share. The single loop
-- evaluates a quadratic bezier per icon with an accelerating
-- temporal map (burst → immediate motion → suck-in), shrinks
-- over the last 20% and fades over the last 15%, then
-- absorbs EXACTLY at the target: destroy + credit + bop +
-- pump. No per-icon Heartbeat, tweens, threads, delays, or
-- connections. Created on first live icon, disconnected when
-- the list empties: zero cost at rest.
type FlightState = {
	t0: number,
	dur: number,
	p0: Vector2,
	p1: Vector2,
	p2: Vector2,
	size0: number,
	rot0: number,
	rotVel: number,
	baseT: number,
}
local flight: { [GuiObject]: FlightState } = {}
local flightConn: RBXScriptConnection? = nil

local function _smooth01(a: number, b: number, x: number): number
	local t = (x - a) / (b - a)
	if t < 0 then
		t = 0
	elseif t > 1 then
		t = 1
	end
	return t * t * (3 - 2 * t)
end

local function _flightStep()
	local now = os.clock()
	for node, st in pairs(flight) do
		if node.Parent == nil then
			_destroyIcon(node)
		else
			local t = (now - st.t0) / st.dur
			if t >= 1 then
				-- Absorb exactly at the HUD target.
				node.Position = UDim2.fromOffset(st.p2.X, st.p2.Y)
				local share = activeIcons[node]
				_destroyIcon(node)
				_onIconSettled(share)
			else
				-- Accelerating map: immediate motion off the
				-- button, fastest into the counter (suck-in).
				local te = t ^ 1.6
				local u = 1 - te
				local pos = u * u * st.p0 + 2 * u * te * st.p1 + te * te * st.p2
				node.Position = UDim2.fromOffset(pos.X, pos.Y)
				-- Shrink over the last 20%, fade over the
				-- last 15%, spin throughout.
				local px = st.size0 * (1 - 0.65 * _smooth01(0.8, 1, t))
				node.Size = UDim2.fromOffset(px, px)
				node.Rotation = st.rot0 + st.rotVel * t
				local fade = _smooth01(0.85, 1, t)
				if node:IsA('ImageLabel') then
					node.ImageTransparency = st.baseT + (1 - st.baseT) * fade
				elseif node:IsA('TextLabel') then
					node.TextTransparency = fade
					node.BackgroundTransparency = 0.25 + 0.75 * fade
				end
			end
		end
	end
	if next(flight) == nil and flightConn ~= nil then
		local conn = flightConn
		flightConn = nil
		pcall(function()
			conn:Disconnect()
		end)
	end
end

local function _ensureFlightLoop()
	if flightConn ~= nil then
		return
	end
	pcall(function()
		flightConn = RunService.Heartbeat:Connect(_flightStep)
	end)
end

_destroyIcon = function(node: GuiObject)
	activeIcons[node] = nil
	flight[node] = nil
	pcall(function()
		node:Destroy()
	end)
end

-- Register a live icon's trajectory and start it moving THIS
-- tick (no delays, no queue — every active icon is always
-- already flying toward the counter). The caller owns the
-- spatial distribution (sector spread start + outward control
-- point + staggered duration); this function only registers
-- the trajectory and starts the shared loop.
local function _launchIcon(
	node: GuiObject,
	p0: Vector2,
	p1: Vector2,
	p2: Vector2,
	dur: number,
	size0: number,
	rot0: number,
	rotVel: number
)
	local baseT = 0
	if node:IsA('ImageLabel') then
		local okT, v = pcall(function()
			return (node :: ImageLabel).ImageTransparency
		end)
		if okT and type(v) == 'number' and v == v then
			baseT = math.clamp(v, 0, 1)
		end
	end
	flight[node] = {
		t0 = os.clock(),
		dur = dur,
		p0 = p0,
		p1 = p1,
		p2 = p2,
		size0 = size0,
		rot0 = rot0,
		rotVel = rotVel,
		baseT = baseT,
	}
	_ensureFlightLoop()
end

-- An icon finished (landed or dropped): pulse, pump, maybe
-- settle. The pool is an AMOUNT accumulator cleared at spawn
-- (icons are pure visuals after that), so arrivals NEVER
-- re-deduct — the share param is accepted for seam compat
-- and ignored. Money truth lives in the target number
-- thread; this keeps the pool from ever going negative and
-- guarantees no visual backlog can accumulate.
_onIconSettled = function(_share: string?)
	-- Visual-only stream: _share is intentionally ignored
	-- (pool was already cleared at spawn; see _pump).
	local live = _findCounter()
	if live then
		_pulseCounter(live)
	end
	_pump()
	_maybeSettled()
end

-- Latest collection world origin (payload Origin), used
-- as the next burst's screen-space spawn. Not trusted for
-- money — position only.
local latestOrigin: Vector3? = nil

-- Project the collection button to screen space, clamped to
-- the viewport. Behind-camera/missing origins fall back to
-- center screen with a nudge so the burst never breaks.
local function _spawnOrigin(viewport: Vector2): Vector2
	local margin = 30
	local fallback = Vector2.new(viewport.X * 0.5, viewport.Y * 0.62)
	local origin = latestOrigin
	local camera = Workspace.CurrentCamera
	if origin == nil or camera == nil then
		return fallback
	end
	local sp: Vector3? = nil
	local visible = false
	pcall(function()
		local projected, isVisible = camera:WorldToScreenPoint(origin :: Vector3)
		sp = Vector2.new(projected.X, projected.Y)
		visible = isVisible
	end)
	if sp == nil or not visible then
		return fallback
	end
	local p = sp :: Vector2
	return Vector2.new(
		math.clamp(p.X, margin, math.max(margin, viewport.X - margin)),
		math.clamp(p.Y, margin, math.max(margin, viewport.Y - margin))
	)
end

-- Distributed burst tuning (presentation feel only).
-- Canonical: BaseConfig.MoneyPool (values preserved exactly).
local BURST_MIN_RADIUS = MP.BurstMinRadius
local BURST_MAX_RADIUS = MP.BurstMaxRadius
local BURST_X_SPREAD = MP.BurstXSpread
local BURST_Y_SPREAD = MP.BurstYSpread
local BURST_JITTER_PX = MP.BurstJitterPx
local FLICK_MIN = MP.FlickMin
local FLICK_MAX = MP.FlickMax
local FLICK_SIDE_JITTER = MP.FlickSideJitter
local FLIGHT_MIN_SECONDS = MP.FlightMinSeconds
local FLIGHT_MAX_SECONDS = MP.FlightMaxSeconds

-- Rotating angular phase: every burst starts at a different
-- angle so rapid/spam collections never stack into the same
-- pattern. Advanced per _pump call (random step, never a
-- fixed repeating cycle).
local burstPhase = math.random() * math.pi * 2

local function _clampToViewport(p: Vector2, viewport: Vector2, margin: number): Vector2
	return Vector2.new(
		math.clamp(p.X, margin, math.max(margin, viewport.X - margin)),
		math.clamp(p.Y, margin, math.max(margin, viewport.Y - margin))
	)
end

-- Spawn while pool > 0 and capacity allows. The pool is an
-- AMOUNT accumulator: the spawned batch visually represents
-- the whole pool (excess folds into the same icons when the
-- cap binds), then the pool clears to '0' — arrivals never
-- re-deduct, so there is no visual queue and no backlog dump.
-- If the cap is full (batch <= 0) the pool stays put as an
-- invisible amount until arrivals free slots.
-- Spawned icons ALWAYS fly immediately via the central loop —
-- the cap is a concurrency limit, never a visual queue.
_pump = function()
	if pool == '0' then
		return
	end
	local counter = _findCounter()
	if not counter then
		return
	end
	local gui = _ensureOverlay()
	if not gui then
		return
	end
	local template = _ensureTemplate()
	if not template then
		return
	end
	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
	local cPos = counter.AbsolutePosition
	local cSize = counter.AbsoluteSize
	local dest = Vector2.new(cPos.X + cSize.X / 2, cPos.Y + cSize.Y / 2)
	-- Burst origin: the collection button in screen space
	-- (payload Origin), clamped to the viewport.
	-- Off-screen/behind-camera/missing origins fall back to
	-- center screen — never a hardcoded point, never broken.
	local origin = _spawnOrigin(viewport)
	local batch = math.min(_burstTierCount(pool), ACTIVE_ICON_CAP - _activeCount())
	if batch <= 0 then
		return
	end
	_log('burst icons=', tostring(batch), 'pool=', pool)
	-- Rotate the burst phase every collection so spam spreads
	-- around the source instead of stacking one pattern.
	burstPhase = (burstPhase + math.pi * (0.7 + math.random() * 1.6)) % (math.pi * 2)
	local sectorWidth = (math.pi * 2) / batch
	local spawned = false
	for i = 1, batch do
		-- SECTOR DISTRIBUTION: icon i owns angular sector i,
		-- with a random angle inside it (margined so neighbours
		-- can't collapse together) plus radial + cartesian
		-- jitter for an organic — never rigid — spread.
		local sectorBase = burstPhase + (i - 1) * sectorWidth
		local angle = sectorBase + sectorWidth * (0.075 + math.random() * 0.85)
		local radius = BURST_MIN_RADIUS + math.random() * (BURST_MAX_RADIUS - BURST_MIN_RADIUS)
		local burstOffset = Vector2.new(
			math.cos(angle) * radius * BURST_X_SPREAD + (math.random() * 2 - 1) * BURST_JITTER_PX,
			math.sin(angle) * radius * BURST_Y_SPREAD + (math.random() * 2 - 1) * BURST_JITTER_PX
		)
		local made: GuiObject? = nil
		pcall(function()
			made = (template :: GuiObject):Clone()
		end)
		local node = made
		if node == nil then
			continue
		end
		node.AnchorPoint = Vector2.new(0.5, 0.5)
		-- Size distribution 0.75x–1.3x around the authored base.
		local px = math.max(12, math.floor(ICON_BASE_PX * (0.75 + math.random() * 0.55) + 0.5))
		local start = _clampToViewport(origin + burstOffset, viewport, px / 2 + 8)
		-- UNIQUE TRAJECTORY: control point flicks OUTWARD from
		-- the origin through this icon's own spread position
		-- (phase 1: burst) with perpendicular jitter, then the
		-- bezier bends back into the HUD (phase 2: magnet).
		-- Every icon gets its own arc.
		local outward = start - origin
		local outwardMag = outward.Magnitude
		local outDir: Vector2
		if outwardMag < 1 then
			local a = math.random() * math.pi * 2
			outDir = Vector2.new(math.cos(a), math.sin(a))
		else
			outDir = outward / outwardMag
		end
		local perp = Vector2.new(-outDir.Y, outDir.X)
		local flickDist = FLICK_MIN + math.random() * (FLICK_MAX - FLICK_MIN)
		local p1 = _clampToViewport(
			start + outDir * flickDist + perp * ((math.random() * 2 - 1) * FLICK_SIDE_JITTER),
			viewport,
			8
		)
		local p2 = dest + Vector2.new((math.random() * 2 - 1) * 4, (math.random() * 2 - 1) * 4)
		-- Staggered flight: a bounded 0.34–0.53s stream so icons
		-- arrive one after another, never as one blob.
		local dur = FLIGHT_MIN_SECONDS + math.random() * (FLIGHT_MAX_SECONDS - FLIGHT_MIN_SECONDS)
		local rot0 = math.random() * 360 - 180
		local rotVel = (math.random() * 2 - 1) * 110
		node.Size = UDim2.fromOffset(px, px)
		node.Position = UDim2.fromOffset(start.X, start.Y)
		node.Rotation = rot0
		-- Flying image icons are ALWAYS fully transparent
		-- behind the image (never a copied rectangle). The
		-- chip fallback keeps its own background.
		if node:IsA('ImageLabel') then
			node.BackgroundTransparency = 1
		elseif node:IsA('TextLabel') then
			node.BackgroundTransparency = 0.25
		end
		node.Parent = gui
		-- Pure visual: the pool clears below, so arrivals carry
		-- no share (money truth is the target number thread).
		activeIcons[node] = '0'
		spawned = true
		_launchIcon(node, start, p1, p2, dur, px, rot0, rotVel)
	end
	if spawned then
		-- The spawned batch visually represents the whole pool:
		-- clear the amount accumulator (no re-deduct on arrival,
		-- no visual backlog, no double-count).
		pool = '0'
	end
end

_maybeSettled = function()
	if pool ~= '0' then
		settledIdle = false
		return
	end
	if _activeCount() ~= 0 then
		settledIdle = false
		return
	end
	local cmp = -1
	pcall(function()
		cmp = BigNumber.Compare(visual, target)
	end)
	if cmp ~= 0 then
		settledIdle = false
		return
	end
	if not settledIdle then
		settledIdle = true
		_log('pool drained visualMoney=', visual, 'target=', target)
	end
end

-- --- Events ---------------------------------------------------------------

local function _onCashCollected(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	-- Amounts are presentation input only; the wallet truth
	-- stays target <- NewMoney / PlayerState.
	local rawAmount = payload.Amount
	if type(rawAmount) ~= 'string' or rawAmount == '' then
		return
	end
	local amount = BigNumber.sanitize(rawAmount)
	if not amount or BigNumber.IsZero(amount) then
		return
	end
	local rawNew = payload.NewMoney
	if type(rawNew) == 'string' and rawNew ~= '' then
		local nm = BigNumber.sanitize(rawNew)
		if nm then
			target = nm
		end
	end
	-- Icon source wiring (the fix): the server-supplied
	-- MoneyIcon visual config becomes the template source
	-- for this and later pumps. Template rebuilds only when
	-- the config Image changes, so retargeting the Studio
	-- asset takes effect with no code changes.
	if type(payload.Icon) == 'table' then
		latestIconCfg = payload.Icon
	end
	-- Collection world origin (position only, never money):
	-- the next burst spawns from the button on screen.
	local rawOrigin = payload.Origin
	if type(rawOrigin) == 'table' then
		local ox = (rawOrigin :: { any })[1]
		local oy = (rawOrigin :: { any })[2]
		local oz = (rawOrigin :: { any })[3]
		if type(ox) == 'number' and type(oy) == 'number' and type(oz) == 'number' then
			if ox == ox and oy == oy and oz == oz then
				latestOrigin = Vector3.new(ox, oy, oz)
			end
		end
	end
	pcall(function()
		pool = BigNumber.Add(pool, amount :: string)
	end)
	settledIdle = false
	_log('CashCollected amount=', amount, 'newMoney=', target, 'pool=', pool)
	_pump()
	_kickNumber()
end

local function _onPlayerState(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	local raw = payload.Money
	local safe = (type(raw) == 'string' and raw ~= '' and BigNumber.sanitize(raw)) or '0'
	-- Diagnostic: log every authoritative money change (change-
	-- gated, so steady-state slot pushes stay silent). Proves
	-- the client RECEIVED the new balance and which wire
	-- delivered it (PlayerState correction vs CashCollected).
	if hasVisual and safe ~= target then
		_log('[MoneySync] PlayerState money old=', target, 'new=', safe)
	end
	target = safe
	if not hasVisual then
		-- First authoritative sight: snap everything exact.
		-- Pre-Init events are not replayed (engine drops
		-- them); the wallet is right and future events stream.
		hasVisual = true
		numberGen += 1
		visual = safe
		pool = '0'
		settledIdle = true
		local counter = _findCounter()
		if counter then
			_paintCounter(counter, safe)
			_log('bound MoneyCounter path=', counter:GetFullName(), 'money=', safe)
		end
		return
	end
	_kickNumber()
end

-- --- Lifecycle (remote once, GUI lazy) ---------------------------------------

local _initialized = false

function MoneyPoolController.Init()
	if _initialized then
		return
	end
	_initialized = true
	_log('controller started')
	-- Remotes FIRST (before any GUI work): events must never
	-- be missed because of init ordering. Each connects at
	-- most once for the controller's lifetime.
	Remotes.WaitForReady()
	local folder = Remotes.WaitForReady()
	do
		local collected = folder:WaitForChild(Remotes.Names.CashCollected, 10)
		if collected and collected:IsA('RemoteEvent') then
			local re = collected :: RemoteEvent
			if cashConn == nil then
				cashConn = re.OnClientEvent:Connect(_onCashCollected)
			end
		else
			_log('CashCollected remote missing; bursts disabled (numbers still track)')
		end
	end
	do
		local statePayload = folder:WaitForChild(Remotes.Names.PlayerState, 10)
		if statePayload and statePayload:IsA('RemoteEvent') then
			local re = statePayload :: RemoteEvent
			if stateConn == nil then
				stateConn = re.OnClientEvent:Connect(_onPlayerState)
			end
		else
			_log('PlayerState remote missing; numbers unavailable')
		end
	end
	-- Respawn: cancel threads, destroy live icons, clear —
	-- never hold a destroyed counter or overlay. Remote
	-- connections are NOT touched (separate lifetime).
	localPlayer.CharacterAdded:Connect(function()
		numberGen += 1
		bopGen += 1
		arrivalStamps = {}
		if bopTween then
			local b = bopTween
			bopTween = nil
			pcall(function()
				b:Cancel()
			end)
		end
		for icon in pairs(activeIcons) do
			_destroyIcon(icon)
		end
		pool = '0'
		settledIdle = false
	end)
	-- Late HUD (respawn rebuild after the last money event):
	-- repaint the known-good target immediately so the Studio
	-- default text never sits as stale UI. No polling — one
	-- ChildAdded connection for the controller lifetime.
	pcall(function()
		local playerGui = localPlayer:FindFirstChildOfClass('PlayerGui')
		if playerGui ~= nil then
			(playerGui :: Instance).ChildAdded:Connect(function(child: Instance)
				if child.Name ~= 'HUD' then
					return
				end
				task.spawn(function()
					if hasVisual then
						local counter = _findCounter()
						if counter then
							_paintCounter(counter, target)
						end
					end
				end)
			end)
		end
	end)
	_log('GUI initialization complete')
end

return table.freeze(MoneyPoolController)
