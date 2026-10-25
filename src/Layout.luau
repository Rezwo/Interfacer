--!strict

const Compatibility = require("./Compatibility")
const Edit = require("./Edit")
const Graph = require("./Graph")

local ConstructInstance = Edit.New

local Color3 = Compatibility.Color3
local ColorSequence = Compatibility.ColorSequence
local ColorSequenceKeypoint = Compatibility.ColorSequenceKeypoint
local Enum = Compatibility.Enum
local NumberSequence = Compatibility.NumberSequence
local NumberSequenceKeypoint = Compatibility.NumberSequenceKeypoint
local UDim = Compatibility.UDim
local UDim2 = Compatibility.UDim2
local Vector2 = Compatibility.Vector2
local CompatibleTypeOf = Compatibility.TypeOf
local ReportWarning = Compatibility.Warn

local CreateComputed = Graph.Computed
local IsDynamicValue = Graph.IsDynamic
local IsReactiveNode = Graph.IsNode
local CreateNode = Graph.New
local ReadReactiveValue = Graph.Read

type Properties = { [string] : any }

type EnumMap = { [string] : EnumItem }

export type Reactive<ValueType> = Graph.Reactive<ValueType>
export type Length = number | UDim
export type ReactiveLength = Reactive<number> | Reactive<UDim>
export type Insets = { Top : number?, Bottom : number?, Left : number?, Right : number? }
export type Align = "Start" | "Center" | "End"
export type FlexAlign = Align | "SpaceBetween" | "SpaceAround" | "SpaceEvenly" | "Stretch" | "Fill" | "None"
export type LineAlign = Align | "Stretch" | "Automatic"
export type Direction = "Horizontal" | "Vertical"
export type FlexMode = "Fill" | "Grow" | "Shrink" | "None"

export type PaddingSides = {
	Top : ReactiveLength?,
	Bottom : ReactiveLength?,
	Left : ReactiveLength?,
	Right : ReactiveLength?,
	X : ReactiveLength?,
	Y : ReactiveLength?,
}

export type ListConfiguration = {
	Gap : ReactiveLength?,
	Direction : Reactive<Direction | Enum.FillDirection>?,
	Align : Reactive<FlexAlign>?,
	Justify : Reactive<FlexAlign>?,
	HorizontalAlign : Reactive<FlexAlign | Enum.HorizontalAlignment | Enum.UIFlexAlignment>?,
	VerticalAlign : Reactive<FlexAlign | Enum.VerticalAlignment | Enum.UIFlexAlignment>?,
	LineAlign : Reactive<LineAlign | Enum.ItemLineAlignment>?,
	Wraps : Reactive<boolean>?,
}

export type GridConfiguration = {
	Cell : Reactive<number | Vector2 | UDim2>?,
	Gap : Reactive<number | Vector2 | UDim2>?,
	Fill : Reactive<Direction | Enum.FillDirection>?,
	Align : Reactive<Align | Enum.HorizontalAlignment>?,
	Justify : Reactive<Align | Enum.VerticalAlignment>?,
	MaximumCells : Reactive<number>?,
}

export type StrokeConfiguration = {
	Thickness : Reactive<number>?,
	Color : Reactive<Color3>?,
	Transparency : Reactive<number>?,
	Mode : Reactive<"Contextual" | "Border" | Enum.ApplyStrokeMode>?,
	Joins : Reactive<"Round" | "Bevel" | "Miter" | Enum.LineJoinMode>?,
	Position : Reactive<"Inner" | "Center" | "Outer" | Enum.BorderStrokePosition>?,
	Offset : Reactive<number | UDim>?,
}

export type CornerSides = {
	Radius : ReactiveLength?,
	TopLeft : ReactiveLength?,
	TopRight : ReactiveLength?,
	BottomLeft : ReactiveLength?,
	BottomRight : ReactiveLength?,
	Top : ReactiveLength?,
	Bottom : ReactiveLength?,
	Left : ReactiveLength?,
	Right : ReactiveLength?,
}

