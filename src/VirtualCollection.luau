--!strict
const Graph = require("./Graph")
const Bind = require("./Bind")
const Edit = require("./Edit")
const Clock = require("./Clock")
const Overlay = require("./Overlay")
const Geometry = require("./VirtualGeometry")
const Synchronous = require("./VirtualSynchronous")

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
	ItemCount : number,
	MountedRows : number,
	PinnedRows : number,
	StagedRows : number,
	RowsConstructed : number,
	RowsDisposed : number,
	Reconciliations : number,
	MetadataBuilds : number,
	KeyVisits : number,
	FrameDispatches : number,
	MaximumStagedRows : number,
	WindowRows : number,
	Connections : number,
}
export type Row<ItemType> = {
	read Key : Key,
	read Item : ReadValue<ItemType>,
	read Index : ReadValue<number>,
	read RegisterControl : (
		Self : Row<ItemType>,
		Name : string,
		Control : GuiObject,
		Detector : UIDragDetector?
	) -> (),
	read GetRevision : (Self : Row<ItemType>) -> number,
	read IsCurrent : (Self : Row<ItemType>, Revision : number?) -> boolean,
}
export type Options<ItemType> = {
	Items : Graph.Reactive<{ ItemType }>,
	GetKey : (ItemType) -> Key,
	Layout : Graph.Reactive<Layout>,
	Render : (Row<ItemType>) -> GuiObject,
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
	Object : GuiObject?,
	Detector : UIDragDetector?,
	Editing : boolean,
	Dragging : boolean,
}
type RowData = {
	Key : Key,
	Item : any,
	Index : any,
	ItemState : Graph.State<any>?,
	IndexState : Graph.State<number>?,
	Owner : Graph.Node<any>?,
	Root : GuiObject?,
	Controller : CollectionData?,
	Revision : number,
	Alive : boolean,
	Committed : boolean,
	PendingItem : boolean,
	Controls : { [string] : Control },
	ControlOrder : { string },
	Connections : { RBXScriptConnection },
}
type CollectionData = {
	Owner : Graph.Node<any>?,
	Viewport : ScrollingFrame?,
	Content : Frame?,
	Configuration : Options<any>?,
	Catalog : Geometry.Catalog<any>,
	Shape : Geometry.Geometry?,
	NumericLayout : Geometry.Layout?,
	Rows : { [Key] : RowData },
	Staging : { RowData },
	Connections : { RBXScriptConnection },
	AncestorConnections : { RBXScriptConnection },
	FailureState : Graph.State<Failure?>?,
	Failure : any,
	Closed : boolean,
	Running : boolean,
	Dirty : boolean,
	Reanchor : boolean,
	Revision : number,
	Scale : number,
	Statistics : Statistics,
	CommittedCanvasPosition : number?,
	FocusRequest : {
		Key : Key,
		ControlName : string?,
		Previous : GuiObject?,
		Revision : number,
		Attempts : number,
	}?,
	ActionName : string,
	NavigationDirection : number?,
	NavigationNext : number,
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
	if State and not Self.Closed then
		State:Set({ Stage = Stage, Key = Key, Cause = Cause })
	end
end

const function Connect(
	List : { RBXScriptConnection },
	Signal : RBXScriptSignal,
	Callback : (...any) -> ()
)
	table.insert(List, Signal:Connect(Callback))
end

const function DisconnectAll(List : { RBXScriptConnection })
	for _, Connection in List do
		Connection:Disconnect()
	end
	table.clear(List)
end

const function IsActive(Self : CollectionData) : boolean
	local Current : Instance? = Self.Viewport
	local Player = game:GetService("Players").LocalPlayer
	local PlayerGui = if Player then Player:FindFirstChildOfClass("PlayerGui") else nil
	if not Current or not PlayerGui or not Current:IsDescendantOf(PlayerGui) then
		return false
	end
	while Current do
		if Current:IsA("GuiObject") and not Current.Visible then
			return false
		end
		if Current:IsA("ScreenGui") and not Current.Enabled then
			return false
		end
		Current = Current.Parent
	end
	return true
end

const function IsPinned(Row : RowData) : boolean
	for _, Control in Row.Controls do
		if Control.Editing or Control.Dragging then
			return true
		end
	end
	return false
end

const function IsCurrent(Row : RowData, Revision : number?) : boolean
	local Self = Row.Controller
	return Row.Alive
		and Row.Committed
		and Self ~= nil
		and not Self.Closed
		and Self.Rows[Row.Key] == Row
		and Self.Catalog.Positions[Row.Key] ~= nil
		and (Revision == nil or Revision == Row.Revision)
end

const function DisposeRow(Self : CollectionData, Row : RowData)
	if not Row.Alive then
		return
	end
	Row.Alive, Row.Committed = false, false
	Row.Revision += 1
	Row.PendingItem = false
	local Owner, Root = Row.Owner, Row.Root
	Row.Owner, Row.Root, Row.Controller = nil, nil, nil
	Row.ItemState, Row.IndexState, Row.Item, Row.Index = nil, nil, nil, nil
	DisconnectAll(Row.Connections)

	if Root then
		Bind.RevokeInstance(Root)
		for _, Child in Root:GetDescendants() do
			Bind.RevokeInstance(Child)
		end
	end
	if Owner then
		Graph.Dispose(Owner)
	end
	for _, Control in Row.Controls do
		local Object, Detector = Control.Object, Control.Detector
		Control.Object, Control.Detector, Control.Editing, Control.Dragging = nil, nil, false, false
		if Object and Object:IsA("TextBox") and Object:IsFocused() then
			pcall(Object.ReleaseFocus, Object, false)
		end
		if Detector then
			pcall(function()
				Detector.Enabled = false
			end)
		end
	end
	table.clear(Row.Controls)
	table.clear(Row.ControlOrder)
	if Root then
		pcall(Bind.DestroyInstance, Root)
	end
	Self.Statistics.RowsDisposed += 1
end

const function RegisterControl(
	Row : RowData,
	Name : string,
	Object : GuiObject,
	Detector : UIDragDetector?
)
	assert(Row.Alive and Row.Controller, "VirtualCollection row has been revoked")
	assert(
		Name ~= "" and Row.Controls[Name] == nil,
		"VirtualCollection control names must be unique"
	)
	local Control : Control =
		{ Object = Object, Detector = Detector, Editing = false, Dragging = false }
	Row.Controls[Name] = Control
	table.insert(Row.ControlOrder, Name)
	local function Update()
		local Self = Row.Controller
		if Self and Row.Alive then
			MarkDirty(Self)
		end
	end
	local function Cancel()
		Control.Editing, Control.Dragging = false, false
		Update()
	end
	Connect(Row.Connections, Object.Destroying, Cancel)
	Connect(Row.Connections, Object.AncestryChanged, function()
		local Root = Row.Root
		if Root and Object ~= Root and not Object:IsDescendantOf(Root) then
			Cancel()
			Control.Object, Control.Detector = nil, nil
		end
	end)
	if Object:IsA("TextBox") then
		Control.Editing = Object:IsFocused()
		Connect(Row.Connections, Object.Focused, function()
			if Row.Alive then
				Control.Editing = true
				Update()
			end
		end)
		Connect(Row.Connections, Object.FocusLost, function()
			Control.Editing = false
			Update()
		end)
	end
	if Detector then
		assert(
			Detector.Parent == Object,
			"VirtualCollection drag detector must belong to its registered control"
		)
		Connect(Row.Connections, Detector.DragStart, function()
			if Row.Alive then
				Control.Dragging = true
				Update()
			end
		end)
		Connect(Row.Connections, Detector.DragEnd, function()
			Control.Dragging = false
			Update()
		end)
		Connect(Row.Connections, Detector.Destroying, Cancel)
		Connect(Row.Connections, Detector.AncestryChanged, function()
			if Detector.Parent ~= Object then
				Cancel()
			end
		end)
		Connect(Row.Connections, Detector:GetPropertyChangedSignal("Enabled"), function()
			if not Detector.Enabled then
				Cancel()
			end
		end)
	end
end

const RowMethods = table.freeze({
	RegisterControl = RegisterControl,
	GetRevision = function(Row : RowData) : number
		return Row.Revision
	end,
	IsCurrent = IsCurrent,
})
const RowMetatable = table.freeze({ __index = RowMethods })

const function BuildRow(Self : CollectionData, Key : Key, Index : number) : RowData
	local Configuration = Self.Configuration
	assert(Configuration and Self.Owner, "VirtualCollection owner unavailable")
	local Row : RowData = {
		Key = Key,
		Item = nil,
		Index = nil,
		ItemState = nil,
		IndexState = nil,
		Owner = nil,
		Root = nil,
		Controller = Self,
		Revision = 1,
		Alive = true,
		Committed = false,
		PendingItem = false,
		Controls = {},
		ControlOrder = {},
		Connections = {},
	}
	setmetatable(Row, RowMetatable)
	table.insert(Self.Staging, Row)
	Self.Statistics.RowsConstructed += 1
	Self.Statistics.MaximumStagedRows = math.max(Self.Statistics.MaximumStagedRows, #Self.Staging)
	Graph.WithOwner(Self.Owner, function()
		Graph.WithOwner(nil, function()
			local Owner = Graph.Scope(function(RowOwner)
				Row.Owner = RowOwner
				local ItemState, IndexState =
					Graph.State(Self.Catalog.Items[Index]), Graph.State(Index)
				Row.ItemState, Row.IndexState = ItemState, IndexState
				Row.Item = Graph.Computed(function()
					return ItemState:Get()
				end)
				Row.Index = Graph.Computed(function()
					return IndexState:Get()
				end)
				Graph.Cleanup(function()
					DisposeRow(Self, Row)
				end)
				local Passed, Root = Synchronous.Run(Configuration.Render, Row :: any)
				if not Passed then
					error(Root, 0)
				end
				if not Row.Alive or Self.Closed then
					if typeof(Root) == "Instance" then
						Bind.DestroyInstance(Root)
					end
					return
				end
				assert(
					typeof(Root) == "Instance" and Root:IsA("GuiObject") and Root.Parent == nil,
					"VirtualCollection Render must return one detached GuiObject"
				)
				assert(
					Root.AutomaticSize == Enum.AutomaticSize.None,
					"VirtualCollection root AutomaticSize is reserved"
				)
				Row.Root = Root
				Graph.Cleanup(function()
					Bind.DestroyInstance(Root)
				end)
				Connect(Row.Connections, Root.Destroying, function()
					if Row.Alive then
						if rawequal(Self.Rows[Key], Row) then
							Self.Rows[Key] = nil
						end
						DisposeRow(Self, Row)
						MarkDirty(Self)
					end
				end)
				for _, Control in Row.Controls do
					local Object = Control.Object
					assert(
						Object and (Object == Root or Object:IsDescendantOf(Root)),
						"VirtualCollection controls must belong to their row"
					)
				end
			end)
			if Row.Alive then
				Row.Owner = Owner
			else
				Graph.Dispose(Owner)
			end
		end)
	end)
	return Row
end

const function ReadLayout(Configuration : Layout) : Geometry.Layout
	local Padding, Gap = Configuration.Padding or Vector2.zero, Configuration.Gap or Vector2.zero
	return {
		Kind = Configuration.Kind,
		ItemHeight = Configuration.ItemHeight,
		MinimumItemWidth = Configuration.MinimumItemWidth,
		PaddingHorizontal = Padding.X,
		PaddingVertical = Padding.Y,
		GapHorizontal = Gap.X,
		GapVertical = Gap.Y,
		OverscanRows = Configuration.OverscanRows,
	}
end

const function ReadSources(Self : CollectionData, OnlyLayout : boolean)
	local Configuration = Self.Configuration
	if not Configuration or Self.Closed then
		return
	end
	local Stage = if OnlyLayout then "Layout" else "Data"
	local Passed, Result = Synchronous.Run(function(_Argument : boolean) : any
		if OnlyLayout then
			local Layout = ReadLayout(Graph.Read(Configuration.Layout))
			Geometry.Geometry(1, 1, #Self.Catalog.Keys, Layout)
			return Layout
		end
		local Items = Graph.Read(Configuration.Items)
		assert(type(Items) == "table", "VirtualCollection Items must resolve to an array")
		return Graph.Untrack(function()
			return Geometry.Catalog(Items, Configuration.GetKey)
		end)
	end, false)
	if Self.Closed then
		return
	end
	if not Passed then
		SetFailure(Self, Stage, Result)
		return
	end

	local Viewport, Shape = Self.Viewport, Self.Shape
	local Anchor = if Viewport and Shape
		then Geometry.CaptureAnchor(Self.Catalog, Shape, Viewport.CanvasPosition.Y / Self.Scale)
		else nil
	local Previous = Self.Catalog
	if OnlyLayout then
		Self.NumericLayout = Result
	else
		Self.Catalog = Result
		Self.Statistics.MetadataBuilds += 1
		Self.Statistics.KeyVisits += #Result.Keys
	end
	Self.Revision += 1
	if Anchor and Viewport and Self.Content and Self.NumericLayout then
		local Scale = Self.Content.AbsoluteSize.X
		if Scale <= 0 then
			Scale = Self.Scale
		end
		local NewShape = Geometry.Geometry(
			Viewport.AbsoluteWindowSize.X / Scale,
			Viewport.AbsoluteWindowSize.Y / Scale,
			#Self.Catalog.Keys,
			Self.NumericLayout
		)
		Self.Shape, Self.Scale = NewShape, Scale
		Viewport.CanvasSize = UDim2.fromOffset(0, NewShape.CanvasHeight)
		Viewport.CanvasPosition =
			Vector2.new(0, Geometry.RestoreAnchor(Anchor, Previous, Self.Catalog, NewShape) * Scale)
		Self.Reanchor = false
	end
	for Key, Row in Self.Rows do
		if Self.Catalog.Positions[Key] == nil then
			Self.Rows[Key] = nil
			DisposeRow(Self, Row)
		elseif not OnlyLayout then
			Row.Revision += 1
			Row.PendingItem = true
		end
	end
	if Self.FailureState then
		local Existing = Self.FailureState:Peek()
		if not Existing or Existing.Stage == Stage or Existing.Stage == "Render" then
			Self.FailureState:Set(nil)
		end
	end
	MarkDirty(Self)
end

const function GetStatistics(Self : CollectionData) : Statistics
	local Result = table.clone(Self.Statistics)
	Result.ItemCount, Result.MountedRows, Result.PinnedRows = #Self.Catalog.Keys, 0, 0
	Result.StagedRows = #Self.Staging
	Result.Connections = #Self.Connections + #Self.AncestorConnections
	for _, Row in Self.Rows do
		Result.MountedRows += 1
		if IsPinned(Row) then
			Result.PinnedRows += 1
		end
		Result.Connections += #Row.Connections
	end
	return Result
end

const function ResolveFocus(Self : CollectionData)
	local Request, Viewport = Self.FocusRequest, Self.Viewport
	if not Request or not Viewport or Self.Closed then
		return
	end
	local Service = game:GetService("GuiService")
	if
		Service.MenuIsOpen
		or Self.Revision ~= Request.Revision
		or Service.SelectedObject ~= Request.Previous
	then
		Self.FocusRequest = nil
		return
	end
	local Row = Self.Rows[Request.Key]
	if not Row or not Row.Alive then
		Self.FocusRequest = nil
		return
	end
	local Control = if Request.ControlName then Row.Controls[Request.ControlName] else nil
	Control = Control or Row.Controls[Row.ControlOrder[1]]
	if not Control or not Control.Object then
		Self.FocusRequest = nil
		return
	end
	local Object = Control.Object
	local Root = Row.Root
	if not Root or (Object ~= Root and not Object:IsDescendantOf(Root)) then
		Self.FocusRequest = nil
		return
	end
	if not Object.Visible or not Object.Selectable then
		Self.FocusRequest = nil
		return
	end
	local Top, Bottom =
		Viewport.AbsolutePosition.Y, Viewport.AbsolutePosition.Y + Viewport.AbsoluteWindowSize.Y
	if
		Object.AbsoluteSize.Y <= 0
		or Object.AbsolutePosition.Y < Top - 1
		or Object.AbsolutePosition.Y + Object.AbsoluteSize.Y > Bottom + 1
	then
		Request.Attempts += 1
		if Request.Attempts <= 2 then
			MarkDirty(Self)
		else
			Self.FocusRequest = nil
		end
		return
	end
	Self.FocusRequest = nil
	if Overlay.AllowsSelection(Object) then
		Service.SelectedObject = Object
	end
end

Reconcile = function(Self : CollectionData)
	if Self.Closed or Self.Running then
		return
	end
	local ExistingFailure = if Self.FailureState then Self.FailureState:Peek() else nil
	if ExistingFailure and ExistingFailure.Stage == "Render" then
		return
	end
	local Viewport, Content, Layout = Self.Viewport, Self.Content, Self.NumericLayout
	if not Viewport or not Content or not Layout then
		return
	end
	Self.Running, Self.Dirty = true, false
	local Revision = Self.Revision
	local Passed, Failure = pcall(function()
		Self.Statistics.Reconciliations += 1
		local Scale = Content.AbsoluteSize.X
		if Scale <= 0 or not IsActive(Self) then
			Self.CommittedCanvasPosition = Viewport.CanvasPosition.Y
			Self.FocusRequest = nil
			for Key, Row in Self.Rows do
				Self.Rows[Key] = nil
				DisposeRow(Self, Row)
			end
			return
		end
		Self.Scale = Scale
		local Shape = Geometry.Geometry(
			Viewport.AbsoluteWindowSize.X / Scale,
			Viewport.AbsoluteWindowSize.Y / Scale,
			#Self.Catalog.Keys,
			Layout
		)
		local PreviousShape = Self.Shape
		if PreviousShape and Self.Reanchor then
			local Anchor = Geometry.CaptureAnchor(
				Self.Catalog,
				PreviousShape,
				Viewport.CanvasPosition.Y / Scale
			)
			Viewport.CanvasSize = UDim2.fromOffset(0, Shape.CanvasHeight)
			Viewport.CanvasPosition = Vector2.new(
				0,
				Geometry.RestoreAnchor(Anchor, Self.Catalog, Self.Catalog, Shape) * Scale
			)
		end
		Self.Reanchor, Self.Shape = false, Shape
		Viewport.CanvasSize = UDim2.fromOffset(0, Shape.CanvasHeight)
		local CanvasPosition = Viewport.CanvasPosition.Y
		local First, Last = Geometry.Window(Shape, CanvasPosition / Scale)
		Self.Statistics.WindowRows = math.max(0, Last - First + 1)
		local Desired : { [Key] : number } = {}
		for Index = First, Last do
			Desired[Self.Catalog.Keys[Index]] = Index
		end
		for Key, Row in Self.Rows do
			if IsPinned(Row) and Self.Catalog.Positions[Key] then
				Desired[Key] = Self.Catalog.Positions[Key]
			end
		end

		for Index = First, Last do
			local Key = Self.Catalog.Keys[Index]
			if not Self.Rows[Key] then
				BuildRow(Self, Key, Index)
			end
			if Self.Closed or Self.Revision ~= Revision then
				return
			end
		end
		for Key, Row in Self.Rows do
			if not Desired[Key] then
				Self.Rows[Key] = nil
				DisposeRow(Self, Row)
			end
		end
		for _, Row in Self.Staging do
			if Row.Alive then
				Self.Rows[Row.Key] = Row
			end
		end
		for Key, Row in Self.Rows do
			local Index, Root = Desired[Key], Row.Root
			if Index and Root and Row.Alive then
				local ItemState, IndexState = Row.ItemState, Row.IndexState
				if
					ItemState
					and (
						Row.PendingItem or not rawequal(ItemState:Peek(), Self.Catalog.Items[Index])
					)
				then
					Row.PendingItem = false
					ItemState:Set(Self.Catalog.Items[Index], true)
					Row.Item:Set(Self.Catalog.Items[Index], true)
				end
				if IndexState then
					IndexState:Set(Index)
				end
				local Horizontal, Vertical = Geometry.Position(Shape, Index)
				Root.AnchorPoint = Vector2.zero
				Root.Position, Root.Size, Root.LayoutOrder =
					UDim2.fromOffset(Horizontal, Vertical),
					UDim2.fromOffset(Shape.ItemWidth, Shape.ItemHeight),
					Index
			end
		end
		Graph.Flush()
		for _, Row in Self.Staging do
			if Self.Closed or Self.Revision ~= Revision then
				return
			end
			local Root = Row.Root
			if Root and Row.Alive then
				Row.Committed = true
				Bind.SetProperty(Root, "Parent", Content)
				if not Row.Alive or Self.Closed then
					return
				end
			end
		end
		table.clear(Self.Staging)
		Self.CommittedCanvasPosition = CanvasPosition
		ResolveFocus(Self)
	end)

	for _, Row in Self.Staging do
		if Self.Rows[Row.Key] == Row then
			Self.Rows[Row.Key] = nil
		end
		DisposeRow(Self, Row)
	end
	table.clear(Self.Staging)
	Self.Running = false
	if not Passed then
		DirtyCollections[Self] = nil
		Self.Dirty = false
		SetFailure(Self, "Render", Failure)
	end
end

const function DrainFrame(_DeltaTime : number)
	for Viewport, Self in Collections do
		if not Self.Closed and Self.CommittedCanvasPosition ~= Viewport.CanvasPosition.Y then
			local Failure = if Self.FailureState then Self.FailureState:Peek() else nil
			if not Failure or Failure.Stage ~= "Render" then
				Self.Dirty = true
				DirtyCollections[Self] = true
			end
		end
	end
	if next(DirtyCollections) == nil then
		return
	end
	local Current = DirtyCollections
	DirtyCollections = {}
	for Self in Current do
		if not Self.Closed then
			Self.Statistics.FrameDispatches += 1
			local Direction = Self.NavigationDirection
			if Direction then
				local Selected = game:GetService("GuiService").SelectedObject
				local Viewport = Self.Viewport
				if
					not Selected
					or not Viewport
					or not Selected:IsDescendantOf(Viewport)
					or game:GetService("GuiService").MenuIsOpen
				then
					Self.NavigationDirection = nil
				else
					if Clock.Now() >= Self.NavigationNext then
						Navigate(Self, Direction)
						Self.NavigationNext = Clock.Now() + 0.12
					end
					Schedule(Self)
				end
			end
			if Self.Dirty then
				Reconcile(Self)
			end
		end
	end
	if next(Collections) == nil and DisconnectFrame then
		local Disconnect = DisconnectFrame
		DisconnectFrame = nil
		Disconnect()
	end
end

Schedule = function(Self : CollectionData)
	if Self.Closed then
		return
	end
	DirtyCollections[Self] = true
	if not DisconnectFrame then
		if Clock.IsManual() then
			DisconnectFrame = Clock.Connect("PreRender", DrainFrame)
		else
			local RunService = game:GetService("RunService")
			local Name = "InterfacerVirtualRender_"
				.. game:GetService("HttpService"):GenerateGUID(false)
			RunService:BindToRenderStep(Name, Enum.RenderPriority.Last.Value, DrainFrame)
			DisconnectFrame = function()
				RunService:UnbindFromRenderStep(Name)
			end
		end
	end
end

MarkDirty = function(Self : CollectionData)
	Self.Dirty = true
	Schedule(Self)
end

Flush = function(Self : CollectionData)
	if Self.Closed then
		return
	end
	Graph.Flush()
	if Self.Running then
		MarkDirty(Self)
		return
	end
	DirtyCollections[Self] = nil
	Reconcile(Self)
end

const function ScrollToKey(Self : CollectionData, Key : Key) : boolean
	if Self.Closed then
		return false
	end
	Flush(Self)
	local Index, Shape, Viewport = Self.Catalog.Positions[Key], Self.Shape, Self.Viewport
	if not Index or not Shape or not Viewport then
		return false
	end
	local _, Top = Geometry.Position(Shape, Index)
	Viewport:ResetScrollVelocity()
	Viewport.CanvasPosition = Vector2.new(
		0,
		math.clamp(Top, 0, math.max(0, Shape.CanvasHeight - Shape.WindowHeight)) * Self.Scale
	)
	MarkDirty(Self)
	Flush(Self)
	return true
end

const function FocusKey(Self : CollectionData, Key : Key, ControlName : string?) : boolean
	if Self.Closed or not Self.Catalog.Positions[Key] or not IsActive(Self) then
		return false
	end
	if not ScrollToKey(Self, Key) then
		return false
	end
	local Previous = game:GetService("GuiService").SelectedObject
	Self.FocusRequest = {
		Key = Key,
		ControlName = ControlName,
		Previous = Previous,
		Revision = Self.Revision,
		Attempts = 0,
	}
	ResolveFocus(Self)
	return true
end

Navigate = function(Self : CollectionData, Direction : number) : boolean
	if Self.Closed or not Self.Shape or game:GetService("GuiService").MenuIsOpen then
		return false
	end
	if game:GetService("UserInputService"):GetFocusedTextBox() then
		return false
	end
	local Selected = game:GetService("GuiService").SelectedObject
	if not Selected then
		return false
	end
	for Key, Row in Self.Rows do
		for Name, Control in Row.Controls do
			if Control.Object == Selected then
				if IsPinned(Row) then
					return false
				end
				local Axis = if math.abs(Direction) == 1
					then Vector2.new(Direction, 0)
					else Vector2.new(0, if Direction < 0 then -1 else 1)
				local Center = Selected.AbsolutePosition + Selected.AbsoluteSize / 2
				for _, Other in Row.Controls do
					local Object = Other.Object
					if Object and Object ~= Selected and Object.Selectable and Object.Visible then
						local Delta = Object.AbsolutePosition + Object.AbsoluteSize / 2 - Center
						if Delta:Dot(Axis) > 1 then
							return false
						end
					end
				end
				local Override = if Direction == -2
					then Selected.NextSelectionUp
					elseif Direction == 2 then Selected.NextSelectionDown
					elseif Direction == -1 then Selected.NextSelectionLeft
					else Selected.NextSelectionRight
				if Override then
					return false
				end
				local Index = Self.Catalog.Positions[Key]
				if not Index then
					return false
				end
				local Columns = Self.Shape.Columns
				local Target = Index
					+ (
						if math.abs(Direction) == 1
							then Direction
							else (if Direction < 0 then -Columns else Columns)
					)
				if
					math.abs(Direction) == 1
					and math.floor((Target - 1) / Columns) ~= math.floor((Index - 1) / Columns)
				then
					return false
				end
				local NextKey = Self.Catalog.Keys[Target]
				if not NextKey then
					return false
				end
				local Neighbor = Self.Rows[NextKey]
				local NextControl = if Neighbor then Neighbor.Controls[Name] else nil
				local Object, Viewport =
					if NextControl then NextControl.Object else nil, Self.Viewport
				if
					Object
					and Viewport
					and Object.AbsolutePosition.Y >= Viewport.AbsolutePosition.Y
					and Object.AbsolutePosition.Y + Object.AbsoluteSize.Y
						<= Viewport.AbsolutePosition.Y + Viewport.AbsoluteWindowSize.Y
				then
					return false
				end
				return FocusKey(Self, NextKey, Name)
			end
		end
	end
	return false
end

Destroy = function(Self : CollectionData)
	if Self.Closed then
		return
	end
	Self.Closed = true
	Self.Revision += 1
	DirtyCollections[Self] = nil
	Self.FocusRequest = nil
	Self.NavigationDirection = nil
	local Viewport, Content, Owner = Self.Viewport, Self.Content, Self.Owner
	Self.Viewport, Self.Content, Self.Owner, Self.Configuration = nil, nil, nil, nil
	Self.Shape, Self.NumericLayout, Self.CommittedCanvasPosition = nil, nil, nil
	if Viewport then
		Collections[Viewport] = nil
	end
	DisconnectAll(Self.Connections)
	DisconnectAll(Self.AncestorConnections)
	game:GetService("ContextActionService"):UnbindAction(Self.ActionName)
	for Key, Row in Self.Rows do
		Self.Rows[Key] = nil
		DisposeRow(Self, Row)
	end
	for _, Row in Self.Staging do
		DisposeRow(Self, Row)
	end
	table.clear(Self.Staging)
	Self.Catalog = { Items = {}, Keys = {}, Positions = {} }
	Self.FailureState, Self.Failure = nil, nil
	if Content then
		Bind.DestroyInstance(Content)
	end
	if Viewport then
		pcall(function()
			Viewport.CanvasSize = UDim2.new()
		end)
	end
	if Owner then
		Graph.Dispose(Owner)
	end
	if next(Collections) == nil and DisconnectFrame then
		local Disconnect = DisconnectFrame
		DisconnectFrame = nil
		Disconnect()
	end
end

const function Retry(Self : CollectionData)
	if Self.Closed then
		return
	end
	if Self.FailureState then
		Self.FailureState:Set(nil)
	end
	Graph.Untrack(function()
		ReadSources(Self, true)
		ReadSources(Self, false)
	end)
	Flush(Self)
end

const CollectionMethods = table.freeze({
	ScrollToKey = ScrollToKey,
	FocusKey = FocusKey,
	Flush = Flush,
	Retry = Retry,
	GetStatistics = GetStatistics,
	Destroy = Destroy,
})
const CollectionMetatable = table.freeze({ __index = CollectionMethods })

const function New<ItemType>(Viewport : ScrollingFrame, Configuration : Options<ItemType>) : Collection
	assert(Graph.GetOwner(), "VirtualCollection requires a declaring scope")
	assert(game:GetService("RunService"):IsClient(), "VirtualCollection is client-only")
	assert(Collections[Viewport] == nil, "VirtualCollection already owns this ScrollingFrame")
	for _, Child in Viewport:GetChildren() do
		assert(
			not Child:IsA("UIGridStyleLayout")
				and not Child:IsA("UIPadding")
				and not Child:IsA("GuiObject"),
			"VirtualCollection requires a dedicated canvas without competing layout"
		)
	end
	local Self : CollectionData = {
		Owner = nil,
		Viewport = Viewport,
		Content = nil,
		Configuration = Configuration :: any,
		Catalog = { Items = {}, Keys = {}, Positions = {} },
		Shape = nil,
		NumericLayout = nil,
		Rows = {},
		Staging = {},
		Connections = {},
		AncestorConnections = {},
		FailureState = nil,
		Failure = nil,
		Closed = false,
		Running = false,
		Dirty = false,
		Reanchor = false,
		Revision = 0,
		Scale = 1,
		FocusRequest = nil,
		Statistics = {
			ItemCount = 0,
			MountedRows = 0,
			PinnedRows = 0,
			StagedRows = 0,
			RowsConstructed = 0,
			RowsDisposed = 0,
			Reconciliations = 0,
			MetadataBuilds = 0,
			KeyVisits = 0,
			FrameDispatches = 0,
			MaximumStagedRows = 0,
			WindowRows = 0,
			Connections = 0,
		},
		ActionName = "InterfacerVirtual_" .. game:GetService("HttpService"):GenerateGUID(false),
		NavigationDirection = nil,
		NavigationNext = 0,
	}
	setmetatable(Self, CollectionMetatable)
	Collections[Viewport] = Self
	local Passed, Failure = pcall(function()
		local Owner = Graph.Scope(function(OwnerHandle)
			Self.Owner = OwnerHandle
			local State = Graph.State(nil :: Failure?)
			Self.FailureState = State
			Self.Failure = Graph.Computed(function()
				return State:Get()
			end)
			Graph.Cleanup(function()
				Destroy(Self)
			end)
			Viewport.AutomaticCanvasSize, Viewport.ScrollingDirection =
				Enum.AutomaticSize.None, Enum.ScrollingDirection.Y
			Viewport.ClipsDescendants = true
			Viewport.VerticalScrollBarInset = Enum.ScrollBarInset.Always
			local Content = Edit.New(
				"Frame",
				{
					Name = "InterfacerVirtualContent",
					Size = UDim2.fromOffset(1, 1),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					Selectable = false,
					Parent = Viewport,
				}
			) :: Frame
			Self.Content = Content
			local function Resize()
				Self.Reanchor = true
				MarkDirty(Self)
			end
			Connect(
				Self.Connections,
				Viewport:GetPropertyChangedSignal("CanvasPosition"),
				function()
					MarkDirty(Self)
				end
			)
			Connect(
				Self.Connections,
				Viewport:GetPropertyChangedSignal("AbsoluteWindowSize"),
				Resize
			)
			Connect(Self.Connections, Content:GetPropertyChangedSignal("AbsoluteSize"), Resize)
			Connect(Self.Connections, Viewport.Destroying, function()
				Destroy(Self)
			end)
			Connect(Self.Connections, Content.Destroying, function()
				Destroy(Self)
			end)
			local function WatchAncestors()
				DisconnectAll(Self.AncestorConnections)
				local Current : Instance? = Viewport
				while Current do
					if Current:IsA("GuiObject") then
						Connect(
							Self.AncestorConnections,
							Current:GetPropertyChangedSignal("Visible"),
							function()
								MarkDirty(Self)
							end
						)
					end
					if Current:IsA("ScreenGui") then
						Connect(
							Self.AncestorConnections,
							Current:GetPropertyChangedSignal("Enabled"),
							function()
								MarkDirty(Self)
							end
						)
					end
					Current = Current.Parent
				end
				MarkDirty(Self)
			end
			WatchAncestors()
			Connect(Self.Connections, Viewport.AncestryChanged, WatchAncestors)
			Connect(
				Self.Connections,
				game:GetService("UserInputService").WindowFocusReleased,
				function()
					for _, Row in Self.Rows do
						for _, Control in Row.Controls do
							Control.Dragging = false
						end
					end
					MarkDirty(Self)
				end
			)
			game:GetService("ContextActionService"):BindActionAtPriority(
				Self.ActionName,
				function(_Name : string, State : Enum.UserInputState, Input : InputObject)
					local Selected = game:GetService("GuiService").SelectedObject
					if
						not Selected
						or not Selected:IsDescendantOf(Viewport)
						or game:GetService("UserInputService"):GetFocusedTextBox()
						or game:GetService("GuiService").MenuIsOpen
					then
						Self.NavigationDirection = nil
						return Enum.ContextActionResult.Pass
					end
					if State == Enum.UserInputState.End or State == Enum.UserInputState.Cancel then
						Self.NavigationDirection = nil
						return Enum.ContextActionResult.Pass
					end
					local Direction : number
					if Input.KeyCode == Enum.KeyCode.Thumbstick1 then
						local Position = Input.Position
						if math.max(math.abs(Position.X), math.abs(Position.Y)) < 0.5 then
							Self.NavigationDirection = nil
							return Enum.ContextActionResult.Pass
						end
						Direction = if math.abs(Position.Y) >= math.abs(Position.X)
							then (if Position.Y > 0 then -2 else 2)
							else (if Position.X > 0 then 1 else -1)
					else
						if State ~= Enum.UserInputState.Begin then
							return Enum.ContextActionResult.Pass
						end
						Direction = if Input.KeyCode == Enum.KeyCode.Up
								or Input.KeyCode == Enum.KeyCode.DPadUp
							then -2
							elseif
								Input.KeyCode == Enum.KeyCode.Down
								or Input.KeyCode == Enum.KeyCode.DPadDown
							then 2
							elseif
								Input.KeyCode == Enum.KeyCode.Left
								or Input.KeyCode == Enum.KeyCode.DPadLeft
							then -1
							else 1
					end
					if Self.NavigationDirection ~= Direction then
						Self.NavigationNext = Clock.Now() + 0.3
					end
					Self.NavigationDirection = Direction
					Schedule(Self)
					return if Navigate(Self, Direction)
						then Enum.ContextActionResult.Sink
						else Enum.ContextActionResult.Pass
				end,
				false,
				Enum.ContextActionPriority.High.Value - 1,
				Enum.KeyCode.Up,
				Enum.KeyCode.Down,
				Enum.KeyCode.Left,
				Enum.KeyCode.Right,
				Enum.KeyCode.DPadUp,
				Enum.KeyCode.DPadDown,
				Enum.KeyCode.DPadLeft,
				Enum.KeyCode.DPadRight,
				Enum.KeyCode.Thumbstick1
			)
			Graph.Effect(function()
				ReadSources(Self, true)
			end)
			Graph.Effect(function()
				ReadSources(Self, false)
			end)
		end)
		if not Self.Closed then
			Self.Owner = Owner
			Flush(Self)
		else
			Graph.Dispose(Owner)
		end
		if Self.FailureState and Self.FailureState:Peek() then
			error((Self.FailureState:Peek() :: Failure).Cause, 0)
		end
	end)
	if not Passed then
		Destroy(Self)
		error(Failure, 0)
	end
	return Self :: any
end

return table.freeze({ New = New })
