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
local For = { value = Flux.ForValue, index = Flux.ForIndex }

test("for · mapFn reads are untracked; item nodes update", function()
	local noise = new(0)
	local list = new({ "a", "b" })
	local mapRuns = 0
	local mapped = For.value(list, function(indexNode, value)
		mapRuns += 1
		noise:Get()
		return value .. tostring(indexNode:Get())
	end)
	local out = mapped:Get()
	expect(out[1] == "a1" and out[2] == "b2" and mapRuns == 2, "initial map")
	noise:Set(1)
	expect(mapped:Get() == out and mapRuns == 2, "mapFn untracked")
	list:Set({ "b", "a" })
	local out2 = mapped:Get()

	expect(mapRuns == 2 and out2[1] == "b2" and out2[2] == "a1", "keyed reuse")
end)

test("forValue · updates in place, caches by value", function()
	local a, b = { id = "a" }, { id = "b" }
	local list = Flux({ a, b })
	local calls = 0
	local mapped = Flux.ForValue(list, function(indexNode, value)
		calls += 1
		expect(Flux.IsNode(indexNode), "forValue first arg is a reactive index")
		return { value = value, indexNode = indexNode }
	end)
	local r1 = mapped()
	expect(calls == 2, "mapped once per value")
	expect(r1[1].value == a and r1[2].value == b, "values mapped to positions")
	expect(r1[1].indexNode() == 1 and r1[2].indexNode() == 2, "index nodes track position")

	list({ b, a })
	local r2 = mapped()
	expect(calls == 2, "reorder reuses cached results (no remap)")
	expect(r2[1].value == b and r2[2].value == a, "result follows new order")
	expect(r1[1].indexNode() == 2, "value a's index node moved to 2")
	expect(r2[2] == r1[1], "same cached object follows the value across positions")
end)

test("forIndex · updates in place, caches by position", function()
	local list = Flux({ 10, 20, 30 })
	local calls = 0
	local mapped = Flux.ForIndex(list, function(index, itemNode)
		calls += 1
		expect(Flux.IsNode(itemNode), "forIndex second arg is a reactive node")
		return {
			read = function()
				return itemNode()
			end,
		}
	end)
	local r1 = mapped()
	expect(calls == 3, "one map call per slot")
	expect(r1[1].read() == 10 and r1[2].read() == 20 and r1[3].read() == 30, "initial values")

	list({ 10, 99, 30 })
	local r2 = mapped()
	expect(calls == 3, "value change does not remap")
	expect(r2[2].read() == 99, "underlying item node updated")
	expect(r2[1] == r1[1], "unchanged slot's cached result reused")

	list({ 10 })
	local r3 = mapped()
	expect(calls == 3, "shrinking does not remap")
	expect(r3[1].read() == 10 and r3[2] == nil and r3[3] == nil, "removed slots cleared")
end)

test("forValue · duplicates share one mapped instance (expected warn)", function()
	local list = new({ "x", "x", "y" })
	local mapRuns = 0
	local mapped = For.value(list, function(indexNode, value)
		mapRuns += 1
		return { value = value }
	end)
	local out = mapped:Get()
	expect(out[1] == out[2] and out[1] ~= out[3], "shared mapped instance")
	expect(mapRuns == 2, "mapper runs once per unique value")
end)

test("forIndex · node and function elements stay opaque", function()

	local userNode = new(5)
	local items = {}
	local list = new({ userNode })
	local mapped = For.index(list, function(index, item)
		table.insert(items, item)
		return item
	end)
	mapped:Get()
	expect(items[1] ~= userNode and items[1]:Get() == userNode, "item node boxes the user node")
	list:Set({ 42 })
	mapped:Get()
	expect(userNode:Get() == 5, "reassignment leaves the user node intact")
	list:Set({})
	mapped:Get()
	expect(getmetatable(userNode) ~= nil, "eviction doesn't destroy the user node")
	mapped:Destroy()
	expect(getmetatable(userNode) ~= nil, "mapper destroy doesn't destroy the user node")

	local fnCalls = 0
	local fnEl = function()
		fnCalls += 1
	end
	local list2 = new({ fnEl })
	local mapped2 = For.index(list2, function(index, item)
		return item:Get()
	end)
	expect(mapped2:Get()[1] == fnEl and fnCalls == 0, "fn element returned raw, never executed")
end)

test("forValue · removed value's mapped result is cleaned and item node destroyed once", function()

	local cleaned = {}
	local nodeDestroyed = {}
	local list = new({ "a", "b", "c" })
	local mapped = For.value(list, function(indexNode, value)

		indexNode:OnDestroy(function()
			nodeDestroyed[value] = (nodeDestroyed[value] or 0) + 1
		end)

		return function()
			cleaned[value] = (cleaned[value] or 0) + 1
		end
	end)
	mapped:Get()
	expect(next(cleaned) == nil and next(nodeDestroyed) == nil, "nothing cleaned while all present")

	list:Set({ "a", "c" })
	mapped:Get()
	expect(cleaned.b == 1, "removed value's mapped result Cleaned exactly once")
	expect(nodeDestroyed.b == 1, "removed value's index node Destroyed exactly once")
	expect(cleaned.a == nil and cleaned.c == nil, "surviving values' results NOT cleaned")
	expect(
		nodeDestroyed.a == nil and nodeDestroyed.c == nil,
		"surviving values' nodes NOT destroyed"
	)
end)

