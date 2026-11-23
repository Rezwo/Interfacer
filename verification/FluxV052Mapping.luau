--!strict

const Interfacer = require("../src")
const Items = Interfacer.State({ { Identifier = "A", Value = 1 }, { Identifier = "B", Value = 2 } })
local Builds = 0
local Cleanups = 0
local EmptyCleanups = 0
const Mapped = Interfacer.ForKey(Items, function(Item)
	return Item.Identifier
end, function(Index, Item)
	Builds += 1
	Interfacer.Cleanup(function()
		Cleanups += 1
	end)
	return { Index = Index, Item = Item }
end, function()
	Interfacer.Cleanup(function()
		EmptyCleanups += 1
	end)
	return "empty"
end)
const Initial = Mapped:Get()
const First = Initial[1]
assert(type(First) == "table", "initial mapped row")
Items:Set({ { Identifier = "B", Value = 3 }, { Identifier = "A", Value = 4 } })
const Reordered = Mapped:Get()
assert(Reordered[2] == First and First.Index:Get() == 2 and First.Item:Get().Value == 4 and Builds == 2, "same-key replacement retains the row and refreshes both reactive inputs")
Items:Set({})
assert(Mapped:Get()[1] == "empty" and Cleanups == 2, "empty revision releases both rows")
Items:Set({ { Identifier = "C", Value = 5 } })
assert(type(Mapped:Get()[1]) == "table" and EmptyCleanups == 1, "leaving empty state releases fallback")
Mapped:Destroy()
assert(Cleanups == 3, "destroy releases the final row")
print("FLUX V052 MAPPING PASS")
