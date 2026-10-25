--!nonstrict
local IS_ROBLOX = game ~= nil

local Flux
local sert
if IS_ROBLOX then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	Flux = require(ReplicatedStorage:WaitForChild("Flux")) :: any
	sert = require(ReplicatedStorage:WaitForChild("sert")) :: any
else
	Flux = require("../../src") :: any
	sert = require("../sert") :: any
end

local test = sert.test
local rtest = sert.rtest
local expect = sert
local new = Flux
local flush = Flux.Flush
local Asynchronous = Flux.Asynchronous

test("async · source change re-triggers; the fetcher's own reads are untracked", function()

	local src = new(1)
	local other = new(10)
	local fetchRuns = 0
	local fetchThread
	local a = Asynchronous(src, function(v)
		fetchRuns += 1
		fetchThread = coroutine.running()
		coroutine.yield()
		return v + other:Get()
	end)
	flush()
	expect(fetchRuns == 1 and a.Loading:Get() == true, "fetch starts on flush")
	coroutine.resume(fetchThread)
	expect(a.Loading:Get() == false and a.Data:Get() == 11, "fetch resolves (1 + 10)")
	other:Set(20)
	flush()
	expect(fetchRuns == 1, "a read inside the fetcher is not a dependency")
	src:Set(2)
	flush()
	expect(fetchRuns == 2, "source change re-triggers the fetch")
	coroutine.resume(fetchThread)
	expect(a.Data:Get() == 22, "refetch resolves with the new source value (2 + 20)")
end)

test("async · fetcher erroring synchronously sets error; source change recovers", function()
	local gate = new(1)
	local fetchRuns = 0
	local a = Asynchronous(gate, function(g)
		fetchRuns += 1
		if g == 1 then
			error("sync fetch failure")
		end
		return g * 10
	end)
	flush()
	expect(
		fetchRuns == 1 and a.Error:Get() ~= nil and a.Loading:Get() == false and a.Data:Get() == nil,
		"error node set, loading false, data nil"
	)
	gate:Set(2)
	flush()
	expect(
		fetchRuns == 2 and a.Data:Get() == 20 and a.Error:Get() == nil and a.Loading:Get() == false,
		"source change re-triggers, recovers"
	)
end)

test("async · mutate sets data without fetching and drops in-flight fetch", function()
	local source = new(1)
	local fetchRuns = 0
	local fetchThread
	local a = Asynchronous(source, function(v)
		fetchRuns += 1
		fetchThread = coroutine.running()
		coroutine.yield()
		return v * 10
	end)
	flush()
	expect(fetchRuns == 1 and a.Loading:Get() == true, "initial fetch in flight")
	a:Mutate(999)
	expect(a.Data:Get() == 999, "mutate writes data immediately")
	expect(a.Loading:Get() == false, "mutate clears loading")
	expect(fetchRuns == 1, "mutate does not trigger a fetch")
	coroutine.resume(fetchThread)
	expect(a.Data:Get() == 999, "stale in-flight fetch is dropped, mutate value kept")
end)

test("async · refetch re-runs with the current source value, no source write", function()
	local source = new(5)
	local fetchRuns = 0
	local seen = {}
	local a = Asynchronous(source, function(v)
		fetchRuns += 1
		seen[fetchRuns] = v
		return v * 2
	end)
	flush()
	expect(fetchRuns == 1 and a.Data:Get() == 10, "initial fetch")
	a:Refetch()
	expect(fetchRuns == 2 and seen[2] == 5, "refetch re-runs with current source value")
	expect(a.Data:Get() == 10 and a.Loading:Get() == false, "synchronous refetch resolves")
end)

test("async · refetch picks up a source set without an intervening flush", function()
	local source = new(1)
	local seen = {}
	local fetchRuns = 0
	local a = Asynchronous(source, function(v)
		fetchRuns += 1
		seen[fetchRuns] = v
		return v
	end)
	flush()
	source:Set(7)
	a:Refetch()
	expect(seen[fetchRuns] == 7, "refetch reads the live source value")
end)

test("async · refetch with a function source re-evaluates the selector", function()
	local base = new(3)
	local fetchRuns = 0
	local seen = {}
	local a = Asynchronous(function()
		return base:Get() * 2
	end, function(v)
		fetchRuns += 1
		seen[fetchRuns] = v
		return v
	end)
	flush()
	base:Set(10)
	a:Refetch()
	expect(seen[fetchRuns] == 20, "function source is re-evaluated on refetch")
end)

