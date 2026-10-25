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
local flush = Flux.Flush

test("show · mounts truthy, swaps to fallback, caches on equal truthiness", function()
	local cond = Flux.State(true)
	local builds = { a = 0, b = 0 }
	local node = Flux.Show(cond, function()
		builds.a += 1
		return { tag = "A" }
	end, function()
		builds.b += 1
		return { tag = "B" }
	end)
	flush()
	expect(node().tag == "A" and builds.a == 1, "truthy branch mounted")
	cond:Set(1)
	flush()
	expect(builds.a == 1, "equal truthiness does not rebuild")
	expect(node().tag == "A", "same branch retained")
	cond:Set(false)
	flush()
	expect(node().tag == "B" and builds.b == 1, "fallback mounted on falsy")
	cond:Set(true)
	flush()
	expect(builds.a == 2, "re-truthy rebuilds the truthy branch")
end)

test("show · falsy with no fallback yields nil", function()
	local cond = Flux.State(false)
	local node = Flux.Show(cond, function()
		return { tag = "A" }
	end)
	flush()
	expect(node() == nil, "no fallback -> nil branch")
	cond:Set(true)
	flush()
	expect(node().tag == "A", "becomes the component when truthy")
end)

test("show · function condition is tracked", function()
	local flag = Flux.State(false)
	local node = Flux.Show(function()
		return flag()
	end, function()
		return { tag = "A" }
	end)
	flush()
	expect(node() == nil, "fn condition initially falsy")
	flag:Set(true)
	flush()
	expect(node() ~= nil and node().tag == "A", "fn-condition branch reacts")
end)

test("show · branch scope torn down on swap (factory owns via its scope)", function()
	local cond = Flux.State(true)
	local cleaned = 0
	local node = Flux.Show(cond, function()
		local inner = Flux(0)
		Flux.Cleanup(function()
			cleaned += 1
		end)
		return { node = inner }
	end, function()
		return { tag = "fallback" }
	end)
	flush()
	expect(node().node ~= nil and cleaned == 0, "branch alive while truthy")
	cond:Set(false)
	flush()
	expect(cleaned == 1, "branch-owned node destroyed when branch unmounts")
end)

test("show · throwing component does not strand tracking (expected warn)", function()
	local cond = Flux.State(true)
	local node = Flux.Show(cond, function()
		error("component boom")
	end)
	flush()
	local probe = Flux.State(1)
	local seen = 0
	Flux.Effect(function()
		probe()
		seen += 1
	end)
	flush()
	probe:Set(2)
	flush()
	expect(seen == 2, "tracking restored after a throwing component")
	expect(node() == nil, "output is nil after the failed build")
end)

test("scope · show is owned by the enclosing scope, torn down on its Destroy", function()
	local cond = Flux.State(true)
	local cleaned = 0

	local s, node = Flux.Scope(function()
		return Flux.Show(cond, function()
			local inner = Flux(0)
			Flux.Cleanup(function()
				cleaned += 1
			end)
			return { node = inner }
		end)
	end)
	flush()
	expect(node().node ~= nil and cleaned == 0, "scoped show mounted")
	s:Destroy()
	expect(cleaned == 1, "scope Destroy cascades through the show to the branch")
end)

test("switch · keyed mount and per-key cache", function()
	local key = Flux.State("x")
	local builds = {}
	local node = Flux.Switch(key)({
		x = function()
			builds.x = (builds.x or 0) + 1
			return { tag = "X" }
		end,
		y = function()
			builds.y = (builds.y or 0) + 1
			return { tag = "Y" }
		end,
	})
	flush()
	expect(node().tag == "X" and builds.x == 1, "initial key mounted")
	key:Set("y")
	flush()
	expect(node().tag == "Y" and builds.y == 1, "switched to y")
	key:Set("y")
	flush()
	expect(builds.y == 1, "same key does not rebuild")
	key:Set("z")
	flush()
	expect(node() == nil, "missing key -> nil branch")
end)

test("switch · destroying the node tears down the live branch", function()
	local key = Flux.State("a")
	local cleaned = 0
	local node = Flux.Switch(key)({
		a = function()
			local n = Flux(0)
			Flux.Cleanup(function()
				cleaned += 1
			end)
			return n
		end,
	})
	flush()
	node:Destroy()
	expect(cleaned == 1, "node Destroy cascades to the branch scope")
end)

test("switch · prior branch scope torn down on key change", function()

	local key = Flux.State("x")
	local xDestroyed = 0
	local yDestroyed = 0
	local node = Flux.Switch(key)({
		x = function()
			local n = Flux(0)
			Flux.Cleanup(function()
				xDestroyed += 1
			end)
			return { tag = "X", n = n }
		end,
		y = function()
			local n = Flux(0)
			Flux.Cleanup(function()
				yDestroyed += 1
			end)
			return { tag = "Y", n = n }
		end,
	})
	flush()
	expect(node().tag == "X" and xDestroyed == 0, "x branch mounted and alive")

	key:Set("y")
	flush()
	expect(node().tag == "Y", "switched to y")
	expect(xDestroyed == 1, "x branch scope torn down exactly once on key change")
	expect(yDestroyed == 0, "new y branch is alive, not torn down")
end)

