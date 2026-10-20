--!strict
--!native
--[[
	ArenaSlots.spec
	================
	Phase 1.5 headless coverage for real ArenaAnimalStands
	slots: deterministic index namespace, SlotService
	registration/transitions on arena ids, normal-track
	isolation (GetFreeSlot never returns arena), rebase +
	unregister lifecycle, and ResolveArenaTeam semantics
	(order, dedupe, invalid-skip) with injected fakes.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local UID = 940001

	local function arenaRecord(index: number, state: string, occupantId: string?): any
		return {
			id = SlotType.BuildId(UID, SlotType.Kind.Slot, index),
			ownerUserId = UID,
			baseId = 'Base_ArenaSpec',
			kind = SlotType.Kind.Slot,
			index = index,
			arenaIndex = index - 1000,
			arena = true,
			state = state,
			occupantId = occupantId,
			occupantKind = if occupantId ~= nil then SlotType.OccupantKind.Animal else nil,
			_mutex = false,
			part = nil,
			cashCollector = nil,
			stand = nil,
			standIndex = index - 1000,
			offset = Vector3.new(0, 2, 0),
		}
	end

	local function normalRecord(index: number, state: string): any
		local rec = arenaRecord(index, state, nil)
		rec.arena = nil
		rec.arenaIndex = nil
		return rec
	end

	local function fakeBase()
		return {
			id = 'Base_ArenaSpec',
			slots = { normalRecord(1, SlotType.State.Empty) },
			arenaSlots = {
				arenaRecord(1001, SlotType.State.Empty, nil),
				arenaRecord(1002, SlotType.State.Empty, nil),
			},
		}
	end

	describe('ArenaSlots index namespace', function()
		it('uses 1000-based indices inside the canonical id format', function()
			local DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)
			expect(DynamicSlotService.ArenaSlotIndexBase()).to.equal(1000)
			local id = SlotType.BuildId(UID, SlotType.Kind.Slot, 1001)
			expect(string.find(id, ':1001$') ~= nil).to.equal(true)
			expect(id == SlotType.BuildId(UID, SlotType.Kind.Slot, 1)).to.equal(false)
		end)

		it('exposes MinTeamSize from ArenaConfig', function()
			local ArenaConfig = require(ReplicatedStorage.Config.World.Arena)
			expect(ArenaConfig.MinTeamSize()).to.equal(1)
		end)
	end)

	describe('ArenaSlots SlotService registry', function()
		it('registers, resolves, and transitions arena ids', function()
			local SlotService = require(ServerScriptService.Base.SlotService)
			local base = fakeBase()
			SlotService.RegisterBase(base)
			local found = SlotService._findSlotById(SlotType.BuildId(UID, SlotType.Kind.Slot, 1001))
			expect(found).to.be.ok()
			expect((found :: any).arena).to.equal(true)
			-- Full Empty -> Reserved -> Occupied -> Empty cycle,
			-- plus the Demote (Occupied -> Reserved) path grabs use.
			expect(SlotService.ReserveSlot((found :: any).id)).to.equal(true)
			expect(SlotService.OccupySlot((found :: any).id, 'AN_arena1', SlotType.OccupantKind.Animal)).to.equal(true)
			local byOcc = SlotService.FindSlotByOccupant('AN_arena1')
			expect(byOcc).to.be.ok()
			expect((byOcc :: any).arena).to.equal(true)
			expect(SlotService.ReleaseSlot((found :: any).id)).to.equal(true)
			expect(SlotService.ReserveSlot((found :: any).id)).to.equal(true)
			expect(SlotService.OccupySlot((found :: any).id, 'AN_arena2', SlotType.OccupantKind.Animal)).to.equal(true)
			expect(SlotService.DemoteSlotToReserved((found :: any).id)).to.equal(true)
			expect(SlotService.ReleaseSlot((found :: any).id)).to.equal(true)
			SlotService.UnregisterBase(base.id)
			expect(SlotService._findSlotById(SlotType.BuildId(UID, SlotType.Kind.Slot, 1001))).to.equal(nil)
		end)

		it('keeps GetFreeSlot normal-only', function()
			local SlotService = require(ServerScriptService.Base.SlotService)
			local base = fakeBase()
			SlotService.RegisterBase(base)
			SlotService.SetBaseOwner(UID, base)
			local free = SlotService.GetFreeSlot(UID)
			expect(free).to.be.ok()
			expect((free :: any).arena == true).to.equal(false)
			expect((free :: any).id).to.equal(SlotType.BuildId(UID, SlotType.Kind.Slot, 1))
			SlotService.ClearBaseOwner(UID)
			SlotService.UnregisterBase(base.id)
		end)

		it('rebases and unregisters arena ids by identity', function()
			local SlotService = require(ServerScriptService.Base.SlotService)
			local base = fakeBase()
			SlotService.RegisterBase(base)
			local oldId = SlotType.BuildId(UID, SlotType.Kind.Slot, 1001)
			-- Simulate an owner re-stamp, then rebase.
			for _, slot in pairs(base.arenaSlots) do
				slot.ownerUserId = UID + 1
				slot.id = SlotType.BuildId(UID + 1, SlotType.Kind.Slot, slot.index)
			end
			SlotService.RebaseSlotIds(base)
			expect(SlotService._findSlotById(oldId)).to.equal(nil)
			local fresh = SlotService._findSlotById(SlotType.BuildId(UID + 1, SlotType.Kind.Slot, 1001))
			expect(fresh).to.be.ok()
			SlotService.UnregisterArenaSlots(base.id)
			expect(SlotService._findSlotById(SlotType.BuildId(UID + 1, SlotType.Kind.Slot, 1001))).to.equal(nil)
			-- Normal record survived the arena unregister.
			expect(SlotService._findSlotById(SlotType.BuildId(UID, SlotType.Kind.Slot, 1))).to.be.ok()
			SlotService.UnregisterBase(base.id)
		end)
	end)

	describe('ArenaSlots prompts', function()
		it('shows arena Place prompts to animal carriers only', function()
			local CarryPrompts = require(ServerScriptService.Animal.CarryPrompts)
			local normalPart = Instance.new('Part')
			local arenaPart = Instance.new('Part')
			local normalRec: any = normalRecord(1, SlotType.State.Empty)
			local arenaRec: any = arenaRecord(1001, SlotType.State.Empty, nil)
			normalRec.part = normalPart
			arenaRec.part = arenaPart
			local base = {
				slots = { normalRec },
				arenaSlots = { arenaRec },
			}
			CarryPrompts.InstallPlacePromptsForBase(base, UID, 'animal')
			expect(normalPart:FindFirstChild('PlacePrompt')).to.be.ok()
			expect(arenaPart:FindFirstChild('PlacePrompt')).to.be.ok()
			CarryPrompts.RemovePlacePromptsForBase(base)
			CarryPrompts.InstallPlacePromptsForBase(base, UID, 'egg')
			expect(normalPart:FindFirstChild('PlacePrompt')).to.be.ok()
			expect(arenaPart:FindFirstChild('PlacePrompt')).to.equal(nil)
			CarryPrompts.RemovePlacePromptsForBase(base)
			normalPart:Destroy()
			arenaPart:Destroy()
		end)

		it('installs Pickup AND Steal on arena occupants (steal parity)', function()
			local CarryPrompts = require(ServerScriptService.Animal.CarryPrompts)
			local primary = Instance.new('Part')
			primary.Name = 'HumanoidRootPart'
			local model = Instance.new('Model')
			model.Name = 'SpecAnimal'
			primary.Parent = model
			model.PrimaryPart = primary
			local slot = arenaRecord(1001, SlotType.State.Occupied, 'AN_x')
			CarryPrompts.InstallPickupPrompt(model, 'AN_x', 'animal', slot, UID)
			expect(primary:FindFirstChild('PickupPrompt')).to.be.ok()
			-- Arena stands are first-class slots: non-owners get
			-- the same Steal prompt as on normal stands (server
			-- validates lock/distance/ownership identically).
			expect(primary:FindFirstChild('StealPrompt')).to.be.ok()
			CarryPrompts._UnregisterPromptsForSlot(slot.id)
			CarryPrompts.RemovePromptsFromModel(model)
			model:Destroy()
		end)
	end)

	describe('ArenaSlots stand compatibility', function()
		local function arenaStand()
			local stand = Instance.new('Model')
			stand.Name = 'ArenaStand1'
			local slot = Instance.new('Part')
			slot.Name = 'Slot'
			local root = Instance.new('Part')
			root.Name = 'Root'
			root.Parent = slot
			local menuPart = Instance.new('Part')
			menuPart.Name = 'MenuPart'
			local menuGui = Instance.new('SurfaceGui')
			menuGui.Name = 'MenuGui'
			local upgrade = Instance.new('TextButton')
			upgrade.Name = 'UpgradeButton'
			local lvl = Instance.new('TextLabel')
			lvl.Name = 'Level'
			lvl.Parent = upgrade
			local cost = Instance.new('TextLabel')
			cost.Name = 'UpgradeAmount'
			cost.Parent = upgrade
			upgrade.Parent = menuGui
			menuGui.Parent = menuPart
			menuPart.Parent = slot
			slot.Parent = stand
			local button = Instance.new('Folder')
			button.Name = 'Button'
			local press = Instance.new('Part')
			press.Name = 'PressPart'
			press.Parent = button
			local surfaceGui = Instance.new('SurfaceGui')
			surfaceGui.Name = 'SurfaceGui'
			local amount = Instance.new('TextLabel')
			amount.Name = 'Amount'
			amount.Text = '$0'
			amount.Parent = surfaceGui
			surfaceGui.Parent = press
			local base = Instance.new('Part')
			base.Name = 'Base'
			base.Parent = button
			button.Parent = stand
			return {
				stand = stand,
				root = root,
				press = press,
				upgrade = upgrade,
				levelLabel = lvl,
			}
		end

		local function bareStand()
			-- Template-shaped stand with NO menu/cash parts:
			-- the auto-provisioner must fill exactly those.
			local stand = Instance.new('Model')
			stand.Name = 'ArenaStand9'
			local root = Instance.new('Part')
			root.Name = 'Root'
			root.Size = Vector3.new(4, 1, 4)
			root.CFrame = CFrame.new(0, 5, 0)
			root.Anchored = true
			root.Parent = stand
			return stand
		end

		it('resolves part, collector, and menu button from arena stands', function()
			local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
			local built = arenaStand()
			local parts = StandResolver.GetStandParts(built.stand)
			expect(parts.root).to.equal(built.root)
			expect(parts.pressPart).to.equal(built.press)
			expect(parts.upgradeButton).to.equal(built.upgrade)
			built.stand:Destroy()
		end)

		it('paints the upgrade readout on arena stands', function()
			local StandDisplayService = require(ServerScriptService.Base.StandDisplayService)
			local built = arenaStand()
			local record: any = arenaRecord(1001, SlotType.State.Occupied, 'AN_d1')
			record.part = built.root
			record.cashCollector = built.press
			record.stand = built.stand
			StandDisplayService.SetAnimalService({
				Get = function(_uniqueId: string)
					return { uniqueId = 'AN_d1', ownerUserId = UID, Level = 3, definitionId = 'Tiger' }
				end,
			})
			StandDisplayService.SetUpgradeService({
				GetUpgradeCost = function(_defId: string, _level: number)
					return '1000'
				end,
			})
			StandDisplayService.RefreshSlot(record)
			expect(built.levelLabel.Text).to.equal('3 >> 4')
			StandDisplayService.SetAnimalService(nil)
			StandDisplayService.SetUpgradeService(nil)
			built.stand:Destroy()
		end)

		it('collects arena CashPool through the canonical path', function()
			local IncomeService = require(ServerScriptService.IncomeService)
			local Helpers = require(script.Parent._Helpers)
			Helpers.StubRemotes()
			local built = arenaStand()
			local record: any = arenaRecord(1001, SlotType.State.Occupied, 'AN_c1')
			record.part = built.root
			record.cashCollector = built.press
			record.stand = built.stand
			local profile: any = {
				Money = '0',
				Multipliers = { Money = 1 },
				Brainrots = { { Id = 'AN_c1', Type = 'Brainrot', CashPool = '500' } },
			}
			local grants: { any } = {}
			IncomeService.SetPlayerService({
				GetPlayerData = function(_userId: number)
					return profile
				end,
			})
			IncomeService.SetEconomyService({
				AddMoney = function(_userId: number, amount: string, _reason: string, _opts: any)
					grants[#grants + 1] = amount
					return { Success = true, NewMoney = amount }
				end,
			})
			local player = Helpers.FakePlayer(UID)
			IncomeService.TryCollect(record, player)
			expect(profile.Brainrots[1].CashPool).to.equal('0')
			expect(#grants).to.equal(1)
			expect(grants[1]).to.equal('500')
			IncomeService.SetPlayerService(nil)
			IncomeService.SetEconomyService(nil)
			built.stand:Destroy()
		end)

		it('mirrors the arena pool into SurfaceGui.Amount (sweep path)', function()
			-- The throttled sweep calls _publishSlot, exposed
			-- headlessly through RepublishSlot: same call the
			-- per-second loop makes for every slot.
			local IncomeService = require(ServerScriptService.IncomeService)
			local built = arenaStand()
			local record: any = arenaRecord(1001, SlotType.State.Occupied, 'AN_m1')
			record.part = built.root
			record.cashCollector = built.press
			record.stand = built.stand
			local amountLabel = built.press:FindFirstChild('SurfaceGui')
			expect(amountLabel).to.be.ok()
			IncomeService.SetPlayerService({
				GetPlayerData = function(_userId: number)
					return {
						Brainrots = { { Id = 'AN_m1', Type = 'Brainrot', CashPool = '1250' } },
					}
				end,
			})
			IncomeService.RepublishSlot(record)
			local textLabel = (built.press:FindFirstChild('SurfaceGui') :: Instance):FindFirstChild('Amount')
			expect(textLabel).to.be.ok()
			expect((textLabel :: TextLabel).Text ~= '$0').to.equal(true)
			IncomeService.SetPlayerService(nil)
			built.stand:Destroy()
		end)

		it('auto-provisions missing menu/cash parts on bare stands', function()
			local DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)
			local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
			local stand = bareStand()
			expect(DynamicSlotService.EnsureArenaStandParts(stand)).to.equal(true)
			local parts = StandResolver.GetStandParts(stand)
			expect(parts.root).to.be.ok()
			expect(parts.menuPart).to.be.ok()
			expect(parts.menuGui).to.be.ok()
			-- No hand-built button: the UpgradeButton comes
			-- exclusively from the shared template pipeline
			-- (StandDisplayService), so arena buttons can
			-- never drift from normal stands.
			expect(parts.upgradeButton).to.equal(nil)
			expect(parts.pressPart).to.be.ok()
			expect(parts.pressPart:IsA('BasePart')).to.equal(true)
			local amount = parts.pressPart:FindFirstChild('SurfaceGui')
			expect(amount).to.be.ok()
			-- NO selling UI on arena stands by design: the
			-- provisioner never creates a SellButton.
			local menuGui = parts.menuGui
			expect(menuGui).to.be.ok()
			expect((menuGui :: Instance):FindFirstChild('SellButton')).to.equal(nil)
			-- Idempotent: second pass creates nothing new.
			local function countMenuButtons(): number
				local n = 0
				for _, d in ipairs(stand:GetDescendants()) do
					if d.Name == 'UpgradeButton' then
						n += 1
					end
				end
				return n
			end
			local function countPress(): number
				local n = 0
				for _, d in ipairs(stand:GetDescendants()) do
					if d.Name == 'PressPart' then
						n += 1
					end
				end
				return n
			end
			expect(DynamicSlotService.EnsureArenaStandParts(stand)).to.equal(true)
			expect(countMenuButtons()).to.equal(0)
			expect(countPress()).to.equal(1)
			stand:Destroy()
		end)

		it('arena stands receive template UpgradeButtons through the shared pipeline', function()
			local ServerStorage = game:GetService('ServerStorage')
			local DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)
			local StandDisplayService = require(ServerScriptService.Base.StandDisplayService)
			-- Stage the authoritative template (destroyed with
			-- the test; the resolver re-resolves when gone).
			local assets = Instance.new('Folder')
			assets.Name = 'Assets'
			local map = Instance.new('Folder')
			map.Name = 'Map'
			map.Parent = assets
			local bases = Instance.new('Folder')
			bases.Name = 'Bases'
			bases.Parent = map
			local base = Instance.new('Folder')
			base.Name = 'Base'
			base.Parent = bases
			local ui = Instance.new('Folder')
			ui.Name = 'Ui'
			ui.Parent = base
			local standUi = Instance.new('Folder')
			standUi.Name = 'Stand'
			standUi.Parent = ui
			local template = Instance.new('TextButton')
			template.Name = 'UpgradeButtonTemplate'
			template.Font = Enum.Font.GothamBlack
			local tlevel = Instance.new('TextLabel')
			tlevel.Name = 'Level'
			tlevel.Parent = template
			local tcost = Instance.new('TextLabel')
			tcost.Name = 'UpgradeAmount'
			tcost.Parent = template
			template.Parent = standUi
			assets.Parent = ServerStorage
			-- Slot-shaped stand (Slot/Root present, menu parts
			-- absent): the provisioner adds MenuPart/MenuGui,
			-- the shared menu pipeline adds the button.
			local stand = Instance.new('Model')
			stand.Name = 'ArenaStandT'
			local slotPart = Instance.new('Part')
			slotPart.Name = 'Slot'
			slotPart.Parent = stand
			local rootPart = Instance.new('Part')
			rootPart.Name = 'Root'
			rootPart.Parent = slotPart
			expect(DynamicSlotService.EnsureArenaStandParts(stand)).to.equal(true)
			StandDisplayService.SetAnimalService({
				Get = function(_uniqueId: string)
					return { uniqueId = 'AN_tm', ownerUserId = UID, Level = 3, definitionId = 'Tiger' }
				end,
			})
			StandDisplayService.SetUpgradeService({
				GetUpgradeCost = function(_defId: string, _level: number)
					return '1000'
				end,
			})
			local record: any = arenaRecord(1001, SlotType.State.Occupied, 'AN_tm')
			record.stand = stand
			StandDisplayService.RefreshSlot(record)
			local menuGui = stand:FindFirstChild('MenuPart', true)
			local gui = menuGui and (menuGui :: Instance):FindFirstChild('MenuGui', true) or nil
			assert(gui ~= nil, 'MenuGui present')
			local buttons: { Instance } = {}
			for _, child in ipairs((gui :: Instance):GetChildren()) do
				if child.Name == 'UpgradeButton' then
					buttons[#buttons + 1] = child
				end
			end
			expect(#buttons).to.equal(1)
			local button = buttons[1]
			-- Managed template clone (never a hand-built twin):
			-- same font as the template, full coverage.
			expect(button:GetAttribute('StandMenuManaged')).to.equal(true)
			expect((button :: TextButton).Font).to.equal(Enum.Font.GothamBlack)
			expect((button :: GuiObject).Size).to.equal(UDim2.fromScale(1, 1))
			expect((button :: GuiObject).Position).to.equal(UDim2.fromScale(0, 0))
			local level = button:FindFirstChild('Level')
			expect((level :: TextLabel).Text).to.equal('3 >> 4')
			StandDisplayService.SetAnimalService(nil)
			StandDisplayService.SetUpgradeService(nil)
			stand:Destroy()
			assets:Destroy()
		end)

		it('reuses authored parts instead of duplicating', function()
			local DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)
			local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
			local built = arenaStand()
			expect(DynamicSlotService.EnsureArenaStandParts(built.stand)).to.equal(true)
			local parts = StandResolver.GetStandParts(built.stand)
			expect(parts.upgradeButton).to.equal(built.upgrade)
			expect(parts.pressPart).to.equal(built.press)
			built.stand:Destroy()
		end)

		it('appends arena snapshots after normal slots', function()
			local SlotService = require(ServerScriptService.Base.SlotService)
			local base = {
				id = 'Base_SnapSpec',
				slots = {},
				arenaSlots = {},
			}
			local n1: any = normalRecord(1, SlotType.State.Empty, nil)
			n1.part = nil
			base.slots = { n1 }
			local a1: any = arenaRecord(1001, SlotType.State.Empty, nil)
			a1.part = nil
			base.arenaSlots = { a1 }
			local snap = SlotService.SnapshotBaseSlots(base)
			expect(snap).to.be.ok()
			expect((snap :: any)[1].Id).to.equal(n1.id)
			expect((snap :: any)[1].Arena).to.equal(nil)
			expect((snap :: any)[#snap].Id).to.equal(a1.id)
			expect((snap :: any)[#snap].Arena).to.equal(true)
			expect((snap :: any)[#snap].State).to.equal(SlotType.State.Empty)
		end)

		it('builds stands, records, and a collectible arena slot end to end', function()
			local ServerStorage = game:GetService('ServerStorage')
			local DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)
			local SlotService = require(ServerScriptService.Base.SlotService)
			local IncomeService = require(ServerScriptService.IncomeService)
			local Helpers = require(script.Parent._Helpers)
			Helpers.StubRemotes()
			DynamicSlotService._TestReset()

			-- Fake authored content: template + one marker.
			local assets = Instance.new('Folder')
			assets.Name = 'Assets'
			local map = Instance.new('Folder')
			map.Name = 'Map'
			map.Parent = assets
			local bases = Instance.new('Folder')
			bases.Name = 'Bases'
			bases.Parent = map
			local templateBase = Instance.new('Folder')
			templateBase.Name = 'Base'
			templateBase.Parent = bases
			local template = Instance.new('Part')
			template.Name = 'ArenaStandTemplate'
			template.Size = Vector3.new(4, 1, 4)
			template.Anchored = true
			template.Parent = templateBase
			assets.Parent = ServerStorage

			local folder = Instance.new('Folder')
			folder.Name = 'Base_CashSpec'
			local markers = Instance.new('Folder')
			markers.Name = 'ArenaStandPos'
			markers.Parent = folder
			local marker = Instance.new('Part')
			marker.Name = 'ArenaStandPos1'
			marker.Size = Vector3.new(4, 1, 4)
			marker.CFrame = CFrame.new(100, 5, 100)
			marker.Anchored = true
			marker.Parent = markers

			local CASH_UID = 950001
			local base: any = { id = 'Base_CashSpec', folder = folder, session = 0, slots = {} }
			local live = DynamicSlotService.BuildArenaStands(base, CASH_UID, 0)
			expect(live).to.equal(1)
			expect(#base.arenaSlots).to.equal(1)
			local record = base.arenaSlots[1]
			expect(record.part).to.be.ok()
			-- The cash trigger resolved from the stand: this
			-- is the hookup that was missing (wiring ran
			-- before records existed).
			expect(record.cashCollector).to.be.ok()
			expect(record.cashCollector:IsA('BasePart')).to.equal(true)
			expect(record.state).to.equal(SlotType.State.Empty)

			-- Occupy through the canonical transitions, then
			-- collect through the canonical path.
			expect(SlotService.ReserveSlot(record.id)).to.equal(true)
			expect(SlotService.OccupySlot(record.id, 'AN_cc9', SlotType.OccupantKind.Animal)).to.equal(true)
			local profile: any = {
				Money = '0',
				Multipliers = { Money = 1 },
				Brainrots = { { Id = 'AN_cc9', Type = 'Brainrot', CashPool = '750' } },
			}
			local grants: { any } = {}
			IncomeService.SetPlayerService({
				GetPlayerData = function(_userId: number)
					return profile
				end,
			})
			IncomeService.SetEconomyService({
				AddMoney = function(_userId: number, amount: string, _reason: string, _opts: any)
					grants[#grants + 1] = amount
					return { Success = true, NewMoney = amount }
				end,
			})
			IncomeService.TryCollect(record, Helpers.FakePlayer(CASH_UID))
			expect(profile.Brainrots[1].CashPool).to.equal('0')
			expect(#grants).to.equal(1)
			expect(grants[1]).to.equal('750')

			IncomeService.SetPlayerService(nil)
			IncomeService.SetEconomyService(nil)
			SlotService.UnregisterBase(base.id)
			DynamicSlotService._TestReset()
			folder:Destroy()
			assets:Destroy()
		end)
	end)

	describe('ArenaService.ResolveArenaTeam', function()
		it('returns empty when unwired or baseless', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			ArenaService._TestReset()
			expect(ArenaService.ResolveArenaTeam(999888).count).to.equal(0)
		end)

		it('orders by arenaIndex, dedupes, and skips invalid', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local animals: { [string]: any } = {
				AN_t1 = {
					uniqueId = 'AN_t1',
					definitionId = 'Tiger',
					displayName = 'Tiger',
					rarity = 'Epic',
					ownerUserId = UID,
					state = 'Slotted',
					slotId = SlotType.BuildId(UID, SlotType.Kind.Slot, 1002),
					Level = 5,
				},
				AN_t2 = {
					uniqueId = 'AN_t2',
					definitionId = 'Frog',
					displayName = 'Frog',
					rarity = 'Common',
					ownerUserId = UID,
					state = 'Slotted',
					slotId = SlotType.BuildId(UID, SlotType.Kind.Slot, 1001),
					Level = 2,
				},
				AN_bad = {
					uniqueId = 'AN_bad',
					definitionId = 'Dog',
					displayName = 'Dog',
					rarity = 'Common',
					ownerUserId = UID + 9,
					state = 'Slotted',
					slotId = SlotType.BuildId(UID, SlotType.Kind.Slot, 1003),
					Level = 1,
				},
			}
			local arenaSlots = {
				arenaRecord(1002, SlotType.State.Occupied, 'AN_t1'),
				arenaRecord(1001, SlotType.State.Occupied, 'AN_t2'),
				-- Duplicate UniqueId on a second record: ignored.
				arenaRecord(1003, SlotType.State.Occupied, 'AN_t1'),
				-- Foreign-owned animal: skipped.
				arenaRecord(1004, SlotType.State.Occupied, 'AN_bad'),
			}
			-- Fix slotIds on the records to match their slots.
			animals.AN_t1.slotId = SlotType.BuildId(UID, SlotType.Kind.Slot, 1002)
			animals.AN_t2.slotId = SlotType.BuildId(UID, SlotType.Kind.Slot, 1001)
			ArenaService.SetBaseService({
				GetBaseByOwner = function(_userId: number)
					return { id = 'Base_Team', arenaSlots = arenaSlots }
				end,
			})
			ArenaService.SetAnimalService({
				Get = function(uniqueId: string)
					return animals[uniqueId]
				end,
			})
			local team = ArenaService.ResolveArenaTeam(UID)
			expect(team.count).to.equal(2)
			expect(team.members[1].UniqueId).to.equal('AN_t2')
			expect(team.members[2].UniqueId).to.equal('AN_t1')
			expect(team.members[1].ArenaIndex).to.equal(1)
			ArenaService._TestReset()
			ArenaService.SetBaseService(nil)
			ArenaService.SetAnimalService(nil)
		end)
	end)
end
