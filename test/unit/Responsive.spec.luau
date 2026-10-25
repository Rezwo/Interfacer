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
local Responsive = Flux.Responsive

local approx = sert.approx

test("responsive · scaleOf min mode fits the tighter axis", function()
	local vp = Flux({ X = 1920, Y = 1080 } :: any)
	local s = Responsive.ScaleOf({ Viewport = vp })
	expect(approx(s:Get(), 1), "at reference → 1.0")
	vp({ X = 960, Y = 540 } :: any)
	expect(approx(s:Get(), 0.5), "half reference → 0.5")
	vp({ X = 800, Y = 600 } :: any)
	expect(approx(s:Get(), 800 / 1920), "min picks the tighter (width) axis")
	vp({ X = 3840, Y = 2160 } :: any)
	expect(approx(s:Get(), 2), "above reference scales up unclamped")
	s:Destroy()
end)

test("responsive · scaleOf honors mode", function()
	local w = Responsive.ScaleOf({ Viewport = Flux({ X = 960, Y = 1080 } :: any), Mode = "Width" })
	expect(approx(w:Get(), 0.5), "width mode tracks X")
	local h = Responsive.ScaleOf({ Viewport = Flux({ X = 1920, Y = 540 } :: any), Mode = "Height" })
	expect(approx(h:Get(), 0.5), "height mode tracks Y")
	local m = Responsive.ScaleOf({ Viewport = Flux({ X = 800, Y = 1080 } :: any), Mode = "Maximum" })
	expect(approx(m:Get(), 1), "max picks the looser axis")
	w:Destroy()
	h:Destroy()
	m:Destroy()
end)

test("responsive · scaleOf clamps", function()
	local floored =
		Responsive.ScaleOf({ Viewport = Flux({ X = 384, Y = 216 } :: any), Minimum = 0.5 })
	expect(approx(floored:Get(), 0.5), "min clamp floors the factor")
	local capped =
		Responsive.ScaleOf({ Viewport = Flux({ X = 3840, Y = 2160 } :: any), Maximum = 1.5 })
	expect(approx(capped:Get(), 1.5), "max clamp caps the factor")
	floored:Destroy()
	capped:Destroy()
end)

test("responsive · scaleOf unknown mode falls back to min (expected warn)", function()
	local s =
		Responsive.ScaleOf({ Viewport = Flux({ X = 960, Y = 540 } :: any), Mode = "wat" :: any })
	expect(approx(s:Get(), 0.5), "bad mode → min")
	s:Destroy()
end)

test("responsive · breakpointOf thresholds", function()
	local vp = Flux({ X = 599, Y = 1080 } :: any)
	local b = Responsive.BreakpointOf({ Viewport = vp })
	expect(b:Get() == "Phone", "< 600 → phone")
	vp({ X = 600, Y = 1080 } :: any)
	expect(b:Get() == "Tablet", "600 boundary → tablet")
	vp({ X = 1023, Y = 1080 } :: any)
	expect(b:Get() == "Tablet", "< 1024 → tablet")
	vp({ X = 1024, Y = 1080 } :: any)
	expect(b:Get() == "Desktop", "1024 boundary → desktop")
	b:Destroy()

	local custom = Responsive.BreakpointOf({
		Viewport = Flux({ X = 700, Y = 0 } :: any),
		Breakpoints = { Phone = 800, Tablet = 1600 },
	})
	expect(custom:Get() == "Phone", "custom thresholds")
	custom:Destroy()
end)

test("responsive · default node values", function()
	expect(approx(Responsive.Scale:Get(), 1), "default scale at reference is 1.0")
	expect(Responsive.Breakpoint:Get() == "Desktop", "default breakpoint is desktop")
	local display = Responsive.DisplaySize:Get()
	expect(
		display == "Small" or display == "Medium" or display == "Large",
		"displaySize is a known size"
	)
	local mode = Responsive.Input:Get()
	expect(mode == "Keyboard" or mode == "Touch" or mode == "Gamepad", "input is a known mode")
	expect(type(Responsive.ReducedMotion:Get()) == "boolean", "reducedMotion is a boolean")
	local transparency = Responsive.PreferredTransparency:Get()
	expect(
		type(transparency) == "number" and transparency >= 0 and transparency <= 1,
		"preferredTransparency is within [0, 1]"
	)
	local size = Responsive.TextSize:Get()
	expect(
		size == "Medium" or size == "Large" or size == "Larger" or size == "Largest",
		"textSize is a known size"
	)
	if not IS_ROBLOX then
		expect(display == "Medium", "default displaySize is Medium")
		expect(mode == "Keyboard", "default input is keyboard")
		expect(Responsive.ReducedMotion:Get() == false, "default reducedMotion is false")
		expect(approx(transparency, 1), "default preferredTransparency is 1")
		expect(size == "Medium", "default textSize is Medium")
	end
end)

