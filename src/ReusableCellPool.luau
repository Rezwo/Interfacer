--!strict
const Graph = require("./Graph")
const Synchronous = require("./VirtualSynchronous")

export type Key = string | number
export type ReadValue<ValueType> = setmetatable<{
	read Get : (Self : any) -> ValueType,
	read Peek : (Self : any) -> ValueType,
}, { __call : (Self : any) -> ValueType }>
export type Assignment<ItemType> = {
	read Key : Key,
	read Generation : number,
	read Index : number,
	GetItem : (Self : any) -> ItemType?,
	IsCurrent : (Self : any) -> boolean,
	Guard : (Self : any, Callback : (...any) -> ()) -> (...any) -> (),
	Connect : (
		Self : any,
		Signal : RBXScriptSignal,
		Callback : (...any) -> ()
	) -> RBXScriptConnection,
	Cleanup : (Self : any, Callback : () -> ()) -> (),
}
export type Cell<ItemType> = {
	read Item : ReadValue<ItemType?>,
	read Index : ReadValue<number?>,
	RegisterControl : (
		Self : any,
		Name : string,
		Object : GuiObject,
		Detector : UIDragDetector?
	) -> (),
}
export type Definition<ItemType> = {
	Root : GuiObject,
	Reset : (Assignment<ItemType>) -> (),
	Attach : (Assignment<ItemType>) -> (),
}
export type Configuration<ItemType> = {
	CreateCell : (Cell<ItemType>, Key) -> Definition<ItemType>,
	SetVisible : (GuiObject, boolean) -> (),
	DestroyRoot : (GuiObject) -> (),
	OnCreated : ((any) -> ())?,
	BeforeRelease : ((any) -> ())?,
}

type AssignmentData = {
	Key : Key,
	Generation : number,
	Index : number,
	Payload : any,
	Alive : boolean,
	Active : boolean,
	Cell : any,
	Owner : Graph.Node<any>?,
	Connections : { RBXScriptConnection },
	Cleanups : { () -> () },
	Guards : { { Callback : ((...any) -> ())? } },
}
type CellData = {
	Item : any,
	Index : any,
	ItemState : Graph.State<any>,
	IndexState : Graph.State<number?>,
	Owner : Graph.Node<any>?,
	Root : GuiObject?,
	Definition : Definition<any>?,
	CellType : Key,
	Assignment : AssignmentData?,
	Alive : boolean,
	Pool : any,
	IdleIndex : number?,
	Controls : { [string] : any },
	ControlOrder : { string },
	Connections : { RBXScriptConnection },
}
type PoolData = {
	Owner : Graph.Owner?,
	Configuration : Configuration<any>?,
	Cells : { CellData },
	Available : { [Key] : { CellData } },
	Capacity : number,
	Generation : number,
	Closed : boolean,
	Constructed : number,
	Destroyed : number,
	Assignments : number,
	Reuses : number,
}

local Discard : (PoolData, CellData) -> ()
local Release : (PoolData, CellData) -> ()
local Destroy : (PoolData) -> ()

const function IsCurrent(Self : AssignmentData) : boolean
	local Cell = Self.Cell
	return Self.Alive
			and Self.Active
			and Cell ~= nil
			and Cell.Alive
			and Cell.Assignment == Self
			and not Cell.Pool.Closed
		or false
end

const function GetItem(Self : AssignmentData) : any
	local Cell : CellData? = Self.Cell
	return if Self.Alive and Cell and Cell.Alive and not Cell.Pool.Closed then Self.Payload else nil
end

const function Guard(Self : AssignmentData, Callback : (...any) -> ()) : (...any) -> ()
	assert(Self.Alive, "Reusable assignment has been revoked")
	local Entry = { Callback = Callback :: ((...any) -> ())? }
	table.insert(Self.Guards, Entry)
	return function(... : any)
		local Current = Entry.Callback
		if Current and IsCurrent(Self) then
			Current(...)
		end
	end
end

const function Connect(
	Self : AssignmentData,
	Signal : RBXScriptSignal,
	Callback : (...any) -> ()
) : RBXScriptConnection
	assert(Self.Alive, "Reusable assignment has been revoked")
	local Connection = Signal:Connect(Guard(Self, Callback))
	table.insert(Self.Connections, Connection)
	return Connection