test("async · refetch/mutate after Destroy are safe no-ops", function()
	local fetches = 0
	local source = new(1)
	local a = Asynchronous(source, function(v)
		fetches += 1
		return v
	end)
	flush()
	expect(fetches == 1, "initial fetch ran once")
	a:Destroy()
	expect((pcall(function()
		a:Refetch()
	end)) == true, "refetch after destroy does not error")
	expect((pcall(function()
		a:Mutate(5)
	end)) == true, "mutate after destroy does not error")
	flush()

	expect(fetches == 1, "no fetch ran after Destroy")
end)

test("async · Destroy while a fetch is in flight is a safe no-op (no crash)", function()

	local resumeThread
	local a = Asynchronous(function()
		resumeThread = coroutine.running()
		coroutine.yield()
		return 7
	end, nil)
	flush()
	a:Destroy()
	local ok = coroutine.resume(resumeThread)
	expect(ok == true, "in-flight fetcher resolving after Destroy does not error")
end)

test("async · refetch does not become a dependency of an enclosing effect", function()
	local source = new(1)
	local a = Asynchronous(source, function(v)
		return v
	end)
	flush()
	local outerRuns = 0
	local e = Flux.Effect(function()
		outerRuns += 1
		a:Refetch()
	end)
	flush()
	expect(outerRuns == 1, "enclosing effect ran once")
	source:Set(2)
	flush()

	expect(outerRuns == 1, "refetch's untracked read did not subscribe the outer effect")
	e:Destroy()
end)

test("async · latest in-flight wins; stale resolution discarded (headless)", function()

	local src = new(1)
	local threads = {}
	local fetchRuns = 0
	local a = Asynchronous(src, function(v)
		fetchRuns += 1
		threads[v] = coroutine.running()
		coroutine.yield()
		return v * 100
	end)

	flush()
	expect(fetchRuns == 1 and threads[1] ~= nil, "first fetch (v=1) is in flight and parked")
	expect(a.Loading:Get() == true, "loading is true during the pending window")
	expect(a.Data:Get() == nil, "no data resolved yet")

	src:Set(2)
	flush()
	expect(fetchRuns == 2 and threads[2] ~= nil, "second fetch (v=2) is now also in flight")
	expect(a.Loading:Get() == true, "still loading with the newer fetch pending")

	coroutine.resume(threads[2])
	expect(a.Data:Get() == 200, "newer fetch (v=2) resolves and wins")
	expect(a.Loading:Get() == false, "loading clears once the latest fetch resolves")

	coroutine.resume(threads[1])
	expect(a.Data:Get() == 200, "stale older fetch (v=1) does NOT clobber the newer result")
	expect(a.Loading:Get() == false, "stale resolution does not re-toggle loading")
	expect(a.Error:Get() == nil, "stale resolution leaves error untouched")
end)

test("async · loading false→true→false across the pending window (headless)", function()
	local fetchThread
	local a = Asynchronous(function()
		fetchThread = coroutine.running()
		coroutine.yield()
		return 42
	end, 0)

	expect(a.Data:Get() == 0, "starts with the initial value before any flush")
	expect(a.Loading:Get() == false, "loading is false before the effect flushes")

	flush()
	expect(a.Loading:Get() == true, "loading flips true once the fetch is in flight")
	expect(a.Data:Get() == 0, "data still the initial value while pending")

	coroutine.resume(fetchThread)
	expect(a.Loading:Get() == false, "loading flips back false after resolution")
	expect(a.Data:Get() == 42, "data holds the resolved value")
	expect(a.Error:Get() == nil, "no error on success")
end)

test("async · a prior error is cleared when the fetch re-triggers (headless)", function()

	local gate = new(1)
	local a = Asynchronous(gate, function(g)
		if g == 1 then
			error("first boom")
		end
		return g * 10
	end)

	flush()
	expect(a.Error:Get() ~= nil, "first run's synchronous error is captured")
	expect(
		string.find(tostring(a.Error:Get()), "first boom", 1, true) ~= nil,
		"error message captured"
	)
	expect(a.Loading:Get() == false and a.Data:Get() == nil, "loading cleared, no data on failure")

	gate:Set(2)
	flush()
	expect(a.Error:Get() == nil, "prior error is cleared on re-trigger")
	expect(a.Data:Get() == 20, "successful re-run resolves")
	expect(a.Loading:Get() == false, "loading cleared after the successful re-run")
end)

