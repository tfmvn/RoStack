--!strict
--!native
--[[
	ArenaUIState.spec
	=================
	Headless coverage for the Arena screen lifecycle coordination:
	  * ArenaUIState result-open flag semantics (set on result open,
	    cleared on every close path — never sticks).
	  * ArenaController starts Hidden after reset (no auto-open).
	The full transition matrix (interaction -> Start -> Running ->
	Result -> Hidden) is event-driven in Studio; these specs pin
	the coordination contract both controllers rely on.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local StarterPlayer = game:GetService('StarterPlayer')
	local scriptsRoot = StarterPlayer:WaitForChild('StarterPlayerScripts', 10)
	assert(scriptsRoot ~= nil, 'StarterPlayerScripts missing in test place')
	local utility = ReplicatedStorage:WaitForChild('Utility', 10)
	assert(utility ~= nil, 'Utility missing in test place')
	local stateModule = (utility :: Instance):WaitForChild('ArenaUIState', 10)
	assert(stateModule ~= nil, 'ArenaUIState missing in test place')
	local ctrlModule = scriptsRoot:WaitForChild('ArenaController', 10)
	assert(ctrlModule ~= nil, 'ArenaController missing in test place')
	local ArenaUIState = require(stateModule)
	local ArenaController = require(ctrlModule)

	describe('ArenaUIState result-open flag', function()
		it('starts closed and clears on close', function()
			ArenaUIState._TestReset()
			expect(ArenaUIState.IsResultOpen()).to.equal(false)
			expect(ArenaUIState.ResultSession()).to.equal(nil)
			ArenaUIState.SetResultOpen(true, '42')
			expect(ArenaUIState.IsResultOpen()).to.equal(true)
			expect(ArenaUIState.ResultSession()).to.equal('42')
			-- Every close path funnels through SetResultOpen(false).
			ArenaUIState.SetResultOpen(false)
			expect(ArenaUIState.IsResultOpen()).to.equal(false)
			expect(ArenaUIState.ResultSession()).to.equal(nil)
			ArenaUIState._TestReset()
		end)

		it('a newer result replaces the previous session token', function()
			ArenaUIState._TestReset()
			ArenaUIState.SetResultOpen(true, '7')
			ArenaUIState.SetResultOpen(true, '8')
			expect(ArenaUIState.IsResultOpen()).to.equal(true)
			expect(ArenaUIState.ResultSession()).to.equal('8')
			ArenaUIState._TestReset()
		end)
	end)

	describe('ArenaController screen state', function()
		it('resets to Hidden (menu never auto-opens)', function()
			ArenaController._TestReset()
			expect(ArenaController._TestScreen()).to.equal('Hidden')
		end)

		it('formats restart prices from authoritative strings', function()
			expect(ArenaController._TestPriceText('25000')).to.equal('$25.0K')
			expect(ArenaController._TestPriceText('150000')).to.equal('$150.0K')
			expect(ArenaController._TestPriceText('0')).to.equal('FREE')
			expect(ArenaController._TestPriceText(nil)).to.equal('FREE')
		end)
	end)
end
