--!strict
--!native
--[[
	DoorService.spec
	================
	Paid door opening against REAL BaseService/BaseLockService
	(headless Studio parts, same setup as BaseLockTimer.spec):

	  * Lock -> OpenDoorPrompt appears on the base Collector
	    with ownerUserId + doorPrompt markers
	  * Unlock -> prompt destroyed (idempotent)
	  * RefreshBase on unknown bases never throws
	  * RequestOpen fail-closes on non-player callers
	  * GrantPendingUnlock with no player resolves terminally
	    without throwing

	Live purchase dialogs, distance checks with real
	characters, and receipt retries are Studio-verified.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local Workspace = game:GetService('Workspace')

	local Helpers = require(script.Parent._Helpers)
	local BaseLockService = require(ServerScriptService.Base.BaseLockService)
	local DoorService = require(ServerScriptService.Shop.DoorService)

	local A = 7301

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
		BaseLockService.Init()
		DoorService.Init()
	end

	local function collectorOf(): BasePart?
		local base = services.BaseService.GetBaseByOwner(A)
		if type(base) ~= 'table' then
			return nil
		end
		local collector = base.collector
		if typeof(collector) == 'Instance' and collector:IsA('BasePart') then
			return collector
		end
		return nil
	end

	local function doorPrompt(): ProximityPrompt?
		local collector = collectorOf()
		if collector == nil then
			return nil
		end
		for _, child in ipairs((collector :: BasePart):GetChildren()) do
			if child:IsA('ProximityPrompt') and child.Name == 'OpenDoorPrompt' then
				return child
			end
		end
		return nil
	end

	describe('DoorService prompt lifecycle', function()
		beforeEach(function()
			setup()
			DoorService._TestReset()
			DoorService.Init()
			-- Start unlocked: destroy leftovers deterministically.
			local base = services.BaseService.GetBaseByOwner(A)
			if base ~= nil then
				BaseLockService.Unlock(base.id)
			end
		end)

		afterEach(function()
			local base = services.BaseService.GetBaseByOwner(A)
			if base ~= nil then
				BaseLockService.Unlock(base.id)
			end
			DoorService._TestReset()
		end)

		it('creates the Open Door prompt on lock with owner markers', function()
			local base = services.BaseService.GetBaseByOwner(A)
			expect(base).to.be.ok()
			expect(doorPrompt()).to.equal(nil)
			expect(BaseLockService.Lock(base)).to.equal(true)
			local prompt = doorPrompt()
			expect(prompt).to.be.ok()
			expect((prompt :: ProximityPrompt).ActionText).to.equal('Open Door')
			expect((prompt :: ProximityPrompt):GetAttribute('ownerUserId')).to.equal(A)
			expect((prompt :: ProximityPrompt):GetAttribute('doorPrompt')).to.equal(true)
		end)

		it('destroys the prompt on unlock, idempotently', function()
			local base = services.BaseService.GetBaseByOwner(A)
			BaseLockService.Lock(base)
			expect(doorPrompt()).to.be.ok()
			BaseLockService.Unlock(base.id)
			expect(doorPrompt()).to.equal(nil)
			BaseLockService.Unlock(base.id)
			expect(doorPrompt()).to.equal(nil)
		end)

		it('RefreshBase on unknown bases never throws', function()
			expect(function()
				DoorService.RefreshBase('Base_999')
				DoorService.RefreshBase('')
				DoorService.RefreshBase(nil :: any)
			end).to.never.throw()
		end)

		it('RequestOpen fail-closes on non-player callers', function()
			local base = services.BaseService.GetBaseByOwner(A)
			BaseLockService.Lock(base)
			local prompt = doorPrompt()
			expect(prompt).to.be.ok()
			expect(DoorService.RequestOpen(nil :: any, prompt)).to.equal(false)
			expect(DoorService.RequestOpen({} :: any, prompt)).to.equal(false)
		end)

		it('GrantPendingUnlock with no player resolves without throwing', function()
			expect(DoorService.GrantPendingUnlock(nil)).to.equal(true)
		end)

		it('GrantPendingUnlock opens the base and records a per-buyer grant; the owner can still re-lock', function()
			local B = 7302
			local base = services.BaseService.GetBaseByOwner(A)
			expect(BaseLockService.Lock(base)).to.equal(true)
			expect(BaseLockService.IsLocked(base.id)).to.equal(true)
			DoorService._TestSetPending(B, { baseId = base.id, ownerId = A, at = os.clock() })
			local buyer: any = { UserId = B }
			expect(DoorService.GrantPendingUnlock(buyer)).to.equal(true)
			-- Immediately open: state, per-buyer grant, prompt gone.
			expect(BaseLockService.IsLocked(base.id)).to.equal(false)
			expect(BaseLockService.IsPurchasedOpen(base.id)).to.equal(true)
			expect(BaseLockService.HasPurchasedAccess(base.id, B)).to.equal(true)
			expect(BaseLockService.HasPurchasedAccess(base.id, 99999)).to.equal(false)
			expect(doorPrompt()).to.equal(nil)
			-- The owner RETAINS lock control after a purchase: a
			-- paid grant never disables the lock button. The buyer
			-- keeps passthrough via their own grant (no one else
			-- does), so re-locking does not revoke it.
			expect(BaseLockService.Lock(base)).to.equal(true)
			expect(BaseLockService.IsLocked(base.id)).to.equal(true)
			expect(BaseLockService.HasPurchasedAccess(base.id, B)).to.equal(true)
			expect(BaseLockService.IsPurchasedOpen(base.id)).to.equal(true)
			-- Repeat receipt delivery is idempotent: same grant,
			-- still consistent, no stuck state.
			DoorService._TestSetPending(B, { baseId = base.id, ownerId = A, at = os.clock() })
			expect(DoorService.GrantPendingUnlock(buyer)).to.equal(true)
			expect(BaseLockService.HasPurchasedAccess(base.id, B)).to.equal(true)
			-- Base release/reassign resets the door slate: grants
			-- clear and the next owner locks normally.
			BaseLockService.HandleBaseReleased(base.id)
			expect(BaseLockService.IsPurchasedOpen(base.id)).to.equal(false)
			expect(BaseLockService.HasPurchasedAccess(base.id, B)).to.equal(false)
			expect(BaseLockService.Lock(base)).to.equal(true)
			expect(BaseLockService.IsLocked(base.id)).to.equal(true)
		end)

		it('GrantPendingUnlock on a raced-open base still records the grant', function()
			local B = 7304
			local base = services.BaseService.GetBaseByOwner(A)
			expect(BaseLockService.Lock(base)).to.equal(true)
			DoorService._TestSetPending(B, { baseId = base.id, ownerId = A, at = os.clock() })
			-- Timer (or another buyer's grant) opened the base
			-- between prompt and receipt: same owner, buyer still
			-- a non-owner, so the paid grant is recorded instead
			-- of consumed silently.
			BaseLockService.Unlock(base.id)
			local buyer: any = { UserId = B }
			expect(DoorService.GrantPendingUnlock(buyer)).to.equal(true)
			expect(BaseLockService.HasPurchasedAccess(base.id, B)).to.equal(true)
			BaseLockService.HandleBaseReleased(base.id)
		end)

		it('GrantPendingUnlock consumes stale contexts without opening a stranger base', function()
			local B = 7303
			local base = services.BaseService.GetBaseByOwner(A)
			BaseLockService.Lock(base)
			local buyer: any = { UserId = B }
			-- Unknown base: consumed, victim base untouched.
			DoorService._TestSetPending(B, { baseId = 'Base_999', ownerId = A, at = os.clock() })
			expect(DoorService.GrantPendingUnlock(buyer)).to.equal(true)
			expect(BaseLockService.IsLocked(base.id)).to.equal(true)
			-- Ownership changed mid-purchase: consumed, never
			-- opens the new situation.
			DoorService._TestSetPending(B, { baseId = base.id, ownerId = 12345, at = os.clock() })
			expect(DoorService.GrantPendingUnlock(buyer)).to.equal(true)
			expect(BaseLockService.IsLocked(base.id)).to.equal(true)
			expect(BaseLockService.IsPurchasedOpen(base.id)).to.equal(false)
		end)
	end)
end
