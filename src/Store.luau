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
	__index : (Proxy : any, Key : any) -> any,
	__newindex : (Proxy : any, Key : any, Value : any) -> (),
	__iter : (Proxy : any) -> ...any,
	__len : (Proxy : any) -> number,
	Target : { [any] : any },
	Nodes : { [any] : Graph.Node<any> },
	Proxy : any,
	Parents : { [any] : boolean }?,
	Children : { [any] : boolean }?,
	Root : boolean?,
}

local ProxiesByRawTable : { [any] : any } = setmetatable({} :: { [any] : any }, { __mode = "v" })
local RawTablesByProxy : { [any] : { [any] : any } } = setmetatable({} :: { [any] : { [any] : any } }, { __mode = "k" })

local StoreSymbol : any = table.freeze({})
local NotANumberKey : any = table.freeze({})

const function GetRawStoreValue(Value : any) : any
	return if type(Value) == "table" then RawTablesByProxy[Value] or Value else Value
end

const function IsPlainMutableTable(Value : any) : boolean
	return type(Value) == "table" and getmetatable(Value) == nil and not table.isfrozen(Value)
end

const function IsRootReachable(StartProxy : any) : boolean
	local Metadata = getmetatable(StartProxy) :: StoreMetadata?
	if Metadata == nil then
		return false
	elseif Metadata.Root then
		return true
	end
	local Parents = Metadata.Parents
	if Parents == nil or next(Parents) == nil then
		return false
	end
	local Visited : { [any] : boolean } = { [StartProxy] = true }
	local Stack : { any } = { StartProxy }
	while #Stack > 0 do
		local Current = table.remove(Stack)
		local CurrentMetadata = getmetatable(Current) :: StoreMetadata?
		local CurrentParents = if CurrentMetadata then CurrentMetadata.Parents else nil
		if CurrentParents then
			for ParentProxy in CurrentParents do
				if not Visited[ParentProxy] then
					local ParentMetadata = getmetatable(ParentProxy) :: StoreMetadata?
					if ParentMetadata then
						if ParentMetadata.Root then
							return true
						end
						Visited[ParentProxy] = true
						table.insert(Stack, ParentProxy)
					end
				end
			end
		end
	end
	return false
end

const function LinkParent(ChildProxy : any, ParentProxy : any)
	if ParentProxy == nil or ChildProxy == ParentProxy then
		return
	end
	local ChildMetadata = getmetatable(ChildProxy) :: StoreMetadata?
	local ParentMetadata = getmetatable(ParentProxy) :: StoreMetadata?
	if ChildMetadata == nil or ParentMetadata == nil then
		return
	end
	local Parents = ChildMetadata.Parents
	if Parents == nil then
		Parents = {}
		ChildMetadata.Parents = Parents
	end
	(Parents :: { [any] : boolean })[ParentProxy] = true
	local Children = ParentMetadata.Children
	if Children == nil then
		Children = {}
		ParentMetadata.Children = Children
	end
	(Children :: { [any] : boolean })[ChildProxy] = true
end

const function LinkIfProxied(RawValue : any, ParentProxy : any)
	if type(RawValue) == "table" and ProxiesByRawTable[RawValue] ~= nil then
		LinkParent(ProxiesByRawTable[RawValue], ParentProxy)
	end
end

local ReadProxyKey : (Proxy : any, Key : any) -> any
local WriteProxyKey : (Proxy : any, Key : any, Value : any) -> ()
local IterateProxy : (Proxy : any) -> ...any
local GetProxyLength : (Proxy : any) -> number

