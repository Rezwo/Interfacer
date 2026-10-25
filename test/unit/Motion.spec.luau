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
local expectError = sert.fails
local flush = Flux.Flush
local Motion = Flux.Motion
local MotionModule = if IS_ROBLOX
	then require(game:GetService("ReplicatedStorage"):WaitForChild("Flux"):WaitForChild("Motion")) :: any
	else require("../../src/Motion") :: any
local Compatibility = if IS_ROBLOX then nil else require("../../src/Compatibility") :: any
local TweenInfo = if IS_ROBLOX then TweenInfo else Compatibility.TweenInfo
local Enum = if IS_ROBLOX then Enum else Compatibility.Enum
local UDim = if IS_ROBLOX then UDim else Compatibility.UDim
local UDim2 = if IS_ROBLOX then UDim2 else Compatibility.UDim2
local Vector2 = if IS_ROBLOX then Vector2 else Compatibility.Vector2
local Vector3 = if IS_ROBLOX then Vector3 else Compatibility.Vector3
local Color3 = if IS_ROBLOX then Color3 else Compatibility.Color3
local ColorSequence = if IS_ROBLOX then ColorSequence else Compatibility.ColorSequence
local ColorSequenceKeypoint = if IS_ROBLOX
	then ColorSequenceKeypoint
	else Compatibility.ColorSequenceKeypoint
local NumberSequence = if IS_ROBLOX then NumberSequence else Compatibility.NumberSequence
local NumberSequenceKeypoint = if IS_ROBLOX
	then NumberSequenceKeypoint
	else Compatibility.NumberSequenceKeypoint

local approx = sert.approx

local function advance(dt : number)
	Motion.Step(dt)
end

local function tweenAt(node : any, elapsed : number) : any
	Motion.Step(elapsed)
	return node:Get()
end

local function tweenToGoal(start : any, goal : any)

	local tw = Flux.Tween(start, TweenInfo.new(0, Enum.EasingStyle.Linear))
	tw:Set(goal)
	flush()
	Motion.Step(0)
	return tw:Get()
end

test("motion · nil-goal fallback follows and survives retarget (expected warn)", function()

	local goal = Flux.State(nil)
	local spr = Flux.Spring(goal)
	goal:Set(5)
	flush()
	expect(spr:Get() == 5, "fallback follows the goal")
	spr:Set(99)
	expect(spr:Get() == 99, "retarget writes")
	goal:Set(7)
	flush()
	expect(spr:Get() == 7, "STILL follows after retarget")
end)

test("motion · non-animatable types error at the call site", function()
	expectError(function()
		return Flux.Spring(true)
	end, "Cannot animate a boolean value")
	expectError(function()
		return Flux.Tween("nope", nil)
	end, "Cannot animate a string value")
end)

test("motion · number spring converges (manual step)", function()
	local goal = Flux(0)
	local spr = Flux.Spring(goal, 10, 1)
	goal:Set(100)
	flush()
	advance(0.1)
	local mid = spr:Get()
	expect(mid > 0, `spring moved toward the goal, got {mid}`)
	advance(0.2)
	expect(approx(spr:Get(), 100, 0.5), `spring converged, got {spr:Get()}`)
end)

test("motion · impulse kicks a resting number spring", function()
	local spr = Flux.Spring(0, 10, 1)
	Motion.Step()
	expect(approx(spr:Get(), 0), "starts at rest at 0")

	spr:Impulse(500)
	advance(0.05)
	local mid = spr:Get()
	expect(mid > 0, `impulse moved the spring off rest, got {mid}`)

	advance(0.2)
	expect(approx(spr:Get(), 0, 0.5), `spring returns to target after impulse, got {spr:Get()}`)
end)

test("motion · impulse accumulates (two impulses > one)", function()
	local a = Flux.Spring(0, 10, 1)
	local b = Flux.Spring(0, 10, 1)
	Motion.Step()

	a:Impulse(100)
	b:Impulse(100)
	b:Impulse(100)

	advance(0.02)
	expect(b:Get() > a:Get(), `accumulated impulse travels further: a={a:Get()} b={b:Get()}`)
end)

test("motion · setVelocity replaces (not adds)", function()
	local spr = Flux.Spring(0, 10, 1)
	Motion.Step()
	spr:Impulse(1000)
	spr:SetVelocity(0)

	advance(0.05)
	expect(approx(spr:Get(), 0, 1e-3), `setVelocity(0) cancelled the impulse, got {spr:Get()}`)
end)

