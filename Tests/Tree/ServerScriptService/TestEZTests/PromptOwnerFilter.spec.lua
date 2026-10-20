--!strict
--!native
--[[
	PromptOwnerFilter.spec
	======================
	Tests for the multi-player prompt visibility rule.

 	The rule (see PromptOwnerFilter.lua header for the full
 	rationale): every ProximityPrompt carries either
 	`ownerUserId` (Pickup / Open / Steal on a placed model) or
 	`targetUserId` (Place on a slot part). Traveling-egg Buy
 	prompts additionally carry `purchaserUserId` (current
 	purchaser only — hidden from them, visible to everyone
 	else). The client-side
 	LocalScript hides any prompt whose attribute is set and
 	doesn't match the local player's UserId. Buy prompts
 	(no purchaser attribute, e.g. center eggs) are visible
 	to all, except the carrying player (server rejects
 	Purchase while carrying). Steal
 	adds two rules: inverse visibility (non-owners only, with
 	a nonzero local Empty-slot count) and fail-closed hiding
 	of marker-less StealPrompts; steal-carriers see nothing.

 	What we test here:
 	  1. CarryPrompts installers stamp the right attribute
 	     on Pickup, Open, and Place prompts. (Server-side
 	     testable via the real CarryPrompts module.)
	  2. The Buy prompt is left without an owner attribute
	     so PromptOwnerFilter treats it as a global prompt.
	  3. The slot's ownerUserId is what we stamp — a prompt
	     installed for owner=42 must show ownerUserId=42.

 	Note: the client-side `shouldShow` rule is pure logic
 	(it doesn't need a Player), so we test it by
 	re-implementing the same rule here and asserting against
 	fake prompt instances. If the rule changes in the
 	LocalScript, mirror it here (including the steal-carry
 	blanket suppression + the Steal inverse-visibility rule).
 ]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local CarryPrompts = require(ServerScriptService.Animal.CarryPrompts)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	-- Re-implementation of PromptOwnerFilter.shouldShow for
	-- testing. Keep in lockstep with the LocalScript (steal
	-- suppression, capacity rule, fail-closed StealPrompt,
	-- traveling-egg purchaser rule, paid door inverse rule).
	local function shouldShow(prompt, localUserId, localCarryKind, localCarrySteal, localFreeSlots)
		-- Thief lockout: steal-carriers see nothing.
		if localCarrySteal then
			return false
		end
		local targetUserId = prompt:GetAttribute('targetUserId')
		if targetUserId ~= nil then
			if type(targetUserId) ~= 'number' then
				return false
			end
			return targetUserId == localUserId
		end
		if prompt:GetAttribute('stealPrompt') == true then
			local ownerUserId = prompt:GetAttribute('ownerUserId')
			if type(ownerUserId) ~= 'number' then
				return false
			end
			if ownerUserId == localUserId then
				return false
			end
			if localFreeSlots == 0 then
				return false
			end
			if localCarryKind ~= nil then
				return false
			end
			return true
		end
		if prompt.Name == 'StealPrompt' then
			return false
		end
		-- Paid door prompt: visible to non-owners only (owner
		-- never sees Open Door on their own base).
		if prompt:GetAttribute('doorPrompt') == true then
			local doorOwner = prompt:GetAttribute('ownerUserId')
			if type(doorOwner) ~= 'number' then
				return false
			end
			return doorOwner ~= localUserId
		end
		local ownerUserId = prompt:GetAttribute('ownerUserId')
		if ownerUserId ~= nil then
			if type(ownerUserId) ~= 'number' then
				return false
			end
			if ownerUserId ~= localUserId then
				return false
			end
			if localCarryKind ~= nil and (prompt.Name == 'PickupPrompt' or prompt.Name == 'HatchPrompt') then
				return false
			end
		end
		if prompt.Name == 'BuyPrompt' and localCarryKind ~= nil then
			return false
		end
		if prompt.Name == 'BuyPrompt' then
			local purchaserUserId = prompt:GetAttribute('purchaserUserId')
			if type(purchaserUserId) == 'number' and purchaserUserId == localUserId then
				return false
			end
		end
		return true
	end

	describe('PromptOwnerFilter.shouldShow rule', function()
		it('Buy prompt visible to non-carrying players', function()
			local p = Instance.new('ProximityPrompt')
			p.Name = 'BuyPrompt'
			-- No ownerUserId / targetUserId — Buy is global.
			expect(shouldShow(p, 100, nil)).to.equal(true)
			expect(shouldShow(p, 200, nil)).to.equal(true)
			p:Destroy()
		end)

		it('Buy prompt hidden for the carrying player', function()
			local p = Instance.new('ProximityPrompt')
			p.Name = 'BuyPrompt'
			expect(shouldShow(p, 100, 'egg')).to.equal(false)
			expect(shouldShow(p, 200, 'animal')).to.equal(false)
			p:Destroy()
		end)

		it('traveling-egg Buy hidden for current purchaser only (prompt matrix)', function()
			-- A buys: A=NONE, B/C=BUY.
			local p = Instance.new('ProximityPrompt')
			p.Name = 'BuyPrompt'
			p:SetAttribute('purchaserUserId', 100)
			expect(shouldShow(p, 100, nil)).to.equal(false)
			expect(shouldShow(p, 200, nil)).to.equal(true)
			expect(shouldShow(p, 300, nil)).to.equal(true)
			-- B rebuys (re-stamp): B=NONE, A/C=BUY.
			p:SetAttribute('purchaserUserId', 200)
			expect(shouldShow(p, 100, nil)).to.equal(true)
			expect(shouldShow(p, 200, nil)).to.equal(false)
			expect(shouldShow(p, 300, nil)).to.equal(true)
			-- No stamp (center egg): visible to all.
			p:SetAttribute('purchaserUserId', nil)
			expect(shouldShow(p, 100, nil)).to.equal(true)
			expect(shouldShow(p, 200, nil)).to.equal(true)
			p:Destroy()
		end)

		it('Pickup/Hatch with ownerUserId is visible only to owner', function()
			local p = Instance.new('ProximityPrompt')
			p.Name = 'PickupPrompt'
			p:SetAttribute('ownerUserId', 42)
			expect(shouldShow(p, 42, nil)).to.equal(true)
			expect(shouldShow(p, 99, nil)).to.equal(false)
			p:Destroy()
		end)

		it('Pickup/Hatch hidden for owner while owner is carrying', function()
			-- Same prompt, same owner, but the owner is
			-- now carrying something. The Place prompt
			-- (handled below) stays visible; Pickup/Open
			-- on the owner's own base must hide so the
			-- carrier doesn't see useless affordances.
			local pickup = Instance.new('ProximityPrompt')
			pickup.Name = 'PickupPrompt'
			pickup:SetAttribute('ownerUserId', 42)
			expect(shouldShow(pickup, 42, 'egg')).to.equal(false)
			expect(shouldShow(pickup, 42, 'animal')).to.equal(false)
			expect(shouldShow(pickup, 42, nil)).to.equal(true)
			pickup:Destroy()

			local open = Instance.new('ProximityPrompt')
			open.Name = 'HatchPrompt'
			open:SetAttribute('ownerUserId', 42)
			expect(shouldShow(open, 42, 'egg')).to.equal(false)
			expect(shouldShow(open, 42, nil)).to.equal(true)
			open:Destroy()
		end)

		it('Place prompt visible to its carrier even while carrying', function()
			local p = Instance.new('ProximityPrompt')
			p.Name = 'PlacePrompt'
			p:SetAttribute('targetUserId', 42)
			-- Carrier sees their own Place prompts.
			expect(shouldShow(p, 42, 'egg')).to.equal(true)
			expect(shouldShow(p, 42, 'animal')).to.equal(true)
			-- Non-carrier never sees another player's Place.
			expect(shouldShow(p, 99, nil)).to.equal(false)
			p:Destroy()
		end)

		it('Place prompt with targetUserId is visible only to carrier', function()
			local p = Instance.new('ProximityPrompt')
			p.Name = 'PlacePrompt'
			p:SetAttribute('targetUserId', 42)
			expect(shouldShow(p, 42, nil)).to.equal(true)
			expect(shouldShow(p, 99, nil)).to.equal(false)
			p:Destroy()
		end)

		it('prompt with non-number attribute is hidden', function()
			-- Defensive: if the server accidentally stamps a
			-- string instead of a number, the rule should
			-- fail closed (hide the prompt) rather than
			-- match everyone.
			local p = Instance.new('ProximityPrompt')
			p.Name = 'PickupPrompt'
			p:SetAttribute('ownerUserId', 'oops')
			expect(shouldShow(p, 'oops', nil)).to.equal(false)
			p:Destroy()
		end)

		it('Steal prompt is visible only to non-owners', function()
			local p = Instance.new('ProximityPrompt')
			p.Name = 'StealPrompt'
			p:SetAttribute('stealPrompt', true)
			p:SetAttribute('ownerUserId', 42)
			-- Strangers see it; the owner never does.
			expect(shouldShow(p, 99, nil)).to.equal(true)
			expect(shouldShow(p, 42, nil)).to.equal(false)
			-- Carriers (any kind) don't see it either.
			expect(shouldShow(p, 99, 'egg')).to.equal(false)
			-- Full destination base hides it (server rejects
			-- before pickup anyway).
			expect(shouldShow(p, 99, nil, false, 0)).to.equal(false)
			expect(shouldShow(p, 99, nil, false, 3)).to.equal(true)
			expect(shouldShow(p, 99, nil, false, nil)).to.equal(true)
			p:Destroy()
		end)

		it(
			'marker-less StealPrompt is hidden for everyone (fail closed)',
			function() -- Half-installed prompt (parented before attributes
				-- stamped, or marker stripped): never visible.
				local p = Instance.new('ProximityPrompt')
				p.Name = 'StealPrompt'
				p:SetAttribute('ownerUserId', 42)
				expect(shouldShow(p, 99, nil)).to.equal(false)
				expect(shouldShow(p, 42, nil)).to.equal(false)
				p:Destroy()
				local bare = Instance.new('ProximityPrompt')
				bare.Name = 'StealPrompt'
				expect(shouldShow(bare, 99, nil)).to.equal(false)
				bare:Destroy()
			end
		)

		it('door prompt is visible to non-owners, never to the owner', function()
			local p = Instance.new('ProximityPrompt')
			p.Name = 'OpenDoorPrompt'
			p:SetAttribute('doorPrompt', true)
			p:SetAttribute('ownerUserId', 42)
			-- Strangers see Open Door; the owner never does.
			expect(shouldShow(p, 99, nil)).to.equal(true)
			expect(shouldShow(p, 300, nil)).to.equal(true)
			expect(shouldShow(p, 42, nil)).to.equal(false)
			-- Missing owner stamps fail closed.
			p:SetAttribute('ownerUserId', nil)
			expect(shouldShow(p, 99, nil)).to.equal(false)
			p:Destroy()
		end)

		it('steal-carrying thief sees NO prompts; everyone else is unaffected', function()
			local kinds = { 'StealPrompt', 'PickupPrompt', 'HatchPrompt', 'BuyPrompt', 'PlacePrompt' }
			for _, name in ipairs(kinds) do
				local p = Instance.new('ProximityPrompt')
				p.Name = name
				p:SetAttribute('ownerUserId', 42)
				p:SetAttribute('targetUserId', 99)
				-- Thief (steal-carry): everything hidden —
				-- even prompts that would otherwise show.
				expect(shouldShow(p, 99, 'egg', true)).to.equal(false)
				expect(shouldShow(p, 42, 'animal', true)).to.equal(false)
				p:Destroy()
			end
			-- Same prompts, normal carrier: only the usual
			-- rules apply (steal flag off changes nothing).
			local steal = Instance.new('ProximityPrompt')
			steal.Name = 'StealPrompt'
			steal:SetAttribute('stealPrompt', true)
			steal:SetAttribute('ownerUserId', 42)
			expect(shouldShow(steal, 99, 'egg', false)).to.equal(false) -- carrying: hidden
			expect(shouldShow(steal, 99, nil, false)).to.equal(true) -- free stranger: shown
			steal:Destroy()
			local buy = Instance.new('ProximityPrompt')
			buy.Name = 'BuyPrompt'
			expect(shouldShow(buy, 99, 'egg', true)).to.equal(false) -- thief: hidden
			expect(shouldShow(buy, 99, 'egg', false)).to.equal(false) -- normal carrier: hidden (carry rule)
			expect(shouldShow(buy, 99, nil, false)).to.equal(true) -- free player: shown
			buy:Destroy()
		end)
	end)

	describe('CarryPrompts installers stamp the right attribute', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('InstallPickupPrompt stamps ownerUserId from slot', function()
			local part = Instance.new('Part')
			part.Parent = workspace :: any
			local model = Instance.new('Model')
			model.Name = 'TestModel'
			model.PrimaryPart = part
			model.Parent = workspace :: any
			CarryPrompts.InstallPickupPrompt(model, 'X1', 'animal', {
				id = 'p7:42:slot:1',
				ownerUserId = 42,
			}, 42)
			-- Find the prompt on the part.
			local prompt = part:FindFirstChildWhichIsA('ProximityPrompt')
			expect(prompt).to.be.ok()
			expect(prompt:GetAttribute('ownerUserId')).to.equal(42)
			prompt:Destroy()
			model:Destroy()
		end)

		it('InstallHatchPrompt stamps ownerUserId from slot', function()
			local part = Instance.new('Part')
			part.Parent = workspace :: any
			local model = Instance.new('Model')
			model.Name = 'TestModel'
			model.PrimaryPart = part
			model.Parent = workspace :: any
			CarryPrompts.InstallHatchPrompt({
				model = model,
				uniqueId = 'LB_X1',
			}, {
				id = 'p7:42:slot:1',
				ownerUserId = 42,
			}, 42)
			local prompt = part:FindFirstChildWhichIsA('ProximityPrompt')
			expect(prompt).to.be.ok()
			expect(prompt.Name).to.equal('HatchPrompt')
			expect(prompt:GetAttribute('ownerUserId')).to.equal(42)
			prompt:Destroy()
			model:Destroy()
		end)

		it('InstallPlacePromptOnSlot stamps targetUserId from playerId', function()
			local part = Instance.new('Part')
			part.Parent = workspace :: any
			CarryPrompts.InstallPlacePromptOnSlot({
				id = 'p7:42:slot:1',
				ownerUserId = 42,
				state = SlotType.State.Empty,
				part = part,
			}, 42)
			local prompt = part:FindFirstChildWhichIsA('ProximityPrompt')
			expect(prompt).to.be.ok()
			expect(prompt.Name).to.equal('PlacePrompt')
			expect(prompt:GetAttribute('targetUserId')).to.equal(42)
			prompt:Destroy()
			part:Destroy()
		end)
	end)
end
