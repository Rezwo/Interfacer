--!strict

const Compatibility = require("./Compatibility")
const Graph = require("./Graph")

local RegisterCleanup = Graph.Cleanup
local CreateState = Graph.State
local GetNodeValue = Graph.Node.Get
local SetNodeValue = Graph.Node.Set
local DestroyNode = Graph.Node.Destroy
local IsTrackingCalculation = Graph.IsReactive
local HasObservers = Graph.IsObserved
local GetCurrentOwner = Graph.GetOwner
local RegisterResource = Graph.Register
local ReportWarning = Compatibility.Warn

type StoreMetadata = {
	__index : (Proxy : any, PropertyKey : any) -> any,
	__newindex : (Proxy : any, PropertyKey : any, Value : any) -> (),
	__iter : (Proxy : any) -> ...any,
	__len : (Proxy : any) -> number,
	Target : { [any] : any },
	Nodes : { [any] : Graph.Node<any> },
	Parent : StoreMetadata?,
	Children : { [any] : boolean }?,
}

local ProxiesByRawTable = setmetatable({}, { __mode = "v" }) :: { [{ [any] : any }] : any }
local RawTablesByProxy = setmetatable({}, { __mode = "k" }) :: { [any] : { [any] : any } }

local StoreSymbol : any = table.freeze({})

const function GetRawStoreValue(Value : any) : any
	return if type(Value) == "table" then RawTablesByProxy[Value] or Value else Value
end

local ReadProxyKey : (Proxy : any, PropertyKey : any) -> any
local WriteProxyKey : (Proxy : any, PropertyKey : any, Value : any) -> ()
local IterateProxy : (Proxy : any) -> ...any
local GetProxyLength : (Proxy : any) -> number

const function DestroyProxy(Proxy : any)
	local Target = RawTablesByProxy[Proxy]
	if Target == nil then
		return
	end
	local Metadata = getmetatable(Proxy) :: StoreMetadata
	if ProxiesByRawTable[Target] == Proxy then
		ProxiesByRawTable[Target] = nil
	end
	RawTablesByProxy[Proxy] = nil
	RegisterResource(Proxy, nil)
	setmetatable(Proxy, nil)

	local Parent = Metadata.Parent
	if Parent and Parent.Children then
		Parent.Children[Proxy] = nil
	end
	local Children = Metadata.Children
	if Children then
		Metadata.Children = nil
		for Child in Children do
			DestroyProxy(Child)
		end
	end
	local Nodes = Metadata.Nodes
	for _, Record in Nodes do
		DestroyNode(Record)
	end
	table.clear(Nodes)
end

const function CreateProxy<ValueType>(Target : ValueType, ParentMetadata : StoreMetadata?) : ValueType
	local Cached = ProxiesByRawTable[Target :: any]
	if Cached then
		return Cached
	end

	local Nodes : { [any] : Graph.Node<any> } = {}
	local Metadata : StoreMetadata = {
		__index = ReadProxyKey,
		__newindex = WriteProxyKey,
		__iter = IterateProxy,
		__len = GetProxyLength,
		Target = Target :: any,
		Nodes = Nodes,
		Parent = ParentMetadata,
		Children = nil,
	}
	local Proxy = setmetatable({}, Metadata)

	ProxiesByRawTable[Target :: any] = Proxy
	RawTablesByProxy[Proxy] = Target :: any
	RegisterResource(Proxy, DestroyProxy)

	if ParentMetadata then
		local Children = ParentMetadata.Children
		if Children == nil then
			Children = {}
			ParentMetadata.Children = Children
		end
		(Children :: { [any] : boolean })[Proxy] = true
	elseif GetCurrentOwner() ~= nil then
		RegisterCleanup(Proxy)
	end

	return Proxy :: any
end

const function TeardownDisplaced(Target : { [any] : any }, Displaced : any)
	if type(Displaced) ~= "table" then
		return
	end
	local DisplacedProxy = ProxiesByRawTable[Displaced]
	if DisplacedProxy == nil then
		return
	end
	for _, Value in Target do
		if Value == Displaced then
			return
		end
	end
	DestroyProxy(DisplacedProxy)
end

const function FireTracker(Nodes : { [any] : any }, Target : { [any] : any })
	local Tracker = Nodes[StoreSymbol]
	if Tracker then
		SetNodeValue(Tracker, Target, true)
	end
