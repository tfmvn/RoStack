--!strict
--!native
--[[
	BaseServiceCollectorFacing.spec
	===============================
	Tests for the Collector-facing rotation applied to every
	slot at RegisterBases time.

	What we test:
	  1. A base with a Collector child has every slot rotated
	     to face the Collector (slot's +Z points AT the
	     Collector's position). The base record has
	     `collectorFacing` non-nil with the matching Yaw, and
	     `collector` pointing at the part itself.
	  2. A base WITHOUT a Collector is a FATAL startup error
	     (Phase 5). `RegisterBases` throws, and the message
	     names the exact missing path so an operator can fix
	     the place without reading the source. There is no
	     fallback: the Collector's placement encodes the
	     base's orientation, so guessing one would silently
	     mis-rotate every slot.
	  3. A Collector at the same XZ as the Spawn also throws,
	     but with its OWN message — the asset exists, so the
	     fix is to MOVE it, not to create one.
]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local ServerScriptService = game:GetService('ServerScriptService')
	local BaseService = require(ServerScriptService.BaseService)
	local Bases = require(ReplicatedStorage.Config.World.Bases)
	local BaseType = require(ReplicatedStorage.Types.BaseType)

	-- Build a `Base_<i>` folder with a Spawn, Slots, and an
	-- optional Collector at the given offset from the
	-- spawn. Returns the base folder, the spawn, the
	-- collector (or nil), and the slotsFolder.
	local function buildBaseFolder(basesFolder: Folder, index: number, collectorOffset: Vector3?)
		-- Tear down any prior folder so re-runs are clean.
		local prior = basesFolder:FindFirstChild(BaseType.BuildId(index))
		if prior then
			prior:Destroy()
		end
		local baseFolder = Instance.new('Folder')
		baseFolder.Name = BaseType.BuildId(index)
		baseFolder.Parent = basesFolder

		local spawn = Instance.new('Part')
		spawn.Name = 'Spawn'
		spawn.Size = Vector3.new(6, 1, 6)
		spawn.Anchored = true
		spawn.CFrame = CFrame.new(index * 40, 0.5, 0)
		spawn.Parent = baseFolder

		local slotsFolder = Instance.new('Folder')
		slotsFolder.Name = 'Slots'
		slotsFolder.Parent = baseFolder

		local collector: BasePart? = nil
		if collectorOffset then
			collector = Instance.new('Part')
			collector.Name = 'Collector'
			collector.Size = Vector3.new(6, 1, 6)
			collector.Anchored = true
			collector.CFrame = spawn.CFrame + collectorOffset
			collector.Parent = baseFolder
		end

		return baseFolder, spawn, collector, slotsFolder
	end

	-- Reset the workspace.Bases tree so each test starts
	-- from a clean slate. RegisterBases creates the
	-- `Bases` folder on first call; tear it down here so
	-- the test's pre-built Base_<i> folder is the one
	-- the function operates on.
	local function resetBasesTree()
		local workspace = game:GetService('Workspace')
		local prior = workspace:FindFirstChild('Bases')
		if prior then
			prior:Destroy()
		end
		return workspace
	end

	describe('BaseService.RegisterBases Collector-facing', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('rotates every slot to face the Collector (look-at semantics)', function()
			local workspace = resetBasesTree()
			local basesFolder = Instance.new('Folder')
			basesFolder.Name = 'Bases'
			basesFolder.Parent = workspace

			-- Collector 10 studs in +X from the spawn
			-- (in spawn's local frame, which is also the
			-- world frame here since spawn has no Yaw).
			-- The slot's +Z should point AT the Collector's
			-- position, so the slot's Yaw is
			-- atan2(10, 0) = +pi/2.
			local _, _, collector, _ = buildBaseFolder(basesFolder, 1, Vector3.new(10, 0, 0))
			expect(collector).to.be.ok()
			-- Bases 2..BaseCount are auto-created by
			-- RegisterBases and would each throw for want of a
			-- Collector, so give them the conventional one. This
			-- leaves Base_1's hand-built +X Collector alone,
			-- which is the one under test.
			Helpers.EnsureCollectors()

			Helpers.WireServices()
			game:GetService('ServerScriptService').BaseService.RegisterBases(workspace)

			local base = game:GetService('ServerScriptService').BaseService.GetBaseById(BaseType.BuildId(1))
			expect(base).to.be.ok()
			expect(base.collectorFacing).to.be.ok()
			-- The part itself is stashed too, so the flight
			-- destination math never re-walks the Workspace tree.
			expect(base.collector).to.equal(collector)

			-- `collectorFacing` is `CFrame.Angles(0, yaw, 0)`.
			-- The expected Yaw is atan2(10, 0) = +pi/2
			-- (the +X Collector is to the slot's local +Z
			-- when Yaw is +pi/2).
			local expectedYaw = math.atan2(10, 0)
			local _, actualYaw, _ = (base.collectorFacing :: CFrame):ToEulerAnglesYXZ()
			expect(actualYaw).to.be.near(expectedYaw, 0.001)

			-- Every slot's +Z (the opposite of LookVector,
			-- since LookVector = -Z for a flat CFrame) should
			-- point AT the Collector's position from the
			-- slot's position. Compare just the XZ direction
			-- via dot product. Use only the first three
			-- slots to keep the test tight.
			for i = 1, math.min(3, Bases.Slots.Count) do
				local slot = base.slots[i]
				expect(slot).to.be.ok()
				local slotPos = slot.part.Position
				local toCollector = (collector :: any).Position - slotPos
				local slotLook = slot.part.CFrame.LookVector
				-- Compare the XZ direction. If the slot's
				-- +Z (LookVector) is parallel to the
				-- direction-to-Collector, the dot product
				-- is 1.0 (slotLook points to the
				-- Collector, slotLook's opposite is
				-- slotLook * -1 ... actually we want the
				-- slot's +Z to point at the Collector, so
				-- the +Z direction is the OPPOSITE of
				-- slotLook. Use -LookVector.)
				local toCollectorXZ = Vector3.new(toCollector.X, 0, toCollector.Z)
				local slotForward = -Vector3.new(slotLook.X, 0, slotLook.Z)
				if toCollectorXZ.Magnitude < 0.001 then
					-- Collector is right above/below this
					-- slot — not testable here, skip.
					continue
				end
				local toCollectorN = toCollectorXZ.Unit
				local slotForwardN = slotForward.Unit
				local dot = toCollectorN:Dot(slotForwardN)
				expect(dot).to.be.near(1.0, 0.001)
			end
		end)

		it('throws, naming the base, when no Collector is present', function()
			local workspace = resetBasesTree()
			local basesFolder = Instance.new('Folder')
			basesFolder.Name = 'Bases'
			basesFolder.Parent = workspace

			-- Base_1 gets a Spawn and Slots but NO Collector.
			-- RegisterBases must refuse to boot rather than
			-- fall back to the spawn's rotation.
			buildBaseFolder(basesFolder, 1, nil)

			Helpers.WireServices()
			local ok, err = pcall(function()
				game:GetService('ServerScriptService').BaseService.RegisterBases(workspace)
			end)
			expect(ok).to.equal(false)
			local msg = tostring(err)
			-- The message must be actionable on its own: the
			-- exact path, and the recipe for the asset.
			expect(msg:find('Base_1', 1, true)).to.be.ok()
			expect(msg:find('Collector', 1, true)).to.be.ok()
			expect(msg:find('is missing', 1, true)).to.be.ok()
			expect(msg:find('base%-collector%.md')).to.be.ok()

			-- The base must NOT be half-registered.
			local base = game:GetService('ServerScriptService').BaseService.GetBaseById(BaseType.BuildId(1))
			expect(base).to.equal(nil)
		end)

		it('throws with a move-it message when the Collector shares the Spawn XZ', function()
			local workspace = resetBasesTree()
			local basesFolder = Instance.new('Folder')
			basesFolder.Name = 'Bases'
			basesFolder.Parent = workspace

			-- Collector at (0, +10, 0) from spawn — same XZ,
			-- only Y differs, so there is no XZ direction to
			-- derive a facing from. This is a DIFFERENT failure
			-- from "missing": the asset exists, so the message
			-- tells the operator to move it, not create it.
			buildBaseFolder(basesFolder, 1, Vector3.new(0, 10, 0))

			Helpers.WireServices()
			local ok, err = pcall(function()
				game:GetService('ServerScriptService').BaseService.RegisterBases(workspace)
			end)
			expect(ok).to.equal(false)
			local msg = tostring(err)
			expect(msg:find('Base_1', 1, true)).to.be.ok()
			expect(msg:find('shares the XZ position', 1, true)).to.be.ok()
			expect(msg:find('Move the Collector', 1, true)).to.be.ok()
			-- Distinctly NOT the missing-asset message.
			expect(msg:find('is missing', 1, true)).to.equal(nil)
		end)
	end)
end