const function DestroyProxy(Proxy : any, PriorVisits : { [any] : boolean }?)
	local Target = RawTablesByProxy[Proxy]
	if Target == nil then
		return
	end
	local Visited = PriorVisits or {}
	if Visited[Proxy] then
		return
	end
	Visited[Proxy] = true

	local Metadata = getmetatable(Proxy) :: StoreMetadata
	if ProxiesByRawTable[Target] == Proxy then
		ProxiesByRawTable[Target] = nil
	end
	RawTablesByProxy[Proxy] = nil
	RegisterResource(Proxy, nil)
	setmetatable(Proxy, nil)

	local Parents = Metadata.Parents
	if Parents then
		Metadata.Parents = nil
		for ParentProxy in Parents do
			local ParentMetadata = getmetatable(ParentProxy) :: StoreMetadata?
			if ParentMetadata and ParentMetadata.Children then
				ParentMetadata.Children[Proxy] = nil
			end
		end
	end
	local Children = Metadata.Children
	if Children then
		Metadata.Children = nil
		for ChildProxy in Children do
			local ChildMetadata = getmetatable(ChildProxy) :: StoreMetadata?
			if ChildMetadata then
				local ChildParents = ChildMetadata.Parents
				if ChildParents then
					ChildParents[Proxy] = nil
				end
				if not IsRootReachable(ChildProxy) then
					DestroyProxy(ChildProxy, Visited)
				end
			end
		end
	end
	local Nodes = Metadata.Nodes
	for _, Record in Nodes do
		DestroyNode(Record)
	end
	table.clear(Nodes)
end

const function DisposeRootProxy(Proxy : any)
	DestroyProxy(Proxy)
end

const function CreateProxy<ValueType>(Target : ValueType, ParentProxy : any?) : ValueType
	local RawTarget : any = Target
	local Cached = ProxiesByRawTable[RawTarget]
	if Cached then
		if ParentProxy ~= nil then
			LinkParent(Cached, ParentProxy)
		else
			local CachedMetadata = getmetatable(Cached) :: StoreMetadata?
			if CachedMetadata ~= nil then
				local WasRoot = CachedMetadata.Root
				CachedMetadata.Root = true
				if not WasRoot and GetCurrentOwner() ~= nil then
					RegisterCleanup(Cached)
				end
			end
		end
		return Cached
	end

	local Nodes : { [any] : Graph.Node<any> } = {}
	local Metadata : StoreMetadata = {
		__index = ReadProxyKey,
		__newindex = WriteProxyKey,
		__iter = IterateProxy,
		__len = GetProxyLength,
		Target = RawTarget,
		Nodes = Nodes,
		Proxy = nil,
		Parents = nil,
		Children = nil,
		Root = ParentProxy == nil,
	}
	local Proxy : any = setmetatable({}, Metadata)
	Metadata.Proxy = Proxy

	ProxiesByRawTable[RawTarget] = Proxy
	RawTablesByProxy[Proxy] = RawTarget
	RegisterResource(Proxy, DisposeRootProxy)

	if ParentProxy ~= nil then
		LinkParent(Proxy, ParentProxy)
	elseif GetCurrentOwner() ~= nil then
		RegisterCleanup(Proxy)
	end

	return Proxy
end

const function TeardownDisplaced(ParentProxy : any, Target : { [any] : any }, Displaced : any)
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
	local ParentMetadata = getmetatable(ParentProxy) :: StoreMetadata?
	if ParentMetadata and ParentMetadata.Children then
		ParentMetadata.Children[DisplacedProxy] = nil
	end
	local ChildMetadata = getmetatable(DisplacedProxy) :: StoreMetadata?
	if ChildMetadata then
		if ChildMetadata.Parents then
			ChildMetadata.Parents[ParentProxy] = nil
		end
		if not IsRootReachable(DisplacedProxy) then
			DestroyProxy(DisplacedProxy)
		end
	end
end

const function SetKeyValue(Nodes : { [any] : any }, Key : any, Record : any, Value : any)
	SetNodeValue(Record, Value)
	if Value == nil and not IsTrackingCalculation() and GetCurrentOwner() == nil and not HasObservers(Record) then
		Nodes[Key] = nil
		DestroyNode(Record)
	end
end

const function FireTracker(Nodes : { [any] : any }, Target : { [any] : any })
	local Tracker = Nodes[StoreSymbol]
	if Tracker then
		SetNodeValue(Tracker, Target, true)
	end
end

const function ResynchronizeIndices(Nodes : { [any] : any }, Target : { [any] : any }, From : number, Destination : number)
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
	GetNodeValue(Tracker)

	return Target
end

const function ValidatePosition(Position : any, MaximumPosition : number) : number
	if type(Position) ~= "number" then
		error(`Position must be a number, got {typeof(Position)}`, 3)
	elseif Position ~= math.floor(Position) or Position < 1 or Position > MaximumPosition then
		error(`Position {Position} out of range [1, {MaximumPosition}]`, 3)
	end
	return Position
end

