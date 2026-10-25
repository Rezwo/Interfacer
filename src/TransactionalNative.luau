--!strict

const Geometry = require("./VirtualGeometry")
const Snapshots = require("./PresentationSnapshots")
const Synchronous = require("./VirtualSynchronous")
const RunService = game:GetService("RunService")

type Cell = { Root : Frame, Label : TextLabel, Button : TextButton, Editor : TextBox,
	Slider : TextButton, Detector : UIDragDetector, Key : number?, Pinned : boolean,
	Dragging : boolean, Connections : { RBXScriptConnection } }
export type Measurement = {
	SourceScale : number, ParentScale : number, Position : Vector2, Window : Vector2,
	ParentPosition : Vector2, Revision : number,
}
type Statistics = {
	Assignments : number, GeometryWrites : number, Constructions : number, Disposals : number,
	Preparations : number, Commits : number, Translations : number, Discarded : number,
	MaximumCells : number, FrameCalls : number, InputActivations : number,
}
type ControllerData = {
	Viewport : ScrollingFrame, Surface : Frame, Content : Frame, ContentScale : UIScale,
	Folder : Folder, SourceProbe : Frame, ParentProbe : Frame, Cells : { Cell },
	Rows : { [number] : Cell }, Idle : { Cell }, Connections : { RBXScriptConnection },
	Count : number, Layout : Geometry.Layout, DataRevision : number, GeometryRevision : number,
	Generation : number, Requested : Snapshots.Snapshot?, Prepared : Snapshots.Snapshot?,
	Displayed : Snapshots.Snapshot?, Measurement : Measurement?, Shape : Geometry.Geometry?,
	Closed : boolean, Running : boolean, Failure : unknown, PendingKey : number?,
	BeforeCommit : ((any) -> any)?, Statistics : Statistics,
}
local Controllers : { [ControllerData] : boolean } = {}
local FrameConnection : RBXScriptConnection? = nil
local Flush : (ControllerData) -> ()
local Destroy : (ControllerData) -> ()
local FinishDestroy : (ControllerData) -> ()

const function SetProperty(Object : Instance, Property : string, Value : any, Statistics : Statistics)
	if (Object :: any)[Property] ~= Value then
		(Object :: any)[Property] = Value
		Statistics.GeometryWrites += 1
	end
end

const function Active(Viewport : ScrollingFrame) : boolean
	local Current : Instance? = Viewport
	while Current do
		if Current:IsA("GuiObject") and not Current.Visible then return false end
		if Current:IsA("ScreenGui") then return Current.Enabled end
		Current = Current.Parent
	end
	return false
end

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

const function ReadMeasurement(Self : ControllerData) : Measurement?

	local Position, Window = Self.Viewport.AbsolutePosition, Self.Viewport.AbsoluteWindowSize
	local ParentPosition = Self.ParentProbe.AbsolutePosition
	local Scale, ParentScale = Self.SourceProbe.AbsoluteSize.X, Self.ParentProbe.AbsoluteSize.X
	if Scale <= 0 or ParentScale <= 0 or Window.X <= 0 or Window.Y <= 0 then return nil end
	if math.abs(Scale - ExpectedScale(Self.SourceProbe)) > 0.0001
		or math.abs(ParentScale - ExpectedScale(Self.ParentProbe)) > 0.0001 then return nil end
	local Previous = Self.Measurement
	if not Previous or Previous.SourceScale ~= Scale or Previous.ParentScale ~= ParentScale
		or Previous.Window ~= Window or Previous.Position ~= Position or Previous.ParentPosition ~= ParentPosition then
		Self.GeometryRevision += 1
	end
	return { SourceScale = Scale, ParentScale = ParentScale, Position = Position,
		ParentPosition = ParentPosition, Window = Window, Revision = Self.GeometryRevision }
end

