--!strict
const Graph = require("./Graph")
const Bind = require("./Bind")
const Clock = require("./Clock")
const Overlay = require("./Overlay")
const Geometry = require("./VirtualGeometry")
const Synchronous = require("./VirtualSynchronous")
const Cells = require("./ReusableCellPool")
const PresentationSurface = require("./PresentationSurface")
const Snapshots = require("./PresentationSnapshots")

export type Key = Geometry.Key
export type ReadValue<ValueType> = setmetatable<{
	read Get : (Self : any) -> ValueType,
	read Peek : (Self : any) -> ValueType,
}, { __call : (Self : any) -> ValueType }>
export type Layout = {
	Kind : "List" | "Grid",
	ItemHeight : number,
	MinimumItemWidth : number?,
	Padding : Vector2?,
	Gap : Vector2?,
	OverscanRows : number?,
}
export type Failure = { Stage : string, Key : Key?, Cause : unknown }
export type Statistics = {
	ItemCount : number, MountedRows : number, PinnedRows : number, StagedRows : number,
	RowsConstructed : number, RowsDisposed : number, Reconciliations : number,
	MetadataBuilds : number, KeyVisits : number, FrameDispatches : number,
	MaximumStagedRows : number, WindowRows : number, Connections : number,
	CellAssignments : number, CellReuses : number, PhysicalCells : number, PixelFastPaths : number, GeometryWrites : number,
}
export type Cell<ItemType> = Cells.Cell<ItemType>
export type Assignment<ItemType> = Cells.Assignment<ItemType>
export type Definition<ItemType> = Cells.Definition<ItemType>
export type function DeclaredItem(Value : type) : type
	return Value
end
export type Options<ItemType> = {
	Items : Graph.Reactive<{ ItemType }>,
	GetKey : (ItemType) -> Key,
	Layout : Graph.Reactive<Layout>,
	CreateCell : (Cell<DeclaredItem<ItemType>>, Key) -> Definition<DeclaredItem<ItemType>>,
	GetCellType : ((ItemType) -> Key)?,
}
export type Collection = {
	read Failure : ReadValue<Failure?>,
	ScrollToKey : (Self : Collection, Key : Key) -> boolean,
	FocusKey : (Self : Collection, Key : Key, ControlName : string?) -> boolean,
	Flush : (Self : Collection) -> (),
	Retry : (Self : Collection) -> (),
	GetStatistics : (Self : Collection) -> Statistics,
	Destroy : (Self : Collection) -> (),
}

type Control = {
	Object : GuiObject?, Detector : UIDragDetector?, Editing : boolean, Dragging : boolean, Pressed : boolean?,
}
type RowData = {
	Cell : any,
	Key : Key, Item : any, Index : any, ItemState : Graph.State<any>?, IndexState : Graph.State<number>?,
	Owner : Graph.Node<any>?, Root : GuiObject?, Controller : CollectionData?,
	Revision : number, Alive : boolean, Committed : boolean,
	PendingItem : boolean,
	Controls : { [string] : Control }, ControlOrder : { string },
}
type CollectionData = {
	Presentation : PresentationSurface.Surface?, PendingPresentation : PresentationSurface.Surface?,
	Requested : Snapshots.Snapshot?, Prepared : Snapshots.Snapshot?, Displayed : Snapshots.Snapshot?,
	PendingScrollKey : Key?, RequestRevision : number, PresentationGeneration : number,
	PendingAnchor : { Anchor : Geometry.Anchor, Previous : Geometry.Catalog<any> }?,
	CellTypes : { [Key] : Key }, Pool : any, ResidentFirst : number, ResidentLast : number, StructuralDirty : boolean,
	Owner : Graph.Node<any>?, Viewport : ScrollingFrame?, Content : Frame?,
	Configuration : Options<any>?, Catalog : Geometry.Catalog<any>, Shape : Geometry.Geometry?,
	NumericLayout : Geometry.Layout?,
	Rows : { [Key] : RowData }, Staging : { RowData }, Connections : { RBXScriptConnection },
	AncestorConnections : { RBXScriptConnection }, FailureState : Graph.State<Failure?>?, Failure : any,
	Closed : boolean, Running : boolean, Dirty : boolean, Reanchor : boolean,
	Revision : number, Scale : number, Statistics : Statistics,
	CommittedCanvasPosition : number?,
	FocusRequest : { Key : Key, ControlName : string?, Previous : GuiObject?, Revision : number, Attempts : number }?,
	ActionName : string, NavigationDirection : number?, NavigationNext : number,
}

local Collections : { [ScrollingFrame] : CollectionData } = setmetatable({}, { __mode = "k" }) :: any
local DirtyCollections : { [CollectionData] : boolean } = {}
local DisconnectFrame : (() -> ())? = nil
local Reconcile : (CollectionData) -> ()
local Destroy : (CollectionData) -> ()
local Flush : (CollectionData) -> ()
local MarkDirty : (CollectionData) -> ()
local Schedule : (CollectionData) -> ()
local Navigate : (CollectionData, number) -> boolean

const function SetFailure(Self : CollectionData, Stage : string, Cause : unknown, Key : Key?)
	local State = Self.FailureState
	if State and not Self.Closed then State:Set({ Stage = Stage, Key = Key, Cause = Cause }) end
end

const function Connect(List : { RBXScriptConnection }, Signal : RBXScriptSignal, Callback : (...any) -> ())
	table.insert(List, Signal:Connect(Callback))