function ReadProxyKey(Proxy : any, Key : any) : any
	local Metadata : StoreMetadata = getmetatable(Proxy)
	local Value = rawget(Metadata.Target, Key)

	if IsTrackingCalculation() then
		local Nodes = Metadata.Nodes
		local Record = Nodes[Key]
		if Record == nil then
			Record = CreateState(Value)
			Nodes[Key] = Record
		end
		GetNodeValue(Record)
	end

	if IsPlainMutableTable(Value) then
		return CreateProxy(Value, Proxy)
	end
	return Value
end

function WriteProxyKey(Proxy : any, Key : any, NewValue : any)
	local Metadata : StoreMetadata = getmetatable(Proxy)
	local Target = Metadata.Target
	local RawValue = GetRawStoreValue(NewValue)
	local OldValue = rawget(Target, Key)
	if OldValue == RawValue and type(RawValue) ~= "table" then
		return
	end

	rawset(Target, Key, RawValue)
	LinkIfProxied(RawValue, Proxy)
	if type(OldValue) == "table" and OldValue ~= RawValue then
		TeardownDisplaced(Proxy, Target, OldValue)
	end

	local Nodes = Metadata.Nodes
	local Record = Nodes[Key]
	if Record ~= nil then
		SetKeyValue(Nodes, Key, Record, RawValue)
	end

	FireTracker(Nodes, Target)
end

const function NextProxy(Metadata : StoreMetadata, KeyValue : any) : (any, any)
	local Key, Value = next(Metadata.Target, KeyValue)
	if IsPlainMutableTable(Value) then
		return Key, CreateProxy(Value, Metadata.Proxy)
	end
	return Key, Value
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

