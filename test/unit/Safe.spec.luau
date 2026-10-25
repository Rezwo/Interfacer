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
local expect = sert
local new = Flux

test("safe · returns tryFn result when it succeeds", function()
	local dep = new(2)
	local s = Flux.Safe(function()
		return dep:Get() * 10
	end, -1)
	expect(s:Get() == 20, "passes through success value")
end)

test("safe · returns plain fallback on throw", function()
	local s = Flux.Safe(function() : number
		error("boom")
	end, 99)
	expect(s:Get() == 99, "fallback value on error")
end)

test("safe · function fallback receives the error", function()
	local seen : any = nil
	local s = Flux.Safe(function() : string
		error("kaboom")
	end, function(err)
		seen = err
		return "recovered"
	end)
	expect(s:Get() == "recovered", "fallback fn result")
	expect(string.find(tostring(seen), "kaboom", 1, true) ~= nil, "fallback fn got the error")
end)

test("safe · self-heals: re-evaluates and recovers when a dep changes", function()
	local dep = new(0)
	local runs = 0
	local s = Flux.Safe(function() : number
		runs += 1
		local v = dep:Get()
		if v == 0 then
			error("not ready")
		end
		return v * 2
	end, -1)
	expect(s:Get() == -1 and runs == 1, "errors -> fallback, deps captured")
	dep:Set(5)
	expect(s:Get() == 10 and runs == 2, "recovers on dep change")
	dep:Set(0)
	expect(s:Get() == -1 and runs == 3, "errors again -> fallback again")
end)

test("safe · does not double-run tryFn per evaluation", function()
	local dep = new(1)
	local runs = 0
	local s = Flux.Safe(function()
		runs += 1
		return dep:Get()
	end, 0)
	s:Get()
	s:Get()
	expect(runs == 1, "single eval, cached read")
	dep:Set(2)
	s:Get()
	expect(runs == 2, "exactly one re-run per dep change")
end)

test("safe · nil fallback is valid and stays clean (no retry storm)", function()
	local runs = 0
	local s = Flux.Safe(function() : number?
		runs += 1
		error("always")
	end, nil)
	expect(s:Get() == nil and runs == 1, "nil fallback")
	s:Get()
	s:Get()
	expect(runs == 1, "no re-run without a dep change (does not park DIRTY)")
end)

test("safe · cleanup inside tryFn runs before each re-eval", function()
	local dep = new(1)
	local cleanups = 0
	local s = Flux.Safe(function()
		Flux.Cleanup(function()
			cleanups += 1
		end)
		return dep:Get()
	end, 0)
	expect(s:Get() == 1 and cleanups == 0, "first eval")
	dep:Set(2)
	expect(s:Get() == 2 and cleanups == 1, "cleanup ran before re-eval")
end)

test("safe · equals short-circuits propagation", function()
	local dep = new(1)
	local downstreamRuns = 0
	local s = Flux.Safe(
		function()
			return dep:Get() % 2
		end,
		-1,
		function(a, b)
			return a == b
		end
	)
	local d = new(function()
		downstreamRuns += 1
		return s:Get()
	end)
	expect(d:Get() == 1 and downstreamRuns == 1, "init")
	dep:Set(3)
	expect(d:Get() == 1 and downstreamRuns == 1, "equal value short-circuits")
	dep:Set(2)
	expect(d:Get() == 0 and downstreamRuns == 2, "changed value propagates")
end)

test("safe · structured (table) error reaches the recovery fn intact", function()
	local errObj = { code = 500, detail = "kaboom" }
	local seen : any = nil
	local s = Flux.Safe(function() : string
		error(errObj)
	end, function(err)
		seen = err
		return "recovered"
	end)
	expect(s:Get() == "recovered", "recovered value")
	expect(seen == errObj, "recovery fn got the exact table (identity preserved, not stringified)")
	expect(type(seen) == "table" and seen.code == 500, "table fields intact")
end)

test("scope · a safe node created in a scope is destroyed with it", function()
	local node
	local destroyed = false
	local s = Flux.Scope(function()
		node = Flux.Safe(function()
			return 1
		end, 0)
		node:OnDestroy(function()
			destroyed = true
		end)
	end)
	expect(node:Get() == 1, "safe works")
	s:Destroy()
	expect(destroyed, "scope destroyed the safe node (its onDestroy fired)")
end)

return {}
