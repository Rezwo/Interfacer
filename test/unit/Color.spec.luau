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
local Color = Flux.Color
local Compatibility = if IS_ROBLOX then nil else require("../../src/Compatibility") :: any
local Color3 = if IS_ROBLOX then Color3 else Compatibility.Color3
local Vector3 = if IS_ROBLOX then Vector3 else Compatibility.Vector3

local approx = sert.approx

local function rgbApprox(a, b, eps)
	return approx(a.R, b.R, eps) and approx(a.G, b.G, eps) and approx(a.B, b.B, eps)
end

test("color · Oklab fromRGB/toRGB round-trips per channel", function()
	local cases = {
		Color3.new(0, 0, 0),
		Color3.new(1, 1, 1),
		Color3.new(0.5, 0.5, 0.5),
		Color3.new(1, 0, 0),
		Color3.new(0, 1, 0),
		Color3.new(0, 0, 1),
		Color3.new(0.2, 0.6, 0.9),
	}
	for _, c in cases do
		local lab = Color.Oklab.FromRgb(c)

		local back = Color.Oklab.ToRgb(lab, false)
		expect(approx(back.R, c.R, 1e-4), `R round-trip for {c}: got {back.R} expected {c.R}`)
		expect(approx(back.G, c.G, 1e-4), `G round-trip for {c}: got {back.G} expected {c.G}`)
		expect(approx(back.B, c.B, 1e-4), `B round-trip for {c}: got {back.B} expected {c.B}`)
	end
end)

test("color · Oklab fromLinear/toLinear round-trips per channel", function()
	local cases = {
		Color3.new(0, 0, 0),
		Color3.new(1, 1, 1),
		Color3.new(0.25, 0.5, 0.75),
		Color3.new(0.8, 0.1, 0.3),
	}
	for _, c in cases do
		local lab = Color.Oklab.FromLinear(c)

		local back = Color.Oklab.ToLinear(lab, false)
		expect(approx(back.R, c.R, 1e-4), `linear R round-trip for {c}: got {back.R}`)
		expect(approx(back.G, c.G, 1e-4), `linear G round-trip for {c}: got {back.G}`)
		expect(approx(back.B, c.B, 1e-4), `linear B round-trip for {c}: got {back.B}`)
	end
end)

test("color · Oklab known values for linear black and white", function()

	local white = Color.Oklab.FromLinear(Color3.new(1, 1, 1))
	expect(approx(white.X, 1, 1e-4), `white L should be 1, got {white.X}`)
	expect(approx(white.Y, 0, 1e-4), `white a should be 0, got {white.Y}`)
	expect(approx(white.Z, 0, 1e-4), `white b should be 0, got {white.Z}`)

	local black = Color.Oklab.FromLinear(Color3.new(0, 0, 0))
	expect(approx(black.X, 0, 1e-6), `black L should be 0, got {black.X}`)
	expect(approx(black.Y, 0, 1e-6), `black a should be 0, got {black.Y}`)
	expect(approx(black.Z, 0, 1e-6), `black b should be 0, got {black.Z}`)
end)

test("color · sRGB fromLinear/toLinear round-trip and endpoints", function()

	local cases = {
		Color3.new(0, 0, 0),
		Color3.new(1, 1, 1),
		Color3.new(0.001, 0.5, 0.95),
		Color3.new(0.2, 0.4, 0.8),
	}
	for _, c in cases do
		local round = Color.Srgb.ToLinear(Color.Srgb.FromLinear(c))
		expect(
			rgbApprox(round, c, 1e-5),
			`sRGB toLinear∘fromLinear round-trip for {c}: got {round}`
		)

		local round2 = Color.Srgb.FromLinear(Color.Srgb.ToLinear(c))
		expect(
			rgbApprox(round2, c, 1e-5),
			`sRGB fromLinear∘toLinear round-trip for {c}: got {round2}`
		)
	end

	expect(
		rgbApprox(Color.Srgb.FromLinear(Color3.new(0, 0, 0)), Color3.new(0, 0, 0), 1e-7),
		"fromLinear black"
	)
	expect(
		rgbApprox(Color.Srgb.FromLinear(Color3.new(1, 1, 1)), Color3.new(1, 1, 1), 1e-7),
		"fromLinear white"
	)
	expect(
		rgbApprox(Color.Srgb.ToLinear(Color3.new(0, 0, 0)), Color3.new(0, 0, 0), 1e-7),
		"toLinear black"
	)
	expect(
		rgbApprox(Color.Srgb.ToLinear(Color3.new(1, 1, 1)), Color3.new(1, 1, 1), 1e-7),
		"toLinear white"
	)
end)

