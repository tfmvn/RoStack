--!strict
--!native
--[[
	EggSpawnNotify.spec
	====================
	Canonical EggSpawned event + high-rarity threshold:

	  * ShouldNotify is true exactly for Legendary and above
	    (Legendary/Mythic/Divine/Secret), false for everything
	    below and for garbage input
	  * EggSpawned fires once per Fire with the payload intact
	    (one event per egg, no debounce, no batching)
	  * the RareEgg_Spawned catalog entry exists with an
	    {EggName} placeholder (unknown ids would send nothing)
	  * RareEggNotifier.Start is idempotent and never throws

	Delivery itself (per-player toast) goes through the
	existing NotifySuccess pipeline, which is a tested path;
	these specs lock the threshold + event contract.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local EggSpawned = require(ServerScriptService.Egg.EggSpawned)
	local RareEggNotifier = require(ServerScriptService.Egg.RareEggNotifier)
	local SuccessMessages = require(ReplicatedStorage.Config.Presentation.Messages).Success

	describe('RareEggNotifier.ShouldNotify', function()
		it('celebrates Legendary and above only', function()
			expect(RareEggNotifier.ShouldNotify('Common')).to.equal(false)
			expect(RareEggNotifier.ShouldNotify('Uncommon')).to.equal(false)
			expect(RareEggNotifier.ShouldNotify('Rare')).to.equal(false)
			expect(RareEggNotifier.ShouldNotify('Epic')).to.equal(false)
			expect(RareEggNotifier.ShouldNotify('Legendary')).to.equal(true)
			expect(RareEggNotifier.ShouldNotify('Mythic')).to.equal(true)
			expect(RareEggNotifier.ShouldNotify('Divine')).to.equal(true)
			expect(RareEggNotifier.ShouldNotify('Secret')).to.equal(true)
		end)

		it('rejects garbage without throwing', function()
			expect(function()
				expect(RareEggNotifier.ShouldNotify(nil)).to.equal(false)
				expect(RareEggNotifier.ShouldNotify('' :: any)).to.equal(false)
				expect(RareEggNotifier.ShouldNotify('legendary' :: any)).to.equal(false)
				expect(RareEggNotifier.ShouldNotify(42 :: any)).to.equal(false)
			end).to.never.throw()
		end)
	end)

	describe('EggSpawned event', function()
		it('fires once per Fire with the payload intact', function()
			local calls: { any } = {}
			local conn = EggSpawned.Connect(function(info: any)
				calls[#calls + 1] = info
			end)
			expect(conn).to.be.ok()
			EggSpawned.Fire({ uniqueId = 'EG_test1', rarity = 'Mythic', origin = 'Test' })
			EggSpawned.Fire({ uniqueId = 'EG_test2', rarity = 'Common', origin = 'Test' })
			expect(#calls).to.equal(2)
			expect(calls[1].uniqueId).to.equal('EG_test1')
			expect(calls[1].rarity).to.equal('Mythic')
			expect(calls[2].rarity).to.equal('Common')
			if conn then
				pcall(function()
					(conn :: RBXScriptConnection):Disconnect()
				end)
			end
		end)
	end)

	describe('RareEgg_Spawned catalog entry', function()
		it('exists with an EggName placeholder', function()
			local found: any = nil
			for _, entry in ipairs(SuccessMessages) do
				if type(entry) == 'table' and entry.Id == 'RareEgg_Spawned' then
					found = entry
					break
				end
			end
			expect(found).to.be.ok()
			expect(string.find(found.Message, '{EggName}', 1, true) ~= nil).to.equal(true)
		end)

		it('RareEggNotifier.Start is idempotent and never throws', function()
			expect(function()
				RareEggNotifier.Start()
				RareEggNotifier.Start()
			end).to.never.throw()
		end)
	end)
end