test("motion · impulse reactivates a converged spring", function()
	local goal = Flux(0)
	local spr = Flux.Spring(goal, 10, 1)
	goal:Set(50)
	flush()
	advance(0.2)
	expect(approx(spr:Get(), 50, 0.5), "converged to 50")

	spr:Impulse(-300)
	advance(0.03)
	expect(spr:Get() < 50, `impulse re-woke the converged spring, got {spr:Get()}`)
end)

test("motion · underdamped number spring overshoots then converges", function()
	local goal = Flux(0)
	local spr = Flux.Spring(goal, 12, 0.3)
	goal:Set(100)
	flush()

	local maxSeen = -math.huge

	for _ = 1, 25 do
		advance(0.02)
		local v = spr:Get()
		if v > maxSeen then
			maxSeen = v
		end
	end

	expect(maxSeen > 101, `underdamped spring overshot the goal, peak={maxSeen}`)
	expect(approx(spr:Get(), 100, 0.5), `underdamped spring converged, got {spr:Get()}`)
end)

test("motion · overdamped number spring converges monotonically (no overshoot)", function()
	local goal = Flux(0)
	local spr = Flux.Spring(goal, 12, 2)
	goal:Set(100)
	flush()

	local prev = spr:Get()
	local maxSeen = prev
	local sawProgress = false

	for _ = 1, 30 do
		advance(0.02)
		local v = spr:Get()

		expect(v >= prev - 1e-3, `overdamped spring is monotonic, prev={prev} now={v}`)
		if v > prev + 1e-4 then
			sawProgress = true
		end
		if v > maxSeen then
			maxSeen = v
		end
		prev = v
	end

	expect(sawProgress, "overdamped spring actually advanced toward the goal")

	expect(maxSeen <= 100 + 1e-3, `overdamped spring never overshoots, peak={maxSeen}`)
	expect(approx(spr:Get(), 100, 0.5), `overdamped spring converged, got {spr:Get()}`)
end)

test("motion · scope teardown unregisters a spring from the engine", function()

	local ms
	local sc = Flux.Scope(function()
		ms = Flux.Spring(0, 10, 1)
		ms(100)
	end)
	advance(0.01)
	local before = ms:Get()
	expect(before > 0, "spring advanced while scope was alive")
	sc:Destroy()
	advance(0.2)
	expect(ms:Get() == before, "the engine no longer steps the scope-destroyed spring")
end)

test("motion · vector spring round-trips exactly and converges componentwise", function()

	local start = vector.create(1.5, -2.25, 3.125)
	local goal = Flux.State(start)
	local spr = Flux.Spring(goal, 10, 1)
	Motion.Step()
	expect(spr:Get() == start, `resting spring pack/unpack is lossless, got {tostring(spr:Get())}`)

	goal:Set(vector.create(30, -20, 10))
	flush()
	advance(0.2)
	local v = spr:Get()
	expect(
		approx(v.x, 30, 0.5) and approx(v.y, -20, 0.5) and approx(v.z, 10, 0.5),
		`vector spring converged componentwise, got {tostring(v)}`
	)
end)

test(
	"motion · impulse/setVelocity/setCurrent/snap warn on a tween node (expected warn)",
	function()
		local tw = Flux.Tween(0, TweenInfo.new(0.2)) :: any
		tw:Impulse(100)
		tw:SetVelocity(100)
		tw:SetCurrent(50)
		tw:Snap(50)
		expect(approx(tw:Get(), 0), "tween value unchanged by spring-only controls")
		tw:Destroy()
	end
)

test(
	"motion · snap, setCurrent, initialVelocity, reactive frequency/damping, and type guards",
	function()
		local goal = Flux.State(0)
		local freq = Flux.State(10)
		local damp = Flux.State(1)
		local spr = Flux.Spring(goal, freq, damp, 500)
		flush()
		advance(0.02)
		expect(spr:Get() > 0, "initialVelocity moved the spring off 0")

		spr:Snap(250)
		expect(spr() == 250, "snap sets current value immediately")
		advance(0.05)
		expect(spr() == 250, "snap zeroes velocity and target so spring stays at rest")

		spr:SetCurrent(100)
		expect(spr() == 100, "setCurrent updates animated value immediately")
		advance(0.05)
		expect(spr() > 100, "spring eases back toward target 250 after setCurrent")

		goal:Set(250)
		freq:Set(20)
		damp:Set(0.8)
		flush()
		advance(0.5)
		expect(approx(spr(), 250, 0.5), "converged with updated frequency and damping")

		expectError(function()
			spr:Set("bad" :: any)
		end, "Cannot retarget")
		expectError(function()
			spr:Impulse("bad" :: any)
		end, "Cannot impulse")
		expectError(function()
			spr:SetVelocity("bad" :: any)
		end, "Cannot set velocity")
		expectError(function()
			spr:SetCurrent("bad" :: any)
		end, "Cannot set a number spring's current value")
		expectError(function()
			spr:Snap("bad" :: any)
		end, "Cannot snap")

		spr:Destroy()
	end
)