end

const AssignmentMethods = table.freeze({
	IsCurrent = IsCurrent,
	GetItem = GetItem,
	Guard = Guard,
	Connect = Connect,
	Cleanup = function(Self : AssignmentData, Callback : () -> ())
		assert(Self.Alive, "Reusable assignment has been revoked")
		table.insert(Self.Cleanups, Callback)
	end,
})
const AssignmentMetatable = table.freeze({ __index = AssignmentMethods })

const function RegisterControl(
	Self : CellData,
	Name : string,
	Object : GuiObject,
	Detector : UIDragDetector?
)
	assert(Self.Alive and not Self.Definition, "Register controls only during CreateCell")
	assert(Name ~= "" and not Self.Controls[Name], "Reusable cell control names must be unique")
	Self.Controls[Name] =
		{ Object = Object, Detector = Detector, Editing = false, Dragging = false, Pressed = false }
	table.insert(Self.ControlOrder, Name)
end

const CellMetatable =
	table.freeze({ __index = table.freeze({ RegisterControl = RegisterControl }) })

const function Invoke(
	Owner : Graph.Owner | Graph.Node<any>?,
	Callback : (any) -> any,
	Argument : any
) : any
	return Graph.WithOwner(Owner, function()
		local Passed, Result = Synchronous.Run(Callback, Argument)
		if not Passed then
			error(Result, 0)
		end
		return Result
	end)
end

const function Revoke(Assignment : AssignmentData)
	if not Assignment.Alive then
		return
	end
	Assignment.Alive, Assignment.Active = false, false
	Assignment.Payload, Assignment.Cell = nil, nil
	for _, Entry in Assignment.Guards do
		Entry.Callback = nil
	end
	table.clear(Assignment.Guards)
	for _, Connection in Assignment.Connections do
		Connection:Disconnect()
	end
	table.clear(Assignment.Connections)
	local Failed, FirstCause = false, nil
	for Index = #Assignment.Cleanups, 1, -1 do
		local Callback = Assignment.Cleanups[Index]
		Assignment.Cleanups[Index] = nil
		local Passed, Cause = Synchronous.Run(function(_Argument : boolean)
			Callback()
			return nil
		end, false)
		if not Passed and not Failed then
			Failed, FirstCause = true, Cause
		end
	end
	local Owner = Assignment.Owner
	Assignment.Owner = nil
	if Owner then
		Graph.Dispose(Owner)
	end
	if Failed then
		error(FirstCause, 0)
	end
end

Discard = function(Self : PoolData, Cell : CellData)
	if not Cell.Alive then
		return
	end
	Cell.Alive = false
	local Bucket = Self.Available[Cell.CellType]
	if Bucket and Cell.IdleIndex then
		table.remove(Bucket, Cell.IdleIndex)
		for Index = Cell.IdleIndex, #Bucket do
			Bucket[Index].IdleIndex = Index
		end
		Cell.IdleIndex = nil
		if #Bucket == 0 then
			Self.Available[Cell.CellType] = nil
		end
	end
	local Assignment = Cell.Assignment
	Cell.Assignment = nil
	local Passed, Cause = true, nil
	if Assignment then
		Passed, Cause = pcall(Revoke, Assignment)
	end
	for _, Connection in Cell.Connections do
		Connection:Disconnect()
	end
	table.clear(Cell.Connections)
	local Root, Owner = Cell.Root, Cell.Owner
	Cell.Root, Cell.Owner, Cell.Definition, Cell.Pool = nil, nil, nil, nil
	table.clear(Cell.Controls)
	table.clear(Cell.ControlOrder)
	Cell.ItemState:Set(nil)
	Cell.IndexState:Set(nil)
	if Owner then
		Graph.Dispose(Owner)
	end
	local RootPassed, RootCause = pcall(function()
		local Configuration = Self.Configuration
		if Root and Configuration then
			Configuration.DestroyRoot(Root)
		end
	end)
	Self.Destroyed += 1
	for Index, Candidate in Self.Cells do
		if Candidate == Cell then
			table.remove(Self.Cells, Index)
			break
		end
	end
	if not Passed then
		error(Cause, 0)
	end
	if not RootPassed then
		error(RootCause, 0)
	end
