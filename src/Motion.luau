--!strict

const Clock = require("./Clock")
const Compatibility = require("./Compatibility")
const Graph = require("./Graph")

local IsRoblox = Compatibility.IsRoblox
local Color3 = Compatibility.Color3
local ColorSequence = Compatibility.ColorSequence
local ColorSequenceKeypoint = Compatibility.ColorSequenceKeypoint
local Enum = Compatibility.Enum
local NumberSequence = Compatibility.NumberSequence
local NumberSequenceKeypoint = Compatibility.NumberSequenceKeypoint
local TweenInfo = Compatibility.TweenInfo
local UDim = Compatibility.UDim
local UDim2 = Compatibility.UDim2
local Vector2 = Compatibility.Vector2
local Vector3 = Compatibility.Vector3
local CompatibleTypeOf = Compatibility.TypeOf
local ReportWarning = Compatibility.Warn

local ReadClock = Clock.Now
local CreateEffect = Graph.Effect
local IsDynamicValue = Graph.IsDynamic
local ReadRawValue = Graph.Raw
local ReadReactiveValue = Graph.Read
local StateMetatable : any = getmetatable(Graph.State(nil) :: any)
local GetStateValue = StateMetatable.Get
local SetNodeValue = StateMetatable.Set

type Reactive<ValueType> = Graph.Reactive<ValueType>

type Unwrap<ValueType> = Graph.Unwrap<ValueType>

export type Spring<ValueType> = Graph.Node<ValueType> & {

	Impulse : (Self : any, Delta : ValueType) -> (),

	SetVelocity : (Self : any, Velocity : ValueType) -> (),

	SetCurrent : (Self : any, AnimatedValue : ValueType) -> (),

	Snap : (Self : any, AnimatedValue : ValueType) -> (),
}

local function FromLinear(ComponentValue : number) : number
	return if ComponentValue < 0.0031308
		then ComponentValue * 12.92
		else ComponentValue ^ (1 / 2.4) * 1.055 - 0.055
end

local function ToLinear(ComponentValue : number) : number
	return if ComponentValue < 0.04045
		then ComponentValue / 12.92
		else ((ComponentValue + 0.055) / 1.055) ^ 2.4
end

local SrgbColorSpace = table.freeze({

	FromLinear = function(ColorValue : Color3) : Color3
		return Color3.new(
			FromLinear(ColorValue.R),
			FromLinear(ColorValue.G),
			FromLinear(ColorValue.B)
		)
	end,

	ToLinear = function(ColorValue : Color3) : Color3
		return Color3.new(ToLinear(ColorValue.R), ToLinear(ColorValue.G), ToLinear(ColorValue.B))
	end,
})

const function OklabToLinearRgb(
	Lightness : number,
	OpponentComponentA : number,
	OpponentComponentB : number
) : (number, number, number)
	local LightnessRoot = Lightness
		+ 0.3963377774 * OpponentComponentA
		+ 0.2158037573 * OpponentComponentB
	local MiddleRoot = Lightness
		- 0.1055613458 * OpponentComponentA
		- 0.0638541728 * OpponentComponentB
	local ShortRoot = Lightness
		- 0.0894841775 * OpponentComponentA
		- 1.2914855480 * OpponentComponentB
	local LightnessValue, MiddleComponent, SourceValue =
		LightnessRoot * LightnessRoot * LightnessRoot,
		MiddleRoot * MiddleRoot * MiddleRoot,
		ShortRoot * ShortRoot * ShortRoot
	return 4.0767416621 * LightnessValue
		- 3.3077115913 * MiddleComponent
		+ 0.2309699292 * SourceValue,
		-1.2684380046 * LightnessValue + 2.6097574011 * MiddleComponent - 0.3413193965 * SourceValue,
		-0.0041960863 * LightnessValue - 0.7034186147 * MiddleComponent + 1.7076147010 * SourceValue
end

const GamutTolerance = 1e-5

const function LinearToOklab(
	RedComponent : number,
	GreenComponent : number,
	BlueComponent : number
) : (number, number, number)
	local LightnessRoot = (
		RedComponent * 0.4122214708
		+ GreenComponent * 0.5363325363
		+ BlueComponent * 0.0514459929
	) ^ (1 / 3)
	local MiddleRoot = (
		RedComponent * 0.2119034982
		+ GreenComponent * 0.6806995451
		+ BlueComponent * 0.1073969566
	) ^ (1 / 3)
	local ShortRoot = (
		RedComponent * 0.0883024619
		+ GreenComponent * 0.2817188376
		+ BlueComponent * 0.6299787005
	) ^ (1 / 3)
	return LightnessRoot * 0.2104542553 + MiddleRoot * 0.7936177850 - ShortRoot * 0.0040720468,
		LightnessRoot * 1.9779984951 - MiddleRoot * 2.4285922050 + ShortRoot * 0.4505937099,
		LightnessRoot * 0.0259040371 + MiddleRoot * 0.7827717662 - ShortRoot * 0.8086757660
end

const function RgbToOklab(RgbColor : Color3) : (number, number, number)
	return LinearToOklab(ToLinear(RgbColor.R), ToLinear(RgbColor.G), ToLinear(RgbColor.B))
end

const function OklabComponentsToLinear(
	Lightness : number,
	OpponentComponentA : number,
	OpponentComponentB : number,
	Clamped : boolean?
) : (number, number, number)
	local RedValue, GreenValue, SecondValue =
		OklabToLinearRgb(Lightness, OpponentComponentA, OpponentComponentB)
	if
		Clamped ~= false
		and (
			RedValue < 0
			or GreenValue < 0
			or SecondValue < 0
			or RedValue > 1
			or GreenValue > 1
			or SecondValue > 1
		)
	then
		if
			RedValue >= -GamutTolerance
			and GreenValue >= -GamutTolerance
			and SecondValue >= -GamutTolerance
			and RedValue <= 1 + GamutTolerance
			and GreenValue <= 1 + GamutTolerance
			and SecondValue <= 1 + GamutTolerance
		then
			return math.clamp(RedValue, 0, 1),
				math.clamp(GreenValue, 0, 1),
				math.clamp(SecondValue, 0, 1)
		end
		local ClampedLightness = math.clamp(Lightness, 0, 1)
		local LowerBound, UpperBound = 0, 1
		for _ = 1, 12 do
			local MiddleValue = (LowerBound + UpperBound) / 2
			local CandidateRed, CandidateGreen, CandidateBlue = OklabToLinearRgb(
				ClampedLightness,
				OpponentComponentA * MiddleValue,
				OpponentComponentB * MiddleValue
			)
			if
				CandidateRed >= 0
				and CandidateGreen >= 0
				and CandidateBlue >= 0
				and CandidateRed <= 1
				and CandidateGreen <= 1
				and CandidateBlue <= 1
			then
				LowerBound = MiddleValue
			else
				UpperBound = MiddleValue
			end
		end
		RedValue, GreenValue, SecondValue = OklabToLinearRgb(
			ClampedLightness,
			OpponentComponentA * LowerBound,
			OpponentComponentB * LowerBound
		)
	end
	return RedValue, GreenValue, SecondValue
