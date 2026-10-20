--!strict
--!native
--[[
	EggWalkAnimator.spec
	====================
	Tests for the single shared egg walk-cycle implementation
	(ReplicatedStorage/Utility/EggWalkAnimator.lua), used by both
	AmbientService (roaming) and FlightController (purchased
	travel). Pure math — no models, no Heartbeats.

	Locks in:
	  * personality rolled once with sane ranges (no per-frame RNG
	    in the loop itself — verified by absence, not assertion)
	  * blend crossfade 0 -> 1 on advance, back to 0 on rest
	  * rest pose at blend 0 (zero lift/lean, unit stretch)
	  * determinism: same state in, same pose out
	  * scale helpers nil-safe, epsilon-quantized, exact-restore
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local EggWalkAnimator = require(ReplicatedStorage.Utility.EggWalkAnimator)

	describe('EggWalkAnimator.New', function()
		it('rolls one-time personality in sane ranges, blend starts at 0', function()
			local s = EggWalkAnimator.New()
			expect(s.blend).to.equal(0)
			expect(s.phase >= 0 and s.phase < math.pi * 2).to.equal(true)
			expect(s.freqMult >= 0.92 and s.freqMult <= 1.08).to.equal(true)
			expect(s.bobMult >= 0.9 and s.bobMult <= 1.1).to.equal(true)
			expect(s.swayMult >= 0.8 and s.swayMult <= 1.2).to.equal(true)
		end)
	end)

	describe('EggWalkAnimator.Advance/Pose', function()
		it('blends 0 -> 1 while advancing the phase', function()
			local s = EggWalkAnimator.New()
			expect(s.blend).to.equal(0)
			local p0 = s.phase
			EggWalkAnimator.Advance(s, 1 / 60, 1)
			expect(s.blend > 0).to.equal(true)
			expect(s.phase == p0).to.equal(false)
			EggWalkAnimator.Advance(s, 10, 1)
			expect(s.blend).to.equal(1)
		end)

		it('poses rest (zeros + unit stretch) at blend 0', function()
			local s = EggWalkAnimator.New()
			local lift, leanSide, leanFwd, stretch = EggWalkAnimator.Pose(s, 1, 1)
			expect(lift).to.equal(0)
			expect(leanSide).to.equal(0)
			expect(leanFwd).to.equal(0)
			expect(stretch).to.equal(1)
		end)

		it('is deterministic for identical state', function()
			local a = { phase = 1.3, blend = 0.7, idlePhase = 0, freqMult = 1, bobMult = 1, swayMult = 1 }
			local b = { phase = 1.3, blend = 0.7, idlePhase = 0, freqMult = 1, bobMult = 1, swayMult = 1 }
			local l1, s1, f1, st1 = EggWalkAnimator.Pose(a, 1, 1)
			local l2, s2, f2, st2 = EggWalkAnimator.Pose(b, 1, 1)
			expect(l1).to.equal(l2)
			expect(s1).to.equal(s2)
			expect(f1).to.equal(f2)
			expect(st1).to.equal(st2)
		end)

		it('produces a coordinated hop (lift >= 0, lean alternates, stretch brackets 1)', function()
			local s = { phase = 0, blend = 1, idlePhase = 0, freqMult = 1, bobMult = 1, swayMult = 1 }
			-- Takeoff (phase 0): grounded, stretched, neutral lean.
			local lift0, lean0, _, stretch0 = EggWalkAnimator.Pose(s, 1, 1)
			expect(lift0).to.equal(0)
			expect(lean0).to.equal(0)
			expect(stretch0 > 1).to.equal(true)
			-- Apex (phase pi/2): lifted, leaning one way, neutral scale.
			s.phase = math.pi / 2
			local liftA, leanA, _, stretchA = EggWalkAnimator.Pose(s, 1, 1)
			expect(liftA > 0).to.equal(true)
			expect(leanA > 0).to.equal(true)
			expect(math.abs(stretchA - 1) < 1e-6).to.equal(true)
			-- Landing (phase pi): grounded, squashed.
			s.phase = math.pi
			local _, _, _, stretchL = EggWalkAnimator.Pose(s, 1, 1)
			expect(stretchL < 1).to.equal(true)
			-- Second hop mirrors the lean to the other side.
			s.phase = math.pi * 1.5
			local _, leanB, _, _ = EggWalkAnimator.Pose(s, 1, 1)
			expect(leanB < 0).to.equal(true)
		end)
	end)

	describe('EggWalkAnimator.Rest', function()
		it('decays blend to 0 with a bounded idle offset', function()
			local s = EggWalkAnimator.New()
			s.blend = 1
			local blend, _ = EggWalkAnimator.Rest(s, 10)
			expect(blend).to.equal(0)
			local _, off = EggWalkAnimator.Rest(s, 0.1)
			expect(math.abs(off) <= 0.05 + 0.03 + 1e-9).to.equal(true)
		end)
	end)

	describe('EggWalkAnimator.IdlePose', function()
		it('is a stationary wobble: micro bob, gentle lean, near-unit stretch, no travel lean', function()
			local s = EggWalkAnimator.New()
			s.idlePhase = 0.7
			local bob, lean, stretch = EggWalkAnimator.IdlePose(s)
			expect(math.abs(bob) <= 0.045 + 1e-9).to.equal(true)
			expect(math.abs(lean) <= 0.05 * 0.7 * 1.2 + 1e-9).to.equal(true)
			expect(math.abs(stretch - 1) <= 0.02 + 1e-9).to.equal(true)
		end)

		it('is deterministic for identical state', function()
			local a = { idlePhase = 2.1, swayMult = 1, bobMult = 1 }
			local b = { idlePhase = 2.1, swayMult = 1, bobMult = 1 }
			local b1, l1, s1 = EggWalkAnimator.IdlePose(a)
			local b2, l2, s2 = EggWalkAnimator.IdlePose(b)
			expect(b1).to.equal(b2)
			expect(l1).to.equal(l2)
			expect(s1).to.equal(s2)
		end)
	end)

	describe('EggWalkAnimator scale helpers', function()
		it('are nil-model safe and epsilon-quantized', function()
			expect(EggWalkAnimator.ApplyScale(nil, 1.05, nil)).to.equal(nil)
			expect(EggWalkAnimator.ApplyScale(nil, 1.05, 0.9)).to.equal(0.9)
			expect(EggWalkAnimator.RestoreScale(nil, 1, 0.97)).to.equal(0.97)
			expect(EggWalkAnimator.RestoreScale(nil, 1, 1)).to.equal(1)
		end)
	end)
end
