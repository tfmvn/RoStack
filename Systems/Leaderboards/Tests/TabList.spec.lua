--!strict
--!native
--[[
	TabList.spec
	============
	Structure coverage for the TAB (player-list) leaderboard:
	the server maintains NATIVE player.leaderstats — no custom
	UI, no feed remote — with exactly Rebirths (IntValue,
	FIRST child = the native primary sort key) and Money
	(StringValue, game-formatted). Values come from injected
	authoritative services (faked here); the native CoreGui
	PlayerList renders and sorts them. cadence/Studio
	presence paths are Studio-playtest items.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local TabListService = require(ServerScriptService.TabList.TabListService)

	local function wireFakes(money: string, rebirths: number, loaded: boolean)
		TabListService.SetPlayerService({
			GetPlayerData = function(_userId: number): any?
				if loaded then
					return {}
				end
				return nil
			end,
		})
		TabListService.SetEconomyService({
			GetMoney = function(_userId: number): string
				return money
			end,
		})
		TabListService.SetRebirthService({
			GetRebirth = function(_userId: number): number
				return rebirths
			end,
		})
	end

	describe('TabList leaderstats structure', function()
		it('creates leaderstats with Rebirths first, Money second', function()
			local host = Instance.new('Folder')
			host.Name = 'SpecPlayer'
			local folder = TabListService.EnsureLeaderstats(host)
			expect(folder).to.be.ok()
			assert(folder ~= nil, 'folder created')
			expect((folder :: Folder).Name).to.equal('leaderstats')
			local children = (folder :: Folder):GetChildren()
			expect(#children).to.equal(2)
			expect(children[1].Name).to.equal('Rebirths')
			expect(children[1]:IsA('IntValue')).to.equal(true)
			expect(children[2].Name).to.equal('Money')
			expect(children[2]:IsA('StringValue')).to.equal(true)
			host:Destroy()
		end)

		it('repairs wrong-typed leftover stats', function()
			local host = Instance.new('Folder')
			host.Name = 'SpecPlayerMessy'
			local folder = Instance.new('Folder')
			folder.Name = 'leaderstats'
			folder.Parent = host
			local wrong = Instance.new('StringValue')
			wrong.Name = 'Rebirths'
			wrong.Value = 'junk'
			wrong.Parent = folder
			local fixed = TabListService.EnsureLeaderstats(host)
			expect(fixed).to.be.ok()
			local stat = (folder :: Folder):FindFirstChild('Rebirths')
			expect(stat ~= nil and stat:IsA('IntValue')).to.equal(true)
			host:Destroy()
		end)

		it('is idempotent (second ensure changes nothing)', function()
			local host = Instance.new('Folder')
			host.Name = 'SpecPlayerIdem'
			TabListService.EnsureLeaderstats(host)
			local folder = TabListService.EnsureLeaderstats(host)
			assert(folder ~= nil, 'folder present')
			expect(#(folder :: Folder):GetChildren()).to.equal(2)
			host:Destroy()
		end)
	end)

	describe('TabList values (server-authoritative)', function()
		it('writes rebirth count and formatted money', function()
			wireFakes('400000000', 100, true)
			local host = Instance.new('Folder')
			host.Name = 'SpecValues'
			expect(TabListService.RefreshValues(host, 4242)).to.equal(true)
			local folder = host:FindFirstChild('leaderstats')
			assert(folder ~= nil, 'leaderstats created')
			local rebirths = (folder :: Instance):FindFirstChild('Rebirths')
			assert(rebirths ~= nil and rebirths:IsA('IntValue'), 'rebirths stat')
			expect((rebirths :: IntValue).Value).to.equal(100)
			local money = (folder :: Instance):FindFirstChild('Money')
			assert(money ~= nil and money:IsA('StringValue'), 'money stat')
			-- Game-formatted, never raw/scientific.
			expect((money :: StringValue).Value).to.equal('400.0M')
			host:Destroy()
		end)

		it('formats a 1Qa fortune for the Money column', function()
			wireFakes('1000000000000000', 0, true)
			local host = Instance.new('Folder')
			host.Name = 'SpecQa'
			expect(TabListService.RefreshValues(host, 4243)).to.equal(true)
			local folder = host:FindFirstChild('leaderstats')
			assert(folder ~= nil, 'leaderstats created')
			local money = (folder :: Instance):FindFirstChild('Money')
			assert(money ~= nil and money:IsA('StringValue'), 'money stat')
			expect((money :: StringValue).Value).to.equal('1.0Qa')
			host:Destroy()
		end)

		it('skips unloaded profiles without writing zeros', function()
			wireFakes('999', 5, false)
			local host = Instance.new('Folder')
			host.Name = 'SpecUnloaded'
			expect(TabListService.RefreshValues(host, 4244)).to.equal(false)
			expect(host:FindFirstChild('leaderstats')).to.equal(nil)
			host:Destroy()
		end)
	end)
end
