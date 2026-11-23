--!strict
const Interfacer = require("../src")
const Depth = 24000
const Source = Interfacer.State(0)
local Tail : Interfacer.Node<number> = Source
local Middle : Interfacer.Node<number> = Source
local Calculations = 0
for Index = 1, Depth do
	local Previous = Tail
	Tail = Interfacer.Computed(function()
		Calculations += 1
		return Previous:Get() + 1
	end)
	assert(Tail:Get() == Index, "prime each dependency")
	if Index == Depth / 2 then
		Middle = Tail
	end
end
assert(Calculations == Depth, "prime each computation once")

const HookOrder : { string } = {}
Source:OnObserved(function()
	table.insert(HookOrder, "source attached")
end)
Source:OnUnobserved(function()
	table.insert(HookOrder, "source detached")
end)
Middle:OnObserved(function()
	table.insert(HookOrder, "middle attached")
end)
Middle:OnUnobserved(function()
	table.insert(HookOrder, "middle detached")
end)
Tail:OnObserved(function()
	table.insert(HookOrder, "tail attached")
end)
Tail:OnUnobserved(function()
	table.insert(HookOrder, "tail detached")
end)

local Observed : number? = nil
local Mirror : number? = nil
local Runs, MirrorRuns = 0, 0
print("START LIVE ATTACH", Depth)
const Owner = Interfacer.Scope(function()
	Interfacer.Effect(function()
		Observed = Tail:Get()
		Runs += 1
	end)
end)
Interfacer.Flush()
assert(Observed == Depth and Runs == 1, "first observer sees the primed value")
assert(Calculations == Depth, "attachment does not recalculate the primed chain")
assert(table.concat(HookOrder, ",") == "source attached,middle attached,tail attached", "attach hook order")

const OtherOwner = Interfacer.Scope(function()
	Interfacer.Effect(function()
		Mirror = Tail:Get()
		MirrorRuns += 1
	end)
end)
Interfacer.Flush()
assert(Mirror == Depth and MirrorRuns == 1 and #HookOrder == 3, "shared observer does not reattach")

print("START LIVE UPDATE")
Source:Set(1)
assert(Tail:Get() == Depth + 1, "live demand settles before an explicit flush")
Interfacer.Flush()
assert(Observed == Depth + 1 and Mirror == Depth + 1, "both observers settle")
assert(Runs == 2 and MirrorRuns == 2 and Calculations == Depth * 2, "one update per computation and observer")

Owner:Destroy()
assert(#HookOrder == 3, "removing one observer retains the shared chain")
Source:Set(2)
Interfacer.Flush()
assert(Runs == 2 and MirrorRuns == 3 and Mirror == Depth + 2, "only the remaining observer runs")
assert(Calculations == Depth * 3, "no extra work after partial removal")

print("START LIVE DETACH")
OtherOwner:Destroy()
assert(table.concat(HookOrder, ",") == "source attached,middle attached,tail attached,source detached,middle detached,tail detached", "detach hook order")
Source:Set(3)
Interfacer.Flush()
assert(Calculations == Depth * 3 and MirrorRuns == 3, "last observer releases the whole chain")
assert(Tail:Get() == Depth + 3 and Calculations == Depth * 4, "dormant demand still updates after detachment")
print("DEEP LIVE GRAPH PASS", Depth, Calculations)
