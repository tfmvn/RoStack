--!strict
--!native
--[[
	InteractionLiveness.spec
	========================
	Server-authoritative death/reset lockout
	(Validation.IsLiveCharacter / CanPlayerInteract).

	The exploit contract: a dead/dying/respawning player has
	ZERO interaction authority. The Player instance survives
	death (still parented), so LivePlayer alone cannot gate
	anything — the CURRENT character must be live.

	What we test here (real Instances, no Player needed):
	  * IsLiveCharacter: live Humanoid -> true; Health 0 ->
	    false; missing Humanoid -> false; unparented model ->
	    false; non-models -> false.
	  * CanPlayerInteract: nil/garbage -> false (LivePlayer
	    fails); non-Player shims (unit-test tables) pass
	    through to domain validation (their own gates apply).
	    Real-Player gating (live character required, dead
	    rejected) is covered by the live death matrix — an
	    engine Player cannot be fabricated in specs.

	Endpoint wiring (steal/grab/place/hatch/collect reject
	'player-not-live' / PlayerNotLive / silent nil) is asserted
	by the service specs + the live death + E-spam matrix.
]]

return function()
	local Workspace = game:GetService('Workspace')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Validation = require(ReplicatedStorage.Utility.Validation)

	local function liveCharacter(health: number?): Model
		local character = Instance.new('Model')
		character.Name = 'LivenessProbe'
		local hrp = Instance.new('Part')
		hrp.Name = 'HumanoidRootPart'
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Anchored = true
		hrp.Parent = character
		character.PrimaryPart = hrp
		local humanoid = Instance.new('Humanoid')
		humanoid.Health = health or 100
		humanoid.Parent = character
		character.Parent = Workspace
		return character
	end

	describe('Validation.IsLiveCharacter', function()
		it('accepts a live character', function()
			local character = liveCharacter(100)
			expect(Validation.IsLiveCharacter(character)).to.equal(true)
			character:Destroy()
		end)

		it('rejects a dead character (Health 0)', function()
			local character = liveCharacter(100)
			local humanoid = character:FindFirstChildOfClass('Humanoid')
			assert(humanoid ~= nil, 'humanoid present')
			humanoid.Health = 0
			expect(Validation.IsLiveCharacter(character)).to.equal(false)
			character:Destroy()
		end)

		it('rejects a removed character, a rig without Humanoid, and non-models', function()
			local character = liveCharacter(100)
			character.Parent = nil
			expect(Validation.IsLiveCharacter(character)).to.equal(false)
			character:Destroy()

			local noHum = Instance.new('Model')
			local part = Instance.new('Part')
			part.Parent = noHum
			noHum.PrimaryPart = part
			noHum.Parent = Workspace
			expect(Validation.IsLiveCharacter(noHum)).to.equal(false)
			noHum:Destroy()

			expect(Validation.IsLiveCharacter(nil)).to.equal(false)
			expect(Validation.IsLiveCharacter({})).to.equal(false)
			expect(Validation.IsLiveCharacter('character')).to.equal(false)
		end)
	end)

	describe('Validation.CanPlayerInteract', function()
		it('rejects nil and garbage (LivePlayer fails)', function()
			expect(Validation.CanPlayerInteract(nil)).to.equal(false)
			expect(Validation.CanPlayerInteract({})).to.equal(false)
			expect(Validation.CanPlayerInteract('player')).to.equal(false)
		end)

		it('passes non-Player shims through to domain validation', function()
			-- Unit-test tables and server-internal call paths
			-- are not engine Players; their own gates
			-- (LivePlayer/domain checks downstream) decide.
			-- Production network boundaries always supply
			-- real Players, which are fully gated.
			expect(Validation.CanPlayerInteract({ UserId = 1 })).to.equal(true)
		end)
	end)
end