test("color · sRGB fromLinear matches a known mid-grey value", function()

	local encoded = Color.Srgb.FromLinear(Color3.new(0.5, 0.5, 0.5))
	expect(
		approx(encoded.R, 0.7353569830, 1e-6),
		`sRGB encode of 0.5 should be ~0.73536, got {encoded.R}`
	)

	local decoded = Color.Srgb.ToLinear(Color3.new(0.7353569830, 0.7353569830, 0.7353569830))
	expect(approx(decoded.R, 0.5, 1e-6), `sRGB decode should be ~0.5, got {decoded.R}`)
end)

test("color · lighten adjusts Oklab L and negative delta darkens", function()
	local c = Color3.new(0.4, 0.55, 0.7)
	local lab = Color.Oklab.FromRgb(c)
	expect(approx(Color.Oklab.Lighten(lab, 0.1).X, lab.X + 0.1, 1e-6), "lighten adds to L")

	expect(
		Color.Oklab.Lighten(Color.Oklab.FromRgb(Color3.new(1, 1, 1)), 0.5).X <= 1,
		"L clamps at 1"
	)

	local back = Color.Lighten(Color.Lighten(c, 0.1), -0.1)
	expect(rgbApprox(back, c, 1e-3), `lighten(+0.1)∘lighten(-0.1) ≈ identity, got {back}`)
end)

test("color · saturate adjusts chroma and negative delta desaturates", function()
	local c = Color3.new(0.6, 0.3, 0.4)
	local lab = Color.Oklab.FromRgb(c)
	local chroma = math.sqrt(lab.Y ^ 2 + lab.Z ^ 2)
	local sat = Color.Oklab.Saturate(lab, 0.05)
	expect(approx(math.sqrt(sat.Y ^ 2 + sat.Z ^ 2), chroma + 0.05, 1e-6), "saturate adds to chroma")
	local desat = Color.Oklab.Saturate(lab, -0.05)
	expect(
		approx(math.sqrt(desat.Y ^ 2 + desat.Z ^ 2), chroma - 0.05, 1e-6),
		"negative saturate reduces chroma"
	)

	expect(approx(sat.Y * lab.Z, sat.Z * lab.Y, 1e-9), "saturate preserves hue direction")

	local gray = Color.Oklab.FromRgb(Color3.new(0.5, 0.5, 0.5))
	local stillGray = Color.Oklab.Saturate(gray, 0.1)
	expect(approx(stillGray.Y, 0, 1e-6) and approx(stillGray.Z, 0, 1e-6), "cannot saturate a gray")
end)

test("color · rotateHue rotates around the wheel", function()
	local lab = Color.Oklab.FromRgb(Color3.new(0.8, 0.2, 0.2))

	local full = Color.Oklab.RotateHue(lab, 360)
	expect(
		approx(full.Y, lab.Y, 1e-5) and approx(full.Z, lab.Z, 1e-5),
		"rotateHue 360° ≈ identity"
	)

	local rot = Color.Oklab.RotateHue(lab, 90)
	expect(approx(rot.X, lab.X, 1e-9), "rotateHue preserves L")
	expect(
		approx(math.sqrt(rot.Y ^ 2 + rot.Z ^ 2), math.sqrt(lab.Y ^ 2 + lab.Z ^ 2), 1e-6),
		"rotateHue preserves chroma"
	)
	local h1 = math.deg(math.atan2(lab.Z, lab.Y))
	local h2 = math.deg(math.atan2(rot.Z, rot.Y))
	local dh = (h2 - h1) % 360
	expect(approx(dh, 90, 1e-3), `hue advances 90°, got {dh}`)
	local rotatedColor = Color.RotateHue(Color3.new(0.8, 0.2, 0.2), 360)
	expect(
		rgbApprox(rotatedColor, Color3.new(0.8, 0.2, 0.2), 1e-3),
		"Color.rotateHue 360° round-trips"
	)
end)