export type GradientConfiguration = {
	Color : Reactive<Color3 | ColorSequence | { Color3 }>?,
	Transparency : Reactive<number | NumberSequence | { number }>?,
	Rotation : Reactive<number>?,
	Offset : Reactive<Vector2>?,
	Enabled : Reactive<boolean>?,
}

export type SizeConstraintConfiguration = {
	Minimum : Reactive<Vector2>?,
	Maximum : Reactive<Vector2>?,
	MinimumWidth : Reactive<number>?,
	MinimumHeight : Reactive<number>?,
	MaximumWidth : Reactive<number>?,
	MaximumHeight : Reactive<number>?,
}

export type TextSizeConstraintConfiguration = {
	Minimum : Reactive<number>?,
	Maximum : Reactive<number>?,
}

local EmptyConfiguration : any = table.freeze({})
local ZeroDimension = UDim.new()
local LayoutSortOrder = Enum.SortOrder.LayoutOrder
local FillDirections : EnumMap =
	{ Horizontal = Enum.FillDirection.Horizontal, Vertical = Enum.FillDirection.Vertical }
local HorizontalAlignments : EnumMap = {
	Start = Enum.HorizontalAlignment.Left,
	Center = Enum.HorizontalAlignment.Center,
	["End"] = Enum.HorizontalAlignment.Right,
}
local VerticalAlignments : EnumMap = {
	Start = Enum.VerticalAlignment.Top,
	Center = Enum.VerticalAlignment.Center,
	["End"] = Enum.VerticalAlignment.Bottom,
}
local FlexAlignments : EnumMap = {
	None = Enum.UIFlexAlignment.None,
	Fill = Enum.UIFlexAlignment.Fill,
	Stretch = Enum.UIFlexAlignment.Fill,
	SpaceBetween = Enum.UIFlexAlignment.SpaceBetween,
	SpaceAround = Enum.UIFlexAlignment.SpaceAround,
	SpaceEvenly = Enum.UIFlexAlignment.SpaceEvenly,
}
local ItemLineAlignments : EnumMap = {
	Automatic = Enum.ItemLineAlignment.Automatic,
	Start = Enum.ItemLineAlignment.Start,
	Center = Enum.ItemLineAlignment.Center,
	["End"] = Enum.ItemLineAlignment.End,
	Stretch = Enum.ItemLineAlignment.Stretch,
}
local FlexModes : EnumMap = {
	Fill = Enum.UIFlexMode.Fill,
	Grow = Enum.UIFlexMode.Grow,
	Shrink = Enum.UIFlexMode.Shrink,
	None = Enum.UIFlexMode.None,
}
local AspectTypes : EnumMap = {
	Fit = Enum.AspectType.FitWithinMaxSize,
	Scale = Enum.AspectType.ScaleWithParentSize,
}
local DominantAxes : EnumMap = { Width = Enum.DominantAxis.Width, Height = Enum.DominantAxis.Height }
local StrokeModes : EnumMap =
	{ Contextual = Enum.ApplyStrokeMode.Contextual, Border = Enum.ApplyStrokeMode.Border }
local LineJoins : EnumMap = {
	Round = Enum.LineJoinMode.Round,
	Bevel = Enum.LineJoinMode.Bevel,
	Miter = Enum.LineJoinMode.Miter,
}
local StrokePositions : EnumMap = {
	Inner = Enum.BorderStrokePosition.Inner,
	Center = Enum.BorderStrokePosition.Center,
	Outer = Enum.BorderStrokePosition.Outer,
}

local FlexItems : { [EnumItem] : true } = {}
for _, Item in FlexAlignments do
	FlexItems[Item] = true
end

local WarnedEnums : { [string] : boolean } = {}

const function ResolveEnum(Map : EnumMap, Value : any, Label : string) : any
	if Value == nil then
		return nil
	elseif type(Value) == "string" then
		local Mapped = Map[Value]
		if Mapped == nil then
			local Key = `{Label}:{Value}`
			if not WarnedEnums[Key] then
				WarnedEnums[Key] = true
				ReportWarning(`[Flux] unknown {Label} "{Value}"; falling back to default`)
			end
			return nil
		end
		return Mapped
	end
	return Value
