--!strict
--!native
--[[
	NotificationService.spec
	========================
	Tests for the ONE canonical player-feedback system
	(ServerScriptService/Base/NotificationService.lua):
	warnings (WarningMessages catalog) + successes
	(SuccessMessages catalog) through one delivery path.

	What this spec locks in:
	  A. Warning ids resolve to short player-friendly text (no
	     dev terminology, no internals); dynamic {Amount} uses
	     server data; unknown ids fall back to General_Generic.
 	  B. Success ids resolve with server data; unknown success
 	     ids resolve to nil (never fabricate a success).
 	  C. Entity names escape always and rarity-color via
 	     RarityConfig when the authoritative rarity resolves.
 	  D. Silent/Internal severities never deliver.
 	  E. Warnings throttle (same id suppressed, burst capped,
 	     per-player isolated); successes NEVER throttle — each
 	     commit sends exactly once, even rapid repeats.
 	  F. NotifyWarning/NotifySuccess never throw (nil player,
 	     unwired ref) and report delivery.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local Helpers = require(script.Parent._Helpers)
	local NotificationService = require(ServerScriptService.Base.NotificationService)

	describe('NotificationService catalogs', function()
		it('resolves catalog warnings verbatim', function()
			expect(NotificationService.GetWarningText('Buy_Carrying', nil)).to.equal(
				"You can't buy while carrying something. Place it down first."
			)
			expect(NotificationService.GetWarningText('Steal_OwnAnimal', nil)).to.equal(
				"You can't steal your own Animal."
			)
			expect(NotificationService.GetWarningText('Lock_NotOwner', nil)).to.equal('This base is locked.')
		end)

		it('dynamic Amount uses server data in HUD format', function()
			expect(NotificationService.GetWarningText('Buy_InsufficientCash', { Amount = '25000' })).to.equal(
				'You need $25.0K more to buy this Egg.'
			)
			expect(NotificationService.GetWarningText('Upgrade_InsufficientCash', { Amount = '157.351936' })).to.equal(
				'You need $157.3 more to upgrade.'
			)
		end)

		it('renders raw money-pack amounts, never $0 (Shop_MoneyPack regression)', function()
			-- Shop money packs pass the RAW BigNumber string;
			-- a preformatted '$10K' value fails sanitize and
			-- renders as '$0'. Lock the raw contract for every
			-- pack magnitude.
			expect(NotificationService.GetSuccessText('Shop_MoneyPack', { Amount = '10000' })).to.equal(
				'Money added!$10.0K'
			)
			expect(NotificationService.GetSuccessText('Shop_MoneyPack', { Amount = '50000' })).to.equal(
				'Money added!$50.0K'
			)
			expect(NotificationService.GetSuccessText('Shop_MoneyPack', { Amount = '250000' })).to.equal(
				'Money added!$250.0K'
			)
			expect(NotificationService.GetSuccessText('Shop_MoneyPack', { Amount = '500000' })).to.equal(
				'Money added!$500.0K'
			)
			expect(NotificationService.GetSuccessText('Shop_MoneyPack', { Amount = '1000000' })).to.equal(
				'Money added!$1.0M'
			)
		end)

		it('explains a purchased-open door to the locking owner', function()
			expect(NotificationService.GetWarningText('Lock_PurchasedOpen', nil)).to.equal(
				'This door was opened by a purchase and stays open for now.'
			)
		end)

		it('unknown warning ids fall back to General_Generic', function()
			expect(NotificationService.GetWarningText('NoSuchId', nil)).to.equal("You can't do that right now.")
			expect(NotificationService.GetWarningText(nil, nil)).to.equal("You can't do that right now.")
		end)

		it('resolves success ids with server data (plain without rarity)', function()
			expect(NotificationService.GetSuccessText('Buy_Success', { EggName = 'Lucky Egg' })).to.equal(
				'Bought Lucky Egg!'
			)
			expect(NotificationService.GetSuccessText('Upgrade_Success', { AnimalName = 'Boneca', Level = 6 })).to.equal(
				'Boneca upgraded to Level 6!'
			)
			expect(NotificationService.GetSuccessText('Sell_Success', { Name = 'Boneca', Amount = '3000' })).to.equal(
				'Sold Boneca for $3.0K!'
			)
			expect(NotificationService.GetSuccessText('Lock_Success', nil)).to.equal('Base locked for ?s!')
			expect(NotificationService.GetSuccessText('Lock_Success', { Duration = 60 })).to.equal(
				'Base locked for 60s!'
			)
			expect(NotificationService.GetSuccessText('Hatch_Success', { AnimalName = 'Dog' })).to.equal(
				'You hatched Dog!'
			)
			expect(NotificationService.GetSuccessText('Arrival_Success', { AnimalName = 'Dog' })).to.equal(
				'Dog joined your base!'
			)
		end)

		it('rarity-colors entity names, surrounding copy stays white', function()
			expect(NotificationService.GetSuccessText('Hatch_Success', { AnimalName = 'Dog', Rarity = 'Legendary' })).to.equal(
				'You hatched <font color="#F5C846">Dog</font>!'
			)
			expect(NotificationService.GetSuccessText('Buy_Success', { EggName = 'Egg', Rarity = 'Common' })).to.equal(
				'Bought <font color="#B4B4B4">Egg</font>!'
			)
			expect(NotificationService.GetSuccessText('Arrival_Success', { AnimalName = 'Cat', Rarity = 'Secret' })).to.equal(
				'<font color="#FFFFFF">Cat</font> joined your base!'
			)
		end)

		it('escapes markup in names and falls back on unknown rarity', function()
			expect(
				NotificationService.GetSuccessText('Hatch_Success', { AnimalName = '<b>Dog</b>', Rarity = 'Legendary' })
			).to.equal('You hatched <font color="#F5C846">&lt;b&gt;Dog&lt;/b&gt;</font>!')
			expect(NotificationService.GetSuccessText('Hatch_Success', { AnimalName = 'Dog', Rarity = 'NotARarity' })).to.equal(
				'You hatched Dog!'
			)
			expect(NotificationService.GetSuccessText('Buy_Success', {})).to.equal('Bought Egg!')
		end)

		it('unknown success ids resolve to nil (never fabricate)', function()
			expect(NotificationService.GetSuccessText('NoSuchId', nil)).to.equal(nil)
			expect(NotificationService.GetSuccessText(nil, nil)).to.equal(nil)
		end)

		it('warning text carries no internals', function()
			for _, id in ipairs({ 'Buy_Carrying', 'Steal_BaseFull', 'Upgrade_MaxLevel', 'General_Generic' }) do
				local text = NotificationService.GetWarningText(id, nil)
				expect(string.find(text, 'RemoteEvent') == nil).to.equal(true)
				expect(string.find(text, 'Service') == nil).to.equal(true)
			end
		end)
	end)

	describe('NotificationService delivery', function()
		local sent: { any } = {}

		beforeEach(function()
			Helpers.StubRemotes()
			sent = {}
			NotificationService._TestReset()
			NotificationService.SetPlayerService({
				Notify = function(player: any, category: string, text: string)
					sent[#sent + 1] = { userId = (player :: any).UserId, category = category, text = text }
				end,
			})
		end)

		afterEach(function()
			NotificationService._TestReset()
			NotificationService.SetPlayerService(nil)
		end)

		it('delivers a warning with the Warning category', function()
			local p = Helpers.FakePlayer(62001)
			expect(NotificationService.NotifyWarning(p, 'Lock_NotOwner', nil)).to.equal(true)
			expect(#sent).to.equal(1)
			expect(sent[1].category).to.equal('Warning')
			expect(sent[1].text).to.equal('This base is locked.')
		end)

		it('delivers a success with the Reward category', function()
			local p = Helpers.FakePlayer(62002)
			expect(NotificationService.NotifySuccess(p, 'Lock_Success', nil)).to.equal(true)
			expect(#sent).to.equal(1)
			expect(sent[1].category).to.equal('Reward')
			expect(sent[1].text).to.equal('Base locked!')
		end)

		it('suppresses the same warning spammed in a row', function()
			local p = Helpers.FakePlayer(62003)
			expect(NotificationService.NotifyWarning(p, 'Lock_NotOwner', nil)).to.equal(true)
			expect(NotificationService.NotifyWarning(p, 'Lock_NotOwner', nil)).to.equal(false)
			expect(#sent).to.equal(1)
		end)

		it('never suppresses legitimate repeated successes', function()
			local p = Helpers.FakePlayer(62004)
			expect(NotificationService.NotifySuccess(p, 'Buy_Success', { EggName = 'Egg A' })).to.equal(true)
			expect(NotificationService.NotifySuccess(p, 'Buy_Success', { EggName = 'Egg B' })).to.equal(true)
			expect(NotificationService.NotifySuccess(p, 'Buy_Success', { EggName = 'Egg A' })).to.equal(true)
			expect(#sent).to.equal(3)
		end)

		it('never delivers Silent or Internal severities', function()
			local p = Helpers.FakePlayer(62005)
			expect(NotificationService.NotifyWarning(p, 'Buy_InProgress', nil)).to.equal(false)
			expect(NotificationService.NotifyWarning(p, 'Buy_ServiceNotReady', nil)).to.equal(false)
			expect(NotificationService.NotifyWarning(p, 'Collect_EmptyPool', nil)).to.equal(false)
			expect(#sent).to.equal(0)
		end)

		it('never delivers unknown success ids', function()
			local p = Helpers.FakePlayer(62006)
			expect(NotificationService.NotifySuccess(p, 'NoSuchId', nil)).to.equal(false)
			expect(#sent).to.equal(0)
		end)

		it('per-player isolation: one spammer does not mute another', function()
			local a = Helpers.FakePlayer(62007)
			local b = Helpers.FakePlayer(62008)
			expect(NotificationService.NotifyWarning(a, 'Lock_NotOwner', nil)).to.equal(true)
			expect(NotificationService.NotifyWarning(a, 'Lock_NotOwner', nil)).to.equal(false)
			expect(NotificationService.NotifyWarning(b, 'Lock_NotOwner', nil)).to.equal(true)
			expect(#sent).to.equal(2)
		end)

		it('never throws and reports false without a wired ref', function()
			NotificationService.SetPlayerService(nil)
			local p = Helpers.FakePlayer(62009)
			expect(NotificationService.NotifyWarning(p, 'Lock_NotOwner', nil)).to.equal(false)
			expect(NotificationService.NotifySuccess(p, 'Lock_Success', nil)).to.equal(false)
			expect(NotificationService.NotifyWarning(nil, 'Lock_NotOwner', nil)).to.equal(false)
			expect(#sent).to.equal(0)
		end)
	end)
end
