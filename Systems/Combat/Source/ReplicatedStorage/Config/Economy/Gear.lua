--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	Single source of truth for its domain. New code must require this path.
	Values preserved exactly from the pre-migration configs - do NOT rebalance
	without a gameplay review. See Docs/configuration/ for domain docs.
]]
-- Gear: shop catalog + per-bat combat tuning (merged BatConfig).
-- Balance gears here. Combat blocks live on each bat via Gear.Combat.
--[[
	Gear
	==========
	Data-driven Gear Shop catalog. Each entry is display data +
	purchase rules; the server re-resolves everything from Id.

PLACEHOLDER BALANCE (tune before release): Price /
  Description below are initial values, not final balance.
  RequiredRebirth gates each gear on the player's completed
  Rebirth count (RebirthService.GetRebirth, read live by
  GearShopService.GetPlayerRebirth): a gear with
  RequiredRebirth N becomes purchasable once the player
  completes Rebirth N. This ladder IS the gear unlock system —
  Rebirth UI previews reuse it, never a copy.

	Conventions:
	  * Id: stable identifier, never shown to players.
	  * ToolName: EXACT Tool Instance name under
	    ServerStorage.Assets.Ui.GearShop.Tools (display Name may
	    change freely without touching the mapping).
	  * Price: BigNumber decimal STRING (never a number).
	  * Order in this list IS the shop display order.
]]

export type GearEntry = {
	Id: string,
	Name: string,
	Price: string,
	Description: string,
	RequiredRebirth: number,
	ToolName: string,
	RobuxOnly: boolean?,
}

local ENTRIES: { GearEntry } = {
	{
		Id = 'SpeedCoil',
		Name = 'Speed Coil',
		Price = '500',
		Description = 'PLACEHOLDER: run faster while held.',
		RequiredRebirth = 0,
		ToolName = 'Speed Coil',
	},
	{
		Id = 'SilverBat',
		Name = 'Silver Bat',
		Price = '1000',
		Description = 'PLACEHOLDER: jump higher while held.',
		RequiredRebirth = 0,
		ToolName = 'Silver Bat',
	},
	{
		Id = 'GravityCoil',
		Name = 'Gravity Coil',
		Price = '5000',
		Description = 'PLACEHOLDER: manipulate gravity while held.',
		RequiredRebirth = 1,
		ToolName = 'Gravity Coil',
	},
	{
		Id = 'GoldBat',
		Name = 'Gold Bat',
		Price = '7500',
		Description = 'PLACEHOLDER: speed and gravity in one tool.',
		RequiredRebirth = 1,
		ToolName = 'Gold Bat',
	},
	{
		Id = 'CoilCombo',
		Name = 'Coil Combo',
		Price = '20000',
		Description = 'PLACEHOLDER: speed and gravity in one tool.',
		RequiredRebirth = 2,
		ToolName = 'Coil Combo',
	},
	{
		Id = 'DiamondBat',
		Name = 'Diamond Bat',
		Price = '25000',
		Description = 'PLACEHOLDER: speed and gravity in one tool.',
		RequiredRebirth = 2,
		ToolName = 'Diamond Bat',
	},
	{
		Id = 'ObsidianBat',
		Name = 'Obsidian Bat',
		Price = '30000',
		Description = 'PLACEHOLDER: speed and gravity in one tool.',
		RequiredRebirth = 3,
		ToolName = 'Obsidian Bat',
	},
	{
		Id = 'CrystalBat',
		Name = 'Crystal Bat',
		Price = '50000',
		Description = 'PLACEHOLDER: speed and gravity in one tool.',
		RequiredRebirth = 4,
		ToolName = 'Crystal Bat',
	},
	{
		Id = 'InvisibleCloak',
		Name = 'Invisible Cloak',
		Price = '55000',
		Description = 'PLACEHOLDER: become invisible while held.',
		RequiredRebirth = 4,
		ToolName = 'Invisible Cloak',
	},
	{
		Id = 'HackerBat',
		Name = 'Hacker Bat',
		Price = '70000',
		Description = 'PLACEHOLDER: speed and gravity in one tool.',
		RequiredRebirth = 5,
		ToolName = 'Hacker Bat',
	},
	{
		-- Robux-only special: never purchasable with cash
		-- (GearShopService.Purchase rejects RobuxOnly entries).
		-- Granted exclusively through the Shop Developer
		-- Product receipt (ShopService -> GrantRobuxGear) and
		-- re-granted on join from the persisted entitlement.
		-- Requires the Studio Tool asset at
		-- ServerStorage.Assets.Ui.GearShop.Tools/'Galaxy Bat';
		-- without it, grants fail loudly and receipts retry.
		Id = 'GalaxyBat',
		Name = 'Galaxy Bat',
		Price = '0',
		Description = 'Robux-exclusive bat. Granted by the Shop Galaxy Bat product.',
		RequiredRebirth = 0,
		ToolName = 'Galaxy Bat',
		RobuxOnly = true,
	},
	{
		-- Default starting bat: every player owns and equips
		-- this on join, no purchase/unlock/gamepass/rebirth.
		-- Granted + equipped by GearShopService.OnPlayerReady
		-- (safe fallback while auto-buy resolves, and whenever
		-- auto-buy cannot afford anything). Never removed from
		-- ownership; buying other bats never deletes it.
		-- Requires the Studio Tool asset at
		-- ServerStorage.Assets.Ui.GearShop.Tools/'Default Bat'.
		Id = 'DefaultBat',
		Name = 'Default Bat',
		Price = '0',
		Description = 'Your trusty starting bat. Always available.',
		RequiredRebirth = 0,
		ToolName = 'Default Bat',
	},
}

