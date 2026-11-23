--!strict
const Interfacer = require("../src")
const Depth = 24000
const HeavyDepth = 32
const HeavySource = Interfacer.State(3)
local Heavy : Interfacer.Node<number> = HeavySource
for Index = 1, HeavyDepth do
	local Previous = Heavy
	Heavy = Interfacer.Computed(function()
		return Previous:Get() + 1
	end)
	assert(Heavy:Get() == Index + 3, "prime taller input")
end
const UseHeavy = Interfacer.State(false)
local Tail = Interfacer.Computed(function()
	return if UseHeavy:Get() then Heavy:Get() else 0
end)
local Middle = Tail
local Calculations = 0
for Index = 1, Depth do
	local Previous = Tail
	Tail = Interfacer.Computed(function()
		Calculations += 1
		return Previous:Get() + 1
	end)
	assert(Tail:Get() == Index, "prime live chain")
	if Index == Depth / 2 then
		Middle = Tail
	end
end
const Upper = Interfacer.Computed(function()
	return Middle:Get() + 2
end)
const Lower = Interfacer.Computed(function()
	return Middle:Get() + 3
end)
const Total = Interfacer.Computed(function()
	return Upper:Get() + Lower:Get() + Tail:Get()
end)
local Observed : number? = nil
local Runs = 0
const Owner = Interfacer.Scope(function()
	Interfacer.Effect(function()
		Observed = Total:Get()
		Runs += 1
	end)
end)
Interfacer.Flush()
const BaseValue = Depth * 2 + 5
assert(Observed == BaseValue and Runs == 1 and Calculations == Depth, "initial fan-out settles")
print("ATTACHED BEFORE SWITCH", Depth)
UseHeavy:Set(true)
Interfacer.Flush()
assert(Observed == BaseValue + 3 * (HeavyDepth + 3), "switch to a taller input propagates through both branches")
assert(Runs == 2 and Calculations == Depth * 2, "switch recalculates each link once")
HeavySource:Set(4)
Interfacer.Flush()
assert(Observed == BaseValue + 3 * (HeavyDepth + 4) and Runs == 3, "new dependency remains live")
UseHeavy:Set(false)
Interfacer.Flush()
assert(Observed == BaseValue and Runs == 4 and Calculations == Depth * 4, "switch back fully settles")
HeavySource:Set(5)
Interfacer.Flush()
assert(Runs == 4 and Calculations == Depth * 4, "detached input no longer invalidates")
Owner:Destroy()
print("LIVE HEIGHT CHANGE PASS", Depth, Calculations)