test(
	"async · state: unresolved → pending → ready → refreshing → ready (headless)",
	function()

		local fetchThread
		local a = Asynchronous(function()
			fetchThread = coroutine.running()
			coroutine.yield()
			return 42
		end, 0)
		expect(a.Data:Get() == 0, "data starts at the initial value")
		expect(
			a.State:Get() == "Unresolved",
			"unresolved before the first flush, despite an initial value"
		)
		flush()
		expect(
			a.State:Get() == "Pending",
			"pending while the first fetch is in flight (no resolved value yet)"
		)
		coroutine.resume(fetchThread)
		expect(a.State:Get() == "Ready" and a.Data:Get() == 42, "ready once the fetch resolves")
		a:Refetch()
		expect(
			a.State:Get() == "Refreshing",
			"refreshing while a refetch runs over an already-resolved value"
		)
		coroutine.resume(fetchThread)
		expect(a.State:Get() == "Ready", "back to ready after the refetch resolves")
	end
)

test("async · state is ready when a fetch resolves to nil", function()

	local a = Asynchronous(function()
		return nil
	end, "init")
	flush()
	expect(a.State:Get() == "Ready", "a nil resolution still counts as resolved")
	expect(a.Data:Get() == nil, "data holds the nil result")
end)

test("async · retry after a never-resolved error is pending, not refreshing (headless)", function()

	local fetchThread, first = nil, true
	local a = Asynchronous(function()
		fetchThread = coroutine.running()
		coroutine.yield()
		if first then
			first = false
			error("boom")
		end
		return 7
	end, nil)
	flush()
	expect(a.State:Get() == "Pending", "first fetch is pending")
	coroutine.resume(fetchThread)
	expect(a.State:Get() == "Errored", "errored after the failure")
	a:Refetch()
	expect(a.State:Get() == "Pending", "retry is pending since nothing ever resolved")
	coroutine.resume(fetchThread)
	expect(a.State:Get() == "Ready" and a.Data:Get() == 7, "ready after the successful retry")
end)

test("async · a falsy source gates the fetch until it turns truthy", function()

	local gate = new(nil :: any)
	local runs = 0
	local a = Asynchronous(gate, function(g)
		runs += 1
		return g * 100
	end, "init")
	flush()
	expect(runs == 0, "fetcher not called while the source is nil")
	expect(
		a.State:Get() == "Unresolved" and a.Loading:Get() == false,
		"unresolved and not loading while gated"
	)
	gate:Set(3)
	flush()
	expect(runs == 1 and a.Data:Get() == 300, "fetches once the source turns truthy")
	expect(a.State:Get() == "Ready", "ready after the gated fetch resolves")
	gate:Set(false)
	flush()
	expect(runs == 1, "a falsy source again does not refetch")
	expect(a.State:Get() == "Ready", "the latest value is retained while re-gated")
end)

test("async · mutate marks the resource ready and drops the in-flight fetch (headless)", function()

	local fetchThread
	local a = Asynchronous(function()
		fetchThread = coroutine.running()
		coroutine.yield()
		return 1
	end, nil)
	flush()
	expect(a.State:Get() == "Pending", "pending before any value resolves")
	a:Mutate(99)
	expect(a.State:Get() == "Ready" and a.Data:Get() == 99, "mutate resolves the resource to ready")
	coroutine.resume(fetchThread)
	expect(
		a.State:Get() == "Ready" and a.Data:Get() == 99,
		"the dropped fetch leaves the mutated value"
	)
end)

