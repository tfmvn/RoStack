--!strict
--!native
--[[
	ShopConfig.spec
	===============
	Monetization registry integrity: every Developer Product
	resolves by ID, IDs are unique, gamepass + luck durations
	are present, and kinds carry their required payloads.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local ShopConfig = require(ReplicatedStorage.Config.Economy.Shop)

	describe('ShopConfig registry', function()
		it('resolves every listed product by ID with its kind payload', function()
			local seen: { [number]: boolean } = {}
			for key, entry in pairs(ShopConfig.DeveloperProducts) do
				expect(type(entry.ProductId)).to.equal('number')
				expect(seen[entry.ProductId]).to.equal(nil)
				seen[entry.ProductId] = true
				local resolved = ShopConfig.FindProduct(entry.ProductId)
				expect(resolved).to.be.ok()
				expect(resolved.Key).to.equal(key)
				if entry.Kind == ShopConfig.ProductKind.Money then
					expect(type(entry.Amount)).to.equal('string')
				elseif entry.Kind == ShopConfig.ProductKind.Gear then
					expect(type(entry.GearId)).to.equal('string')
				elseif entry.Kind == ShopConfig.ProductKind.ServerLuck then
					expect(type(entry.Multiplier)).to.equal('number')
				end
			end
		end)

		it('contains exactly the specified product IDs', function()
			for _, id in ipairs({
				3715397847,
				3715397812,
				3715398478,
				3715398070,
				3715398723,
				3715397862,
				3715397884,
				3715397918,
				3715397931,
				3715397968,
				3716261541,
				3716261585,
			}) do
				expect(ShopConfig.FindProduct(id)).to.be.ok()
			end
			expect(ShopConfig.FindProduct(1)).to.equal(nil)
			expect(ShopConfig.FindProduct('nope' :: any)).to.equal(nil)
		end)

		it('registers the 2X Money gamepass + luck durations', function()
			expect(ShopConfig.Gamepasses.Money2x.GamepassId).to.equal(2002490328)
			for _, mult in ipairs({ 2, 4, 8 }) do
				local duration = ShopConfig.ServerLuckDurations[mult]
				expect(type(duration)).to.equal('number')
				expect(duration > 0).to.equal(true)
			end
		end)

		it('CardMap resolves every mapped path to a real product entry', function()
			for path, key in pairs(ShopConfig.CardMap) do
				expect(type(key)).to.equal('string')
				local entry = ShopConfig.DeveloperProducts[key] or ShopConfig.Gamepasses[key]
				expect(entry).to.be.ok()
			end
		end)

		it('Passes/5 is the Money2x gamepass (PromptGamePassPurchase path)', function()
			expect(ShopConfig.CardMap['Passes/5']).to.equal('Money2x')
			local entry = ShopConfig.Gamepasses.Money2x
			expect(type(entry.GamepassId)).to.equal('number')
			expect(entry.GamepassId).to.equal(2002490328)
		end)

		it('Items/1 is the GalaxyBat product (PromptProductPurchase path)', function()
			expect(ShopConfig.CardMap['Items/1']).to.equal('GalaxyBat')
			local entry = ShopConfig.DeveloperProducts.GalaxyBat
			expect(type(entry.ProductId)).to.equal('number')
			expect(entry.ProductId).to.equal(3715398070)
			expect(entry.Kind).to.equal('Gear')
		end)

		it('ambiguous cards stay unmapped (no invented products)', function()
			-- Events/1 (one Server Luck card, three products),
			-- Passes/4 (VIP, no product), Items/2 +
			-- Featured/StarterPack (no product anywhere).
			-- Mapping any of these requires a real Creator
			-- Dashboard ID behind an actual product entry.
			expect(ShopConfig.CardMap['Events/1']).to.equal(nil)
			expect(ShopConfig.CardMap['Passes/4']).to.equal(nil)
			expect(ShopConfig.CardMap['Items/2']).to.equal(nil)
			expect(ShopConfig.CardMap['Featured/StarterPack']).to.equal(nil)
		end)
	end)
end