test("responsive · scale & breakpoint nodes react to viewport writes", function()

	Responsive.Viewport:Set({ X = 800, Y = 600 } :: any)
	expect(
		approx(Responsive.Scale:Get(), 800 / 1920),
		"scale recomputes from viewport (pull-based)"
	)
	expect(Responsive.Breakpoint:Get() == "Tablet", "800 wide → tablet")
	Responsive.Viewport:Set({ X = 500, Y = 900 } :: any)
	expect(Responsive.Breakpoint:Get() == "Phone", "500 wide → phone")
end)

test("responsive · scaleOf / breakpointOf escape hatches use merged config", function()
	Responsive.Viewport:Set({ X = 1280, Y = 720 } :: any)
	local s = Responsive.ScaleOf({ Mode = "Width" })
	expect(approx(s:Get(), 1280 / 1920), "scaleOf overrides mode")
	local b = Responsive.BreakpointOf({ Breakpoints = { Phone = 400, Tablet = 800 } })
	expect(b:Get() == "Desktop", "breakpointOf overrides thresholds (1280 ≥ 800)")
	s:Destroy()
	b:Destroy()
end)

test(
	"responsive · scaleOf/breakpointOf accept a custom viewport source (container queries)",
	function()

		local container = Flux({ X = 400, Y = 300 } :: any)
		local s =
			Responsive.ScaleOf({ Viewport = container, Reference = { X = 800, Y = 600 } :: any })
		local b = Responsive.BreakpointOf({
			Viewport = container,
			Breakpoints = { Phone = 500, Tablet = 700 },
		})

		expect(approx(s:Get(), 0.5), "scale derives from the container, not the global viewport")
		expect(b:Get() == "Phone", "breakpoint derives from the container width")

		container({ X = 800, Y = 600 } :: any)
		expect(approx(s:Get(), 1), "scale tracks container resizes")
		expect(b:Get() == "Desktop", "breakpoint tracks container resizes")

		local fn = Responsive.BreakpointOf({
			Viewport = function()
				return { X = container().X / 2, Y = 0 } :: any
			end,
		})
		expect(fn:Get() == "Phone", "a function source works too")

		s:Destroy()
		b:Destroy()
		fn:Destroy()
	end
)

test("responsive · platform resolves to a device class", function()
	local platform = Responsive.Platform:Get()
	expect(
		platform == "Desktop" or platform == "Mobile" or platform == "Console" or platform == "VirtualReality",
		"platform is a known device class"
	)
	if not IS_ROBLOX then
		expect(platform == "Desktop", "headless defaults to pc")
	end
end)

rtest("responsive · scale node drives a real UIScale from viewport", function()
	local uiScale
	local s = Flux.Scope(function()
		Responsive.Viewport:Set(Vector2.new(960, 540))
		uiScale = Flux.New("UIScale")({ Scale = Responsive.Scale })
	end)
	flush()
	expect(approx(uiScale.Scale, 0.5), "UIScale tracks scale node (960x540 → 0.5)")
	Responsive.Viewport:Set(Vector2.new(1920, 1080))
	flush()
	expect(approx(uiScale.Scale, 1), "UIScale updates on viewport change")
	s:Destroy()
end)

test("responsive · scaleOf clamps zero reference dimensions to 1 to avoid NaN/inf", function()
	local s = Responsive.ScaleOf({
		Viewport = Flux({ X = 0, Y = 0 } :: any),
		Reference = { X = 0, Y = 0 } :: any,
	})
	local val = s:Get()
	expect(
		val == val and val ~= math.huge and approx(val, 0),
		"0/max(0,1) produces finite 0 instead of NaN"
	)
	s:Destroy()
end)

return {}