end

const function ResolveEnumProperty(Map : EnumMap, Value : any, Label : string, Default : EnumItem) : any
	if IsDynamicValue(Value) then
		return function()
			local Resolved = ResolveEnum(Map, ReadReactiveValue(Value), Label)
			return if Resolved == nil then Default else Resolved
		end
	end
	return ResolveEnum(Map, Value, Label)
end

const function ToDimension(Value : any) : UDim
	return if type(Value) == "number" then UDim.new(0, Value) else Value
end

const function ToDimensionPair(Value : any) : UDim2
	local Kind = CompatibleTypeOf(Value)
	if Kind == "Vector2" then
		return UDim2.fromOffset(Value.X, Value.Y)
	elseif Kind == "number" then
		return UDim2.fromOffset(Value, Value)
	end
	return Value
end

const function ResolveReactiveProperty(Value : any, Convert : (any) -> any) : any
	if IsDynamicValue(Value) then
		return function()
			return Convert(ReadReactiveValue(Value))
		end
	end
	return Convert(Value)
end

const function DimensionProperty(Value : any) : any
	return ResolveReactiveProperty(Value, ToDimension)
end

const function DimensionPairProperty(Value : any) : any
	return ResolveReactiveProperty(Value, ToDimensionPair)
end

const function CornerProperty(
	Sides : CornerSides,
	CreateCorner : string,
	VerticalMode : string,
	HorizontalMode : string
) : any
	local Entries = Sides :: any
	local Value = Entries[CreateCorner]
		or Entries[VerticalMode]
		or Entries[HorizontalMode]
		or Sides.Radius
	return DimensionProperty(if Value == nil then 8 else Value)
end

const function Spread(Values : { any }, Keypoint : any, Sequence : any) : any
	local Count = #Values
	if Count == 1 then
		return Sequence.new(Values[1])
	end
	local Keypoints = table.create(Count)
	for SequenceIndex, Value in Values do
		Keypoints[SequenceIndex] = Keypoint.new((SequenceIndex - 1) / (Count - 1), Value)
	end
	return Sequence.new(Keypoints)
end

const function ToColorSequence(Value : any) : ColorSequence
	local Kind = CompatibleTypeOf(Value)
	if Kind == "ColorSequence" then
		return Value
	elseif Kind == "Color3" then
		return ColorSequence.new(Value :: Color3)
	elseif Kind == "table" and #Value > 0 then
		return Spread(Value, ColorSequenceKeypoint, ColorSequence)
	end
	return ColorSequence.new(Color3.new(1, 1, 1))
end

const function ToNumberSequence(Value : any) : NumberSequence
	local Kind = CompatibleTypeOf(Value)
	if Kind == "NumberSequence" then
		return Value
	elseif Kind == "number" then
		return NumberSequence.new(Value :: number)
	elseif Kind == "table" and #Value > 0 then
		return Spread(Value, NumberSequenceKeypoint, NumberSequence)
	end
	return NumberSequence.new(0)
end

const function ToAxisPair(
	VectorValue : any,
	HorizontalValue : any,
	VerticalValue : any,
	Fallback : number
) : Vector2
	local Base = ReadReactiveValue(VectorValue)
	local HorizontalDimension, VerticalDimension =
		ReadReactiveValue(HorizontalValue), ReadReactiveValue(VerticalValue)
	return Vector2.new(
		if HorizontalDimension ~= nil
			then HorizontalDimension
			elseif Base ~= nil then Base.X
			else Fallback,
		if VerticalDimension ~= nil
			then VerticalDimension
			elseif Base ~= nil then Base.Y
			else Fallback
	)
end

