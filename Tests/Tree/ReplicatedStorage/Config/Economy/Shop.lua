--!strict
--!native
--[[
	CANONICAL CONFIG (unified architecture).
	This module is the single source of truth for its domain; the legacy
	flat config under ReplicatedStorage.Config is a deprecated shim.
	New code must require this canonical path.
	Values below are preserved exactly from the pre-migration configs.
	Do NOT rebalance here without a gameplay review.
]]
--[[
	Shop
	==========
	Single registry for ALL monetization product identities.
	IDs live here and nowhere else: server receipt routing,
	client Shop buy buttons, and audit logs all resolve
	through this table.

	Sections:
	  * DeveloperProducts: keyed by feature key; each entry
	    carries ProductId, Robux, Kind (dispatch), and the
	    kind-specific payload (Multiplier / GearId / Amount).
	  * ByProductId: reverse lookup built below (server receipt
	    router uses it; duplicate ProductIds are a boot error).
	  * Gamepasses: same treatment for gamepass entitlements.
	  * ServerLuck: durations per multiplier for temporary
	    luck boosts. DESIGNER-OWNED: tune freely, services
	    never hardcode durations.

	Money pack amounts: derived from the live economy
	(StartingMoney = 5000; Common egg = 100) as a roughly
	value-scaling ladder with bulk bonus. DESIGNER: confirm
	these before launch — they are sane but unapproved.
]]

local Shop = {}

export type ProductEntry = {
	Key: string,
	ProductId: number,
	Robux: number,
	Kind: string, -- 'Money' | 'Gear' | 'ServerLuck' | 'UnlockDoors' | 'SkipDaily' | 'SkipPlaytime'
	Amount: string?, -- Money: BigNumber grant string
	GearId: string?, -- Gear: GearConfig id
	Multiplier: number?, -- ServerLuck: luck multiplier
}

Shop.ProductKind = {
	Money = 'Money',
	Gear = 'Gear',
	ServerLuck = 'ServerLuck',
	UnlockDoors = 'UnlockDoors',
	SkipDaily = 'SkipDaily',
	SkipPlaytime = 'SkipPlaytime',
}

-- ProductId -> entry (built + de-duplicated below).
Shop.DeveloperProducts = {
	ServerLuck2x = {
		Key = 'ServerLuck2x',
		ProductId = 3715397847,
		Robux = 99,
		Kind = 'ServerLuck',
		Multiplier = 2,
	},
	UnlockDoors = {
		Key = 'UnlockDoors',
		ProductId = 3715397812,
		Robux = 29,
		Kind = 'UnlockDoors',
	},
	ServerLuck4x = {
		Key = 'ServerLuck4x',
		ProductId = 3715398478,
		Robux = 199,
		Kind = 'ServerLuck',
		Multiplier = 4,
	},
	GalaxyBat = {
		Key = 'GalaxyBat',
		ProductId = 3715398070,
		Robux = 199,
		Kind = 'Gear',
		GearId = 'GalaxyBat',
	},
	ServerLuck8x = {
		Key = 'ServerLuck8x',
		ProductId = 3715398723,
		Robux = 499,
		Kind = 'ServerLuck',
		Multiplier = 8,
	},
	-- DESIGNER: confirm amounts (derived ladder, unapproved).
	MoneyPack1 = {
		Key = 'MoneyPack1',
		ProductId = 3715397862,
		Robux = 19,
		Kind = 'Money',
		Amount = '10000',
	},
	MoneyPack2 = {
		Key = 'MoneyPack2',
		ProductId = 3715397884,
		Robux = 49,
		Kind = 'Money',
		Amount = '50000',
	},
	MoneyPack3 = {
		Key = 'MoneyPack3',
		ProductId = 3715397918,
		Robux = 99,
		Kind = 'Money',
		Amount = '250000',
	},
	MoneyPack4 = {
		Key = 'MoneyPack4',
		ProductId = 3715397931,
		Robux = 199,
		Kind = 'Money',
		Amount = '500000',
	},
	MoneyPack5 = {
		Key = 'MoneyPack5',
		ProductId = 3715397968,
		Robux = 249,
		Kind = 'Money',
		Amount = '1000000',
	},
	SkipPlaytime = {
		Key = 'SkipPlaytime',
		ProductId = 3716261541,
		Robux = 149,
		Kind = 'SkipPlaytime',
	},
	SkipDaily = {
		Key = 'SkipDaily',
		ProductId = 3716261585,
		Robux = 249,
		Kind = 'SkipDaily',
	},
}

Shop.Gamepasses = {
	Money2x = {
		Key = 'Money2x',
		GamepassId = 2002490328,
		Robux = 199,
	},
}

-- Temporary luck boost durations, seconds per multiplier.
-- DESIGNER-OWNED: set the exact live values here. Services
-- read them at purchase time; no duration is hardcoded in
-- service logic.
Shop.ServerLuckDurations = {
	[2] = 900,
	[4] = 600,
	[8] = 300,
}

-- Reverse lookup: ProductId -> entry. Duplicate ProductIds
-- are a configuration error (loud warn; first entry wins so
-- receipts stay deterministic).
Shop.ByProductId = {} :: { [number]: ProductEntry }
do
	local seen: { [number]: string } = {}
	for key, entry in pairs(Shop.DeveloperProducts) do
		if type(entry.ProductId) == 'number' then
			if seen[entry.ProductId] ~= nil then
				warn(
					('[Shop] duplicate ProductId %d (keys %s, %s); first wins'):format(
						entry.ProductId,
						tostring(seen[entry.ProductId]),
						tostring(key)
					)
				)
			else
				seen[entry.ProductId] = tostring(key)
				Shop.ByProductId[entry.ProductId] = entry
			end
		end
	end
end

function Shop.FindProduct(productId: number): ProductEntry?
	if type(productId) ~= 'number' then
		return nil
	end
	return Shop.ByProductId[productId]
end

-- Studio card-path -> product key, for Shop cards whose Buy
-- buttons carry neither a ProductId attribute nor a
-- product-key name (e.g. Money/Row1/1). Paths are relative
-- to the Shop ScrollingFrame, computed by walking up from
-- the clicked Buy button. Cards with ambiguous semantics
-- (Events/1 Server Luck single-card-vs-three-products,
-- Passes/4 VIP, Items/2 + Featured/StarterPack) stay UNMAPPED
-- on purpose: guessing a charge is worse than a loud error,
-- and no such products exist in this config. Either map them
-- here once identified (with a real Creator Dashboard ID
-- behind the product), or stamp a ProductId number attribute
-- on the button in Studio (attribute wins).
Shop.CardMap = {
	['Money/Row1/1'] = 'MoneyPack1',
	['Money/Row1/2'] = 'MoneyPack2',
	['Money/Row1/3'] = 'MoneyPack3',
	['Money/Row2/4'] = 'MoneyPack4',
	['Money/Row2/5'] = 'MoneyPack5',
	-- Passes/5 is the 2X Money gamepass card: Money2x is the
	-- ONLY gamepass in this config, and the client routes
	-- gamepass entries to PromptGamePassPurchase.
	['Passes/5'] = 'Money2x',
	-- Items/1 is the Galaxy Bat card: GalaxyBat is the ONLY
	-- Gear-kind Developer Product here, routed to
	-- PromptProductPurchase like every other product.
	['Items/1'] = 'GalaxyBat',
}

return table.freeze(Shop)
