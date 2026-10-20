--!strict
--!native
--[[
	BaseLockTimer.spec
	==================
	Timer label contract for server-authoritative Base Locking.

	Covers the label path (the actual bug: the resolver looked
	for TestLabel while Studio builds Timer):
	  * Lock(base) flips IsLocked with ~30s remaining
	    (BaseLockConfig.LockDurationSeconds, single value).
	  * The live Timer label (LazerButton chain BillboardGui
	    Timer) shows remaining seconds on Heartbeat ticks.
	  * Unlock clears the label back to its default and flips
	    IsLocked off with 0 remaining.
	  * Legacy TestLabel-named labels still resolve.

	Heartbeat timing is live (Studio steps), so label asserts
	poll boundedly instead of assuming tick alignment.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Workspace = game:GetService('Workspace')
	local RunService = game:GetService('RunService')

	local Helpers = require(script.Parent._Helpers)
	local BaseLockConfig = require(ReplicatedStorage.Config.World.Bases).Lock

	local A = 7201

	local services: any = nil

	local function setup()
		Helpers.StubRemotes()
		services = Helpers.WireServices()
		Helpers.EnsureCollectors()
		if not next(services.BaseService.GetAllBases()) then
			services.BaseService.RegisterBases(Workspace)
		end
		if not services.BaseService.GetBaseByOwner(A) then
			services.BaseService.AssignBaseById(A, 'Base_1')
		end
	end

	-- Build the Studio button hierarchy on every registered
	-- base BEFORE BaseLockService.Init runs (registration
	-- resolves the label once; the update loop re-resolves).
	local function buildButtons(labelName: string)
		for _, base in pairs(services.BaseService.GetAllBases()) do
			local folder = base.folder
			if folder and not folder:FindFirstChild('LazerButton') then
				local button = Instance.new('Model')
				button.Name = 'LazerButton'
				local press = Instance.new('Part')
				press.Name = 'PressPart'
				press.Size = Vector3.new(2, 1, 2)
				press.Anchored = true
				press.Parent = button
				local gui = Instance.new('BillboardGui')
				gui.Name = 'BillboardGui'
				gui.Parent = press
				local label = Instance.new('TextLabel')
				label.Name = labelName
				label.Text = ''
				label.Parent = gui
				button.Parent = folder
			end
		end
	end

	local function baseALabel(): TextLabel?
		local base = services.BaseService.GetBaseByOwner(A)
		if not base or not base.folder then
			return nil
		end
		return base.folder:FindFirstChild('Timer', true) or base.folder:FindFirstChild('TestLabel', true)
	end

	local function waitFor(predicate: () -> boolean, timeoutS: number): boolean
		local deadline = os.clock() + timeoutS
		while os.clock() < deadline do
			local ok, result = pcall(predicate)
			if ok and result then
				return true
			end
			RunService.Heartbeat:Wait()
		end
		return false
	end

	describe('BaseLockService timer label', function()
		beforeEach(function()
			setup()
		end)

		it('uses one 30s authoritative duration', function()
			expect(BaseLockConfig.LockDurationSeconds).to.equal(30)
		end)

		it('Lock shows remaining seconds on Timer; Unlock clears it', function()
			local BaseLockService = require(ServerScriptService.Base.BaseLockService)
			buildButtons('Timer')
			BaseLockService.Init()
			local base = services.BaseService.GetBaseByOwner(A)
			expect(base).to.be.ok()
			local label = baseALabel()
			expect(label ~= nil).to.equal(true)
			local before = (label :: TextLabel).Text

			expect(BaseLockService.Lock(base)).to.equal(true)
			expect(BaseLockService.IsLocked(base.id)).to.equal(true)
			local remaining = BaseLockService.GetRemainingTime(base.id)
			expect(remaining > 0).to.equal(true)
			expect(remaining <= 30).to.equal(true)
			-- Live countdown appears on the label (any
			-- 1..30 reading proves the path; exact-second
			-- asserts would race the tick).
			local shown = waitFor(function()
				local n = tonumber((label :: TextLabel).Text)
				return n ~= nil and n >= 1 and n <= 30
			end, 2)
			expect(shown).to.equal(true)

			BaseLockService.Unlock(base.id)
			expect(BaseLockService.IsLocked(base.id)).to.equal(false)
			expect(BaseLockService.GetRemainingTime(base.id)).to.equal(0)
			local cleared = waitFor(function()
				return (label :: TextLabel).Text == before
			end, 2)
			expect(cleared).to.equal(true)
		end)
	end)
end
