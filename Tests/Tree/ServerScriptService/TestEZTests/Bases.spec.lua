--!strict
--!native
--[[
	Bases.spec
	==========
	World.Bases + World.Prompts invariants (unified-config migration;
	replaces the legacy GameConfig.spec). The slot pool is unified (a
	single Slots.Count, a single Slots.Offsets, a single Slots.Size).
	The Carry action config has per-kind sub-tables for both
	lucky eggs and animals. Pins the preserved live values so a
	refactor can never silently rebalance the game.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Bases = require(ReplicatedStorage.Config.World.Bases)
	local Prompts = require(ReplicatedStorage.Config.World.Prompts)
	local CenterSpawn = require(ReplicatedStorage.Config.Creatures.Eggs).CenterSpawn
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	describe('Bases.Slots.Count', function()
		it('is 8', function()
			expect(Bases.Slots.Count).to.equal(8)
		end)

		it('the legacy lucky/animal split counts are gone', function()
			expect((Bases.Slots :: any).LuckyBlockSlotCount).to.equal(nil)
			expect((Bases.Slots :: any).BrainrotSlotCount).to.equal(nil)
		end)
	end)

	describe('Bases.Slots.Size', function()
		it('is a Vector3 with positive X and Z', function()
			expect(Bases.Slots.Size).to.be.a('userdata')
			expect(Bases.Slots.Size.X).to.be.greaterThan(0)
			expect(Bases.Slots.Size.Z).to.be.greaterThan(0)
		end)
	end)

	describe('Bases.Slots.Offsets', function()
		it('has exactly Slots.Count entries', function()
			expect(#Bases.Slots.Offsets).to.equal(Bases.Slots.Count)
		end)

		it('all offsets have the same Y (flat ring)', function()
			local y0 = Bases.Slots.Offsets[1].Y
			for i = 2, #Bases.Slots.Offsets do
				expect(Bases.Slots.Offsets[i].Y).to.equal(y0)
			end
		end)

		it('all offsets lie on a ring of consistent radius', function()
			local r0 = (Vector3.new(Bases.Slots.Offsets[1].X, 0, Bases.Slots.Offsets[1].Z)).Magnitude
			for i = 2, #Bases.Slots.Offsets do
				local r = (Vector3.new(Bases.Slots.Offsets[i].X, 0, Bases.Slots.Offsets[i].Z)).Magnitude
				expect(math.abs(r - r0)).to.be.near(0, 0.001)
			end
		end)
	end)

	describe('Bases sizing', function()
		it('pins base count + server cap', function()
			expect(Bases.Count).to.equal(8)
			expect(Bases.Server.MaxPlayers).to.equal(5)
		end)

		it('pins the lock duration', function()
			expect(Bases.Lock.LockDurationSeconds).to.equal(60)
		end)
	end)

	describe('Eggs.CenterSpawn', function()
		it('pins the preserved center-spawn baseline', function()
			expect(CenterSpawn.TravelDuration).to.equal(7)
			expect(CenterSpawn.CenterMax).to.equal(10)
			expect(CenterSpawn.MinSpawnSpacing).to.equal(7)
			expect(CenterSpawn.Radius).to.equal(20)
			expect(CenterSpawn.Interval).to.equal(30)
		end)
	end)

	describe('Prompts.Carry', function()
		it('has a per-kind sub-table for both kinds', function()
			expect(Prompts.Carry).to.be.a('table')
			expect(Prompts.Carry.PerKind).to.be.a('table')
			expect(Prompts.Carry.PerKind[SlotType.OccupantKind.Egg]).to.be.a('table')
			expect(Prompts.Carry.PerKind[SlotType.OccupantKind.Animal]).to.be.a('table')
		end)

		it('shared distance + hold stay canonical', function()
			expect(Prompts.CarryMaxDistance).to.equal(8)
			expect(Prompts.CarryHoldDuration).to.equal(1)
		end)

		it('action tables cover every slot state', function()
			expect(Prompts.Carry.Actions[SlotType.OccupantKind.Egg]).to.be.a('table')
			expect(Prompts.Carry.Actions[SlotType.OccupantKind.Animal]).to.be.a('table')
			expect(Prompts.Carry.Actions.Empty).to.be.a('table')
			expect(Prompts.Carry.Actions.Reserved).to.be.a('table')
		end)

		it('each per-kind entry has the prompt text fields', function()
			local egg = Prompts.Carry.PerKind[SlotType.OccupantKind.Egg]
			expect(egg.GrabActionText).to.be.a('string')
			expect(egg.GrabObjectText).to.be.a('string')
			expect(egg.PlaceActionText).to.be.a('string')
			expect(egg.PlaceObjectText).to.be.a('string')
			expect(egg.HatchActionText).to.be.a('string')
			expect(egg.HatchObjectText).to.be.a('string')
			local animal = Prompts.Carry.PerKind[SlotType.OccupantKind.Animal]
			expect(animal.GrabActionText).to.be.a('string')
			expect(animal.GrabObjectText).to.be.a('string')
			expect(animal.PlaceActionText).to.be.a('string')
			expect(animal.PlaceObjectText).to.be.a('string')
		end)
	end)
end
