--!strict
--!native
--[[
	EggTimerFormat.spec
	====================
	Billboard text contract for the guarantee timers: every
	static word is WHITE, ONLY the rarity word carries the
	canonical rarity color, and ONLY the timer carries the
	urgency ramp. Asserts the exact segment structure through
	the controller's pure format seam (no Studio assets, no
	remotes, no clock).
]]

return function()
	local StarterPlayer = game:GetService('StarterPlayer')

	local EggTimerController = require(StarterPlayer.StarterPlayerScripts.EggTimerController)

	describe('EggTimerController._TestFormat', function()
		it('colors only the rarity word and the timer', function()
			local text = EggTimerController._TestFormat('Mythic', '#FF0000', '#00FF00', '08:32')
			expect(text).to.equal(
				'Guaranteed <font color="#FF0000">Mythic</font> in: <font color="#00FF00">08:32</font>'
			)
		end)

		it('keeps static words uncolored for Legendary too', function()
			local text = EggTimerController._TestFormat('Legendary', '#FFF700', '#FF4646', '03:17')
			expect(string.find(text, 'Guaranteed <font', 1, true)).to.be.ok()
			expect(string.find(text, '</font> in: <font', 1, true)).to.be.ok()
			expect(string.find(text, '>Legendary<', 1, true)).to.be.ok()
			expect(string.find(text, '>03:17<', 1, true)).to.be.ok()
		end)
	end)
end
