--!strict
local Clock = require("./Clock")

local IsRoblox = game ~= nil

type Task = {
	spawn : (FunctionOrThread : any, ...any) -> thread,
	defer : (FunctionOrThread : any, ...any) -> thread,
	delay : (Seconds : number?, FunctionOrThread : any, ...any) -> thread,
	wait : (Seconds : number?) -> number,
	cancel : (thread : thread) -> (),
}

type Compatibility = {
	IsRoblox : boolean,
	Traceback : (Failure : any, Level : number?) -> any,
	Warn : (...any) -> (),
	SetWarnHook : (Hook : ((Message : string) -> ())?) -> (),
	Task : Task,
	Clock : () -> number,
	TypeOf : (ComponentValue : any) -> string,
	GetService : (ItemName : string) -> any,
	Services : { [string] : any },
	Instance : any,
	Color3: typeof(Color3),
	UDim: typeof(UDim),
	UDim2: typeof(UDim2),
	Vector2: typeof(Vector2),
	Vector3: typeof(Vector3),
	Font: typeof(Font),
	TweenInfo: typeof(TweenInfo),
	Enum: typeof(Enum),
	ColorSequence: typeof(ColorSequence),
	ColorSequenceKeypoint: typeof(ColorSequenceKeypoint),
	NumberSequence: typeof(NumberSequence),
	NumberSequenceKeypoint: typeof(NumberSequenceKeypoint),
}

local BuiltinTypeOf = typeof
local RawWarn : (...any) -> () = if IsRoblox then warn else print
local WarnHook : ((Message : string) -> ())? = nil

const function ReportCompatibleWarning(... : any)
	local Hook = WarnHook
	if Hook then
		local Parts = table.pack(...)
		for IndexValue = 1, Parts.n do
			Parts[IndexValue] = tostring(Parts[IndexValue])
		end
		Hook(table.concat(Parts :: any, " ", 1, Parts.n))
		return
	end
	RawWarn(...)
end

local function SetWarnHook(Hook : ((Message : string) -> ())?)
	WarnHook = Hook
end

const function CreateTraceback(Failure : any, Level : number?) : any
	return if type(Failure) == "string" then debug.traceback(Failure, Level) else Failure
end

Clock.Internal.SetReport(ReportCompatibleWarning)

local CompatibleTaskLibrary : Task = table.freeze({
	spawn = if IsRoblox then task.spawn else Clock.Internal.Spawn,
	defer = Clock.Defer,
	delay = Clock.Delay,
	wait = Clock.Wait,
	cancel = Clock.Cancel,
}) :: any

if IsRoblox then
	return table.freeze({
		IsRoblox = true,
		Traceback = CreateTraceback,
		Warn = ReportCompatibleWarning,
		SetWarnHook = SetWarnHook,
		Task = CompatibleTaskLibrary,
		Clock = Clock.Now,
		TypeOf = typeof,
		GetService = function(ItemName : string) : any
			return game:GetService(ItemName :: any)
		end,
		Services = {},
		Instance = Instance,
		Color3 = Color3,
		UDim = UDim,
		UDim2 = UDim2,
		Vector2 = Vector2,
		Vector3 = Vector3,
		Font = Font,
		TweenInfo = TweenInfo,
		Enum = Enum,
		ColorSequence = ColorSequence,
		ColorSequenceKeypoint = ColorSequenceKeypoint,
		NumberSequence = NumberSequence,
		NumberSequenceKeypoint = NumberSequenceKeypoint,
	}) :: Compatibility
end

const function CompatibleTypeOf(ComponentValue : any) : string
	local Metatable = getmetatable(ComponentValue)
	return if type(Metatable) == "table" and type(Metatable.__type) == "string"
		then Metatable.__type
		else BuiltinTypeOf(ComponentValue)
end

const function FieldsEqual(FirstValue : any, BlueComponent : any) : boolean
	if getmetatable(FirstValue) ~= getmetatable(BlueComponent) then
		return false
	end
	for Key, ComponentValue in FirstValue do
		if BlueComponent[Key] ~= ComponentValue then
			return false
		end
	end
	return true
end