const function AxisPair(
	VectorValue : any,
	HorizontalValue : any,
	VerticalValue : any,
	Fallback : number
) : any
	if VectorValue == nil and HorizontalValue == nil and VerticalValue == nil then
		return nil
	end
	if
		IsDynamicValue(VectorValue)
		or IsDynamicValue(HorizontalValue)
		or IsDynamicValue(VerticalValue)
	then
		return function() : Vector2
			return ToAxisPair(VectorValue, HorizontalValue, VerticalValue, Fallback)
		end
	end
	return ToAxisPair(VectorValue, HorizontalValue, VerticalValue, Fallback)
end

const function SetSide(Properties : Properties, Property : string, Value : any)
	if Value ~= nil then
		Properties[Property] = DimensionProperty(Value)
	end
end

const function PaddingSide(Source : any, Field : string) : () -> UDim
	return function()
		local Value = ReadReactiveValue(Source)
		if CompatibleTypeOf(Value) == "table" then
			return ToDimension(Value[Field] or 0)
		elseif Value == nil then
			return ZeroDimension
		end
		return ToDimension(Value)
	end
end

const function ToFlexAlignment(Value : any) : EnumItem?
	if type(Value) == "string" then
		return FlexAlignments[Value]
	end
	return if FlexItems[Value] then Value else nil
end

const function ReadListAlign(
	Pinned : any,
	DirectionMode : any,
	AlignmentMode : any,
	Justify : any,
	Axis : Direction,
	Label : string
) : (any, string)
	if Pinned ~= nil then
		local Override = ReadReactiveValue(Pinned :: any)
		if Override ~= nil then
			return Override, Label
		end
	end
	local Main = ReadReactiveValue(DirectionMode) == FillDirections.Horizontal
	if (Axis == "Horizontal") == Main then
		return ReadReactiveValue(Justify), "justify"
	end
	return ReadReactiveValue(AlignmentMode), "align"
end

const function ListAlign(
	Configuration : ListConfiguration,
	DirectionMode : any,
	Axis : Direction,
	Map : EnumMap,
	Label : string
) : (any, any)
	local Pinned = if Axis == "Horizontal"
		then Configuration.HorizontalAlign
		else Configuration.VerticalAlign
	local AlignmentMode, Justify = Configuration.Align, Configuration.Justify

	if Pinned == nil and AlignmentMode == nil and Justify == nil then
		return nil, nil
	end

	local ReactiveInput = if Pinned ~= nil
		then IsDynamicValue(Pinned)
		else IsDynamicValue(DirectionMode) or IsDynamicValue(AlignmentMode) or IsDynamicValue(
			Justify
		)
	if ReactiveInput then
		return function()
			local Value, Source =
				ReadListAlign(Pinned, DirectionMode, AlignmentMode, Justify, Axis, Label)
			return if ToFlexAlignment(Value) ~= nil
				then Map.Start
				else ResolveEnum(Map, Value, Source) or Map.Start
		end, function()
			local Value, _ =
				ReadListAlign(Pinned, DirectionMode, AlignmentMode, Justify, Axis, Label)
			return ToFlexAlignment(Value) or FlexAlignments.None
		end
	end

	local Value, Source = ReadListAlign(Pinned, DirectionMode, AlignmentMode, Justify, Axis, Label)
	local CreateFlexItem = ToFlexAlignment(Value)
	if CreateFlexItem ~= nil then
		return Map.Start, CreateFlexItem
	end
	return ResolveEnum(Map, Value, Source), nil
end

local Layout = {}

