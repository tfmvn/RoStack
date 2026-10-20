--!strict
--!native
--[[
	TutorialService.spec
	====================
	Tests for the tutorial guide layer's pure core
	(ServerScriptService/Tutorial/TutorialService.lua):
	  * step order / terminal state
	  * NextStep full happy chain (exact identity matching)
	  * wrong-id / wrong-slot / wrong-step events ignored
	  * cancel revert, gated continue, completed terminal
	  * DeriveResume join/rejoin mapping with fake lookups
	  * client step-text mapping (display only)

	Service wiring (bus subscriptions, remotes, persistence
	writes, tagging) runs in Studio; specs assert the
	decision logic that drives it. No threads started here
	(never Init/Start).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local StarterPlayer = game:GetService('StarterPlayer')

	local TutorialService = require(ServerScriptService.Tutorial.TutorialService)
	local TutorialController = require(StarterPlayer.StarterPlayerScripts.TutorialController)

	local function state(step: string, eggId: string?, animalId: string?): any
		return { Step = step, EggId = eggId, AnimalId = animalId }
	end

	describe('TutorialService steps', function()
		it('has exactly one terminal state at the end of the chain', function()
			local order = {
				'BuyEgg',
				'WaitForEgg',
				'HatchEgg',
				'PickUpAnimal',
				'PlaceAnimal',
				'StartArena',
				'ArenaStarted',
				'ArenaEnded',
				'UpgradeAnimal',
				'LockBase',
				'Completed',
			}
			for _, name in ipairs(order) do
				expect(TutorialService.Step[name]).to.equal(name)
			end
			-- Completed accepts nothing further.
			local done = state('Completed', nil, nil)
			expect(TutorialService.NextStep(done, { Name = 'EggPurchased', EggId = 'EG_1' })).to.equal(nil)
			expect(TutorialService.NextStep(done, { Name = 'BaseLocked' })).to.equal(nil)
		end)

		it('advances the full happy chain on exact identity matches', function()
			local s0 = state('BuyEgg', nil, nil)
			local s1 = TutorialService.NextStep(s0, { Name = 'EggPurchased', EggId = 'EG_1' })
			expect(s1 ~= nil).to.equal(true)
			expect(s1.Step).to.equal('WaitForEgg')
			expect(s1.EggId).to.equal('EG_1')
			local s2 = TutorialService.NextStep(s1, { Name = 'EggPlaced', EggId = 'EG_1' })
			expect(s2.Step).to.equal('HatchEgg')
			local s3 = TutorialService.NextStep(s2, { Name = 'EggHatched', EggId = 'EG_1', AnimalId = 'AN_1' })
			expect(s3.Step).to.equal('PickUpAnimal')
			expect(s3.AnimalId).to.equal('AN_1')
			expect(s3.EggId).to.equal(nil)
			local s4 = TutorialService.NextStep(s3, { Name = 'AnimalPickedUp', AnimalId = 'AN_1' })
			expect(s4.Step).to.equal('PlaceAnimal')
			local s5 =
				TutorialService.NextStep(s4, { Name = 'AnimalPlaced', AnimalId = 'AN_1', SlotId = 'p7:1:slot:1001' })
			expect(s5.Step).to.equal('StartArena')
			local s6 = TutorialService.NextStep(s5, { Name = 'ArenaStarted' })
			expect(s6.Step).to.equal('ArenaStarted')
			local s7 = TutorialService.NextStep(s6, { Name = 'ArenaEnded' })
			expect(s7.Step).to.equal('ArenaEnded')
			local s8 = TutorialService.NextStep(s7, { Name = 'ContinueConfirmed' })
			expect(s8.Step).to.equal('UpgradeAnimal')
			local s9 = TutorialService.NextStep(s8, { Name = 'AnimalUpgraded', AnimalId = 'AN_1' })
			expect(s9.Step).to.equal('LockBase')
			local s10 = TutorialService.NextStep(s9, { Name = 'BaseLocked' })
			expect(s10.Step).to.equal('Completed')
			expect(s10.EggId).to.equal(nil)
			expect(s10.AnimalId).to.equal(nil)
		end)

		it('ignores wrong ids, wrong slots, and wrong steps', function()
			-- A different egg arriving changes nothing.
			local waiting = state('WaitForEgg', 'EG_1', nil)
			expect(TutorialService.NextStep(waiting, { Name = 'EggPlaced', EggId = 'EG_9' })).to.equal(nil)
			-- Hatching a different egg changes nothing.
			local hatching = state('HatchEgg', 'EG_1', nil)
			expect(TutorialService.NextStep(hatching, { Name = 'EggHatched', EggId = 'EG_9', AnimalId = 'AN_9' })).to.equal(
				nil
			)
			-- Hatch without an animal id never tracks.
			expect(TutorialService.NextStep(hatching, { Name = 'EggHatched', EggId = 'EG_1' })).to.equal(nil)
			-- Picking up another animal changes nothing.
			local carrying = state('PickUpAnimal', nil, 'AN_1')
			expect(TutorialService.NextStep(carrying, { Name = 'AnimalPickedUp', AnimalId = 'AN_9' })).to.equal(nil)
			-- Placing the tracked animal into a NON-arena slot
			-- does not complete the fight-slot step.
			local placing = state('PlaceAnimal', nil, 'AN_1')
			expect(
				TutorialService.NextStep(placing, { Name = 'AnimalPlaced', AnimalId = 'AN_1', SlotId = 'p7:1:slot:3' })
			).to.equal(nil)
			-- Upgrading another animal changes nothing.
			local upgrading = state('UpgradeAnimal', nil, 'AN_1')
			expect(TutorialService.NextStep(upgrading, { Name = 'AnimalUpgraded', AnimalId = 'AN_9' })).to.equal(nil)
			-- Events for other steps are ignored (purchase while
			-- waiting keeps the FIRST egg — first purchase wins).
			expect(TutorialService.NextStep(waiting, { Name = 'EggPurchased', EggId = 'EG_2' })).to.equal(nil)
			-- Unknown event names never transition.
			expect(TutorialService.NextStep(waiting, { Name = 'Nope' })).to.equal(nil)
			-- Bad inputs never transition.
			expect(TutorialService.NextStep(nil, { Name = 'EggPurchased' })).to.equal(nil)
			expect(TutorialService.NextStep(waiting, nil)).to.equal(nil)
		end)

		it('reverts arena cancel and gates continue on ArenaEnded', function()
			local live = state('ArenaStarted', nil, 'AN_1')
			local back = TutorialService.NextStep(live, { Name = 'ArenaCancelled' })
			expect(back.Step).to.equal('StartArena')
			expect(back.AnimalId).to.equal('AN_1')
			-- Continue from any other step is ignored.
			expect(TutorialService.NextStep(live, { Name = 'ContinueConfirmed' })).to.equal(nil)
			expect(TutorialService.NextStep(state('StartArena', nil, 'AN_1'), { Name = 'ContinueConfirmed' })).to.equal(
				nil
			)
			-- Lock completion only fires from LockBase.
			expect(TutorialService.NextStep(live, { Name = 'BaseLocked' })).to.equal(nil)
		end)

		it('REGRESSION (Studio log): hatch advances to PickUpAnimal, never back to BuyEgg', function()
			-- Mirrors the real 21:11 sequence egg-for-egg:
			-- purchase EG_peLLyidbMB -> WaitForEgg -> arrival ->
			-- HatchEgg -> hatch result AN_PoqUxlmWFe.
			local bought =
				TutorialService.NextStep(state('BuyEgg', nil, nil), { Name = 'EggPurchased', EggId = 'EG_peLLyidbMB' })
			expect(bought.Step).to.equal('WaitForEgg')
			expect(bought.EggId).to.equal('EG_peLLyidbMB')
			local arrived = TutorialService.NextStep(bought, { Name = 'EggPlaced', EggId = 'EG_peLLyidbMB' })
			expect(arrived.Step).to.equal('HatchEgg')
			local hatched = TutorialService.NextStep(arrived, {
				Name = 'EggHatched',
				EggId = 'EG_peLLyidbMB',
				AnimalId = 'AN_PoqUxlmWFe',
			})
			expect(hatched.Step).to.equal('PickUpAnimal')
			expect(hatched.AnimalId).to.equal('AN_PoqUxlmWFe')
			expect(hatched.EggId).to.equal('EG_peLLyidbMB')
		end)
	end)

	describe('TutorialService.DeriveResume', function()
		local function lookup(eggs: any, animals: any, owned: string?): any
			return {
				eggById = function(id: string)
					return eggs[id]
				end,
				animalById = function(id: string)
					return animals[id]
				end,
				ownedUnhatchedEggId = function()
					return owned
				end,
			}
		end

		it('keeps Completed terminal and starts fresh buyers at BuyEgg', function()
			local done = TutorialService.DeriveResume({ Completed = true }, lookup({}, {}, nil))
			expect(done.Step).to.equal('Completed')
			local fresh = TutorialService.DeriveResume({ Completed = false }, lookup({}, {}, nil))
			expect(fresh.Step).to.equal('BuyEgg')
		end)

		it('adopts an already-owned unhatched egg instead of repeating BuyEgg', function()
			local resumed =
				TutorialService.DeriveResume({ Completed = false, Step = 'BuyEgg' }, lookup({}, {}, 'EG_owned'))
			expect(resumed.Step).to.equal('HatchEgg')
			expect(resumed.EggId).to.equal('EG_owned')
		end)

		it('keeps live tracked eggs and falls back along the chain', function()
			local live = { state = 'Traveling' }
			local kept = TutorialService.DeriveResume(
				{ Completed = false, Step = 'WaitForEgg', EggId = 'EG_1' },
				lookup({ EG_1 = live }, {}, nil)
			)
			expect(kept.Step).to.equal('WaitForEgg')
			expect(kept.EggId).to.equal('EG_1')
			local adopted = TutorialService.DeriveResume(
				{ Completed = false, Step = 'WaitForEgg', EggId = 'EG_gone' },
				lookup({}, {}, 'EG_owned')
			)
			expect(adopted.Step).to.equal('HatchEgg')
			expect(adopted.EggId).to.equal('EG_owned')
			local fallback = TutorialService.DeriveResume(
				{ Completed = false, Step = 'HatchEgg', EggId = 'EG_gone' },
				lookup({}, {}, nil)
			)
			expect(fallback.Step).to.equal('BuyEgg')
		end)

		it('REGRESSION (Studio log): mid-hatch Opening egg with destroyed model stays in HatchEgg', function()
			-- During the ~5s hatch roll the egg record reads
			-- { state = Opening, model = nil } (EggService
			-- destroys the model before the roulette). The old
			-- model-liveness lookup read that as "gone" and the
			-- 1 Hz recovery reset HatchEgg -> BuyEgg mid-hatch.
			-- Record existence is the liveness rule now.
			local opening = { state = 'Opening', model = nil }
			local kept = TutorialService.DeriveResume(
				{ Completed = false, Step = 'HatchEgg', EggId = 'EG_peLLyidbMB' },
				lookup({ EG_peLLyidbMB = opening }, {}, nil)
			)
			expect(kept.Step).to.equal('HatchEgg')
			expect(kept.EggId).to.equal('EG_peLLyidbMB')
		end)

		it('never invents animals: keeps live ones, otherwise falls back to eggs', function()
			local liveAnimal = { state = 'Slotted' }
			local liveEgg = { state = 'Placed' }
			local kept = TutorialService.DeriveResume(
				{ Completed = false, Step = 'UpgradeAnimal', AnimalId = 'AN_1' },
				lookup({}, { AN_1 = liveAnimal }, nil)
			)
			expect(kept.Step).to.equal('UpgradeAnimal')
			expect(kept.AnimalId).to.equal('AN_1')
			local toEgg = TutorialService.DeriveResume(
				{ Completed = false, Step = 'PlaceAnimal', EggId = 'EG_1', AnimalId = 'AN_gone' },
				lookup({ EG_1 = liveEgg }, {}, nil)
			)
			expect(toEgg.Step).to.equal('HatchEgg')
			expect(toEgg.EggId).to.equal('EG_1')
			expect(toEgg.AnimalId).to.equal(nil)
			local toBuy = TutorialService.DeriveResume(
				{ Completed = false, Step = 'PickUpAnimal', AnimalId = 'AN_gone' },
				lookup({}, {}, nil)
			)
			expect(toBuy.Step).to.equal('BuyEgg')
		end)
	end)

	describe('TutorialController text map', function()
		it('maps every active step to its prompt text', function()
			expect(TutorialController._TestTextFor('BuyEgg', false)).to.equal('Go buy a Common Egg!')
			expect(TutorialController._TestTextFor('WaitForEgg', false)).to.equal(
				'Wait for your egg to reach your base!'
			)
			expect(TutorialController._TestTextFor('HatchEgg', false)).to.equal('Hatch the egg!')
			expect(TutorialController._TestTextFor('PickUpAnimal', false)).to.equal('Pick up your animal!')
			expect(TutorialController._TestTextFor('PlaceAnimal', false)).to.equal(
				'Place your animal in an Arena slot!'
			)
			expect(TutorialController._TestTextFor('StartArena', false)).to.equal('Start an Arena!')
			expect(TutorialController._TestTextFor('StartArena', true)).to.equal("Let's see what your animal can do!")
			expect(TutorialController._TestTextFor('ArenaStarted', false)).to.equal('Arena in progress — good luck!')
			expect(TutorialController._TestTextFor('ArenaEnded', false)).to.equal('Arena complete! Continue.')
			expect(TutorialController._TestTextFor('UpgradeAnimal', false)).to.equal('Upgrade your animal!')
			expect(TutorialController._TestTextFor('LockBase', false)).to.equal('Lock your base!')
			expect(TutorialController._TestTextFor('Completed', false)).to.equal(nil)
			expect(TutorialController._TestTextFor('Nope', false)).to.equal(nil)
		end)

		it('pins the tutorial beam asset id', function()
			expect(TutorialService.BeamAssetId()).to.equal(17476697388)
		end)

		it('finds the Studio-authored HUD.Tutorial label without creating UI', function()
			local root = Instance.new('Folder')
			local hud = Instance.new('Folder')
			hud.Name = 'HUD'
			hud.Parent = root
			expect(TutorialController._TestFindTutorialLabel(root)).to.equal(nil)
			local label = Instance.new('TextLabel')
			label.Name = 'Tutorial'
			label.Parent = hud
			expect(TutorialController._TestFindTutorialLabel(root)).to.equal(label)
			-- A bare container resolves to its text child.
			label:Destroy()
			local wrap = Instance.new('Frame')
			wrap.Name = 'Tutorial'
			wrap.Parent = hud
			local inner = Instance.new('TextLabel')
			inner.Name = 'Inner'
			inner.Parent = wrap
			expect(TutorialController._TestFindTutorialLabel(root)).to.equal(inner)
			-- Wrong class with no text child is ignored, never created.
			inner:Destroy()
			expect(TutorialController._TestFindTutorialLabel(root)).to.equal(nil)
			expect(TutorialController._TestFindTutorialLabel(nil)).to.equal(nil)
			root:Destroy()
		end)

		it('builds a white fallback beam and named attachments', function()
			local beam = TutorialController.BuildFallbackBeam()
			expect(beam ~= nil).to.equal(true)
			expect((beam :: Beam):IsA('Beam')).to.equal(true)
			expect((beam :: Beam).FaceCamera).to.equal(true)
			local host = Instance.new('Part')
			local a1 = TutorialController.EnsureAttachment(host, 'TutorialBeamRoot')
			expect(a1 ~= nil).to.equal(true)
			-- Second call reuses the live attachment (no duplicates).
			local a2 = TutorialController.EnsureAttachment(host, 'TutorialBeamRoot')
			expect(a2).to.equal(a1)
			local count = 0
			for _, child in ipairs(host:GetChildren()) do
				if child:IsA('Attachment') then
					count += 1
				end
			end
			expect(count).to.equal(1)
			expect(TutorialController.EnsureAttachment(nil, 'X')).to.equal(nil)
			host:Destroy()
			if beam ~= nil then
				pcall(function()
					(beam :: Beam):Destroy()
				end)
			end
		end)

		it('upgrades a fallback beam once asset 17476697388 replicates late', function()
			local ReplicatedStorage = game:GetService('ReplicatedStorage')
			-- Stash a real template if the place has one; the test
			-- needs a template-free start to prove the fallback.
			local realTemplate = ReplicatedStorage:FindFirstChild('TutorialBeamTemplate')
			if realTemplate then
				realTemplate.Parent = nil
			end
			TutorialController._TestResetBeam()
			local first = TutorialController._TestEnsureBeam()
			expect(first ~= nil).to.equal(true)
			expect(TutorialController._TestIsAssetBeam()).to.equal(false)
			-- Late replication: fake asset template with a Beam.
			local fakeTemplate = Instance.new('Model')
			fakeTemplate.Name = 'TutorialBeamTemplate'
			local assetBeam = Instance.new('Beam')
			assetBeam.Name = 'AssetBeam'
			assetBeam.Parent = fakeTemplate
			fakeTemplate.Parent = ReplicatedStorage
			local second = TutorialController._TestEnsureBeam()
			expect(second ~= nil).to.equal(true)
			expect(TutorialController._TestIsAssetBeam()).to.equal(true)
			-- The live beam is a clone of the asset beam, and the
			-- stale fallback is gone.
			expect(second).never.to.equal(first)
			expect(second).never.to.equal(assetBeam)
			expect((second :: Beam).Parent).to.equal(Workspace)
			expect(first.Parent).to.equal(nil)
			-- Steady state afterwards: same beam, no rebuild.
			local third = TutorialController._TestEnsureBeam()
			expect(third).to.equal(second)
			TutorialController._TestResetBeam()
			expect(TutorialController._TestIsAssetBeam()).to.equal(false)
			fakeTemplate:Destroy()
			if realTemplate then
				realTemplate.Parent = ReplicatedStorage
			end
		end)

		it('derives the actual-steps checklist from every internal step', function()
			local function check(step: string, count: number, doneCount: number, current: number?)
				local derived = TutorialController._TestChecklistFor(step)
				expect(derived.Count).to.equal(count)
				expect(derived.Total).to.equal(10)
				local n = 0
				for i = 1, 10 do
					if derived.Done[i] then
						n += 1
					end
				end
				expect(n).to.equal(doneCount)
				expect(derived.Current).to.equal(current)
			end
			check('BuyEgg', 0, 0, 1)
			check('WaitForEgg', 1, 1, 2)
			check('HatchEgg', 2, 2, 3)
			check('PickUpAnimal', 3, 3, 4)
			check('PlaceAnimal', 4, 4, 5)
			check('StartArena', 5, 5, 6)
			check('ArenaStarted', 6, 6, 7)
			check('ArenaEnded', 7, 7, 8)
			check('UpgradeAnimal', 8, 8, 9)
			check('LockBase', 9, 9, 10)
			check('Completed', 10, 10, nil)
			check('Nope', 0, 0, 1)
		end)

		it('skip intent payload is the gated server action', function()
			local payload = TutorialController._TestSkipPayload()
			expect(payload.Action).to.equal('Skip')
		end)

		it('resolves client sound templates from an injected root', function()
			local root = Instance.new('Folder')
			expect(TutorialController._TestResolveSfx('Pop', root)).to.equal(nil)
			local assets = Instance.new('Folder')
			assets.Name = 'Assets'
			assets.Parent = root
			local sfx = Instance.new('Folder')
			sfx.Name = 'Sfx'
			sfx.Parent = assets
			local pop = Instance.new('Sound')
			pop.Name = 'Pop'
			pop.SoundId = 'rbxassetid://999'
			pop.Parent = sfx
			expect(TutorialController._TestResolveSfx('Pop', root)).to.equal('rbxassetid://999')
			expect(TutorialController._TestResolveSfx('Approved', root)).to.equal(nil)
			expect(TutorialController._TestResolveSfx('', root)).to.equal(nil)
			root:Destroy()
		end)

		it('typewriter aborts the stale task so only the newest text lands', function()
			TutorialController._TestSetTypeInterval(0)
			local holder = Instance.new('Folder')
			local label = Instance.new('TextLabel')
			label.Parent = holder
			TutorialController._TestTypeText(label, 'AAAAAA')
			TutorialController._TestTypeText(label, 'B')
			local start = os.clock()
			while label.Text ~= 'B' and os.clock() - start < 2 do
				task.wait()
			end
			expect(label.Text).to.equal('B')
			TutorialController._TestSetTypeInterval(0.03)
			holder:Destroy()
		end)
	end)

	describe('TutorialController spotlight + beats', function()
		it('times UI-open instruction beats without hardcoding paths', function()
			local text1, key1 = TutorialController._TestBeatFor('StartArena', true, 0)
			expect(text1).to.equal("Let's see what your animal can do!")
			expect(key1).to.equal('StartArena:open:1')
			local text2, key2 = TutorialController._TestBeatFor('StartArena', true, 30)
			expect(text2).to.equal('Press to start arena!')
			expect(key2).to.equal('StartArena:open:2')
			local text3, key3 = TutorialController._TestBeatFor('ArenaEnded', true, 0)
			expect(text3).to.equal('Great job! Your arena is complete.')
			expect(key3).to.equal('ArenaEnded:open:1')
			local text4, key4 = TutorialController._TestBeatFor('ArenaEnded', true, 30)
			expect(text4).to.equal('Continue!')
			expect(key4).to.equal('ArenaEnded:open:2')
			-- Closed UI and unrelated steps have no beat.
			local text5, key5 = TutorialController._TestBeatFor('StartArena', false, 0)
			expect(text5).to.equal(nil)
			expect(key5).to.equal(nil)
			local text6, _ = TutorialController._TestBeatFor('BuyEgg', true, 0)
			expect(text6).to.equal(nil)
		end)

		it('spotlights the real button and restores it on teardown', function()
			local root = Instance.new('Folder')
			local button = Instance.new('TextButton')
			button.Name = 'Buy3'
			button.ZIndex = 3
			button.Parent = root
			TutorialController._TestUpdateSpotlight(button)
			-- Real button lifted above the dimmer.
			expect(button.ZIndex).to.equal(100)
			-- Exactly one ring and one owned scale.
			local rings = 0
			local scales = 0
			for _, child in ipairs(button:GetChildren()) do
				if child:IsA('UIStroke') and child.Name == 'TutorialRing' then
					rings += 1
				end
				if child:IsA('UIScale') and child.Name == 'TutorialSpotScale' then
					scales += 1
				end
			end
			expect(rings).to.equal(1)
			expect(scales).to.equal(1)
			-- Same button again: no stacking, tweens keep looping.
			TutorialController._TestUpdateSpotlight(button)
			local rings2 = 0
			for _, child in ipairs(button:GetChildren()) do
				if child:IsA('UIStroke') and child.Name == 'TutorialRing' then
					rings2 += 1
				end
			end
			expect(rings2).to.equal(1)
			expect(button.ZIndex).to.equal(100)
			-- Teardown restores the Studio-authored look exactly.
			TutorialController._TestClearSpotlight()
			expect(button.ZIndex).to.equal(3)
			expect(button:FindFirstChild('TutorialSpotScale')).to.equal(nil)
			expect(button:FindFirstChild('TutorialRing')).to.equal(nil)
			-- Idempotent: safe to clear twice.
			TutorialController._TestClearSpotlight()
			expect(button.ZIndex).to.equal(3)
			root:Destroy()
		end)

		it('reuses a Studio UIScale instead of stacking its own', function()
			local root = Instance.new('Folder')
			local button = Instance.new('TextButton')
			button.ZIndex = 7
			button.Parent = root
			local studioScale = Instance.new('UIScale')
			studioScale.Scale = 2
			studioScale.Parent = button
			TutorialController._TestUpdateSpotlight(button)
			-- Same instance reused (not destroyed, not duplicated).
			expect(button:FindFirstChildWhichIsA('UIScale', false)).to.equal(studioScale)
			expect(button:FindFirstChild('TutorialSpotScale')).to.equal(nil)
			TutorialController._TestClearSpotlight()
			-- Studio scale survives with its original value.
			expect(studioScale.Parent).to.equal(button)
			expect(studioScale.Scale).to.equal(2)
			expect(button.ZIndex).to.equal(7)
			root:Destroy()
		end)

		it('switching buttons tears down the old spotlight first', function()
			local root = Instance.new('Folder')
			local first = Instance.new('TextButton')
			first.ZIndex = 3
			first.Parent = root
			local second = Instance.new('TextButton')
			second.ZIndex = 4
			second.Parent = root
			TutorialController._TestUpdateSpotlight(first)
			expect(first.ZIndex).to.equal(100)
			TutorialController._TestUpdateSpotlight(second)
			expect(first.ZIndex).to.equal(3)
			expect(first:FindFirstChild('TutorialRing')).to.equal(nil)
			expect(second.ZIndex).to.equal(100)
			expect(second:FindFirstChild('TutorialRing') ~= nil).to.equal(true)
			TutorialController._TestClearSpotlight()
			root:Destroy()
		end)

		it('lifts the RightSide chain so nested Continue paints above the dimmer', function()
			local root = Instance.new('Frame')
			local right = Instance.new('Frame')
			right.Name = 'RightSide'
			right.ZIndex = 5
			right.Parent = root
			local button = Instance.new('TextButton')
			button.Name = 'Continue'
			button.ZIndex = 6
			button.Parent = right
			TutorialController._TestUpdateSpotlight(button, root)
			expect(button.ZIndex).to.equal(100)
			-- Sibling-scoped dimming buries nested buttons unless
			-- the ancestor chain is lifted too.
			expect(right.ZIndex).to.equal(100)
			expect(button:FindFirstChild('TutorialRing') ~= nil).to.equal(true)
			TutorialController._TestClearSpotlight()
			expect(button.ZIndex).to.equal(6)
			expect(right.ZIndex).to.equal(5)
			expect(button:FindFirstChild('TutorialRing')).to.equal(nil)
			root:Destroy()
		end)

		it('pivots to the button center and restores the authored corner', function()
			local root = Instance.new('Folder')
			local button = Instance.new('TextButton')
			button.AnchorPoint = Vector2.new(0, 0)
			button.Position = UDim2.fromScale(0.2, 0.3)
			button.Size = UDim2.fromScale(0.4, 0.1)
			button.Parent = root
			TutorialController._TestUpdateSpotlight(button)
			-- Centered pulse (UIScale on a (0, 0) button would
			-- otherwise grow toward the bottom-right).
			expect(button.AnchorPoint).to.equal(Vector2.new(0.5, 0.5))
			TutorialController._TestClearSpotlight()
			expect(button.AnchorPoint).to.equal(Vector2.new(0, 0))
			expect(button.Position).to.equal(UDim2.fromScale(0.2, 0.3))
			root:Destroy()
		end)
	end)

	describe('multiplayer tutorial egg targeting (starter + per-player ids)', function()
		it('starter rarity is the cheapest EggConfig egg, never hardcoded', function()
			local ReplicatedStorage = game:GetService('ReplicatedStorage')
			local Eggs = require(ReplicatedStorage.Config.Creatures.Eggs)
			-- Cheapest Price entry today is Common at 100.
			expect(Eggs.GetStarterRarity()).to.equal('Common')
			-- Server helper agrees with the config helper.
			expect(TutorialService.StarterEggRarity()).to.equal(Eggs.GetStarterRarity())
		end)

		it('tutorial tags are per-player, never a shared global tag', function()
			expect(TutorialService.TagFor(123)).to.equal('TutorialTarget_123')
			expect(TutorialService.TagFor(456)).to.equal('TutorialTarget_456')
			expect(TutorialService.TagFor(123)).never.to.equal(TutorialService.TagFor(456))
			expect(TutorialController._TestTagNameFor(123)).to.equal('TutorialTarget_123')
			expect(TutorialController._TestTagNameFor(456)).to.equal('TutorialTarget_456')
			-- Client and server derive the SAME per-player tag.
			expect(TutorialController._TestTagNameFor(123)).to.equal(TutorialService.TagFor(123))
		end)

		it('BuyEgg prompt names the starter egg', function()
			expect(TutorialController._TestTextFor('BuyEgg', false)).to.equal('Go buy a Common Egg!')
		end)

		it("two players track their own purchased egg ids, never each other's", function()
			-- Both start fresh at BuyEgg (no shared target).
			local a0 = state('BuyEgg', nil, nil)
			local b0 = state('BuyEgg', nil, nil)
			-- Player A buys their egg: only A's state moves, and
			-- it stores A's ACTUAL egg id.
			local a1 = TutorialService.NextStep(a0, { Name = 'EggPurchased', EggId = 'EG_A' })
			expect(a1.Step).to.equal('WaitForEgg')
			expect(a1.EggId).to.equal('EG_A')
			-- Player B is untouched by A's purchase.
			expect(b0.Step).to.equal('BuyEgg')
			expect(b0.EggId).to.equal(nil)
			-- Player B buys their own (different) egg.
			local b1 = TutorialService.NextStep(b0, { Name = 'EggPurchased', EggId = 'EG_B' })
			expect(b1.Step).to.equal('WaitForEgg')
			expect(b1.EggId).to.equal('EG_B')
			-- Cross-egg events are ignored: A's egg arriving at
			-- the base does NOT advance B's WaitForEgg(EG_B).
			expect(TutorialService.NextStep(b1, { Name = 'EggPlaced', EggId = 'EG_A' })).to.equal(nil)
			expect(TutorialService.NextStep(a1, { Name = 'EggPlaced', EggId = 'EG_B' })).to.equal(nil)
			-- Own-egg events advance each chain independently.
			local a2 = TutorialService.NextStep(a1, { Name = 'EggPlaced', EggId = 'EG_A' })
			expect(a2.Step).to.equal('HatchEgg')
			expect(a2.EggId).to.equal('EG_A')
			local b2 = TutorialService.NextStep(b1, { Name = 'EggPlaced', EggId = 'EG_B' })
			expect(b2.Step).to.equal('HatchEgg')
			expect(b2.EggId).to.equal('EG_B')
		end)

		it('DeriveResume restores each player from their own persisted egg', function()
			local function lookup(eggs: any, animals: any, owned: string?): any
				return {
					eggById = function(id: string)
						return eggs[id]
					end,
					animalById = function(id: string)
						return animals[id]
					end,
					ownedUnhatchedEggId = function()
						return owned
					end,
				}
			end
			local liveA = { state = 'Traveling' }
			local liveB = { state = 'Traveling' }
			local resumedA = TutorialService.DeriveResume(
				{ Completed = false, Step = 'WaitForEgg', EggId = 'EG_A' },
				lookup({ EG_A = liveA, EG_B = liveB }, {}, nil)
			)
			local resumedB = TutorialService.DeriveResume(
				{ Completed = false, Step = 'WaitForEgg', EggId = 'EG_B' },
				lookup({ EG_A = liveA, EG_B = liveB }, {}, nil)
			)
			expect(resumedA.Step).to.equal('WaitForEgg')
			expect(resumedA.EggId).to.equal('EG_A')
			expect(resumedB.Step).to.equal('WaitForEgg')
			expect(resumedB.EggId).to.equal('EG_B')
		end)

		it('BuyEgg target is starter-only, prompt-gated, container-scoped, purchaser-aware', function()
			-- Hermetic stand-in for Workspace.EggArea.ActiveEggs
			-- (never the live Workspace, never a real base).
			local folder = Instance.new('Folder')
			folder.Name = 'ActiveEggs'
			local function makeEgg(name: string, withPrompt: boolean, purchaser: number?): Model
				local model = Instance.new('Model')
				model.Name = name
				if withPrompt then
					local prompt = Instance.new('ProximityPrompt')
					prompt.Name = 'BuyPrompt'
					if purchaser ~= nil then
						prompt:SetAttribute('purchaserUserId', purchaser)
					end
					prompt.Parent = model
				end
				model.Parent = folder
				return model
			end
			-- Decoy 1: non-starter rarity with a live prompt.
			makeEgg('Rare Egg', true, nil)
			-- Decoy 2: starter egg nested under a base-like
			-- folder (proves no base descent — direct children
			-- only).
			local baseDecoy = Instance.new('Folder')
			baseDecoy.Name = 'Base_1'
			baseDecoy.Parent = folder
			local nested = Instance.new('Model')
			nested.Name = 'Common Egg'
			local nestedPrompt = Instance.new('ProximityPrompt')
			nestedPrompt.Name = 'BuyPrompt'
			nestedPrompt.Parent = nested
			nested.Parent = baseDecoy
			expect(TutorialController._TestFindStarterInFolder(folder, nil, 7)).to.equal(nil)
			-- Decoy 3: starter egg with no BuyPrompt (destroyed/
			-- inactive affordance) is not a target.
			makeEgg('Common Egg', false, nil)
			expect(TutorialController._TestFindStarterInFolder(folder, nil, 7)).to.equal(nil)
			-- Decoy 4: starter egg carrying base-Slot prompts
			-- (ownerUserId-stamped PickupPrompt = a base Slot
			-- owns it) is NEVER a target even with a stale
			-- BuyPrompt still attached.
			local baseEgg = makeEgg('Common Egg', true, nil)
			local pickup = Instance.new('ProximityPrompt')
			pickup.Name = 'PickupPrompt'
			pickup:SetAttribute('ownerUserId', 1234)
			pickup.Parent = baseEgg
			expect(TutorialController._TestFindStarterInFolder(folder, nil, 7)).to.equal(nil)
			baseEgg:Destroy()
			-- Decoy 5: BuyPrompt present but Disabled (e.g.
			-- PromptOwnerFilter hid it while carrying) is not
			-- a live target.
			local quiet = makeEgg('Common Egg', true, nil)
			local quietPrompt = quiet:FindFirstChild('BuyPrompt', true)
			assert(quietPrompt ~= nil);
			(quietPrompt :: ProximityPrompt).Enabled = false
			expect(TutorialController._TestFindStarterInFolder(folder, nil, 7)).to.equal(nil)
			quiet:Destroy()
			-- Contested starter egg (another player's traveling
			-- egg): last-resort fallback, still ActiveEggs-only.
			local contested = makeEgg('Common Egg', true, 999)
			expect(TutorialController._TestFindStarterInFolder(folder, nil, 7)).to.equal(contested)
			-- The purchaser themself can never target their own
			-- traveling egg (server rejects re-buy: dead end).
			expect(TutorialController._TestFindStarterInFolder(folder, nil, 999)).to.equal(nil)
			-- A clean uncontested starter egg wins over the
			-- contested fallback for everyone else.
			local free = makeEgg('Common Egg', true, nil)
			expect(TutorialController._TestFindStarterInFolder(folder, nil, 7)).to.equal(free)
			expect(TutorialController._TestFindStarterInFolder(folder, nil, 555)).to.equal(free)
			folder:Destroy()
		end)
	end)
end
