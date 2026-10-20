--!strict
--!native
--[[
	EggLifecycle.spec
	=================
	Universal ambient lifecycle / rotation:

	  * lifetime config exists per rarity (all 8, positive)
	  * canonical price resolver (real prices, safe fallback)
	  * _spawnCenter stamps pool + _expireAt (Normal default,
	    Admin always Extra)
	  * normal cap enforced at 20; Extra (admin) bypasses it
	  * ExpireEgg reaps only past-deadline Available eggs
	    (Traveling/mutex/future-deadline untouched, model
	    destroyed + record dropped, dead-model records freed)
	  * SweepExpired collects exactly the due set
	  * cap constant is 20 (normal pool target)
	  * ServerLuck HUD formatter ("%.1fx", safe default)

	No threads are started here (never Start()); the sweep
	loop itself is production-wired in EggService.Start/Stop.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Workspace = game:GetService('Workspace')
	local StarterPlayer = game:GetService('StarterPlayer')

	local SpawnService = require(ServerScriptService.Egg.SpawnService)
	local Catalog = require(ServerScriptService.Egg.Catalog)
	local Constants = require(ServerScriptService.Egg.Constants)
	local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
	local CenterSpawn = require(ReplicatedStorage.Config.Creatures.Eggs).CenterSpawn
	local ServerLuckController = require(StarterPlayer.StarterPlayerScripts.ServerLuckController)

	local function cleanSlate()
		for _, b in ipairs(SpawnService.AllEggs()) do
			if b.model then
				pcall(function()
					(b.model :: Model):Destroy()
				end)
			end
			SpawnService.DropEgg(b.uniqueId)
		end
		if not Workspace:FindFirstChild('EggArea') then
			SpawnService.RegisterCenter(Workspace)
		end
	end

	local function spawnTestEgg(rarity: string, origin: string?, pool: string?): any
		local r = SpawnService.Request({
			definition = { rarity = rarity, price = EggConfig.Price[rarity] or 100 },
			origin = origin or Catalog.Origin.Test,
			pool = pool,
		})
		assert(r.success, 'test spawn must succeed')
		return r.egg
	end

	describe('EggLifecycle config', function()
		it('cap target is 10 across canonical readers', function()
			expect(CenterSpawn.CenterMax).to.equal(10)
			expect(Constants.EggCenterMax).to.equal(10)
		end)

		it('every rarity has a positive lifetime + sweep cadence', function()
			for _, rarity in ipairs({ 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Mythic', 'Divine', 'Secret' }) do
				local seconds = EggConfig.EggLifetimeSeconds[rarity]
				expect(type(seconds)).to.equal('number')
				expect(seconds > 0).to.equal(true)
			end
			expect(EggConfig.ExpirySweepSeconds >= 1).to.equal(true)
		end)

		it('ResolvePrice returns canonical prices with a safe fallback', function()
			expect(SpawnService.ResolvePrice('Legendary')).to.equal(EggConfig.Price['Legendary'])
			expect(SpawnService.ResolvePrice('Common')).to.equal(100)
			expect(SpawnService.ResolvePrice('Nope' :: any)).to.equal(100)
		end)
	end)

	describe('EggLifecycle spawn stamping', function()
		beforeEach(cleanSlate)
		afterEach(cleanSlate)

		it('Test spawn stamps Normal pool + rarity deadline', function()
			local before = os.clock()
			local egg = spawnTestEgg('Common')
			expect(egg.pool).to.equal('Normal')
			expect(type(egg._expireAt)).to.equal('number')
			expect(egg._expireAt >= before + EggConfig.EggLifetimeSeconds['Common'] - 1).to.equal(true)
			expect(SpawnService.CountNormalAvailable()).to.equal(1)
		end)

		it('Admin spawn stamps Extra pool', function()
			local egg = spawnTestEgg('Legendary', Catalog.Origin.Admin)
			expect(egg.pool).to.equal('Extra')
			expect(SpawnService.CountNormalAvailable()).to.equal(0)
			expect(SpawnService.CountByState(Constants.State.Available)).to.equal(1)
		end)
	end)

	describe('EggLifecycle cap semantics', function()
		beforeEach(cleanSlate)
		afterEach(cleanSlate)

		it('normal pool caps at 10 but admin overflows', function()
			for _ = 1, Constants.EggCenterMax do
				spawnTestEgg('Common', Catalog.Origin.Test)
			end
			expect(SpawnService.CountNormalAvailable()).to.equal(Constants.EggCenterMax)
			-- Normal/Test at cap: rejected.
			local extra = SpawnService.Request({
				definition = { rarity = 'Common', price = 100 },
				origin = Catalog.Origin.Test,
			})
			expect(extra.success).to.equal(false)
			expect(extra.error).to.equal('cap-reached')
			-- Admin at 10/10: succeeds as Extra.
			local admin = SpawnService.Request({
				definition = { rarity = 'Legendary', price = 50000 },
				origin = Catalog.Origin.Admin,
			})
			expect(admin.success).to.equal(true)
			expect(admin.egg.pool).to.equal('Extra')
			expect(SpawnService.CountNormalAvailable()).to.equal(Constants.EggCenterMax)
			expect(SpawnService.CountByState(Constants.State.Available)).to.equal(Constants.EggCenterMax + 1)
		end)

		it('explicit Extra pool bypasses the normal cap', function()
			for _ = 1, Constants.EggCenterMax do
				spawnTestEgg('Common', Catalog.Origin.Test)
			end
			local r = SpawnService.Request({
				definition = { rarity = 'Mythic', price = 25500 },
				origin = Catalog.Origin.Automatic,
				pool = 'Extra',
			})
			expect(r.success).to.equal(true)
			expect(SpawnService.CountNormalAvailable()).to.equal(Constants.EggCenterMax)
		end)
	end)

	describe('EggLifecycle expiry', function()
		beforeEach(cleanSlate)
		afterEach(cleanSlate)

		it('reaps a past-deadline Available egg completely', function()
			local egg = spawnTestEgg('Common')
			local model = egg.model
			egg._expireAt = os.clock() - 1
			expect(SpawnService.ExpireEgg(egg)).to.equal(true)
			expect(model.Parent).to.equal(nil)
			expect(SpawnService.GetEgg(egg.uniqueId)).to.equal(nil)
		end)

		it('leaves future-deadline eggs alone', function()
			local egg = spawnTestEgg('Common')
			egg._expireAt = os.clock() + 10000
			expect(SpawnService.ExpireEgg(egg)).to.equal(false)
			expect(SpawnService.GetEgg(egg.uniqueId)).to.be.ok()
		end)

		it('never reaps Traveling or mutex-held eggs', function()
			local traveling = spawnTestEgg('Rare')
			traveling.state = Constants.State.Traveling
			traveling._expireAt = os.clock() - 1000
			expect(SpawnService.ExpireEgg(traveling)).to.equal(false)
			expect(SpawnService.GetEgg(traveling.uniqueId)).to.be.ok()
			local held = spawnTestEgg('Epic')
			held._mutex = true
			held._expireAt = os.clock() - 1000
			expect(SpawnService.ExpireEgg(held)).to.equal(false)
			expect(SpawnService.GetEgg(held.uniqueId)).to.be.ok()
			expect(SpawnService.ExpireEgg(nil :: any)).to.equal(false)
		end)

		it('frees past-deadline records whose model is already gone', function()
			local egg = spawnTestEgg('Common')
			egg._expireAt = os.clock() - 1
			egg.model:Destroy()
			expect(SpawnService.ExpireEgg(egg)).to.equal(true)
			expect(SpawnService.GetEgg(egg.uniqueId)).to.equal(nil)
		end)

		it('SweepExpired collects exactly the due set', function()
			local due = spawnTestEgg('Common')
			due._expireAt = os.clock() - 1
			local fresh = spawnTestEgg('Common')
			fresh._expireAt = os.clock() + 10000
			expect(SpawnService.SweepExpired(nil)).to.equal(1)
			expect(SpawnService.GetEgg(due.uniqueId)).to.equal(nil)
			expect(SpawnService.GetEgg(fresh.uniqueId)).to.be.ok()
		end)
	end)

	describe('ServerLuck HUD format', function()
		it('formats canonical %.1fx with a safe default', function()
			expect(ServerLuckController._TestFormatLuck(1)).to.equal('1.0x')
			expect(ServerLuckController._TestFormatLuck(2)).to.equal('2.0x')
			expect(ServerLuckController._TestFormatLuck(4)).to.equal('4.0x')
			expect(ServerLuckController._TestFormatLuck(1.5)).to.equal('1.5x')
			expect(ServerLuckController._TestFormatLuck(nil :: any)).to.equal('1.0x')
			expect(ServerLuckController._TestFormatLuck('nope' :: any)).to.equal('1.0x')
		end)
	end)
end