end

Release = function(Self : PoolData, Cell : CellData)
	local Assignment = Cell.Assignment
	if not Cell.Alive or not Assignment then
		return
	end
	Cell.Assignment = nil

	local Passed, Cause = pcall(Revoke, Assignment)
	local Released, ReleaseCause = pcall(function()
		local Configuration = Self.Configuration
		if Configuration and Configuration.BeforeRelease then
			Configuration.BeforeRelease(Cell)
		end
		if Cell.Root and Configuration then
			Configuration.SetVisible(Cell.Root, false)
		end
		Cell.ItemState:Set(nil)
		Cell.IndexState:Set(nil)
	end)
	if not Passed or not Released then
		pcall(Discard, Self, Cell)
		error(if not Passed then Cause else ReleaseCause, 0)
	end
	if Cell.Alive and not Self.Closed then
		local Bucket = Self.Available[Cell.CellType]
		if not Bucket then
			Bucket = {}
			Self.Available[Cell.CellType] = Bucket
		end
		table.insert(Bucket, Cell)
		Cell.IdleIndex = #Bucket
	end
end

const function Build(Self : PoolData, CellType : Key) : CellData
	assert(#Self.Cells < Self.Capacity, "Reusable cell capacity exhausted by live assignments")
	local Configuration = Self.Configuration
	assert(Configuration, "Reusable pool configuration released")
	local Cell : CellData
	local Owner : Graph.Node<any>? = nil
	local Passed, Cause = pcall(function()
		Graph.WithOwner(Self.Owner, function()
			Owner = Graph.Scope(function(CellOwner : Graph.Node<any>)
				local ItemState, IndexState = Graph.State(nil :: any), Graph.State(nil :: number?)
				Cell = setmetatable({
					Item = Graph.Computed(function()
						return ItemState:Get()
					end),
					Index = Graph.Computed(function()
						return IndexState:Get()
					end),
					ItemState = ItemState,
					IndexState = IndexState,
					Owner = CellOwner,
					Root = nil,
					Definition = nil,
					CellType = CellType,
					Assignment = nil,
					Alive = true,
					Pool = Self,
					Controls = {},
					ControlOrder = {},
					Connections = {},
				}, CellMetatable) :: any
				table.insert(Self.Cells, Cell)
				Self.Constructed += 1
				local Definition : Definition<any> = Invoke(CellOwner, function(Value)
					return Configuration.CreateCell(Value, CellType)
				end, Cell)
				assert(Cell.Alive and not Self.Closed, "Collection disposed during CreateCell")
				assert(
					Definition
						and Definition.Root
						and type(Definition.Reset) == "function"
						and type(Definition.Attach) == "function",
					"CreateCell must return Root, Reset and Attach"
				)
				Cell.Root, Cell.Definition = Definition.Root, Definition
				Configuration.SetVisible(Definition.Root, false)
				if Configuration.OnCreated then
					Configuration.OnCreated(Cell)
				end
			end)
		end)
	end)
	if not Passed then
		if Cell then
			pcall(Discard, Self, Cell)
		elseif Owner then
			Graph.Dispose(Owner)
		end
		error(Cause, 0)
	end
	return Cell
end

const function Warm(Self : PoolData, CellType : Key, Count : number)
	assert(not Self.Closed, "Reusable cell pool destroyed")
	assert(
		Count >= 0 and Count % 1 == 0 and Count <= Self.Capacity,
		"Invalid reusable warm capacity"
	)
	while #Self.Cells < Count do
		local Cell = Build(Self, CellType)
		assert(Cell.Alive and not Self.Closed, "Collection disposed during warm construction")
		local Bucket = Self.Available[CellType]
		if not Bucket then
			Bucket = {}
			Self.Available[CellType] = Bucket
		end
		table.insert(Bucket, Cell)
		Cell.IdleIndex = #Bucket
	end
end

const function Stage(
	Self : PoolData,
	Key : Key,
	Index : number,
	Item : any,
	CellType : Key,
	Preferred : CellData?
) : CellData
	assert(not Self.Closed, "Reusable cell pool destroyed")
	local Cell : CellData? = Preferred
	if Cell then
		assert(
			Cell.Alive
				and Cell.Pool == Self
				and Cell.CellType == CellType
				and not Cell.Assignment
				and not Cell.IdleIndex,
			"Preferred cell must be live and unassigned"
		)
	end
	local Bucket = Self.Available[CellType]
	if not Cell and Bucket then
		Cell = table.remove(Bucket)
		if Cell then
			Cell.IdleIndex = nil
		end
		if #Bucket == 0 then
			Self.Available[CellType] = nil
		end
	end
	if Cell then
		Self.Reuses += 1
	else
		if #Self.Cells >= Self.Capacity then
			for _, Candidate in Self.Cells do
				if not Candidate.Assignment then
					Discard(Self, Candidate)
					break
				end
			end
		end
		Cell = Build(Self, CellType)
	end
	local Current = Cell :: CellData
	Self.Generation += 1
	Self.Assignments += 1
	local Assignment : AssignmentData = setmetatable({
		Key = Key,
		Index = Index,
		Generation = Self.Generation,
		Payload = Item,
		Alive = true,
		Active = false,
		Cell = Current,
		Owner = nil,
		Connections = {},
		Cleanups = {},
		Guards = {},
	}, AssignmentMetatable) :: any
	Current.Assignment = Assignment
	local Passed, Cause = pcall(function()
		Graph.WithOwner(Current.Owner, function()
			local Owner = Graph.Scope(function(AssignmentOwner : Graph.Node<any>)
				Assignment.Owner = AssignmentOwner
				Current.ItemState:Set(Item, true)
				Current.IndexState:Set(Index)
			end)
			if Assignment.Alive then
				Assignment.Owner = Owner
			else
				Graph.Dispose(Owner)
			end
		end)
	end)
	if not Passed then
		pcall(Discard, Self, Current)
		error(Cause, 0)
	end
	return Current
end

const function Finish(Self : PoolData, Cells : { CellData }, Validate : (() -> boolean)?) : boolean
	assert(not Self.Closed, "Reusable cell pool destroyed")
	if #Cells == 0 then
		return true
	end
	Graph.Flush()
	if Validate and not Validate() then
		return false
	end
	for _, Cell in Cells do
		if Validate and not Validate() then
			return false
		end
		local Assignment = Cell.Assignment
		assert(
			Cell.Alive and Cell.Pool == Self and Assignment and Assignment.Alive and not Self.Closed,
			"Cannot finish revoked assignment"
		)
		local Definition = Cell.Definition :: Definition<any>
		Invoke(Assignment.Owner, Definition.Reset, Assignment)
		Graph.Flush()
		if Validate and not Validate() then
			return false
		end
		assert(
			Cell.Alive and Cell.Assignment == Assignment and Assignment.Alive and not Self.Closed,
			"Assignment revoked during Reset"
		)
		Invoke(Assignment.Owner, Definition.Attach, Assignment)
		assert(
			Cell.Alive and Cell.Assignment == Assignment and Assignment.Alive and not Self.Closed,
			"Assignment revoked during Attach"
		)
	end
	return true
end

const function Prepare(
	Self : PoolData,
	Key : Key,
	Index : number,
	Item : any,
	CellType : Key,
	Preferred : CellData?
) : CellData
	assert(not Self.Closed, "Reusable cell pool destroyed")
	local Cell : CellData? = Preferred
	local Bucket = Self.Available[CellType]
	if not Cell and Bucket then
		Cell = table.remove(Bucket)
		if Cell then
			Cell.IdleIndex = nil
		end
		if #Bucket == 0 then
			Self.Available[CellType] = nil
		end
	end
	if Cell then
		Self.Reuses += 1
	else
		if #Self.Cells >= Self.Capacity then
			for _, Candidate in Self.Cells do
				if not Candidate.Assignment then
					Discard(Self, Candidate)
					break
				end
			end
		end
		Cell = Build(Self, CellType)
	end
	local Current = Cell :: CellData
	Self.Generation += 1
	Self.Assignments += 1
	local Assignment : AssignmentData = setmetatable({
		Key = Key,
		Index = Index,
		Generation = Self.Generation,
		Payload = Item,
		Alive = true,
		Active = false,
		Cell = Current,
		Owner = nil,
		Connections = {},
		Cleanups = {},
		Guards = {},
	}, AssignmentMetatable) :: any
	Current.Assignment = Assignment
	local Passed, Cause = pcall(function()
		Graph.WithOwner(Current.Owner, function()
			local Owner = Graph.Scope(function(AssignmentOwner : Graph.Node<any>)
				Assignment.Owner = AssignmentOwner
				Current.ItemState:Set(Item, true)
				Current.IndexState:Set(Index)
				Graph.Flush()
				local Definition = Current.Definition :: Definition<any>
				Invoke(AssignmentOwner, Definition.Reset, Assignment)
				Graph.Flush()
				assert(
					Current.Alive and Assignment.Alive and not Self.Closed,
					"Assignment revoked during Reset"
				)
				Invoke(AssignmentOwner, Definition.Attach, Assignment)
				assert(
					Current.Alive and Assignment.Alive and not Self.Closed,
					"Assignment revoked during Attach"
				)
			end)
			if Assignment.Alive then
				Assignment.Owner = Owner
			else
				Graph.Dispose(Owner)
			end
		end)
	end)
	if not Passed then
		pcall(Discard, Self, Current)
		error(Cause, 0)
	end
	return Current
end

const function Commit(Self : PoolData, Cell : CellData)
	local Assignment = Cell.Assignment
	assert(
		not Self.Closed and Cell.Alive and Assignment and Assignment.Alive,
		"Cannot commit revoked assignment"
	)
	Assignment.Active = true
	local Configuration = Self.Configuration
	if Cell.Root and Configuration then
		Configuration.SetVisible(Cell.Root, true)
	end
end

Destroy = function(Self : PoolData)
	if Self.Closed then
		return
	end
	Self.Closed = true

	for _, Cell in Self.Cells do
		local Assignment = Cell.Assignment
		if Assignment then
			Assignment.Active = false
		end
	end
	local Failed, Cause = false, nil
	while #Self.Cells > 0 do
		local Passed, CurrentCause = pcall(function()
			Discard(Self, Self.Cells[#Self.Cells])
			return nil
		end)
		if not Passed and not Failed then
			Failed, Cause = true, CurrentCause
		end
	end
	table.clear(Self.Available)
	Self.Owner, Self.Configuration = nil, nil
	if Failed then
		error(Cause, 0)
	end
end

const PoolMetatable = table.freeze({
	__index = table.freeze({
		Warm = Warm,
		Stage = Stage,
		Finish = Finish,
		Prepare = Prepare,
		Commit = Commit,
		Release = Release,
		Discard = Discard,
		Destroy = Destroy,
		Refresh = function(Self : PoolData, Cell : CellData, Key : Key, Index : number, Item : any)
			local Previous = Cell.Assignment
			assert(
				Cell.Alive and Previous and Previous.Key == Key,
				"Refresh requires the same live logical item"
			)
			Cell.Assignment = nil
			local Passed, Cause = pcall(Revoke, Previous)
			if not Passed then
				pcall(Discard, Self, Cell)
				error(Cause, 0)
			end
			return Prepare(Self, Key, Index, Item, Cell.CellType, Cell)
		end,
		SetCapacity = function(Self : PoolData, Capacity : number)
			assert(Capacity >= 0 and Capacity % 1 == 0, "Invalid reusable cell capacity")
			Self.Capacity = Capacity
			for Index = #Self.Cells, 1, -1 do
				if #Self.Cells <= Capacity then
					break
				end
				local Cell = Self.Cells[Index]
				if not Cell.Assignment then
					Discard(Self, Cell)
				end
			end
		end,
	}),
})

const function New<ItemType>(Configuration : Configuration<ItemType>) : any
	local Owner = Graph.GetOwner()
	assert(Owner, "Reusable cell pool requires a declaring scope")
	local Self : PoolData = setmetatable(
		{
			Owner = Owner,
			Configuration = Configuration :: any,
			Cells = {},
			Available = {},
			Capacity = 0,
			Generation = 0,
			Closed = false,
			Constructed = 0,
			Destroyed = 0,
			Assignments = 0,
			Reuses = 0,
		},
		PoolMetatable
	) :: any
	Graph.Cleanup(function()
		Destroy(Self)
	end)
	return Self
end

return table.freeze({ New = New })