end

const function OklabToSrgb(
	Lightness : number,
	OpponentComponentA : number,
	OpponentComponentB : number,
	Clamped : boolean?
) : Color3
	local RedValue, GreenValue, SecondValue =
		OklabComponentsToLinear(Lightness, OpponentComponentA, OpponentComponentB, Clamped)
	return Color3.new(FromLinear(RedValue), FromLinear(GreenValue), FromLinear(SecondValue))
end

local Oklab = {}

function Oklab.FromLinear(ColorValue : Color3) : Vector3
	return Vector3.new(LinearToOklab(ColorValue.R, ColorValue.G, ColorValue.B))
end

function Oklab.ToLinear(ColorValue : Vector3, Clamped : boolean?) : Color3
	return Color3.new(OklabComponentsToLinear(ColorValue.X, ColorValue.Y, ColorValue.Z, Clamped))
end

function Oklab.FromRgb(RgbColor : Color3) : Vector3
	return Vector3.new(RgbToOklab(RgbColor))
end

function Oklab.ToRgb(LabColor : Vector3, Clamped : boolean?) : Color3
	return OklabToSrgb(LabColor.X, LabColor.Y, LabColor.Z, Clamped)
end

function Oklab.Lighten(LabColor : Vector3, Amount : number) : Vector3
	return Vector3.new(math.clamp(LabColor.X + Amount, 0, 1), LabColor.Y, LabColor.Z)
end

function Oklab.Saturate(LabColor : Vector3, Amount : number) : Vector3
	local FirstValue, SecondValue = LabColor.Y, LabColor.Z
	local ComponentValue = math.sqrt(FirstValue * FirstValue + SecondValue * SecondValue)
	if ComponentValue < 1e-6 then
		return LabColor
	end
	local ChromaScale = math.max(ComponentValue + Amount, 0) / ComponentValue
	return Vector3.new(LabColor.X, FirstValue * ChromaScale, SecondValue * ChromaScale)
end

function Oklab.RotateHue(LabColor : Vector3, Degrees : number) : Vector3
	local RedValue = math.rad(Degrees)
	local CosineOfAngle, SineOfAngle = math.cos(RedValue), math.sin(RedValue)
	local FirstValue, SecondValue = LabColor.Y, LabColor.Z
	return Vector3.new(
		LabColor.X,
		FirstValue * CosineOfAngle - SecondValue * SineOfAngle,
		FirstValue * SineOfAngle + SecondValue * CosineOfAngle
	)
end

function Oklab.Grayscale(LabColor : Vector3) : Vector3
	return Vector3.new(LabColor.X, 0, 0)
end

function Oklab.Mix(FirstLabColor : Vector3, SecondLabColor : Vector3, Alpha : number) : Vector3
	return FirstLabColor:Lerp(SecondLabColor, Alpha)
end

local Color = {
	Oklab = table.freeze(Oklab),
	Srgb = SrgbColorSpace,
}

function Color.Lighten(ComponentValue : Color3, Amount : number) : Color3
	local Lightness, FirstValue, SecondValue = RgbToOklab(ComponentValue)
	return OklabToSrgb(math.clamp(Lightness + Amount, 0, 1), FirstValue, SecondValue)
end

function Color.Saturate(ComponentValue : Color3, Amount : number) : Color3
	local Lightness, FirstValue, SecondValue = RgbToOklab(ComponentValue)
	local Chroma = math.sqrt(FirstValue * FirstValue + SecondValue * SecondValue)
	if Chroma < 1e-6 then
		return OklabToSrgb(Lightness, FirstValue, SecondValue)
	end
	local ChromaScale = math.max(Chroma + Amount, 0) / Chroma
	return OklabToSrgb(Lightness, FirstValue * ChromaScale, SecondValue * ChromaScale)
end

function Color.RotateHue(ComponentValue : Color3, Degrees : number) : Color3
	local Lightness, FirstValue, SecondValue = RgbToOklab(ComponentValue)
	local RedValue = math.rad(Degrees)
	local CosineOfAngle, SineOfAngle = math.cos(RedValue), math.sin(RedValue)
	return OklabToSrgb(
		Lightness,
		FirstValue * CosineOfAngle - SecondValue * SineOfAngle,
		FirstValue * SineOfAngle + SecondValue * CosineOfAngle
	)
end

function Color.Grayscale(ComponentValue : Color3) : Color3
	local Lightness = RgbToOklab(ComponentValue)
	return OklabToSrgb(Lightness, 0, 0)
end

function Color.Mix(FirstValue : Color3, SecondValue : Color3, Progress : number) : Color3
	local FirstLightness, FirstOpponentComponentA, FirstOpponentComponentB = RgbToOklab(FirstValue)
	local SecondLightness, SecondOpponentComponentA, SecondOpponentComponentB =
		RgbToOklab(SecondValue)
	return OklabToSrgb(
		FirstLightness + (SecondLightness - FirstLightness) * Progress,
		FirstOpponentComponentA + (SecondOpponentComponentA - FirstOpponentComponentA) * Progress,
		FirstOpponentComponentB + (SecondOpponentComponentB - FirstOpponentComponentB) * Progress
	)
end

function Color.Luminance(ComponentValue : Color3) : number
	return 0.2126 * ToLinear(ComponentValue.R)
		+ 0.7152 * ToLinear(ComponentValue.G)
		+ 0.0722 * ToLinear(ComponentValue.B)