const function CreateDatatype(
	ItemName : string,
	Representation : (Self : any) -> string,
	Methods : { [string] : any }?
) : (any, (Fields : { [string] : any }) -> any)
	local Metatable : { [string] : any } = {
		__type = ItemName,
		__index = Methods,
		__eq = FieldsEqual,
		__tostring = function(Self : any) : string
			return `{ItemName}({Representation(Self)})`
		end,
	}
	return Metatable,
		function(Fields : { [string] : any }) : any
			return table.freeze(setmetatable(Fields, Metatable))
		end
end

local NewColor3 : (Fields : { [string] : any }) -> any
local _, BuildColor3 = CreateDatatype("Color3", function(TextValue : any)
	return `{TextValue.R}, {TextValue.G}, {TextValue.B}`
end, {
	Lerp = function(Self : any, Other : any, Alpha : number) : any
		return NewColor3({
			R = Self.R + (Other.R - Self.R) * Alpha,
			G = Self.G + (Other.G - Self.G) * Alpha,
			B = Self.B + (Other.B - Self.B) * Alpha,
		})
	end,
	ToHex = function(Self : any) : string
		return string.format(
			"%02x%02x%02x",
			math.round(Self.R * 255),
			math.round(Self.G * 255),
			math.round(Self.B * 255)
		)
	end,
})
NewColor3 = BuildColor3

