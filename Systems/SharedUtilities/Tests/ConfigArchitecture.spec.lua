--!strict
--!native
--[[
	ConfigArchitecture.spec
	========================
	Architecture invariants for the UNIFIED configuration system
	(ReplicatedStorage/Config/{Creatures,Economy,World,Presentation,Systems}).
	Every tunable lives in exactly one canonical domain; legacy mirrors
	(GameConfig blocks, FormattingConfig) are deleted; cross-catalog
	ladders stay pegged; spot-checks pin the preserved baseline values
	so a refactor can never silently rebalance the game.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local ConfigFolder = ReplicatedStorage.Config

	local function requirePath(...: string): any
		local node: any = ConfigFolder
		for _, seg in ipairs({ ... }) do
			node = (node :: Folder):WaitForChild(seg)
		end
		return require(node)
	end

	describe('ConfigValidator', function()
		it('ValidateAll reports zero issues', function()
			local ConfigValidator = require(ReplicatedStorage.Utility.ConfigValidator)
			local issues = ConfigValidator.ValidateAll()
			expect(#issues).to.equal(0)
		end)
	end)

	describe('canonical Validate()', function()
		local domains: { { Name: string, A: string, B: string } } = {
			{ Name = 'World.Prompts', A = 'World', B = 'Prompts' },
			{ Name = 'Economy.Money', A = 'Economy', B = 'Money' },
			{ Name = 'World.ArenaFeel', A = 'World', B = 'ArenaFeel' },
			{ Name = 'Economy.Sell', A = 'Economy', B = 'Sell' },
			{ Name = 'World.Bases', A = 'World', B = 'Bases' },
			{ Name = 'World.Movement', A = 'World', B = 'Movement' },
			{ Name = 'Systems.Debug', A = 'Systems', B = 'Debug' },
			{ Name = 'Presentation.Audio', A = 'Presentation', B = 'Audio' },
			{ Name = 'Presentation.Vfx', A = 'Presentation', B = 'Vfx' },
			{ Name = 'World.Stealing', A = 'World', B = 'Stealing' },
			{ Name = 'Economy.Rebirth', A = 'Economy', B = 'Rebirth' },
			{ Name = 'World.Events', A = 'World', B = 'Events' },
			{ Name = 'Systems.Security', A = 'Systems', B = 'Security' },
		}
		for _, entry in ipairs(domains) do
			it(entry.Name .. '.Validate() is clean', function()
				local mod = requirePath(entry.A, entry.B)
				expect(mod.Validate()).to.be.a('table')
				expect(#mod.Validate()).to.equal(0)
			end)
		end

		it('subsection Validates() are clean', function()
			local UI = requirePath('Presentation', 'UI')
			expect(UI.Overhead.Validate()).to.be.a('table')
			expect(#UI.Overhead.Validate()).to.equal(0)
			local Movement = requirePath('World', 'Movement')
			expect(Movement.Player.Validate()).to.be.a('table')
			expect(#Movement.Player.Validate()).to.equal(0)
			local Gear = requirePath('Economy', 'Gear')
			expect(Gear.Combat.Validate()).to.be.a('table')
			expect(#Gear.Combat.Validate()).to.equal(0)
			local Rewards = requirePath('Economy', 'Rewards')
			expect(Rewards.Codes.Validate()).to.be.a('table')
			expect(#Rewards.Codes.Validate()).to.equal(0)
			expect(#Rewards.Daily.Validate()).to.equal(0)
			expect(#Rewards.Playtime.Validate()).to.equal(0)
		end)
	end)

	describe('prompt canonical source (World.Prompts)', function()
		it('shared distance + hold are single-sourced', function()
			local Prompts = requirePath('World', 'Prompts')
			expect(Prompts.CarryMaxDistance).to.equal(8)
			expect(Prompts.CarryHoldDuration).to.equal(1)
		end)

		it('pins the preserved prompt baseline', function()
			local Prompts = requirePath('World', 'Prompts')
			expect(Prompts.AnimalPickup.HoldDuration).to.equal(1)
			expect(Prompts.AnimalPickup.MaxActivationDistance).to.equal(8)
			expect(Prompts.EggHatch.HoldDuration).to.equal(0)
			expect(Prompts.Steal.HoldDuration).to.equal(2.5)
			expect(Prompts.AnimalSell.HoldDuration).to.equal(0.5)
			expect(Prompts.CenterEggBuy.HoldDuration).to.equal(0.4)
			expect(Prompts.CenterEggBuy.MaxActivationDistance).to.equal(12)
			expect(Prompts.Arena.MaxActivationDistance).to.equal(12)
			expect(Prompts.GearShop.MaxActivationDistance).to.equal(12)
		end)
	end)

	describe('economy ladders (no legacy mirrors)', function()
		it('egg price == sell base per rarity (liquidate at 75% via SellMultiplier)', function()
			local Eggs = requirePath('Creatures', 'Eggs')
			local Animals = requirePath('Creatures', 'Animals')
			for rarity, price in pairs(Eggs.Price) do
				local sell = (Animals.SellBaseValue :: any)[rarity]
				if sell ~= nil then
					expect(sell).to.equal(price)
				end
			end
			-- The sale haircut lives in SellMultiplier (uniform
			-- 0.75): L1 liquidates for 75% of egg cost so
			-- hatch-and-sell can never print money.
			for _, rarity in ipairs({ 'Common', 'Uncommon', 'Rare', 'Epic', 'Mythic', 'Legendary', 'Divine', 'Secret' }) do
				expect((Animals.SellMultiplier :: any)[rarity]).to.equal('0.75')
			end
		end)

		it('upgrade growth is the XP growth (single source)', function()
			local Progression = requirePath('Creatures', 'Progression')
			expect(Progression.XP.GrowthRate).to.equal(1.12)
			expect(Progression.AdminLevelCap).to.equal(99)
		end)

		it('L1 upgrade cost is 12-15x L1 income per rarity (early pacing anchor)', function()
			local Animals = requirePath('Creatures', 'Animals')
			for rarity, sell in pairs(Animals.SellBaseValue) do
				local row = (Animals.Stats :: any).Income[rarity]
				expect(row).to.be.ok()
				expect(row.Base > 0).to.equal(true)
				-- L1->L2 costs SellBase x growth^0 = SellBase;
				-- L1 income/sec is Income.Base.
				local ratio = (sell :: number) / (row.Base :: number)
				expect(ratio >= 12 and ratio <= 15).to.equal(true)
			end
		end)

		it('luck pool is the design order (Mythic favored)', function()
			local Events = requirePath('World', 'Events')
			expect(#Events.LuckPoolOrder).to.equal(6)
			expect(Events.LuckPoolOrder[6]).to.equal('Mythic')
		end)
	end)

	describe('no legacy mirrors survive', function()
		it('GameConfig + FormattingConfig are deleted', function()
			expect(ConfigFolder:FindFirstChild('GameConfig')).to.equal(nil)
			expect(ConfigFolder:FindFirstChild('FormattingConfig')).to.equal(nil)
		end)

		it('toast text cap lives in UI.Notify only', function()
			local UI = requirePath('Presentation', 'UI')
			expect(UI.Notify.MaxTextLength).to.equal(120)
		end)
	end)

	describe('preserved presentation baselines', function()
		it('arena combat + camera baseline unchanged', function()
			local P = requirePath('World', 'ArenaFeel')
			expect(P.Combat.TravelDuration).to.equal(0.3)
			expect(P.Combat.ReturnDuration).to.equal(0.3)
			expect(P.Combat.HitStop).to.equal(0.05)
			expect(P.Combat.TickInterval).to.equal(0.25)
			expect(P.Combat.TurnInterval).to.equal(1.1)
			expect(P.HitFlash.Duration).to.equal(0.18)
			expect(P.CameraShake.FullRange).to.equal(15)
			expect(P.CameraShake.MaxRange).to.equal(30)
			expect(P.CameraShake.Duration).to.equal(0.28)
			expect(#P.AttackAnims).to.equal(5)
		end)

		it('sell viewport + overhead baseline (reconciled canonical values)', function()
			local Sell = requirePath('Economy', 'Sell')
			expect(Sell.Viewport.PreviewScale).to.equal(1.25)
			expect(Sell.Viewport.ShowcaseYawDeg).to.equal(25)
			expect(Sell.Viewport.ShowcaseZoom).to.equal(0.7)
			expect(Sell.Viewport.ShowcaseMargin).to.equal(1.1)
			expect(Sell.ResultTimeout).to.equal(8)
			expect(Sell.RarityGradient.LightenT).to.equal(0.45)
			local UI = requirePath('Presentation', 'UI')
			expect(UI.Overhead.Rainbow.Period).to.equal(3)
			expect(UI.Overhead.StolenTextColor).to.equal(Color3.fromRGB(255, 90, 90))
		end)

		it('player + base baseline unchanged', function()
			local Movement = requirePath('World', 'Movement')
			expect(Movement.Player.WalkSpeed).to.equal(24)
			expect(Movement.Player.JumpPower).to.equal(50)
			local Bases = requirePath('World', 'Bases')
			expect(Bases.Spawn.JoinLiftStuds).to.equal(4)
			expect(Bases.MoneyPool.BopUpSeconds).to.equal(0.08)
			expect(Bases.Collector.Feel.PressSeconds).to.equal(0.05)
			local Audio = requirePath('Presentation', 'Audio')
			expect(Audio.Collect.PoolSize).to.equal(4)
			expect(Movement.YawSmoothing).to.equal(8.0)
			expect(Movement.StandIdle.TickRate).to.equal(30)
			local Stealing = requirePath('World', 'Stealing')
			expect(Stealing.Cooldown).to.equal(0.5)
			expect(Stealing.StealSpeedMultiplier).to.equal(0.6)
			expect(Stealing.StealPresentation.FOVMultiplier).to.equal(0.9)
			expect(Stealing.StealPresentation.FOVTweenTime).to.equal(0.3)
		end)

		it('event transition cinematic baseline unchanged', function()
			local Events = requirePath('World', 'Events')
			expect(Events.Transition.FovMultiplier).to.equal(0.83)
			expect(Events.Transition.FovSeconds).to.equal(0.35)
			expect(Events.Transition.FlashDelaySeconds).to.equal(0.05)
			expect(Events.Transition.FlashInSeconds).to.equal(0.3)
			expect(Events.Transition.HoldSeconds).to.equal(0.3)
			expect(Events.Transition.FadeOutSeconds).to.equal(1)
			expect(Events.Transition.CoverSeconds).to.equal(0.65)
		end)

		it('security + rewards + messages baselines', function()
			local Security = requirePath('Systems', 'Security')
			expect(Security.RequestThrottleSeconds).to.equal(0.5)
			expect(Security.Receipts.SeenCap).to.equal(5000)
			expect(Security.Door.RequestCooldownSeconds).to.equal(5)
			local Rewards = requirePath('Economy', 'Rewards')
			expect(Rewards.Playtime.Settings.DayBoundaryOffsetSeconds).to.equal(19800)
			expect(Rewards.Daily.Settings.ClaimInterval).to.equal(86400)
			local Arena = requirePath('World', 'Arena')
			expect(Arena.ResultCardCap).to.equal(6)
			local Messages = requirePath('Presentation', 'Messages')
			expect(#Messages.Success).to.equal(29)
			expect(#Messages.Warning).to.equal(103)
			local Debug = requirePath('Systems', 'Debug')
			expect(Debug.Audio.Enabled).to.equal(false)
		end)
	end)
end