test("switch · changing to an unmapped key tears down prior branch and nulls output", function()

	local key = Flux.State("x")
	local xDestroyed = 0
	local node = Flux.Switch(key)({
		x = function()
			Flux.Cleanup(function()
				xDestroyed += 1
			end)
			return { tag = "X" }
		end,
	})
	flush()
	expect(node().tag == "X" and xDestroyed == 0, "x branch mounted")

	key:Set("z")
	flush()
	expect(xDestroyed == 1, "prior x branch torn down exactly once")
	expect(node() == nil, "output nil for unmapped key")
end)

test("switch · Flux.otherwise mounts for unmapped keys without rebuilding", function()
	local key = Flux.State("x")
	local builds = { x = 0, fallback = 0 }
	local node = Flux.Switch(key)({
		x = function()
			builds.x += 1
			return { tag = "X" }
		end,
		[Flux.Otherwise] = function()
			builds.fallback += 1
			return { tag = "DEFAULT" }
		end,
	})
	flush()
	expect(node().tag == "X" and builds.x == 1, "a matched key wins over the default")

	key:Set("y")
	flush()
	expect(
		node().tag == "DEFAULT" and builds.fallback == 1,
		"unmapped key mounts the default factory"
	)

	key:Set("z")
	flush()
	expect(builds.fallback == 1, "switching between unmapped values reuses one default mount")

	key:Set("x")
	flush()
	expect(node().tag == "X" and builds.x == 2, "returns to the matched branch from the default")
end)

test("show · the value accessor tracks the live condition without remounting", function()

	local user = Flux.State({ name = "Ada" })
	local builds, seen = 0, nil
	Flux.Show(user, function(value)
		builds += 1
		Flux.Effect(function()
			seen = value().name
		end)
		return "panel"
	end)
	flush()
	expect(builds == 1 and seen == "Ada", "mounted once; accessor effect saw the initial value")

	user:Set({ name = "Grace" })
	flush()
	expect(builds == 1, "no rebuild across a truthy -> truthy change")
	expect(seen == "Grace", "accessor effect re-ran with the live value")
end)

test("showKeyed · keys on identity where show keys on truthiness", function()

	local a, b = { id = 1 }, { id = 2 }
	local sel = Flux.State(a)
	local showBuilds, keyedBuilds = 0, 0

	Flux.Show(sel, function()
		showBuilds += 1
		return "x"
	end)
	local keyed = Flux.ShowKeyed(sel, function(value)
		keyedBuilds += 1
		return value().id
	end)
	flush()
	expect(showBuilds == 1 and keyedBuilds == 1, "both branches mount once")
	expect(keyed() == 1, "keyed factory read the initial value via value()")

	sel:Set(b)
	flush()
	expect(showBuilds == 1, "plain show keeps its branch across truthy -> truthy")
	expect(keyedBuilds == 2 and keyed() == 2, "showKeyed remounts and value() is the new identity")
end)

test("showKeyed · swaps to fallback on falsy and rebuilds on the next identity", function()
	local sel = Flux.State({ id = 1 })
	local comp, fb = 0, 0
	local node = Flux.ShowKeyed(sel, function()
		comp += 1
		return "C"
	end, function()
		fb += 1
		return "F"
	end)
	flush()
	expect(node() == "C" and comp == 1, "truthy value mounts the component")

	sel:Set(nil)
	flush()
	expect(node() == "F" and fb == 1, "falsy mounts the fallback")

	sel:Set({ id = 2 })
	flush()
	expect(node() == "C" and comp == 2, "a new truthy identity rebuilds the component")
end)

