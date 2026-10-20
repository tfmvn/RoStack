--!strict
--!native
--[[
	StandPresentation.spec
	======================
	Registry-level tests for the centralized stand idle-wobble
	loop (ServerScriptService/StandPresentation.lua). The live
	Heartbeat loop is NEVER started here — these lock bind/unbind
	balance, hold semantics, and no-throw degradation without
	running presentation.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local StandPresentation = require(ServerScriptService.StandPresentation)

	local function makeModel(): Model
		local model = Instance.new('Model')
		local root = Instance.new('Part')
		root.Name = 'HumanoidRootPart'
		root.Size = Vector3.new(2, 2, 2)
		root.Anchored = true
		root.Parent = model
		model.PrimaryPart = root
		model.Parent = game:GetService('Workspace')
		return model
	end

	describe('StandPresentation registry', function()
		it('binds and unbinds with balanced counts, twice-unbind safe', function()
			local before = StandPresentation._TestCount()
			local model = makeModel()
			StandPresentation.Bind(model)
			expect(StandPresentation._TestCount()).to.equal(before + 1)
			-- Re-bind overwrites (stand change), never duplicates.
			StandPresentation.Bind(model)
			expect(StandPresentation._TestCount()).to.equal(before + 1)
			StandPresentation.Unbind(model)
			expect(StandPresentation._TestCount()).to.equal(before)
			StandPresentation.Unbind(model)
			expect(StandPresentation._TestCount()).to.equal(before)
			model:Destroy()
		end)

		it('hold/unbind/bind degrade gracefully on garbage input', function()
			expect(function()
				StandPresentation.Bind(nil)
				StandPresentation.Bind({})
				StandPresentation.Bind('nope' :: any)
				StandPresentation.Unbind(nil)
				StandPresentation.Hold(nil, 1)
				StandPresentation.Hold({}, 1)
			end).to.never.throw()
		end)

		it('unbinding a destroyed model is safe (auto-drop path)', function()
			local before = StandPresentation._TestCount()
			local model = makeModel()
			StandPresentation.Bind(model)
			expect(StandPresentation._TestCount()).to.equal(before + 1)
			model:Destroy()
			-- Explicit unbind after destroy still balances.
			StandPresentation.Unbind(model)
			expect(StandPresentation._TestCount()).to.equal(before)
		end)

		it('is EGG-ONLY: explicit animal kind never binds', function()
			local before = StandPresentation._TestCount()
			local model = makeModel()
			-- Canonical animal occupant kind: must be a no-op.
			StandPresentation.Bind(model, 'animal')
			expect(StandPresentation._TestCount()).to.equal(before)
			-- Explicit egg kind binds.
			StandPresentation.Bind(model, 'egg')
			expect(StandPresentation._TestCount()).to.equal(before + 1)
			StandPresentation.Unbind(model)
			expect(StandPresentation._TestCount()).to.equal(before)
			model:Destroy()
		end)

		it('exposes the canonical egg/animal kind checks', function()
			expect(StandPresentation.IsEggKind('egg')).to.equal(true)
			expect(StandPresentation.IsEggKind(nil)).to.equal(true)
			expect(StandPresentation.IsEggKind('animal')).to.equal(false)
			expect(StandPresentation.IsAnimalKind('animal')).to.equal(true)
			expect(StandPresentation.IsAnimalKind('egg')).to.equal(false)
		end)
	end)
end
