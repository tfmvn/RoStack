--!strict
--!native
--[[
	HudTree.spec
	============
	Shared HUD path resolver: nested Studio hierarchy first,
	legacy flat layout as fallback, nil-safe everywhere.
	Builds plain Instances (no Studio HUD required).
]]

return function()
	local StarterPlayer = game:GetService('StarterPlayer')

	local HudTree = require(StarterPlayer.StarterPlayerScripts.HudTree)
	local ArenaController = require(StarterPlayer.StarterPlayerScripts.ArenaController)

	local function playerGuiWith(build: (Instance) -> ()): Instance
		local root = Instance.new('Folder')
		root.Name = 'PlayerGui'
		local hud = Instance.new('Folder')
		hud.Name = 'HUD'
		hud.Parent = root
		build(hud)
		return root
	end

	local function textLabel(name: string): TextLabel
		local label = Instance.new('TextLabel')
		label.Name = name
		return label
	end

	describe('HudTree nested resolution', function()
		it('resolves BottomLeft money + luck text labels', function()
			local gui = playerGuiWith(function(hud: Instance)
				local left = Instance.new('Folder')
				left.Name = 'BottomLeft'
				left.Parent = hud
				local money = Instance.new('Folder')
				money.Name = 'MoneyCounter'
				money.Parent = left
				local moneyText = textLabel('Text')
				moneyText.Parent = money
				local luck = textLabel('ServerLuckCounter')
				luck.Parent = left
			end)
			expect(HudTree.MoneyText(gui)).to.be.ok()
			expect((HudTree.MoneyText(gui) :: TextLabel).Name).to.equal('Text')
			expect(HudTree.LuckText(gui)).to.be.ok()
			expect((HudTree.LuckText(gui) :: TextLabel).Name).to.equal('ServerLuckCounter')
		end)

		it('resolves Left buttons + tutorial + notification + wave nodes', function()
			local gui = playerGuiWith(function(hud: Instance)
				local left = Instance.new('Folder')
				left.Name = 'Left'
				left.Parent = hud
				local rb = Instance.new('TextButton')
				rb.Name = 'RebirthButton'
				rb.Parent = left
				local sb = Instance.new('TextButton')
				sb.Name = 'ShopButton'
				sb.Parent = left
				local top = Instance.new('Folder')
				top.Name = 'Top'
				top.Parent = hud
				local tut = Instance.new('Folder')
				tut.Name = 'Tutorial'
				tut.Parent = top
				local counter = textLabel('Counter')
				counter.Parent = tut
				local steps = textLabel('Steps')
				steps.Parent = tut
				local center = Instance.new('Folder')
				center.Name = 'Center'
				center.Parent = hud
				local notif = textLabel('Notification')
				notif.Parent = center
				local bottom = Instance.new('Folder')
				bottom.Name = 'Bottom'
				bottom.Parent = hud
				local wave = Instance.new('Folder')
				wave.Name = 'WaveCounter'
				wave.Parent = bottom
				local waveText = textLabel('Counter')
				waveText.Parent = wave
			end)
			expect(HudTree.RebirthButton(gui)).to.be.ok()
			expect(HudTree.ShopButton(gui)).to.be.ok()
			expect(HudTree.TutorialCounter(gui)).to.be.ok()
			expect(HudTree.TutorialSteps(gui)).to.be.ok()
			expect((HudTree.TutorialSteps(gui) :: TextLabel).Name).to.equal('Steps')
			expect(HudTree.NotificationPanel(gui)).to.be.ok()
			expect(HudTree.WaveCounter(gui)).to.be.ok()
			expect((HudTree.WaveCounter(gui) :: TextLabel).Name).to.equal('Counter')
		end)

		it('falls back to legacy flat layout', function()
			local gui = playerGuiWith(function(hud: Instance)
				local money = textLabel('MoneyCounter')
				money.Parent = hud
				local luck = textLabel('ServerLuck')
				luck.Parent = hud
				local rb = Instance.new('TextButton')
				rb.Name = 'RebirthButton'
				rb.Parent = hud
				local notifs = Instance.new('Frame')
				notifs.Name = 'Notifications'
				notifs.Parent = hud
			end)
			expect(HudTree.MoneyText(gui)).to.be.ok()
			expect(HudTree.LuckText(gui)).to.be.ok()
			expect(HudTree.RebirthButton(gui)).to.be.ok()
			expect(HudTree.ShopButton(gui)).to.equal(nil)
			expect(HudTree.TutorialCounter(gui)).to.equal(nil)
			expect(HudTree.NotificationPanel(gui)).to.be.ok()
		end)

		it('is nil-safe on missing trees', function()
			expect(HudTree.MoneyText(nil)).to.equal(nil)
			expect(HudTree.LuckText(nil)).to.equal(nil)
			expect(HudTree.RebirthButton(nil)).to.equal(nil)
			expect(HudTree.ShopButton(nil)).to.equal(nil)
			expect(HudTree.TutorialCounter(nil)).to.equal(nil)
			expect(HudTree.TutorialSteps(nil)).to.equal(nil)
			expect(HudTree.NotificationPanel(nil)).to.equal(nil)
			expect(HudTree.WaveCounter(nil)).to.equal(nil)
			local empty = Instance.new('Folder')
			empty.Name = 'PlayerGui'
			expect(HudTree.MoneyText(empty)).to.equal(nil)
			expect(HudTree.WaveCounter(empty)).to.equal(nil)
		end)
	end)

	describe('ArenaController wave text', function()
		it('renders "Wave N" from the authoritative session Stage', function()
			expect(ArenaController._TestWaveText({ Stage = 3 })).to.equal('Wave 3')
			expect(ArenaController._TestWaveText({ ArenaLevel = 7 })).to.equal('Wave 7')
			expect(ArenaController._TestWaveText({})).to.equal(nil)
			expect(ArenaController._TestWaveText(nil)).to.equal(nil)
		end)
	end)
end