end

const function ContrastLuminance(FirstLuminance : number, SecondLuminance : number) : number
	return (math.max(FirstLuminance, SecondLuminance) + 0.05)
		/ (math.min(FirstLuminance, SecondLuminance) + 0.05)
end

function Color.Contrast(FirstValue : Color3, SecondValue : Color3) : number
	return ContrastLuminance(Color.Luminance(FirstValue), Color.Luminance(SecondValue))
end

local BlackColor = Color3.new(0, 0, 0)
local WhiteColor = Color3.new(1, 1, 1)

function Color.Readable(BackgroundColor : Color3, Dark : Color3?, Light : Color3?) : Color3
	local DarkCandidate = Dark or BlackColor
	local LightnessValue = Light or WhiteColor
	local BackgroundLuminance = Color.Luminance(BackgroundColor)
	return if ContrastLuminance(BackgroundLuminance, Color.Luminance(DarkCandidate))
			>= ContrastLuminance(BackgroundLuminance, Color.Luminance(LightnessValue))
		then DarkCandidate
		else LightnessValue
end

table.freeze(Color)

export type Animatable =
	number
	& vector
	& CFrame
	& Color3
	& ColorSequence
	& ColorSequenceKeypoint
	& NumberRange
	& NumberSequence
	& NumberSequenceKeypoint
	& Rect
	& UDim
	& UDim2
	& Vector2
	& Vector3

local Round = math.round
local Maximum = math.max
local CreateColor3 = Color3.new
local CreateColorSequence = ColorSequence.new
local CreateColorKeypoint = ColorSequenceKeypoint.new
local CreateNumberSequence = NumberSequence.new
local CreateNumberKeypoint = NumberSequenceKeypoint.new
local CreateUDim = UDim.new
local CreateUDim2 = UDim2.new
local CreateVector2 = Vector2.new
local CreateVector3 = Vector3.new

const function CreateRgbFromOklab(
	Lightness : number,
	OpponentComponentA : number,
	OpponentComponentB : number,
	Clamped : boolean
) : Color3
	local RedValue, GreenValue, SecondValue =
		OklabComponentsToLinear(Lightness, OpponentComponentA, OpponentComponentB, Clamped)
	return CreateColor3(
		Maximum(FromLinear(RedValue), 0),
		Maximum(FromLinear(GreenValue), 0),
		Maximum(FromLinear(SecondValue), 0)
	)
end

local Packers : { [string] : ({ number }, any) -> () } = {
	number = function(Value, AnimatedValue : number)
		Value[1] = AnimatedValue
	end,
	vector = function(Value, AnimatedValue : vector)
		Value[1], Value[2], Value[3] = AnimatedValue.x, AnimatedValue.y, AnimatedValue.z
	end,
	Color3 = function(Progress, Value : Color3)
		Progress[1], Progress[2], Progress[3] = RgbToOklab(Value)
	end,
	ColorSequence = function(Progress, Value : ColorSequence)
		for Index, Key in Value.Keypoints do
			local Base = (Index - 1) * 4
			Progress[Base + 1], Progress[Base + 2], Progress[Base + 3], Progress[Base + 4] =
				Key.Time, RgbToOklab(Key.Value)
		end
	end,
	ColorSequenceKeypoint = function(Progress, Value : ColorSequenceKeypoint)
		Progress[1], Progress[2], Progress[3], Progress[4] = Value.Time, RgbToOklab(Value.Value)
	end,
	NumberSequence = function(Progress, Value : NumberSequence)
		for Index, Key in Value.Keypoints do
			local Base = (Index - 1) * 3
			Progress[Base + 1], Progress[Base + 2], Progress[Base + 3] =
				Key.Time, Key.Value, Key.Envelope
		end
	end,
	NumberSequenceKeypoint = function(Progress, Value : NumberSequenceKeypoint)
		Progress[1], Progress[2], Progress[3] = Value.Time, Value.Value, Value.Envelope
	end,
	UDim = function(Progress, Value : UDim)
		Progress[1], Progress[2] = Value.Scale, Value.Offset
	end,
	UDim2 = function(Progress, Value : UDim2)
		Progress[1], Progress[2], Progress[3], Progress[4] =
			Value.X.Scale, Value.X.Offset, Value.Y.Scale, Value.Y.Offset
	end,
	Vector2 = function(Progress, Value : Vector2)
		Progress[1], Progress[2] = Value.X, Value.Y
	end,
	Vector3 = function(Progress, Value : Vector3)
		Progress[1], Progress[2], Progress[3] = Value.X, Value.Y, Value.Z
	end,
}

local Unpackers : { [string] : ({ number }) -> any } = {
	number = function(Value) : number
		return Value[1]
	end,
	vector = function(Value) : vector
		return vector.create(Value[1], Value[2], Value[3])
	end,
	Color3 = function(Progress) : Color3
		return CreateRgbFromOklab(Progress[1], Progress[2], Progress[3], false)
	end,
	ColorSequence = function(Progress) : ColorSequence
		local Count = #Progress // 4
		local Key = table.create(Count) :: { ColorSequenceKeypoint }
		for Index = 1, Count do
			local Base = (Index - 1) * 4
			Key[Index] = CreateColorKeypoint(
				Progress[Base + 1],
				CreateRgbFromOklab(Progress[Base + 2], Progress[Base + 3], Progress[Base + 4], true)
			)
		end
		return CreateColorSequence(Key)
	end,
	ColorSequenceKeypoint = function(Progress) : ColorSequenceKeypoint
		return CreateColorKeypoint(
			Progress[1],
			CreateRgbFromOklab(Progress[2], Progress[3], Progress[4], false)
		)
	end,
	NumberSequence = function(Progress) : NumberSequence
		local Count = #Progress // 3
		local Key = table.create(Count) :: { NumberSequenceKeypoint }
		for Index = 1, Count do
			local Base = (Index - 1) * 3
			Key[Index] =
				CreateNumberKeypoint(Progress[Base + 1], Progress[Base + 2], Progress[Base + 3])
		end
		return CreateNumberSequence(Key)
	end,
	NumberSequenceKeypoint = function(Progress) : NumberSequenceKeypoint
		return CreateNumberKeypoint(Progress[1], Progress[2], Progress[3])
	end,
	UDim = function(Progress) : UDim
		return CreateUDim(Progress[1], Round(Progress[2]))
	end,
	UDim2 = function(Progress) : UDim2
		return CreateUDim2(Progress[1], Round(Progress[2]), Progress[3], Round(Progress[4]))
	end,
	Vector2 = function(Progress) : Vector2
		return CreateVector2(Progress[1], Progress[2])
	end,
	Vector3 = function(Progress) : Vector3
		return CreateVector3(Progress[1], Progress[2], Progress[3])
	end,
}

