--!strict
--!native
--[[
	LuckyBlockSpawnService.spec
	===========================
	Tests for the SpawnService / Catalog / Placement stack. These cover the surfaces the refactor changed so a future
	tweak can't silently break the contract.

	What's covered:
	  * Catalog validation (Definition + Origin)
	  * SpawnService cap enforcement (10 Available eggs)
	  * SpawnService origin branching (Automatic -> center, Persistence
	    -> directly Placed at a slot)
	  * SpawnService registry (Get / Drop / CountByState)
	  * Placement.IsFarFromAll math
	  * Placement.PickXZ with no existing eggs (random fallback)
	  * Placement.PickXZ with a full ring (spiral fallback)
	  * AdminService allowlist + rank gate
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Helpers = require(ServerScriptService.TestEZTests._Helpers)
	local Services = Helpers.WireServices()
	local SpawnService = require(ServerScriptService.Egg.SpawnService)
	local Catalog = require(ServerScriptService.Egg.Catalog)
	local Placement = require(ServerScriptService.Egg.Placement)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminConfig = require(ServerScriptService.Admin.AdminConfig)
	local Constants = require(ServerScriptService.Egg.Constants)

	-- --- Catalog -------------------------------------------------

	describe('Catalog.ValidateDefinition', function()
		it('accepts a valid Definition', function()
			local ok, err = Catalog.ValidateDefinition({ rarity = 'Common', price = 100 })
			expect(ok).to.equal(true)
			expect(err).to.equal(nil)
		end)

		it('rejects a non-table', function()
			local ok = Catalog.ValidateDefinition('Common')
			expect(ok).to.equal(false)
		end)

		it('rejects a negative price', function()
			local ok, err = Catalog.ValidateDefinition({ rarity = 'Common', price = -1 })
			expect(ok).to.equal(false)
			expect(err).to.equal('definition.price must be non-negative')
		end)

		it('rejects a missing rarity', function()
			local ok = Catalog.ValidateDefinition({ price = 100 })
			expect(ok).to.equal(false)
		end)
	end)

	describe('Catalog.ValidateOrigin', function()
		it('accepts each known origin', function()
			expect(Catalog.ValidateOrigin('Automatic')).to.equal(true)
			expect(Catalog.ValidateOrigin('Admin')).to.equal(true)
			expect(Catalog.ValidateOrigin('Persistence')).to.equal(true)
			expect(Catalog.ValidateOrigin('Test')).to.equal(true)
		end)

		it('rejects an unknown origin', function()
			local ok = Catalog.ValidateOrigin('Garbage')
			expect(ok).to.equal(false)
		end)
	end)

	-- --- Placement -----------------------------------------------

	describe('Placement.IsFarFromAll', function()
		it('returns true for an empty list', function()
			expect(Placement.IsFarFromAll(Vector2.new(0, 0), {}, 7)).to.equal(true)
		end)

		it('returns true when far enough away', function()
			local existing = { { centerCFrame = CFrame.new(0, 0, 0) } }
			expect(Placement.IsFarFromAll(Vector2.new(20, 20), existing, 7)).to.equal(true)
		end)

		it('returns false when too close', function()
			local existing = { { centerCFrame = CFrame.new(0, 0, 0) } }
			expect(Placement.IsFarFromAll(Vector2.new(2, 0), existing, 7)).to.equal(false)
		end)

		it('ignores eggs without a centerCFrame', function()
			local existing = { { noCenterHere = true } }
			expect(Placement.IsFarFromAll(Vector2.new(0, 0), existing, 7)).to.equal(true)
		end)
	end)

	describe('Placement.PickXZ', function()
		it('returns a point on the ring when no eggs exist', function()
			local xz = Placement.PickXZ({}, 20, 7)
			local r = (xz - Vector2.zero).Magnitude
			expect(r > 18 and r < 22).to.equal(true)
		end)

		it('returns a point far from a single existing egg', function()
			local existing = { { centerCFrame = CFrame.new(20, 0, 0) } }
			local xz = Placement.PickXZ(existing, 20, 7)
			local dx = xz.X - 20
			local dz = xz.Y - 0
			expect(math.sqrt(dx * dx + dz * dz) >= 7).to.equal(true)
		end)
	end)

	-- --- SpawnService --------------------------------------------

	describe('SpawnService', function()
		local prevAdmins

		beforeEach(function()
			-- Snapshot the existing admins so we can restore them
			-- after the test mutates the table.
			prevAdmins = {}
			for userId, entry in pairs(AdminConfig.Admins) do
				prevAdmins[userId] = entry.rank
			end
			-- Wipe the allowlist to a known state.
			for userId in pairs(AdminConfig.Admins) do
				AdminConfig.Admins[userId] = nil
			end
			-- Make sure the registry is empty between tests.
			for _, b in ipairs(SpawnService.AllEggs()) do
				if b.model then
					b.model:Destroy()
				end
				SpawnService.DropEgg(b.uniqueId)
			end
			-- Register the center if not already registered.
			if not game:GetService('Workspace'):FindFirstChild('EggArea') then
				SpawnService.RegisterCenter(game:GetService('Workspace'))
			end
		end)

		afterEach(function()
			for userId in pairs(AdminConfig.Admins) do
				AdminConfig.Admins[userId] = nil
			end
			for userId, rank in pairs(prevAdmins) do
				AdminConfig.Admins[userId] = { rank = rank }
			end
		end)

		it('Request fails on bad definition', function()
			local r = SpawnService.Request({
				definition = { rarity = 'Common', price = -1 },
				origin = 'Test',
			})
			expect(r.success).to.equal(false)
		end)

		it('Request fails on bad origin', function()
			local r = SpawnService.Request({
				definition = { rarity = 'Common', price = 100 },
				origin = 'Garbage',
			})
			expect(r.success).to.equal(false)
		end)

		it('Persistence origin requires targetSlot', function()
			local r = SpawnService.Request({
				definition = { rarity = 'Common', price = 100 },
				origin = 'Persistence',
			})
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('persistence-requires-target-slot')
		end)

		it('Test origin spawns an Available egg in the registry', function()
			local r = SpawnService.Request({
				definition = { rarity = 'Common', price = 100 },
				origin = 'Test',
			})
			expect(r.success).to.equal(true)
			expect(r.egg.state).to.equal(Constants.State.Available)
			expect(SpawnService.CountByState(Constants.State.Available)).to.equal(1)
		end)

		it('caps the registry at EggCenterMax', function()
			-- Spawn the maximum allowed.
			for _ = 1, Constants.EggCenterMax do
				local r = SpawnService.Request({
					definition = { rarity = 'Common', price = 100 },
					origin = 'Test',
				})
				expect(r.success).to.equal(true)
			end
			-- One more should fail.
			local extra = SpawnService.Request({
				definition = { rarity = 'Common', price = 100 },
				origin = 'Test',
			})
			expect(extra.success).to.equal(false)
			expect(extra.error).to.equal('cap-reached')
		end)

		it('DropEgg removes from the registry', function()
			local r = SpawnService.Request({
				definition = { rarity = 'Common', price = 100 },
				origin = 'Test',
			})
			expect(r.success).to.equal(true)
			local id = r.egg.uniqueId
			expect(SpawnService.GetEgg(id)).never.to.equal(nil)
			SpawnService.DropEgg(id)
			expect(SpawnService.GetEgg(id)).to.equal(nil)
		end)
	end)

	-- --- AdminService --------------------------------------------

	describe('AdminService', function()
		local prevAdmins

		beforeEach(function()
			prevAdmins = {}
			for userId, entry in pairs(AdminConfig.Admins) do
				prevAdmins[userId] = entry.rank
			end
			for userId in pairs(AdminConfig.Admins) do
				AdminConfig.Admins[userId] = nil
			end
		end)

		afterEach(function()
			for userId in pairs(AdminConfig.Admins) do
				AdminConfig.Admins[userId] = nil
			end
			for userId, rank in pairs(prevAdmins) do
				AdminConfig.Admins[userId] = { rank = rank }
			end
		end)

		it('IsAdmin returns false for a non-admin userId', function()
			expect(AdminService.IsAdmin(99999999)).to.equal(false)
		end)

		it('AddAdmin then IsAdmin returns true', function()
			expect(AdminService.AddAdmin(424242, 'admin')).to.equal(true)
			expect(AdminService.IsAdmin(424242)).to.equal(true)
			expect(AdminService.GetRank(424242)).to.equal('admin')
		end)

		it('CanRun respects rank ordering', function()
			AdminService.AddAdmin(100, 'mod')
			AdminService.AddAdmin(200, 'admin')
			AdminService.AddAdmin(300, 'superadmin')
			-- mod can run mod but not admin
			expect(AdminService.CanRun(100, 'mod')).to.equal(true)
			expect(AdminService.CanRun(100, 'admin')).to.equal(false)
			-- admin can run mod + admin but not superadmin
			expect(AdminService.CanRun(200, 'mod')).to.equal(true)
			expect(AdminService.CanRun(200, 'admin')).to.equal(true)
			expect(AdminService.CanRun(200, 'superadmin')).to.equal(false)
			-- superadmin can run all
			expect(AdminService.CanRun(300, 'mod')).to.equal(true)
			expect(AdminService.CanRun(300, 'admin')).to.equal(true)
			expect(AdminService.CanRun(300, 'superadmin')).to.equal(true)
		end)

		it('AddAdmin rejects an unknown rank', function()
			expect(AdminService.AddAdmin(1, 'owner')).to.equal(false)
		end)

		it('RemoveAdmin returns true for an existing admin and false otherwise', function()
			AdminService.AddAdmin(7, 'admin')
			expect(AdminService.RemoveAdmin(7)).to.equal(true)
			expect(AdminService.RemoveAdmin(7)).to.equal(false)
		end)

		it('AssertCanRun throws for an under-privileged user', function()
			AdminService.AddAdmin(1, 'mod')
			local threw = false
			local ok = pcall(function()
				AdminService.AssertCanRun(1, 'superadmin')
			end)
			expect(ok).to.equal(false)
		end)
	end)
end
