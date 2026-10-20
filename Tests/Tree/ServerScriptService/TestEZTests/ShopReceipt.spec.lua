--!strict
--!native
--[[
	ShopReceipt.spec
	================
	Single receipt router contract (no Studio purchases):

	  * malformed receipt info resolves Granted (no retry loop)
	  * unknown ProductId resolves NotProcessedYet (loud retry)
	  * duplicate PurchaseId resolves Granted without
	    re-executing (prove: luck stays cancelled across replay)
	  * server-wide luck grants apply buyer-independently
	    (offline buyer still moves global luck)
	  * player-bound grants with no buyer resolve NotProcessedYet

	Full grant effects (money ledger, gear tools, skip-all
	rewards, door unlocks) run through the canonical services
	and are covered by their own specs + Studio tests.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local Helpers = require(script.Parent._Helpers)
	local ShopService = require(ServerScriptService.Shop.ShopService)
	local ServerLuckService = require(ServerScriptService.ServerLuckService)
	local ShopConfig = require(game:GetService('ReplicatedStorage').Config.Economy.Shop)

	local LUCK4X = 3715398478
	local MONEY1 = 3715397862

	describe('ShopService receipt routing', function()
		beforeEach(function()
			Helpers.StubRemotes()
			ShopService._TestReset()
			ServerLuckService._TestReset()
		end)

		afterEach(function()
			ShopService._TestReset()
			ServerLuckService._TestReset()
		end)

		it('malformed receipt info resolves Granted', function()
			expect(ShopService._TestHandleReceipt(nil)).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(ShopService._TestHandleReceipt({})).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
		end)

		it('unknown ProductId resolves NotProcessedYet', function()
			expect(ShopService._TestHandleReceipt({
				PurchaseId = 'shop-spec-unknown-1',
				PlayerId = 1,
				ProductId = 999999999,
			})).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
		end)

		it('luck grants apply without a buyer present', function()
			expect(ServerLuckService.GetLuck()).to.equal(1)
			local decision = ShopService._TestHandleReceipt({
				PurchaseId = 'shop-spec-luck-1',
				PlayerId = 987654321,
				ProductId = LUCK4X,
			})
			expect(decision).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(ServerLuckService.GetLuck()).to.equal(4)
		end)

		it('duplicate PurchaseIds resolve without re-executing', function()
			local info = {
				PurchaseId = 'shop-spec-dupe-1',
				PlayerId = 987654321,
				ProductId = LUCK4X,
			}
			expect(ShopService._TestHandleReceipt(info)).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(ServerLuckService.GetLuck()).to.equal(4)
			-- Cancel the boost out-of-band, then replay the
			-- same receipt: dedupe must NOT re-activate it.
			ServerLuckService.SetLuck(1)
			expect(ServerLuckService.GetLuck()).to.equal(1)
			expect(ShopService._TestHandleReceipt(info)).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(ServerLuckService.GetLuck()).to.equal(1)
		end)

		it('player-bound grants with no buyer resolve NotProcessedYet', function()
			expect(ShopService._TestHandleReceipt({
				PurchaseId = 'shop-spec-money-1',
				PlayerId = 987654321,
				ProductId = MONEY1,
			})).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
		end)

		it('door grants with no buyer resolve NotProcessedYet (never consume blind)', function()
			-- Leave-mid-dialog: the pending context survives
			-- leave, so retry fulfills on rejoin instead of
			-- eating the purchase.
			expect(ShopService._TestHandleReceipt({
				PurchaseId = 'shop-spec-door-1',
				PlayerId = 987654321,
				ProductId = 3715397812,
			})).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
		end)

		it('every ShopConfig product maps to a handled kind', function()
			local kinds: { [string]: boolean } = {}
			for _, entry in pairs(ShopConfig.DeveloperProducts) do
				kinds[entry.Kind] = true
			end
			for _, kind in ipairs({ 'Money', 'Gear', 'ServerLuck', 'UnlockDoors', 'SkipDaily', 'SkipPlaytime' }) do
				expect(kinds[kind]).to.equal(true)
			end
		end)
	end)
end