if IsRoblox then
	local CreateCFrame = CFrame.new
	local CreateCFrameFromAxisAngle = CFrame.fromAxisAngle
	local CreateNumberRange = NumberRange.new
	local CreateRect = Rect.new

	Packers.CFrame = function(Progress, Value : CFrame)
		local Position, FirstValue = Value:ToAxisAngle()
		Progress[1], Progress[2], Progress[3], Progress[4], Progress[5], Progress[6], Progress[7] =
			Value.X, Value.Y, Value.Z, Position.X, Position.Y, Position.Z, FirstValue
	end
	Packers.NumberRange = function(Progress, Value : NumberRange)
		Progress[1], Progress[2] = Value.Min, Value.Max
	end
	Packers.Rect = function(Progress, Value : Rect)
		Progress[1], Progress[2], Progress[3], Progress[4] =
			Value.Min.X, Value.Min.Y, Value.Max.X, Value.Max.Y
	end

	Unpackers.CFrame = function(Progress) : CFrame
		local Position, FirstValue =
			CreateCFrame(Progress[1], Progress[2], Progress[3]),
			CreateVector3(Progress[4], Progress[5], Progress[6])
		return if FirstValue.Magnitude < 1e-6
			then Position
			else Position * CreateCFrameFromAxisAngle(FirstValue, Progress[7])
	end
	Unpackers.NumberRange = function(Progress) : NumberRange
		return CreateNumberRange(Progress[1], Progress[2])
	end
	Unpackers.Rect = function(Progress) : Rect
		return CreateRect(Progress[1], Progress[2], Progress[3], Progress[4])
	end
end

local DataTypes = table.freeze({
	Unpacker = function(Progress : string) : (({ number }) -> any)?
		return Unpackers[Progress]
	end,
	Pack = function(Components : { number }, AnimatedValue : Animatable, Progress : string)
		table.clear(Components)
		local Pack = Packers[Progress]
		if Pack then
			Pack(Components, AnimatedValue)
		end
		return Components
	end,
})

export type Curve = (Alpha : number) -> number

local SineOfAngle, CosineOfAngle, Sqrt, Pi = math.sin, math.cos, math.sqrt, math.pi
const BackOvershoot = 1.70158

const function BounceOut(Progress : number) : number
	if Progress < 1 / 2.75 then
		return 7.5625 * Progress * Progress
	elseif Progress < 2 / 2.75 then
		Progress -= 1.5 / 2.75
		return 7.5625 * Progress * Progress + 0.75
	elseif Progress < 2.5 / 2.75 then
		Progress -= 2.25 / 2.75
		return 7.5625 * Progress * Progress + 0.9375
	else
		Progress -= 2.625 / 2.75
		return 7.5625 * Progress * Progress + 0.984375
	end
end

local Curves : { [string] : { In : Curve, Out : Curve, InOut : Curve? } } = {
	Linear = {
		In = function(Progress)
			return Progress
		end,
		Out = function(Progress)
			return Progress
		end,
	},
	Sine = {
		In = function(Progress)
			return 1 - CosineOfAngle(Progress * Pi / 2)
		end,
		Out = function(Progress)
			return SineOfAngle(Progress * Pi / 2)
		end,
		InOut = function(Progress)
			return (1 - CosineOfAngle(Progress * Pi)) / 2
		end,
	},
	Quad = {
		In = function(Progress)
			return Progress * Progress
		end,
		Out = function(Progress)
			Progress = 1 - Progress
			return 1 - Progress * Progress
		end,
	},
	Cubic = {
		In = function(Progress)
			return Progress * Progress * Progress
		end,
		Out = function(Progress)
			Progress = 1 - Progress
			return 1 - Progress * Progress * Progress
		end,
	},
	Quart = {
		In = function(Progress)
			Progress *= Progress
			return Progress * Progress
		end,
		Out = function(Progress)
			Progress = 1 - Progress
			Progress *= Progress
			return 1 - Progress * Progress
		end,
	},
	Quint = {
		In = function(Progress)
			local SquaredTime = Progress * Progress
			return SquaredTime * SquaredTime * Progress
		end,
		Out = function(Progress)
			Progress = 1 - Progress
			local SquaredTime = Progress * Progress
			return 1 - SquaredTime * SquaredTime * Progress
		end,
	},
	Exponential = {
		In = function(Progress)
			return if Progress == 0 then 0 else 2 ^ (10 * Progress - 10)
		end,
		Out = function(Progress)
			return if Progress == 1 then 1 else 1 - 2 ^ (-10 * Progress)
		end,
	},
	Circular = {
		In = function(Progress)
			return 1 - Sqrt(1 - Progress * Progress)
		end,
		Out = function(Progress)
			Progress = 1 - Progress
			return Sqrt(1 - Progress * Progress)
		end,
	},
	Back = {
		In = function(Progress)
			return Progress * Progress * ((BackOvershoot + 1) * Progress - BackOvershoot)
		end,
		Out = function(Progress)
			Progress -= 1
			return 1 + Progress * Progress * ((BackOvershoot + 1) * Progress + BackOvershoot)
		end,
	},
	Elastic = {
		In = function(Progress)
			if Progress == 0 or Progress == 1 then
				return Progress
			end
			Progress = 1 - Progress
			return 2 ^ (-10 * Progress) * CosineOfAngle(6.5 * Pi * Progress)
		end,
		Out = function(Progress)
			if Progress == 0 or Progress == 1 then
				return Progress
			end
			return 1 - 2 ^ (-10 * Progress) * CosineOfAngle(6.5 * Pi * Progress)
		end,
	},
	Bounce = {
		In = function(Progress)
			return 1 - BounceOut(1 - Progress)
		end,
		Out = BounceOut,
	},
}

