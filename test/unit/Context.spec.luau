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
local expectError = sert.fails
local new = Flux
local flush = Flux.Flush
local Context = Flux.Context

test("context · default outside provide", function()
	local ctx = Context("base")
	expect(ctx:Get() == "base", ":get() returns default outside provide")
end)

test("context · provide shadows for the synchronous extent, then restores", function()
	local ctx = Context("base")
	local inside
	local ret = ctx:Provide("scoped", function()
		inside = ctx:Get()
		return 42
	end)
	expect(inside == "scoped", "read inside provide sees provided value")
	expect(ret == 42, "provide returns fn's result")
	expect(ctx:Get() == "base", "value restored after provide")
end)

test("context · nesting pushes/pops innermost", function()
	local ctx = Context("a")
	local mid, inner
	ctx:Provide("b", function()
		ctx:Provide("c", function()
			inner = ctx:Get()
		end)
		mid = ctx:Get()
	end)
	expect(inner == "c", "innermost provide wins")
	expect(mid == "b", "outer value restored when inner pops")
	expect(ctx:Get() == "a", "default restored after all pop")
end)

test("context · nil and false values shadow the default", function()
	local ctx = Context("default")
	local nilSeen, gotInside = "untouched", true
	ctx:Provide(nil, function()
		nilSeen = ctx:Get()
	end)
	expect(nilSeen == nil, "nil value shadows the default")
	ctx:Provide(false, function()
		gotInside = ctx:Get()
	end)
	expect(gotInside == false, "false value shadows the default")
	expect(ctx:Get() == "default", "default restored")
end)

test("context · provide pops and re-raises on error", function()
	local ctx = Context("base")
	expectError(function()
		ctx:Provide("scoped", function()
			error("boom")
		end)
	end, "boom")
	expect(ctx:Get() == "base", "value popped even though fn threw")
end)

test("context · independent contexts don't interfere", function()
	local a = Context("a0")
	local b = Context("b0")
	local seenA, seenB
	a:Provide("a1", function()
		b:Provide("b1", function()
			seenA, seenB = a:Get(), b:Get()
		end)
	end)
	expect(seenA == "a1" and seenB == "b1", "each context tracks its own stack")
	expect(a:Get() == "a0" and b:Get() == "b0", "both restored")
end)

test("context · value may be a Node; stored opaquely", function()
	local node = new(7)
	local ctx = Context(node)
	local seen
	ctx:Provide(node, function()
		seen = ctx:Get()
	end)
	expect(seen == node, "context stores the Node itself, does not unwrap it")
	expect(ctx:Get() == node, "default is the same node, returned as-is")
end)

test("context · reactions remember the context provided where they were created", function()
	local ctx = Context("default")
	local captured, lateRead
	ctx:Provide("scoped", function()
		captured = ctx:Get()
		Flux.Effect(function()
			lateRead = ctx:Get()
		end)
	end)
	flush()
	expect(captured == "scoped", "synchronous capture sees provided value")
	expect(lateRead == "scoped", "deferred effect remembers creation-time context")
end)

test(
	"bindContext · captures active context frames for deferred callbacks and passes through at root",
	function()
		local Theme = Context("dark")
		local Lang = Context("en")

		local rootFn = function(x : number)
			return Theme:Get() .. ":" .. tostring(x)
		end
		expect(
			Flux.BindContext(rootFn) == rootFn,
			"outside any provide, bindContext returns fn unchanged"
		)

		local bound
		Theme:Provide("light", function()
			Lang:Provide("fr", function()
				bound = Flux.BindContext(function(suffix : string)
					return `{Theme:Get()}-{Lang:Get()}-{suffix}`
				end)
			end)
		end)

		expect(Theme:Get() == "dark" and Lang:Get() == "en", "outer context restored")
		expect(
			bound("ok") == "light-fr-ok",
			"bound callback sees the context snapshot from where it was wrapped"
		)

		local throwingBound
		Theme:Provide("solarized", function()
			throwingBound = Flux.BindContext(function()
				error("handler boom")
			end)
		end)
		expectError(function()
			throwingBound()
		end, "handler boom")
		expect(Theme:Get() == "dark", "context restored after a throwing bound callback")
	end
)

test("context · provide and untrack restore fast-path ownership and flush state", function()
	local ctx = Context("root")
	local seenInProvidedEffect
	local seenInRootEffect
	local rootScope = Flux.Scope(function()
		ctx:Provide("branch", function()
			Flux.Untrack(function()
				expect(ctx:Get() == "branch", "untrack inside provide still sees provided context")
			end)
			Flux.Effect(function()
				seenInProvidedEffect = ctx:Get()
			end)
		end)

		Flux.Effect(function()
			seenInRootEffect = ctx:Get()
		end)
	end)
	flush()
	expect(
		seenInProvidedEffect == "branch",
		"effect created inside provide captured branch context"
	)
	expect(seenInRootEffect == "root", "effect created after provide exited sees root default")
	rootScope:Destroy()
end)

return {}
