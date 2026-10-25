--!strict
const Geometry = require("./VirtualGeometry")

const function Covers(Shape : Geometry.Geometry, First : number, Last : number, Offset : number) : boolean
	if Shape.Count == 0 then return Last < First end
	local Clamped = math.clamp(Offset, 0, math.max(0, Shape.CanvasHeight - Shape.WindowHeight))
	local Margin = math.min(1, Shape.OverscanRows)
	local FirstBand = math.max(0, math.floor((Clamped - Shape.PaddingVertical) / Shape.StrideVertical) - Margin)
	local LastBand = math.floor((Clamped + Shape.WindowHeight - Shape.PaddingVertical - 0.000001) / Shape.StrideVertical) + Margin
	return First <= math.min(Shape.Count, FirstBand * Shape.Columns + 1)
		and Last >= math.min(Shape.Count, (LastBand + 1) * Shape.Columns)
end

return table.freeze({ Covers = Covers })
