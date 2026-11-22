--!strict
const Interfacer = require("../src")
local Cleanups = 0
const Stop = Interfacer.Mount(function()
	assert(Interfacer.GetOwner() ~= nil, "render has a scope")
	Interfacer.Cleanup(function()
		Cleanups += 1
	end)
end)
assert(Cleanups == 0, "mount stays active after rendering")
Stop()
Stop()
assert(Cleanups == 1, "unmount is idempotent")
const Failure = {}
const Passed, Cause = pcall(function()
	Interfacer.Mount(function()
		Interfacer.Cleanup(function()
			Cleanups += 1
		end)
		error(Failure, 0)
	end)
end)
assert(not Passed and Cause == Failure and Cleanups == 2, "render failure releases the scope and preserves the error object")
print("FLUX V052 MOUNT PASS")