function Store.Insert(Proxy : any, PositionOrValue : any, Value : any?)
	local Target = RawTablesByProxy[Proxy]
	if not Target then
		if Value == nil then
			table.insert(Proxy, PositionOrValue)
		else
			table.insert(Proxy, PositionOrValue, Value)
		end
		return
	end

	local Position : number
	local CurrentValue : any
	if Value == nil then
		Position = #Target + 1
		CurrentValue = PositionOrValue
	else
		Position = ValidatePosition(PositionOrValue, #Target + 1)
		CurrentValue = Value
	end

	local RawValue = GetRawStoreValue(CurrentValue)
	table.insert(Target, Position, RawValue)
	LinkIfProxied(RawValue, Proxy)

	local Nodes = (getmetatable(Proxy) :: StoreMetadata).Nodes
	ResynchronizeIndices(Nodes, Target, Position, #Target)
	FireTracker(Nodes, Target)
end

function Store.Remove(Proxy : any, Position : number?) : any
	local Target = RawTablesByProxy[Proxy]
	if not Target then
		return table.remove(Proxy, Position)
	end

	local Length = #Target
	if Position ~= nil then
		ValidatePosition(Position, Length)
	end
	if Length == 0 then
		return nil
	end

	local RemovalIndex = Position or Length
	local Removed = table.remove(Target, RemovalIndex)

	TeardownDisplaced(Proxy, Target, Removed)

	local Nodes = (getmetatable(Proxy) :: StoreMetadata).Nodes
	ResynchronizeIndices(Nodes, Target, RemovalIndex, Length - 1)
	local TailRecord = Nodes[Length]
	if TailRecord then
		SetKeyValue(Nodes, Length, TailRecord, nil)
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
	ValidatePosition(From, Length)
	ValidatePosition(Destination, Length)
	if From == Destination then
		return
	end

	table.insert(Target, Destination, table.remove(Target, From))

	local Nodes = (getmetatable(Proxy) :: StoreMetadata).Nodes
	ResynchronizeIndices(Nodes, Target, math.min(From, Destination), math.max(From, Destination))
	FireTracker(Nodes, Target)
end

const function IsArrayLike(Values : { [any] : any }) : boolean
	return rawget(Values, 1) ~= nil
end

const function IsArrayIndex(Key : any, ArrayLength : number) : boolean
	return type(Key) == "number" and Key >= 1 and Key <= ArrayLength and Key == math.floor(Key)
end

local ReconcileTable : (
	Proxy : any,
	Target : { [any] : any },
	NewData : { [any] : any },
	ReconcileKey : string?,
	Visited : { [any] : boolean }?
) -> ()

const function DestroyOrphanedProxy(RawValue : any)
	if type(RawValue) == "table" then
		local CachedProxy = ProxiesByRawTable[RawValue]
		if CachedProxy ~= nil and not IsRootReachable(CachedProxy) then
			DestroyProxy(CachedProxy)
		end
	end
end

const function SynchronizeRawValue(
	PreviousValue : { [any] : any },
	NewData : { [any] : any },
	ReconcileKey : string?,
	Visited : { [any] : boolean }
)
	if Visited[PreviousValue] then
		return
	end
	Visited[PreviousValue] = true
	for Field, PreviousFieldValue in PreviousValue do
		if rawget(NewData, Field) == nil then
			PreviousValue[Field] = nil
			DestroyOrphanedProxy(PreviousFieldValue)
		end
	end
	for Field, Value in NewData do
		local NewRawValue = GetRawStoreValue(Value)
		local OldFieldValue = rawget(PreviousValue, Field)
		if type(OldFieldValue) == "table" and IsPlainMutableTable(OldFieldValue) and IsPlainMutableTable(NewRawValue) then
			local ChildProxy = ProxiesByRawTable[OldFieldValue]
			if ChildProxy ~= nil then
				ReconcileTable(ChildProxy, OldFieldValue, NewRawValue, ReconcileKey, Visited)
			elseif OldFieldValue ~= NewRawValue then
				SynchronizeRawValue(OldFieldValue, NewRawValue, ReconcileKey, Visited)
			end
		else
			rawset(PreviousValue, Field, NewRawValue)
			if OldFieldValue ~= NewRawValue then
				DestroyOrphanedProxy(OldFieldValue)
			end
		end
	end
end

const function ReconcileLeaf(
	Proxy : any,
	Target : { [any] : any },
	Nodes : { [any] : any },
	Key : any,
	NewRawValue : any,
	ReconcileKey : string?,
	Visited : { [any] : boolean }
) : boolean
	local OldValue = rawget(Target, Key)
	if OldValue == NewRawValue then
		return false
	end
	if type(OldValue) == "table" and IsPlainMutableTable(OldValue) and IsPlainMutableTable(NewRawValue) then
		local OldProxy = ProxiesByRawTable[OldValue]
		if OldProxy ~= nil then
			ReconcileTable(OldProxy, OldValue, NewRawValue, ReconcileKey, Visited)
		else
			SynchronizeRawValue(OldValue, NewRawValue, ReconcileKey, Visited)
		end
		return false
	end
	rawset(Target, Key, NewRawValue)
	if type(OldValue) == "table" then
		TeardownDisplaced(Proxy, Target, OldValue)
	end
	LinkIfProxied(NewRawValue, Proxy)
	local Record = Nodes[Key]
	if Record ~= nil then
		SetKeyValue(Nodes, Key, Record, NewRawValue)
	end
	return true
end

const function ReconcileArray(
	Proxy : any,
	Target : { [any] : any },
	NewData : { [any] : any },
	Nodes : { [any] : any },
	Visited : { [any] : boolean }
) : (number, boolean)
	local OldLength = #Target
	local NewLength = #NewData
	local Span = if OldLength > NewLength then OldLength else NewLength
	local Structural = false

	for Index = 1, Span do
		Structural = ReconcileLeaf(Proxy, Target, Nodes, Index, GetRawStoreValue(rawget(NewData, Index)), nil, Visited) or Structural
	end

	return Span, Structural
end

const function NormalizeReconcileKey(KeyValue : any) : any
	return if KeyValue ~= KeyValue then NotANumberKey else KeyValue
end

const function ReconcileArrayKeyed(
	Proxy : any,
	Target : { [any] : any },
	NewData : { [any] : any },
	Nodes : { [any] : any },
	ReconcileKey : string,
	Visited : { [any] : boolean }
) : (number, boolean)
	local OldLength = #Target
	local NewLength = #NewData
	local Span = if OldLength > NewLength then OldLength else NewLength
	local Structural = false

	local OldElements = table.create(Span)
	local OldByKey : { [any] : any } = {}
	for Index = 1, Span do
		local Element = rawget(Target, Index)
		if Element == nil then
			continue
		end
		OldElements[Index] = Element
		if type(Element) == "table" then
			local KeyValue = rawget(Element, ReconcileKey)
			if KeyValue ~= nil then
				OldByKey[NormalizeReconcileKey(KeyValue)] = Element
			end
		end
	end

	local Matched : { [any] : boolean } = {}
	local SeenKeys : { [any] : boolean } = {}
	for Index = 1, Span do
		local NewRawValue = GetRawStoreValue(rawget(NewData, Index))

		local Placed = NewRawValue
		if IsPlainMutableTable(NewRawValue) then
			local KeyValue = rawget(NewRawValue, ReconcileKey)
			local Reuse
			if KeyValue ~= nil then
				local KeySlot = NormalizeReconcileKey(KeyValue)
				if SeenKeys[KeySlot] then
					ReportWarning(
						`[Flux] Store.reconcile : duplicate key "{tostring(KeyValue)}" on field "{ReconcileKey}"; keys must be unique or the duplicate aliases one element`
					)
				else
					SeenKeys[KeySlot] = true
				end
				Reuse = OldByKey[KeySlot]
			else
				local PreviousValue : any = OldElements[Index]
				if IsPlainMutableTable(PreviousValue) and rawget(PreviousValue, ReconcileKey) == nil then
					Reuse = PreviousValue
				end
			end
			if Reuse ~= nil and IsPlainMutableTable(Reuse) then
				Matched[Reuse] = true
				local ChildProxy = ProxiesByRawTable[Reuse]
				if ChildProxy ~= nil then
					ReconcileTable(ChildProxy, Reuse, NewRawValue, ReconcileKey, Visited)
				else
					SynchronizeRawValue(Reuse, NewRawValue, ReconcileKey, Visited)
				end
				Placed = Reuse
			end
		end

		if rawget(Target, Index) ~= Placed then
			Structural = true
			rawset(Target, Index, Placed)
			if Placed == NewRawValue then
				LinkIfProxied(Placed, Proxy)
			end
			local Record = Nodes[Index]
			if Record ~= nil then
				SetKeyValue(Nodes, Index, Record, Placed)
			end
		end
	end

	for Index = 1, Span do
		local Element = OldElements[Index]
		if type(Element) == "table" and not Matched[Element] then
			TeardownDisplaced(Proxy, Target, Element)
		end
	end

	return Span, Structural
end

function ReconcileTable(
	Proxy : any,
	Target : { [any] : any },
	NewData : { [any] : any },
	ReconcileKey : string?,
	Visited : { [any] : boolean }?
)
	local PriorVisits = Visited or {}
	if PriorVisits[Target] then
		return
	end
	PriorVisits[Target] = true
	local Nodes = (getmetatable(Proxy) :: StoreMetadata).Nodes
	local Structural = false

	local ArrayLength = 0
	if IsArrayLike(Target) or IsArrayLike(NewData) then
		if ReconcileKey ~= nil then
			ArrayLength, Structural = ReconcileArrayKeyed(Proxy, Target, NewData, Nodes, ReconcileKey, PriorVisits)
		else
			ArrayLength, Structural = ReconcileArray(Proxy, Target, NewData, Nodes, PriorVisits)
		end
	end

	for Key, NewValue in NewData do
		if IsArrayIndex(Key, ArrayLength) then
			continue
		end
		Structural = ReconcileLeaf(Proxy, Target, Nodes, Key, GetRawStoreValue(NewValue), ReconcileKey, PriorVisits) or Structural
	end

	for Key in Target do
		if IsArrayIndex(Key, ArrayLength) then
			continue
		end
		if rawget(NewData, Key) == nil then
			Structural = true
			ReconcileLeaf(Proxy, Target, Nodes, Key, nil, ReconcileKey, PriorVisits)
		end
	end

	if Structural then
		FireTracker(Nodes, Target)
	end
end

function Store.Reconcile<ValueType>(Proxy : ValueType, NewData : ValueType, Key : string?) : ValueType
	local Target = RawTablesByProxy[Proxy]
	assert(Target ~= nil, "Store.reconcile expects a store proxy")
	assert(type(NewData) == "table", "Store.reconcile newData must be a table")

	local NewRawValue : { [any] : any } = GetRawStoreValue(NewData)
	ReconcileTable(Proxy, Target, NewRawValue, Key)
	return Proxy
end

return table.freeze(Store)