local Color3Stub = {
	new = function(RedComponent : number?, GreenComponent : number?, BlueComponent : number?) : any
		return NewColor3({ R = RedComponent or 0, G = GreenComponent or 0, B = BlueComponent or 0 })
	end,
	fromRGB = function(RedComponent : number?, GreenComponent : number?, BlueComponent : number?) : any
		return NewColor3({
			R = (RedComponent or 0) / 255,
			G = (GreenComponent or 0) / 255,
			B = (BlueComponent or 0) / 255,
		})
	end,
	fromHex = function(Hex : string) : any
		local Digits = string.match(Hex, "^#?(%x+)$")
		if Digits == nil or (#Digits ~= 3 and #Digits ~= 6) then
			error(`invalid hex color "{Hex}"`, 2)
		end
		if #Digits == 3 then
			Digits = string.gsub(Digits, "(%x)", "%1%1")
		end
		local ValueItem = tonumber(Digits, 16) :: number
		return NewColor3({
			R = bit32.rshift(ValueItem, 16) / 255,
			G = bit32.band(bit32.rshift(ValueItem, 8), 0xff) / 255,
			B = bit32.band(ValueItem, 0xff) / 255,
		})
	end,
}

const function ToSigned32Bit(ValueItem : number) : number
	return if ValueItem >= 0 then math.floor(ValueItem) else math.ceil(ValueItem)
end

local UDimMetatable, NewUDim = CreateDatatype("UDim", function(TextValue : any)
	return `{TextValue.Scale}, {TextValue.Offset}`
end)

local DimensionStub = {
	new = function(Scale : number?, Offset : number?) : any
		return NewUDim({ Scale = Scale or 0, Offset = ToSigned32Bit(Offset or 0) })
	end,
}

UDimMetatable.__add = function(FirstValue : any, BlueComponent : any) : any
	return DimensionStub.new(
		FirstValue.Scale + BlueComponent.Scale,
		FirstValue.Offset + BlueComponent.Offset
	)
end
UDimMetatable.__sub = function(FirstValue : any, BlueComponent : any) : any
	return DimensionStub.new(
		FirstValue.Scale - BlueComponent.Scale,
		FirstValue.Offset - BlueComponent.Offset
	)
end

local _, NewUDim2 = CreateDatatype("UDim2", function(TextValue : any)
	return `\{{TextValue.X.Scale}, {TextValue.X.Offset}\}, \{{TextValue.Y.Scale}, {TextValue.Y.Offset}\}`
end)

const function CreateUDim2(HorizontalComponent : any, VerticalComponent : any) : any
	return NewUDim2({
		X = HorizontalComponent,
		Y = VerticalComponent,
		Width = HorizontalComponent,
		Height = VerticalComponent,
	})
end

local DimensionPairStub = {
	new = function(
		FirstValue : any,
		BlueComponent : any,
		ColorValue : number?,
		DimensionValue : number?
	) : any
		return if type(FirstValue) == "table"
			then CreateUDim2(FirstValue, BlueComponent)
			else CreateUDim2(
				DimensionStub.new(FirstValue, BlueComponent),
				DimensionStub.new(ColorValue, DimensionValue)
			)
	end,
	fromScale = function(HorizontalComponent : number?, VerticalComponent : number?) : any
		return CreateUDim2(
			DimensionStub.new(HorizontalComponent, 0),
			DimensionStub.new(VerticalComponent, 0)
		)
	end,
	fromOffset = function(HorizontalComponent : number?, VerticalComponent : number?) : any
		return CreateUDim2(
			DimensionStub.new(0, HorizontalComponent),
			DimensionStub.new(0, VerticalComponent)
		)
	end,
}

local CreateVector2 : (HorizontalComponent : number?, VerticalComponent : number?) -> any
local Vector2Metatable, NewVector2 = CreateDatatype("Vector2", function(TextValue : any)
	return `{TextValue.X}, {TextValue.Y}`
end, {
	Lerp = function(Self : any, Goal : any, Alpha : number) : any
		return CreateVector2(Self.X + (Goal.X - Self.X) * Alpha, Self.Y + (Goal.Y - Self.Y) * Alpha)
	end,
})
function CreateVector2(HorizontalComponent : number?, VerticalComponent : number?) : any
	return NewVector2({ X = HorizontalComponent or 0, Y = VerticalComponent or 0 })
end
Vector2Metatable.__add = function(FirstValue : any, BlueComponent : any) : any
	return CreateVector2(FirstValue.X + BlueComponent.X, FirstValue.Y + BlueComponent.Y)
end
Vector2Metatable.__sub = function(FirstValue : any, BlueComponent : any) : any
	return CreateVector2(FirstValue.X - BlueComponent.X, FirstValue.Y - BlueComponent.Y)
end
Vector2Metatable.__mul = function(FirstValue : any, BlueComponent : any) : any
	if type(BlueComponent) == "number" then
		return CreateVector2(FirstValue.X * BlueComponent, FirstValue.Y * BlueComponent)
	elseif type(FirstValue) == "number" then
		return CreateVector2(FirstValue * BlueComponent.X, FirstValue * BlueComponent.Y)
	end
	return CreateVector2(FirstValue.X * BlueComponent.X, FirstValue.Y * BlueComponent.Y)
end
Vector2Metatable.__div = function(FirstValue : any, BlueComponent : any) : any
	return if type(BlueComponent) == "number"
		then CreateVector2(FirstValue.X / BlueComponent, FirstValue.Y / BlueComponent)
		else CreateVector2(FirstValue.X / BlueComponent.X, FirstValue.Y / BlueComponent.Y)
end
Vector2Metatable.__unm = function(FirstValue : any) : any
	return CreateVector2(-FirstValue.X, -FirstValue.Y)
end

local Vector2Stub = { new = CreateVector2, zero = CreateVector2(0, 0) }

local CreateVector3 : (
	HorizontalComponent : number?,
	VerticalComponent : number?,
	DepthComponent : number?
) -> any
local Vector3Metatable, NewVector3 = CreateDatatype("Vector3", function(TextValue : any)
	return `{TextValue.X}, {TextValue.Y}, {TextValue.Z}`
end, {
	Lerp = function(Self : any, Goal : any, Alpha : number) : any
		return CreateVector3(
			Self.X + (Goal.X - Self.X) * Alpha,
			Self.Y + (Goal.Y - Self.Y) * Alpha,
			Self.Z + (Goal.Z - Self.Z) * Alpha
		)
	end,
})
function CreateVector3(
	HorizontalComponent : number?,
	VerticalComponent : number?,
	DepthComponent : number?
) : any
	return NewVector3({
		X = HorizontalComponent or 0,
		Y = VerticalComponent or 0,
		Z = DepthComponent or 0,
	})
end
Vector3Metatable.__add = function(FirstValue : any, BlueComponent : any) : any
	return CreateVector3(
		FirstValue.X + BlueComponent.X,
		FirstValue.Y + BlueComponent.Y,
		FirstValue.Z + BlueComponent.Z
	)
end
Vector3Metatable.__sub = function(FirstValue : any, BlueComponent : any) : any
	return CreateVector3(
		FirstValue.X - BlueComponent.X,
		FirstValue.Y - BlueComponent.Y,
		FirstValue.Z - BlueComponent.Z
	)
end
Vector3Metatable.__mul = function(FirstValue : any, BlueComponent : any) : any
	if type(BlueComponent) == "number" then
		return CreateVector3(
			FirstValue.X * BlueComponent,
			FirstValue.Y * BlueComponent,
			FirstValue.Z * BlueComponent
		)
	elseif type(FirstValue) == "number" then
		return CreateVector3(
			FirstValue * BlueComponent.X,
			FirstValue * BlueComponent.Y,
			FirstValue * BlueComponent.Z
		)
	end
	return CreateVector3(
		FirstValue.X * BlueComponent.X,
		FirstValue.Y * BlueComponent.Y,
		FirstValue.Z * BlueComponent.Z
	)
end
Vector3Metatable.__div = function(FirstValue : any, BlueComponent : any) : any
	return if type(BlueComponent) == "number"
		then CreateVector3(
			FirstValue.X / BlueComponent,
			FirstValue.Y / BlueComponent,
			FirstValue.Z / BlueComponent
		)
		else CreateVector3(
			FirstValue.X / BlueComponent.X,
			FirstValue.Y / BlueComponent.Y,
			FirstValue.Z / BlueComponent.Z
		)
end
Vector3Metatable.__unm = function(FirstValue : any) : any
	return CreateVector3(-FirstValue.X, -FirstValue.Y, -FirstValue.Z)
end

local Vector3Stub = { new = CreateVector3, zero = CreateVector3(0, 0, 0) }

local EnumValues : { [string] : { [string] : number } } = {
	FontWeight = {
		Thin = 100,
		ExtraLight = 200,
		Light = 300,
		Regular = 400,
		Medium = 500,
		SemiBold = 600,
		Bold = 700,
		ExtraBold = 800,
		Heavy = 900,
	},
	InputSink = { None = 0, Activate = 1, All = 100 },
	EasingStyle = {
		Linear = 0,
		Sine = 1,
		Back = 2,
		Quad = 3,
		Quart = 4,
		Quint = 5,
		Bounce = 6,
		Elastic = 7,
		Exponential = 8,
		Circular = 9,
		Cubic = 10,
	},
	EasingDirection = { In = 0, Out = 1, InOut = 2 },
}

local EnumItemMetatable = {
	__type = "EnumItem",
	__tostring = function(Self : any) : string
		return `Enum.{tostring(Self.EnumType)}.{Self.Name}`
	end,
}

local EnumStub = setmetatable({}, {
	__type = "Enums",
	__index = function(Enums : any, EnumType : string) : any
		local Values = EnumValues[EnumType]
		local Items
		Items = setmetatable({}, {
			__type = "Enum",
			__index = function(Self : any, ItemName : string) : any
				local Item = table.freeze(setmetatable({
					Name = ItemName,
					EnumType = Items,
					Value = if Values then Values[ItemName] or 0 else 0,
				}, EnumItemMetatable))
				rawset(Self, ItemName, Item)
				return Item
			end,
			__tostring = function() : string
				return EnumType
			end,
		})
		rawset(Enums, EnumType, Items)
		return Items
	end,
	__tostring = function() : string
		return "Enums"
	end,
})

local _, NewFont = CreateDatatype("Font", function(TextValue : any)
	return `{TextValue.Family}, {TextValue.Weight.Name}, {TextValue.Style.Name}`
end)

const function CreateFont(FontFamily : string, FontWeight : any?, FontStyle : any?) : any
	local ResolvedWeight = FontWeight or EnumStub.FontWeight.Regular
	return NewFont({
		Family = FontFamily,
		Weight = ResolvedWeight,
		Style = FontStyle or EnumStub.FontStyle.Normal,
		Bold = ResolvedWeight.Value >= 600,
	})
end

local FontStub = {
	new = CreateFont,
	fromEnum = function(Item : any) : any
		return CreateFont(`rbxasset://fonts/families/{Item.Name}.json`)
	end,
	fromId = function(Identifier : number, FontWeight : any?, FontStyle : any?) : any
		return CreateFont(`rbxassetid://{Identifier}`, FontWeight, FontStyle)
	end,
}

local _, NewTweenInfo = CreateDatatype("TweenInfo", function(TextValue : any)
	return `{TextValue.Time}, {TextValue.EasingStyle.Name}, {TextValue.EasingDirection.Name}, {TextValue.RepeatCount}, {TextValue.Reverses}, {TextValue.DelayTime}`
end)

local TweenInfoStub = {
	new = function(
		Duration : number?,
		EasingStyle : any?,
		EasingDirection : any?,
		RepeatCount : number?,
		Reverses : boolean?,
		DelayTime : number?
	) : any
		return NewTweenInfo({
			Time = Duration or 1,
			EasingStyle = EasingStyle or EnumStub.EasingStyle.Quad,
			EasingDirection = EasingDirection or EnumStub.EasingDirection.Out,
			RepeatCount = RepeatCount or 0,
			Reverses = Reverses or false,
			DelayTime = DelayTime or 0,
		})
	end,
}

local _, NewColorKeypoint = CreateDatatype("ColorSequenceKeypoint", function(TextValue : any)
	return `{TextValue.Time}, {TextValue.Value}`
end)
const function ColorKeypoint(Duration : number, ComponentValue : any) : any
	return NewColorKeypoint({ Time = Duration, Value = ComponentValue })
end

local _, NewNumberKeypoint = CreateDatatype("NumberSequenceKeypoint", function(TextValue : any)
	return `{TextValue.Time}, {TextValue.Value}, {TextValue.Envelope}`
end)
const function NumberKeypoint(Duration : number, ComponentValue : number, Envelope : number?) : any
	return NewNumberKeypoint({ Time = Duration, Value = ComponentValue, Envelope = Envelope or 0 })
end

const function Sequence(
	ItemName : string,
	Keypoint : (Duration : number, ComponentValue : any) -> any
) : any
	local Metatable = {
		__type = ItemName,
		__eq = function(FirstValue : any, BlueComponent : any) : boolean
			if
				getmetatable(BlueComponent) ~= getmetatable(FirstValue)
				or #FirstValue.Keypoints ~= #BlueComponent.Keypoints
			then
				return false
			end
			for IndexValue, Point in FirstValue.Keypoints do
				if Point ~= BlueComponent.Keypoints[IndexValue] then
					return false
				end
			end
			return true
		end,
		__tostring = function(Self : any) : string
			local Parts = {}
			for _, Point in Self.Keypoints do
				table.insert(Parts, `({tostring(Point)})`)
			end
			return `{ItemName}({table.concat(Parts, ", ")})`
		end,
	}
	return {
		new = function(First : any, Last : any?) : any
			local Points = if type(First) == "table" and getmetatable(First) == nil
				then table.clone(First)
				else { Keypoint(0, First), Keypoint(1, if Last == nil then First else Last) }
			return table.freeze(setmetatable({ Keypoints = table.freeze(Points) }, Metatable))
		end,
	}
end

local Compatibility = {} :: any
Compatibility.IsRoblox = false
Compatibility.Traceback = CreateTraceback
Compatibility.Warn = ReportCompatibleWarning
Compatibility.SetWarnHook = SetWarnHook
Compatibility.Task = CompatibleTaskLibrary
Compatibility.Clock = Clock.Now
Compatibility.TypeOf = CompatibleTypeOf
Compatibility.Services = {} :: { [string] : any }
Compatibility.GetService = function(ItemName : string) : any
	return Compatibility.Services[ItemName]
end
Compatibility.Instance = nil :: any
Compatibility.Color3 = Color3Stub :: any
Compatibility.UDim = DimensionStub :: any
Compatibility.UDim2 = DimensionPairStub :: any
Compatibility.Vector2 = Vector2Stub :: any
Compatibility.Vector3 = Vector3Stub :: any
Compatibility.Font = FontStub :: any
Compatibility.TweenInfo = TweenInfoStub :: any
Compatibility.Enum = EnumStub :: any
Compatibility.ColorSequence = Sequence("ColorSequence", ColorKeypoint)
Compatibility.ColorSequenceKeypoint = { new = ColorKeypoint } :: any
Compatibility.NumberSequence = Sequence("NumberSequence", NumberKeypoint)
Compatibility.NumberSequenceKeypoint = { new = NumberKeypoint } :: any

return Compatibility :: Compatibility
