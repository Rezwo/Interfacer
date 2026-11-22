--!strict
const Interfacer = require("../src")
const Depth = 24000
const Source = Interfacer.State(0)
local Calculations = 0
local Tail : Interfacer.Node<number> = Source
for Index = 1, Depth do
	local Previous = Tail
	Tail = Interfacer.Computed(function()
		Calculations += 1
		return Previous:Get() + 1
	end)
	assert(Tail:Get() == Index, "prime known dependency")
end
assert(Calculations == Depth, "priming computes each link exactly once")
Source:Set(20)
Interfacer.Flush()
assert(Tail:Get() == Depth + 20, "dormant demand observes change")
assert(Calculations == Depth * 2, "one calculation per changed link")
assert(Tail:Get() == Depth + 20 and Calculations == Depth * 2, "warm read is cached")
print("DEEP DORMANT PASS", Depth, Calculations)

const AccumulatorSource = Interfacer.State(2)
const Accumulator = Interfacer.Computed(function(PreviousValue : number?) : number
	return (PreviousValue or 0) + AccumulatorSource:Get()
end)
assert(Accumulator:Get() == 2, "first computation has no previous value")
AccumulatorSource:Set(3)
assert(Accumulator:Get() == 5 and Accumulator:Get() == 5, "previous value and warm caching")
Accumulator:Destroy()
AccumulatorSource:Destroy()

const Failure = { Reason = "not ready" }
const Untracked = Interfacer.State(0)
local Ready = false
local Attempts = 0
local Reset : (() -> ())? = nil
local Guarded : Interfacer.Node<number>
const Owner = Interfacer.Scope(function()
	Guarded = Interfacer.Safe(function() : number
		Attempts += 1
		if not Ready then
			error(Failure)
		end
		return 42
	end, function(Problem : unknown, Retry : () -> ()) : number
		assert(Problem == Failure, "structured error identity")
		Reset = Retry
		return Untracked:Get()
	end)
end)
assert(Guarded:Get() == 0 and Attempts == 1, "safe evaluation is cached")
Untracked:Set(5)
assert(Guarded:Get() == 0 and Attempts == 1, "fallback reads do not subscribe")
const Retry = assert(Reset, "fallback received a reset function")
Retry()
Retry()
assert(Guarded:Get() == 5 and Attempts == 2, "reset retries once on demand")
Ready = true
Retry()
assert(Guarded:Get() == 42 and Attempts == 3, "manual retry recovers")
Retry()
assert(Guarded:Get() == 42 and Attempts == 3, "the healed node drops its retry dependency")
Owner:Destroy()
Retry()
Interfacer.Flush()
assert(Attempts == 3, "saved reset has no authority after disposal")
Untracked:Destroy()
print("COMPUTED PREVIOUS AND SAFE RESET PASS")

const Branch = Interfacer.State(true)
const Left = Interfacer.State(1)
const Right = Interfacer.State(1)
local Reads = 0
const Switched = Interfacer.Computed(function()
	Reads += 1
	return if Branch:Get() then Left:Get() else Right:Get()
end)
assert(Switched:Get() == 1 and Reads == 1, "first branch tracked")
Branch:Set(false)
assert(Switched:Get() == 1 and Reads == 2, "equal result still switches dependencies")
Left:Set(2)
assert(Switched:Get() == 1 and Reads == 2, "old branch stops invalidating")
Right:Set(2)
assert(Switched:Get() == 2 and Reads == 3, "new branch invalidates")
Right:Update()
assert(Switched:Get() == 2 and Reads == 4, "existing State Update forces invalidation")

local OwnedRuns = 0
const DisposalTrigger = Interfacer.State(false)
local DisposeOwner : (() -> ())? = nil
const DisposalOwner = Interfacer.Scope(function()
	Interfacer.Effect(function()
		local Dispose = DisposeOwner
		if DisposalTrigger:Get() and Dispose ~= nil then
			Dispose()
		end
	end)
	Interfacer.Effect(function()
		DisposalTrigger:Get()
		OwnedRuns += 1
	end)
end)
DisposeOwner = function()
	DisposalOwner:Destroy()
end
Interfacer.Flush()
assert(OwnedRuns == 1, "owned effect ran once at initialization")
DisposalTrigger:Set(true)
Interfacer.Flush()
const RunsAfterDisposal = OwnedRuns
DisposalTrigger:Set(false)
Interfacer.Flush()
assert(OwnedRuns == RunsAfterDisposal, "disposal during settlement revokes subsequent work")
print("DYNAMIC DEPENDENCIES AND DISPOSAL PASS")
