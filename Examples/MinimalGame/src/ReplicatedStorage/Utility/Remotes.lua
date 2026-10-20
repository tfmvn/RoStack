--!strict
--[[
	Remotes
	=======
	Single source of truth for every RemoteEvent in the game.
	Server creates the events in bootstrap.server.lua, then
	`SetRemotes` is called with the folder. Client waits on the
	folder, then calls `GetRemote(name)` to obtain a typed wrapper.

	Keeping all remote names + payload shapes in one place is the
	way to avoid the "I added a remote and forgot to tell the
	client" failure mode.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')

local Signal = require(script.Parent.Signals)
local Validation = require(script.Parent.Validation)
local Debug = require(script.Parent.Debug)

local Remotes = {}

-- --- Names ---------------------------------------------------------

Remotes.Names = {
	PlayerState = 'PlayerState', -- S->C: cash, base, slot states
	Notify = 'Notify', -- S->C: toast
	EggArrived = 'EggArrived', -- S->C: an egg reached a slot
	AnimalArrived = 'AnimalArrived', -- S->C: an animal reached its slot
	-- Phase 1.5: carry/place events. The HUD is not required to
	-- consume these — PlayerState already reflects the slot's new
	-- occupancy — but they're useful for clients that want to play
	-- grab/place feedback (a SFX, a quick toast, an anim).
	AnimalCarried = 'AnimalCarried', -- S->C: an animal left its slot (payload: { UniqueId, DefinitionId, DisplayName, Rarity })
	AnimalPlaced = 'AnimalPlaced', -- S->C: an animal landed in a new slot (payload: { UniqueId, SlotId })
	-- Level-up presentation: S->C fired by the authoritative
	-- server-side level-up (AnimalService AddXP threshold cross /
	-- ApplyLevelUpgrade) AFTER the mutation. Payload: { AnimalId,
	-- SlotId, OldLevel, NewLevel, LevelsGained }. Display-only —
	-- the server already plays the bop + Upgrade VFX on the
	-- replicated model; clients use this for HUD/toast hooks.
	AnimalLeveledUp = 'AnimalLeveledUp',
	-- Phase 2: unified carry. Mirrors the animal carry
	-- events for lucky eggs. Payload: { BaseId, SlotId,
	-- Rarity }.
	EggCarried = 'EggCarried', -- S->C: a lucky egg left its slot
	EggPlaced = 'EggPlaced', -- S->C: a lucky egg landed in a new slot
	-- Phase 2.9: slot interaction menus (player-facing,
	-- owner-validated per request — NOT admin-gated).
	-- SlotMenuRequest C->S { SlotId }: ask for the selected
	--   slot's authoritative menu data (preview only).
	-- SlotMenuState S->C: the structured menu snapshot, or
	--   { Valid = false } when the slot has nothing to show.
	-- SlotMenuAction C->S { SlotId, OccupantId }: confirm the
	--   sale. Values are NEVER accepted from the client — the
	--   server re-resolves everything and transacts through
	--   SlotActionHandler (same validation as prompt sales).
	-- SlotMenuResult S->C { SlotId, Success, Error? }: the
	--   confirm outcome for menu close/clear decisions.
	SlotMenuRequest = 'SlotMenuRequest',
	SlotMenuState = 'SlotMenuState',
	SlotMenuAction = 'SlotMenuAction',
	SlotMenuResult = 'SlotMenuResult',
	-- Animal sell confirmation (server-authoritative two-step
	-- sale; the Sell prompt opens, it never sells directly):
	-- SellPreviewState S->C: pushed after the Sell prompt
	--   fires and passes read-only validation. { Valid,
	--   AnimalId, Name, Rarity, Trait?, Level, LevelText,
	--   GenerationText, Mutations, SellValueRaw?,
	--   Model? } — display-only preview (Trait/SellValueRaw
	--   feed the name/sell-button text; Model is the live
	--   animal Model reference for the client to Clone locally
	--   into the viewport — never reparented, never mutated);
	--   { Valid = false, AnimalId, Reason? } opens nothing.
	-- SellConfirmAction C->S { AnimalId }: the SellConfirmation
	--   Sell button. The server revalidates EVERYTHING and runs
	--   the canonical SellService.SellAnimal transaction.
	-- SellConfirmResult S->C { AnimalId, Success, Error? }:
	--   confirm outcome for confirmation close/clear decisions.
	SellPreviewState = 'SellPreviewState',
	SellConfirmAction = 'SellConfirmAction',
	SellConfirmResult = 'SellConfirmResult',
	-- Cash collection presentation: S->C fired by the
	-- authoritative claim commit (IncomeService.TryCollect
	-- AFTER AddMoney succeeds and the pool zeroes) for the
	-- collecting player only. Payload: { Amount: string
	-- (BigNumber, the committed pool), NewMoney: string?
	-- (BigNumber, authoritative wallet after the commit),
	-- Icon: table? (visual config read from the
	-- Assets.Decals.MoneyIcon ImageLabel: Image plus
	-- RectOffset/RectSize/ScaleType/SliceCenter/SliceScale/
	-- Color/Transparency/BgTransparency),
	-- Origin: {x,y,z}? (world position of the cash trigger
	-- the claim came from; the client projects it to screen
	-- space so icons burst from the button) }. Display-only: the client
	-- accumulates Amount into its visual pool and converges
	-- to NewMoney / the PlayerState push; it never decides
	-- money itself.
	CashCollected = 'CashCollected',
	-- Reset protection gate: S->C fired by the server-side
	-- ResetProtectionService when the player's protected state
	-- CHANGES (never polled, never per-frame). Payload:
	-- { Protected: boolean, Reason: string? } where Reason is
	-- 'CarryingAnimal' | 'CarryingEgg' | 'Stealing' (nil when
	-- unprotected). The client only presents the gate (greys
	-- the reset button); the server remains authoritative and
	-- still recovers unexpected Character loss via the existing
	-- carry/steal recovery paths.
	ResetProtection = 'ResetProtection',
	-- Gear Shop (server-authoritative purchases + session
	-- ownership + AutoBuy preferences):
	-- GearShopAction C->S { Action: 'Purchase' | 'Equip' | 'SetAutoBuy',
	--   GearId: string, Enabled: boolean? (SetAutoBuy only) }:
	--   the ONLY client input. Price/Name/rebirth/tool path
	--   are NEVER accepted — the server re-resolves from
	--   GearConfig.
	-- GearShopState S->C { Money, MoneyText, Rebirth, Gears:
	--   [{ Id, Name, Description, Price, PriceText,
	--   RequiredRebirth, ToolName, Locked, Owned, AutoBuy }] }: full
	--   snapshot pushed on open + after every mutation.
	-- GearShopResult S->C { Action, GearId, Success, Error? }:
	--   per-request outcome for client state decisions.
	GearShopAction = 'GearShopAction',
	GearShopState = 'GearShopState',
	GearShopResult = 'GearShopResult',
	-- Arena raids (server-authoritative continuous runs):
	-- ArenaAction C->S { Action: 'Open' | 'Start' | 'StartRaid'
	--   | 'Cancel', Option?: 'Buy1' | 'Buy2' | 'Buy3' }: the ONLY
	--   client input. 'Start' and 'StartRaid' both start a raid
	--   through the one authoritative path; Option names the
	--   authored-menu button (Buy3 = free stage-1 entry, Buy1 =
	--   paid warmup restart, Buy2 = paid direct restart) and the
	--   server resolves the starting stage + price per request —
	--   any client-sent level or price is ignored; 'Cancel'
	--   retreats from the active raid. Loadout, stages, HP, and
	--   rewards are NEVER accepted — the server re-resolves from
	--   SlotService / AnimalService / ArenaConfig.
	-- ArenaState S->C { Progression, Levels, Session?,
	--   Loadout?, LastRaid?, Dialogue, Show? }: full snapshot
	--   pushed on open + after every mutation. Session carries
	--   the run view (Stage/MaxStage/Generation/Raid team HP);
	--   Loadout previews the pre-raid arena-slot team.
	-- ArenaResult S->C { Action, Success, Error?, SessionId?,
	--   RaidComplete?, Outcome? ('Victory'|'Defeat'), Stage?,
	--   MaxStage?, EarnedCash?, EarnedXP?, Animals?, Eggs? }:
	--   per-request outcome for client open/close/results
	--   decisions ('RaidEnd' fires on raid completion/failure
	--   with the settled totals: full accumulator on completion,
	--   cleared-stage accumulator on defeat ($0/0 only when
	--   nothing was cleared); Animals is the server-finalized
	--   snapshot rows for the result cards, Eggs the finalized
	--   egg rewards, SessionId the dedupe token). Each Animals row
	--   carries CombatModel: the captured ACTUAL combat-model clone
	--   (ReplicatedStorage.ArenaResultModels/Session_<id>) — the
	--   client's only viewport source, never a template).
	ArenaAction = 'ArenaAction',
	ArenaState = 'ArenaState',
	ArenaResult = 'ArenaResult',
	-- Rebirth (server-authoritative progression reset):
	-- RebirthAction C->S { Action: 'Rebirth' | 'State' }:
	--   'Rebirth' attempts the next sequential rebirth (the
	--   client never selects a number); 'State' requests a fresh
	--   GUI snapshot. Missing/empty payloads attempt.
	-- RebirthState S->C: full GUI snapshot { Current, Next?,
	--   Maxed, Money, MoneyRequired, MoneySatisfied, ArenaLevel,
	--   ArenaRequired, ArenaSatisfied, Animals: [{ DefId,
	--   DisplayName, Trait, MinimumLevel, Matched, BestLevel,
	--   TemplateModel? }], Unlocks: [{ Kind ('AnimalStand' |
	--   'ArenaStand' | 'Gear'), Amount (delta), Name, GearId?
	--   (gear only), TemplateModel? (stands only) }], StartingCash,
	--   MoneyMultiplier, CanRebirth }. TemplateModel is the parked ServerStorage-
	--   template clone (ReplicatedStorage.RebirthPreviews) — the
	--   ONLY card viewport source (never a live Workspace animal,
	--   never a reconstruction); nil renders text-only. Gear cards
	--   resolve their visual from ReplicatedStorage.GearShopPreviews
	--   by GearId (the Gear Shop's canonical preview source).
	-- RebirthResult S->C { Success, Rebirth?, Error? }:
	--   attempt outcome; a fresh RebirthState always follows.
	RebirthAction = 'RebirthAction',
	RebirthState = 'RebirthState',
	RebirthResult = 'RebirthResult',
	-- ArenaCombatEvent S->C (server presentation feed only):
	--   { SessionId, StageGeneration?, Event: 'CombatStarted'
	--   | 'CombatantSpawned' | 'Attack' | 'CombatantDied'
	--   | 'Victory' | 'Defeat' | 'ArenaHit', ...event fields }.
	--   'ArenaHit' is THE single authoritative impact packet,
	--   fired at contact and broadcast to every client:
	--   { AttackerId, AttackerTeam, TargetId, TargetTeam,
	--   Damage, ImpactPosition (Vector3, may be absent
	--   headless), AttackIndex (anim 1-5), SoundIndex (1-3
	--   cycle), AttackSequence, OwnerUserId }. Clients present
	--   VFX/sound/number/camera from it instantly; nothing in
	--   it is ever trusted inbound.
	ArenaCombatEvent = 'ArenaCombatEvent',
	-- Event start/stop transition cinematic (server-authoritative
	-- presentation feed, broadcast to EVERY client in the server):
	-- Prepare S->C { Phase = 'Prepare', Kind = 'Start' | 'End',
	--   EventId, TransitionId, FovMultiplier, FovSeconds,
	--   FlashDelaySeconds, FlashInSeconds, FadeOutSeconds,
	--   CoverSeconds }: begin FOV zoom + white flash now; the
	--   server performs the world change after CoverSeconds.
	-- Reveal S->C { Phase = 'Reveal', Kind, EventId,
	--   TransitionId }: the world change is committed; fade the
	--   white out and ease FOV back. Clients never decide event
	--   state (attributes stay the source of truth); unmatched
	--   TransitionIds are ignored, so joins/misses can't stick.
	EventTransition = 'EventTransition',
	-- Bat PvP (server-authoritative knockback/ragdoll interaction):	-- BatSwing C->S with NO payload (empty fire = "I swung"). The
	-- server resolves the equipped Bat, cooldown, hitbox, and
	-- targets itself; the confirmed-hit sound is server-mounted on
	-- the target (no hit VFX by design), so no hit-result remote
	-- exists by design.
	BatSwing = 'BatSwing',
	-- Carry tool lock (server-authoritative gameplay-Tool gate):
	-- CarryLock S->C { Locked: boolean }, pushed on CHANGE only
	-- from the committed CarryRegistry feed (any carry/steal start
	-- locks, any release unlocks). The client mirrors it for
	-- Backpack/hotbar prevention; the server ALSO unequips at Set
	-- time and gates every server-activated Tool on IsCarrying,
	-- so forged activation can never bypass it.
	CarryLock = 'CarryLock',
	-- Tutorial (server-authoritative first-time onboarding):
	-- TutorialAction C->S { Action: 'State' | 'Continue' }:
	--   'State' requests a fresh snapshot; 'Continue' reports
	--   the locally-observed Arena Continue press (accepted
	--   ONLY while the server itself holds ArenaEnded for that
	--   player — never trusted blindly).
	-- TutorialState S->C: { Step, EggId?, AnimalId?, SlotId?,
	--   BaseId? }. Step drives text/arrow/highlight/overlay;
	--   ids resolve live models through the server-moved
	--   TutorialTarget CollectionService tag.
	TutorialAction = 'TutorialAction',
	TutorialState = 'TutorialState',
	-- Redeem codes (server-authoritative: the client sends ONLY
	-- the typed string, the server resolves everything from
	-- CodesConfig):
	-- CodesAction C->S { Action: 'Redeem', Code: string }: the
	--   ONLY client input. Reward/cash/egg/tool/animal data is
	--   NEVER accepted — the server normalizes, validates, grants
	--   through the canonical services, and persists redemption.
	-- CodesResult S->C { Success, Reason?, Message?,
	--   RewardText? }: per-request outcome for UI state (clear
	--   the TextBox on success, restore Continue). Player-facing
	--   text + SFX travel on the existing Notify channel, never
	--   here — this result is presentation state only.
	CodesAction = 'CodesAction',
	CodesResult = 'CodesResult',
	-- Daily rewards (server-authoritative streak system: the
	-- client sends ONLY intent, the server decides the day):
	-- DailyRewardsAction C->S { Action: 'State' | 'Claim',
	--   Day?: number }: 'State' requests the authoritative
	--   snapshot (current day, claimability, countdown anchor,
	--   per-day reward descriptors); 'Claim' requests the
	--   server-computed claimable day. A client-sent Day is
	--   UX/debug only and NEVER authoritative.
	-- DailyRewardsState S->C { Day, ClaimableDay?, CanClaim,
	--   NextClaimAt, LastClaimAt, DayCount, Days: [{ Day,
	--   Rewards }] }: presentation snapshot (also pushed after
	--   every claim). Rewards carry server-resolved display
	--   data; the client never calculates eligibility.
	-- DailyRewardsResult S->C { Success, Reason?, Message?,
	--   Day?, RewardText? }: per-claim outcome for UI state.
	--   Player-facing text + SFX travel on Notify, never here.
	DailyRewardsAction = 'DailyRewardsAction',
	DailyRewardsState = 'DailyRewardsState',
	DailyRewardsResult = 'DailyRewardsResult',
	-- Playtime rewards (server-authoritative session courses:
	-- the client sends ONLY intent, the server decides pool,
	-- playtime, and eligibility from its session clock):
	-- PlaytimeRewardsAction C->S { Action: 'State' | 'Claim',
	--   Index?: number }: 'State' requests the authoritative
	--   snapshot (pool, playtime, per-milestone states);
	--   'Claim' requests milestone Index. A client-sent Index
	--   is validated but NEVER authoritative, and no
	--   playtime/reward/pool field is ever accepted.
	-- PlaytimeRewardsState S->C { PoolId, DayId, Playtime,
	--   Completed, Version, Rewards: [{ Index,
	--   RequiredPlaytime, State, Cash?, Eggs?, Tools?,
	--   Animals? }] }: presentation snapshot (also pushed
	--   after every claim and at threshold crossings).
	-- PlaytimeRewardsResult S->C { Success, Reason?, Message?,
	--   Index?, RewardText?, State? }: per-claim outcome.
	--   Player-facing text + SFX travel on Notify, never here.
	PlaytimeRewardsAction = 'PlaytimeRewardsAction',
	PlaytimeRewardsState = 'PlaytimeRewardsState',
	PlaytimeRewardsResult = 'PlaytimeRewardsResult',
	-- Client presentation settings (no gameplay effect):
	-- SaveSettings C->S { Bgm?: number, Sfx?: number,
	--   FastMode?: boolean } — clamped/validated server-side,
	--   written to the profile on change (debounced client-side).
	-- SettingsState S->C { Bgm, Sfx, FastMode } — pushed on load
	-- so the Settings UI restores saved positions.
	SaveSettings = 'SaveSettings',
	SettingsState = 'SettingsState',
	-- Robux Shop housekeeping (server-authoritative; purchases
	-- themselves travel client->MarketplaceService, receipts
	-- resolve server-side with no client input):
	-- ShopAction C->S { Action: 'SyncGamepass' }: re-resolve
	--   the 2X Money gamepass entitlement after an in-session
	--   purchase dialog closes (join path syncs automatically).
	-- ShopResult S->C { Action, Success, Owned? }: sync outcome
	--   for client state decisions. Player-facing text + SFX
	--   travel on Notify, never here.
	ShopAction = 'ShopAction',
	ShopResult = 'ShopResult',
	-- NOTE: the TAB player list uses NATIVE Roblox leaderstats
	-- (player.leaderstats, maintained server-side by
	-- TabListService) — no custom remote, no custom UI. The
	-- native CoreGui PlayerList renders it. SEPARATE from the
	-- global money-only physical board.
}

-- A signal fired locally when the Remotes folder is wired up. On the
-- server this fires synchronously in bootstrap. On the client this
-- fires when WaitForChild returns the folder (after the server has
-- created it).
Remotes.Ready = Signal.new()

-- The folder instance once known.
local folderRef: Folder? = nil

-- --- Folder lifecycle ---------------------------------------------

function Remotes.SetRemotes(folder: Folder)
	folderRef = folder
	Remotes.Ready:Fire()
end

function Remotes.GetFolder(): Folder
	if not folderRef then
		-- Try to find it (suitable for server before SetRemotes was called,
		-- or for client waiting on replication).
		local candidate = ReplicatedStorage:FindFirstChild('Remotes')
		if candidate and candidate:IsA('Folder') then
			folderRef = candidate
		else
			error('Remotes folder not wired up; call SetRemotes first or wait for replication')
		end
	end
	return folderRef :: Folder
end

-- Block until the folder is available. Client-side helper.
function Remotes.WaitForReady(): Folder
	if folderRef then
		return folderRef :: Folder
	end
	if RunService:IsServer() then
		-- Server: the folder should already be there if bootstrap ran.
		return Remotes.GetFolder()
	end
	-- Client: wait for replication.
	local folder = ReplicatedStorage:WaitForChild('Remotes', 10)
	if not folder then
		error('Remotes folder did not replicate from server within 10s')
	end
	assert(folder:IsA('Folder'), 'ReplicatedStorage.Remotes must be a Folder')
	folderRef = folder
	Remotes.Ready:Fire()
	return folder :: Folder
end

-- --- Typed wrappers ------------------------------------------------

-- Server-side fire. Validation only — never trust client payloads.
function Remotes.FireClient(player: Player, remoteName: string, payload: any)
	Debug.Log('RM', '> FireClient', { to = player.Name, remote = remoteName, payload = type(payload) })
	Validation.t.instanceOf('Player')(player)
	Validation.t.string(remoteName)
	local folder = Remotes.GetFolder()
	local remote = folder:FindFirstChild(remoteName)
	if not remote then
		Debug.Log('RM', 'FireClient: remote not found, throwing')
		error(string.format('Remote %q not found', remoteName))
	end
	if not remote:IsA('RemoteEvent') then
		Debug.Log('RM', 'FireClient: not RemoteEvent, throwing')
		error(string.format('Remote %q is not a RemoteEvent', remoteName))
	end
	local re = remote
	re:FireClient(player, payload)
	Debug.Log('RM', '< FireClient ok')
end

-- Server-side broadcast. Same validation as FireClient, for
-- presentation events every client must observe (e.g. Arena
-- hit impacts: each client presents locally, distance-cut).
function Remotes.FireAllClients(remoteName: string, payload: any)
	Validation.t.string(remoteName)
	local folder = Remotes.GetFolder()
	local remote = folder:FindFirstChild(remoteName)
	if not remote then
		error(string.format('Remote %q not found', remoteName))
	end
	if not remote:IsA('RemoteEvent') then
		error(string.format('Remote %q is not a RemoteEvent', remoteName))
	end
	(remote :: RemoteEvent):FireAllClients(payload)
end

-- Client-side subscription. Returns a Signal that fires with the
-- payload each time the server pushes.
function Remotes.OnClientEvent(remoteName: string)
	Validation.t.string(remoteName)
	local folder = Remotes.WaitForReady()
	local remote = folder:WaitForChild(remoteName, 10)
	if not remote or not remote:IsA('RemoteEvent') then
		error(string.format('Remote %q did not replicate', remoteName))
	end
	-- remote is a RemoteEvent (verified above). Wrap its OnClientEvent
	-- signal so callers can subscribe with a normal sleitnick Signal.
	local signal = remote.OnClientEvent
	return Signal.Wrap(signal)
end

return Remotes
