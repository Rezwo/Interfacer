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

test("on · getter-function dep is called and tracked", function()
	local a = new(5)
	local calls = 0
	local c = new(Flux.On(function()
		return a:Get() * 2
	end, function(v : number)
		calls += 1
		return v
	end))
	expect(c:Get() == 10, "getter dep is invoked, not passed as a function")
	a:Set(6)
	expect(c:Get() == 12 and calls == 2, "getter's inner read is tracked; re-triggers")
end)

test("on · plain non-node array passed as single dep is array-shaped", function()
	local got : any
	local c = new(Flux.On({ 1, 2, 3 }, function(v : { number })
		got = v
		return #v
	end))
	expect(c:Get() == 3, "treated as array of three static deps")
	expect(got[1] == 1 and got[2] == 2 and got[3] == 3, "each element read via readDep")
end)

test("on · single Node dep threads prevInput across runs", function()
	local a = new(1)
	local seen = {}
	local c = new(Flux.On(a, function(v, prevV)
		seen[#seen + 1] = { v, prevV }
		return v * 10
	end))
	expect(c:Get() == 10, "first run uses current dep")
	expect(seen[1][1] == 1 and seen[1][2] == nil, "first prevInput is nil")
	a:Set(2)
	expect(c:Get() == 20, "re-runs on dep change")
	expect(seen[2][1] == 2 and seen[2][2] == 1, "prevInput is the prior dep value")
end)

test("on · defer skips the first run", function()
	local a = new(1)
	local runs = 0
	local c = new(Flux.On(a, function(v)
		runs += 1
		return v * 100
	end, true))
	expect(c:Get() == nil and runs == 0, "deferred: first eval does not call fn")
	a:Set(3)
	expect(c:Get() == 300 and runs == 1, "fires on the first dependency change")
end)

test("on · array dep only re-runs when a listed dep changes", function()
	local a = new(1)
	local b = new(2)
	local untracked = new(99)
	local runs = 0
	local c = new(Flux.On({ a, b }, function(inp)
		runs += 1
		return inp[1] + inp[2]
	end))
	expect(c:Get() == 3 and runs == 1, "sum of listed deps")
	untracked:Set(100)
	expect(c:Get() == 3 and runs == 1, "unlisted state does not re-trigger")
	b:Set(5)
	expect(c:Get() == 6 and runs == 2, "listed dep change re-triggers")
end)

test("new · rejects a non-string className", function()
	sert.fails(function()
		Flux.New(123 :: any)
	end, "String expected")
end)

test("clock · manual delay heap ordering, FIFO ties, and step", function()
	local Clock = Flux.Clock
	Clock.Manual(true)
	local t0 = Clock.Now()
	local w0 = Clock.Wall()
	expect(Clock.IsManual() == true, "manual clock active")

	local order = {}
	Clock.Delay(0.3, function(tag)
		table.insert(order, tag)
	end, "c")
	Clock.Delay(0.1, function(tag)
		table.insert(order, tag)
	end, "a1")
	Clock.Delay(0.1, function(tag)
		table.insert(order, tag)
	end, "a2")
	Clock.Delay(0.2, function(tag)
		table.insert(order, tag)
	end, "b")

	Clock.Step(0.15, 0.05)
	expect(table.concat(order, ",") == "a1,a2", "0.1s timers ran in FIFO tie-break order")

	Clock.Step(0.2, 0.05)
	expect(table.concat(order, ",") == "a1,a2,b,c", "remaining timers ran in deadline order")
	expect(sert.approx(Clock.Now() - t0, 0.35), "Clock.now advanced by 0.35s")
	expect(sert.approx(Clock.Wall() - w0, 0.35), "Clock.wall advanced in lockstep")
	Clock.Manual(false)
end)

test("clock · wait inside a coroutine, defer, drain, and cancel", function()
	local Clock = Flux.Clock
	Clock.Manual(true)

	local waited : number? = nil
	local co = coroutine.create(function()
		waited = Clock.Wait(0.25)
	end)
	assert(coroutine.resume(co))
	expect(waited == nil, "coroutine parked on Clock.wait")

	Clock.Step(0.25, 0.25)
	expect(
		waited ~= nil and sert.approx(waited :: number, 0.25),
		"Clock.wait resumed with elapsed time"
	)

	local ranDelay, ranDefer, ranWait = false, false, false
	local tDelay = Clock.Delay(0.1, function()
		ranDelay = true
	end)
	local tDefer = Clock.Defer(function()
		ranDefer = true
	end)
	local tWait = coroutine.create(function()
		Clock.Wait(0.1)
		ranWait = true
	end)
	assert(coroutine.resume(tWait))

	Clock.Cancel(tDelay)
	Clock.Cancel(tDefer)
	Clock.Cancel(tWait)
	Clock.Step(0.2, 0.1)
	expect(
		not ranDelay and not ranDefer and not ranWait,
		"cancelled delay, defer, and wait never ran"
	)

	local log = {}
	Clock.Defer(function(first)
		table.insert(log, first)
		Clock.Defer(function(second)
			table.insert(log, second)
		end, "inner")
	end, "outer")
	Clock.Drain()
	expect(table.concat(log, ",") == "outer,inner", "Clock.drain runs transitive deferred calls")
	Clock.Manual(false)
end)

test("clock · connect phases, disconnect, frame step integration, and reset", function()
	local Clock = Flux.Clock
	Clock.Manual(true)

	sert.fails(function()
		Clock.Connect("InvalidPhase" :: any, function() end)
	end, "unknown phase")

	local phases = {}
	local sig = Flux.State(0)
	local effSeen = -1
	local eff = Flux.Effect(function()
		effSeen = sig()
	end)
	local spr = Flux.Spring(0, 10, 1)
	spr:Set(100)

	local offRender = Clock.Connect("PreRender", function(_dt)
		table.insert(phases, "render")
	end)
	local offHeart = Clock.Connect("Heartbeat", function(_dt)
		table.insert(phases, `hb:{effSeen}`)
	end)

	sig:Set(7)
	Clock.Step(0.1, 0.1)
	expect(
		phases[1] == "render" and phases[2] == "hb:7",
		"PreRender -> Flux flush -> Heartbeat order"
	)
	expect(spr:Get() > 0, "Clock.step advanced active springs via frameHook")

	offRender()
	offHeart()
	table.clear(phases)
	Clock.Step(0.1, 0.1)
	expect(#phases == 0, "disconnected phase listeners no longer fire")

	local never = false
	Clock.Delay(0.1, function()
		never = true
	end)
	local beforeReset = Clock.Now()
	Clock.Reset()
	Clock.Step(0.2, 0.1)
	expect(
		not never and Clock.Now() >= beforeReset,
		"reset dropped pending timers and kept monotonic time"
	)

	eff:Destroy()
	spr:Destroy()
	Clock.Manual(false)
end)

rtest("heartbeat · effects auto-flush via the RunService hookup", function()
	local a = Flux(1)
	local seen = {}
	local e = Flux.Effect(function()
		table.insert(seen, a:Get())
	end)
	task.wait(0.1)
	expect(#seen >= 1 and seen[1] == 1, "creation run flushed by Heartbeat")
	a:Set(2)
	task.wait(0.1)
	expect(seen[#seen] == 2, "set flushed by Heartbeat")
	e:Destroy()
end)

test(
	"on · defer=true skips initial run and passes initial input as prevInput on first change",
	function()
		local src = new(10)
		local calls = 0
		local seenCur, seenPrev
		local c = new(Flux.On(src, function(cur, prev)
			calls += 1
			seenCur = cur
			seenPrev = prev
			return cur
		end, true))
		expect(
			c:Get() == nil and calls == 0,
			"defer=true returns nil on initial evaluation without running fn"
		)
		src:Set(25)
		expect(c:Get() == 25 and calls == 1, "first change runs fn")
		expect(
			seenCur == 25 and seenPrev == 10,
			"first change receives initial value 10 as prevInput"
		)
		c:Destroy()
	end
)

test("compat · headless stubs and arithmetic metamethods behave consistently", function()
	local Compatibility = if IS_ROBLOX
		then require(
			game:GetService("ReplicatedStorage"):WaitForChild("Flux"):WaitForChild("Compatibility")
		) :: any
		else require("../../src/Compatibility") :: any
	local OutputType = Compatibility.UDim
	local U2 = Compatibility.UDim2
	local V2 = Compatibility.Vector2
	local V3 = Compatibility.Vector3
	local C3 = Compatibility.Color3

	local uSum = OutputType.new(0.25, 10) + OutputType.new(0.5, 5)
	local uDiff = OutputType.new(0.75, 20) - OutputType.new(0.25, 8)
	expect(uSum == OutputType.new(0.75, 15), "UDim __add and __eq")
	expect(uDiff == OutputType.new(0.5, 12), "UDim __sub")

	local u2 = U2.fromScale(0.5, 0.25)
	expect(
		u2 == U2.new(0.5, 0, 0.25, 0) and U2.fromOffset(10, 20) == U2.new(0, 10, 0, 20),
		"UDim2 constructors"
	)

	local v2 = (V2.new(3, 4) + V2.new(1, 2) - V2.new(1, 2)) * 2 / 2
	expect(v2 == V2.new(3, 4) and -v2 == V2.new(-3, -4), "Vector2 arithmetic")
	expect(V2.zero:Lerp(V2.new(1, 1), 0.5) == V2.new(0.5, 0.5), "Vector2 Lerp")

	local v3 = (V3.new(1, 2, 2) + V3.new(1, 1, 1) - V3.new(1, 1, 1)) * 2 / 2
	expect(v3 == V3.new(1, 2, 2) and -v3 == V3.new(-1, -2, -2), "Vector3 arithmetic")
	expect(V3.zero:Lerp(V3.new(2, 4, 6), 0.5) == V3.new(1, 2, 3), "Vector3 Lerp")

	expect(C3.fromHex("#ff8000") == C3.fromRGB(255, 128, 0), "Color3.fromHex 6-digit")
	expect(C3.fromHex("f0f") == C3.fromRGB(255, 0, 255), "Color3.fromHex 3-digit")
	expect(C3.fromRGB(255, 128, 0):ToHex() == "ff8000", "Color3:ToHex")
	expect(
		C3.new(0, 0, 0):Lerp(C3.new(1, 0.5, 0.25), 0.5) == C3.new(0.5, 0.25, 0.125),
		"Color3:Lerp"
	)
end)

return {}