test(
	"async · fetcher receives the previous value and the refetching payload (headless)",
	function()
		local seen, fetchThread = {}, nil
		local a = Asynchronous(function(_input, previous, refetching)
			seen[#seen + 1] = { value = previous, refetching = refetching }
			fetchThread = coroutine.running()
			coroutine.yield()
			return (previous or 0) + 1
		end, 10)
		flush()
		coroutine.resume(fetchThread)
		expect(a.Data:Get() == 11, "first run sees previous == initial value (10 + 1)")
		expect(seen[1].refetching == false, "a source/initial run reports refetching = false")
		a:Refetch("manual")
		coroutine.resume(fetchThread)
		expect(a.Data:Get() == 12, "refetch sees the previous resolved value (11 + 1)")
		expect(
			seen[2].refetching == "manual",
			"the refetch payload is forwarded as the refetching arg"
		)
	end
)

local function waitSettled(res : any, minWait : number)
	task.wait(minWait)
	local deadline = os.clock() + 1
	while res.Loading() and os.clock() < deadline do
		task.wait()
	end
end

rtest("async · loading lifecycle with real yields", function()
	local res = Flux.Asynchronous(function()
		task.wait(0.03)
		return 42
	end, 0)
	expect(res.Data() == 0, "starts with the initial value")
	expect(res.Loading() == false, "not loading before the effect flushes")
	flush()
	expect(res.Loading() == true, "loading becomes true once the fetch starts")
	waitSettled(res, 0.08)
	expect(res.Loading() == false, "loading clears after resolution")
	expect(res.Data() == 42, "data holds the resolved value")
	expect(res.Error() == nil, "no error on success")
	res:Destroy()
end)

rtest("async · captures errors across yields", function()
	local res = Flux.Asynchronous(function()
		task.wait(0.02)
		error("boom")
	end)
	flush()
	waitSettled(res, 0.06)
	expect(res.Loading() == false, "loading cleared after failure")
	expect(res.Data() == nil, "data stays nil on failure")
	expect(res.Error() ~= nil, "error node populated")
	expect(string.find(tostring(res.Error()), "boom", 1, true) ~= nil, "error message captured")
	res:Destroy()
end)

rtest("async · latest request wins (race handling)", function()
	local input = Flux(1)
	local res = Flux.Asynchronous(input, function(v)
		task.wait(if v == 1 then 0.08 else 0.03)
		return v
	end)
	flush()
	task.wait(0.02)
	input(2)
	flush()
	waitSettled(res, 0.12)
	expect(res.Data() == 2, `the newer result should win, got {tostring(res.Data())}`)
	res:Destroy()
end)

rtest("async · refetch with a real yielding fetcher resolves fresh", function()
	local source = Flux(1)
	local a = Flux.Asynchronous(source, function(v)
		task.wait(0.02)
		return v * 100
	end)
	flush()
	waitSettled(a, 0.05)
	expect(a.Data() == 100, "initial fetch resolved")
	source(4)
	a:Refetch()
	waitSettled(a, 0.05)
	expect(a.Data() == 400, "refetch resolved with the live source value")
	a:Destroy()
end)

test("gate · gating the source off drops an in-flight fetch", function()
	local gate = new(1)
	local fetchThread
	local a = Asynchronous(gate, function(v)
		fetchThread = coroutine.running()
		coroutine.yield()
		return v * 100
	end, "init")
	flush()
	expect(a.Loading() == true, "loading while the fetch is in flight")

	gate(false)
	flush()
	coroutine.resume(fetchThread)

	expect(a.Data() == "init", "the stale in-flight result is discarded")
	expect(a.State() == "Unresolved", "the gated-off node reads as unresolved")
	a:Destroy()
end)

test("gate · gating off after an error clears the error", function()
	local gate = new(1)
	local a = Asynchronous(gate, function()
		error("boom")
	end, "x")
	flush()
	expect(a.State() == "Errored", "errored after the fetcher throws")

	gate(false)
	flush()
	expect(a.Error() == nil, "error cleared when gated off")
	expect(a.State() == "Unresolved", "gated-off node reads as unresolved, not errored")
	a:Destroy()
end)

test("refetch · honors the source gate", function()
	local gate = new(false)
	local runs = 0
	local a = Asynchronous(gate, function(v)
		runs += 1
		return v
	end, "init")
	flush()
	expect(runs == 0, "the fetcher does not run while gated")
	a:Refetch()
	expect(runs == 0, "refetch does not bypass the gate")
	a:Destroy()
end)

test(
	"scope · async created in a scope is destroyed with it and double Destroy is a no-op",
	function()
		local res
		local scope = Flux.Scope(function()
			res = Asynchronous(function()
				return 7
			end, 0)
		end)
		flush()
		expect(res.Data() == 7 and res.State() == "Ready", "resolved inside scope")
		scope:Destroy()
		expect(res.Data == nil and res.State == nil, "scope teardown destroyed the async resource")
		res:Destroy()
		res:Mutate(99)
		res:Refetch()
		expect(res.Data == nil, "double Destroy and post-Destroy mutate/refetch are safe no-ops")
	end
)

return {}
