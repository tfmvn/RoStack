--!strict
--!native
--[[
	RollController.spec
	===================
	Tests for RollController.ComputeGroundCFrame.

	Pre-Collector-facing: the helper rotated 180° from the
	lucky egg's facing because the egg and the animal
	were on opposite sides of the slot. Post-Collector-facing
	the slot's rotation IS the desired facing (slot's +Z
	points at the Collector), and the roll previews are
	placed at the slot's rotation directly. No 180° flip.

 	What we test:
 	  1. With a slot CFrame whose Yaw points "east"
 	     (LookVector along +X), ComputeGroundCFrame returns
 	     a CFrame whose Yaw equals the slot's Yaw (NOT the
 	     slot's Yaw + π). The roll previews face the
 	     Collector's direction.
 	  2. The XZ of the result matches the slot's XZ (the
 	     roll happens on the slot).
 	  3. The Y of the result equals egg._localFloor when
 	     present, and HoverMath.FloorY(slotCFrame.Y, egg.model)
 	     as a fallback. Same constant-clearance formula that
 	     places an egg at the slot.
 	  4. Mystery silhouette (_TestSilhouette): preview clones
 	     go pitch black with identity hidden, geometry/rig
 	     intact, source templates never mutated, re-apply is
 	     a no-op.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local RollController = require(ServerScriptService['Egg'].RollController)
	local HoverMath = require(ServerScriptService['Egg'].HoverMath)
	local Constants = require(ServerScriptService['Egg'].Constants)

	describe('RollController.ComputeGroundCFrame', function()
		it('returns a CFrame with the slot rotation (no 180° flip)', function()
			-- Slot Yaw 90° (LookVector = +X).
			local slotCF = CFrame.new(10, 5, 20) * CFrame.Angles(0, math.rad(90), 0)
			local egg = { _localFloor = 5.5 }
			local groundCF = RollController.ComputeGroundCFrame(slotCF, egg)

			local _, groundYaw, _ = groundCF:ToEulerAnglesYXZ()
			local _, slotYaw, _ = slotCF:ToEulerAnglesYXZ()
			-- The ground CFrame's Yaw should equal the
			-- slot's Yaw (NOT slotYaw + π, which would
			-- be the pre-fix behavior).
			expect(groundYaw).to.be.near(slotYaw, 0.001)
		end)

		it('uses egg._localFloor for the Y when available', function()
			local slotCF = CFrame.new(10, 5, 20)
			local egg = { _localFloor = 7.25 }
			local groundCF = RollController.ComputeGroundCFrame(slotCF, egg)
			expect(groundCF.Y).to.equal(7.25)
		end)

		it('falls back to HoverMath.FloorY(slotCFrame.Y, model) when _localFloor is missing', function()
			local slotCF = CFrame.new(10, 5, 20)
			-- A 4-tall egg: fallback = 5 - HoverClearance - height/2
			-- = 5 - 3 - 2 = 0.
			local egg = { model = { PrimaryPart = { Size = Vector3.new(4, 4, 4) } } }
			local groundCF = RollController.ComputeGroundCFrame(slotCF, egg)
			local expected = HoverMath.FloorY(5, egg.model)
			expect(groundCF.Y).to.be.near(expected, 0.001)
			expect(groundCF.Y).to.be.near(0, 0.001)
		end)

		it('preserves the slot XZ', function()
			local slotCF = CFrame.new(13.5, 5, -7.25) * CFrame.Angles(0, math.rad(45), 0)
			local egg = { _localFloor = 5.5 }
			local groundCF = RollController.ComputeGroundCFrame(slotCF, egg)
			expect(groundCF.X).to.equal(13.5)
			expect(groundCF.Z).to.equal(-7.25)
		end)
	end)

	describe('RollController._TestSilhouette (mystery blackout)', function()
		local function makeAnimalLike(): Model
			-- A fake "animal": colored Neon body (glow must
			-- die), a face Decal (identity must hide), a
			-- Texture, a ParticleEmitter, a PointLight, a
			-- BillboardGui nametag (name must hide), an
			-- invisible hitbox (must STAY invisible), and a
			-- Humanoid (rig must survive).
			local model = Instance.new('Model')
			model.Name = 'FakeAnimal'
			local body = Instance.new('Part')
			body.Name = 'Body'
			body.Size = Vector3.new(2, 2, 2)
			body.Color = Color3.fromRGB(255, 0, 0)
			body.Material = Enum.Material.ForceField
			body.Parent = model
			model.PrimaryPart = body
			local decal = Instance.new('Decal')
			decal.Name = 'Face'
			decal.Parent = body
			local texture = Instance.new('Texture')
			texture.Parent = body
			local emitter = Instance.new('ParticleEmitter')
			emitter.Rate = 20
			emitter.Parent = body
			local light = Instance.new('PointLight')
			light.Color = Color3.fromRGB(0, 255, 0)
			light.Parent = body
			local hitbox = Instance.new('Part')
			hitbox.Name = 'Hitbox'
			hitbox.Size = Vector3.new(4, 4, 4)
			hitbox.Transparency = 1
			hitbox.Parent = model
			local head = Instance.new('Part')
			head.Name = 'Head'
			head.Size = Vector3.new(1, 1, 1)
			head.Color = Color3.fromRGB(0, 0, 255)
			head.Parent = model
			local bb = Instance.new('BillboardGui')
			bb.Name = 'NameTag'
			bb.Parent = head
			local humanoid = Instance.new('Humanoid')
			humanoid.Parent = model
			model.Parent = game:GetService('Workspace')
			return model
		end

		it('blacks out parts, hides identity, keeps geometry + rig', function()
			local model = makeAnimalLike()
			local count = RollController._TestSilhouette(model)
			expect(count).to.equal(2) -- Body + Head (hitbox stays invisible)
			local body = model:FindFirstChild('Body')
			assert(body ~= nil, 'body kept')
			expect((body :: BasePart).Color).to.equal(Color3.fromRGB(0, 0, 0))
			expect((body :: BasePart).Material).to.equal(Enum.Material.Neon)
			expect((body :: BasePart).Transparency).to.equal(0)
			-- White aura: one Highlight, Adornee'd to the entry,
			-- black fill + white outline, always generic.
			local aura = model:FindFirstChildOfClass('Highlight')
			assert(aura ~= nil, 'aura present')
			expect((aura :: Highlight).FillColor).to.equal(Color3.fromRGB(0, 0, 0))
			expect((aura :: Highlight).FillTransparency).to.equal(0)
			expect((aura :: Highlight).OutlineColor).to.equal(Color3.fromRGB(255, 255, 255))
			expect((aura :: Highlight).OutlineTransparency).to.equal(0)
			expect((aura :: Highlight).DepthMode).to.equal(Enum.HighlightDepthMode.Occluded)
			expect((aura :: Highlight).Adornee).to.equal(model)
			-- Identity leaks destroyed (clone-local; the entry
			-- itself is destroyed at preview end).
			expect(body:FindFirstChildOfClass('Decal')).to.equal(nil)
			expect(body:FindFirstChildOfClass('Texture')).to.equal(nil)
			expect(body:FindFirstChildOfClass('ParticleEmitter')).to.equal(nil)
			expect(body:FindFirstChildOfClass('PointLight')).to.equal(nil)
			expect(model:FindFirstChild('NameTag', true)).to.equal(nil)
			-- Invisible hitbox untouched (no false geometry),
			-- rig untouched.
			local hitbox = model:FindFirstChild('Hitbox')
			assert(hitbox ~= nil, 'hitbox kept')
			expect((hitbox :: BasePart).Transparency).to.equal(1)
			expect(model:FindFirstChildOfClass('Humanoid') ~= nil).to.equal(true)
			model:Destroy()
		end)

		it('is idempotent and safe on garbage', function()
			local model = makeAnimalLike()
			expect(RollController._TestSilhouette(model)).to.equal(2)
			-- Second apply: marker short-circuits, zero work —
			-- still exactly one aura, never accumulated.
			expect(RollController._TestSilhouette(model)).to.equal(0)
			local auras = 0
			for _, child in ipairs(model:GetChildren()) do
				if child:IsA('Highlight') then
					auras += 1
				end
			end
			expect(auras).to.equal(1)
			model:Destroy()
			expect(RollController._TestSilhouette(nil :: any)).to.equal(0)
			expect(RollController._TestSilhouette({} :: any)).to.equal(0)
		end)

		it('never mutates the source template (clone-only blackout)', function()
			-- Mirrors the production flow: template stays
			-- pristine, only the per-preview clone is blacked.
			local template = makeAnimalLike()
			template.Name = 'TemplateAnimal'
			local clone = template:Clone()
			clone.Parent = game:GetService('Workspace')
			expect(RollController._TestSilhouette(clone)).to.equal(2)
			local tplBody = template:FindFirstChild('Body')
			assert(tplBody ~= nil, 'template body kept')
			expect((tplBody :: BasePart).Color).to.equal(Color3.fromRGB(255, 0, 0))
			expect((tplBody :: BasePart).Material).to.equal(Enum.Material.ForceField)
			expect(tplBody:FindFirstChildOfClass('Decal') ~= nil).to.equal(true)
			expect(template:FindFirstChild('NameTag', true) ~= nil).to.equal(true)
			expect(template:GetAttribute('SilhouetteApplied')).to.equal(nil)
			expect(template:FindFirstChildOfClass('Highlight')).to.equal(nil)
			clone:Destroy()
			template:Destroy()
		end)
	end)

	describe('RollController roll audio rig (Pop pool + Reward)', function()
		local ServerStorage = game:GetService('ServerStorage')

		-- Throwaway Pop/Reward assets when the Studio project
		-- has none. Returns cleanup info for teardown.
		local function ensureSfx(): { createdAssets: boolean, createdSfx: boolean, created: { Instance } }
			local created: { Instance } = {}
			local assets = ServerStorage:FindFirstChild('Assets')
			local createdAssets = false
			if not assets then
				assets = Instance.new('Folder')
				assets.Name = 'Assets'
				assets.Parent = ServerStorage
				createdAssets = true
			end
			local sfx = (assets :: Instance):FindFirstChild('Sfx')
			local createdSfx = false
			if not sfx then
				sfx = Instance.new('Folder')
				sfx.Name = 'Sfx'
				sfx.Parent = assets
				createdSfx = true
			end
			for _, name in ipairs({ 'Pop', 'Reward' }) do
				if not (sfx :: Instance):FindFirstChild(name) then
					local sound = Instance.new('Sound')
					sound.Name = name
					sound.SoundId = 'rbxassetid://123456'
					sound.Volume = 0.5
					sound.Parent = sfx
					created[#created + 1] = sound
				end
			end
			return { createdAssets = createdAssets, createdSfx = createdSfx, created = created }
		end

		local function teardownSfx(info: { createdAssets: boolean, createdSfx: boolean, created: { Instance } })
			for _, inst in ipairs(info.created) do
				inst:Destroy()
			end
			if info.createdSfx then
				local sfx = ServerStorage:FindFirstChild('Assets')
				local folder = sfx and (sfx :: Instance):FindFirstChild('Sfx') or nil
				if folder then
					folder:Destroy()
				end
			end
			if info.createdAssets then
				local assets = ServerStorage:FindFirstChild('Assets')
				if assets then
					assets:Destroy()
				end
			end
		end

		it('prepares a bounded pool + reward under the host folder, inheriting SoundIds', function()
			local info = ensureSfx()
			local host = Instance.new('Folder')
			host.Name = 'RollAudioTest'
			host.Parent = game:GetService('Workspace')
			local rig = RollController._TestPrepareRollAudio(host, Vector3.new(0, 5, 0))
			expect(rig.pops).to.equal(4)
			expect(rig.hasReward).to.equal(true)
			assert(rig.anchor ~= nil, 'anchor built')
			local anchor = rig.anchor :: BasePart
			expect(anchor.Parent).to.equal(host)
			expect(anchor.Transparency).to.equal(1)
			-- Pool sounds inherit the source SoundId. There is
			-- deliberately NO RollReward instance: Reward must
			-- survive pool teardown, so it clones
			-- player-targeted at commit time instead (see
			-- _playReward) — a pool instance would be cut at
			-- ~0ms when the folder is destroyed.
			local popSource = ServerStorage:FindFirstChild('Assets') :: Instance
			local sfxFolder = popSource:FindFirstChild('Sfx') :: Instance
			local popId = (sfxFolder:FindFirstChild('Pop') :: Sound).SoundId
			local popCount = 0
			for _, child in ipairs(anchor:GetChildren()) do
				if child:IsA('Sound') then
					expect(child.Name).to.equal('RollPop')
					popCount += 1
					expect((child :: Sound).SoundId).to.equal(popId)
				end
			end
			expect(popCount).to.equal(4)
			-- Reward resolution reads the exact live asset
			-- path (never an assumed reference).
			expect(RollController._TestRewardSoundId()).to.equal((sfxFolder:FindFirstChild('Reward') :: Sound).SoundId)
			host:Destroy()
			teardownSfx(info)
		end)

		it('round-robins Pops and plays Reward exactly once, without throwing', function()
			local info = ensureSfx()
			local host = Instance.new('Folder')
			host.Name = 'RollAudioTest2'
			host.Parent = game:GetService('Workspace')
			local rig = RollController._TestPrepareRollAudio(host, Vector3.new(0, 5, 0))
			assert(rig.anchor ~= nil, 'anchor built')
			local anchor = rig.anchor :: BasePart
			local pool: { Sound } = {}
			for _, child in ipairs(anchor:GetChildren()) do
				if child:IsA('Sound') and child.Name == 'RollPop' then
					pool[#pool + 1] = child
				end
			end
			expect(#pool).to.equal(4)
			-- Reward source (not an instance): the finish
			-- block clones player-targeted at commit time.
			local sfxFolder = (ServerStorage:FindFirstChild('Assets') :: Instance):FindFirstChild('Sfx')
			assert(sfxFolder ~= nil, 'sfx folder present')
			local rewardSource = (sfxFolder :: Instance):FindFirstChild('Reward')
			assert(rewardSource ~= nil, 'reward source present')
			local controller: any = {
				egg = { ownerUserId = 999999999 }, -- no such player: skip path, flag still flips
				_popPool = pool,
				_popPoolIdx = 0,
				_rewardSource = rewardSource,
				_revealPlayed = false,
			}
			-- Fake post-commit animal: unknown rarity (VFX
			-- skips), unreachable owner (SFX skips), real
			-- model (mount checks run). The reveal still
			-- fires exactly once by controller state.
			local fakeModel = Instance.new('Model')
			local fakeRoot = Instance.new('Part')
			fakeRoot.Name = 'HumanoidRootPart'
			fakeRoot.Size = Vector3.new(2, 2, 2)
			fakeRoot.Anchored = true
			fakeRoot.Parent = fakeModel
			fakeModel.PrimaryPart = fakeRoot
			fakeModel.Parent = game:GetService('Workspace')
			local animal: any = {
				uniqueId = 'AN_reveal01',
				rarity = 'NopeRarity',
				ownerUserId = 999999999,
				model = fakeModel,
			}
			expect(function()
				-- Five pops over a 4-pool: 1,2,3,4,1.
				RollController._TestPlayAudio(controller, 'pop')
				expect(controller._popPoolIdx).to.equal(1)
				RollController._TestPlayAudio(controller, 'pop')
				RollController._TestPlayAudio(controller, 'pop')
				RollController._TestPlayAudio(controller, 'pop')
				expect(controller._popPoolIdx).to.equal(4)
				RollController._TestPlayAudio(controller, 'pop')
				expect(controller._popPoolIdx).to.equal(1)
				-- Canonical reveal: true once, false after
				-- (state identity, not timing).
				expect(RollController._TestPlayAudio(controller, 'reveal', animal)).to.equal(true)
				expect(controller._revealPlayed).to.equal(true)
				expect(RollController._TestPlayAudio(controller, 'reveal', animal)).to.equal(false)
				-- Unknown selector is a safe no-op.
				expect(RollController._TestPlayAudio(controller, 'nope')).to.equal(false)
			end).to.never.throw()
			fakeModel:Destroy()
			host:Destroy()
			teardownSfx(info)
		end)

		it('rarity explosion mounts on the real animal without mutating the template', function()
			local info = ensureSfx()
			-- Throwaway Explosions.NopeRarity asset (never
			-- collides with the 8 real rarities).
			local assets = ServerStorage:FindFirstChild('Assets') :: Instance
			local vfx = assets:FindFirstChild('Vfx')
			local createdVfx = false
			if not vfx then
				vfx = Instance.new('Folder')
				vfx.Name = 'Vfx'
				vfx.Parent = assets
				createdVfx = true
			end
			local explosions = (vfx :: Instance):FindFirstChild('Explosions')
			local createdExplosions = false
			if not explosions then
				explosions = Instance.new('Folder')
				explosions.Name = 'Explosions'
				explosions.Parent = vfx
				createdExplosions = true
			end
			local existing = (explosions :: Instance):FindFirstChild('NopeRarity')
			local template: Instance
			local createdTemplate = false
			if existing then
				template = existing
			else
				local folder = Instance.new('Folder')
				folder.Name = 'NopeRarity'
				local attachment = Instance.new('Attachment')
				attachment.Name = 'Burst'
				attachment.Position = Vector3.new(0, 1, 0)
				local emitter = Instance.new('ParticleEmitter')
				emitter.Rate = 20
				emitter.Lifetime = NumberRange.new(0.4, 0.8)
				emitter.Parent = attachment
				attachment.Parent = folder
				folder.Parent = explosions
				template = folder
				createdTemplate = true
			end
			local beforeDescendants = #template:GetDescendants()

			local fakeModel = Instance.new('Model')
			local fakeRoot = Instance.new('Part')
			fakeRoot.Name = 'HumanoidRootPart'
			fakeRoot.Size = Vector3.new(2, 2, 2)
			fakeRoot.Anchored = true
			fakeRoot.Parent = fakeModel
			fakeModel.PrimaryPart = fakeRoot
			fakeModel.Parent = game:GetService('Workspace')
			local controller: any = { _revealPlayed = false }
			local animal: any = {
				uniqueId = 'AN_reveal02',
				rarity = 'NopeRarity',
				ownerUserId = 999999999,
				model = fakeModel,
			}
			expect(function()
				expect(RollController.RevealFinalAnimal(controller, animal)).to.equal(true)
			end).to.never.throw()
			-- Explosion mounted on the animal (attachment
			-- re-homed under PrimaryPart, emitter present).
			local mounted = false
			for _, descendant in ipairs(fakeModel:GetDescendants()) do
				if descendant:IsA('ParticleEmitter') then
					mounted = true
					break
				end
			end
			expect(mounted).to.equal(true)
			-- Source template untouched (still one attachment
			-- + one emitter, never re-homed, never emitted).
			expect(#template:GetDescendants()).to.equal(beforeDescendants)
			fakeModel:Destroy()
			if createdTemplate then
				template:Destroy()
				if createdExplosions then
					(explosions :: Instance):Destroy()
				end
				if createdVfx then
					(vfx :: Instance):Destroy()
				end
			end
			teardownSfx(info)
		end)

		it('missing rig degrades silently (mute roll, no throw)', function()
			local controller: any = {}
			expect(function()
				RollController._TestPlayAudio(controller, 'pop')
				expect(RollController._TestPlayAudio(controller, 'reveal', nil)).to.equal(false)
				expect(RollController._TestPlayAudio(controller, 'nope')).to.equal(false)
			end).to.never.throw()
			expect(controller._revealPlayed).to.equal(nil)
		end)
	end)
end