end

const function ResyncIndices(
	Nodes : { [any] : any },
	Target : { [any] : any },
	From : number,
	Destination : number
)
	for Index = From, Destination do
		local Record = Nodes[Index]
		if Record then
			SetNodeValue(Record, Target[Index])
		end
	end
end

const function ReadTracker(Metadata : StoreMetadata) : { [any] : any }
	local Target = Metadata.Target
	local Nodes = Metadata.Nodes

	local Tracker = Nodes[StoreSymbol]
	if not Tracker then
		Tracker = CreateState(Target)
		Nodes[StoreSymbol] = Tracker
	end
	GetNodeValue(Tracker :: any)

	return Target
end

const function ValidatePos(Position : any, Max : number) : number
	if type(Position) ~= "number" then
		error(`Position must be a number, got {typeof(Position)}`, 3)
	elseif Position ~= math.floor(Position) or Position < 1 or Position > Max then
		error(`Position {Position} out of range [1, {Max}]`, 3)
	end
	return Position
end

function ReadProxyKey(Proxy : any, PropertyKey : any) : any
	local Metadata : StoreMetadata = getmetatable(Proxy)
	local Value = rawget(Metadata.Target, PropertyKey)

	if IsTrackingCalculation() then
		local Nodes = Metadata.Nodes
		local Record = Nodes[PropertyKey]
		if Record == nil then
			Record = CreateState(Value)
			Nodes[PropertyKey] = Record
		end
		GetNodeValue(Record)
	end

	if type(Value) == "table" and getmetatable(Value) == nil then
		return CreateProxy(Value, Metadata)
	end
	return Value
end

function WriteProxyKey(Proxy : any, PropertyKey : any, NewVal : any)
	local Metadata : StoreMetadata = getmetatable(Proxy)
	local Target = Metadata.Target
	local RawValue = GetRawStoreValue(NewVal)
	local OldValue = rawget(Target, PropertyKey)

	if OldValue ~= RawValue or type(RawValue) == "table" then
		rawset(Target, PropertyKey, RawValue)

		if type(OldValue) == "table" and OldValue ~= RawValue then
			TeardownDisplaced(Target, OldValue)
		end

		local Nodes = Metadata.Nodes
		local Record = Nodes[PropertyKey]
		if Record ~= nil then
			SetNodeValue(Record, RawValue)
			if
				RawValue == nil
				and not IsTrackingCalculation()
				and GetCurrentOwner() == nil
				and not HasObservers(Record)
			then
				Nodes[PropertyKey] = nil
				DestroyNode(Record)
			end
		end

		FireTracker(Nodes, Target)
	end
end

const function NextProxy(Metadata : StoreMetadata, Key : any) : (any, any)
	local PropertyKey, Value = next(Metadata.Target, Key)
	if type(Value) == "table" and getmetatable(Value) == nil then
		return PropertyKey, CreateProxy(Value, Metadata)
	end
	return PropertyKey, Value
end

function IterateProxy(Proxy : any)
	local Metadata : StoreMetadata = getmetatable(Proxy)
	ReadTracker(Metadata)
	return NextProxy, Metadata
end

function GetProxyLength(Proxy : any) : number
	return #ReadTracker(getmetatable(Proxy))
end

local Store = {}

function Store.New<ValueType>(InitialState : ValueType) : ValueType
	local PropertyState : any = InitialState
	assert(type(PropertyState) == "table", "Store initialState must be a table")
	if RawTablesByProxy[PropertyState] ~= nil then
		return PropertyState
	end
	return CreateProxy(PropertyState)
end

function Store.Destroy<ValueType>(Proxy : ValueType)
	DestroyProxy(Proxy)
end

function Store.Unwrap<ValueType>(Proxy : ValueType) : ValueType
	return (RawTablesByProxy[Proxy] or Proxy) :: ValueType
end

