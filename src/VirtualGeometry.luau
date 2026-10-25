--!strict
const Synchronous = require("./VirtualSynchronous")

export type Key = string | number
export type Catalog<ItemType> = {
	Items : { ItemType },
	Keys : { Key },
	Positions : { [Key] : number },
}
export type Layout = {
	Kind : string,
	ItemHeight : number,
	MinimumItemWidth : number?,
	PaddingHorizontal : number?,
	PaddingVertical : number?,
	GapHorizontal : number?,
	GapVertical : number?,
	OverscanRows : number?,
}
export type Geometry = {
	Columns : number,
	Count : number,
	ItemWidth : number,
	ItemHeight : number,
	StrideHorizontal : number,
	StrideVertical : number,
	PaddingHorizontal : number,
	PaddingVertical : number,
	CanvasHeight : number,
	WindowHeight : number,
	OverscanRows : number,
}
export type Anchor = { Key : Key?, PreviousIndex : number, Offset : number }

const function IsFinite(Value : number) : boolean
	return Value == Value and Value > -math.huge and Value < math.huge
end

const function Nonnegative(Value : number, Name : string) : number
	assert(IsFinite(Value) and Value >= 0, `VirtualCollection {Name} must be finite and nonnegative`)
	return Value
end

const function Catalog<ItemType>(Items : { ItemType }, GetKey : (ItemType) -> Key) : Catalog<ItemType>
	local Values, Keys, Positions = {}, {}, {}
	local Entries = 0
	for Index, Item in Items do
		Entries += 1
		assert(type(Index) == "number" and Index >= 1 and Index % 1 == 0 and Index <= #Items, "VirtualCollection Items must be a dense array")
		local Passed, Key = Synchronous.Run(GetKey, Item)
		if not Passed then error(Key, 0) end
		assert(type(Key) == "string" or (type(Key) == "number" and IsFinite(Key)), "VirtualCollection key must be a string or finite number")
		assert(Positions[Key] == nil, "VirtualCollection duplicate key")
		Values[Index], Keys[Index], Positions[Key] = Item, Key, Index
	end
	assert(Entries == #Items and #Keys == #Items, "VirtualCollection Items must be a dense array")
	return { Items = Values, Keys = Keys, Positions = Positions }
end

const function Geometry(Width : number, Height : number, Count : number, Layout : Layout) : Geometry
	Nonnegative(Width, "width")
	Nonnegative(Height, "height")
	assert(Layout.Kind == "List" or Layout.Kind == "Grid", "VirtualCollection unknown layout")
	assert(IsFinite(Layout.ItemHeight) and Layout.ItemHeight > 0, "VirtualCollection ItemHeight must be positive and finite")
	local PaddingHorizontal = Nonnegative(Layout.PaddingHorizontal or 0, "horizontal padding")
	local PaddingVertical = Nonnegative(Layout.PaddingVertical or 0, "vertical padding")
	local GapHorizontal = Nonnegative(Layout.GapHorizontal or 0, "horizontal gap")
	local GapVertical = Nonnegative(Layout.GapVertical or 0, "vertical gap")
	local OverscanRows = Nonnegative(Layout.OverscanRows or 2, "overscan")
	assert(OverscanRows % 1 == 0, "VirtualCollection OverscanRows must be an integer")
	local AvailableWidth = math.max(0, Width - PaddingHorizontal * 2)
	local Columns = 1
	if Layout.Kind == "Grid" then
		local Minimum = Layout.MinimumItemWidth
		assert(Minimum and IsFinite(Minimum) and Minimum > 0, "VirtualCollection MinimumItemWidth must be positive and finite")
		Columns = math.max(1, math.floor((AvailableWidth + GapHorizontal) / (Minimum + GapHorizontal)))
	end
	local ItemWidth = math.max(0, (AvailableWidth - (Columns - 1) * GapHorizontal) / Columns)
	local Rows = math.ceil(Count / Columns)
	return {
		Columns = Columns, Count = Count, ItemWidth = ItemWidth, ItemHeight = Layout.ItemHeight,
		StrideHorizontal = ItemWidth + GapHorizontal, StrideVertical = Layout.ItemHeight + GapVertical,
		PaddingHorizontal = PaddingHorizontal, PaddingVertical = PaddingVertical,
		CanvasHeight = PaddingVertical * 2 + Rows * Layout.ItemHeight + math.max(0, Rows - 1) * GapVertical,
		WindowHeight = Height, OverscanRows = OverscanRows,
	}
end

const function Position(Shape : Geometry, Index : number) : (number, number)
	return Shape.PaddingHorizontal + ((Index - 1) % Shape.Columns) * Shape.StrideHorizontal,
		Shape.PaddingVertical + math.floor((Index - 1) / Shape.Columns) * Shape.StrideVertical
end

const function Window(Shape : Geometry, Offset : number) : (number, number)
	if Shape.Count == 0 or Shape.WindowHeight <= 0 or Shape.ItemWidth <= 0 then return 1, 0 end
	local Clamped = math.clamp(Offset, 0, math.max(0, Shape.CanvasHeight - Shape.WindowHeight))
	local FirstRow = math.max(0, math.floor((Clamped - Shape.PaddingVertical) / Shape.StrideVertical) - Shape.OverscanRows)
	local LastRow = math.floor((Clamped + Shape.WindowHeight - Shape.PaddingVertical - 0.000001) / Shape.StrideVertical) + Shape.OverscanRows
	return math.min(Shape.Count, FirstRow * Shape.Columns + 1), math.min(Shape.Count, (LastRow + 1) * Shape.Columns)
end

const function CaptureAnchor<ItemType>(Values : Catalog<ItemType>, Shape : Geometry, Offset : number) : Anchor
	local Row = math.max(0, math.floor((Offset - Shape.PaddingVertical) / Shape.StrideVertical))
	local Index = math.min(#Values.Keys, Row * Shape.Columns + 1)
	local _, Top = Position(Shape, math.max(1, Index))
	return { Key = Values.Keys[Index], PreviousIndex = Index, Offset = Offset - Top }
end

const function RestoreAnchor<ItemType>(Anchor : Anchor, Previous : Catalog<ItemType>, Current : Catalog<ItemType>, Shape : Geometry) : number
	local Index = if Anchor.Key ~= nil then Current.Positions[Anchor.Key] else nil
	if not Index then
		for Cursor = Anchor.PreviousIndex + 1, #Previous.Keys do
			Index = Current.Positions[Previous.Keys[Cursor]]
			if Index then break end
		end
	end
	if not Index then
		for Cursor = Anchor.PreviousIndex - 1, 1, -1 do
			Index = Current.Positions[Previous.Keys[Cursor]]
			if Index then break end
		end
	end
	if not Index then return 0 end
	local _, Top = Position(Shape, Index)
	return math.clamp(Top + Anchor.Offset, 0, math.max(0, Shape.CanvasHeight - Shape.WindowHeight))
end

return table.freeze({ Catalog = Catalog, Geometry = Geometry, Window = Window, Position = Position, CaptureAnchor = CaptureAnchor, RestoreAnchor = RestoreAnchor })