function Layout.Padding(
	Value : Length | PaddingSides | Graph.Node<any> | (() -> Length | Insets)
) : UIPadding
	local Properties : Properties = {}

	if IsDynamicValue(Value) then
		local Source : any = CreateNode(Value :: any)
		Properties.PaddingTop = PaddingSide(Source, "Top")
		Properties.PaddingBottom = PaddingSide(Source, "Bottom")
		Properties.PaddingLeft = PaddingSide(Source, "Left")
		Properties.PaddingRight = PaddingSide(Source, "Right")
		if Source ~= Value then
			Properties.__CLEAN = { Source }
		end
	elseif CompatibleTypeOf(Value) == "table" then
		local Sides = Value :: PaddingSides
		SetSide(Properties, "PaddingTop", Sides.Top or Sides.Y)
		SetSide(Properties, "PaddingBottom", Sides.Bottom or Sides.Y)
		SetSide(Properties, "PaddingLeft", Sides.Left or Sides.X)
		SetSide(Properties, "PaddingRight", Sides.Right or Sides.X)
	else
		local Side = DimensionProperty(Value)
		Properties.PaddingTop, Properties.PaddingBottom, Properties.PaddingLeft, Properties.PaddingRight =
			Side, Side, Side, Side
	end

	return ConstructInstance("UIPadding", Properties) :: any
end

function Layout.Corner(Radius : ReactiveLength | CornerSides?) : UICorner
	if type(Radius) == "table" and not IsReactiveNode(Radius) and (Radius :: any).Offset == nil then
		local Sides = Radius :: CornerSides
		return ConstructInstance("UICorner", {
			TopLeftRadius = CornerProperty(Sides, "TopLeft", "Top", "Left"),
			TopRightRadius = CornerProperty(Sides, "TopRight", "Top", "Right"),
			BottomLeftRadius = CornerProperty(Sides, "BottomLeft", "Bottom", "Left"),
			BottomRightRadius = CornerProperty(Sides, "BottomRight", "Bottom", "Right"),
		}) :: any
	end
	return ConstructInstance("UICorner", { CornerRadius = DimensionProperty(Radius) }) :: any
end

function Layout.Stroke(Options : StrokeConfiguration?) : UIStroke
	local Configuration : StrokeConfiguration = (Options or EmptyConfiguration) :: any
	return ConstructInstance("UIStroke", {
		Thickness = Configuration.Thickness,
		Color = Configuration.Color,
		Transparency = Configuration.Transparency,
		ApplyStrokeMode = ResolveEnumProperty(
			StrokeModes,
			Configuration.Mode,
			"strokeMode",
			StrokeModes.Contextual
		),
		LineJoinMode = ResolveEnumProperty(
			LineJoins,
			Configuration.Joins,
			"lineJoin",
			LineJoins.Round
		),
		BorderStrokePosition = if Configuration.Position ~= nil
			then ResolveEnumProperty(
				StrokePositions,
				Configuration.Position,
				"strokePosition",
				StrokePositions.Outer
			)
			else nil,
		BorderOffset = if Configuration.Offset ~= nil
			then DimensionProperty(Configuration.Offset)
			else nil,
	}) :: any
end

function Layout.AspectRatio(
	Ratio : Reactive<number>,
	AspectMode : Reactive<"Fit" | "Scale" | Enum.AspectType>?,
	DominantAxisMode : Reactive<"Width" | "Height" | Enum.DominantAxis>?
) : UIAspectRatioConstraint
	return ConstructInstance("UIAspectRatioConstraint", {
		AspectRatio = Ratio,
		AspectType = ResolveEnumProperty(AspectTypes, AspectMode, "aspectType", AspectTypes.Fit),
		DominantAxis = ResolveEnumProperty(
			DominantAxes,
			DominantAxisMode,
			"dominantAxis",
			DominantAxes.Width
		),
	}) :: any
end

function Layout.List(Options : ListConfiguration?) : UIListLayout
	local Configuration : ListConfiguration = (Options or EmptyConfiguration) :: any
	local Properties : Properties = {
		SortOrder = LayoutSortOrder,
		Padding = DimensionProperty(Configuration.Gap),
		Wraps = Configuration.Wraps,
		ItemLineAlignment = ResolveEnumProperty(
			ItemLineAlignments,
			Configuration.LineAlign,
			"lineAlign",
			ItemLineAlignments.Automatic
		),
	}

	local DirectionMode : any = Configuration.Direction
	if IsDynamicValue(DirectionMode) then
		local Source = DirectionMode
		DirectionMode = CreateComputed(function()
			return ResolveEnum(FillDirections, ReadReactiveValue(Source), "direction")
				or FillDirections.Vertical
		end)
		Properties.__CLEAN = { DirectionMode }
	else
		DirectionMode = ResolveEnum(FillDirections, DirectionMode, "direction")
	end
	Properties.FillDirection = DirectionMode

	Properties.HorizontalAlignment, Properties.HorizontalFlex =
		ListAlign(Configuration, DirectionMode, "Horizontal", HorizontalAlignments, "horizontalAlign")
	Properties.VerticalAlignment, Properties.VerticalFlex =
		ListAlign(Configuration, DirectionMode, "Vertical", VerticalAlignments, "verticalAlign")

	return ConstructInstance("UIListLayout", Properties) :: any