test("switch · the default branch value accessor tracks the live unmatched value", function()

	local route = Flux.State("home")
	local defaultBuilds, seen = 0, {}
	local node = Flux.Switch(route)({
		home = function(value)
			return "home:" .. value()
		end,
		[Flux.Otherwise] = function(value)
			defaultBuilds += 1
			Flux.Effect(function()
				seen[#seen + 1] = value()
			end)
			return "default"
		end,
	})
	flush()
	expect(node() == "home:home", "keyed branch value() returns the matched key")

	route:Set("about")
	flush()
	route:Set("contact")
	flush()
	expect(defaultBuilds == 1, "the one default mount is reused across unmatched values")
	expect(
		table.concat(seen, ",") == "about,contact",
		"default accessor tracked each live unmatched value"
	)
end)

test(
	"presence · mounts truthy, holds branch with exiting=true on falsy, and unmounts on done()",
	function()
		local open = Flux.State(true)
		local builds = 0
		local cleaned = 0
		local exitNode : any
		local finishExit : (() -> ())?

		local node = Flux.Presence(open, function(exiting, done)
			builds += 1
			exitNode = exiting
			finishExit = done
			Flux.Cleanup(function()
				cleaned += 1
			end)
			return { tag = "modal" }
		end)
		flush()
		expect(node() ~= nil and node().tag == "modal" and builds == 1, "mounted when truthy")
		expect(exitNode() == false, "exiting starts false")

		finishExit()
		flush()
		expect(node() ~= nil and cleaned == 0, "done() ignored while not exiting")

		open:Set(false)
		flush()
		expect(node() ~= nil and cleaned == 0, "branch stays mounted during exit transition")
		expect(exitNode() == true, "exiting node flipped to true")

		open:Set(true)
		flush()
		expect(builds == 1 and cleaned == 0, "interrupted exit keeps the existing mount")
		expect(exitNode() == false, "exiting reset to false")

		open:Set(false)
		flush()
		expect(exitNode() == true, "exiting again")
		finishExit()
		flush()
		expect(node() == nil and cleaned == 1, "done() unmounts and tears down the branch scope")
	end
)

test(
	"presence · destroying the presence node tears down the live branch and throwing factory recovers (expected warn)",
	function()
		local cond = Flux.State(true)
		local cleaned = 0
		local node = Flux.Presence(cond, function()
			Flux.Cleanup(function()
				cleaned += 1
			end)
			return "panel"
		end)
		flush()
		expect(node() == "panel" and cleaned == 0, "mounted")
		node:Destroy()
		expect(cleaned == 1, "Destroy tore down the active presence branch")

		local bad = Flux.Presence(Flux.State(true), function()
			error("presence boom (expected warn)")
		end)
		flush()
		expect(bad() == nil, "throwing presence factory leaves output nil")
	end
)

test("pick · selects between reactive branches and only subscribes to the active side", function()
	local cond = Flux.State(true)
	local a = Flux.State("A1")
	local b = Flux.State("B1")
	local aReads, bReads = 0, 0

	local picked = Flux.Pick(cond, function()
		aReads += 1
		return a()
	end, function()
		bReads += 1
		return b()
	end)
	expect(picked() == "A1" and aReads == 1 and bReads == 0, "only truthy branch read")

	b:Set("B2")
	expect(picked() == "A1" and aReads == 1 and bReads == 0, "untaken branch is not a dependency")

	cond:Set(false)
	expect(picked() == "B2" and bReads == 1, "falsy branch selected")
	a:Set("A2")
	expect(picked() == "B2" and bReads == 1, "truthy branch no longer a dependency while falsy")

	local optional = Flux.Pick(cond, "present")
	expect(optional() == nil, "omitted whenFalse yields nil when falsy")
	cond:Set(true)
	expect(optional() == "present", "yields whenTrue when truthy")
end)

rtest("show · mounts/unmounts real instances under a parent", function()
	local cond = Flux.State(true)
	local parent
	local s = Flux.Scope(function()
		local shown = Flux.Show(cond, function()
			return Flux.New("Frame")({ Name = "Branch" })
		end)
		parent = Flux.New("Frame")({ Name = "Root", shown })
	end)
	flush()
	expect(parent:FindFirstChild("Branch") ~= nil, "branch instance parented via Bind.children")
	cond:Set(false)
	flush()
	expect(parent:FindFirstChild("Branch") == nil, "branch unparented when falsy")
	s:Destroy()
end)

rtest("switch · reparents the selected instance on key change", function()
	local key = Flux.State("red")
	local root
	local s = Flux.Scope(function()
		local view = Flux.Switch(key)({
			red = function()
				return Flux.New("Frame")({ Name = "Red" })
			end,
			blue = function()
				return Flux.New("Frame")({ Name = "Blue" })
			end,
		})
		root = Flux.New("Frame")({ Name = "Root", view })
	end)
	flush()
	expect(root:FindFirstChild("Red") ~= nil, "red mounted")
	key:Set("blue")
	flush()
	expect(
		root:FindFirstChild("Red") == nil and root:FindFirstChild("Blue") ~= nil,
		"swapped to blue"
	)
	s:Destroy()
end)

test(
	"presence · destroys exiting and done nodes when mount completes or output is destroyed",
	function()
		local visible = Flux.State(true)
		local exitDestroyed = 0
		local finishFn : (() -> ())?
		local out = Flux.Presence(visible, function(exiting, done)
			exiting:OnDestroy(function()
				exitDestroyed += 1
			end)
			finishFn = done
			return "mounted"
		end)
		flush()
		expect(out() == "mounted" and exitDestroyed == 0, "mounted with live exiting node")

		visible:Set(false)
		flush()
		expect(exitDestroyed == 0, "exiting node still alive while exit animation is in progress")
		assert(finishFn)()
		flush()
		expect(
			out() == nil and exitDestroyed == 1,
			"completing exit destroys the per-mount exiting node"
		)

		visible:Set(true)
		flush()
		expect(out() == "mounted" and exitDestroyed == 1, "re-mounted with a fresh exiting node")
		out:Destroy()
		expect(exitDestroyed == 2, "destroying presence output destroys the active exiting node")
	end
)

return {}
