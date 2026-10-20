--!strict
--!native
--[[
	CollectFeedback.spec
	====================
	Tests for the instant cash-collection feedback module
	(ServerScriptService/Base/CollectFeedback.lua).

	What this spec locks in:
	  A. ComputePressedCFrame moves PressPart toward Base
	     along the button's OWN local Y by PRESS_FRACTION of
	     the projected gap — never a hardcoded world offset,
	     never sideways.
	  B. Degenerate gaps (Base level with / above PressPart)
	     return the rest transform (press skipped).
	  C. The rest transform is never mutated by the math.
	  D. Play is total: nil player / bad slot / missing
	     assets never throw and report which effects fired.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local CollectFeedback = require(ServerScriptService.Base.CollectFeedback)

	describe('CollectFeedback.ComputePressedCFrame', function()
		it('moves toward Base along local Y by a fraction of the gap', function()
			local rest = CFrame.new(0, 5, 0)
			local basePos = Vector3.new(0, 4, 0) -- 1 stud below
			local pressed = CollectFeedback.ComputePressedCFrame(rest, basePos)
			-- Same X/Z, strictly lower Y, strictly above Base.
			expect(pressed.X).to.equal(0)
			expect(pressed.Z).to.equal(0)
			expect(pressed.Y < 5).to.equal(true)
			expect(pressed.Y > 4).to.equal(true)
			-- Orientation preserved (no tilt introduced).
			expect(pressed.UpVector.Y).to.be.near(1, 0.001)
		end)

		it('never moves sideways when Base is offset horizontally', function()
			local rest = CFrame.new(0, 5, 0)
			local basePos = Vector3.new(3, 4, -2)
			local pressed = CollectFeedback.ComputePressedCFrame(rest, basePos)
			expect(pressed.X).to.equal(0)
			expect(pressed.Z).to.equal(0)
			expect(pressed.Y < 5).to.equal(true)
		end)

		it('respects the button orientation (tilted button presses along its own Y)', function()
			local rest = CFrame.new(0, 5, 0) * CFrame.Angles(0, 0, math.rad(90))
			-- Button local Y now points along world -X; put the
			-- Base 1 stud down that axis.
			local down = -rest.UpVector
			local basePos = rest.Position + down * 1
			local pressed = CollectFeedback.ComputePressedCFrame(rest, basePos)
			local moved = pressed.Position - rest.Position
			expect(moved.Magnitude > 0).to.equal(true)
			expect(moved.Magnitude < 1).to.equal(true)
			-- Movement is along the button's local Y only.
			local lateral = moved - down * moved:Dot(down)
			expect(lateral.Magnitude).to.be.near(0, 0.0001)
		end)

		it('returns rest for degenerate gaps (Base level with PressPart)', function()
			local rest = CFrame.new(0, 5, 0)
			local pressed = CollectFeedback.ComputePressedCFrame(rest, Vector3.new(0, 5, 0))
			expect(pressed == rest).to.equal(true)
		end)

		it('returns rest when Base is above PressPart', function()
			local rest = CFrame.new(0, 5, 0)
			local pressed = CollectFeedback.ComputePressedCFrame(rest, Vector3.new(0, 6, 0))
			expect(pressed == rest).to.equal(true)
		end)

		it('honours an explicit fraction', function()
			local rest = CFrame.new(0, 5, 0)
			local basePos = Vector3.new(0, 4, 0)
			local half = CollectFeedback.ComputePressedCFrame(rest, basePos, 0.5)
			expect(half.Y).to.be.near(4.5, 0.0001)
		end)
	end)

	describe('CollectFeedback.Play', function()
		beforeEach(function()
			CollectFeedback._TestReset()
		end)

		it('never throws on bad input and reports nothing fired', function()
			local r1 = CollectFeedback.Play(nil, nil)
			expect(r1.sfx).to.equal(false)
			expect(r1.vfx).to.equal(false)
			expect(r1.press).to.equal(false)
			local r2 = CollectFeedback.Play(nil, { cashCollector = nil })
			expect(r2.vfx).to.equal(false)
		end)

		it('skips gracefully when assets are missing (no ServerStorage setup)', function()
			-- No Assets folder in the test env: SFX/VFX warn
			-- once and report false; nothing throws.
			local part = Instance.new('Part')
			part.Anchored = true
			part.Parent = game:GetService('Workspace')
			local r = CollectFeedback.Play(nil, { cashCollector = part, stand = nil })
			expect(r.sfx).to.equal(false)
			expect(r.vfx).to.equal(false)
			expect(r.press).to.equal(false)
			part:Destroy()
		end)
	end)

	describe('CollectFeedback button spam determinism', function()
		local pressPart: BasePart? = nil
		local basePart: BasePart? = nil

		beforeEach(function()
			CollectFeedback._TestReset()
			local pp = Instance.new('Part')
			pp.Name = 'PressPart'
			pp.Size = Vector3.new(2, 0.5, 2)
			pp.Anchored = true
			pp.CFrame = CFrame.new(0, 5, 0)
			pp.Parent = game:GetService('Workspace')
			pressPart = pp
			local bp = Instance.new('Part')
			bp.Name = 'Base'
			bp.Size = Vector3.new(2, 0.5, 2)
			bp.Anchored = true
			bp.CFrame = CFrame.new(0, 4, 0)
			bp.Parent = game:GetService('Workspace')
			basePart = bp
		end)

		afterEach(function()
			CollectFeedback._TestReset()
			if pressPart ~= nil then
				(pressPart :: BasePart):Destroy()
				pressPart = nil
			end
			if basePart ~= nil then
				(basePart :: BasePart):Destroy()
				basePart = nil
			end
		end)

		it('bumps one generation per press on a single controller', function()
			local pp = pressPart :: BasePart
			local bp = basePart :: BasePart
			expect(CollectFeedback._TestPress(pp, bp)).to.equal(1)
			expect(CollectFeedback._TestPress(pp, bp)).to.equal(2)
			expect(CollectFeedback._TestPress(pp, bp)).to.equal(3)
		end)

		it('returns exactly to rest after rapid spam with no drift', function()
			local pp = pressPart :: BasePart
			local bp = basePart :: BasePart
			local rest = pp.CFrame
			for _ = 1, 10 do
				CollectFeedback._TestPress(pp, bp)
			end
			-- Full press + hold + release settles well inside
			-- this bound; the final snap is exact, not near.
			task.wait(0.8)
			expect(pp.CFrame == rest).to.equal(true)
		end)

		it('never travels below the pressed transform or above rest', function()
			local pp = pressPart :: BasePart
			local bp = basePart :: BasePart
			local rest = pp.CFrame
			local pressed = CollectFeedback.ComputePressedCFrame(rest, bp.Position)
			for _ = 1, 5 do
				CollectFeedback._TestPress(pp, bp)
				task.wait(0.02)
				-- Every observed pose stays within [pressed, rest].
				expect(pp.Position.Y <= rest.Position.Y + 0.001).to.equal(true)
				expect(pp.Position.Y >= pressed.Position.Y - 0.001).to.equal(true)
			end
			task.wait(0.8)
			expect(pp.CFrame == rest).to.equal(true)
		end)
	end)

	describe('CollectFeedback VFX rig', function()
		local pressPart: BasePart? = nil
		local createdAssets = false
		local createdVfx = false
		local createdCashClaim = false

		local function ensureAsset(): Attachment
			local storage = game:GetService('ServerStorage')
			local assets = storage:FindFirstChild('Assets')
			if not assets then
				assets = Instance.new('Folder')
				assets.Name = 'Assets'
				assets.Parent = storage
				createdAssets = true
			end
			local vfx = (assets :: Instance):FindFirstChild('Vfx')
			if not vfx then
				vfx = Instance.new('Folder')
				vfx.Name = 'Vfx'
				vfx.Parent = assets
				createdVfx = true
			end
			local cashClaim = (vfx :: Instance):FindFirstChild('CashClaim')
			if cashClaim then
				local att = (cashClaim :: Instance):FindFirstChildWhichIsA('Attachment', true)
				if att then
					return att
				end
			end
			local folder = Instance.new('Folder')
			folder.Name = 'CashClaim'
			local att = Instance.new('Attachment')
			att.Name = 'Attachment'
			local emitter = Instance.new('ParticleEmitter')
			emitter.Rate = 16
			emitter.Parent = att
			att.Parent = folder
			folder.Parent = vfx
			createdCashClaim = true
			return att
		end

		beforeEach(function()
			CollectFeedback._TestReset()
			ensureAsset()
			local pp = Instance.new('Part')
			pp.Name = 'PressPart'
			pp.Size = Vector3.new(2, 0.5, 2)
			pp.Anchored = true
			pp.CFrame = CFrame.new(0, 5, 0)
			pp.Parent = game:GetService('Workspace')
			pressPart = pp
		end)

		afterEach(function()
			CollectFeedback._TestReset()
			if pressPart ~= nil then
				(pressPart :: BasePart):Destroy()
				pressPart = nil
			end
			if createdCashClaim then
				local storage = game:GetService('ServerStorage')
				local assets = storage:FindFirstChild('Assets')
				local vfx = assets and (assets :: Instance):FindFirstChild('Vfx') or nil
				local cashClaim = vfx and (vfx :: Instance):FindFirstChild('CashClaim') or nil
				if cashClaim then
					cashClaim:Destroy()
				end
				createdCashClaim = false
			end
			if createdVfx then
				local storage = game:GetService('ServerStorage')
				local assets = storage:FindFirstChild('Assets')
				local vfx = assets and (assets :: Instance):FindFirstChild('Vfx') or nil
				if vfx then
					vfx:Destroy()
				end
				createdVfx = false
			end
			if createdAssets then
				local storage = game:GetService('ServerStorage')
				local assets = storage:FindFirstChild('Assets')
				if assets then
					assets:Destroy()
				end
				createdAssets = false
			end
		end)

		it('mounts clones under PressPart with the burst above the button top', function()
			local pp = pressPart :: BasePart
			expect(CollectFeedback._TestFireVfx(pp)).to.equal(true)
			local found = 0
			for _, child in ipairs(pp:GetChildren()) do
				if child:IsA('Attachment') then
					found += 1
					-- Re-anchored above the live top surface so
					-- particles escape the opaque mesh (LevelUp
					-- re-anchor convention), orientation intact.
					local topY = pp.Position.Y + pp.Size.Y / 2
					expect((child :: Attachment).WorldPosition.Y >= topY - 0.001).to.equal(true)
				end
			end
			expect(found >= 1).to.equal(true)
			-- Spam: every claim fires; short-lived clones
			-- coexist briefly (Debris-bounded, like rapid
			-- level-ups) instead of erroring or piling
			-- permanently.
			expect(CollectFeedback._TestFireVfx(pp)).to.equal(true)
			expect(CollectFeedback._TestFireVfx(pp)).to.equal(true)
			-- The ServerStorage template is never mutated or
			-- consumed: it still resolves for the next claim.
			local storage = game:GetService('ServerStorage')
			local assets = storage:FindFirstChild('Assets')
			local vfx = assets and (assets :: Instance):FindFirstChild('Vfx') or nil
			local cashClaim = vfx and (vfx :: Instance):FindFirstChild('CashClaim') or nil
			expect(cashClaim ~= nil).to.equal(true)
			expect((cashClaim :: Instance).Parent == vfx).to.equal(true)
		end)
	end)

	describe('CollectFeedback SFX pool', function()
		local root: Folder? = nil
		local createdAssets = false
		local createdSfx = false
		local createdCashClaim = false

		local function ensureSfx(): Sound
			local storage = game:GetService('ServerStorage')
			local assets = storage:FindFirstChild('Assets')
			if not assets then
				assets = Instance.new('Folder')
				assets.Name = 'Assets'
				assets.Parent = storage
				createdAssets = true
			end
			local sfx = (assets :: Instance):FindFirstChild('Sfx')
			if not sfx then
				sfx = Instance.new('Folder')
				sfx.Name = 'Sfx'
				sfx.Parent = assets
				createdSfx = true
			end
			local cashClaim = (sfx :: Instance):FindFirstChild('CashClaim')
			if cashClaim and (cashClaim :: Instance):IsA('Sound') then
				return cashClaim :: Sound
			end
			if not cashClaim then
				local sound = Instance.new('Sound')
				sound.Name = 'CashClaim'
				sound.SoundId = 'rbxassetid://123456'
				sound.Parent = sfx
				createdCashClaim = true
				return sound
			end
			local inner = (cashClaim :: Instance):FindFirstChildWhichIsA('Sound', true)
			if inner then
				return inner
			end
			local sound = Instance.new('Sound')
			sound.Name = 'CashClaimInner'
			sound.SoundId = 'rbxassetid://123456'
			sound.Parent = cashClaim
			createdCashClaim = true
			return sound
		end

		beforeEach(function()
			CollectFeedback._TestReset()
			ensureSfx()
			local folder = Instance.new('Folder')
			folder.Name = 'FakePlayerGui'
			folder.Parent = game:GetService('Workspace')
			root = folder
		end)

		afterEach(function()
			CollectFeedback._TestReset()
			if root ~= nil then
				(root :: Folder):Destroy()
				root = nil
			end
			if createdCashClaim then
				local storage = game:GetService('ServerStorage')
				local assets = storage:FindFirstChild('Assets')
				local sfx = assets and (assets :: Instance):FindFirstChild('Sfx') or nil
				local cashClaim = sfx and (sfx :: Instance):FindFirstChild('CashClaim') or nil
				if cashClaim then
					cashClaim:Destroy()
				end
				createdCashClaim = false
			end
			if createdSfx then
				local storage = game:GetService('ServerStorage')
				local assets = storage:FindFirstChild('Assets')
				local sfx = assets and (assets :: Instance):FindFirstChild('Sfx') or nil
				if sfx then
					sfx:Destroy()
				end
				createdSfx = false
			end
			if createdAssets then
				local storage = game:GetService('ServerStorage')
				local assets = storage:FindFirstChild('Assets')
				if assets then
					assets:Destroy()
				end
				createdAssets = false
			end
		end)

		it('creates a bounded pool of 4 and warming is idempotent', function()
			local gui = root :: Folder
			expect(CollectFeedback._TestEnsurePool(gui)).to.equal(4)
			-- Second ensure (warm race / respawn rebuild) tops
			-- up, never duplicates.
			expect(CollectFeedback._TestEnsurePool(gui)).to.equal(4)
			local members = 0
			local poolFolder = gui:FindFirstChild('CashClaimPool')
			expect(poolFolder ~= nil).to.equal(true)
			for _, child in ipairs((poolFolder :: Instance):GetChildren()) do
				if child:IsA('Sound') then
					members += 1
				end
			end
			expect(members).to.equal(4)
		end)

		it('round-robins rapid plays across distinct members (no restart truncation)', function()
			local gui = root :: Folder
			local seen: { [string]: boolean } = {}
			for _ = 1, 4 do
				local played, name = CollectFeedback._TestPlayPool(gui, 1001)
				expect(played).to.equal(true)
				expect(name ~= nil).to.equal(true)
				seen[name :: string] = true
			end
			local distinct = 0
			for _ in pairs(seen) do
				distinct += 1
			end
			expect(distinct).to.equal(4)
			-- 5th wraps to the first member (bounded reuse).
			local _, name5 = CollectFeedback._TestPlayPool(gui, 1001)
			expect(seen[name5 :: string]).to.equal(true)
		end)

		it('refreshes a stale member SoundId instead of replaying mute', function()
			local gui = root :: Folder
			CollectFeedback._TestEnsurePool(gui)
			local poolFolder = gui:FindFirstChild('CashClaimPool') :: Folder
			local first = poolFolder:FindFirstChild('CashClaim1') :: Sound
			first.SoundId = ''
			-- Next plays rotate through the pool; after a full
			-- cycle every member is valid again.
			for _ = 1, 4 do
				CollectFeedback._TestPlayPool(gui, 2002)
			end
			expect(first.SoundId ~= '').to.equal(true)
		end)

		it('removes the legacy singleton when the pool is ensured', function()
			local gui = root :: Folder
			local legacy = Instance.new('Sound')
			legacy.Name = 'CashClaimSfx'
			legacy.Parent = gui
			CollectFeedback._TestEnsurePool(gui)
			expect(gui:FindFirstChild('CashClaimSfx')).to.equal(nil)
		end)

		it('Warm(nil) and ForgetPlayer never throw', function()
			CollectFeedback.Warm(nil)
			CollectFeedback.ForgetPlayer(9999)
		end)
	end)
end
