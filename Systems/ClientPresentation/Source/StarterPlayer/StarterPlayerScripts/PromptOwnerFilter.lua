--!strict
--!native
--[[
	PromptOwnerFilter
	=================
	Client-side filter for cross-player prompt visibility.

  Every ProximityPrompt installed by the server carries an
  `ownerUserId` attribute (Pickup / Sell / Open / Steal) or a `targetUserId`
  attribute (Place). Traveling-egg Buy prompts additionally
  carry `purchaserUserId` (the current purchaser, re-stamped
  on every rebuy — the purchaser never sees Buy). The
  server-side prompt installers
  (`CarryPrompts.InstallPickupPrompt`,
  `CarryPrompts.InstallHatchPrompt`,
  `CarryPrompts.InstallPlacePromptOnSlot`) set these on
  creation; center Available Egg Buy prompts carry no
  purchaser attribute and are visible to all players.

	Why a client-side filter at all? The server is the source
	of truth (`SlotActionHandler` rejects any action whose
	caller isn't the owner), but a non-owner walking past
	someone else's base would still see a wall of Pickup /
	Open / Place prompts they can't actually use. Visually
	that's noise. The filter hides them client-side so each
	player only sees the affordances they own.

 	Implementation: the live prompt set is maintained
 	incrementally (`DescendantAdded`/`Removing` on Workspace,
 	seeded by one full scan at Init) and re-evaluated on a
 	0.25s `Heartbeat`-throttled tick; a slow 5s full resync
 	heals any missed signal. Toggling `prompt.Enabled`
 	is cheap; the rule is per-prompt: hide if any of the
 	following is true:
 	  * the local player is steal-carrying (carryReason ==
 	    Steal) — see below; while a steal is in flight the
 	    thief is in "carrying / locked interaction UI" and
 	    sees NO interaction prompts at all, OR
 	  * `targetUserId` is set AND ≠ local player's UserId, OR
 	  * `ownerUserId` is set AND ≠ local player's UserId.
 	Plus a global rule: hide every prompt whose name is
 	`BuyPrompt` when the local player is carrying (read from
 	the last `PlayerState` remote payload — `CarriedKind`).

  	Steal-suppression (thief-only, never global): the server
  	replicates `CarriedSteal` in the `PlayerState` payload
  	(true while THIS player's carry is a steal in progress).
  	While set, the scan hides EVERY prompt for this player
  	only — Steal, Pickup, Open, Buy, Place, anything on any
  	base. Other players' filters are driven by their own
  	payloads, so everyone else keeps normal visibility. When
  	the carry ends (delivery, rollback, cancel) the next
  	`PlayerState` push clears the flag and this player's
  	prompts restore on the following tick. No stuck state: the
  	flag lives in the client's session and resets on rejoin.

  	Steal-capacity + fail-closed Steal: a Steal prompt shows
  	only with its `stealPrompt` marker AND a non-owner
  	`ownerUserId` AND a nonzero local Empty-slot count (the
  	server rejects full-base steals before pickup regardless).
  	Anything NAMED StealPrompt that lacks the marker (a
  	half-installed prompt observed mid-transition) is hidden
  	for everyone — presentation can never fail open, and the
  	server revalidates ownership on every request anyway.

	Why Heartbeat over `PromptShown`? `PromptShown` fires on
	the client AFTER the prompt's owner attribute has been
	set, and a prompt can show while the scan is sleeping.
	The 0.25s tick is dumb but correct: it catches every
	prompt that exists at scan time, regardless of when it
	was parented. A new prompt installed by the server
	shows up at most 0.25s later in the local player's UI.

	Server rules still apply — disabling the prompt client-side
	never grants access; the server still rejects non-owner
	actions.
]]

local RunService = game:GetService('RunService')
local Players = game:GetService('Players')
local Workspace = game:GetService('Workspace')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Remotes = require(ReplicatedStorage.Utility.Remotes)

local PromptOwnerFilter = {}

-- Mirror of the local player's carry state, kept in sync by
-- SetLocalCarry. The server replicates this via the
-- `PlayerState` remote — HUDController already receives it
-- and so does the filter, but we keep an independent copy so
-- HUD / filter lifecycle is decoupled (the filter must work
-- even if HUD is destroyed for some reason).
local localCarryKind: string? = nil
-- True while the local player's carry is a steal in progress
-- (server replicates `CarriedSteal`). While set, EVERY prompt
-- is hidden for this player only (thief "locked UI").
local localCarrySteal: boolean = false
-- Count of Empty slots on the local player's OWN base from
-- the last PlayerState payload (nil = unknown payload shape).
-- Steal prompts hide at 0: the server rejects steal attempts
-- from a full base before pickup, so the prompt would only be
-- noise. Stale by at most one push (only the owner's own
-- actions change their base) — and staleness is UX-only, the
-- server revalidates capacity on every request.
local localFreeSlots: number? = nil

-- Tick rate. 0.25s = 4Hz; a human can perceive flicker at
-- >10Hz, so this is the slowest rate that won't visibly
-- stutter. 4Hz scan is O(prompt count) per tick — typically
-- <20 prompts in a populated server; <1ms per scan.
local TICK_SECONDS = 0.25

-- Set the local carry state from the most recent PlayerState
-- payload. The HUDController also receives this payload; we
-- capture it independently so the filter can run before the
-- HUD finishes parsing the same payload.
function PromptOwnerFilter.SetLocalCarry(carriedKind: string?, _carriedName: string?, carriedSteal: boolean?)
	localCarryKind = carriedKind
	localCarrySteal = carriedSteal == true
end

-- Subscribe to PlayerState. We deliberately do this on
-- Init, before any HUD subscription, so a carry transition
-- that arrives while the HUD is mid-paint still flips the
-- Buy prompt's Enabled state correctly.
local function onPlayerState(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	PromptOwnerFilter.SetLocalCarry(payload.CarriedKind, payload.CarriedName, payload.CarriedSteal)
	-- Free-slot count for the Steal-capacity rule below.
	-- payload.Slots is the LOCAL player's own base snapshot
	-- ({ State = 'Empty' | ... } per slot).
	local slots = payload.Slots
	if type(slots) == 'table' then
		local free = 0
		for _, s in pairs(slots) do
			if type(s) == 'table' and s.State == 'Empty' then
				free += 1
			end
		end
		localFreeSlots = free
	else
		localFreeSlots = nil
	end
end

-- Decide whether the local player should see `prompt`. Returns
-- true if the prompt is allowed, false if it should be hidden.
-- The rule is per-instance; see the file header for the full
-- design rationale.
--
-- Steal prompts (marked `stealPrompt`, carrying the owner's
-- `ownerUserId`) use the INVERSE rule: visible ONLY to
-- non-owners. The owner never sees Steal on their own
-- objects; strangers never see Pickup/Open. Server
-- validation is independent of all of this.
local function shouldShow(prompt: ProximityPrompt, localUserId: number): boolean
	-- Thief lockout (player-specific): while THIS player's
	-- carry is a steal, hide every interaction prompt. Other
	-- players evaluate their own flags, so only the thief is
	-- affected. Normal (non-steal) carriers keep the rules
	-- below.
	if localCarrySteal then
		return false
	end
	local targetUserId = prompt:GetAttribute('targetUserId')
	if targetUserId ~= nil then
		-- Place prompt — owned by a single carrying player.
		-- If the local player is not that player, hide.
		if type(targetUserId) ~= 'number' then
			return false
		end
		return targetUserId == localUserId
	end
	if prompt:GetAttribute('stealPrompt') == true then
		local ownerUserId = prompt:GetAttribute('ownerUserId')
		if type(ownerUserId) ~= 'number' then
			return false
		end
		if ownerUserId == localUserId then
			return false
		end
		-- Full destination base: the server rejects the steal
		-- before pickup, so hide the prompt (UX-only; the
		-- server revalidates on every request).
		if localFreeSlots == 0 then
			return false
		end
		-- While carrying anything (normal or steal), hide
		-- Steal too (the server rejects steal-while-carrying;
		-- the prompt would only be noise). Note the
		-- steal-carry blanket rule above already returns
		-- false first; this covers normal carriers.
		if localCarryKind ~= nil then
			return false
		end
		return true
	end
	-- Fail closed: anything NAMED a steal prompt that lacks
	-- the marker (half-installed during a rapid transition)
	-- is hidden rather than shown to everyone.
	if prompt.Name == 'StealPrompt' then
		return false
	end
	-- Paid door prompt (marked `doorPrompt`, carrying the base
	-- owner's `ownerUserId`): visible to NON-owners only — the
	-- inverse of Pickup/Open. The owner never sees Open Door
	-- on their own base; strangers do while it is locked
	-- (the server creates the prompt only on locked bases and
	-- destroys it on unlock, and revalidates every trigger).
	if prompt:GetAttribute('doorPrompt') == true then
		local doorOwner = prompt:GetAttribute('ownerUserId')
		if type(doorOwner) ~= 'number' then
			return false
		end
		return doorOwner ~= localUserId
	end
	local ownerUserId = prompt:GetAttribute('ownerUserId')
	if ownerUserId ~= nil then
		-- Pickup / Open — owned by the player whose base the
		-- object sits on.
		if type(ownerUserId) ~= 'number' then
			return false
		end
		if ownerUserId ~= localUserId then
			return false
		end
		-- Carry rule: when the local player is carrying,
		-- hide every Pickup/Open prompt on their own base
		-- (not on other players' bases — those are already
		-- hidden by the ownerUserId check above). Without
		-- this, the filter would re-show the very prompts
		-- the server's DisablePickupHatchPromptsForBase just
		-- hid on grab, every 0.25s. The Place prompt is
		-- keyed by `targetUserId` (handled above) and stays
		-- visible because the carrying player needs the
		-- place affordance.
		if localCarryKind ~= nil and (prompt.Name == 'PickupPrompt' or prompt.Name == 'HatchPrompt') then
			return false
		end
	end
	-- Buy prompt: hide for the carrying player (the server
	-- rejects Purchase while carrying, so the prompt is
	-- useless). Traveling-egg contest rule: the server stamps
	-- `purchaserUserId` with the CURRENT purchaser on the Buy
	-- prompt for a traveling egg (re-stamped on every rebuy);
	-- the current purchaser never sees Buy, everyone else
	-- eligible still does. Server enforcement is independent
	-- (owner re-buy is rejected pre-debit) — this is display
	-- only, applied on the existing tick when the replicated
	-- attribute changes. Non-carrying players still see Buy.
	if prompt.Name == 'BuyPrompt' and localCarryKind ~= nil then
		return false
	end
	if prompt.Name == 'BuyPrompt' then
		local purchaserUserId = prompt:GetAttribute('purchaserUserId')
		if type(purchaserUserId) == 'number' and purchaserUserId == localUserId then
			return false
		end
	end
	return true
end

-- One scan: iterate every KNOWN ProximityPrompt and flip
-- `Enabled` to match `shouldShow`. Idempotent; safe to call
-- as often as the Heartbeat tick fires.
--
-- PERF: the prompt set is maintained incrementally via
-- DescendantAdded/Removing (see Init) instead of a full
-- Workspace:GetDescendants() every tick. A full-workspace
-- traversal allocates a thousands-entry array 4x/second on
-- every client; the incremental set only ever holds the
-- ~dozen live prompts, and a slow full resync (see below)
-- heals any missed add/remove.
local _prompts: { [ProximityPrompt]: boolean } = {}
local _lastResync = 0

-- Slow safety resync (seconds): rebuild the set from scratch
-- in case any add/remove signal was missed (e.g. bulk
-- StreamingEnabled loads). Cheap when amortized.
local RESYNC_SECONDS = 5

local function _resync()
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA('ProximityPrompt') then
			_prompts[desc] = true
		end
	end
	_lastResync = os.clock()
end

local function scan(localUserId: number)
	for prompt in pairs(_prompts) do
		-- Stale refs (destroyed without a Removing signal
		-- reaching us) drop out lazily here.
		if prompt.Parent == nil or not prompt:IsDescendantOf(Workspace) then
			_prompts[prompt] = nil
		else
			local allowed = shouldShow(prompt, localUserId)
			-- Only assign when it changes; ProximityPrompt
			-- `.Enabled` writes are cheap but no-op writes
			-- are free.
			if prompt.Enabled ~= allowed then
				prompt.Enabled = allowed
			end
		end
	end
	if os.clock() - _lastResync >= RESYNC_SECONDS then
		_resync()
	end
end

function PromptOwnerFilter.Init()
	Remotes.WaitForReady()
	Remotes.OnClientEvent(Remotes.Names.PlayerState):Connect(onPlayerState)

	-- The local Player exists before this LocalScript runs.
	-- (StarterPlayerScripts run after the player joins the
	-- game.) Capture once and re-scan if the local player
	-- changes (Studio local-player swap; rare in production).
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	-- Local-player-swap re-scan is implicit: we re-scan
	-- every Heartbeat, and `Players.LocalPlayer` is read
	-- fresh each tick. If the Studio test swaps the local
	-- player, the next tick's `scan(me.UserId)` uses the
	-- new UserId automatically. No explicit listener
	-- needed.

	local lastTick = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastTick < TICK_SECONDS then
			return
		end
		lastTick = now
		local me = Players.LocalPlayer
		if not me then
			return
		end
		scan(me.UserId)
	end)

	-- Incremental prompt tracking: seed with one full scan,
	-- then maintain the set from add/remove signals (no more
	-- full traversals on the hot path; see scan/resync).
	_resync()
	Workspace.DescendantAdded:Connect(function(desc: Instance)
		if desc:IsA('ProximityPrompt') then
			_prompts[desc] = true
		end
	end)
	Workspace.DescendantRemoving:Connect(function(desc: Instance)
		if desc:IsA('ProximityPrompt') then
			_prompts[desc] = nil
		end
	end)

	-- Also scan immediately so the very first frame after
	-- Init shows the correct state. A player that joined
	-- with carry state already set (e.g. a Studio playtest
	-- where the player's last state was Carried) would
	-- otherwise wait up to 0.25s for the first tick.
	scan(localPlayer.UserId)
end

return PromptOwnerFilter
