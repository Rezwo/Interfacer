--!strict
const Bind = require("./Bind")

export type Measurement = {
	SourceScale : number, ParentScale : number, Position : Vector2, Window : Vector2,
	ParentPosition : Vector2, Revision : number,
}
type SurfaceData = {
	Viewport : ScrollingFrame?, Folder : Folder?, Surface : Frame?, Content : Frame?,
	ContentScale : UIScale?, SourceProbe : Frame?, ParentProbe : Frame?,
	Measurement : Measurement?, GeometryRevision : number, GeometryWrites : number, Closed : boolean,
}

const function ExpectedScale(Object : Instance) : number
	local Product = 1
	local Current : Instance? = Object.Parent
	while Current do
		local Modifier = Current:FindFirstChildOfClass("UIScale")
		if Modifier then Product *= Modifier.Scale end
		Current = Current.Parent
	end
	return Product
end

const function Read(Self : SurfaceData) : Measurement?
	local Viewport, SourceProbe, ParentProbe = Self.Viewport, Self.SourceProbe, Self.ParentProbe
	if Self.Closed or not Viewport or not SourceProbe or not ParentProbe then return nil end
	local Position, Window = Viewport.AbsolutePosition, Viewport.AbsoluteWindowSize
	local ParentPosition = ParentProbe.AbsolutePosition
	local Scale, ParentScale = SourceProbe.AbsoluteSize.X, ParentProbe.AbsoluteSize.X
	if Scale <= 0 or ParentScale <= 0 or Window.X <= 0 or Window.Y <= 0 then return nil end

	if math.abs(Scale - ExpectedScale(SourceProbe)) > 0.0001
		or math.abs(ParentScale - ExpectedScale(ParentProbe)) > 0.0001 then return nil end
	local Previous = Self.Measurement
	if not Previous or Previous.SourceScale ~= Scale or Previous.ParentScale ~= ParentScale
		or Previous.Window ~= Window or Previous.Position ~= Position or Previous.ParentPosition ~= ParentPosition then
		Self.GeometryRevision += 1
	end
	return { SourceScale = Scale, ParentScale = ParentScale, Position = Position,
		ParentPosition = ParentPosition, Window = Window, Revision = Self.GeometryRevision }
end

const function Write(Self : SurfaceData, Object : Instance, Property : string, Value : any)
	if (Object :: any)[Property] ~= Value then
		Bind.SetProperty(Object, Property, Value)
		Self.GeometryWrites += 1
	end
end

const function Commit(Self : SurfaceData, Measurement : Measurement, Offset : number)
	local Surface, Content, Modifier, Viewport = Self.Surface, Self.Content, Self.ContentScale, Self.Viewport
	if Self.Closed or not Surface or not Content or not Modifier or not Viewport then return end
	Write(Self, Surface, "Position", UDim2.fromOffset(
		(Measurement.Position.X - Measurement.ParentPosition.X) / Measurement.ParentScale,
		(Measurement.Position.Y - Measurement.ParentPosition.Y) / Measurement.ParentScale))
	Write(Self, Surface, "Size", UDim2.fromOffset(Measurement.Window.X / Measurement.ParentScale,
		Measurement.Window.Y / Measurement.ParentScale))
	Write(Self, Surface, "ZIndex", Viewport.ZIndex + 1)
	Write(Self, Modifier, "Scale", Measurement.SourceScale / Measurement.ParentScale)
	Write(Self, Content, "Position", UDim2.fromOffset(0, -Offset * Measurement.SourceScale / Measurement.ParentScale))
	Self.Measurement = Measurement
end

const function SetVisible(Self : SurfaceData, Visible : boolean)
	if Self.Surface then Write(Self, Self.Surface, "Visible", Visible) end
end

const function Destroy(Self : SurfaceData)
	if Self.Closed then return end
	Self.Closed = true
	local SourceProbe, Folder = Self.SourceProbe, Self.Folder
	Self.Viewport, Self.Folder, Self.Surface, Self.Content = nil, nil, nil, nil
	Self.SourceProbe, Self.ParentProbe, Self.ContentScale, Self.Measurement = nil, nil, nil, nil
	if SourceProbe then Bind.DestroyInstance(SourceProbe) end
	if Folder then Bind.DestroyInstance(Folder) end
end

const Methods = table.freeze({ Read = Read, Commit = Commit, SetVisible = SetVisible, Destroy = Destroy })
const Metatable = table.freeze({ __index = Methods })
export type Surface = setmetatable<SurfaceData, typeof(Metatable)>

const function New(Viewport : ScrollingFrame) : Surface
	assert(Viewport.Parent, "Presentation viewport must have a parent")
	local Folder = Instance.new("Folder")
	Folder.Name, Folder.Parent = "InterfacerTransactionalPresentation", Viewport.Parent
	local ParentProbe = Instance.new("Frame")
	ParentProbe.Name, ParentProbe.Size = "ParentScaleProbe", UDim2.fromOffset(1, 1)
	ParentProbe.BackgroundTransparency, ParentProbe.Parent = 1, Folder
	local SourceProbe = ParentProbe:Clone()
	SourceProbe.Name, SourceProbe.Parent = "SourceScaleProbe", Viewport
	local Surface = Instance.new("Frame")
	Surface.Name, Surface.BackgroundTransparency, Surface.BorderSizePixel = "PresentationSurface", 1, 0
	Surface.ClipsDescendants, Surface.Active, Surface.Parent = true, false, Folder
	local Content = Instance.new("Frame")
	Content.Name, Content.Size = "InterfacerVirtualContent", UDim2.fromOffset(1, 1)
	Content.BackgroundTransparency, Content.BorderSizePixel, Content.Parent = 1, 0, Surface
	local Modifier = Instance.new("UIScale")
	Modifier.Parent = Content
	local Data : SurfaceData = { Viewport = Viewport, Folder = Folder, Surface = Surface, Content = Content,
		ContentScale = Modifier, SourceProbe = SourceProbe, ParentProbe = ParentProbe, Measurement = nil,
		GeometryRevision = 0, GeometryWrites = 0, Closed = false }
	return setmetatable(Data, Metatable)
end

return table.freeze({ New = New })
