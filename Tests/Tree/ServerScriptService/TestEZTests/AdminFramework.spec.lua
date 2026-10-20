--!strict
--!native
--[[
	AdminFramework.spec
	===================
	Tests for the admin command framework: target resolution,
	canonical argument resolvers, audit log, rate limiter, type
	utilities, and the structural contract of every Cmdr command
	definition (name/group/args + Server counterpart present).

	Uses the REAL Admin/ modules and the REAL canonical configs.
	No players, no Workspace, no DataStore: target tests cover
	the input-validation paths; live multi-player behavior is a
	Studio manual-test concern (see the implementation report).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminArgs = require(ServerScriptService.Admin.AdminArgs)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)

	describe('AdminTargetResolver', function()
		it('rejects non-string and empty targets', function()
			assert(AdminTargetResolver.Resolve(nil, nil).ok == false)
			assert(AdminTargetResolver.Resolve('', nil).ok == false)
			assert(AdminTargetResolver.Resolve('   ', nil).ok == false)
		end)

		it('rejects unknown players without picking anyone', function()
			local r = AdminTargetResolver.Resolve('DefinitelyNotAPlayer12345', nil)
			assert(r.ok == false)
			assert(typeof(r.error) == 'string')
		end)

		it('resolves me only with a live executor', function()
			local r = AdminTargetResolver.Resolve('me', nil)
			assert(r.ok == false)
		end)

		it('treats all and server as server scope when players exist', function()
			-- Headless suites usually have zero players; either the
			-- empty-server error or a Server result is acceptable,
			-- but the scope must never be Single for these words.
			for _, word in ipairs({ 'all', 'server', 'ALL', 'Server' }) do
				local r = AdminTargetResolver.Resolve(word, nil)
				if r.ok then
					assert(r.scope == 'Server')
					assert(#(r.players or {}) >= 1)
				else
					assert(typeof(r.error) == 'string')
				end
			end
		end)
	end)

	describe('AdminArgs animals', function()
		it('resolves defIds case-insensitively to canonical form', function()
			local ok, defId = AdminArgs.ResolveAnimal('Dragon')
			assert(ok == true)
			assert(defId == 'Dragon')
			local okLower, defIdLower = AdminArgs.ResolveAnimal('dragon')
			assert(okLower == true)
			assert(defIdLower == 'Dragon')
		end)

		it('rejects unknown animals', function()
			local ok, err = AdminArgs.ResolveAnimal('FakeAnimalXYZ')
			assert(ok == false)
			assert(typeof(err) == 'string')
		end)

		it('enforces single trait (nil for absent)', function()
			local okNil, traitNil = AdminArgs.ResolveTrait(nil)
			assert(okNil == true)
			assert(traitNil == nil)
			local okDash, traitDash = AdminArgs.ResolveTrait('-')
			assert(okDash == true)
			assert(traitDash == nil)
			local okGold, traitGold = AdminArgs.ResolveTrait('Gold')
			assert(okGold == true)
			assert(traitGold == 'Gold')
		end)

		it('rejects multi-trait input instead of truncating', function()
			local ok, err = AdminArgs.ResolveTrait('Gold,Diamond')
			assert(ok == false)
			assert(typeof(err) == 'string')
		end)

		it('rejects unknown traits', function()
			local ok, _ = AdminArgs.ResolveTrait('FakeTraitXYZ')
			assert(ok == false)
		end)

		it('resolves mutation lists sorted and canonical', function()
			local ok, list = AdminArgs.ResolveMutations('Galactic,Frost')
			assert(ok == true)
			assert(#list == 2)
			assert(list[1] == 'Frost')
			assert(list[2] == 'Galactic')
		end)

		it('accepts empty mutation input as empty list', function()
			local okNil, listNil = AdminArgs.ResolveMutations(nil)
			assert(okNil == true)
			assert(#listNil == 0)
			local okDash, listDash = AdminArgs.ResolveMutations('-')
			assert(okDash == true)
			assert(#listDash == 0)
		end)

		it('rejects duplicate mutations loudly', function()
			local ok, err = AdminArgs.ResolveMutations('Frost,Frost')
			assert(ok == false)
			assert(typeof(err) == 'string')
		end)

		it('rejects unknown mutations loudly', function()
			local ok, err = AdminArgs.ResolveMutations('Frost,FakeXYZ')
			assert(ok == false)
			assert(typeof(err) == 'string')
		end)

		it('canonicalizes mutation case before uniqueness', function()
			local ok, list = AdminArgs.ResolveMutations('frost, Galactic')
			assert(ok == true)
			assert(#list == 2)
			local okDup, _ = AdminArgs.ResolveMutations('frost,Frost')
			assert(okDup == false)
		end)

		it('enforces the LevelConfig ceiling', function()
			local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)
			local ok, _ = AdminArgs.ResolveAnimalLevel(1)
			assert(ok == true)
			local okMax, _ = AdminArgs.ResolveAnimalLevel(LevelConfig.MaxLevel)
			assert(okMax == true)
			local okZero, _ = AdminArgs.ResolveAnimalLevel(0)
			assert(okZero == false)
			local okOver, _ = AdminArgs.ResolveAnimalLevel(LevelConfig.MaxLevel + 1)
			assert(okOver == false)
		end)
	end)

	describe('AdminArgs catalogs', function()
		it('resolves rarities case-insensitively', function()
			local ok, rarity = AdminArgs.ResolveRarity('legendary')
			assert(ok == true)
			assert(rarity == 'Legendary')
			local okBad, _ = AdminArgs.ResolveRarity('FakeRarity')
			assert(okBad == false)
		end)

		it('resolves gear by id and by display name', function()
			local ok, gearId = AdminArgs.ResolveGear('SilverBat')
			assert(ok == true)
			assert(gearId == 'SilverBat')
			local okName, gearIdName = AdminArgs.ResolveGear('Silver Bat')
			assert(okName == true)
			assert(gearIdName == 'SilverBat')
			local okBad, _ = AdminArgs.ResolveGear('FakeGearXYZ')
			assert(okBad == false)
		end)

		it('resolves codes with normalization', function()
			local ok, codeId = AdminArgs.ResolveCode('welcome')
			assert(ok == true)
			assert(codeId == 'WELCOME')
			local okBad, _ = AdminArgs.ResolveCode('NO_SUCH_CODE_XYZ')
			assert(okBad == false)
		end)

		it('bounds quantity and arena/rebirth levels', function()
			local okQ, qty = AdminArgs.ResolveQuantity(nil, 5)
			assert(okQ == true)
			assert(qty == 1)
			local okQBad, _ = AdminArgs.ResolveQuantity(99, 5)
			assert(okQBad == false)
			local okA, _ = AdminArgs.ResolveArenaLevel(1)
			assert(okA == true)
			local okABad, _ = AdminArgs.ResolveArenaLevel(99999)
			assert(okABad == false)
			local okR, _ = AdminArgs.ResolveRebirthIndex(0)
			assert(okR == true)
			local okRBad, _ = AdminArgs.ResolveRebirthIndex(999)
			assert(okRBad == false)
		end)
	end)

	describe('AdminNotify builders', function()
		it('describes eggs and animals with applied metadata only', function()
			assert(AdminNotify.DescribeEgg('Legendary', nil, {}) == 'Legendary Egg')
			assert(
				AdminNotify.DescribeEgg('Legendary', 'Gold', { 'Frost', 'Galactic' })
					== 'Legendary Egg — Gold — Frost, Galactic'
			)
			assert(AdminNotify.DescribeAnimal('Dragon', nil, {}, nil) == 'Dragon')
			assert(
				AdminNotify.DescribeAnimal('Dragon', 'Gold', { 'Galactic' }, 25)
					== 'Dragon — Gold — Galactic — Lv.25'
			)
		end)

		it('formats money without inventing a formatter', function()
			local text = AdminNotify.FormatMoney('100000')
			assert(string.find(text, '100') ~= nil)
		end)
	end)

	describe('AdminAudit', function()
		it('records newest-first entries', function()
			AdminAudit.Log(123, 'spec-probe-a', nil, true, 'first')
			AdminAudit.Log(123, 'spec-probe-b', nil, false, 'second')
			local recent = AdminAudit.Recent(2)
			assert(#recent == 2)
			assert(string.find(recent[1], 'spec-probe-b') ~= nil)
			assert(string.find(recent[2], 'spec-probe-a') ~= nil)
		end)
	end)

	describe('AdminRateLimit', function()
		it('allows normal use and blocks runaway bursts', function()
			AdminRateLimit._TestReset()
			for _ = 1, 30 do
				local ok, _ = AdminRateLimit.Check(424242)
				assert(ok == true)
			end
			local okOver, errOver = AdminRateLimit.Check(424242)
			assert(okOver == false)
			assert(typeof(errOver) == 'string')
			AdminRateLimit._TestReset()
		end)
	end)

	describe('CmdrTypeUtil', function()
		it('filters case-insensitively and matches exactly', function()
			local out = TypeUtil.FuzzyFilter({ 'Frost', 'Galactic', 'Gold' }, 'g')
			assert(#out == 2)
			assert(TypeUtil.ExactMatch({ 'Gold', 'Diamond' }, 'gold') == 'Gold')
			assert(TypeUtil.BestMatch({ 'Buy1', 'Buy2', 'Buy3' }, 'buy') == 'Buy1')
			assert(TypeUtil.Trimmed('  hi  ') == 'hi')
		end)
	end)

	describe('command definition contract', function()
		it('every command has a valid def and a Server counterpart', function()
			local commandsFolder = ServerScriptService.Cmdr.Server.Commands
			local knownTypes: { [string]: boolean } = {}
			for _, name in ipairs({
				'player',
				'players',
				'string',
				'strings',
				'number',
				'numbers',
				'integer',
				'positiveInteger',
				'boolean',
				'adminTarget',
				'eggRarity',
				'animalDef',
				'traitId',
				'mutationList',
				'gearId',
				'codeId',
				'arenaOption',
			}) do
				knownTypes[name] = true
			end
			local checked = 0
			for _, child in ipairs(commandsFolder:GetChildren()) do
				if child:IsA('ModuleScript') and string.find(child.Name, 'Server') == nil then
					local def = require(child)
					assert(typeof(def.Name) == 'string' and #def.Name > 0, child.Name)
					assert(typeof(def.Description) == 'string', child.Name)
					assert(def.Group == 'Admin' or def.Group == 'Superadmin' or def.Group == 'Default', child.Name)
					assert(typeof(def.Args) == 'table', child.Name)
					for _, arg in ipairs(def.Args) do
						assert(typeof(arg.Name) == 'string', child.Name)
						assert(typeof(arg.Type) == 'string', child.Name)
						assert(knownTypes[arg.Type] == true, child.Name .. ':' .. tostring(arg.Type))
						assert(typeof(arg.Description) == 'string', child.Name)
					end
					local serverSide = commandsFolder:FindFirstChild(child.Name .. 'Server')
					assert(serverSide ~= nil, 'missing Server for ' .. child.Name)
					checked += 1
				end
			end
			assert(checked >= 60, 'expected 60+ command defs, got ' .. tostring(checked))
		end)

		it('custom types exist as modules', function()
			local typesFolder = ServerScriptService.Cmdr.Server.Types
			for _, name in ipairs({
				'adminTarget',
				'eggRarity',
				'animalDef',
				'traitId',
				'mutationList',
				'gearId',
				'codeId',
				'arenaOption',
			}) do
				assert(typesFolder:FindFirstChild(name) ~= nil, 'missing type ' .. name)
			end
		end)
	end)
end