test("motion · tween reactive TweenInfo, DelayTime, and easing styles", function()
	local goal = Flux.State(0)
	local info = Flux.State(
		TweenInfo.new(0.4, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, 0.2)
	)
	local tw = Flux.Tween(goal, info)
	goal:Set(100)
	flush()

	local rawTween = MotionModule.NodeToMotion[tw] :: any
	MotionModule.Engine.SetupTween(rawTween, info:Peek())
	advance(0.1)
	expect(approx(tw(), 0), "tween waits during DelayTime")
	advance(0.3)
	expect(approx(tw(), 50, 1), "halfway through tween after DelayTime")

	info:Set(TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In))
	goal:Set(200)
	flush()
	advance(0.2)
	expect(approx(tw(), 200, 1e-3), "completed with updated reactive TweenInfo")
	tw:Destroy()

	local styles = {
		Enum.EasingStyle.Linear,
		Enum.EasingStyle.Sine,
		Enum.EasingStyle.Back,
		Enum.EasingStyle.Quad,
		Enum.EasingStyle.Quart,
		Enum.EasingStyle.Quint,
		Enum.EasingStyle.Bounce,
		Enum.EasingStyle.Elastic,
		Enum.EasingStyle.Exponential,
		Enum.EasingStyle.Circular,
		Enum.EasingStyle.Cubic,
	}
	local directions = {
		Enum.EasingDirection.In,
		Enum.EasingDirection.Out,
		Enum.EasingDirection.InOut,
	}
	for _, style in styles do
		for _, dir in directions do
			local curve = MotionModule.Easing.Curve(style, dir)
			local v0 = curve(0)
			local vMid = MotionModule.Easing.Get(0.5, style, dir)
			local v1 = curve(1)
			expect(
				approx(v0, 0, 2e-3) and approx(v1, 1, 2e-3) and vMid == vMid,
				`curve {style.Name}/{dir.Name}`
			)
		end
	end
end)

test("motion · Vector3 spring impulse moves componentwise", function()
	local spr = Flux.Spring(Vector3.zero, 10, 1)
	advance(0.05)
	spr:Impulse(Vector3.new(0, 200, 0))
	advance(0.05)
	local v = spr:Get()
	expect(v.Y > 0 and math.abs(v.X) < 1e-2, `impulse hit Y only, got {tostring(v)}`)
end)

test("motion · Vector3 spring follows a reactive goal", function()
	local goal = Flux.State(Vector3.zero)
	local spr = Flux.Spring(goal, 10, 1)
	goal:Set(Vector3.new(0, 50, 0))
	flush()
	advance(0.05)
	local v = spr:Get()
	expect(v.Y > 1, `spring moved toward the goal, got {tostring(v)}`)
end)

test("motion · UDim2 tween reaches its goal", function()
	local goal = Flux.State(UDim2.fromScale(0, 0))
	local tw = Flux.Tween(goal, TweenInfo.new(0))
	goal:Set(UDim2.fromScale(1, 0))
	flush()
	Motion.Step(0)
	local v = tw:Get()
	expect(
		approx(v.X.Scale, 1) and approx(v.X.Offset, 0),
		`X axis reached the goal exactly, got {tostring(v)}`
	)
	expect(
		approx(v.Y.Scale, 0) and approx(v.Y.Offset, 0),
		`Y axis reached the goal exactly, got {tostring(v)}`
	)
end)

test("motion · tween linear easing is ~quarter-value at quarter-flight", function()

	local goal = Flux.State(0)
	local tw = Flux.Tween(goal, TweenInfo.new(1, Enum.EasingStyle.Linear))
	goal:Set(100)
	flush()
	local v = tweenAt(tw, 0.25)
	expect(v > 18 and v < 40, `linear tween ~25 at quarter-flight, got {v}`)
end)

test("motion · tween Reverses heads back toward the start", function()
	local goal = Flux.State(0)

	local tw = Flux.Tween(
		goal,
		TweenInfo.new(0.3, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, true)
	)
	goal:Set(100)
	flush()

	local v = tweenAt(tw, 0.55)
	expect(v < 30, `Reverses=true sent the tween back toward start, got {v}`)
end)

test("motion · tween RepeatCount loops back toward the start", function()
	local goal = Flux.State(0)
	local tw =
		Flux.Tween(goal, TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 2))
	goal:Set(100)
	flush()

	local v = tweenAt(tw, 0.6)
	expect(v < 50, `RepeatCount restarted the leg near the start, got {v}`)
