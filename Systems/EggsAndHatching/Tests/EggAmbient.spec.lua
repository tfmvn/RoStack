--!strict
--!native
--[[
	EggAmbient.spec
	================
	Regression guard for the ambient/purchased movement split:

	  * Ambient eggs roam the EggArea floor ONLY. The module
	    must expose NO base/collector targeting surface: no
	    SetBaseService, no target pickers, no seek states to
	    drive. (The purchasing player's Base Collector belongs
	    exclusively to the FlightController travel path, which
	    takes over after Purchase unregisters the model here.)
	  * Register/Unregister lifecycle stays balanced.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local AmbientService = require(ServerScriptService.Egg.AmbientService)

	describe('EggAmbientService movement split', function()
		it('exposes no base/collector targeting surface', function()
			expect((AmbientService :: any).SetBaseService).to.equal(nil)
			expect((AmbientService :: any).PickTarget).to.equal(nil)
			expect((AmbientService :: any).GetTargets).to.equal(nil)
			expect((AmbientService :: any).SeekBase).to.equal(nil)
			expect((AmbientService :: any).SetCollector).to.equal(nil)
		end)

		it('keeps the roam lifecycle surface intact', function()
			expect(type(AmbientService.Init)).to.equal('function')
			expect(type(AmbientService.Start)).to.equal('function')
			expect(type(AmbientService.Stop)).to.equal('function')
			expect(type(AmbientService.RegisterModel)).to.equal('function')
			expect(type(AmbientService.UnregisterModel)).to.equal('function')
		end)

		it('Register/Unregister degrade gracefully on garbage input', function()
			expect(function()
				AmbientService.RegisterModel(nil)
				AmbientService.RegisterModel({} :: any)
				AmbientService.UnregisterModel(nil)
				AmbientService.UnregisterModel({} :: any)
			end).to.never.throw()
		end)
	end)
end