end

const function DisconnectAll(List : { RBXScriptConnection })
	for _, Connection in List do Connection:Disconnect() end
	table.clear(List)
end

const function IsActive(Self : CollectionData) : boolean
	local Current : Instance? = Self.Viewport
	local Player = game:GetService("Players").LocalPlayer
	local PlayerGui = if Player then Player:FindFirstChildOfClass("PlayerGui") else nil
	if not Current or not PlayerGui or not Current:IsDescendantOf(PlayerGui) then return false end
	while Current do
		if Current:IsA("GuiObject") and not Current.Visible then return false end
		if Current:IsA("ScreenGui") and not Current.Enabled then return false end
		Current = Current.Parent
	end
	return true
end

const function IsPinned(Row : RowData) : boolean
	for _, Control in Row.Controls do
		if Control.Editing or Control.Dragging or Control.Pressed then return true end
	end
	return false
end

const function DisposeRow(Self : CollectionData, Row : RowData)
	if not Row.Alive then return end
	Row.Alive, Row.Committed = false, false
	Row.Revision += 1
	local Cell = Row.Cell
	Row.Cell, Row.Root, Row.Controller = nil, nil, nil
	Row.ItemState, Row.IndexState, Row.Item, Row.Index = nil, nil, nil, nil
	if Cell then
		Cell.Row = nil
		Self.Pool:Release(Cell)
	end
end

