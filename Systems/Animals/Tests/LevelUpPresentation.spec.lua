--!strict
--!native
--[[
	LevelUpPresentation.spec
	========================
	Tests for the level-up feedback add-on (happy bop + Upgrade VFX
	+ smooth weight-growth), served server-authoritatively from the
	real AnimalService level-up paths.

	Coverage maps to the add-on spec §9:
	  1. Normal level-up (AddXP + ApplyLevelUpgrade) bumps the
	     celebration generation exactly once per real level change.
	  2. Capped weight (provider returns nil) still celebrates.
	  3. Rapid XP / multi-level grants merge safely (one generation
	     per Notify, no throw, no stuck state).
	  4. Celebration targets the correct animal (per-animal
	     generations are independent).
	  5. Destroy/rejoin cleanup cancels in-flight work (Cancel bumps
	     the generation so stale loops exit without touching models).
	  6. Multi-animal independence (covered by 4).
  7. Missing/malformed VFX asset (and missing model) degrades
     gracefully — level-up results are unaffected and nothing
     throws.
  8. Celebration is visuals-only: VFX-embedded Sounds are never
     played (a Workspace sting would leak to nearby players);
     the personal sting plays on the owning client via the
     AnimalLeveledUp remote, and the removed server audio API
     (Ensure/PlayLevelUpSfx) stays removed.

	No live slots/stands are spawned: records use the documented
	_TestRegister seam, and VFX tests build throwaway instances.
	Background celebration threads are always cancelled and their
	models destroyed at the end of each test.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ServerStorage = game:GetService('ServerStorage')
	local AnimalService = require(ServerScriptService.AnimalService)
	local LevelUpPresentation = require(ServerScriptService.Animal.LevelUpPresentation)

	describe('LevelUpPresentation', function()
		it('ignores malformed Notify calls without throwing or bumping generation', function()
			expect(function()
				LevelUpPresentation.NotifyLevelUp(nil, nil)
			end).to.never.throw()
			expect(function()
				LevelUpPresentation.NotifyLevelUp({}, { oldLevel = 1, newLevel = 2 })
			end).to.never.throw()
			expect(function()
				LevelUpPresentation.NotifyLevelUp({ uniqueId = 123 }, nil)
			end).to.never.throw()
			expect(LevelUpPresentation._TestGeneration('no-such-animal')).to.equal(0)
		end)

		it('celebrates a real AddXP level-up exactly once, not a bare XP change', function()
			local id = 'BR_lvlup01'
			AnimalService._TestRegister({ uniqueId = id, ownerUserId = 9901, Level = 1, XP = 0 })
			-- Bare XP change (no threshold cross): no celebration.
			local small = AnimalService:AddXP(id, 10)
			expect(small.success).to.equal(true)
			expect(small.leveledUp).to.equal(false)
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(0)
			-- Real level-up: exactly one celebration generation.
			local big = AnimalService:AddXP(id, 1000)
			expect(big.success).to.equal(true)
			expect(big.leveledUp).to.equal(true)
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(1)
			LevelUpPresentation.Cancel(id)
			AnimalService._TestUnregister(id)
		end)

		it('celebrates a paid ApplyLevelUpgrade', function()
			local id = 'BR_lvlup02'
			AnimalService._TestRegister({ uniqueId = id, ownerUserId = 9902, Level = 3, XP = 0 })
			local result = AnimalService.ApplyLevelUpgrade(id)
			expect(result.success).to.equal(true)
			expect(result.oldLevel).to.equal(3)
			expect(result.newLevel).to.equal(4)
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(1)
			LevelUpPresentation.Cancel(id)
			AnimalService._TestUnregister(id)
		end)

		it('merges rapid level-ups: one generation per Notify, per-animal independent', function()
			local a = 'BR_lvlup03a'
			local b = 'BR_lvlup03b'
			AnimalService._TestRegister({ uniqueId = a, ownerUserId = 9903, Level = 1, XP = 0 })
			AnimalService._TestRegister({ uniqueId = b, ownerUserId = 9903, Level = 1, XP = 0 })
			-- Rapid multi-level grant on A (several thresholds at once).
			local burst = AnimalService:AddXP(a, 5000)
			expect(burst.success).to.equal(true)
			expect(burst.levelsGained > 1).to.equal(true)
			expect(LevelUpPresentation._TestGeneration(a)).to.equal(1)
			-- B is untouched: no cross-animal interference.
			expect(LevelUpPresentation._TestGeneration(b)).to.equal(0)
			-- Two more rapid grants merge as two more generations.
			AnimalService:AddXP(a, 5000)
			AnimalService:AddXP(a, 5000)
			expect(LevelUpPresentation._TestGeneration(a)).to.equal(3)
			expect(LevelUpPresentation._TestGeneration(b)).to.equal(0)
			LevelUpPresentation.Cancel(a)
			LevelUpPresentation.Cancel(b)
			AnimalService._TestUnregister(a)
			AnimalService._TestUnregister(b)
		end)

		it('still celebrates when the weight provider reports capped growth (nil)', function()
			local id = 'BR_lvlup04'
			LevelUpPresentation.SetWeightProvider(function(_animal: any): number?
				return nil -- MaxWeight reached: no growth this level-up
			end)
			AnimalService._TestRegister({ uniqueId = id, ownerUserId = 9904, Level = 1, XP = 0 })
			local result = AnimalService:AddXP(id, 500)
			expect(result.leveledUp).to.equal(true)
			-- Celebration fires even though growth is skipped.
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(1)
			LevelUpPresentation.SetWeightProvider(nil)
			LevelUpPresentation.Cancel(id)
			AnimalService._TestUnregister(id)
		end)

		it('rejects a bad weight provider without throwing', function()
			expect(function()
				LevelUpPresentation.SetWeightProvider('not-a-function' :: any)
			end).to.never.throw()
			expect(function()
				LevelUpPresentation.SetWeightProvider(nil)
			end).to.never.throw()
		end)

		it('BUG-1: a finished walk handle does not block the bop; an active carry does', function()
			-- Session-hatched animals keep their WalkController table
			-- after arrival (stopped=true, connection disconnected).
			-- That parked handle must NOT read as "being driven".
			expect(LevelUpPresentation._TestIsDriving({
				controller = { stopped = true, aborted = false, connection = nil },
				controllerType = 'Walk',
			})).to.equal(false)
			-- Teleport-arrival handle shape (stopped, no connection).
			expect(LevelUpPresentation._TestIsDriving({
				controller = { stopped = true, aborted = false },
				controllerType = 'Walk',
			})).to.equal(false)
			-- No controller at all (rejoin-spawned animals).
			expect(LevelUpPresentation._TestIsDriving({ controller = nil })).to.equal(false)
			-- An actively-walking animal still blocks.
			expect(LevelUpPresentation._TestIsDriving({
				controller = { stopped = false, aborted = false },
				controllerType = 'Walk',
			})).to.equal(true)
			-- An actively-carried animal still blocks.
			expect(LevelUpPresentation._TestIsDriving({
				controller = { running = true },
				controllerType = 'Carry',
			})).to.equal(true)
			-- A stopped carry handle does not block.
			expect(LevelUpPresentation._TestIsDriving({
				controller = { running = false },
				controllerType = 'Carry',
			})).to.equal(false)
		end)

		it('Cancel is safe on unknown ids and invalidates in-flight work', function()
			expect(function()
				LevelUpPresentation.Cancel('never-seen')
			end).to.never.throw()
			expect(function()
				LevelUpPresentation.Cancel(123 :: any)
			end).to.never.throw()
			local id = 'BR_lvlup05'
			AnimalService._TestRegister({ uniqueId = id, ownerUserId = 9905, Level = 1, XP = 0 })
			AnimalService:AddXP(id, 500)
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(1)
			LevelUpPresentation.Cancel(id)
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(2)
			AnimalService._TestUnregister(id)
		end)

		it('missing VFX asset degrades gracefully (no throw, level-up unaffected)', function()
			expect(function()
				LevelUpPresentation.PlayUpgradeVfx(nil)
			end).to.never.throw()
			local model = Instance.new('Model')
			model.Parent = game:GetService('Workspace')
			expect(function()
				LevelUpPresentation.PlayUpgradeVfx(model)
			end).to.never.throw()
			-- A bare level-up with no model still succeeds; the
			-- celebration is skipped while the mutation stands.
			local id = 'BR_lvlup07'
			AnimalService._TestRegister({ uniqueId = id, ownerUserId = 9907, Level = 1, XP = 0 })
			local result = AnimalService:AddXP(id, 500)
			expect(result.success).to.equal(true)
			expect(result.leveledUp).to.equal(true)
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(1)
			LevelUpPresentation.Cancel(id)
			AnimalService._TestUnregister(id)
			model:Destroy()
		end)

		it('upgrade celebration is visuals-only: no Workspace audio, server audio API removed', function()
			-- The server-side upgrade-audio path was deleted:
			-- a Workspace sting would be audible to every nearby
			-- player. The sting is personal (owning client plays
			-- it on the AnimalLeveledUp remote). Lock that the
			-- removed API stays removed.
			expect((LevelUpPresentation :: any).EnsureLevelUpSfx).to.equal(nil)
			expect((LevelUpPresentation :: any).PlayLevelUpSfx).to.equal(nil)

			-- Craft an Upgrade VFX template that CONTAINS a Sound
			-- (the leak shape): the celebration must destroy it
			-- unplayed while the visuals still mount.
			local assets = ServerStorage:FindFirstChild('Assets')
			local createdAssets = false
			if not assets then
				assets = Instance.new('Folder')
				assets.Name = 'Assets'
				assets.Parent = ServerStorage
				createdAssets = true
			end
			local vfx = (assets :: Instance):FindFirstChild('Vfx')
			local createdVfx = false
			if not vfx then
				vfx = Instance.new('Folder')
				vfx.Name = 'Vfx'
				vfx.Parent = assets
				createdVfx = true
			end
			local existing = (vfx :: Instance):FindFirstChild('Upgrade')
			local template: Instance
			local createdTemplate = false
			if existing then
				template = existing
			else
				local folder = Instance.new('Folder')
				folder.Name = 'Upgrade'
				local sting = Instance.new('Sound')
				sting.Name = 'LeakCheck'
				sting.SoundId = 'rbxassetid://123456'
				sting.Volume = 0.5
				sting.Parent = folder
				local attachment = Instance.new('Attachment')
				attachment.Name = 'Burst'
				attachment.Position = Vector3.new(0, 1, 0)
				local emitter = Instance.new('ParticleEmitter')
				emitter.Rate = 20
				emitter.Lifetime = NumberRange.new(0.4, 0.8)
				emitter.Parent = attachment
				attachment.Parent = folder
				folder.Parent = vfx
				template = folder
				createdTemplate = true
			end

			local model = Instance.new('Model')
			model.Name = 'SilentCelebrant'
			local root = Instance.new('Part')
			root.Name = 'HumanoidRootPart'
			root.Size = Vector3.new(2, 2, 2)
			root.Anchored = true
			root.Parent = model
			model.PrimaryPart = root
			model.Parent = game:GetService('Workspace')

			local function workspaceSoundCount(): number
				local n = 0
				for _, child in ipairs(model:GetDescendants()) do
					if child:IsA('Sound') then
						n += 1
					end
				end
				return n
			end

			expect(function()
				LevelUpPresentation.PlayUpgradeVfx(model)
			end).to.never.throw()
			-- VFX mounted (visuals unaffected)...
			expect(root:FindFirstChildWhichIsA('Attachment', true) ~= nil).to.equal(true)
			-- ...but no Sound survives anywhere on the model.
			expect(workspaceSoundCount()).to.equal(0)

			-- Full notify path: celebration + owner remote, still
			-- zero Workspace audio.
			local id = 'BR_lvlup_silent'
			local record: any = {
				uniqueId = id,
				ownerUserId = 9912,
				Level = 2,
				XP = 0,
				state = 'Slotted',
				controller = nil,
				model = model,
			}
			AnimalService._TestRegister(record)
			expect(function()
				LevelUpPresentation.NotifyLevelUp(record, { oldLevel = 1, newLevel = 2, levelsGained = 1 })
			end).to.never.throw()
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(1)
			expect(workspaceSoundCount()).to.equal(0)

			LevelUpPresentation.Cancel(id)
			AnimalService._TestUnregister(id)
			model:Destroy()
			if createdTemplate then
				template:Destroy()
				if createdVfx then
					vfx:Destroy()
				end
				if createdAssets then
					assets:Destroy()
				end
			end
		end)

		it('clones (never mutates) the Attachment-structured Upgrade asset onto the animal', function()
			-- Mirrors the production shape:
			--   Assets.Vfx.Upgrade → Attachment → ParticleEmitter.
			local assets = ServerStorage:FindFirstChild('Assets')
			local createdAssets = false
			if not assets then
				assets = Instance.new('Folder')
				assets.Name = 'Assets'
				assets.Parent = ServerStorage
				createdAssets = true
			end
			local vfx = assets:FindFirstChild('Vfx')
			local createdVfx = false
			if not vfx then
				vfx = Instance.new('Folder')
				vfx.Name = 'Vfx'
				vfx.Parent = assets
				createdVfx = true
			end
			local existing = vfx:FindFirstChild('Upgrade')
			local template: Instance
			local createdTemplate = false
			if existing then
				template = existing
			else
				local folder = Instance.new('Folder')
				folder.Name = 'Upgrade'
				local attachment = Instance.new('Attachment')
				attachment.Name = 'Burst'
				attachment.Position = Vector3.new(0, 1, 0)
				local emitter = Instance.new('ParticleEmitter')
				emitter.Rate = 20
				emitter.Lifetime = NumberRange.new(0.4, 0.8)
				emitter.Parent = attachment
				attachment.Parent = folder
				folder.Parent = vfx
				template = folder
				createdTemplate = true
			end
			local beforeCount = #template:GetChildren()
			local beforeDescendants = #template:GetDescendants()

			local model = Instance.new('Model')
			model.Name = 'Celebrant'
			local root = Instance.new('Part')
			root.Name = 'HumanoidRootPart'
			root.Size = Vector3.new(2, 2, 2)
			root.Anchored = true
			root.Parent = model
			model.PrimaryPart = root
			model.Parent = game:GetService('Workspace')

			-- Synchronous VFX playback: deterministic assertions.
			expect(function()
				LevelUpPresentation.PlayUpgradeVfx(model)
			end).to.never.throw()
			-- Original asset untouched; the clone's Attachment was
			-- re-homed under the PrimaryPart (attachments only
			-- resolve under a BasePart) with its emitter inside.
			expect(#template:GetChildren()).to.equal(beforeCount)
			expect(#template:GetDescendants()).to.equal(beforeDescendants)
			local mounted = root:FindFirstChildWhichIsA('Attachment', true)
			expect(mounted ~= nil).to.equal(true)
			assert(mounted ~= nil, 're-homed attachment present')
			expect(mounted:FindFirstChildWhichIsA('ParticleEmitter', true) ~= nil).to.equal(true)

			local id = 'BR_lvlup06'
			local record: any = {
				uniqueId = id,
				ownerUserId = 9906,
				Level = 2,
				XP = 0,
				state = 'Slotted',
				controller = nil,
				model = model,
			}
			AnimalService._TestRegister(record)
			expect(function()
				LevelUpPresentation.NotifyLevelUp(record, { oldLevel = 1, newLevel = 2, levelsGained = 1 })
			end).to.never.throw()
			expect(LevelUpPresentation._TestGeneration(id)).to.equal(1)

			LevelUpPresentation.Cancel(id)
			AnimalService._TestUnregister(id)
			model:Destroy()
			if createdTemplate then
				template:Destroy()
				if createdVfx then
					vfx:Destroy()
				end
				if createdAssets then
					assets:Destroy()
				end
			end
		end)

		it('rapid spam leaves the model exactly grounded (no Y ratchet)', function()
			-- Regression test for the Y-drift ratchet: every
			-- superseding celebration used to re-capture the
			-- ground reference mid-hop and bake the in-flight
			-- lift into its "exact restore". Spam upgrades with
			-- mid-air supersedes, then assert the final pivot
			-- equals the canonical rest pivot (no pickup/place
			-- required) and scale is unchanged.
			LevelUpPresentation.SetWeightProvider(nil) -- isolate position: no growth
			local model = Instance.new('Model')
			model.Name = 'DriftCheck'
			local root = Instance.new('Part')
			root.Name = 'HumanoidRootPart'
			root.Size = Vector3.new(2, 2, 2)
			root.Anchored = true
			root.CFrame = CFrame.new(0, 5, 0)
			root.Parent = model
			model.PrimaryPart = root
			model.Parent = game:GetService('Workspace')
			local id = 'BR_lvlup_drift'
			local record: any = {
				uniqueId = id,
				ownerUserId = 9911,
				Level = 2,
				XP = 0,
				state = 'Slotted',
				controller = nil,
				model = model,
			}
			AnimalService._TestRegister(record)
			local restPivot: CFrame = model:GetPivot()
			local restScale: number = model:GetScale()
			-- Spam 6 celebrations 0.12s apart: each new burst
			-- supersedes the previous mid-hop (celebration is
			-- ~0.68s), which is exactly the old ratchet trigger.
			for i = 1, 6 do
				LevelUpPresentation.NotifyLevelUp(record, { oldLevel = i, newLevel = i + 1, levelsGained = 1 })
				if i < 6 then
					task.wait(0.12)
				end
			end
			-- Vacuity guard: prove the bop actually ran (model
			-- left the ground at some point), otherwise a dead
			-- celebration would pass the final assert for free.
			local sawAirborne = false
			local deadline = os.clock() + 1.0
			while os.clock() < deadline do
				if model.Parent == nil then
					break
				end
				if model:GetPivot().Y > restPivot.Y + 0.15 then
					sawAirborne = true
					break
				end
				task.wait()
			end
			expect(sawAirborne).to.equal(true)
			-- Let the final celebration complete (~0.68s tail).
			task.wait(1.5)
			local finalPivot: CFrame = model:GetPivot()
			expect(math.abs(finalPivot.Position.X - restPivot.Position.X) < 0.01).to.equal(true)
			expect(math.abs(finalPivot.Position.Y - restPivot.Position.Y) < 0.01).to.equal(true)
			expect(math.abs(finalPivot.Position.Z - restPivot.Position.Z) < 0.01).to.equal(true)
			expect(model:GetScale()).to.equal(restScale)
			LevelUpPresentation.Cancel(id)
			AnimalService._TestUnregister(id)
			model:Destroy()
		end)
	end)
end
