--!strict
--[[
	Signals
	=======
	Re-export of sleitnick/signal. Imported in one place so callers
	can swap libraries by editing this file only.
]]

local Signal = require(script.Parent.Parent.Packages.Signal)
return Signal