const function BuildRow(Self : CollectionData, Key : Key, Index : number) : RowData
	local Configuration = Self.Configuration
	assert(Configuration and Self.Pool, "Reusable collection unavailable")
	local Item = Self.Catalog.Items[Index]
	local CellType = Self.CellTypes[Key] or "Default"
	local Cell = Self.Pool:Stage(Key, Index, Item, CellType)
	local Row : RowData = {
		Key = Key, Cell = Cell, Item = Cell.Item, Index = Cell.Index,
		ItemState = Cell.ItemState, IndexState = Cell.IndexState, Owner = nil,
		Root = Cell.Root, Controller = Self, Revision = Self.Revision, Alive = true,
		Committed = false, PendingItem = false, Controls = Cell.Controls,
		ControlOrder = Cell.ControlOrder,
	}
	Cell.Row = Row
	table.insert(Self.Staging, Row)
	Self.Statistics.MaximumStagedRows = math.max(Self.Statistics.MaximumStagedRows, #Self.Staging)
	return Row
end

const function InitializeCell(Self : CollectionData, Cell : any)
	local Root = Cell.Root :: GuiObject
	assert(typeof(Root) == "Instance" and Root:IsA("GuiObject") and Root.Parent == nil, "CreateCell must return a detached GuiObject")
	assert(Root.AutomaticSize == Enum.AutomaticSize.None, "Reusable root AutomaticSize is reserved")
	local function Changed()
		local Row = Cell.Row
		if Row and Row.Alive then MarkDirty(Self) end
	end
	Connect(Cell.Connections, Root.Destroying, function()
		if not Cell.Alive then return end
		Cell.Root = nil
		MarkDirty(Self)
		local Row = Cell.Row
		if Row then Self.Rows[Row.Key] = nil; DisposeRow(Self, Row) end
		Self.Pool:Discard(Cell)
	end)
	for _, Name in Cell.ControlOrder do
		local Control = Cell.Controls[Name]
		local Object, Detector = Control.Object :: GuiObject, Control.Detector :: UIDragDetector?
		assert(Object == Root or Object:IsDescendantOf(Root), "Registered control must belong to its cell")
		Connect(Cell.Connections, Object.Destroying, function()
			Control.Editing, Control.Dragging, Control.Pressed = false, false, false
			Control.Object = nil
			Changed()
		end)
		if Object:IsA("TextBox") then
			Connect(Cell.Connections, Object.Focused, function() Control.Editing = true; Changed() end)
			Connect(Cell.Connections, Object.FocusLost, function() Control.Editing = false; Changed() end)
		end
		if Object:IsA("GuiButton") then
			Connect(Cell.Connections, Object.InputBegan, function(Input : InputObject)
				if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
					Control.Pressed, Control.PressInput = true, Input
					Changed()
				end
			end)
		end
		if Detector then
			assert(Detector.Parent == Object, "Drag detector must belong to its control")
			Connect(Cell.Connections, Detector.DragStart, function() Control.Dragging = true; Changed() end)
			Connect(Cell.Connections, Detector.DragEnd, function() Control.Dragging = false; Changed() end)
			Connect(Cell.Connections, Detector:GetPropertyChangedSignal("Enabled"), function()
				if not Detector.Enabled then Control.Dragging = false; Changed() end
			end)
		end
	end
end

const function BeforeRelease(Cell : any)
	local Selected = game:GetService("GuiService").SelectedObject
	local Root = Cell.Root
	if Selected and Root and (Selected == Root or Selected:IsDescendantOf(Root)) then
		game:GetService("GuiService").SelectedObject = nil
	end
	for _, Control in Cell.Controls do
		local Object, Detector = Control.Object, Control.Detector
		if Object and Object:IsA("TextBox") and Object:IsFocused() then Object:ReleaseFocus(false) end
		if Detector and Control.Dragging then Detector.Enabled = false; Detector.Enabled = true end
		Control.Editing, Control.Dragging, Control.Pressed, Control.PressInput = false, false, false, nil
	end
end

const function ReadLayout(Configuration : Layout) : Geometry.Layout
	local Padding, Gap = Configuration.Padding or Vector2.zero, Configuration.Gap or Vector2.zero
	return {
		Kind = Configuration.Kind, ItemHeight = Configuration.ItemHeight, MinimumItemWidth = Configuration.MinimumItemWidth,
		PaddingHorizontal = Padding.X, PaddingVertical = Padding.Y, GapHorizontal = Gap.X, GapVertical = Gap.Y,
		OverscanRows = Configuration.OverscanRows,
	}
end

const function ReadSources(Self : CollectionData, OnlyLayout : boolean)
	local Configuration = Self.Configuration
	if not Configuration or Self.Closed then return end
	local Stage = if OnlyLayout then "Layout" else "Data"
	local Passed, Result = Synchronous.Run(function(_Argument : boolean) : any
		if OnlyLayout then
			local Layout = ReadLayout(Graph.Read(Configuration.Layout))
			Geometry.Geometry(1, 1, #Self.Catalog.Keys, Layout)
			return Layout
		end
		local Items = Graph.Read(Configuration.Items)
		assert(type(Items) == "table", "ReusableVirtualCollection Items must resolve to an array")
		return Graph.Untrack(function()
			local Catalog = Geometry.Catalog(Items, Configuration.GetKey)
			local Types : { [Key] : Key } = {}
			for Index, Item in Catalog.Items do
				local CellType : Key = "Default"
				if Configuration.GetCellType then
					local Valid, Value = Synchronous.Run(Configuration.GetCellType, Item)
					if not Valid then error(Value, 0) end
					assert(type(Value) == "string" or (type(Value) == "number" and Value == Value and math.abs(Value) < math.huge), "Invalid cell type")
					CellType = Value
				end
				Types[Catalog.Keys[Index]] = CellType
			end
			return { Items = Catalog.Items, Keys = Catalog.Keys, Positions = Catalog.Positions, CellTypes = Types }
		end)
	end, false)
	if Self.Closed then return end
	if not Passed then SetFailure(Self, Stage, Result); return end

	local Viewport, Shape = Self.Viewport, Self.Shape
	local Anchor = if Viewport and Shape then Geometry.CaptureAnchor(Self.Catalog, Shape, if Self.Displayed then Self.Displayed.Offset else Viewport.CanvasPosition.Y / Self.Scale) else nil
	local Previous = Self.Catalog
	if OnlyLayout then
		Self.NumericLayout = Result
	else
		Self.Catalog, Self.CellTypes = Result, Result.CellTypes
		Self.Statistics.MetadataBuilds += 1
		Self.Statistics.KeyVisits += #Result.Keys
	end
	Self.Revision += 1
	if Anchor then Self.PendingAnchor = { Anchor = Anchor, Previous = Previous } end

	for Key, Row in Self.Rows do
		if Self.Catalog.Positions[Key] == nil then
			Self.Rows[Key] = nil; DisposeRow(Self, Row)
		elseif not OnlyLayout then
			Row.Revision += 1
			Row.PendingItem = true
		end
	end
	for _, Row in Self.Staging do
		if Self.Catalog.Positions[Row.Key] == nil then DisposeRow(Self, Row) end
	end
	if Self.FailureState then
		local Existing = Self.FailureState:Peek()
		if not Existing or Existing.Stage == Stage or Existing.Stage == "Render" then Self.FailureState:Set(nil) end
	end
	MarkDirty(Self)
end

const function GetStatistics(Self : CollectionData) : Statistics
	local Result = table.clone(Self.Statistics)
	Result.RowsConstructed, Result.RowsDisposed = Self.Pool.Constructed, Self.Pool.Destroyed
	Result.CellAssignments, Result.CellReuses, Result.PhysicalCells = Self.Pool.Assignments, Self.Pool.Reuses, #Self.Pool.Cells
	Result.ItemCount, Result.MountedRows, Result.PinnedRows = #Self.Catalog.Keys, 0, 0
	Result.StagedRows = #Self.Staging
	Result.Connections = #Self.Connections + #Self.AncestorConnections
	for _, Row in Self.Rows do
		Result.MountedRows += 1
		if IsPinned(Row) then Result.PinnedRows += 1 end
	end
	for _, Cell in Self.Pool.Cells do
		Result.Connections += #Cell.Connections
		local Assignment = Cell.Assignment
		if Assignment then Result.Connections += #Assignment.Connections end
	end
	return Result
end

const function ResolveFocus(Self : CollectionData)
	local Request, Viewport = Self.FocusRequest, Self.Viewport
	if not Request or not Viewport or Self.Closed then return end
	local Service = game:GetService("GuiService")
	if Service.MenuIsOpen or Self.Revision ~= Request.Revision or Service.SelectedObject ~= Request.Previous then
		Self.FocusRequest = nil; return
	end
	local Row = Self.Rows[Request.Key]
	if not Row or not Row.Alive then Self.FocusRequest = nil; return end
	local Control = if Request.ControlName then Row.Controls[Request.ControlName] else nil
	Control = Control or Row.Controls[Row.ControlOrder[1]]
	if not Control or not Control.Object then Self.FocusRequest = nil; return end
	local Object = Control.Object
	local Root = Row.Root
	if not Root or (Object ~= Root and not Object:IsDescendantOf(Root)) then Self.FocusRequest = nil; return end
	if not Object.Visible or not Object.Selectable then Self.FocusRequest = nil; return end
	local Top, Bottom = Viewport.AbsolutePosition.Y, Viewport.AbsolutePosition.Y + Viewport.AbsoluteWindowSize.Y
	if Object.AbsoluteSize.Y <= 0 or Object.AbsolutePosition.Y < Top - 1 or Object.AbsolutePosition.Y + Object.AbsoluteSize.Y > Bottom + 1 then
		Request.Attempts += 1
		if Request.Attempts <= 2 then MarkDirty(Self) else Self.FocusRequest = nil end
		return
	end
	Self.FocusRequest = nil
	if Overlay.AllowsSelection(Object) then Service.SelectedObject = Object end
end

const function WriteGeometry(Self : CollectionData, Root : GuiObject, Property : string, Value : any)
	if (Root :: any)[Property] ~= Value then
		Bind.SetProperty(Root, Property, Value)
		Self.Statistics.GeometryWrites += 1
	end
end

Reconcile = function(Self : CollectionData)
	if Self.Closed or Self.Running then return end
	local ExistingFailure = if Self.FailureState then Self.FailureState:Peek() else nil
	if ExistingFailure and ExistingFailure.Stage == "Render" then return end
	local Viewport, Content, Layout, Presentation = Self.Viewport, Self.Content, Self.NumericLayout, Self.Presentation
	if not Viewport or not Content or not Layout or not Presentation then return end
	Self.Running, Self.Dirty = true, false
	local Revision, RequestRevision = Self.Revision, Self.RequestRevision
	local Completed = false
	local Passed, Failure = pcall(function()
		Self.Statistics.Reconciliations += 1
		local Active = IsActive(Self)
		Presentation:SetVisible(Active)
		if not Active then
			Self.CommittedCanvasPosition = Viewport.CanvasPosition.Y
			Self.FocusRequest = nil
			for Key, Row in Self.Rows do Self.Rows[Key] = nil; DisposeRow(Self, Row) end
			Completed = true
			return
		end
		local Measurement = Presentation:Read()
		if not Measurement then return end
		local Scale = Measurement.SourceScale
		local Shape = Geometry.Geometry(Measurement.Window.X / Scale, Measurement.Window.Y / Scale, #Self.Catalog.Keys, Layout)
		local Offset = Viewport.CanvasPosition.Y / Scale
		local PendingAnchor = Self.PendingAnchor
		if PendingAnchor then
			Offset = Geometry.RestoreAnchor(PendingAnchor.Anchor, PendingAnchor.Previous, Self.Catalog, Shape)
		elseif Self.Reanchor and Self.Shape and Self.Displayed then
			local Anchor = Geometry.CaptureAnchor(Self.Catalog, Self.Shape, Self.Displayed.Offset)
			Offset = Geometry.RestoreAnchor(Anchor, Self.Catalog, Self.Catalog, Shape)
		end
		local ScrollKey = Self.PendingScrollKey
		if ScrollKey then
			local Index = Self.Catalog.Positions[ScrollKey]
			if Index then local _, Top = Geometry.Position(Shape, Index); Offset = Top end
		end
		Offset = math.clamp(Offset, 0, math.max(0, Shape.CanvasHeight - Shape.WindowHeight))
		local First, Last = Geometry.Window(Shape, Offset)
		Self.PresentationGeneration += 1
		local Requested = Snapshots.New(Self.PresentationGeneration, Offset, First, Last, Revision, Measurement.Revision)
		Self.Requested = Requested
		local function StillCurrent() : boolean
			return not Self.Closed and Self.Revision == Revision and Self.RequestRevision == RequestRevision
		end
		local function CommitOffset()
			if Viewport.CanvasSize ~= UDim2.fromOffset(0, Shape.CanvasHeight) then
				Viewport.CanvasSize = UDim2.fromOffset(0, Shape.CanvasHeight)
			end
			if ScrollKey or PendingAnchor or Self.Reanchor then
				Viewport:ResetScrollVelocity()
				Viewport.CanvasPosition = Vector2.new(0, Offset * Scale)
			end
			Presentation:Commit(Measurement, Offset)
			Self.Shape, Self.Scale, Self.Displayed = Shape, Scale, Requested
			Self.PendingScrollKey, Self.PendingAnchor, Self.Reanchor = nil, nil, false
			Self.StructuralDirty = false
			Self.CommittedCanvasPosition = Viewport.CanvasPosition.Y
		end
		if not Self.StructuralDirty and not PendingAnchor and Self.Displayed
			and Snapshots.Covers(Self.Displayed, Shape, Offset, Revision, Measurement.Revision) then
			Requested.First, Requested.Last = Self.Displayed.First, Self.Displayed.Last
			CommitOffset()
			Self.Statistics.PixelFastPaths += 1
			Completed = true
			ResolveFocus(Self)
			return
		end
		Self.Statistics.WindowRows = math.max(0, Last - First + 1)
		local MaximumWindow = math.min(#Self.Catalog.Keys,
			(math.ceil(Shape.WindowHeight / Shape.StrideVertical) + 1 + 2 * Shape.OverscanRows) * Shape.Columns)
		local Desired : { [Key] : number } = {}
		for Index = First, Last do Desired[Self.Catalog.Keys[Index]] = Index end
		local Pins, OldCount = 0, 0
		for Key, Row in Self.Rows do
			OldCount += 1
			if IsPinned(Row) and Self.Catalog.Positions[Key] then
				Desired[Key] = Self.Catalog.Positions[Key]; Pins += 1
			end
		end

		local PreviousShape = Self.Shape
		local PreviousMaximumWindow = if PreviousShape then math.min(PreviousShape.Count,
			(math.ceil(PreviousShape.WindowHeight / PreviousShape.StrideVertical) + 1 + 2 * PreviousShape.OverscanRows) * PreviousShape.Columns) else 0
		local RetainedCapacity = if PreviousMaximumWindow == MaximumWindow
			then math.min(Self.Pool.Capacity, 2 * MaximumWindow + Pins) else 0
		Self.Pool:SetCapacity(math.max(RetainedCapacity, OldCount + MaximumWindow + Pins))
		for Index = First, Last do
			local Key = Self.Catalog.Keys[Index]
			local Existing = Self.Rows[Key]
			if not Existing or Existing.Cell.CellType ~= Self.CellTypes[Key] then BuildRow(Self, Key, Index) end
			if not StillCurrent() then return end
		end
		local Entering : { any } = {}
		for _, Row in Self.Staging do table.insert(Entering, Row.Cell) end
		if #Entering > 0 and not Self.Pool:Finish(Entering, StillCurrent) then return end
		if not StillCurrent() then return end
		local Replacements : { [Key] : RowData } = {}
		for _, Row in Self.Staging do Replacements[Row.Key] = Row end

		for Key, Row in Self.Rows do
			local Index = Desired[Key]
			if Index and not Replacements[Key] and Row.PendingItem then
				Self.Pool:Refresh(Row.Cell, Key, Index, Self.Catalog.Items[Index])
				Row.Committed = false
				Row.PendingItem = false
			end
			if not StillCurrent() then return end
		end
		for Key, Row in Self.Rows do
			local Index = Desired[Key]
			if Index and not Replacements[Key] and Row.IndexState then Row.IndexState:Set(Index) end
		end
		Graph.Flush()
		if not StillCurrent() then return end
		Self.Prepared = Snapshots.New(Requested.Generation, Offset, First, Last, Revision, Measurement.Revision)
		for _, Row in Self.Staging do
			local Root = Row.Root
			if Root and Row.Alive then
				local Horizontal, Vertical = Geometry.Position(Shape, Row.Cell.Assignment.Index)
				WriteGeometry(Self, Root, "AnchorPoint", Vector2.zero)
				WriteGeometry(Self, Root, "Position", UDim2.fromOffset(Horizontal, Vertical))
				WriteGeometry(Self, Root, "Size", UDim2.fromOffset(Shape.ItemWidth, Shape.ItemHeight))
				WriteGeometry(Self, Root, "LayoutOrder", Row.Cell.Assignment.Index)
				if Root.Parent == nil then Bind.SetProperty(Root, "Parent", Content) end
				if not StillCurrent() then return end
				assert(Root.Parent == Content and Row.Alive, "Reusable cell Parent ownership changed")
			end
		end
		assert(Self.Prepared and Snapshots.Matches(Requested, Self.Prepared), "Incompatible prepared window")
		local Obsolete : { RowData } = {}
		for Key, Row in Self.Rows do
			if not Desired[Key] or Replacements[Key] then
				Self.Rows[Key] = nil; table.insert(Obsolete, Row)
			else
				local Root, Index = Row.Root, Desired[Key]
				if Root then
					local Horizontal, Vertical = Geometry.Position(Shape, Index)
					WriteGeometry(Self, Root, "AnchorPoint", Vector2.zero)
					WriteGeometry(Self, Root, "Position", UDim2.fromOffset(Horizontal, Vertical))
					WriteGeometry(Self, Root, "Size", UDim2.fromOffset(Shape.ItemWidth, Shape.ItemHeight))
					WriteGeometry(Self, Root, "LayoutOrder", Index)
				end
				if not StillCurrent() then return end
				if not Row.Committed then
					Self.Pool:Commit(Row.Cell)
					Row.Committed = true
				end
			end
		end
		for _, Row in Self.Staging do
			Self.Rows[Row.Key] = Row
			Self.Pool:Commit(Row.Cell)
			Row.Committed = true
		end
		table.clear(Self.Staging)
		CommitOffset()
		Self.ResidentFirst, Self.ResidentLast = First, Last
		Self.Prepared = nil
		Completed = true
		for _, Row in Obsolete do DisposeRow(Self, Row) end
		local Capacity = math.max(RetainedCapacity, Self.Statistics.WindowRows + MaximumWindow + Pins)
		Self.Pool:SetCapacity(Capacity)
		local UniformType : Key? = nil
		local Homogeneous = true
		for Index = First, Last do
			local CurrentType = Self.CellTypes[Self.Catalog.Keys[Index]]
			if UniformType == nil then UniformType = CurrentType elseif UniformType ~= CurrentType then Homogeneous = false; break end
		end
		if Homogeneous and UniformType ~= nil then Self.Pool:Warm(UniformType, Capacity) end
		ResolveFocus(Self)
	end)
	for _, Row in Self.Staging do DisposeRow(Self, Row) end
	table.clear(Self.Staging)
	Self.Prepared, Self.Running = nil, false
	local PendingPresentation = Self.PendingPresentation
	Self.PendingPresentation = nil
	if PendingPresentation then PendingPresentation:Destroy() end
	if not Passed then
		DirtyCollections[Self] = nil
		Self.Dirty = false
		SetFailure(Self, "Render", Failure)
	elseif not Completed and not Self.Closed then
		Self.Dirty = true
		Schedule(Self)
	end
end

const function DrainFrame(_DeltaTime : number)

	for Viewport, Self in Collections do
		if not Self.Closed and (Self.PendingScrollKey ~= nil or Self.CommittedCanvasPosition ~= Viewport.CanvasPosition.Y) then
			local Failure = if Self.FailureState then Self.FailureState:Peek() else nil
			if not Failure or Failure.Stage ~= "Render" then
				Self.Dirty = true
				DirtyCollections[Self] = true
			end
		end
	end
	if next(DirtyCollections) == nil then return end
	local Current = DirtyCollections
	DirtyCollections = {}
	for Self in Current do
		if not Self.Closed then
			Self.Statistics.FrameDispatches += 1
			local Direction = Self.NavigationDirection
			if Direction then
				local Selected = game:GetService("GuiService").SelectedObject
				local Viewport = Self.Viewport
				if not Selected or not Viewport or (not Self.Content or not Selected:IsDescendantOf(Self.Content)) or game:GetService("GuiService").MenuIsOpen then
					Self.NavigationDirection = nil
				else
					if Clock.Now() >= Self.NavigationNext then Navigate(Self, Direction); Self.NavigationNext = Clock.Now() + 0.12 end
					Schedule(Self)
				end
			end
			if Self.Dirty then Reconcile(Self) end
		end
	end
	if next(Collections) == nil and DisconnectFrame then
		local Disconnect = DisconnectFrame
		DisconnectFrame = nil
		Disconnect()
	end
end

Schedule = function(Self : CollectionData)
	if Self.Closed then return end
	DirtyCollections[Self] = true
	if not DisconnectFrame then
		DisconnectFrame = Clock.Connect("PreRender", DrainFrame)
	end
end

MarkDirty = function(Self : CollectionData)
	Self.Dirty, Self.StructuralDirty = true, true
	Schedule(Self)
end

Flush = function(Self : CollectionData)
	if Self.Closed then return end
	Graph.Flush()
	if Self.Running then MarkDirty(Self); return end
	DirtyCollections[Self] = nil
	Reconcile(Self)
end

const function ScrollToKey(Self : CollectionData, Key : Key) : boolean
	if Self.Closed then return false end
	Graph.Flush()
	if not Self.Catalog.Positions[Key] then return false end
	Self.PendingScrollKey = Key
	Self.RequestRevision += 1
	MarkDirty(Self)
	Flush(Self)
	return true
end

const function FocusKey(Self : CollectionData, Key : Key, ControlName : string?) : boolean
	if Self.Closed or not Self.Catalog.Positions[Key] or not IsActive(Self) then return false end
	if not ScrollToKey(Self, Key) then return false end
	local Previous = game:GetService("GuiService").SelectedObject
	Self.FocusRequest = { Key = Key, ControlName = ControlName, Previous = Previous, Revision = Self.Revision, Attempts = 0 }
	ResolveFocus(Self)
	return true
end

Navigate = function(Self : CollectionData, Direction : number) : boolean
	if Self.Closed or not Self.Shape or game:GetService("GuiService").MenuIsOpen then return false end
	if game:GetService("UserInputService"):GetFocusedTextBox() then return false end
	local Selected = game:GetService("GuiService").SelectedObject
	if not Selected then return false end
	for Key, Row in Self.Rows do
		for Name, Control in Row.Controls do
			if Control.Object == Selected then
				if IsPinned(Row) then return false end
				local Axis = if math.abs(Direction) == 1 then Vector2.new(Direction, 0) else Vector2.new(0, if Direction < 0 then -1 else 1)
				local Center = Selected.AbsolutePosition + Selected.AbsoluteSize / 2
				for _, Other in Row.Controls do
					local Object = Other.Object
					if Object and Object ~= Selected and Object.Selectable and Object.Visible then
						local Delta = Object.AbsolutePosition + Object.AbsoluteSize / 2 - Center
						if Delta:Dot(Axis) > 1 then return false end
					end
				end
				local Override = if Direction == -2 then Selected.NextSelectionUp elseif Direction == 2 then Selected.NextSelectionDown elseif Direction == -1 then Selected.NextSelectionLeft else Selected.NextSelectionRight
				if Override then return false end
				local Index = Self.Catalog.Positions[Key]
				if not Index then return false end
				local Columns = Self.Shape.Columns
				local Target = Index + (if math.abs(Direction) == 1 then Direction else (if Direction < 0 then -Columns else Columns))
				if math.abs(Direction) == 1 and math.floor((Target - 1) / Columns) ~= math.floor((Index - 1) / Columns) then return false end
				local NextKey = Self.Catalog.Keys[Target]
				if not NextKey then return false end
				local Neighbor = Self.Rows[NextKey]
				local NextControl = if Neighbor then Neighbor.Controls[Name] else nil
				local Object, Viewport = if NextControl then NextControl.Object else nil, Self.Viewport
				if Object and Viewport and Object.AbsolutePosition.Y >= Viewport.AbsolutePosition.Y and Object.AbsolutePosition.Y + Object.AbsoluteSize.Y <= Viewport.AbsolutePosition.Y + Viewport.AbsoluteWindowSize.Y then return false end
				return FocusKey(Self, NextKey, Name)
			end
		end
	end
	return false
end

Destroy = function(Self : CollectionData)
	if Self.Closed then return end
	Self.Closed = true
	Self.Revision += 1
	DirtyCollections[Self] = nil
	Self.FocusRequest = nil
	Self.NavigationDirection = nil
	local Viewport, Owner = Self.Viewport, Self.Owner
	Self.Viewport, Self.Content, Self.Owner, Self.Configuration = nil, nil, nil, nil
	Self.Shape, Self.NumericLayout, Self.CommittedCanvasPosition = nil, nil, nil
	if Viewport then Collections[Viewport] = nil end
	DisconnectAll(Self.Connections)
	DisconnectAll(Self.AncestorConnections)
	game:GetService("ContextActionService"):UnbindAction(Self.ActionName)
	local Failed, FirstCause = false, nil
	local function Finish(Callback : () -> ())
		local Passed, Cause = pcall(function() Callback(); return nil end)
		if not Passed and not Failed then Failed, FirstCause = true, Cause end
	end
	for Key, Row in Self.Rows do Self.Rows[Key] = nil; Finish(function() DisposeRow(Self, Row) end) end
	for _, Row in Self.Staging do Finish(function() DisposeRow(Self, Row) end) end
	table.clear(Self.Staging)
	if Self.Pool then Finish(function() Self.Pool:Destroy() end) end
	Self.Catalog = { Items = {}, Keys = {}, Positions = {} }
	table.clear(Self.CellTypes)
	Self.FailureState, Self.Failure = nil, nil
	local Presentation = Self.Presentation
	Self.Presentation, Self.Requested, Self.Prepared, Self.Displayed, Self.PendingAnchor, Self.PendingScrollKey = nil, nil, nil, nil, nil, nil
	if Presentation then
		Presentation:SetVisible(false)
		if Self.Running then Self.PendingPresentation = Presentation else Presentation:Destroy() end
	end
	if Viewport then pcall(function() Viewport.CanvasSize = UDim2.new() end) end
	if Owner then Finish(function() Graph.Dispose(Owner) end) end
	if next(Collections) == nil and DisconnectFrame then local Disconnect = DisconnectFrame; DisconnectFrame = nil; Disconnect() end
	if Failed then error(FirstCause, 0) end
end

const function Retry(Self : CollectionData)
	if Self.Closed then return end
	if Self.FailureState then Self.FailureState:Set(nil) end
	Graph.Untrack(function() ReadSources(Self, true); ReadSources(Self, false) end)
	Flush(Self)
end

const CollectionMethods = table.freeze({ ScrollToKey = ScrollToKey, FocusKey = FocusKey, Flush = Flush, Retry = Retry, GetStatistics = GetStatistics, Destroy = Destroy })
const CollectionMetatable = table.freeze({ __index = CollectionMethods })

const function New<ItemType>(Viewport : ScrollingFrame, Configuration : Options<ItemType>) : Collection
	assert(Graph.GetOwner(), "ReusableVirtualCollection requires a declaring scope")
	assert(game:GetService("RunService"):IsClient(), "ReusableVirtualCollection is client-only")
	assert(Collections[Viewport] == nil, "ReusableVirtualCollection already owns this ScrollingFrame")
	for _, Child in Viewport:GetChildren() do
		assert(not Child:IsA("UIGridStyleLayout") and not Child:IsA("UIPadding") and not Child:IsA("GuiObject"), "ReusableVirtualCollection requires a dedicated canvas without competing layout")
	end
	local Self : CollectionData = {
		Presentation = nil, PendingPresentation = nil, Requested = nil, Prepared = nil, Displayed = nil,
		PendingScrollKey = nil, PendingAnchor = nil, RequestRevision = 0, PresentationGeneration = 0,
		CellTypes = {}, Pool = nil, ResidentFirst = 1, ResidentLast = 0, StructuralDirty = true,
		Owner = nil, Viewport = Viewport, Content = nil, Configuration = Configuration :: any,
		Catalog = { Items = {}, Keys = {}, Positions = {} }, Shape = nil, NumericLayout = nil,
		Rows = {}, Staging = {}, Connections = {}, AncestorConnections = {},
		FailureState = nil, Failure = nil, Closed = false, Running = false, Dirty = false, Reanchor = false,
		Revision = 0, Scale = 1, FocusRequest = nil,
		Statistics = { ItemCount = 0, MountedRows = 0, PinnedRows = 0, StagedRows = 0, RowsConstructed = 0, RowsDisposed = 0, Reconciliations = 0, MetadataBuilds = 0, KeyVisits = 0, FrameDispatches = 0, MaximumStagedRows = 0, WindowRows = 0, Connections = 0, CellAssignments = 0, CellReuses = 0, PhysicalCells = 0, PixelFastPaths = 0, GeometryWrites = 0 },
		ActionName = "InterfacerVirtual_" .. game:GetService("HttpService"):GenerateGUID(false), NavigationDirection = nil, NavigationNext = 0,
	}
	setmetatable(Self, CollectionMetatable)
	Collections[Viewport] = Self
	local Passed, Failure = pcall(function()
		local Owner = Graph.Scope(function(OwnerHandle)
			Self.Owner = OwnerHandle
			Self.Pool = Cells.New({
				CreateCell = Configuration.CreateCell,
				SetVisible = function(Root : GuiObject, Visible : boolean) Root.Visible = Visible end,
				DestroyRoot = function(Root : GuiObject) Bind.DestroyInstance(Root) end,
				OnCreated = function(Cell : any) InitializeCell(Self, Cell) end,
				BeforeRelease = BeforeRelease,
			})
			local State = Graph.State(nil :: Failure?)
			Self.FailureState = State
			Self.Failure = Graph.Computed(function() return State:Get() end)
			Graph.Cleanup(function() Destroy(Self) end)
			Viewport.AutomaticCanvasSize, Viewport.ScrollingDirection = Enum.AutomaticSize.None, Enum.ScrollingDirection.Y
			Viewport.ClipsDescendants = true
			Viewport.VerticalScrollBarInset = Enum.ScrollBarInset.Always
			local Presentation = PresentationSurface.New(Viewport)
			Self.Presentation = Presentation
			local Content = Presentation.Content :: Frame
			Self.Content = Content
			local function Resize() Self.Reanchor = true; MarkDirty(Self) end
			Connect(Self.Connections, Viewport:GetPropertyChangedSignal("CanvasPosition"), function() Self.Dirty = true; Schedule(Self) end)
			Connect(Self.Connections, Viewport:GetPropertyChangedSignal("AbsoluteWindowSize"), Resize)
			Connect(Self.Connections, (Presentation.SourceProbe :: Frame):GetPropertyChangedSignal("AbsoluteSize"), Resize)
			Connect(Self.Connections, Viewport.Destroying, function() Destroy(Self) end)
			Connect(Self.Connections, Content.Destroying, function() Destroy(Self) end)
			Connect(Self.Connections, (Presentation.Surface :: Frame).Destroying, function() Destroy(Self) end)
			local function WatchAncestors()
				DisconnectAll(Self.AncestorConnections)
				local Current : Instance? = Viewport
				while Current do
					if Current:IsA("GuiObject") then Connect(Self.AncestorConnections, Current:GetPropertyChangedSignal("Visible"), function() MarkDirty(Self) end) end
					if Current:IsA("ScreenGui") then Connect(Self.AncestorConnections, Current:GetPropertyChangedSignal("Enabled"), function() MarkDirty(Self) end) end
					Current = Current.Parent
				end
				MarkDirty(Self)
			end
			WatchAncestors()
			Connect(Self.Connections, Viewport.AncestryChanged, WatchAncestors)
			Connect(Self.Connections, game:GetService("UserInputService").InputEnded, function(Input : InputObject)
				for _, Cell in Self.Pool.Cells do
					for _, Control in Cell.Controls do
						if Control.PressInput == Input then Control.Pressed, Control.PressInput = false, nil; MarkDirty(Self) end
					end
				end
			end)
			Connect(Self.Connections, game:GetService("UserInputService").WindowFocusReleased, function()
				for _, Row in Self.Rows do for _, Control in Row.Controls do Control.Dragging, Control.Pressed = false, false end end
				MarkDirty(Self)
			end)
			game:GetService("ContextActionService"):BindActionAtPriority(Self.ActionName, function(_Name : string, State : Enum.UserInputState, Input : InputObject)
				local Selected = game:GetService("GuiService").SelectedObject
				if not Selected or (not Self.Content or not Selected:IsDescendantOf(Self.Content)) or game:GetService("UserInputService"):GetFocusedTextBox() or game:GetService("GuiService").MenuIsOpen then Self.NavigationDirection = nil; return Enum.ContextActionResult.Pass end
				if State == Enum.UserInputState.End or State == Enum.UserInputState.Cancel then Self.NavigationDirection = nil; return Enum.ContextActionResult.Pass end
				local Direction : number
				if Input.KeyCode == Enum.KeyCode.Thumbstick1 then
					local Position = Input.Position
					if math.max(math.abs(Position.X), math.abs(Position.Y)) < 0.5 then Self.NavigationDirection = nil; return Enum.ContextActionResult.Pass end
					Direction = if math.abs(Position.Y) >= math.abs(Position.X) then (if Position.Y > 0 then -2 else 2) else (if Position.X > 0 then 1 else -1)
				else
					if State ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
					Direction = if Input.KeyCode == Enum.KeyCode.Up or Input.KeyCode == Enum.KeyCode.DPadUp then -2 elseif Input.KeyCode == Enum.KeyCode.Down or Input.KeyCode == Enum.KeyCode.DPadDown then 2 elseif Input.KeyCode == Enum.KeyCode.Left or Input.KeyCode == Enum.KeyCode.DPadLeft then -1 else 1
				end
				if Self.NavigationDirection ~= Direction then Self.NavigationNext = Clock.Now() + 0.3 end
				Self.NavigationDirection = Direction
				Schedule(Self)
				return if Navigate(Self, Direction) then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
			end, false, Enum.ContextActionPriority.High.Value - 1, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.DPadUp, Enum.KeyCode.DPadDown, Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight, Enum.KeyCode.Thumbstick1)
			Graph.Effect(function() ReadSources(Self, true) end)
			Graph.Effect(function() ReadSources(Self, false) end)
		end)
		if not Self.Closed then Self.Owner = Owner; Flush(Self) else Graph.Dispose(Owner) end
		if Self.FailureState and Self.FailureState:Peek() then error((Self.FailureState:Peek() :: Failure).Cause, 0) end
	end)
	if not Passed then Destroy(Self); error(Failure, 0) end
	return Self :: any
end

return table.freeze({ New = New })