end)

test("motion · number tween lands EXACTLY on the goal", function()
	local goal = Flux.State(0)
	local tw = Flux.Tween(goal, TweenInfo.new(0, Enum.EasingStyle.Linear))
	goal:Set(42)
	flush()
	Motion.Step(0)
	expect(approx(tw:Get(), 42, 1e-4), `number tween equals the goal exactly, got {tw:Get()}`)
end)

test("motion · UDim2 tween lands EXACTLY on the goal on both axes", function()
	local goal = Flux.State(UDim2.new(0, 0, 0, 0))
	local tw = Flux.Tween(goal, TweenInfo.new(0, Enum.EasingStyle.Linear))
	local target = UDim2.new(0.5, 10, 0.25, 20)
	goal:Set(target)
	flush()
	Motion.Step(0)
	local v = tw:Get()
	expect(approx(v.X.Scale, 0.5, 1e-4), `X.Scale exact, got {v.X.Scale}`)
	expect(approx(v.X.Offset, 10, 1e-4), `X.Offset exact, got {v.X.Offset}`)
	expect(approx(v.Y.Scale, 0.25, 1e-4), `Y.Scale exact, got {v.Y.Scale}`)
	expect(approx(v.Y.Offset, 20, 1e-4), `Y.Offset exact, got {v.Y.Offset}`)
end)

test("motion · Vector2 reaches its goal", function()
	local got = tweenToGoal(Vector2.new(-3, 7), Vector2.new(12.5, -4.25))
	expect(got == Vector2.new(12.5, -4.25), `Vector2 round-trip, got {tostring(got)}`)
end)

test("motion · Vector3 reaches its goal exactly", function()
	local got = tweenToGoal(Vector3.new(-3, 7, 1), Vector3.new(12.5, -4.25, 9))
	expect(got == Vector3.new(12.5, -4.25, 9), `Vector3 round-trip, got {tostring(got)}`)
end)

test("motion · UDim reaches its goal", function()

	local got = tweenToGoal(UDim.new(0, 0), UDim.new(0.5, 40))
	expect(got.Scale == 0.5 and got.Offset == 40, `UDim round-trip, got {tostring(got)}`)
end)

test("motion · UDim2 reaches its goal exactly", function()

	local got = tweenToGoal(UDim2.new(0, 0, 0, 0), UDim2.new(0.25, 30, 0.75, -10))
	expect(
		got.X.Scale == 0.25 and got.X.Offset == 30 and got.Y.Scale == 0.75 and got.Y.Offset == -10,
		`UDim2 round-trip, got {tostring(got)}`
	)
end)

rtest("motion · Rect reaches its goal", function()

	local got = tweenToGoal(Rect.new(0, 0, 1, 1), Rect.new(4, 8, 16, 32))
	expect(
		got.Min == Vector2.new(4, 8) and got.Max == Vector2.new(16, 32),
		`Rect round-trip, got {tostring(got)}`
	)
end)

rtest("motion · NumberRange reaches its goal", function()
	local got = tweenToGoal(NumberRange.new(0, 1), NumberRange.new(3.5, 9.25))
	expect(
		approx(got.Min, 3.5) and approx(got.Max, 9.25),
		`NumberRange round-trip, got {tostring(got.Min)}..{tostring(got.Max)}`
	)
end)

test("motion · NumberSequenceKeypoint reaches its goal", function()

	local goal = NumberSequenceKeypoint.new(0.4, 0.8, 0.1)
	local got = tweenToGoal(NumberSequenceKeypoint.new(0, 0, 0), goal)
	expect(
		approx(got.Time, 0.4) and approx(got.Value, 0.8) and approx(got.Envelope, 0.1),
		`NSK round-trip time={got.Time} value={got.Value} env={got.Envelope}`
	)
end)

test("motion · NumberSequence reaches its goal", function()

	local start = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0, 0),
		NumberSequenceKeypoint.new(0.5, 0.5, 0),
		NumberSequenceKeypoint.new(1, 1, 0),
	})
	local goal = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25, 0.05),
		NumberSequenceKeypoint.new(0.4, 0.9, 0.1),
		NumberSequenceKeypoint.new(1, 0.1, 0.2),
	})
	local got = tweenToGoal(start, goal)
	expect(#got.Keypoints == 3, `keypoint count preserved, got {#got.Keypoints}`)
	for i, k in goal.Keypoints do
		local g = got.Keypoints[i]
		expect(
			approx(g.Time, k.Time) and approx(g.Value, k.Value) and approx(g.Envelope, k.Envelope),
			`NS keypoint {i} round-trip, got time={g.Time} value={g.Value} env={g.Envelope}`
		)
	end
end)