const function Construct(Self : ControllerData) : Cell
	assert(not Self.Closed, "Presentation disposed before cell construction")
	local Root = Instance.new("Frame")
	Root.Name, Root.BackgroundColor3, Root.BorderSizePixel = "PreparedCell", Color3.fromRGB(32, 39, 53), 0
	Root.Visible, Root.Active = false, false
	local Label = Instance.new("TextLabel")
	Label.Name, Label.Size, Label.Position = "Identifier", UDim2.new(1, -72, 0, 28), UDim2.fromOffset(6, 2)
	Label.BackgroundTransparency, Label.TextColor3, Label.TextSize = 1, Color3.new(1, 1, 1), 15
	Label.Parent = Root
	local Button = Instance.new("TextButton")
	Button.Name, Button.Text, Button.Position, Button.Size = "Action", "+", UDim2.new(1, -54, 0, 4), UDim2.fromOffset(48, 24)
	Button.Parent = Root
	local Editor = Instance.new("TextBox")
	Editor.Name, Editor.PlaceholderText, Editor.Position, Editor.Size = "Editor", "Native editor", UDim2.fromOffset(6, 36), UDim2.new(1, -12, 0, 28)
	Editor.ClearTextOnFocus, Editor.Text, Editor.Parent = false, "", Root
	local Track = Instance.new("Frame")
	Track.Name, Track.Position, Track.Size = "Track", UDim2.fromOffset(6, 78), UDim2.new(1, -12, 0, 16)
	Track.BackgroundColor3, Track.BorderSizePixel, Track.Parent = Color3.fromRGB(54, 69, 94), 0, Root
	local Slider = Instance.new("TextButton")
	Slider.Name, Slider.Text, Slider.Size, Slider.Parent = "Slider", "", UDim2.fromOffset(24, 16), Track
	local Detector = Instance.new("UIDragDetector")
	Detector.DragStyle = Enum.UIDragDetectorDragStyle.TranslateLine
	Detector.DragAxis = Vector2.xAxis
	Detector.Parent = Slider
	local Cell : Cell = { Root = Root, Label = Label, Button = Button, Editor = Editor,
		Slider = Slider, Detector = Detector, Key = nil, Pinned = false, Dragging = false, Connections = {} }
	table.insert(Cell.Connections, Editor.Focused:Connect(function() Cell.Pinned = true end))
	table.insert(Cell.Connections, Editor.FocusLost:Connect(function() Cell.Pinned = false end))
	table.insert(Cell.Connections, Detector.DragStart:Connect(function() Cell.Dragging = true end))
	table.insert(Cell.Connections, Detector.DragEnd:Connect(function() Cell.Dragging = false end))
	table.insert(Cell.Connections, Button.Activated:Connect(function() Self.Statistics.InputActivations += 1 end))
	table.insert(Self.Cells, Cell)
	Self.Statistics.Constructions += 1
	Self.Statistics.MaximumCells = math.max(Self.Statistics.MaximumCells, #Self.Cells)
	Root.Parent = Self.Content
	assert(not Self.Closed, "Presentation disposed during cell parenting")
	return Cell
end

const function Release(Self : ControllerData, Cell : Cell)
	Cell.Root.Visible = false
	Cell.Key = nil
	Cell.Label.Text, Cell.Editor.Text = "", ""
	Cell.Pinned, Cell.Dragging = false, false
	if not Self.Closed then table.insert(Self.Idle, Cell) end
end

const function ApplyGeometry(Self : ControllerData, Cell : Cell, Shape : Geometry.Geometry, Index : number)
	local Horizontal, Vertical = Geometry.Position(Shape, Index)
	SetProperty(Cell.Root, "Position", UDim2.fromOffset(Horizontal, Vertical), Self.Statistics)
	SetProperty(Cell.Root, "Size", UDim2.fromOffset(Shape.ItemWidth, Shape.ItemHeight), Self.Statistics)
	SetProperty(Cell.Root, "AnchorPoint", Vector2.zero, Self.Statistics)
	SetProperty(Cell.Root, "LayoutOrder", Index, Self.Statistics)
end

const function Align(Self : ControllerData, Measurement : Measurement, Offset : number)
	local Statistics = Self.Statistics
	SetProperty(Self.Surface, "Position", UDim2.fromOffset(
		(Measurement.Position.X - Measurement.ParentPosition.X) / Measurement.ParentScale,
		(Measurement.Position.Y - Measurement.ParentPosition.Y) / Measurement.ParentScale), Statistics)
	SetProperty(Self.Surface, "Size", UDim2.fromOffset(
		Measurement.Window.X / Measurement.ParentScale, Measurement.Window.Y / Measurement.ParentScale), Statistics)
	SetProperty(Self.Surface, "ZIndex", Self.Viewport.ZIndex + 1, Statistics)
	SetProperty(Self.ContentScale, "Scale", Measurement.SourceScale / Measurement.ParentScale, Statistics)
	SetProperty(Self.Content, "Position", UDim2.fromOffset(0, -Offset * Measurement.SourceScale / Measurement.ParentScale), Statistics)
end

Flush = function(Self : ControllerData)
	if Self.Closed or Self.Running then return end
	Self.Statistics.FrameCalls += 1
	Self.Surface.Visible = Active(Self.Viewport)
	if not Self.Surface.Visible then
		for _, Cell in Self.Cells do
			if Cell.Editor:IsFocused() then Cell.Editor:ReleaseFocus(false) end
			Cell.Pinned, Cell.Dragging = false, false
		end
		return
	end
	if Self.Failure ~= nil then return end
	local Measurement = ReadMeasurement(Self)
	if not Measurement then return end
	local Shape = Geometry.Geometry(Measurement.Window.X / Measurement.SourceScale,
		Measurement.Window.Y / Measurement.SourceScale, Self.Count, Self.Layout)
	local Offset = Self.Viewport.CanvasPosition.Y / Measurement.SourceScale
	local Key = Self.PendingKey
	if Key and Key >= 1 and Key <= Self.Count then
		local _, Top = Geometry.Position(Shape, Key)
		Offset = math.clamp(Top, 0, math.max(0, Shape.CanvasHeight - Shape.WindowHeight))
	end
	Offset = math.clamp(Offset, 0, math.max(0, Shape.CanvasHeight - Shape.WindowHeight))
	Self.Generation += 1
	local First, Last = Geometry.Window(Shape, Offset)
	local Requested = Snapshots.New(Self.Generation, Offset, First, Last, Self.DataRevision, Measurement.Revision)
	Self.Requested = Requested
	local Displayed = Self.Displayed
	if Displayed and Snapshots.Covers(Displayed, Shape, Offset, Self.DataRevision, Measurement.Revision) then
		if Key then
			Self.Viewport:ResetScrollVelocity()
			Self.Viewport.CanvasPosition = Vector2.new(0, Offset * Measurement.SourceScale)
			Self.PendingKey = nil
		end
		Align(Self, Measurement, Offset)
		Self.Displayed = Snapshots.New(Requested.Generation, Offset, Displayed.First, Displayed.Last,
			Requested.DataRevision, Requested.GeometryRevision)
		Self.Statistics.Translations += 1
		return
	end
	Self.Running = true
	local Staged : { [number] : Cell } = {}
	local Passed, Fail = pcall(function()
		Self.Statistics.Preparations += 1

		for Index = First, Last do
			if not Self.Rows[Index] then
				local Cell = table.remove(Self.Idle) or Construct(Self)
				Staged[Index] = Cell
				Cell.Key = Index
				Cell.Root.Name = `Item{Index}`
				Cell.Label.Text = `Inventory item {Index}`
				Self.Statistics.Assignments += 1
				ApplyGeometry(Self, Cell, Shape, Index)
			end
		end
		Self.Prepared = Snapshots.New(Requested.Generation, Offset, First, Last,
			Requested.DataRevision, Requested.GeometryRevision)
		if Self.BeforeCommit then
			local Completed, Cause = Synchronous.Run(Self.BeforeCommit, Self)
			if not Completed then error(Cause, 0) end
		end
		if Self.Closed or Self.DataRevision ~= Requested.DataRevision then return end

		if not Key and Self.Viewport.CanvasPosition.Y / Measurement.SourceScale ~= Requested.Offset then return end
		assert(Self.Prepared and Snapshots.Matches(Requested, Self.Prepared), "Incompatible presentation snapshots")
		Self.Viewport.CanvasSize = UDim2.fromOffset(0, Shape.CanvasHeight)
		if Key then
			Self.Viewport:ResetScrollVelocity()
			Self.Viewport.CanvasPosition = Vector2.new(0, Offset * Measurement.SourceScale)
			Self.PendingKey = nil
		end
		Align(Self, Measurement, Offset)
		for Index, Cell in Self.Rows do
			if Index >= First and Index <= Last then ApplyGeometry(Self, Cell, Shape, Index) end
		end
		for Index, Cell in Staged do
			Self.Rows[Index] = Cell
			Cell.Root.Visible = true
		end
		table.clear(Staged)
		Self.Displayed, Self.Shape, Self.Measurement = Self.Prepared, Shape, Measurement
		Self.Prepared = nil
		Self.Statistics.Commits += 1
		for Index, Cell in Self.Rows do
			if (Index < First or Index > Last) and not Cell.Pinned and not Cell.Dragging then
				Self.Rows[Index] = nil
				Release(Self, Cell)
			end
		end
	end)
	for _, Cell in Staged do Release(Self, Cell); Self.Statistics.Discarded += 1 end
	Self.Prepared = nil
	Self.Running = false
	if not Passed and not Self.Closed then Self.Failure = Fail end
	if Self.Closed then FinishDestroy(Self) end
end

FinishDestroy = function(Self : ControllerData)
	for _, Cell in Self.Cells do
		Cell.Root:Destroy()
		Self.Statistics.Disposals += 1
	end
	table.clear(Self.Cells)
	Self.SourceProbe:Destroy(); Self.Folder:Destroy()
end

Destroy = function(Self : ControllerData)
	if Self.Closed then return end
	Self.Closed = true
	Controllers[Self] = nil
	for _, Connection in Self.Connections do Connection:Disconnect() end
	table.clear(Self.Connections)
	for _, Cell in Self.Cells do
		Cell.Key = nil
		for _, Connection in Cell.Connections do Connection:Disconnect() end
		table.clear(Cell.Connections)
		if Cell.Editor:IsFocused() then Cell.Editor:ReleaseFocus(false) end
	end
	table.clear(Self.Rows); table.clear(Self.Idle)
	Self.Requested, Self.Prepared, Self.Displayed, Self.BeforeCommit = nil, nil, nil, nil
	Self.Surface.Visible = false

	if not Self.Running then FinishDestroy(Self) end
	if next(Controllers) == nil and FrameConnection then FrameConnection:Disconnect(); FrameConnection = nil end
end

const Methods = table.freeze({
	Flush = Flush, Destroy = Destroy,
	ScrollToKey = function(Self : ControllerData, Key : number) : boolean
		if Self.Closed or Key < 1 or Key > Self.Count or Key % 1 ~= 0 then return false end
		Self.PendingKey = Key
		Flush(Self)
		return true
	end,
})
const Metatable = table.freeze({ __index = Methods })
export type Controller = setmetatable<ControllerData, typeof(Metatable)>

const function New(Viewport : ScrollingFrame, Count : number, Layout : Geometry.Layout) : Controller
	assert(Viewport.Parent, "Transactional viewport must have a live parent")
	local Folder = Instance.new("Folder")
	Folder.Name, Folder.Parent = "TransactionalPresentation", Viewport.Parent
	local ParentProbe = Instance.new("Frame")
	ParentProbe.Name, ParentProbe.Size, ParentProbe.BackgroundTransparency = "ParentScaleProbe", UDim2.fromOffset(1, 1), 1
	ParentProbe.Parent = Folder
	local SourceProbe = ParentProbe:Clone()
	SourceProbe.Name, SourceProbe.Parent = "SourceScaleProbe", Viewport
	local Surface = Instance.new("Frame")
	Surface.Name, Surface.BackgroundTransparency, Surface.BorderSizePixel = "PresentationSurface", 1, 0
	Surface.ClipsDescendants, Surface.Active, Surface.Parent = true, false, Folder
	local Content = Instance.new("Frame")
	Content.Name, Content.BackgroundTransparency, Content.BorderSizePixel = "PresentationContent", 1, 0
	Content.Size, Content.Parent = UDim2.fromOffset(1, 1), Surface
	local ContentScale = Instance.new("UIScale")
	ContentScale.Parent = Content
	local Self : ControllerData = {
		Viewport = Viewport, Folder = Folder, Surface = Surface, Content = Content, ContentScale = ContentScale,
		SourceProbe = SourceProbe, ParentProbe = ParentProbe, Count = Count, Layout = Layout,
		Cells = {}, Rows = {}, Idle = {}, Connections = {}, DataRevision = 1, GeometryRevision = 0,
		Generation = 0, Requested = nil, Prepared = nil, Displayed = nil, Measurement = nil, Shape = nil,
		Closed = false, Running = false, Failure = nil, PendingKey = nil, BeforeCommit = nil,
		Statistics = { Assignments = 0, GeometryWrites = 0, Constructions = 0, Disposals = 0,
			Preparations = 0, Commits = 0, Translations = 0, Discarded = 0, MaximumCells = 0,
			FrameCalls = 0, InputActivations = 0 },
	}
	Viewport.AutomaticCanvasSize, Viewport.ScrollingDirection = Enum.AutomaticSize.None, Enum.ScrollingDirection.Y
	Viewport.VerticalScrollBarInset = Enum.ScrollBarInset.Always
	table.insert(Self.Connections, Viewport.Destroying:Connect(function() Destroy(Self) end))
	table.insert(Self.Connections, Surface.Destroying:Connect(function() Destroy(Self) end))
	table.insert(Self.Connections, Folder.Destroying:Connect(function() Destroy(Self) end))
	Controllers[Self] = true
	if not FrameConnection then
		FrameConnection = RunService.PreRender:Connect(function()
			for Entry in Controllers do Flush(Entry) end
		end)
	end
	Flush(Self)
	return setmetatable(Self, Metatable)
end

return table.freeze({ New = New })