const function CreateInOutCurve(EaseIn : Curve, EaseOut : Curve) : Curve
	return function(Progress)
		return if Progress < 0.5
			then EaseIn(2 * Progress) / 2
			else (1 + EaseOut(2 * Progress - 1)) / 2
	end
end

local Styles : { [any] : { [any] : Curve } } = {}
for EasingName, SetMotionValue in Curves do
	local ByDirection : { [any] : Curve } = {
		In = SetMotionValue.In,
		Out = SetMotionValue.Out,
		InOut = SetMotionValue.InOut or CreateInOutCurve(SetMotionValue.In, SetMotionValue.Out),
	}
	if Enum then
		for _, Direction in { "In", "Out", "InOut" } do
			ByDirection[(Enum.EasingDirection :: any)[Direction]] = ByDirection[Direction]
		end
		Styles[(Enum.EasingStyle :: any)[EasingName]] = ByDirection
	end
	Styles[EasingName] = ByDirection
end

const function ItemKey(Item : any) : any
	return if type(Item) == "string" then Item else Item.Name
end

local Easing = {}

function Easing.Curve(Style : any, Direction : any) : Curve
	local ByDirection = Styles[Style] or Styles[ItemKey(Style)]
	if ByDirection == nil then
		error(`Unknown EasingStyle {tostring(Style)}`, 2)
	end
	local EasingCurve = ByDirection[Direction] or ByDirection[ItemKey(Direction)]
	if EasingCurve == nil then
		error(`Unknown EasingDirection {tostring(Direction)}`, 2)
	end
	return EasingCurve
end

function Easing.Get(Alpha : number, Style : any, Direction : any) : number
	return Easing.Curve(Style, Direction)(math.clamp(Alpha, 0, 1))
end

table.freeze(Easing)

local MotionEngine = { Now = 0 }
local LastClock = ReadClock()

const TweenKind = 1
const SpringKind = 2
const MotionTolerance = 1e-4

MotionEngine.TweenKind = TweenKind
MotionEngine.SpringKind = SpringKind

export type Motion = {
	Kind : number,
	Count : number,
	Node : Graph.Node<any>,
	ValueTypeName : string,
	Unpack : ({ number }) -> any,
	Target : { number },
	Value : { number },
}

export type EngineSpring = Motion & {
	Velocity : { number },
	Frequency : number,
	Damping : number,
}

export type Tween = Motion & {
	Information : TweenInfo,
	Ease : Curve,
	StartTime : number,
	RepeatsLeft : number,
	Reversing : boolean,
	Start : { number },
}

local ActiveSprings : { [Motion] : any } = {}
local ActiveTweens : { [Motion] : any } = {}

function MotionEngine.NewSpring(Count : number, TypeString : string, Record : any) : EngineSpring
	return {
		Kind = SpringKind,
		Count = Count,
		Node = Record,
		ValueTypeName = TypeString,
		Unpack = DataTypes.Unpacker(TypeString) :: any,
		Target = table.create(Count, 0),
		Value = table.create(Count, 0),
		Velocity = table.create(Count, 0),
		Frequency = nil :: any,
		Damping = nil :: any,
	}
end

function MotionEngine.NewTween(Count : number, TypeString : string, Record : any) : Tween
	return {
		Kind = TweenKind,
		Count = Count,
		Node = Record,
		ValueTypeName = TypeString,
		Unpack = DataTypes.Unpacker(TypeString) :: any,
		Start = table.create(Count, 0),
		Target = table.create(Count, 0),
		Value = table.create(Count, 0),
		Information = nil :: any,
		Ease = nil :: any,
		StartTime = nil :: any,
		RepeatsLeft = nil :: any,
		Reversing = nil :: any,
	}
end

function MotionEngine.Destroy(MotionRecord : EngineSpring | Tween)
	ActiveSprings[MotionRecord] = nil
	ActiveTweens[MotionRecord] = nil
	table.clear(MotionRecord)
end

function MotionEngine.IsActive(MotionRecord : EngineSpring | Tween) : boolean
	return ActiveSprings[MotionRecord] ~= nil or ActiveTweens[MotionRecord] ~= nil
end

function MotionEngine.SetupSpring(SpringRecord : EngineSpring, Frequency : number?, Damping : number?)
	SpringRecord.Frequency = math.max(Frequency or 1, MotionTolerance)
	SpringRecord.Damping = math.max(Damping or 1, MotionTolerance)
	ActiveSprings[SpringRecord] = SpringRecord.Node
end

MotionEngine.DefaultTweenInfo =
	TweenInfo.new(0.3, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut)

function MotionEngine.SetupTween(TweenRecord : Tween, TweenInformation : TweenInfo?)
	local Information = TweenInformation or MotionEngine.DefaultTweenInfo
	TweenRecord.Information = Information
	TweenRecord.Ease = Easing.Curve(Information.EasingStyle, Information.EasingDirection)
	TweenRecord.StartTime = MotionEngine.Now + Information.DelayTime
	TweenRecord.RepeatsLeft = Information.RepeatCount
	TweenRecord.Reversing = false
	local Start = TweenRecord.Start
	for Index, Value in TweenRecord.Value do
		Start[Index] = Value
	end
	ActiveTweens[TweenRecord] = TweenRecord.Node
end

function MotionEngine.Snap(MotionRecord : EngineSpring | Tween, Components : { number })
	local Target, AnimatedValue = MotionRecord.Target, MotionRecord.Value
	table.clear(Target)
	table.clear(AnimatedValue)
	for Index, Value in Components do
		Target[Index] = Value
		AnimatedValue[Index] = Value
	end
	if MotionRecord.Kind == TweenKind then
		local Start = (MotionRecord :: Tween).Start
		table.clear(Start)
		for Index, Value in Components do
			Start[Index] = Value
		end
	else
		local VelocityComponents = (MotionRecord :: EngineSpring).Velocity
		table.clear(VelocityComponents)
		for Index = 1, #Components do
			VelocityComponents[Index] = 0
		end
	end
	MotionRecord.Count = #Components
	ActiveSprings[MotionRecord] = nil
	ActiveTweens[MotionRecord] = nil
end