test("color · grayscale removes chroma and preserves L", function()
	local lab = Color.Oklab.FromRgb(Color3.new(0.2, 0.7, 0.5))
	local gray = Color.Oklab.Grayscale(lab)
	expect(approx(gray.Y, 0, 1e-9) and approx(gray.Z, 0, 1e-9), "grayscale zeroes chroma")
	expect(approx(gray.X, lab.X, 1e-9), "grayscale preserves L")

	local c = Color.Grayscale(Color3.new(0.2, 0.7, 0.5))
	expect(
		approx(c.R, c.G, 1e-3) and approx(c.G, c.B, 1e-3),
		`grayscale Color3 is neutral, got {c}`
	)
end)

test("color · mix matches the engine's lab-lerp path", function()
	local a = Color3.new(0.9, 0.1, 0.1)
	local b = Color3.new(0.1, 0.1, 0.9)

	expect(rgbApprox(Color.Mix(a, b, 0), a, 1e-4), "mix t=0 is a")
	expect(rgbApprox(Color.Mix(a, b, 1), b, 1e-4), "mix t=1 is b")

	local expected = Color.Oklab.ToRgb(Color.Oklab.FromRgb(a):Lerp(Color.Oklab.FromRgb(b), 0.5))
	expect(rgbApprox(Color.Mix(a, b, 0.5), expected, 1e-6), "mix midpoint is the lab midpoint")
end)

test("color · luminance and contrast follow WCAG", function()
	expect(approx(Color.Luminance(Color3.new(1, 1, 1)), 1, 1e-6), "white luminance is 1")
	expect(approx(Color.Luminance(Color3.new(0, 0, 0)), 0, 1e-6), "black luminance is 0")

	expect(
		approx(Color.Contrast(Color3.new(1, 1, 1), Color3.new(0, 0, 0)), 21, 1e-4),
		"white/black contrast is 21"
	)
	expect(
		approx(Color.Contrast(Color3.new(0, 0, 0), Color3.new(1, 1, 1)), 21, 1e-4),
		"contrast is symmetric"
	)
	local c = Color3.new(0.3, 0.6, 0.9)
	expect(approx(Color.Contrast(c, c), 1, 1e-9), "contrast with self is 1")
end)

test("color · readable picks the more legible text colour", function()
	local white = Color3.new(1, 1, 1)
	local black = Color3.new(0, 0, 0)
	expect(Color.Readable(white) == black, "black text on white")
	expect(Color.Readable(black) == white, "white text on black")

	local navy = Color3.new(0.05, 0.05, 0.3)
	expect(
		Color.Readable(Color3.new(0.95, 0.95, 0.8), navy, white) == navy,
		"picks the higher-contrast candidate"
	)
end)

test("color · gamut clip keeps colours in range and preserves hue", function()

	local pushed = Color.Saturate(Color3.new(1, 0, 0), 0.3)
	expect(pushed.R >= 0 and pushed.R <= 1, `clip R in range, got {pushed.R}`)
	expect(pushed.G >= 0 and pushed.G <= 1, `clip G in range, got {pushed.G}`)
	expect(pushed.B >= 0 and pushed.B <= 1, `clip B in range, got {pushed.B}`)

	local outOfGamut = Vector3.new(0.7, 0.3, 0.1)
	local clipped = Color.Oklab.ToRgb(outOfGamut, true)
	local hueIn = math.deg(math.atan2(outOfGamut.Z, outOfGamut.Y)) % 360
	local labOut = Color.Oklab.FromRgb(clipped)
	local hueOut = math.deg(math.atan2(labOut.Z, labOut.Y)) % 360
	local dh = math.abs(hueIn - hueOut)
	dh = math.min(dh, 360 - dh)
	expect(dh < 2, `gamut clip preserves hue within 2°, got {dh}`)
end)

return {}