function Store.Insert(Proxy : any, PosOrValue : any, Value : any?)
	local Target = RawTablesByProxy[Proxy]
	if not Target then
		if Value == nil then
			table.insert(Proxy, PosOrValue)
		else
			table.insert(Proxy, PosOrValue, Value)
		end
		return
	end

	local Position : number
	local CurrentValue : any
	if Value == nil then
		Position = #Target + 1
		CurrentValue = PosOrValue
	else
		Position = ValidatePos(PosOrValue, #Target + 1)
		CurrentValue = Value
	end

	local RawValue = GetRawStoreValue(CurrentValue)
	table.insert(Target, Position, RawValue)

	local Nodes = (getmetatable(Proxy) :: StoreMetadata).Nodes
	ResyncIndices(Nodes, Target, Position, #Target)
	FireTracker(Nodes, Target)
end

function Store.Remove(Proxy : any, Position : number?) : any
	local Target = RawTablesByProxy[Proxy]
	if not Target then
		return table.remove(Proxy, Position)
	end

	local Length = #Target
	if Position ~= nil then
		ValidatePos(Position, Length)
	end
	if Length == 0 then
		return nil
	end

	local Index = Position or Length
	local Removed = table.remove(Target, Index)

	TeardownDisplaced(Target, Removed)

	local Nodes = (getmetatable(Proxy) :: StoreMetadata).Nodes
	ResyncIndices(Nodes, Target, Index, Length - 1)
	local TailNode = Nodes[Length]
	if TailNode then
		SetNodeValue(TailNode, nil)
	end

	FireTracker(Nodes, Target)
	return Removed
end

function Store.Move(Proxy : any, From : number, Destination : number)
	local Target = RawTablesByProxy[Proxy]
	if not Target then
		table.insert(Proxy, Destination, table.remove(Proxy, From))
		return
	end

	local Length = #Target
	ValidatePos(From, Length)
	ValidatePos(Destination, Length)
	if From == Destination then
		return
	end

	table.insert(Target, Destination, table.remove(Target, From))

	local Nodes = (getmetatable(Proxy) :: StoreMetadata).Nodes
	ResyncIndices(Nodes, Target, math.min(From, Destination), math.max(From, Destination))
	FireTracker(Nodes, Target)
end

const function IsArrayLike(ValueOrStorage : { [any] : any }) : boolean
	return rawget(ValueOrStorage, 1) ~= nil
end

const function IsArrayIndex(PropertyKey : any, ArrayLen : number) : boolean
	return type(PropertyKey) == "number"
		and PropertyKey >= 1
		and PropertyKey <= ArrayLen
		and PropertyKey == math.floor(PropertyKey)
end

local ReconcileTable : (
	Proxy : any,
	Target : { [any] : any },
	NewData : { [any] : any },
	ReconcileKey : string?
) -> ()

const function SynchronizeRawValue(PreviousValue : { [any] : any }, NewData : { [any] : any })
	for Field in PreviousValue do
		if rawget(NewData, Field) == nil then
			PreviousValue[Field] = nil
		end
	end
	for Field, Value in NewData do
		PreviousValue[Field] = GetRawStoreValue(Value)
	end
end

const function ReconcileLeaf(
	Target : { [any] : any },
	Nodes : { [any] : any },
	PropertyKey : any,
	RawNew : any,
	ReconcileKey : string?
) : boolean
	local OldValue = rawget(Target, PropertyKey)
	if OldValue == RawNew then
		return false
	end
	if type(OldValue) == "table" and type(RawNew) == "table" then
		local OldProxy = ProxiesByRawTable[OldValue]
		if OldProxy ~= nil then
			ReconcileTable(OldProxy, OldValue, RawNew, ReconcileKey)
		else
			SynchronizeRawValue(OldValue, RawNew)
		end
		return false
	end
	rawset(Target, PropertyKey, RawNew)
	if type(OldValue) == "table" then
		TeardownDisplaced(Target, OldValue)
	end
	local Record = Nodes[PropertyKey]
	if Record ~= nil then
		SetNodeValue(Record, RawNew)
	end
	return true
end

const function ReconcileArray(
	Target : { [any] : any },
	NewData : { [any] : any },
	Nodes : { [any] : any }
) : (number, boolean)
	local OldLen = #Target
	local NewLen = #NewData
	local Span = if OldLen > NewLen then OldLen else NewLen
	local Structural = false

	for Index = 1, Span do
		Structural = ReconcileLeaf(
			Target,
			Nodes,
			Index,
			GetRawStoreValue(rawget(NewData, Index)),
			nil
		) or Structural
	end

	return Span, Structural
end

const function ReconcileArrayKeyed(
	Target : { [any] : any },
	NewData : { [any] : any },
	Nodes : { [any] : any },
	ReconcileKey : string
) : (number, boolean)
	local OldLen = #Target
	local NewLen = #NewData
	local Span = if OldLen > NewLen then OldLen else NewLen
	local Structural = false

	local OldElems = table.create(OldLen)
	local OldByKey : { [any] : any } = {}
	for Index = 1, OldLen do
		local Element = rawget(Target, Index)
		if Element == nil then
			continue
		end
		OldElems[Index] = Element
		if type(Element) == "table" then
			local Key = rawget(Element, ReconcileKey)
			if Key ~= nil then
				OldByKey[Key] = Element
			end
		end
	end

	local Matched : { [any] : boolean } = {}
	local SeenKeys : { [any] : boolean } = {}
	for Index = 1, Span do
		local RawNew = GetRawStoreValue(rawget(NewData, Index))

		local Placed = RawNew
		if type(RawNew) == "table" then
			local Key = rawget(RawNew, ReconcileKey)
			local Reuse
			if Key ~= nil then
				if SeenKeys[Key] then
					ReportWarning(
						`[Flux] Store.reconcile: duplicate key "{tostring(Key)}" on field "{ReconcileKey}"; keys must be unique or the duplicate aliases one element`
					)
				else
					SeenKeys[Key] = true
				end
				Reuse = OldByKey[Key]
			else
				local PreviousValue : any = OldElems[Index]
				if
					type(PreviousValue) == "table"
					and rawget(PreviousValue, ReconcileKey) == nil
				then
					Reuse = PreviousValue
				end
			end
			if Reuse ~= nil then
				Matched[Reuse] = true
				local ChildProxy = ProxiesByRawTable[Reuse]
				if ChildProxy ~= nil then
					ReconcileTable(ChildProxy, Reuse, RawNew, ReconcileKey)
				else
					SynchronizeRawValue(Reuse, RawNew)
				end
				Placed = Reuse
			end
		end

		if rawget(Target, Index) ~= Placed then
			Structural = true
			rawset(Target, Index, Placed)
			local Record = Nodes[Index]
			if Record ~= nil then
				SetNodeValue(Record, Placed)
			end
		end
	end

	for Index = 1, OldLen do
		local Element = OldElems[Index]
		if type(Element) == "table" and not Matched[Element] then
			TeardownDisplaced(Target, Element)
		end
	end

	return Span, Structural
end

function ReconcileTable(
	Proxy : any,
	Target : { [any] : any },
	NewData : { [any] : any },
	ReconcileKey : string?
)
	local Nodes = (getmetatable(Proxy) :: StoreMetadata).Nodes
	local Structural = false

	local ArrayLen = 0
	if IsArrayLike(Target) or IsArrayLike(NewData) then
		if ReconcileKey ~= nil then
			ArrayLen, Structural = ReconcileArrayKeyed(Target, NewData, Nodes, ReconcileKey)
		else
			ArrayLen, Structural = ReconcileArray(Target, NewData, Nodes)
		end
	end

	for PropertyKey, NewVal in NewData do
		if IsArrayIndex(PropertyKey, ArrayLen) then
			continue
		end
		Structural = ReconcileLeaf(
			Target,
			Nodes,
			PropertyKey,
			GetRawStoreValue(NewVal),
			ReconcileKey
		) or Structural
	end

	for PropertyKey in Target do
		if IsArrayIndex(PropertyKey, ArrayLen) then
			continue
		end
		if rawget(NewData, PropertyKey) == nil then
			Structural = true
			ReconcileLeaf(Target, Nodes, PropertyKey, nil, ReconcileKey)
		end
	end

	if Structural then
		FireTracker(Nodes, Target)
	end
end

function Store.Reconcile<ValueType>(Proxy : ValueType, NewData : ValueType, PropertyKey : string?) : ValueType
	local Target = RawTablesByProxy[Proxy]
	assert(Target ~= nil, "Store.reconcile expects a store proxy")
	assert(type(NewData) == "table", "Store.reconcile newData must be a table")

	local RawNew = GetRawStoreValue(NewData)
	ReconcileTable(Proxy, Target, RawNew :: any, PropertyKey)
	return Proxy
end

return table.freeze(Store)