function MotionEngine.SetTarget(MotionRecord : EngineSpring | Tween, Components : { number })
	local ActiveMap = ActiveSprings
	if MotionRecord.Kind == TweenKind then
		MotionRecord = MotionRecord :: Tween
		ActiveMap = ActiveTweens
		local Start, AnimatedValue = MotionRecord.Start, MotionRecord.Value
		for Index = 1, #Components do
			Start[Index] = AnimatedValue[Index]
		end
		MotionRecord.StartTime = MotionEngine.Now
		MotionRecord.RepeatsLeft = MotionRecord.Information.RepeatCount
		MotionRecord.Reversing = false
	end

	if #Components ~= MotionRecord.Count then
		MotionEngine.Snap(MotionRecord, Components)
	else
		local Target = MotionRecord.Target
		local Same = MotionRecord.Kind ~= TweenKind and ActiveMap[MotionRecord] == nil
		for Index, Value in Components do
			if Target[Index] ~= Value then
				Same = false
				Target[Index] = Value
			end
		end
		if Same then
			return
		end
	end
	ActiveMap[MotionRecord] = MotionRecord.Node
end

function MotionEngine.AddVelocity(SpringRecord : EngineSpring, Components : { number })
	local VelocityComponents = SpringRecord.Velocity
	for Index = 1, math.min(#Components, SpringRecord.Count) do
		VelocityComponents[Index] += Components[Index]
	end
	ActiveSprings[SpringRecord] = SpringRecord.Node
end

function MotionEngine.SetVelocity(SpringRecord : EngineSpring, Components : { number })
	local VelocityComponents = SpringRecord.Velocity
	for Index = 1, math.min(#Components, SpringRecord.Count) do
		VelocityComponents[Index] = Components[Index]
	end
	ActiveSprings[SpringRecord] = SpringRecord.Node
end

const function StepSpring(MotionRecord : EngineSpring, DeltaTime : number)
	local Frequency, DampingRatio = MotionRecord.Frequency, MotionRecord.Damping
	local AngularFrequency = math.tau * Frequency
	local IsSleeping = true
	local Target, AnimatedValue, CurrentVelocities =
		MotionRecord.Target, MotionRecord.Value, MotionRecord.Velocity

	if DampingRatio == 1 then
		local ExponentialTerm = math.exp(-AngularFrequency * DeltaTime)
		for ComponentValue, Position in AnimatedValue do
			local TargetComponent, CurrentVelocity =
				Target[ComponentValue], CurrentVelocities[ComponentValue]
			local FirstSolutionCoefficient = Position - TargetComponent
			if
				math.abs(FirstSolutionCoefficient) > MotionTolerance
				or math.abs(CurrentVelocity) > MotionTolerance
			then
				IsSleeping = false
				local SecondSolutionCoefficient = CurrentVelocity
					+ AngularFrequency * FirstSolutionCoefficient
				local PositionTerm = FirstSolutionCoefficient
					+ SecondSolutionCoefficient * DeltaTime
				AnimatedValue[ComponentValue] = TargetComponent + PositionTerm * ExponentialTerm
				CurrentVelocities[ComponentValue] = (
					SecondSolutionCoefficient - AngularFrequency * PositionTerm
				) * ExponentialTerm
			end
		end
	elseif DampingRatio < 1 then
		local DampedAngularFrequency = AngularFrequency * math.sqrt(1 - DampingRatio * DampingRatio)
		local DampingRate = AngularFrequency * DampingRatio
		local ExponentialTerm = math.exp(-DampingRate * DeltaTime)
		local Phase = DampedAngularFrequency * DeltaTime
		local CosineTerm, SineTerm = math.cos(Phase), math.sin(Phase)
		for ComponentValue, Position in AnimatedValue do
			local TargetComponent, CurrentVelocity =
				Target[ComponentValue], CurrentVelocities[ComponentValue]
			local FirstSolutionCoefficient = Position - TargetComponent
			if
				math.abs(FirstSolutionCoefficient) > MotionTolerance
				or math.abs(CurrentVelocity) > MotionTolerance
			then
				IsSleeping = false
				local SecondSolutionCoefficient = (
					CurrentVelocity + DampingRate * FirstSolutionCoefficient
				) / DampedAngularFrequency
				AnimatedValue[ComponentValue] = TargetComponent
					+ ExponentialTerm
						* (FirstSolutionCoefficient * CosineTerm + SecondSolutionCoefficient * SineTerm)
				CurrentVelocities[ComponentValue] = ExponentialTerm
					* (
						CurrentVelocity * CosineTerm
						- (
								FirstSolutionCoefficient * DampedAngularFrequency
								+ SecondSolutionCoefficient * DampingRate
							)
							* SineTerm
					)
			end
		end
	else
		local DampedAngularFrequency = AngularFrequency * math.sqrt(DampingRatio * DampingRatio - 1)
		local NegativeDampingRate = -AngularFrequency * DampingRatio
		local FirstCharacteristicRoot, SecondCharacteristicRoot =
			NegativeDampingRate + DampedAngularFrequency,
			NegativeDampingRate - DampedAngularFrequency
		local CharacteristicRootDifference = SecondCharacteristicRoot - FirstCharacteristicRoot
		local FirstExponential, SecondExponential =
			math.exp(FirstCharacteristicRoot * DeltaTime),
			math.exp(SecondCharacteristicRoot * DeltaTime)
		for ComponentValue, Position in AnimatedValue do
			local TargetComponent, CurrentVelocity =
				Target[ComponentValue], CurrentVelocities[ComponentValue]
			local Displacement = Position - TargetComponent
			if
				math.abs(Displacement) > MotionTolerance
				or math.abs(CurrentVelocity) > MotionTolerance
			then
				IsSleeping = false
				local SecondSolutionCoefficient = (
					CurrentVelocity - FirstCharacteristicRoot * Displacement
				) / CharacteristicRootDifference
				local FirstSolutionCoefficient = Displacement - SecondSolutionCoefficient
				AnimatedValue[ComponentValue] = TargetComponent
					+ FirstSolutionCoefficient * FirstExponential
					+ SecondSolutionCoefficient * SecondExponential
				CurrentVelocities[ComponentValue] = FirstSolutionCoefficient
						* FirstCharacteristicRoot
						* FirstExponential
					+ SecondSolutionCoefficient * SecondCharacteristicRoot * SecondExponential
			end
		end
	end

	if IsSleeping then
		for ComponentValue, TargetComponent in Target do
			AnimatedValue[ComponentValue] = TargetComponent
			CurrentVelocities[ComponentValue] = 0
		end
		ActiveSprings[MotionRecord] = nil
	end
end

const function StepTween(TweenRecord : Tween, CurrentTime : number)
	local Elapsed = CurrentTime - TweenRecord.StartTime
	if Elapsed < 0 then
		return
	end
	local AnimationInformation = TweenRecord.Information
	local Duration = AnimationInformation.Time
	local Alpha = if Duration > 0 then Elapsed / Duration else 1

	while Alpha >= 1 do
		if AnimationInformation.Reverses and not TweenRecord.Reversing then
			TweenRecord.Reversing = true
		elseif TweenRecord.RepeatsLeft ~= 0 then
			if TweenRecord.RepeatsLeft > 0 then
				TweenRecord.RepeatsLeft -= 1
			end
			TweenRecord.Reversing = false
		else
			ActiveTweens[TweenRecord] = nil
			local AnimatedValue = TweenRecord.Value
			for Index, Value in
				(if TweenRecord.Reversing then TweenRecord.Start else TweenRecord.Target)
			do
				AnimatedValue[Index] = Value
			end
			return
		end
		TweenRecord.StartTime += Duration
		if Duration <= 0 then
			Alpha = 1
			break
		end
		Alpha = (CurrentTime - TweenRecord.StartTime) / Duration
	end

	Alpha = TweenRecord.Ease(math.clamp(Alpha, 0, 1))
	if TweenRecord.Reversing then
		Alpha = 1 - Alpha
	end
	local AnimatedValue, Target = TweenRecord.Value, TweenRecord.Target
	for Index, Start in TweenRecord.Start do
		AnimatedValue[Index] = Start + (Target[Index] - Start) * Alpha
	end
end

local Stepping : { any } = {}

const function StepActive(
	ActiveMap : { [Motion] : any },
	StepCallback : (any, number) -> (),
	StepArgument : number
)
	if next(ActiveMap) == nil then
		return
	end
	local Count = 0
	for MotionRecord in ActiveMap do
		Count += 1
		Stepping[Count] = MotionRecord
	end
	for Index = 1, Count do
		local MotionRecord = Stepping[Index]
		Stepping[Index] = nil
		local Record = ActiveMap[MotionRecord]
		if Record ~= nil then
			StepCallback(MotionRecord, StepArgument)
			SetNodeValue(Record, MotionRecord.Unpack(MotionRecord.Value))
		end
	end
end

function MotionEngine.Step(DeltaTime : number?)
	local NormalizedTime = ReadClock()
	local Elapsed = DeltaTime or math.max(0, NormalizedTime - LastClock)
	local CurrentTime = MotionEngine.Now + Elapsed
	LastClock = NormalizedTime
	MotionEngine.Now = CurrentTime

	StepActive(ActiveSprings, StepSpring, Elapsed)
	StepActive(ActiveTweens, StepTween, CurrentTime)
end

local PackValue = DataTypes.Pack
local TemporaryComponents = { 0, 0, 0, 0, 0, 0, 0 }
local MotionByNode : { [Graph.Node<any>] : EngineSpring | Tween } = setmetatable({}, { __mode = "k" }) :: any

const function PackSpring(Self : Graph.Node<any>, Method : string, AnimatedValue : any) : EngineSpring?
	local SpringRecord = MotionByNode[Self]
	if SpringRecord == nil or SpringRecord.Kind ~= SpringKind then
		ReportWarning(`[Flux] :{Method}() is only valid on a spring; ignoring`)
		return nil
	end
	local CurrentValue = ReadRawValue(AnimatedValue)
	local TypeString = CompatibleTypeOf(CurrentValue)
	if TypeString ~= SpringRecord.ValueTypeName then
		local FailureMessage = if Method == "impulse"
			then `Cannot impulse a {SpringRecord.ValueTypeName} spring with a {TypeString} value`
			elseif
				Method == "setVelocity"
			then `Cannot set velocity of a {SpringRecord.ValueTypeName} spring to a {TypeString} value`
			elseif
				Method == "setCurrent"
			then `Cannot set a {SpringRecord.ValueTypeName} spring's current value to a {TypeString} value`
			else `Cannot snap a {SpringRecord.ValueTypeName} spring to a {TypeString} value`
		error(FailureMessage, 3)
	end
	PackValue(TemporaryComponents, CurrentValue, TypeString)
	return SpringRecord :: EngineSpring
end

local MotionStateMetatable = {}
for EasingKey, Method in StateMetatable do
	(MotionStateMetatable :: any)[EasingKey] = Method
end
MotionStateMetatable.__index = MotionStateMetatable

function MotionStateMetatable.Set<ValueType>(Self : Graph.Node<ValueType>, AnimatedValue : ValueType)
	local MotionRecord = MotionByNode[Self]
	if MotionRecord == nil then
		ReportWarning("[Flux] :set() called on a destroyed motion node; ignoring")
		return
	end
	local Goal = ReadRawValue(AnimatedValue)
	local TypeString = CompatibleTypeOf(Goal)
	if TypeString ~= MotionRecord.ValueTypeName then
		error(`Cannot retarget a {MotionRecord.ValueTypeName} motion with a {TypeString} value`, 2)
	end
	MotionEngine.SetTarget(MotionRecord, PackValue(TemporaryComponents, Goal, TypeString))
end

function MotionStateMetatable.Impulse<ValueType>(Self : Graph.Node<ValueType>, Delta : ValueType)
	local SpringRecord = PackSpring(Self, "impulse", Delta)
	if SpringRecord ~= nil then
		MotionEngine.AddVelocity(SpringRecord, TemporaryComponents)
	end
end

function MotionStateMetatable.SetVelocity<ValueType>(Self : Graph.Node<ValueType>, Velocity : ValueType)
	local SpringRecord = PackSpring(Self, "setVelocity", Velocity)
	if SpringRecord ~= nil then
		MotionEngine.SetVelocity(SpringRecord, TemporaryComponents)
	end
end

function MotionStateMetatable.SetCurrent<ValueType>(Self : Graph.Node<ValueType>, AnimatedValue : ValueType)
	local SpringRecord = PackSpring(Self, "setCurrent", AnimatedValue)
	if SpringRecord == nil then
		return
	end
	local CurrentValue = SpringRecord.Value
	for Index = 1, math.min(#TemporaryComponents, SpringRecord.Count) do
		CurrentValue[Index] = TemporaryComponents[Index]
	end
	SetNodeValue(SpringRecord.Node, SpringRecord.Unpack(CurrentValue))
	ActiveSprings[SpringRecord] = SpringRecord.Node
end

function MotionStateMetatable.Snap<ValueType>(Self : Graph.Node<ValueType>, AnimatedValue : ValueType)
	local SpringRecord = PackSpring(Self, "snap", AnimatedValue)
	if SpringRecord ~= nil then
		MotionEngine.Snap(SpringRecord, TemporaryComponents)
		SetNodeValue(SpringRecord.Node, SpringRecord.Unpack(SpringRecord.Value))
	end
end

function MotionStateMetatable.__call<ValueType>(Self : Graph.Node<ValueType>, AnimatedValue : any?) : any?
	if AnimatedValue ~= nil then
		MotionStateMetatable.Set(Self, AnimatedValue)
		return
	end
	return GetStateValue(Self)
end

const function AttachEffect(StateNode : Graph.Node<any>, Callback : () -> ())
	local EffectNode = CreateEffect(Callback)
	StateNode:OnDestroy(function()
		EffectNode:Destroy()
	end)
end

const function RegisterResource(StateNode : Graph.Node<any>, MotionRecord : EngineSpring | Tween)
	MotionByNode[StateNode] = MotionRecord
	local function Unregister()
		MotionByNode[StateNode] = nil
		MotionEngine.Destroy(MotionRecord)
	end
	StateNode:OnDestroy(Unregister)
	if Graph.GetOwner() then
		Graph.Cleanup(Unregister)
	end
end

const function PackOrFallback(
	Target : any,
	InitialValue : any,
	ValueTypeName : string
) : Graph.Node<any>?
	PackValue(TemporaryComponents, InitialValue, ValueTypeName)
	if #TemporaryComponents ~= 0 then
		return nil
	end
	if ValueTypeName == "nil" then
		ReportWarning("[Flux] Animating a nil value; following the goal without animation")
		local StateNode = Graph.State(InitialValue)
		if IsDynamicValue(Target) then
			AttachEffect(StateNode, function()
				StateNode:Set(ReadReactiveValue(Target))
			end)
		end
		return StateNode
	end
	error(`Cannot animate a {ValueTypeName} value`, 3)
end

local MotionModule = {
	Color = Color,

	DataType = DataTypes,

	Easing = Easing,

	Engine = MotionEngine,

	NodeToMotion = MotionByNode,

	Step = MotionEngine.Step,
}

function MotionModule.Spring<TargetType>(
	Target : TargetType,
	Frequency : Reactive<number>?,
	Damping : Reactive<number>?,
	InitialVelocity : any?
) : Spring<Unwrap<TargetType>>
	local InitialValue = ReadRawValue(Target)
	local ValueTypeName = CompatibleTypeOf(InitialValue)
	local Fallback = PackOrFallback(Target, InitialValue, ValueTypeName)
	if Fallback ~= nil then
		return Fallback :: any
	end

	local StateNode = Graph.State(InitialValue)
	local SpringRecord = MotionEngine.NewSpring(#TemporaryComponents, ValueTypeName, StateNode)
	RegisterResource(StateNode, SpringRecord)
	MotionEngine.Snap(SpringRecord, TemporaryComponents)
	MotionEngine.SetupSpring(SpringRecord, ReadRawValue(Frequency), ReadRawValue(Damping))
	if InitialVelocity ~= nil then
		local InitialVelocityValue : any = ReadRawValue(InitialVelocity)
		if InitialVelocityValue ~= nil then
			MotionEngine.SetVelocity(
				SpringRecord,
				PackValue(TemporaryComponents, InitialVelocityValue, ValueTypeName)
			)
		end
	end

	if IsDynamicValue(Target) or IsDynamicValue(Frequency) or IsDynamicValue(Damping) then
		local ReactiveSetup = IsDynamicValue(Frequency) or IsDynamicValue(Damping)
		AttachEffect(StateNode, function()
			if ReactiveSetup then
				MotionEngine.SetupSpring(
					SpringRecord,
					ReadReactiveValue(Frequency),
					ReadReactiveValue(Damping)
				)
			end
			MotionEngine.SetTarget(
				SpringRecord,
				PackValue(TemporaryComponents, ReadReactiveValue(Target), ValueTypeName)
			)
		end)
	end

	return setmetatable(StateNode, MotionStateMetatable) :: any
end

function MotionModule.Tween<TargetType>(
	Target : TargetType,
	TweenInformation : Reactive<TweenInfo>?
) : Graph.Node<Unwrap<TargetType>>
	local InitialValue = ReadRawValue(Target)
	local ValueTypeName = CompatibleTypeOf(InitialValue)
	local Fallback = PackOrFallback(Target, InitialValue, ValueTypeName)
	if Fallback ~= nil then
		return Fallback :: any
	end

	local StateNode = Graph.State(InitialValue)
	local TweenRecord = MotionEngine.NewTween(#TemporaryComponents, ValueTypeName, StateNode)
	RegisterResource(StateNode, TweenRecord)
	MotionEngine.Snap(TweenRecord, TemporaryComponents)
	MotionEngine.SetupTween(TweenRecord, ReadRawValue(TweenInformation))

	if IsDynamicValue(Target) or IsDynamicValue(TweenInformation) then
		AttachEffect(StateNode, function()
			local Index = ReadReactiveValue(TweenInformation) or MotionEngine.DefaultTweenInfo
			if TweenRecord.Information ~= Index then
				MotionEngine.SetupTween(TweenRecord, Index)
			end
			MotionEngine.SetTarget(
				TweenRecord,
				PackValue(TemporaryComponents, ReadReactiveValue(Target), ValueTypeName)
			)
		end)
	end

	return setmetatable(StateNode, MotionStateMetatable) :: any
end

return table.freeze(MotionModule)