end

function Layout.Grid(Options : GridConfiguration?) : UIGridLayout
	local Configuration : GridConfiguration = (Options or EmptyConfiguration) :: any
	return ConstructInstance("UIGridLayout", {
		SortOrder = LayoutSortOrder,
		CellSize = DimensionPairProperty(Configuration.Cell),
		CellPadding = DimensionPairProperty(Configuration.Gap),
		FillDirectionMaxCells = Configuration.MaximumCells,
		FillDirection = ResolveEnumProperty(
			FillDirections,
			Configuration.Fill,
			"Fill",
			FillDirections.Horizontal
		),
		HorizontalAlignment = ResolveEnumProperty(
			HorizontalAlignments,
			Configuration.Align,
			"align",
			HorizontalAlignments.Start
		),
		VerticalAlignment = ResolveEnumProperty(
			VerticalAlignments,
			Configuration.Justify,
			"justify",
			VerticalAlignments.Start
		),
	}) :: any
end

function Layout.Flex(Mode : Reactive<FlexMode | Enum.UIFlexMode>?) : UIFlexItem
	if IsDynamicValue(Mode) then
		return ConstructInstance("UIFlexItem", {
			FlexMode = function()
				local Value = ReadReactiveValue(Mode)
				return if Value == nil
					then FlexModes.Fill
					else ResolveEnum(FlexModes, Value, "flexMode") or FlexModes.None
			end,
		}) :: any
	end
	return ConstructInstance("UIFlexItem", {
		FlexMode = if Mode == nil then FlexModes.Fill else ResolveEnum(FlexModes, Mode, "flexMode"),
	}) :: any
end

function Layout.Gradient(Options : GradientConfiguration?) : UIGradient
	local Configuration : GradientConfiguration = (Options or EmptyConfiguration) :: any
	return ConstructInstance("UIGradient", {
		Color = if Configuration.Color ~= nil
			then ResolveReactiveProperty(Configuration.Color, ToColorSequence)
			else nil,
		Transparency = if Configuration.Transparency ~= nil
			then ResolveReactiveProperty(Configuration.Transparency, ToNumberSequence)
			else nil,
		Rotation = Configuration.Rotation,
		Offset = Configuration.Offset,
		Enabled = Configuration.Enabled,
	}) :: any
end

function Layout.SizeConstraint(Options : SizeConstraintConfiguration?) : UISizeConstraint
	local Configuration : SizeConstraintConfiguration = (Options or EmptyConfiguration) :: any
	return ConstructInstance("UISizeConstraint", {
		MinSize = AxisPair(
			Configuration.Minimum,
			Configuration.MinimumWidth,
			Configuration.MinimumHeight,
			0
		),
		MaxSize = AxisPair(
			Configuration.Maximum,
			Configuration.MaximumWidth,
			Configuration.MaximumHeight,
			math.huge
		),
	}) :: any
end

function Layout.TextSizeConstraint(Options : TextSizeConstraintConfiguration?) : UITextSizeConstraint
	local Configuration : TextSizeConstraintConfiguration = (Options or EmptyConfiguration) :: any
	return ConstructInstance("UITextSizeConstraint", {
		MinTextSize = Configuration.Minimum,
		MaxTextSize = Configuration.Maximum,
	}) :: any
end

return table.freeze(Layout)