local Gear = {}

-- Shop preview viewport framing (GearShopController): distance =
-- max(bbox * Factor, Min), viewed along Direction from the model
-- center. Added by the configuration pass; values preserved
-- exactly. Presentation only.
Gear.Viewport = {
	DistanceFactor = 1.4,
	MinDistance = 2,
	Direction = Vector3.new(1, 0.6, 1.6),
}

function Gear.GetAll(): { GearEntry }
	return ENTRIES
end

function Gear.FindGear(id: string): GearEntry?
	if type(id) ~= 'string' then
		return nil
	end
	for _, entry in ipairs(ENTRIES) do
		if entry.Id == id then
			return entry
		end
	end
	return nil
end

function Gear.IsLocked(playerRebirth: number, required: number): boolean
	if type(playerRebirth) ~= 'number' or type(required) ~= 'number' then
		return true
	end
	return playerRebirth < required
end

-- Pure validation over an entry list. The tool probe
-- returns true (valid Tool), 'wrong-class' (Instance exists
-- under the exact ToolName but is not a Tool), or falsy
-- (missing). Returns an array of issue strings; empty = valid.
function Gear.ValidateList(entries: any, toolProbe: ((string) -> any)?): { string }
	local issues: { string } = {}
	if type(entries) ~= 'table' then
		issues[#issues + 1] = 'catalog is not a table'
		return issues
	end
	local seen: { [string]: boolean } = {}
	for i, entry in ipairs(entries) do
		local where = 'entry ' .. tostring(i)
		if type(entry) ~= 'table' then
			issues[#issues + 1] = where .. ' is not a table'
			continue
		end
		if type(entry.Id) ~= 'string' or entry.Id == '' then
			issues[#issues + 1] = where .. ' has invalid Id'
		elseif seen[entry.Id] then
			issues[#issues + 1] = 'Duplicate GearId=' .. entry.Id
		else
			seen[entry.Id] = true
		end
		if type(entry.Name) ~= 'string' or entry.Name == '' then
			issues[#issues + 1] = where .. ' has invalid Name'
		end
		if type(entry.Description) ~= 'string' then
			issues[#issues + 1] = where .. ' has invalid Description'
		end
		if type(entry.Price) ~= 'string' or entry.Price == '' then
			issues[#issues + 1] = where .. ' has invalid Price'
		end
		if
			type(entry.RequiredRebirth) ~= 'number'
			or entry.RequiredRebirth < 0
			or entry.RequiredRebirth ~= math.floor(entry.RequiredRebirth)
		then
			issues[#issues + 1] = where .. ' has invalid RequiredRebirth'
		end
		if type(entry.ToolName) ~= 'string' or entry.ToolName == '' then
			issues[#issues + 1] = where .. ' has invalid ToolName'
		elseif toolProbe then
			local status = toolProbe(entry.ToolName)
			local path = 'ServerStorage.Assets.Ui.GearShop.Tools/' .. tostring(entry.ToolName)
			if status == 'wrong-class' then
				issues[#issues + 1] = 'Tool wrong class GearId='
					.. tostring(entry.Id)
					.. ' ToolName='
					.. tostring(entry.ToolName)
					.. ' path='
					.. path
					.. ' (expected Tool)'
			elseif status ~= true then
				issues[#issues + 1] = 'Missing Tool GearId='
					.. tostring(entry.Id)
					.. ' ToolName='
					.. tostring(entry.ToolName)
					.. ' path='
					.. path
			end
		end
	end
	return issues
end

function Gear.ValidateLive(): { string }
	local toolProbe = function(toolName: string): any
		local ok, status = pcall(function()
			local ServerStorage = game:GetService('ServerStorage')
			local assets = ServerStorage:FindFirstChild('Assets')
			local ui = assets and assets:FindFirstChild('Ui') or nil
			local shop = ui and ui:FindFirstChild('GearShop') or nil
			local tools = shop and shop:FindFirstChild('Tools') or nil
			local tool = tools and tools:FindFirstChild(toolName) or nil
			if tool == nil then
				return false
			end
			if tool:IsA('Tool') then
				return true
			end
			return 'wrong-class'
		end)
		if not ok then
			return false
		end
		return status
	end
	return Gear.ValidateList(ENTRIES, toolProbe)
end

-- --- Combat (former BatConfig; keyed by GearId AND Tool name) ---
--[[
	Combat
	=========
	Data-driven Bat PvP tuning. One entry per Bat Tool (keyed by the
	GearId AND by the granted Tool Instance name, which is the
	ToolName from GearConfig — e.g. 'Silver Bat').

	NOTE: no combat values existed anywhere in the project
	(GearConfig carries shop price/description only), so every
	number below is a NEW sensible default, clearly marked.
	Cooldown/knockback/ragdoll durations from the feature spec are
	used where given; the rest scale modestly by Bat tier.

	Server resolves everything from the equipped Tool (never trusts
	client-sent bat identity); the client reads SwingCooldown only
	for matching local input gating (server remains authoritative).
]]

export type BatHitbox = {
	Size: Vector3,
	Offset: CFrame,
}

export type BatKnockback = {
	Horizontal: number,
	Vertical: number,
}

export type BatEntry = {
	GearId: string,
	ToolName: string,
	SwingCooldown: number,
	Hitbox: BatHitbox,
	Knockback: BatKnockback,
	RagdollDuration: number,
	RagdollImmunity: number,
}

local COMBAT_ENTRIES: { BatEntry } = {
	{
		-- Default starting bat: deliberately the weakest
		-- (slowest swing, smallest hitbox). Every upgrade is
		-- strictly better, so progression always feels earned.
		GearId = 'DefaultBat',
		ToolName = 'Default Bat',
		SwingCooldown = 1.0,
		Hitbox = { Size = Vector3.new(4.5, 5, 5.5), Offset = CFrame.new(0, 0, -2.8) },
		Knockback = { Horizontal = 60, Vertical = 20 },
		RagdollDuration = 1.25,
		RagdollImmunity = 1.25,
	},
	{
		GearId = 'SilverBat',
		ToolName = 'Silver Bat',
		SwingCooldown = 0.8,
		Hitbox = { Size = Vector3.new(5, 5, 6), Offset = CFrame.new(0, 0, -3) },
		Knockback = { Horizontal = 70, Vertical = 25 },
		RagdollDuration = 1.5,
		RagdollImmunity = 1.25,
	},
	{
		GearId = 'GoldBat',
		ToolName = 'Gold Bat',
		SwingCooldown = 0.7,
		Hitbox = { Size = Vector3.new(5, 5, 6), Offset = CFrame.new(0, 0, -3) },
		Knockback = { Horizontal = 80, Vertical = 30 },
		RagdollDuration = 1.75,
		RagdollImmunity = 1.25,
	},
	{
		GearId = 'DiamondBat',
		ToolName = 'Diamond Bat',
		SwingCooldown = 0.65,
		Hitbox = { Size = Vector3.new(5.5, 5.5, 6.5), Offset = CFrame.new(0, 0, -3.2) },
		Knockback = { Horizontal = 90, Vertical = 35 },
		RagdollDuration = 2.0,
		RagdollImmunity = 1.25,
	},
	{
		GearId = 'ObsidianBat',
		ToolName = 'Obsidian Bat',
		SwingCooldown = 0.6,
		Hitbox = { Size = Vector3.new(5.5, 5.5, 6.5), Offset = CFrame.new(0, 0, -3.2) },
		Knockback = { Horizontal = 100, Vertical = 40 },
		RagdollDuration = 2.25,
		RagdollImmunity = 1.25,
	},
	{
		GearId = 'CrystalBat',
		ToolName = 'Crystal Bat',
		SwingCooldown = 0.55,
		Hitbox = { Size = Vector3.new(6, 6, 7), Offset = CFrame.new(0, 0, -3.5) },
		Knockback = { Horizontal = 115, Vertical = 45 },
		RagdollDuration = 2.5,
		RagdollImmunity = 1.25,
	},
	{
		GearId = 'HackerBat',
		ToolName = 'Hacker Bat',
		SwingCooldown = 0.6,
		Hitbox = { Size = Vector3.new(5.5, 5.5, 6.5), Offset = CFrame.new(0, 0, -3.2) },
		Knockback = { Horizontal = 90, Vertical = 35 },
		RagdollDuration = 2.0,
		RagdollImmunity = 1.25,
	},
	{
		-- Robux Galaxy Bat: a normal catalog bat in every
		-- system (ownership, equip, respawn, combat). Paid
		-- item tuned just above CrystalBat; the Shop receipt
		-- grants into the shared GearShop ownership, never a
		-- parallel copy.
		GearId = 'GalaxyBat',
		ToolName = 'Galaxy Bat',
		SwingCooldown = 0.5,
		Hitbox = { Size = Vector3.new(6.5, 6.5, 7.5), Offset = CFrame.new(0, 0, -3.7) },
		Knockback = { Horizontal = 130, Vertical = 50 },
		RagdollDuration = 2.75,
		RagdollImmunity = 1.25,
	},
}

local ByGearId: { [string]: BatEntry } = {}
local ByToolName: { [string]: BatEntry } = {}
for _, entry in ipairs(COMBAT_ENTRIES) do
	ByGearId[entry.GearId] = entry
	ByToolName[entry.ToolName] = entry
end

local Combat = {}

function Combat.GetByGearId(gearId: string): BatEntry?
	if type(gearId) ~= 'string' then
		return nil
	end
	return ByGearId[gearId]
end

-- Server AND client entry-point: the equipped Tool Instance name
-- ('Silver Bat') resolves to its tuning. Never trusts client-sent ids.
function Combat.GetByToolName(toolName: string): BatEntry?
	if type(toolName) ~= 'string' then
		return nil
	end
	return ByToolName[toolName]
end

function Combat.All(): { BatEntry }
	local out: { BatEntry } = {}
	for _, entry in ipairs(COMBAT_ENTRIES) do
		out[#out + 1] = entry
	end
	return out
end

function Combat.Validate(): { string }
	local issues: { string } = {}
	for _, entry in ipairs(COMBAT_ENTRIES) do
		local prefix = 'Combat.' .. entry.GearId
		if type(entry.SwingCooldown) ~= 'number' or entry.SwingCooldown <= 0 then
			issues[#issues + 1] = prefix .. '.SwingCooldown must be a number > 0'
		end
		if type(entry.Knockback.Horizontal) ~= 'number' or entry.Knockback.Horizontal < 0 then
			issues[#issues + 1] = prefix .. '.Knockback.Horizontal must be a number >= 0'
		end
		if type(entry.Knockback.Vertical) ~= 'number' or entry.Knockback.Vertical < 0 then
			issues[#issues + 1] = prefix .. '.Knockback.Vertical must be a number >= 0'
		end
		if type(entry.RagdollDuration) ~= 'number' or entry.RagdollDuration <= 0 then
			issues[#issues + 1] = prefix .. '.RagdollDuration must be a number > 0'
		end
		if type(entry.RagdollImmunity) ~= 'number' or entry.RagdollImmunity < 0 then
			issues[#issues + 1] = prefix .. '.RagdollImmunity must be a number >= 0'
		end
	end
	return issues
end

-- Attach combat lookup to the gear catalog (single module).
table.freeze(Combat)
Gear.Combat = Combat

return table.freeze(Gear)
