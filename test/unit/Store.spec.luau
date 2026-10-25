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
local flush = Flux.Flush
local Store = Flux.Store

test("store · deep reactivity per key", function()
	local state = Flux.CreateStore({
		player = { health = 100, name = "Guest" },
		settings = { volume = 0.5 },
	})
	local healthRuns, volumeRuns = 0, 0
	Flux.Effect(function()
		healthRuns += 1
		local _ = state.player.health
	end)
	Flux.Effect(function()
		volumeRuns += 1
		local _ = state.settings.volume
	end)
	flush()
	expect(healthRuns == 1 and volumeRuns == 1, "both effects run once initially")
	state.player.health = 90
	flush()
	expect(state.player.health == 90, "deep write persisted")
	expect(healthRuns == 2, "health observer re-ran")
	expect(volumeRuns == 1, "unrelated branch observer did NOT re-run")
end)

test("store · structural (length) tracking", function()
	local s = Flux.CreateStore({ items = { "a", "b" } })
	local lenRuns, lastLen = 0, 0
	Flux.Effect(function()
		lenRuns += 1
		lastLen = #s.items
	end)
	flush()
	expect(lenRuns == 1 and lastLen == 2, "tracks length initially")
	s.items[#s.items + 1] = "c"
	flush()
	expect(lenRuns == 2 and lastLen == 3, "length observer re-runs on structural change")
end)

test("store · iteration yields proxies; writes through them track", function()
	local store = Flux.CreateStore({ list = { { n = 1 }, { n = 2 } } })
	local total = new(function()
		local sum = 0
		for _, item in store.list do
			sum += item.n
		end
		return sum
	end)
	expect(total:Get() == 3, "store iter sum")
	local firstProxy
	for _, item in store.list do
		firstProxy = item
		break
	end
	firstProxy.n = 10
	expect(total:Get() == 12, "store iter write tracked")
end)

test("store · unwrap returns the raw table", function()
	local s = Flux.CreateStore({ a = 1, nested = { b = 2 } })
	local raw = Store.Unwrap(s)
	expect(type(raw) == "table", "unwrap returns a table")
	expect(getmetatable(raw) == nil, "raw table has no proxy metatable")
	expect(raw.a == 1, "values are intact")
	expect(getmetatable(raw.nested) == nil, "nested raw table is also un-proxied")
end)

test("store · metatable'd values stay unwrapped; plain tables proxy", function()
	local innerNode = new(7)
	local Class = {}
	Class.__index = Class
	function Class.getValue(self)
		return self.v
	end
	local instObj = setmetatable({ v = 3 }, Class)
	local s = Flux.CreateStore({ node = innerNode, obj = instObj, plain = { count = 1 } })
	local sawNode, sawObj, plainProxy = false, false, nil
	local total = new(function()
		local sum = 0
		for key, value in s do
			if key == "node" then
				sawNode = Flux.IsNode(value)
				sum += value:Get()
			elseif key == "obj" then
				sawObj = getmetatable(value) == Class
				sum += value:getValue()
			else
				plainProxy = value
				sum += value.count
			end
		end
		return sum
	end)
	expect(total:Get() == 11 and sawNode and sawObj, "iteration yields callable values")
	expect(s.node == innerNode and s.obj == instObj, "__index leaves metatable'd values raw")
	plainProxy.count = 5
	expect(total:Get() == 15, "plain tables stay tracked")
	innerNode:Set(9)
	expect(total:Get() == 17, "node reads stay tracked")
end)

test("store · node-valued keys never alias user nodes", function()
	local userNode = new(7)
	local s = Flux.CreateStore({ slot = userNode })
	local reader = new(function()
		local n = s.slot
		return if Flux.IsNode(n) then n:Get() else n
	end)
	expect(reader:Get() == 7, "baseline read")
	s.slot = 99
	expect(userNode:Get() == 7 and Flux.IsNode(userNode), "replaced key leaves user node untouched")
	expect(reader:Get() == 99, "reader sees the replacement")
	Store.Destroy(s)
	expect(
		getmetatable(userNode) ~= nil and userNode:Get() == 7,
		"store teardown spares the user node"
	)

	local nodeA, nodeB = new(1), new(2)
	local s2 = Flux.CreateStore({ nodeA, nodeB })
	local first = new(function()
		local n = s2[1]
		return if Flux.IsNode(n) then n:Get() else n
	end)
	local second = new(function()
		local n = s2[2]
		return if Flux.IsNode(n) then n:Get() else n
	end)
	expect(first:Get() == 1 and second:Get() == 2, "node array baseline")
	expect(Store.Remove(s2, 1) == nodeA, "remove returns the user node")
	expect(
		nodeA:Get() == 1 and nodeB:Get() == 2 and getmetatable(nodeA) ~= nil,
		"user nodes uncorrupted"
	)
	expect(first:Get() == 2 and second:Get() == nil, "readers shift")
end)

test("store · function values stay opaque leaves through every set path", function()

	local calls = 0
	local fnA = function()
		calls += 1
		return "A"
	end
	local fnB = function()
		calls += 1
		return "B"
	end

	local s = Flux.CreateStore({ cb = fnA })
	local reader = new(function()
		return s.cb
	end)
	expect(reader:Get() == fnA, "baseline read")
	s.cb = fnB
	expect(reader:Get() == fnB, "newindex returns the new fn")

	local arr = Flux.CreateStore({ fnA, fnB })
	local first = new(function()
		return arr[1]
	end)
	expect(first:Get() == fnA, "array baseline")
	Store.Remove(arr, 1)
	expect(first:Get() == fnB, "remove shift returns the fn raw")
	Store.Insert(arr, 1, fnA)
	expect(first:Get() == fnA, "insert shift returns the fn raw")
	expect(calls == 0, "stored fns never executed")
end)

test("store.remove · shifted readers, trackers, pos validation", function()
	local s = Flux.CreateStore({ 10, 20, 30, 40 })
	local r2 = new(function()
		return s[2]
	end)
	local r4 = new(function()
		return s[4]
	end)
	local len = new(function()
		return #s
	end)
	local total = new(function()
		local sum = 0
		for _, v in s do
			sum += v
		end
		return sum
	end)
	expect(r2:Get() == 20 and r4:Get() == 40 and len:Get() == 4 and total:Get() == 100, "baseline")
	expect(Store.Remove(s, 2) == 20, "middle returns removed value")
	expect(
		r2:Get() == 30 and r4:Get() == nil and len:Get() == 3 and total:Get() == 80,
		"readers shift"
	)
	expect(Store.Remove(s) == 40, "default pos removes the tail")
	expect(r2:Get() == 30 and len:Get() == 2 and total:Get() == 40, "tail removal tracked")
	expect(
		(pcall(Store.Remove, s, 5)) == false
			and (pcall(Store.Remove, s, 0)) == false
			and (pcall(Store.Remove, s, 1.5)) == false
			and (pcall(Store.Remove, s, "2")) == false,
		"out-of-range / fractional / string pos errors"
	)
	expect(len:Get() == 2 and total:Get() == 40, "rejected pos leaves state intact")
	local empty = Flux.CreateStore({})
	expect(Store.Remove(empty) == nil, "empty store with no pos is a nil no-op")
end)

test("store.remove · alias survival and displaced teardown", function()

	local shared = { x = 1 }
	local s = Flux.CreateStore({ shared, shared })
	local reader = new(function()
		return s[1].x
	end)
	expect(reader:Get() == 1, "baseline")
	expect(Store.Remove(s, 1) == shared, "returns the raw table")
	s[1].x = 5
	expect(reader:Get() == 5, "survivor stays reactive")

	local s2 = Flux.CreateStore({ { v = 1 }, { v = 2 } })
	local first = new(function()
		return s2[1].v
	end)
	expect(first:Get() == 1, "shift baseline")
	Store.Remove(s2, 1)
	expect(first:Get() == 2, "reader follows the survivor")
end)

test("store · displacement via assignment runs the same alias scan", function()

	local shared = { x = 1 }
	local s = Flux.CreateStore({ shared, shared, "filler" })
	local reader = new(function()
		return s[2].x
	end)
	expect(reader:Get() == 1, "baseline")
	s[1] = "other"
	s[2].x = 5
	expect(reader:Get() == 5, "survivor stays reactive")
end)

test("store.insert · middle/append with readers and a length tracker", function()
	local s = Flux.CreateStore({ 10, 30 })
	local r1 = new(function()
		return s[1]
	end)
	local r2 = new(function()
		return s[2]
	end)
	local r3 = new(function()
		return s[3]
	end)
	local len = new(function()
		return #s
	end)
	expect(r1:Get() == 10 and r2:Get() == 30 and r3:Get() == nil and len:Get() == 2, "baseline")
	Store.Insert(s, 2, 20)
	expect(
		r1:Get() == 10 and r2:Get() == 20 and r3:Get() == 30 and len:Get() == 3,
		"middle shifts readers"
	)
	Store.Insert(s, 40)
	expect(s[4] == 40 and len:Get() == 4, "append updates the length tracker")
end)

test("store.insert · validates explicit positions", function()

	local s = Flux.CreateStore({ 10, 20, 30 })
	local r1 = new(function()
		return s[1]
	end)
	expect(r1:Get() == 10, "baseline")
	expect((pcall(Store.Insert, s, 1.5, 99)) == false, "fractional pos rejected")
	expect((pcall(Store.Insert, s, 50, 99)) == false, "out-of-range pos rejected")
	expect((pcall(Store.Insert, s, "2", 99)) == false, "string pos rejected")
	Store.Insert(s, 4, 40)
	expect(s[4] == 40 and r1:Get() == 10, "append at length+1")
end)

test("store.reconcile · sparse and out-of-band integer keys", function()
	local s = Flux.CreateStore({ [2] = "old", name = "n" })
	Store.Reconcile(s, { [2] = "new", name = "n" })
	expect(Store.Unwrap(s)[2] == "new", "sparse [2] (no [1]) updated")

	local s2 = Flux.CreateStore({ name = "n" })
	Store.Reconcile(s2, { [2] = "added", name = "n" })
	expect(Store.Unwrap(s2)[2] == "added", "sparse [2] added")

	local s3 = Flux.CreateStore({ [3] = "x", name = "n" })
	Store.Reconcile(s3, { name = "n" })
	expect(Store.Unwrap(s3)[3] == nil, "hole [3] removed")

	local s4 = Flux.CreateStore({ 10, 20, [5] = "x" })
	Store.Reconcile(s4, { 10, 20, [5] = "z" })
	expect(Store.Unwrap(s4)[5] == "z", "out-of-band [5] past a real array updated")
end)

test("store.reconcile · fires only changed leaves, leaves others untouched", function()
	local s =
		Flux.CreateStore({ player = { health = 100, name = "Guest" }, settings = { volume = 0.5 } })
	local healthRuns, nameRuns, volRuns = 0, 0, 0
	Flux.Effect(function()
		healthRuns += 1
		local _ = s.player.health
	end)
	Flux.Effect(function()
		nameRuns += 1
		local _ = s.player.name
	end)
	Flux.Effect(function()
		volRuns += 1
		local _ = s.settings.volume
	end)
	flush()
	expect(healthRuns == 1 and nameRuns == 1 and volRuns == 1, "baseline runs")

	Store.Reconcile(s, { player = { health = 90, name = "Guest" }, settings = { volume = 0.5 } })
	flush()
	expect(s.player.health == 90, "changed leaf applied")
	expect(healthRuns == 2, "only the changed leaf observer re-ran")
	expect(nameRuns == 1 and volRuns == 1, "unchanged leaves did not fire")
end)

test("store.reconcile · identical snapshot is a no-op", function()
	local s = Flux.CreateStore({ a = 1, nested = { b = 2 } })
	local runs = 0
	Flux.Effect(function()
		runs += 1
		local _ = s.a + s.nested.b
	end)
	flush()
	expect(runs == 1, "baseline")
	Store.Reconcile(s, { a = 1, nested = { b = 2 } })
	flush()
	expect(runs == 1, "identical reconcile fired nothing")
end)

test("store.reconcile · reuses nested proxy identity, no teardown", function()
	local s = Flux.CreateStore({ nested = { b = 2 } })
	local nestedBefore = s.nested
	local reader = new(function()
		return s.nested.b
	end)
	expect(reader:Get() == 2, "baseline")
	Store.Reconcile(s, { nested = { b = 5 } })
	expect(s.nested == nestedBefore, "nested proxy identity preserved")
	expect(reader:Get() == 5, "leaf updated through the reused proxy")
end)

test("store.reconcile · adds and removes keys, fires the tracker once", function()
	local s = Flux.CreateStore({ a = 1, b = 2 })
	local keyRuns, sawKeys = 0, {}
	Flux.Effect(function()
		keyRuns += 1
		sawKeys = {}
		for k in s do
			sawKeys[k] = true
		end
	end)
	flush()
	expect(keyRuns == 1 and sawKeys.a and sawKeys.b, "baseline keys")
	Store.Reconcile(s, { a = 1, c = 3 })
	flush()
	expect(keyRuns == 2, "key-set change fired the tracker exactly once")
	expect(s.a == 1 and s.b == nil and s.c == 3, "key set reconciled")
	expect(sawKeys.c and sawKeys.b == nil, "iteration reflects new key set")
end)

test("store.reconcile · array positional diff with grow and shrink", function()
	local s = Flux.CreateStore({ 10, 20, 30 })
	local r2 = new(function()
		return s[2]
	end)
	local len = new(function()
		return #s
	end)
	expect(r2:Get() == 20 and len:Get() == 3, "baseline")

	Store.Reconcile(s, { 10, 99, 30, 40 })
	expect(r2:Get() == 99 and len:Get() == 4, "changed index + grow")
	expect(Store.Unwrap(s)[4] == 40, "appended value present")

	Store.Reconcile(s, { 10 })
	expect(len:Get() == 1, "length tracker followed the shrink")
	expect(Store.Unwrap(s)[2] == nil and Store.Unwrap(s)[3] == nil, "tail cleared")
end)

test("store.reconcile · scalar replaces nested table tears down the displaced proxy", function()
	local s = Flux.CreateStore({ slot = { v = 1 } })
	local innerRaw = Store.Unwrap(s).slot
	local _ = s.slot.v
	expect(getmetatable(s.slot) ~= nil, "nested proxy exists")
	Store.Reconcile(s, { slot = "gone" })
	expect(s.slot == "gone", "scalar replacement applied")
	local reproxied = Flux.CreateStore(innerRaw)
	expect(getmetatable(reproxied) ~= nil, "displaced proxy was torn down")
end)

test("store.reconcile · nested array inside hash reconciles positionally", function()
	local s = Flux.CreateStore({ items = { "a", "b" }, count = 2 })
	local lenRuns, lastLen = 0, 0
	Flux.Effect(function()
		lenRuns += 1
		lastLen = #s.items
	end)
	flush()
	expect(lenRuns == 1 and lastLen == 2, "baseline")
	Store.Reconcile(s, { items = { "a", "b", "c" }, count = 3 })
	flush()
	expect(lastLen == 3, "nested array length followed reconcile")
	expect(s.items[3] == "c" and s.count == 3, "nested + sibling scalar applied")
end)

test("store.reconcile · stored functions stay opaque leaves", function()
	local calls = 0
	local fnA = function()
		calls += 1
	end
	local fnB = function()
		calls += 1
	end
	local s = Flux.CreateStore({ cb = fnA })
	local reader = new(function()
		return s.cb
	end)
	expect(reader:Get() == fnA, "baseline")
	Store.Reconcile(s, { cb = fnB })
	expect(reader:Get() == fnB, "fn leaf swapped")
	expect(calls == 0, "stored fns never executed by reconcile")
end)

test("store.reconcile · rejects non-store and non-table args", function()
	local s = Flux.CreateStore({ a = 1 })
	expect((pcall(Store.Reconcile, {}, { a = 1 })) == false, "non-proxy target rejected")
	expect((pcall(Store.Reconcile, s, 5 :: any)) == false, "non-table newData rejected")
end)

test("store · per-key nodes are owned by the store, not the reading reaction", function()

	local s = Flux.CreateStore({ count = 1 })
	local first = new(function()
		return s.count
	end)
	expect(first:Get() == 1, "first reader sees the value")
	first:Destroy()

	local runs, last = 0, 0
	Flux.Effect(function()
		runs += 1
		last = s.count
	end)
	flush()
	expect(runs == 1 and last == 1, "a fresh reader still sees the live store node")
	s.count = 2
	flush()
	expect(runs == 2 and last == 2, "the surviving store node still propagates writes")
	Store.Destroy(s)
end)

test("store · created in a scope is destroyed with the scope", function()
	local raw = { hp = 100, nested = { mp = 50 } }
	local s, nestedProxy
	local owner = Flux.Scope(function()
		s = Flux.CreateStore(raw)
		Flux.Effect(function()
			local _ = s.hp
		end)
		nestedProxy = s.nested
		Flux.Effect(function()
			local _ = s.nested.mp
		end)
	end)
	flush()
	expect(
		getmetatable(s) ~= nil and getmetatable(nestedProxy) ~= nil,
		"proxies are live inside the scope"
	)

	owner:Destroy()
	expect(getmetatable(s) == nil, "root proxy is stripped when its scope is destroyed")
	expect(getmetatable(nestedProxy) == nil, "nested proxy is torn down by the cascade too")
	expect(raw.hp == 100 and raw.nested.mp == 50, "the raw table is left intact")

	local s2 = Flux.CreateStore(raw)
	expect(getmetatable(s2) ~= nil and s2 ~= s, "the raw table can be re-wrapped after teardown")
	Store.Destroy(s2)
end)

test("store.reconcile · duplicate keys alias one element (expected warn)", function()

	local s = Flux.CreateStore({ { id = 1, name = "a" } })
	Store.Reconcile(s, { { id = 1, name = "b" }, { id = 1, name = "c" } }, "id")
	local raw = Store.Unwrap(s)
	expect(raw[1] == raw[2], "duplicate keys collapse onto one reused element")
end)

test("store.move · shifts elements forward and backward and notifies affected indices", function()
	local s = Flux.CreateStore({ "a", "b", "c", "d" })
	local seen1, seen2, seen3, seen4
	local runs2, runs4 = 0, 0
	Flux.Effect(function()
		seen1 = s[1]
	end)
	Flux.Effect(function()
		runs2 += 1
		seen2 = s[2]
	end)
	Flux.Effect(function()
		seen3 = s[3]
	end)
	Flux.Effect(function()
		runs4 += 1
		seen4 = s[4]
	end)
	flush()
	expect(seen1 == "a" and seen2 == "b" and seen3 == "c" and seen4 == "d", "initial elements")

	Store.Move(s, 1, 3)
	flush()
	expect(seen1 == "b" and seen2 == "c" and seen3 == "a" and seen4 == "d", "forward move 1 -> 3")
	expect(runs4 == 1, "index 4 outside moved range [1..3] was not re-evaluated")

	Store.Move(s, 4, 2)
	flush()
	expect(seen1 == "b" and seen2 == "d" and seen3 == "c" and seen4 == "a", "backward move 4 -> 2")

	local beforeRuns2 = runs2
	Store.Move(s, 2, 2)
	flush()
	expect(runs2 == beforeRuns2, "from == to is a no-op")

	local plain = { 10, 20, 30 }
	Store.Move(plain, 3, 1)
	expect(plain[1] == 30 and plain[2] == 10 and plain[3] == 20, "Store.move works on plain tables")

	sert.fails(function()
		Store.Move(s, 0, 2)
	end, "out of range")
	sert.fails(function()
		Store.Move(s, 1, 99)
	end, "out of range")
	Store.Destroy(s)
end)

return {}