test("motion · ColorSequenceKeypoint reaches its goal", function()

	local goal = ColorSequenceKeypoint.new(0.6, Color3.new(0.2, 0.4, 0.8))
	local got = tweenToGoal(ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)), goal)
	local c = got.Value
	expect(approx(got.Time, 0.6), `CSK time round-trip, got {got.Time}`)
	expect(
		approx(c.R, 0.2, 3e-3) and approx(c.G, 0.4, 3e-3) and approx(c.B, 0.8, 3e-3),
		`CSK color round-trip, got {tostring(c)}`
	)
end)

test("motion · ColorSequence reaches its goal", function()

	local start = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 0, 0)),
		ColorSequenceKeypoint.new(0.5, Color3.new(0, 1, 0)),
		ColorSequenceKeypoint.new(1, Color3.new(0, 0, 1)),
	})
	local goal = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(0.2, 0.4, 0.8)),
		ColorSequenceKeypoint.new(0.25, Color3.new(0.9, 0.1, 0.5)),
		ColorSequenceKeypoint.new(1, Color3.new(0.05, 0.95, 0.35)),
	})
	local got = tweenToGoal(start, goal)
	expect(#got.Keypoints == 3, `keypoint count preserved, got {#got.Keypoints}`)
	for i, k in goal.Keypoints do
		local g = got.Keypoints[i]
		local c, e = g.Value, k.Value
		expect(approx(g.Time, k.Time, 1e-4), `CS keypoint {i} time round-trip, got {g.Time}`)
		expect(
			approx(c.R, e.R, 3e-3) and approx(c.G, e.G, 3e-3) and approx(c.B, e.B, 3e-3),
			`CS keypoint {i} color round-trip, got {tostring(c)}`
		)
	end
end)

test("motion · Color3 reaches its goal", function()

	local goal = Color3.new(0.9, 0.1, 0.5)
	local got = tweenToGoal(Color3.new(0, 0, 0), goal)
	expect(
		approx(got.R, 0.9, 3e-3) and approx(got.G, 0.1, 3e-3) and approx(got.B, 0.5, 3e-3),
		`Color3 round-trip, got {tostring(got)}`
	)
end)

rtest("motion · CFrame reaches its goal", function()

	local goal = CFrame.new(5, -2, 8) * CFrame.Angles(0, math.rad(90), 0)
	local got = tweenToGoal(CFrame.new(0, 0, 0), goal)
	local pos = got.Position
	expect(
		approx(pos.X, 5, 1e-3) and approx(pos.Y, -2, 1e-3) and approx(pos.Z, 8, 1e-3),
		`CFrame position round-trip, got {tostring(pos)}`
	)

	local ga = { goal:GetComponents() }
	local na = { got:GetComponents() }
	local ok = true
	for i = 4, 12 do
		if not approx(na[i], ga[i], 1e-3) then
			ok = false
		end
	end
	expect(ok, `CFrame rotation round-trip mismatch, got {tostring(got)}`)
end)

rtest("motion · NumberRange degenerate (Min==Max) reaches its goal", function()

	local got = tweenToGoal(NumberRange.new(2, 2), NumberRange.new(5, 5))
	expect(
		approx(got.Min, 5) and approx(got.Max, 5),
		`degenerate NumberRange, got {tostring(got.Min)}..{tostring(got.Max)}`
	)
end)

test(
	"motion · :set() and call-write on a destroyed motion warn and return early (expected warn)",
	function()
		local spr = Flux.Spring(0)
		spr:Destroy()

		spr:Set(100)
		spr(200)
		expect(
			spr:Get() == nil,
			"destroyed motion node remains stripped after :set() and call-write"
		)
	end
)

test(
	"motion · waking a sleeping motion inside step callback does not corrupt iteration",
	function()
		local b = Flux.Tween(0, TweenInfo.new(0, Enum.EasingStyle.Linear))
		local a = Flux.Tween(0, TweenInfo.new(0, Enum.EasingStyle.Linear))
		local motionA = MotionModule.NodeToMotion[a]
		local origUnpack = motionA.Unpack
		motionA.Unpack = function(arr)
			b:Set(50)
			return origUnpack(arr)
		end
		a:Set(10)
		Motion.Step(0)
		expect(approx(a:Get(), 10), "first tween completed")
		Motion.Step(0)
		expect(approx(b:Get(), 50), "woken second tween completed on subsequent step")
		a:Destroy()
		b:Destroy()
	end
)

return {}