test("for · eviction-scan reads stay untracked (no leaked mapper dependency)", function()

	local dep = new(0)
	local list = new({ "a", "b" })
	local mapped = For.value(list, function(indexNode, value)
		return function()
			dep:Get()
		end
	end)
	mapped:Get()
	list:Set({ "a" })
	mapped:Get()

	local inner = mapped[1]
	local hasDep, hasList = false, false
	for i = 11, inner[8] - 2, 2 do
		if inner[i] == dep[1] then
			hasDep = true
		elseif inner[i] == list[1] then
			hasList = true
		end
	end
	expect(not hasDep, "cleanup read did not leak into deps")
	expect(hasList, "list remains the mapper's only dependency")
end)

test("for · cleanup inside mapFn scopes to the row (Solid <For> per-row root)", function()

	local cleaned = {}
	local list = new({ "a", "b" })
	local mapped = For.value(list, function(indexNode, value)
		Flux.Cleanup(function()
			cleaned[value] = (cleaned[value] or 0) + 1
		end)
		return value
	end)
	mapped:Get()
	list:Set({ "b", "a" })
	mapped:Get()
	expect(next(cleaned) == nil, "no row cleanup on a reconcile that evicts nothing")
	list:Set({ "b" })
	mapped:Get()
	expect(
		cleaned.a == 1 and cleaned.b == nil,
		"only the evicted row's cleanup fired, exactly once"
	)
end)

test("forIndex · shrinking cleans the removed slot's result and item node once", function()

	local cleaned = {}
	local nodeDestroyed = {}
	local list = new({ 10, 20, 30 })
	local mapped = For.index(list, function(index, itemNode)

		itemNode:OnDestroy(function()
			nodeDestroyed[index] = (nodeDestroyed[index] or 0) + 1
		end)
		return function()
			cleaned[index] = (cleaned[index] or 0) + 1
		end
	end)
	mapped:Get()
	expect(next(cleaned) == nil and next(nodeDestroyed) == nil, "nothing cleaned while all present")

	list:Set({ 10 })
	mapped:Get()
	expect(cleaned[2] == 1 and cleaned[3] == 1, "dropped slots' results Cleaned exactly once")
	expect(
		nodeDestroyed[2] == 1 and nodeDestroyed[3] == 1,
		"dropped slots' item nodes Destroyed exactly once"
	)
	expect(cleaned[1] == nil, "surviving slot's result NOT cleaned")
	expect(nodeDestroyed[1] == nil, "surviving slot's item node NOT destroyed")
end)

test("forIndex · reorder keeps results BY POSITION, mutating item nodes (unkeyed)", function()

	local list = new({ "a", "b", "c" })
	local calls = 0
	local mapped = For.index(list, function(index, itemNode)
		calls += 1
		return { slot = index, item = itemNode }
	end)
	local r1 = mapped:Get()
	expect(calls == 3, "one map call per slot")
	expect(
		r1[1].item:Get() == "a" and r1[2].item:Get() == "b" and r1[3].item:Get() == "c",
		"initial values per slot"
	)

	list:Set({ "c", "b", "a" })
	local r2 = mapped:Get()
	expect(calls == 3, "reorder does NOT remap (no new map calls)")

	expect(r2[1] == r1[1] and r2[2] == r1[2] and r2[3] == r1[3], "cached results stay by position")
	expect(r2[1].slot == 1 and r2[3].slot == 3, "the per-slot result identity is positional")

	expect(r2[1].item:Get() == "c", "position 1's item node now holds the new element")
	expect(r2[2].item:Get() == "b", "position 2 unchanged element")
	expect(r2[3].item:Get() == "a", "position 3's item node now holds the new element")
end)

test("for · non-table source returns empty array and Destroy tears down cached rows", function()
	local src = new(nil :: any)
	local cleaned = 0
	local nodeDestroyed = 0
	local mapped = For.value(src, function(indexNode, value)
		indexNode:OnDestroy(function()
			nodeDestroyed += 1
		end)
		return function()
			cleaned += 1
		end
	end)
	expect(#mapped:Get() == 0, "non-table source maps to empty table")
	src:Set({ "row1", "row2" })
	expect(#mapped:Get() == 2, "populates once source becomes a table")
	mapped:Destroy()
	expect(
		nodeDestroyed == 2 and cleaned == 2,
		"mapper Destroy tears down all row nodes and disposes cached results"
	)
end)

test("for · recovers cleanly after mapFn throws without retaining scratch state", function()
	local shouldThrow = true
	local src = new({ "ok", "bad" })
	local mapped = For.value(src, function(_index, val)
		if shouldThrow and val == "bad" then
			error("row boom")
		end
		return string.upper(val)
	end)
	sert.fails(function()
		mapped:Get()
	end, "row boom")

	shouldThrow = false
	src:Set({ "ok", "fixed" })
	local res = mapped:Get()
	expect(
		#res == 2 and res[1] == "OK" and res[2] == "FIXED",
		"subsequent evaluation succeeds cleanly"
	)
	mapped:Destroy()
end)

return {}
