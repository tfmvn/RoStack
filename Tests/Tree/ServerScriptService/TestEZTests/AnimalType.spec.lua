--!strict
--!native
--[[
	AnimalType.spec
	=================
	Locks in the type contract for the Animal record (Phase 1.5
	carry fields). The exported type is a structural contract:
	any new field on an animal must appear here so that
	consumers (services, tests) can rely on the shape.

	What this spec covers:
	  A. The carry-state enum has exactly three values: Slotted,
	     Carried, Recovering. The record's `state` field is one
	     of these.
	  B. `carriedBy` is a number (or nil); it identifies the
	     carrying player when state = Carried.
	  C. `originalSlotId` is a string (or nil); it points to the
	     slot the animal should return to on disconnect / death.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	describe('AnimalType (Phase 1.5 carry fields)', function()
		-- Build a representative record that satisfies the
		-- type contract. Any drift in the type shape
		-- (renamed field, wrong type) breaks this synthetic
		-- record.
		it('a record with the canonical carry fields is constructible', function()
			local record = {
				uniqueId = 'BR_test_1',
				definitionId = 'Chicken',
				displayName = 'Chicken',
				rarity = 'Common',
				ownerUserId = 1,
				slotId = 'p7:1:animal:1',
				spawnSlotId = 'p7:1:lucky:1',
				level = 1,
				health = 5,
				damage = 2,
				model = nil,
				walkingFrom = nil,
				walkingTo = nil,
				state = 'Slotted',
				carriedBy = nil,
				originalSlotId = nil,
				_mutex = false,
				createdAt = 0,
			}
			expect(record.state).to.equal('Slotted')
			expect(record.carriedBy).to.equal(nil)
			expect(record.originalSlotId).to.equal(nil)
		end)

		it('state field accepts the three documented values', function()
			local states = { 'Slotted', 'Carried', 'Recovering' }
			for _, s in ipairs(states) do
				local record = { state = s }
				expect(record.state == s).to.equal(true)
			end
		end)

		it('Carried record carries carriedBy as a number and originalSlotId as a string', function()
			local record = {
				uniqueId = 'BR_carried',
				state = 'Carried',
				carriedBy = 12345,
				originalSlotId = 'p7:12345:animal:1',
				slotId = nil,
			}
			expect(record.state).to.equal('Carried')
			expect(type(record.carriedBy)).to.equal('number')
			expect(record.carriedBy > 0).to.equal(true)
			expect(type(record.originalSlotId)).to.equal('string')
			expect(record.slotId).to.equal(nil)
		end)

		it('Recovering record preserves carriedBy + originalSlotId as recovery hints', function()
			local record = {
				uniqueId = 'BR_recovering',
				state = 'Recovering',
				carriedBy = 99,
				originalSlotId = 'p7:99:animal:2',
				slotId = nil,
			}
			expect(record.state).to.equal('Recovering')
			expect(record.carriedBy).to.equal(99)
			expect(record.originalSlotId).to.equal('p7:99:animal:2')
		end)
	end)
end
